defmodule OnePlaylist.Transfers.Runner do
  @moduledoc """
  Executes one transfer, and can be asked to execute it again safely.

  ## Four phases, in this order for a reason

  1. **Ensure a destination playlist.** Created only if the transfer does not
     already name one. This single `nil` check is what stops a retry leaving a
     trail of half-filled duplicate playlists behind it.
  2. **Snapshot the destination.** What it already holds, before writing
     anything. `docs/reference/domain.md` requires that a retried add must not
     duplicate, and a snapshot is the only way to keep that promise against a
     provider whose append does not deduplicate — TIDAL's does not.
  3. **Resolve every source track**, against candidates fetched per track.
     Nothing is written in this phase, so a failure here costs requests and no
     inconsistency.
  4. **Write, in batches**, then record the report.

  Resolving before writing is not just tidiness. It means the expensive,
  failure-prone half runs without touching the destination, and the write half
  is a short burst against a provider that rate-limits writes hard.

  ## Idempotency is a diff, not a flag

  Re-running does not consult a "done" marker. It re-reads the destination and
  adds what is missing, which is the same computation as the first run and
  degrades correctly when something outside changed — a user who deleted three
  tracks by hand gets them back, and one who added them by hand does not get
  duplicates.

  The report says so too: a track that resolved but was already present is
  recorded `:already_present` rather than `:matched`, so a second run's report
  reads "nothing to do" rather than looking mysteriously empty.

  ## Batching

  Writes go out in chunks rather than one call per track. TIDAL returned four
  429s out of five rapid single deletes, and a 200-track playlist as 200 calls
  would spend the whole retry budget discovering that; as four calls of fifty
  it is four calls.
  """

  use Bond
  use Errata

  alias OnePlaylist.Library.Identities
  alias OnePlaylist.Matching
  alias OnePlaylist.Matching.Match
  alias OnePlaylist.Matching.TrackNotMatched
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Music.Work
  alias OnePlaylist.MusicBrainz
  alias OnePlaylist.Providers
  alias OnePlaylist.Transfers.Candidate
  alias OnePlaylist.Transfers.PlaylistTooLarge
  alias OnePlaylist.Transfers.Progress
  alias OnePlaylist.Transfers.Source
  alias OnePlaylist.Transfers.SourceMissing
  alias OnePlaylist.Transfers.Transfer
  alias OnePlaylist.Transfers.TransferItem
  alias OnePlaylist.Transfers.TransferOverride
  alias OnePlaylist.Transfers.WriteNotConfirmed

  # Large enough that a long playlist is a handful of calls, small enough that
  # one rejected batch does not cost the whole transfer a retry.
  @batch_size 50

  @typedoc "What one source track resolved to, before anything was written."
  @type resolution ::
          {non_neg_integer(), OnePlaylist.Music.Track.t(),
           {:ok, Matching.Match.t()} | {:error, Exception.t()}}

  @doc """
  Runs the transfer, returning it with its counters filled in.

  Safe to call again on the same transfer: see the module documentation.
  """
  # The product's central promise, stated where it can be checked. A run that
  # finished must account for every source track exactly once — `<=` would let a
  # dropped track pass, which is the failure this application is organised
  # against, and it is invisible in every other signal: the transfer completes,
  # the report looks plausible, and the playlist is short.
  #
  # Strictly stronger than the `@invariant` on `Transfer`, which must use `<=`
  # because a transfer legitimately passes through partial states while running.
  # Here the run is over, so equality is the honest claim, and that difference is
  # the whole reason this assertion exists separately.
  #
  # `added_at_most_matched` deliberately does *not* sit here beside it. Unlike
  # the equality above, it is identical to `Transfer`'s invariant, and every
  # counter this function returns passes through `Transfer.reset_counters/1`,
  # `with_total/2`, `record_matched/2` or `record_unmatched/1` — each of which
  # checks it on the way out. Meyer's Non-Redundancy principle, and the
  # invariant is also the better locus: it names the counter update that broke
  # the law rather than the run that contained it.
  @post whenever({:ok, completed} <- result),
    every_track_accounted_for:
      completed.matched_count + completed.unmatched_count == completed.total_tracks,
    # The database half of the same promise. The counters could agree with each
    # other and still disagree with the report a user actually reads; this is
    # the one place both are in scope at once.
    reported_every_track: item_count(completed) == completed.total_tracks
  @spec run(Transfer.t()) :: {:ok, Transfer.t()} | {:error, Exception.t()}
  def run(%Transfer{} = transfer) do
    with {:ok, destination_connection} <-
           connection(transfer.user_id, transfer.destination_provider),
         {:ok, destination_adapter} <- Providers.adapter(transfer.destination_provider),
         {:ok, tracks} <- read_source(transfer),
         {:ok, transfer, destination} <-
           ensure_destination(transfer, destination_adapter, destination_connection),
         {:ok, present} <-
           destination_adapter.playlist_track_ids(destination_connection, destination),
         {resolutions, candidates} =
           resolve_all(
             transfer,
             tracks,
             destination_adapter,
             destination_connection,
             transfer.threshold
           ),
         {:ok, added} <-
           write_missing(
             resolutions,
             MapSet.new(present),
             destination_adapter,
             destination_connection,
             destination
           ),
         :ok <-
           confirm_written(
             resolutions,
             added,
             destination_adapter,
             destination_connection,
             destination
           ) do
      finish(transfer, tracks, resolutions, added, candidates)
    end
  end

  @doc """
  How many report rows exist for a transfer.

  Public because `run/1` names it in a postcondition, and an assertion rendered
  into the documentation should reference something a reader can look up.
  """
  @spec item_count(Transfer.t()) :: non_neg_integer()
  def item_count(%Transfer{id: nil}), do: 0

  def item_count(%Transfer{} = transfer),
    do: OnePlaylist.Transfers.count_items(transfer)

  defp connection(user_id, provider) do
    case Providers.fetch_connection(user_id, provider) do
      {:ok, connection} -> Providers.ensure_fresh(connection)
      {:error, _reason} = error -> error
    end
  end

  # The one place the two kinds of source differ. Everything after this point —
  # matching, the destination snapshot, the write, the report — is the same
  # whether the tracks came from a catalogue or from somebody's spreadsheet,
  # which is the argument for importing through this pipeline at all.
  # The size guard sits here rather than in either branch, so a source that is
  # too big is refused the same way whether it came from a provider or a file.
  defp read_source(%Transfer{} = transfer) do
    with {:ok, tracks} <- read_tracks(transfer), do: within_limit(tracks)
  end

  defp within_limit(tracks) do
    limit = max_tracks()

    if length(tracks) > limit do
      {:error,
       Errata.create(PlaylistTooLarge,
         reason: :too_many_tracks,
         # "More than the limit" rather than the exact count: the streaming read
         # stops at `limit + 1` on purpose, and reporting a number it did not
         # finish counting would be a guess dressed as a fact.
         context: %{limit: limit}
       )}
    else
      {:ok, tracks}
    end
  end

  # Above any real playlist. See `OnePlaylist.Transfers.PlaylistTooLarge` for
  # why this is a safety valve rather than a rationing decision.
  @default_max_tracks 10_000

  defp max_tracks do
    :one_playlist
    |> Application.get_env(OnePlaylist.Transfers, [])
    |> Keyword.get(:max_tracks, @default_max_tracks)
  end

  defp read_tracks(%Transfer{source_provider: :file} = transfer) do
    # Already parsed, in the request that received the upload. This worker has
    # no session and therefore no way to read Storage without the service key;
    # see `OnePlaylist.Transfers.Source`.
    case OnePlaylist.Repo.get(Source, transfer.id) do
      %Source{} = source ->
        {:ok, Source.tracks(source)}

      nil ->
        {:error,
         Errata.create(SourceMissing,
           reason: :not_parsed,
           context: %{transfer_id: transfer.id}
         )}
    end
  end

  defp read_tracks(%Transfer{} = transfer) do
    with {:ok, connection} <- connection(transfer.user_id, transfer.source_provider),
         {:ok, adapter} <- Providers.adapter(transfer.source_provider),
         {:ok, stream} <- adapter.stream_tracks(connection, transfer.source_playlist_id, []) do
      # One past the limit, so `within_limit/1` can tell "at the limit" from
      # "over it" without draining the stream. A provider that reports a
      # playlist size it then exceeds, or a paging bug that never terminates,
      # stops here rather than in the worker's memory.
      {:ok, Enum.take(stream, max_tracks() + 1)}
    end
  rescue
    error -> {:error, error}
  end

  # The `nil` check that makes a retry safe. A transfer that already named a
  # destination playlist reuses it; only a first run creates one.
  defp ensure_destination(%Transfer{destination_playlist_id: id} = transfer, _adapter, _conn)
       when is_binary(id),
       do: {:ok, transfer, id}

  defp ensure_destination(%Transfer{} = transfer, adapter, connection) do
    name = transfer.destination_playlist_name || transfer.source_playlist_name || "Transferred"

    with {:ok, playlist} <- adapter.create_playlist(connection, name, []) do
      # Persisted immediately, before a single track is written. If the process
      # dies during the writes, the next run finds this and adds to the same
      # playlist instead of creating a second one.
      {:ok, transfer} =
        OnePlaylist.Transfers.record_progress(transfer, %{
          destination_playlist_id: playlist.provider_id,
          destination_playlist_name: playlist.name
        })

      {:ok, transfer, playlist.provider_id}
    end
  end

  # Reports as it goes rather than at the end. Matching a playlist is one
  # rate-limited provider search per track, so a 58 track import is a minute or
  # more of a page that otherwise says only "running".
  #
  # Batched through `Progress`, because the naive reading of "as it goes" is one
  # broadcast per track and that does not survive a 5,000 track playlist. The
  # final flush is not optional: without it a run ending mid-batch strands its
  # last tracks.
  defp resolve_all(transfer, tracks, adapter, connection, threshold) do
    total = length(tracks)

    overrides = OnePlaylist.Transfers.overrides(transfer)

    {resolved, {progress, candidates}} =
      tracks
      |> Enum.with_index()
      |> Enum.map_reduce({Progress.new(total), %{}}, fn {track, position},
                                                        {progress, candidates} ->
        {outcome, ranked} =
          resolve(track, adapter, connection, threshold, Map.get(overrides, position))

        {batch, progress} = Progress.add(progress, provisional_item(position, track, outcome))

        _ = report(transfer, batch, progress)

        {{position, track, outcome}, {progress, remember(candidates, position, outcome, ranked)}}
      end)

    {batch, progress} = Progress.flush(progress)
    _ = report(transfer, batch, progress)

    {resolved, candidates}
  end

  # How many alternatives a person is offered for one track. Enough to choose
  # between three recordings of a song and few enough that a report full of them
  # stays a reasonable row.
  @candidate_limit 5

  # Kept only where somebody might act on them. An exact identifier match is not
  # overridden by anyone, and keeping five candidates for every track of a
  # 5,000 track transfer is megabytes of rows nobody opens. A track that matched
  # inexactly, or failed to match at all, is exactly the one worth showing the
  # alternatives for.
  defp remember(candidates, _position, {:ok, %Match{strategy: strategy}}, _ranked)
       when strategy in [:isrc, :upc_position],
       do: candidates

  defp remember(candidates, _position, _outcome, []), do: candidates

  defp remember(candidates, position, _outcome, ranked),
    do: Map.put(candidates, position, Candidate.top(ranked, @candidate_limit))

  # An empty batch is the ordinary case between flushes, and broadcasting it
  # would undo the batching.
  defp report(_transfer, [], _progress), do: :ok

  defp report(transfer, batch, %Progress{} = progress) do
    OnePlaylist.Transfers.report_progress(transfer, progress, batch)
  end

  # What a watcher can be shown before the writes happen. Deliberately says
  # `:matched` for anything resolved, because the difference between that and
  # `:already_present` is not known yet: it depends on what the destination
  # already holds, which is compared after every track has been resolved. The
  # final report corrects it.
  # A provisional row is drawn by the same template as a persisted one, so it
  # has to carry the same fields. Asserted rather than commented, because the
  # failure mode is a `KeyError` in the middle of a running transfer and the
  # thing that causes it is a migration in a different file — adding a column to
  # the report is all it takes.
  #
  # `TransferItem.display_fields/0` is derived from the schema, so a column
  # added later is required here without anyone remembering to come back.
  @post shaped_like_a_report_row:
          Enum.all?(TransferItem.display_fields(), &Map.has_key?(result, &1))
  defp provisional_item(position, track, outcome) do
    base = %{
      position: position,
      source_title: track.title,
      source_artist: primary_artist(track),
      source_album: track.album,
      source_artwork_url: track.artwork_url,
      source_track_id: track.provider_id,
      # Nothing is stored mid-run, so there is nothing to offer yet. The
      # persisted report brings the alternatives with it.
      candidates: []
    }

    case outcome do
      {:ok, match} ->
        Map.merge(base, %{
          outcome: :matched,
          destination_track_id: match.track.provider_id,
          destination_title: match.track.title,
          destination_artist: List.first(match.track.artists),
          destination_album: match.track.album,
          destination_artwork_url: match.track.artwork_url,
          confidence: to_string(match.confidence),
          score: match.score,
          strategy: to_string(match.strategy),
          reason: nil
        })

      {:error, error} ->
        Map.merge(base, %{
          outcome: :unmatched,
          destination_track_id: nil,
          destination_title: nil,
          destination_artist: nil,
          destination_album: nil,
          destination_artwork_url: nil,
          confidence: nil,
          score: nil,
          strategy: nil,
          reason: to_string(Errata.reason(error))
        })
    end
  end

  defp primary_artist(track), do: List.first(track.artists)

  # Returns the outcome *and* the ranking behind it, because the alternatives
  # are what a person needs to correct a wrong answer and they are gone the
  # moment this returns otherwise.
  defp resolve(track, adapter, connection, threshold, override)

  defp resolve(track, _adapter, connection, _threshold, %TransferOverride{} = override) do
    chosen = TransferOverride.as_track(override, connection.provider)
    match = Match.chosen_by_hand(track, chosen)

    # The strongest evidence the spine can be given, and the reason
    # `docs/reference/domain.md` §5 argues a correction is worth more than a
    # better scorer: corrected once, it is corrected for **every future
    # transfer of that recording**, not only for the report row that prompted
    # it. `learn/2` admits it because `:chosen` outranks every identifier rung.
    recording = Identities.anchor(track)

    Identities.record_source(recording, track)
    learn(recording, {:ok, match})

    {{:ok, match}, []}
  end

  # A correction the user already made. Consulted before the ladder rather than
  # applied to its output, because `record_run/3` rewrites every report row and
  # a correction living there would be destroyed by the next retry. See the
  # migration that creates `transfer_overrides`.
  defp resolve(track, adapter, connection, threshold, nil) do
    cond do
      # The track came from the catalogue it is going to, so its own id is
      # already the answer and there is nothing to search for. The condition is
      # a *capability* rather than a comparison of provider names, because two
      # Subsonic servers are both `:subsonic` and share no ids — see
      # `same_service?/3`.
      same_service?(track, adapter, connection) ->
        # Still worth learning from. The source identity is free and true
        # whichever way the transfer went.
        track |> Identities.anchor() |> Identities.record_source(track)

        {{:ok, Match.same_service(track)}, []}

      accepts_any_track?(adapter) ->
        accept_then_learn(track, adapter, connection, threshold)

      true ->
        spine_first(track, adapter, connection, threshold)
    end
  end

  # A destination that accepts any track has no catalogue to look anything up
  # in, so there is nothing to recall — and anchoring first would change what
  # the search sees, because `anchor/1` writes to `library_recordings`, which is
  # the very store `OnePlaylist.Providers.Library` searches. It would turn every
  # `stored` row into an identifier match against a recording this run had just
  # created. So the spine learns from that case afterwards, not before.
  defp accept_then_learn(track, adapter, connection, threshold) do
    {resolved, ranked} = search_and_decide(track, adapter, connection, threshold)

    recording = Identities.anchor(track)
    Identities.record_source(recording, track)
    learn(recording, resolved)

    {resolved, ranked}
  end

  # Safe only when the provider says an id means the same thing to every
  # connection of it. TIDAL's ids name entries in one catalogue that every
  # account shares; two Subsonic connections are two different servers, where an
  # id from one names nothing on the other — or something else entirely, which
  # is the failure worth refusing to risk.
  defp same_service?(track, adapter, connection) do
    track.provider == connection.provider and :global_ids in adapter.capabilities()
  end

  defp spine_first(track, adapter, connection, threshold) do
    recording = Identities.anchor(track)

    # Recall *before* recording the source, so the spine answers from what an
    # earlier transfer learned rather than from this one's own write.
    remembered = Identities.recall(recording, track, connection.provider)

    Identities.record_source(recording, track)

    case remembered do
      %Match{} = match ->
        # No search, no request, no scoring. This is L5's whole claim, and the
        # answer is only here because a previous transfer resolved it at an
        # exact identifier or a person chose it by hand — see
        # `OnePlaylist.Library.Identities`.
        {{:ok, match}, []}

      nil ->
        {resolved, ranked} = search_and_decide(track, adapter, connection, threshold)

        learn(recording, resolved)

        {resolved, ranked}
    end
  end

  defp search_and_decide(track, adapter, connection, threshold) do
    if Matching.searchable?(track) do
      case adapter.search_tracks(connection, track, []) do
        {:ok, candidates} ->
          {outcome, ranked} = decide(track, candidates, threshold, adapter)

          {store_if_accepted(outcome, track, adapter, connection), ranked}

        {:error, _reason} = error ->
          {error, []}
      end
    else
      # Skipping the search rather than letting the adapter's precondition fire:
      # an unsearchable track is a normal thing to find in a playlist, not a
      # caller's bug.
      {Matching.match(track, [], threshold: threshold), []}
    end
  end

  # Teaches the spine where the destination holds this recording, but only from
  # evidence strong enough to assert as a fact. `Identities.record/4` states that
  # rule as a precondition, so the confidence is checked here rather than left
  # for it to raise on — a transfer must not fail because it matched a track by
  # text.
  defp learn(recording, {:ok, %Match{} = match}) do
    if Identities.trustworthy?(match.confidence) do
      Identities.record(recording, match.track, match.strategy, match.score)
    end

    :ok
  end

  defp learn(_recording, _not_matched), do: :ok

  # The one place the pipeline knows that a miss is not always a dead end.
  #
  # Every provider is a catalogue: a track it does not carry cannot be put
  # there, and that is what an unmatched row means. `OnePlaylist.Providers.Library`
  # is not — it can hold anything — so against a destination declaring
  # `:accepts_any_track` a failed match is an instruction to store the track and
  # carry on. See `docs/reference/domain.md` §5.
  #
  # Narrow on purpose, in three ways. Only a `TrackNotMatched` is converted, so
  # a provider that was *unreachable* still fails rather than being quietly
  # stored. Only where the capability is declared, asked before calling rather
  # than by trying and interpreting the error. And the accepted track is the
  # destination's own — `accept_track/3` returns a track with an id that
  # `playlist_track_ids/3` will report, without which `confirm_written/5` would
  # look for the *source's* id in the destination and declare its own write
  # missing.
  defp store_if_accepted({:error, %TrackNotMatched{}} = failed, track, adapter, connection) do
    if accepts_any_track?(adapter) do
      case adapter.accept_track(connection, track, []) do
        {:ok, accepted} -> {:ok, Match.stored(track, accepted)}
        {:error, _reason} -> failed
      end
    else
      failed
    end
  end

  defp store_if_accepted(outcome, _track, _adapter, _connection), do: outcome

  defp decide(track, candidates, threshold, adapter) do
    opts = [threshold: threshold]

    case Matching.match(track, candidates, opts) do
      {:ok, _match} = matched ->
        {matched, Matching.rank(track, candidates, opts)}

      {:error, _reason} = failed ->
        if accepts_any_track?(adapter) do
          # No rescue to attempt. Both fallbacks below exist to save a match
          # against a **catalogue** — a track the destination really does carry
          # under another identifier, or a classical title whose catalogue
          # number is missing. A destination that will store the track either
          # way has nothing to be saved from, so a MusicBrainz request here
          # cannot change the outcome; it only changes whether the track is
          # deduplicated onto a recording already held.
          #
          # That is worth having and does not belong here. MusicBrainz allows
          # one request a second, so a 153-track import into an empty library
          # spent one on every track to learn nothing — minutes of a job for a
          # question whose answer was already "store it". Identity is
          # enrichment's business, in the background, where the same lookup is
          # paid for once per *recording* rather than once per import. See
          # `docs/reference/domain.md` §5.
          {failed, Matching.rank(track, candidates, opts)}
        else
          retry_with_isrc_family(track, candidates, opts, failed)
        end
    end
  end

  defp accepts_any_track?(adapter), do: :accepts_any_track in adapter.capabilities()

  # The second chance an ISRC deserves, and only ever a second chance.
  #
  # An ISRC names a recording *as issued*, so the same master carries a
  # different code on every reissue and a direct lookup can miss a track the
  # destination plainly has. `MusicBrainz.family/2` says which codes name one
  # recording — see that module for the case it was built for.
  #
  # The candidates are the ones already in hand, so this costs **one**
  # MusicBrainz request and no provider call at all. It runs only after a match
  # has already failed, which measured at about one ISRC-bearing track in seven,
  # and every answer is cached in two tiers.
  defp retry_with_isrc_family(%Track{isrc: isrc} = track, candidates, opts, failed)
       when is_binary(isrc) do
    case MusicBrainz.family(isrc) do
      [] ->
        {failed, Matching.rank(track, candidates, opts)}

      family ->
        enriched = %{track | isrc_family: family}

        {Matching.match(enriched, candidates, opts), Matching.rank(enriched, candidates, opts)}
    end
  end

  defp retry_with_isrc_family(track, candidates, opts, failed),
    do: retry_with_work(track, candidates, opts, failed)

  # The last resort, and it is deliberately hard to reach.
  #
  # A classical title identifies its piece by catalogue number, and a great many
  # omit it: "Brandenburg Concerto no. 2 in F major" names the work exactly and
  # gives no number, while every catalogue TIDAL carries writes `BWV 1047`.
  # `Strategy.Work` then has nothing to match on, and nothing local can bridge
  # it.
  #
  # The trigger is narrow on purpose, because MusicBrainz allows one request a
  # second: the match has already failed, the source's own title yields no
  # catalogue number, and **some candidate has one**. That last condition is what
  # keeps a pop playlist out — a search for "Woo" answers with 48,000 works —
  # and it costs nothing to check, being a property of results already in hand.
  defp retry_with_work(%Track{} = track, candidates, opts, failed) do
    if worth_asking?(track, candidates) do
      case MusicBrainz.works(track.title, Track.primary_artist(track)) do
        [] ->
          {failed, Matching.rank(track, candidates, opts)}

        titles ->
          enriched = %{track | work_titles: titles}

          {Matching.match(enriched, candidates, opts), Matching.rank(enriched, candidates, opts)}
      end
    else
      {failed, Matching.rank(track, candidates, opts)}
    end
  end

  defp worth_asking?(%Track{} = track, candidates) do
    source_work = Work.parse(track.title)

    not Work.identifies_work?(source_work) and
      Enum.any?(candidates, fn candidate ->
        Work.identifies_work?(Work.parse("#{candidate.title} #{candidate.album}"))
      end)
  end

  # Adds only what the destination does not already have, in batches. Returns
  # the set of source positions that were actually written, which is what tells
  # `:matched` apart from `:already_present`.
  defp write_missing(resolutions, present, adapter, connection, destination) do
    missing =
      for {position, _source, {:ok, match}} <- resolutions,
          not MapSet.member?(present, match.track.provider_id),
          do: {position, match.track}

    # Deduplicated by destination id: two source tracks can resolve to the same
    # destination track — a playlist containing the same recording twice, or two
    # near-identical entries matching one candidate. Writing it twice would put
    # a duplicate in somebody's playlist, which no later run could tell from a
    # duplicate they had added themselves.
    {to_write, _seen} =
      Enum.reduce(missing, {[], MapSet.new()}, fn {position, track}, {acc, seen} ->
        if MapSet.member?(seen, track.provider_id) do
          {acc, seen}
        else
          {[{position, track} | acc], MapSet.put(seen, track.provider_id)}
        end
      end)

    to_write = Enum.reverse(to_write)

    result =
      to_write
      |> Enum.chunk_every(@batch_size)
      |> Enum.reduce_while(:ok, fn batch, :ok ->
        tracks = Enum.map(batch, fn {_position, track} -> track end)

        case adapter.add_tracks(connection, destination, tracks, []) do
          {:ok, _count} -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case result do
      :ok -> {:ok, MapSet.new(to_write, fn {position, _track} -> position end)}
      {:error, _reason} = error -> error
    end
  end

  # Re-reads the destination and checks the writes landed.
  #
  # An `add_tracks/4` implementation can only report what it was *given* — TIDAL
  # answers an append with an empty 200, Subsonic with `ok`, and neither says
  # what was stored. So "added 6" means "asked for 6 and was not refused", and
  # the gap between that and "6 are there" is precisely the failure this
  # application exists to prevent. One extra request closes it.
  #
  # Deliberately **not** a `@post`. The destination is shared state a user can
  # edit while a transfer runs, so an assertion that every written track is
  # still present would accuse correct code the moment somebody deleted one by
  # hand — `docs/reference/contracts.md` shape 0b, the same reason
  # `disconnect/2`'s row-count law lives in a test. A check that returns an
  # error can be retried; a contract that raises cannot.
  defp confirm_written(resolutions, added_positions, adapter, connection, destination) do
    expected =
      for {position, _source, {:ok, match}} <- resolutions,
          MapSet.member?(added_positions, position),
          do: match.track.provider_id

    if expected == [] do
      :ok
    else
      with {:ok, present} <- adapter.playlist_track_ids(connection, destination) do
        report_missing(Enum.reject(expected, &(&1 in present)), expected, destination)
      end
    end
  end

  defp report_missing([], _expected, _destination), do: :ok

  defp report_missing(missing, expected, destination) do
    {:error,
     Errata.create(WriteNotConfirmed,
       context: %{
         missing: missing,
         expected: length(expected),
         destination_playlist_id: destination
       }
     )}
  end

  defp finish(transfer, tracks, resolutions, added_positions, candidates) do
    # Reset first: a run recomputes the whole ledger, so a re-run must not add
    # to the previous one's numbers.
    base = transfer |> Transfer.reset_counters() |> Transfer.with_total(length(tracks))

    counted =
      Enum.reduce(resolutions, base, fn
        {position, _source, {:ok, _match}}, acc ->
          Transfer.record_matched(acc, MapSet.member?(added_positions, position))

        {_position, _source, {:error, _error}}, acc ->
          Transfer.record_unmatched(acc)
      end)

    items =
      Enum.map(resolutions, fn {position, source, outcome} ->
        base = %{
          transfer_id: transfer.id,
          user_id: transfer.user_id,
          candidates: Map.get(candidates, position, [])
        }

        case outcome do
          {:ok, match} ->
            TransferItem.matched(base, position, match, MapSet.member?(added_positions, position))

          {:error, error} ->
            TransferItem.unmatched(base, position, source, error)
        end
      end)

    OnePlaylist.Transfers.record_run(transfer, counted, items)
  end
end
