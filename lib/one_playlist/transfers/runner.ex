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

  alias OnePlaylist.Matching
  alias OnePlaylist.Providers
  alias OnePlaylist.Transfers.Progress
  alias OnePlaylist.Transfers.Source
  alias OnePlaylist.Transfers.SourceMissing
  alias OnePlaylist.Transfers.Transfer
  alias OnePlaylist.Transfers.TransferItem
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
  # `added_at_most_matched` used to sit here beside it and was removed when the
  # invariant landed: unlike the equality above it is *identical* to the
  # invariant, and every counter this function returns passes through
  # `Transfer.reset_counters/1`, `with_total/2`, `record_matched/2` or
  # `record_unmatched/1` — each of which now checks it on the way out. Meyer's
  # Non-Redundancy principle, and the invariant is also the better locus: it
  # names the counter update that broke the law rather than the run that
  # contained it.
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
         resolutions =
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
      finish(transfer, tracks, resolutions, added)
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
  defp read_source(%Transfer{source_provider: :file} = transfer) do
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

  defp read_source(%Transfer{} = transfer) do
    with {:ok, connection} <- connection(transfer.user_id, transfer.source_provider),
         {:ok, adapter} <- Providers.adapter(transfer.source_provider),
         {:ok, stream} <- adapter.stream_tracks(connection, transfer.source_playlist_id, []) do
      {:ok, Enum.to_list(stream)}
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
  # Batched through `Progress`, because "as it goes" used to mean one broadcast
  # per track and that does not survive a 5,000 track playlist. The final flush
  # is not optional: without it a run ending mid-batch strands its last tracks.
  defp resolve_all(transfer, tracks, adapter, connection, threshold) do
    total = length(tracks)

    {resolutions, progress} =
      tracks
      |> Enum.with_index()
      |> Enum.map_reduce(Progress.new(total), fn {track, position}, progress ->
        outcome = resolve(track, adapter, connection, threshold)
        {batch, progress} = Progress.add(progress, provisional_item(position, track, outcome))

        _ = report(transfer, batch, progress)

        {{position, track, outcome}, progress}
      end)

    {batch, progress} = Progress.flush(progress)
    _ = report(transfer, batch, progress)

    resolutions
  end

  # An empty batch is the ordinary case between flushes, and broadcasting it
  # would undo the batching.
  defp report(_transfer, [], _progress), do: :ok

  defp report(transfer, batch, %Progress{} = progress) do
    OnePlaylist.Transfers.report_progress(transfer, progress.resolved, progress.total, batch)
  end

  # What a watcher can be shown before the writes happen. Deliberately says
  # `:matched` for anything resolved, because the difference between that and
  # `:already_present` is not known yet: it depends on what the destination
  # already holds, which is compared after every track has been resolved. The
  # final report corrects it.
  defp provisional_item(position, track, outcome) do
    base = %{position: position, source_title: track.title, source_artist: primary_artist(track)}

    case outcome do
      {:ok, match} ->
        Map.merge(base, %{
          outcome: :matched,
          destination_track_id: match.track.provider_id,
          confidence: to_string(match.confidence),
          score: match.score,
          strategy: to_string(match.strategy),
          reason: nil
        })

      {:error, error} ->
        Map.merge(base, %{
          outcome: :unmatched,
          destination_track_id: nil,
          confidence: nil,
          score: nil,
          strategy: nil,
          reason: to_string(Errata.reason(error))
        })
    end
  end

  defp primary_artist(track), do: List.first(track.artists)

  defp resolve(track, adapter, connection, threshold) do
    if Matching.searchable?(track) do
      case adapter.search_tracks(connection, track, []) do
        {:ok, candidates} -> Matching.match(track, candidates, threshold: threshold)
        {:error, _reason} = error -> error
      end
    else
      # Skipping the search rather than letting the adapter's precondition fire:
      # an unsearchable track is a normal thing to find in a playlist, not a
      # caller's bug.
      Matching.match(track, [], threshold: threshold)
    end
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

  defp finish(transfer, tracks, resolutions, added_positions) do
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
        base = %{transfer_id: transfer.id, user_id: transfer.user_id}

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
