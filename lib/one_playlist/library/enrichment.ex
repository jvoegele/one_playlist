defmodule OnePlaylist.Library.Enrichment do
  @moduledoc """
  Filling in what a recording does not know about itself.

  `docs/reference/domain.md` §5's L4, and the thing that makes §5's claim about
  the library real. A track imported from a CSV arrives as a title, an artist
  and perhaps an album; enriched, it carries an ISRC, a MusicBrainz identity, a
  length and a cover — and an ISRC is what makes it *exactly* matchable at every
  service, for every future transfer, by anyone.

  That is the compounding asset: identity resolved once per recording rather
  than once per transfer.

  ## Filling gaps is not the same as correcting

  Nothing here overwrites a value the recording already has. What the source
  said is what the user's playlist shows, and a background job quietly replacing
  a title with MusicBrainz's canonical spelling is a surprise nobody asked for.
  Where the two disagree, the stored value wins and the disagreement is simply
  not recorded — telling them apart needs a provenance model, which is a
  separate feature and a bigger one.

  So enrichment can only make a recording *more* complete, never different.

  ## The score is not a verdict, so the ladder decides

  Finding a recording by name is the dangerous half. Verified live: MusicBrainz
  answers a search for *Corduroy* by *Pearl Jam* with a **live bootleg at score
  100**. Taking the top hit would attach that recording's identity — and then
  its ISRC, its length, its artwork — to the studio track somebody imported,
  which is enrichment making the data worse.

  So candidates are scored by `OnePlaylist.Matching` exactly as candidates from
  any service are, at `:high`. Two things follow, and both are inherited rather
  than re-argued:

    * the version veto, the duration conflict and the credit rules all apply,
      because they are the ladder's and the ladder is what is running;
    * a recording with **nothing to corroborate with** — no album, no duration —
      is declined rather than guessed at. `Strategy.Text` scores an
      uncorroborated match at `0.89`, and `:high` is `0.90`. That is not a
      coincidence to be tuned; it is the ladder already knowing that text alone
      is not enough.

  An ISRC needs none of this. It is an identifier, so `OnePlaylist.MusicBrainz`
  answers directly and the search path is never reached.

  ## A recording has many releases, and they disagree

  MusicBrainz lists every release a recording appears on — the original pressing,
  a reissue, a regional edition, a compilation — and the barcode and the cover
  differ between them. The first version of this took `List.first/1`, which is no
  order at all: eight tracks from *Dark Matter* landed on **three** releases, so
  the album contradicted itself about its own barcode and showed a cover on two
  tracks out of eight.

  The choice is now made deliberately, in `choose_release/2`, and the winner is
  stored in `musicbrainz_release_id` so it can be audited rather than inferred
  from a barcode. Three rules, in order:

    1. **An album agrees with itself.** If another recording of the same album
       already settled on a release, and this recording appears on it, that one
       wins outright. Read from Postgres rather than a cache, because the
       agreement has to survive a restart — the ninth track of an album enriched
       tomorrow must reach the same answer as the first eight.
    2. **The release should be the album the track says it is on.** Candidates
       whose title matches the recording's stored album are preferred over a
       compilation the track also happens to appear on.
    3. **Prefer a cover we can actually show,** then the earliest release, then
       the lowest id — so the result is deterministic rather than merely stable.

  Rule 3's artwork check costs a request per candidate, so it is capped and
  cached; rule 1 means it is paid once per album rather than once per track.

  Measured on the dev library: thirteen albums disagreed with themselves before,
  and afterwards the only one that still does is *Pearl Jam - Non-Album Tracks* —
  which is not an album, so its tracks genuinely appear on unrelated releases and
  rule 1's membership test correctly declines to force them together.

  ### The limit of this, stated plainly

  Rule 1 makes an album agree **where it can**. A widely reissued album has
  dozens of pressings and MusicBrainz lists, for each recording, only the ones it
  actually appears on — so the release the first track settles on may not be in
  the fifth track's list, and it falls through to its own best. Seven albums here
  still span more than one release for that reason. Their covers agree, because
  a reissue's cover is the same picture, but their barcodes do not.

  Fixing that properly means resolving the **album** once and mapping its tracks
  onto it, rather than resolving each track and hoping they converge. That is a
  different and larger piece of work, and it is not needed for the thing this
  screen shows.

  ## What it costs

  One or two requests per recording, at MusicBrainz's one per second: a lookup
  by MBID always, preceded by a search when there is no ISRC to identify it
  with. Artwork adds one per *release* rather than per recording, cached,
  because an album's worth of recordings asks the same question twelve times.

  Which is why this is an `Oban` job on a queue of one and never happens on the
  path a person is watching — see `OnePlaylist.Library.EnrichmentWorker`.
  """

  alias OnePlaylist.Cache
  alias OnePlaylist.Library.Recording
  alias OnePlaylist.Matching
  alias OnePlaylist.Matching.Normalize
  alias OnePlaylist.Music.Isrc
  alias OnePlaylist.MusicBrainz
  alias OnePlaylist.MusicBrainz.Client
  alias OnePlaylist.Repo

  require Logger

  import Ecto.Query

  use Bond

  # Long enough that a sweep does not re-ask about a recording it looked at
  # yesterday, short enough that a recording MusicBrainz knew nothing about last
  # month is asked about again. The same reasoning as the negative caches in
  # `OnePlaylist.Catalogue`: an absence is an answer, and only true for now.
  @stale_after_days 30

  # How many releases are asked about artwork before settling for the first
  # candidate. Bounded because each is a request; small because rule 1 means the
  # question is asked once per album, and the album's own pressing is almost
  # always among the first few once the title match has sorted it forward.
  @artwork_candidates 3

  # What `reset/1` may clear, and the two lists are different for a reason worth
  # reading. Only these three are written by enrichment and nothing else, so only
  # these can be cleared unconditionally.
  @always_cleared [:enriched_at, :musicbrainz_recording_id, :musicbrainz_release_id]

  # These come from a *release*, so a non-null `musicbrainz_release_id` is proof
  # enrichment wrote them — the nearest thing to provenance this schema has. With
  # it null they came from the track's own source and are not ours to clear.
  @cleared_with_a_release [:album_upc, :artwork_url]

  @doc """
  Enriches one recording, returning it as it now stands.

  Always marks the attempt, whether or not anything was learned. A recording
  MusicBrainz has never heard of must not be asked about again tomorrow, and the
  timestamp is the only thing that distinguishes "nothing to find" from "not
  looked at yet".
  """
  # Filling gaps only, stated where it can be checked. The failure it guards is
  # quiet and hard to notice afterwards: a job that assigned rather than merged
  # would rewrite a user's own titles and albums with a stranger's spelling, on
  # a schedule, in the background, for every recording in the library.
  #
  # No input can falsify either, so both are verified by mutation. Dropping
  # `record_attempt/2`'s "already has a value" test fires
  # `nothing_was_overwritten`; dropping its `Map.put(:enriched_at, …)` fires
  # `attempt_recorded`. The second is what stops `due/1` from re-offering a
  # recording MusicBrainz cannot identify, every night, forever.
  @post whenever(
          {:ok, enriched} <- result,
          nothing_was_overwritten: only_filled_gaps?(recording, enriched),
          attempt_recorded: is_struct(enriched.enriched_at, DateTime)
        )
  @spec enrich(Recording.t()) :: {:ok, Recording.t()} | {:error, term()}
  def enrich(%Recording{} = recording) do
    case identify(recording) do
      {:ok, mbid} when is_binary(mbid) -> describe(recording, mbid)
      _nothing_found -> record_attempt(recording, %{})
    end
  end

  @doc """
  Whether one recording is a strict improvement on another.

  Public because `enrich/1` names it in a postcondition, and an assertion
  rendered into the documentation should reference something a reader can look
  up. Every field the enrichment writes is checked: a field that had a value
  before must have the same value after.
  """
  @spec only_filled_gaps?(Recording.t(), Recording.t()) :: boolean()
  def only_filled_gaps?(%Recording{} = before, %Recording{} = enriched) do
    Enum.all?(fillable(), fn field ->
      case Map.fetch!(before, field) do
        nil -> true
        existing -> Map.fetch!(enriched, field) == existing
      end
    end)
  end

  @doc """
  Forgets what MusicBrainz said about these recordings, returning how many.

  The counterpart to `enrich/1` never overwriting. That rule is right — a
  background job must not rewrite a user's own metadata — but it also means a
  recording enriched from the *wrong source* stays wrong for ever, because every
  later run sees a filled field and leaves it alone.

  So correcting is a separate, explicit operation rather than a thing enrichment
  decides to do. It clears only what enrichment itself writes; the title, the
  artists and the origin are the user's or their source's and are never touched.
  `enriched_at` goes too, which is what puts the recording back in front of
  `due/1`.

  Written for the release-selection defect described in the moduledoc — eight
  tracks of one album resolved to three releases — and kept because "look at
  this again from scratch" is the mechanism any future correction needs.

  ## What it will not clear, and why that is not timidity

  `title`, `artists` and `isrc` are **never** cleared, and neither are `album`
  or `duration_seconds`. This schema does not record where a field came from, and
  most of those arrive with the track: a recording transferred from TIDAL brings
  its own title, album, ISRC and length, and enrichment only ever filled the
  gaps. Clearing them would discard the source's data and let the next run
  replace it with MusicBrainz's — which is precisely the overwrite `enrich/1`
  refuses to perform, reached by the back door.

  `album_upc` and `artwork_url` are the exception, and only where
  `musicbrainz_release_id` is set. That column is proof enrichment chose the
  release those two were read from, which is the nearest thing to provenance
  available here. Where it is null they came from the track's source and stay.
  """
  @spec reset([Ecto.UUID.t()]) :: non_neg_integer()
  def reset([]), do: 0

  def reset(recording_ids) when is_list(recording_ids) do
    from_release =
      Recording
      |> where([r], r.id in ^recording_ids and not is_nil(r.musicbrainz_release_id))
      |> select([r], r.id)
      |> Repo.all()

    {_count, _returned} =
      Recording
      |> where([r], r.id in ^from_release)
      |> Repo.update_all(set: Enum.map(@cleared_with_a_release, &{&1, nil}))

    {count, _returned} =
      Recording
      |> where([r], r.id in ^recording_ids)
      |> Repo.update_all(set: Enum.map(@always_cleared, &{&1, nil}))

    count
  end

  @doc """
  Recordings due for enrichment, least recently looked at first.

  Never-enriched rows come first, because a recording nothing is known about is
  worth more attention than one whose answer is a month old.
  """
  @spec due(pos_integer()) :: [Recording.t()]
  def due(limit) do
    import Ecto.Query

    cutoff = DateTime.add(DateTime.utc_now(), -@stale_after_days * 24 * 3600, :second)

    Recording
    |> where([r], is_nil(r.enriched_at) or r.enriched_at < ^cutoff)
    |> order_by([r], asc_nulls_first: r.enriched_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # The fields enrichment may write. Named rather than derived from the schema,
  # because most of the schema is deliberately *not* fillable: `title` and
  # `artists` are what the user's playlist shows and are theirs, and identity
  # columns like `origin_provider` describe where the row came from rather than
  # what the music is.
  defp fillable,
    do: [:isrc, :musicbrainz_recording_id, :album, :album_upc, :duration_seconds, :artwork_url]

  # An identifier answers directly; a name has to be argued for. The ISRC path
  # costs nothing beyond what matching already caches, which is why it is tried
  # first even though the search path would also work.
  defp identify(%Recording{isrc: isrc}) when is_binary(isrc) do
    {:ok, MusicBrainz.recording_mbid(isrc)}
  end

  defp identify(%Recording{title: title} = recording) when is_binary(title) and title != "" do
    case Client.search_recordings(title, List.first(recording.artists || [])) do
      {:ok, candidates} ->
        chosen(recording, candidates)

      {:error, reason} ->
        Logger.warning("musicbrainz recording search failed for #{title}: #{inspect(reason)}")
        :error
    end
  end

  defp identify(%Recording{}), do: :none

  # The ladder, at `:high`. See the moduledoc for why the threshold is doing the
  # work rather than a rule of this module's own.
  defp chosen(recording, candidates) do
    case Matching.match(Recording.to_track(recording), candidates, threshold: :high) do
      {:ok, match} -> {:ok, match.track.provider_id}
      {:error, _not_matched} -> :none
    end
  end

  defp describe(recording, mbid) do
    case Client.recording(mbid) do
      {:ok, nil} ->
        record_attempt(recording, %{})

      {:ok, details} ->
        record_attempt(recording, learned(recording, details, mbid))

      {:error, reason} ->
        Logger.warning("musicbrainz lookup failed for #{mbid}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp learned(recording, details, mbid) do
    release = choose_release(recording, Map.get(details, "releases", [])) || %{}

    %{
      musicbrainz_recording_id: mbid,
      musicbrainz_release_id: release["id"],
      isrc: details |> Map.get("isrcs", []) |> List.first() |> Isrc.normalize(),
      album: release["title"],
      album_upc: release["barcode"],
      duration_seconds: details["length"] && div(details["length"], 1000),
      artwork_url: artwork(recording, release["id"])
    }
  end

  @doc """
  The release a recording's album, barcode and cover should come from.

  Public so the moduledoc's three rules can be read against something, and so a
  probe can ask what would be chosen without writing anything. Returns `nil`
  when MusicBrainz lists no releases at all.
  """
  @spec choose_release(Recording.t(), [map()]) :: map() | nil
  def choose_release(_recording, []), do: nil

  def choose_release(%Recording{} = recording, releases) do
    settled(recording, releases) || best(recording, releases)
  end

  # Rule 1. The release this album already agreed on, if this recording is on it.
  # The membership test is what makes matching on title alone safe: two different
  # albums sharing a name cannot mislead each other, because the loser's release
  # will not be in the winner's list.
  defp settled(%Recording{album: nil}, _releases), do: nil

  defp settled(%Recording{album: album, id: id}, releases) do
    chosen =
      Recording
      |> where([r], r.album == ^album and not is_nil(r.musicbrainz_release_id))
      |> where([r], r.id != ^id)
      |> select([r], r.musicbrainz_release_id)
      |> limit(1)
      |> Repo.one()

    chosen && Enum.find(releases, &(&1["id"] == chosen))
  end

  # Rules 2 and 3. Sorting rather than filtering on the album title, so a
  # recording whose only releases are compilations still gets one of those.
  defp best(recording, releases) do
    candidates = Enum.sort_by(releases, &ranking(recording, &1))

    with_art =
      candidates
      |> Enum.take(@artwork_candidates)
      |> Enum.find(&has_artwork?(&1["id"]))

    with_art || List.first(candidates)
  end

  # `false` sorts before `true`, so naming the track's own album comes first.
  # A missing date sorts last rather than first: an undated release is usually
  # a stub, and a real pressing with a date should win over it.
  defp ranking(recording, release) do
    {not same_album?(recording, release), release["date"] || "9999", release["id"]}
  end

  defp same_album?(%Recording{album: nil}, _release), do: false

  defp same_album?(%Recording{album: album}, release) do
    Normalize.text(album) == Normalize.text(release["title"])
  end

  # Only asked when there is nothing already, and only ever once per release —
  # an album's worth of recordings names the same one. `Cache` is L1 only here:
  # a cover either exists or does not, so a miss after a deploy costs one
  # request rather than a wrong answer.
  defp artwork(%Recording{artwork_url: existing}, _release_mbid) when is_binary(existing), do: nil
  defp artwork(_recording, nil), do: nil

  defp artwork(_recording, release_mbid) do
    if has_artwork?(release_mbid), do: Client.artwork_url(release_mbid)
  end

  # `Cache` is L1 only: a cover either exists or does not, so a miss after a
  # deploy costs one request rather than a wrong answer. An error is *not*
  # cached, for the reason `OnePlaylist.MusicBrainz` gives — an outage is a fact
  # about MusicBrainz, not about the release.
  defp has_artwork?(nil), do: false

  defp has_artwork?(release_mbid) do
    Cache.read_through({:mb_release_art, release_mbid}, fn ->
      case Client.release_has_artwork?(release_mbid) do
        {:ok, answer} -> {:ok, answer}
        {:error, _reason} -> {:error, :unknown}
      end
    end) == {:ok, true}
  end

  # Blank values are dropped rather than written, so a MusicBrainz field that is
  # absent cannot turn a gap into an empty string — which would look filled and
  # compare equal to every other empty string.
  defp record_attempt(recording, learned) do
    attrs =
      learned
      |> Enum.reject(fn {field, value} ->
        value in [nil, "", []] or not is_nil(Map.fetch!(recording, field))
      end)
      |> Map.new()
      |> Map.put(:enriched_at, DateTime.utc_now())

    recording
    |> Recording.changeset(attrs)
    |> Repo.update()
  end
end
