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
  alias OnePlaylist.Music.Isrc
  alias OnePlaylist.MusicBrainz
  alias OnePlaylist.MusicBrainz.Client
  alias OnePlaylist.Repo

  require Logger

  use Bond

  # Long enough that a sweep does not re-ask about a recording it looked at
  # yesterday, short enough that a recording MusicBrainz knew nothing about last
  # month is asked about again. The same reasoning as the negative caches in
  # `OnePlaylist.Catalogue`: an absence is an answer, and only true for now.
  @stale_after_days 30

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
    release = details |> Map.get("releases", []) |> List.first() || %{}

    %{
      musicbrainz_recording_id: mbid,
      isrc: details |> Map.get("isrcs", []) |> List.first() |> Isrc.normalize(),
      album: release["title"],
      album_upc: release["barcode"],
      duration_seconds: details["length"] && div(details["length"], 1000),
      artwork_url: artwork(recording, release["id"])
    }
  end

  # Only asked when there is nothing already, and only ever once per release —
  # an album's worth of recordings names the same one. `Cache` is L1 only here:
  # a cover either exists or does not, so a miss after a deploy costs one
  # request rather than a wrong answer.
  defp artwork(%Recording{artwork_url: existing}, _release_mbid) when is_binary(existing), do: nil
  defp artwork(_recording, nil), do: nil

  defp artwork(_recording, release_mbid) do
    has_art? =
      Cache.read_through({:mb_release_art, release_mbid}, fn ->
        case Client.release_has_artwork?(release_mbid) do
          {:ok, answer} -> {:ok, answer}
          {:error, _reason} -> {:error, :unknown}
        end
      end)

    case has_art? do
      {:ok, true} -> Client.artwork_url(release_mbid)
      _no_or_unknown -> nil
    end
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
