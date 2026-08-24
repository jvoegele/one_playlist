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
  any service are. The version veto, the duration conflict and the credit rules
  all apply, because they are the ladder's and the ladder is what is running.

  ### `:high` is not enough, which had to be measured

  This first ran at `:high`, on the reasoning that a recording with nothing to
  corroborate with is declined anyway because `Strategy.Text` scores an
  uncorroborated match at `0.89` against a `0.90` threshold.

  **That was wrong**, and a real library disproved it. *Throw Your Arms Around Me*
  from the tribute album *Crucible* scored **0.9139** against a Hunters &
  Collectors compilation — comfortably over `:high` — on nothing but an exact
  title and an exact credit, with a different album and no duration to check. An
  exact credit alone lifts text well above `0.90`.

  Measured across the ten recordings MusicBrainz could not identify by ISRC, the
  separation is not subtle:

  | | Score | Album agreed |
  | --- | --- | --- |
  | Four correct identifications | `0.98` each | yes |
  | One wrong identification | `0.9139` | no |

  So the threshold is `@every_field_agreed` — the **top of the `:text` band**,
  which `OnePlaylist.Matching.Confidence` defines as "every compared field agreed
  after normalization". It is read from the band rather than written as `0.98`,
  because the point is the definition and not the number: a threshold chosen to
  separate five measured cases would be tuning, and a threshold that means *the
  ladder had nothing left to disagree about* is a specification.

  ### Rejected: distrusting a candidate whose ISRC differs

  The obvious alternative, measured and thrown away. When a recording carries an
  ISRC MusicBrainz has never seen, a candidate carrying a *different* ISRC looks
  like positive evidence of being a different recording.

  It is not. MusicBrainz indexes recordings per release, so the same performance
  legitimately carries a different code on the pressing it happens to hold — and
  rejecting those made three of the four correct answers **worse**, swapping
  *Earthling* for *Earthling Expansion: The Adventurous Cuts*. It did not help
  the wrong one at all. Fourth negative result of this kind in the project; the
  others are in `docs/reference/domain.md`.

  ### The album is the best term the query has

  Measured against twelve hand-labelled cases in `dev/Unmatched PJ Favorites.csv`,
  and the largest single improvement to this feature so far. A prolific artist
  has more recordings of a title than a page of results can hold, so relevance
  buries the wanted one — Pearl Jam has a bootleg of nearly every song from
  nearly every show. Title and artist alone found the wanted recording once in
  six; adding the release found it **five times in six**, four of them ranked
  first.

  So `by_release/3` asks the narrow question first and `by_title/3` is the
  fallback, because naming a release can also over-narrow — the stored album may
  be a disc subtitle MusicBrainz does not use. Ordering them this way can only
  add: everything that matched before still matches, at the cost of one extra
  request when the narrow question fails.

  ### The query is not the stored strings

  Two more things measured rather than assumed, and neither works without the
  other. Across the six recordings still unidentified after the fallback landed:

  | Query | Identified |
  | --- | --- |
  | The stored title and the stored credit | 0 |
  | The **parsed** title, stored credit | 0 |
  | The parsed title **and** the credit's first name | **2**, both at `0.98` |

  A stored title often carries in parentheses what MusicBrainz keeps out of the
  title entirely — *"The Face Of Love (with Eddie Vedder)"* matches no recording
  and *"the face of love"* matches it exactly — so the query uses
  `Normalize.title/1`'s parsed title. Nothing is lost by that: the ladder still
  scores the *raw* track, so the version marker stripped from the query is still
  applied to whatever comes back, and the two recordings whose queries got
  broader as a result were both correctly declined.

  And a credit naming several people is often written as one string, which
  MusicBrainz matches to no artist at all and answers with nothing. So a search
  that comes back **empty** is retried with the credit's first name. Empty
  rather than unconvincing, because that is the signal that the query itself was
  wrong; a search that found candidates and declined them was asked a good
  question and given a bad answer, and asking a narrower one would not help.

  ## An ISRC MusicBrainz has never seen is not a dead end

  The identifier path is tried first and answers directly when it can. When it
  cannot — MusicBrainz indexes no such code — the recording falls through to the
  search above rather than being reported as unknown.

  That gap was found by looking at a playlist, not by a test: seven of the dev
  library's ten unidentified recordings carried a perfectly good ISRC that
  MusicBrainz simply does not hold, and one of them was a recording MusicBrainz
  demonstrably *does* have under its own name.

  ## Artwork belongs to the album, not to the pressing

  A separate question from the one below, and it was got wrong first. Enrichment
  asked whether the release it had chosen *for the barcode* had a front cover —
  but which pressing wins a barcode has nothing to do with which pressing
  somebody uploaded a scan for. Of six releases of *Pearl Jam* (2006), three have
  a cover and three do not, and the one chosen for its barcode was among the
  three that do not. Nine albums here showed no artwork while their cover sat in
  the archive.

  So the cover comes from the **release group** — MusicBrainz's model of an album
  across all its pressings — which is correct and also cheaper: one question per
  album rather than one per pressing, and the group id arrives free in the
  recording lookup. See `OnePlaylist.CoverArt.Client`.

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
    3. **The earliest release, then the lowest id** — so the result is
       deterministic rather than merely stable.

  All three are decided from the response already in hand, at no extra cost. An
  earlier version made rule 3 "prefer a pressing that has cover art", which spent
  a request per candidate to answer a question that turned out to belong to the
  release group instead.

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
  alias OnePlaylist.CoverArt.Client, as: CoverArt
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
  # The top of `OnePlaylist.Matching.Confidence`'s `:text` band, which that
  # module defines as "every compared field agreed after normalization". Used as
  # the search path's threshold because it is a *statement about corroboration*
  # rather than a number that happened to separate the measured cases — see the
  # moduledoc. Read from the band so it cannot drift from the definition.
  @every_field_agreed elem(OnePlaylist.Matching.Confidence.band(:text), 1)

  # What `reset/1` may clear, and the two lists are different for a reason worth
  # reading. Only these three are written by enrichment and nothing else, so only
  # these can be cleared unconditionally.
  @always_cleared [:enriched_at, :musicbrainz_recording_id, :musicbrainz_release_id]

  # A barcode comes from a *release*, so a non-null `musicbrainz_release_id` is
  # evidence enrichment wrote it — the nearest thing to provenance this schema
  # has. Imperfect, and worth naming: a track that arrived from TIDAL with its
  # own barcode, and later had a release chosen for it, would have that barcode
  # cleared here. Closing that needs the provenance model `enrich/1`'s moduledoc
  # twice defers, and until then this errs toward re-fetching a value rather
  # than keeping a stale one.
  @cleared_with_a_release [:album_upc]

  # Artwork needs no such proxy, because the URL says who wrote it. Only a cover
  # this application fetched from the archive is cleared; one from TIDAL is the
  # source's and stays.
  @our_artwork "https://coverartarchive.org/%"

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

  `album_upc` is the exception, and only where `musicbrainz_release_id` is set —
  the nearest thing to provenance available here, and imperfect in a way named
  at the attribute itself.

  `artwork_url` needs no proxy, because the URL says who wrote it: a cover this
  application fetched carries the archive's own host, and one from TIDAL does
  not and stays.
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

    {_count, _returned} =
      Recording
      |> where([r], r.id in ^recording_ids and like(r.artwork_url, ^@our_artwork))
      |> Repo.update_all(set: [artwork_url: nil])

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
  defp identify(%Recording{isrc: isrc} = recording) when is_binary(isrc) do
    case MusicBrainz.recording_mbid(isrc) do
      mbid when is_binary(mbid) -> {:ok, mbid}
      # MusicBrainz does not index every ISRC. Carrying one it has never seen is
      # not a reason to give up on the recording — see the moduledoc.
      nil -> by_name(recording)
    end
  end

  defp identify(%Recording{} = recording), do: by_name(recording)

  defp by_name(%Recording{title: raw} = recording) when is_binary(raw) and raw != "" do
    credit = List.first(recording.artists || [])
    # The *parsed* title, because a stored title often carries a credit or a
    # version in parentheses that MusicBrainz keeps out of the title entirely.
    # "The Face Of Love (with Eddie Vedder)" matches no recording; "the face of
    # love" matches it exactly. `Normalize.title/1` already knows how to take
    # one apart, and the version it strips is not lost — the ladder still scores
    # the raw track, so its version veto and tags apply to whatever comes back.
    title = Normalize.title(raw).title

    # Narrowest first. Naming the release is worth more than any other term the
    # query can carry — see `OnePlaylist.MusicBrainz.Client.search_recordings/3`
    # — but it can also over-narrow, so a decline here falls through to the
    # broader question rather than ending the search.
    case by_release(recording, title, credit) do
      :none -> by_title(recording, title, credit)
      found -> found
    end
  end

  defp by_name(%Recording{}), do: :none

  defp by_release(%Recording{album: album} = recording, title, credit)
       when is_binary(album) and album != "" do
    case search(title, credit, album: album) do
      {:ok, candidates} -> chosen(recording, candidates)
      :error -> :none
    end
  end

  defp by_release(_recording, _title, _credit), do: :none

  defp by_title(recording, title, credit) do
    case search(title, credit) do
      # A credit naming several people is often written as one string — a CSV
      # import carries `"Nusrat Fateh Ali Khan, Eddie Vedder"` as a single
      # artist — and MusicBrainz has no artist of that name, so the query
      # answers with nothing at all. Asking again for the first name finds them.
      {:ok, []} -> retry_named(recording, title, credit)
      {:ok, candidates} -> chosen(recording, candidates)
      :error -> :error
    end
  end

  defp retry_named(recording, title, credit) do
    case lead_name(credit) do
      nil ->
        :none

      ^credit ->
        # Nothing to narrow: the credit already names one artist, and asking the
        # identical question again would spend a request to be told the same
        # thing.
        :none

      lead ->
        case search(title, lead) do
          {:ok, candidates} -> chosen(recording, candidates)
          :error -> :error
        end
    end
  end

  # The first name in a credit written as one string.
  #
  # Deliberately *not* `OnePlaylist.Matching.Normalize.credits/1`, which returns
  # an unordered set of normalized names — "first" would be arbitrary, and the
  # query is better with the original spelling. Deliberately not applied to the
  # stored value either: `Earth, Wind & Fire` splits into three here, which is
  # harmless for a second attempt at a search and would be data corruption in
  # `OnePlaylist.Formats.CSV`, which refuses to do it for exactly that reason.
  #
  # A wrong split can only cost recall. The candidates it finds are still scored
  # by the ladder at `@every_field_agreed`, so a query that names the wrong
  # artist answers with recordings that fail to corroborate and are declined.
  defp lead_name(nil), do: nil

  defp lead_name(credit) do
    credit
    |> String.split(~r/\s*[,&\/+]\s*/u, parts: 2)
    |> List.first()
    |> String.trim()
    |> case do
      "" -> nil
      name -> name
    end
  end

  defp search(title, artist, opts \\ []) do
    case Client.search_recordings(title, artist, opts) do
      {:ok, candidates} ->
        {:ok, candidates}

      {:error, reason} ->
        Logger.warning("musicbrainz recording search failed for #{title}: #{inspect(reason)}")
        :error
    end
  end

  # The ladder, at text's own ceiling. See the moduledoc for why that number is a
  # meaning rather than a tuning.
  defp chosen(recording, candidates) do
    case Matching.match(Recording.to_track(recording), candidates, threshold: @every_field_agreed) do
      {:ok, match} -> {:ok, match.track.provider_id}
      {:error, _not_matched} -> :none
    end
  end

  defp describe(recording, mbid) do
    case Client.recording(mbid) do
      {:ok, nil} ->
        record_attempt(recording, %{})

      {:ok, details} ->
        apply_details(recording, details, mbid)

      {:error, reason} ->
        Logger.warning("musicbrainz lookup failed for #{mbid}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Writes what was learned either way, but only calls it a *completed* attempt
  # when every source answered. An archive that could not be reached is not the
  # same as an album with no cover, and stamping `enriched_at` for the first
  # would make a transient outage permanent: the recording would never be
  # offered again, and nothing would say why.
  #
  # Learned the hard way. A whole library was re-enriched against a
  # `CoverArt.Service` that had not been started, every artwork call returned
  # `ServiceNotStarted`, **no job failed**, and 150 recordings were stamped as
  # fully looked at with no cover between them.
  defp apply_details(recording, details, mbid) do
    {learned, artwork} = learned(recording, details, mbid)

    case artwork do
      :unavailable ->
        _ = write(recording, learned)
        {:error, :artwork_unavailable}

      _asked_and_answered ->
        record_attempt(recording, learned)
    end
  end

  defp learned(recording, details, mbid) do
    release = choose_release(recording, Map.get(details, "releases", [])) || %{}
    artwork = artwork(recording, get_in(release, ["release-group", "id"]))

    fields = %{
      musicbrainz_recording_id: mbid,
      musicbrainz_release_id: release["id"],
      isrc: details |> Map.get("isrcs", []) |> List.first() |> Isrc.normalize(),
      album: release["title"],
      album_upc: release["barcode"],
      duration_seconds: details["length"] && div(details["length"], 1000),
      artwork_url: if(is_binary(artwork), do: artwork)
    }

    {fields, artwork}
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
  #
  # No request is made here. An earlier version asked the first few candidates
  # whether they had cover art and preferred one that did — which was the wrong
  # question in the wrong place, and is now the release group's. Deciding this
  # from the response already in hand is the whole of it.
  defp best(recording, releases) do
    releases
    |> Enum.sort_by(&ranking(recording, &1))
    |> List.first()
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

  # Only asked when there is nothing already, and only ever once per **album** —
  # see `OnePlaylist.CoverArt.Client` for why the release group rather than the
  # release, and for the measurement that forced the change.
  # Answers `nil` when there is nothing to ask about or the recording already has
  # a cover, a URL when the archive holds one, and `:unavailable` when it could
  # not be asked — which `apply_details/3` treats as an incomplete attempt.
  defp artwork(%Recording{artwork_url: existing}, _group_mbid) when is_binary(existing), do: nil
  defp artwork(_recording, nil), do: nil

  # `Cache` is L1 only: a cover either exists or does not, so a miss after a
  # deploy costs one request rather than a wrong answer. An error is *not*
  # cached, for the reason `OnePlaylist.MusicBrainz` gives — an outage is a fact
  # about the archive, not about the album.
  defp artwork(_recording, group_mbid) do
    case Cache.read_through({:cover_art_group, group_mbid}, fn -> ask_archive(group_mbid) end) do
      {:ok, url} -> url
      {:error, _unknown} -> :unavailable
    end
  end

  defp ask_archive(group_mbid) do
    case CoverArt.front_url(group_mbid) do
      {:ok, url} -> {:ok, url}
      {:error, _reason} -> {:error, :unknown}
    end
  end

  # Blank values are dropped rather than written, so a MusicBrainz field that is
  # absent cannot turn a gap into an empty string — which would look filled and
  # compare equal to every other empty string.
  defp record_attempt(recording, learned) do
    write(recording, Map.put(learned, :enriched_at, DateTime.utc_now()))
  end

  defp write(recording, learned) do
    attrs =
      learned
      |> Enum.reject(fn {field, value} ->
        value in [nil, "", []] or
          (field != :enriched_at and not is_nil(Map.fetch!(recording, field)))
      end)
      |> Map.new()

    recording
    |> Recording.changeset(attrs)
    |> Repo.update()
  end
end
