defmodule OnePlaylist.MusicBrainz do
  @moduledoc """
  What else a recording is called, cached in two tiers.

  ## The problem this solves

  An ISRC names a recording **as issued**, so the same master carries a
  different code on every reissue. Roon exports Eddie Vedder's *Setting Forth*
  as `USJY50700001`, the 2007 soundtrack; TIDAL holds `USJY51700100`, the 2017
  reissue. Asking TIDAL for the first returns nothing, and the track was
  reported as "nothing found on the destination" while sitting in the catalogue
  under another number.

  `family/2` answers with both, so `OnePlaylist.Matching.Strategy.IsrcFamily`
  can recognise a candidate the direct lookup missed.

  ## Called on failure, never on the happy path

  This is consulted only after an identifier lookup has already missed — about
  one ISRC-bearing track in seven, measured against the credit corpus. That
  matters because MusicBrainz asks for one request a second and means it: doing
  this per track would spend ninety minutes on a five thousand track playlist.

  Both tiers then make the second occurrence free. `OnePlaylist.Cache` holds it
  per node; `musicbrainz_isrc_lookups` holds it for the whole application and
  survives deploys. The fact is permanent, which is the ideal shape for a cache
  — an ISRC does not stop naming a recording.

  ## A miss is remembered too

  MusicBrainz not knowing an ISRC is an answer, and re-asking for it is the case
  that costs the most: a playlist of bootlegs is exactly the playlist whose
  ISRCs are unknown. Those rows expire nightly, because the database is edited
  continuously and an absence is only true for now.
  """

  use Bond

  alias OnePlaylist.Cache
  alias OnePlaylist.Errors
  alias OnePlaylist.Music.Isrc
  alias OnePlaylist.MusicBrainz.Client
  alias OnePlaylist.MusicBrainz.IsrcLookup
  alias OnePlaylist.MusicBrainz.Recording
  alias OnePlaylist.MusicBrainz.Release
  alias OnePlaylist.MusicBrainz.WorkLookup
  alias OnePlaylist.Repo

  require Logger

  # Bounds an L1 entry so a negative answer refreshes from L2 rather than
  # living forever in memory. A positive that lapses costs one Postgres read,
  # not one MusicBrainz request, which is the point of having L2 at all.
  @l1_ttl :timer.hours(24)

  @doc """
  Every ISRC naming the same recording as this one, or `[]` if unknown.

  Always includes the ISRC asked about, when the answer is non-empty. Callers
  compare candidate identifiers against the whole list, so a family missing its
  own key would fail to recognise the very track it was fetched for.

  Never returns an error. A MusicBrainz outage, a rate limit or a malformed
  identifier all answer `[]`, because every caller is already handling "the
  identifier rung found nothing" and there is nothing more useful for them to
  do with the difference. The failure is logged, not propagated.
  """
  # The whole point of the value: it is a *superset* of what the caller already
  # had. A family that dropped its own key would silently stop matching the
  # track it was looked up for, and nothing downstream would report it.
  # Against the *canonical* form of the argument, not the argument. A caller may
  # pass "usjy5-070-0001"; the family holds "USJY50700001", and every consumer
  # compares canonical identifiers. Stated over the raw input, this would fire
  # on the very normalisation it exists to permit.
  @post whenever([_ | _] <- result, contains_the_key: Isrc.normalize(isrc) in result)
  @spec family(String.t() | nil, keyword()) :: [String.t()]
  def family(isrc, opts \\ [])

  def family(isrc, opts) when is_binary(isrc) do
    case lookup(isrc, opts) do
      %{isrcs: isrcs} -> isrcs
      nil -> []
    end
  end

  def family(_isrc, _opts), do: []

  @doc """
  MusicBrainz's identifier for the recording an ISRC names, or `nil`.

  The other half of the fact `family/2` already fetches and caches, which is why
  this costs nothing on top of matching: an ISRC lookup answers with an MBID and
  the codes beside it, and until now only the codes were being read back.

  `OnePlaylist.Library.Enrichment` wants the MBID, because that is what a
  recording lookup is addressed by. Never returns an error, for the reason given
  on `family/2`.
  """
  @spec recording_mbid(String.t() | nil, keyword()) :: String.t() | nil
  def recording_mbid(isrc, opts \\ [])

  def recording_mbid(isrc, opts) when is_binary(isrc) do
    case lookup(isrc, opts) do
      %{recording_mbid: mbid} -> mbid
      nil -> nil
    end
  end

  def recording_mbid(_isrc, _opts), do: nil

  @doc """
  Titles of the works MusicBrainz thinks a classical title names.

  For the case `Strategy.Work` cannot handle alone: a title that names its piece
  exactly and gives no catalogue number. "Brandenburg Concerto no. 2 in F major"
  is one; every catalogue TIDAL carries writes `BWV 1047`, and there is nothing
  local to bridge that with.

  Returns titles rather than numbers, because that is where the numbers are and
  `OnePlaylist.Music.Work.parse/1` already reads them. It also crosses numbering
  systems, which no local rule can: Scarlatti's *Sonata in D minor, L 413* comes
  back as *K 9*.

  Never returns an error, for the same reason `family/2` does not: every caller
  is already handling "nothing matched", and there is nothing more useful to do
  with the difference.
  """
  @spec works(String.t() | nil, String.t() | nil, keyword()) :: [String.t()]
  def works(title, composer, opts \\ [])

  def works(title, composer, opts) when is_binary(title) do
    case query_for(title, composer) do
      "" -> []
      query -> cached_works(query, opts)
    end
  end

  def works(_title, _composer, _opts), do: []

  @doc """
  Deletes negative entries older than `older_than`, returning how many.

  The same work `pg_cron` does nightly, callable from Elixir for a test or a
  console. See the migration for why the schedule is best-effort.
  """
  @doc """
  A release and its track list, from the cache or from MusicBrainz.

  Read-through, like `recording_mbid/2`, and with one difference that matters:
  **nothing here expires**. A release fetched by its own id cannot be a negative,
  and what it says is close to immutable — see the migration for the full
  reasoning. `looked_up_at` exists so a stale release being consulted can be
  refreshed, not so one can be deleted.

  `nil` when MusicBrainz does not hold the id, or could not be reached. A caller
  cannot tell those apart and should not need to: both mean "no track list to
  compare against", and neither is remembered.
  """
  @spec release(String.t() | nil, keyword()) :: Release.t() | nil
  def release(mbid, opts \\ [])

  def release(mbid, opts) when is_binary(mbid) do
    case Cache.read_through({:musicbrainz_release, mbid}, fn -> resolve_release(mbid, opts) end,
           ttl: @l1_ttl
         ) do
      {:ok, release} -> release
      _unavailable -> nil
    end
  end

  def release(_mbid, _opts), do: nil

  @doc """
  What MusicBrainz says about a recording, by its own id.

  Answers the lookup **document**, exactly as `OnePlaylist.MusicBrainz.Client`
  would — so callers read `details["releases"]` and `details["title"]` the way
  they always have, and the cache is an implementation detail rather than a new
  shape to learn.

  Two tiers, like `release/2`: `OnePlaylist.Cache` per node, over a Postgres row
  that survives a deploy. A lookup by MBID cannot be a negative — every id here
  came from MusicBrainz in the first place — so a `nil` is passed back without
  being remembered, and nothing about this table ever expires.

  Before this existed, `Enrichment.describe/3` called the network on **every**
  attempt. Re-enrichment paid for it, so did every corpus harvest, and so did a
  646-request backfill that was re-asking questions already answered.
  """
  @spec recording(String.t() | nil, keyword()) :: {:ok, map() | nil} | {:error, term()}
  def recording(mbid, opts \\ [])

  def recording(mbid, opts) when is_binary(mbid) do
    # Passed straight back: `read_through/3` answers `{:ok, _} | {:error, _}`,
    # which is already this function's contract. `release/2` collapses an error
    # to `nil` because a caller there can do nothing with it; here the caller
    # must be able to tell an outage from an absence.
    Cache.read_through({:musicbrainz_recording, mbid}, fn -> resolve_recording(mbid, opts) end,
      ttl: @l1_ttl
    )
  end

  def recording(_mbid, _opts), do: {:ok, nil}

  defp resolve_recording(mbid, opts) do
    case Repo.get(Recording, mbid) do
      %Recording{document: document} -> {:ok, document}
      nil -> ask_recording(mbid, opts)
    end
  end

  # An error is **propagated, not swallowed**, which is where this differs from
  # `ask_release/2`. A release that cannot be fetched costs a barcode and a
  # cover; a recording that cannot be fetched is the whole answer, and
  # `describe/3` has to be able to tell "MusicBrainz is down" from "MusicBrainz
  # has nothing" — an outage recorded as a completed attempt is a recording
  # never asked about again.
  defp ask_recording(mbid, opts) do
    case Client.recording(mbid, opts) do
      {:ok, nil} -> {:ok, nil}
      {:ok, document} -> {:ok, remember_recording(mbid, document)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remember_recording(mbid, document) do
    row = %Recording{
      mbid: mbid,
      title: document["title"],
      length_ms: document["length"],
      isrcs: Map.get(document, "isrcs", []),
      artist_credit: document |> Client.artist_credit() |> Enum.join(", "),
      document: document,
      looked_up_at: DateTime.utc_now()
    }

    # `on_conflict: :nothing`, for the race `remember_release/2` documents: two
    # callers resolving one recording concurrently produce one row, and neither
    # of them fails.
    Repo.insert(row, on_conflict: :nothing, conflict_target: :mbid)

    document
  end

  defp resolve_release(mbid, opts) do
    case Repo.get(Release, mbid) do
      %Release{} = cached -> {:ok, cached}
      nil -> ask_release(mbid, opts)
    end
  end

  defp ask_release(mbid, opts) do
    case Client.release(mbid, opts) do
      {:ok, nil} ->
        # Not remembered. "MusicBrainz does not hold this id" is the one answer
        # this table has no shape for, and it is also the one a caller can do
        # nothing with.
        {:ok, nil}

      {:ok, document} ->
        {:ok, remember_release(mbid, document)}

      {:error, reason} ->
        Logger.warning(
          "musicbrainz release lookup failed for #{mbid}: #{Errors.describe(reason)}"
        )

        {:ok, nil}
    end
  end

  defp remember_release(mbid, document) do
    row = %Release{
      mbid: mbid,
      title: document["title"],
      artist_credit:
        document |> Map.get("artist-credit", []) |> Enum.map_join(", ", & &1["name"]),
      barcode: document["barcode"],
      date: document["date"],
      release_group_mbid: get_in(document, ["release-group", "id"]),
      release_group_title: get_in(document, ["release-group", "title"]),
      primary_type: get_in(document, ["release-group", "primary-type"]),
      secondary_types: get_in(document, ["release-group", "secondary-types"]) || [],
      tracks: tracks_in(document),
      looked_up_at: DateTime.utc_now()
    }

    # `on_conflict: :nothing`, so two callers resolving one release concurrently
    # produce one row and neither fails — the same race `Library.create/1`
    # documents.
    Repo.insert(row, on_conflict: :nothing, conflict_target: :mbid)

    row
  end

  # **`media[].tracks`, plural.** A recording *search* nests the matching track
  # under `media[].track` instead, and reading the wrong key yields an empty
  # list rather than an error — which is a silent way to cache a release with no
  # tracks in it.
  defp tracks_in(document) do
    document
    |> Map.get("media", [])
    |> Enum.flat_map(&Map.get(&1, "tracks", []))
    |> Enum.map(fn track ->
      %{
        "position" => track["position"],
        "title" => track["title"],
        "recording_mbid" => get_in(track, ["recording", "id"]),
        "length_ms" => track["length"] || get_in(track, ["recording", "length"])
      }
    end)
  end

  @spec prune_negatives(String.t()) :: non_neg_integer()
  def prune_negatives(older_than \\ "30 days") do
    # `$1::text::interval` rather than `$1::interval`: Postgrex otherwise infers
    # the parameter type from the function signature and refuses to encode a
    # string as an interval. Casting from text lets Postgres parse it, which is
    # where interval syntax belongs.
    %{rows: [[removed]]} =
      Repo.query!("select public.prune_musicbrainz_isrc_lookups($1::text::interval)", [older_than])

    removed
  end

  # Title and the composer's **surname**, folded.
  #
  # The composer is not decoration: a search for "Prelude" alone answers with
  # tens of thousands of works, and the client's score floor is only meaningful
  # once the query is specific. The surname rather than the full name is not
  # decoration either — "Brandenburg Concerto no. 2 johann sebastian bach"
  # returned *Johann Sebastian Bach auf Rügen* and no catalogue number at all,
  # where "…bach" returns *Brandenburgisches Konzert Nr. 2 F-Dur, BWV 1047*.
  # The forenames match works *about* the composer.
  defp query_for(title, composer) do
    [title, surname(composer)]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp surname(composer) when is_binary(composer) do
    composer
    |> String.replace(",", " ")
    |> String.split(~r/\s+/u, trim: true)
    |> List.last()
    |> Kernel.||("")
  end

  defp surname(_composer), do: ""

  defp cached_works(query, opts) do
    case Cache.read_through({:musicbrainz_work, query}, fn -> resolve_works(query, opts) end,
           ttl: @l1_ttl
         ) do
      {:ok, titles} -> titles
      {:error, _reason} -> []
    end
  end

  defp resolve_works(query, opts) do
    case Repo.get(WorkLookup, query) do
      %WorkLookup{catalogue_titles: nil} -> {:ok, []}
      %WorkLookup{catalogue_titles: titles} -> {:ok, titles}
      nil -> ask_works(query, opts)
    end
  end

  defp ask_works(query, opts) do
    case Client.works(query, opts) do
      {:ok, titles} ->
        Repo.insert(
          %WorkLookup{
            query: query,
            catalogue_titles: if(titles == [], do: nil, else: titles),
            looked_up_at: DateTime.utc_now()
          },
          on_conflict: :nothing,
          conflict_target: [:query]
        )

        {:ok, titles}

      {:error, reason} ->
        Logger.warning("musicbrainz work lookup failed for #{query}: #{Errors.describe(reason)}")
        {:ok, []}
    end
  end

  # Both public readers share one cached fact, so asking for the MBID after the
  # family — which enrichment does on every ISRC-bearing recording — is free.
  defp lookup(isrc, opts) do
    with canonical when is_binary(canonical) <- Isrc.normalize(isrc),
         {:ok, answer} <-
           Cache.read_through({:musicbrainz_isrc, canonical}, fn -> resolve(canonical, opts) end,
             ttl: @l1_ttl
           ) do
      answer
    else
      _unknown -> nil
    end
  end

  defp resolve(isrc, opts) do
    case fetch_l2(isrc) do
      {:ok, answer} -> {:ok, answer}
      :miss -> ask(isrc, opts)
    end
  end

  defp fetch_l2(isrc) do
    case Repo.get(IsrcLookup, isrc) do
      nil ->
        :miss

      %IsrcLookup{isrcs: nil} ->
        {:ok, %{recording_mbid: nil, isrcs: []}}

      %IsrcLookup{recording_mbid: mbid, isrcs: isrcs} ->
        {:ok, %{recording_mbid: mbid, isrcs: isrcs}}
    end
  end

  defp ask(isrc, opts) do
    case Client.isrc_family(isrc, opts) do
      {:ok, nil} ->
        remember(isrc, nil)
        {:ok, %{recording_mbid: nil, isrcs: []}}

      {:ok, %{recording_mbid: mbid, isrcs: isrcs}} ->
        remember(isrc, %{recording_mbid: mbid, isrcs: isrcs})
        {:ok, %{recording_mbid: mbid, isrcs: isrcs}}

      {:error, reason} ->
        # Not remembered. A failure is about MusicBrainz being unreachable
        # rather than about the ISRC, and caching it would turn a minute's
        # outage into a month of wrong answers.
        Logger.warning("musicbrainz lookup failed for #{isrc}: #{Errors.describe(reason)}")
        {:ok, %{recording_mbid: nil, isrcs: []}}
    end
  end

  # `on_conflict: :nothing`: two nodes learning the same fact at once is
  # expected and their answers agree, so the loser has nothing to correct. It
  # also keeps `looked_up_at` meaning "when we first learned this", which is
  # what the negative TTL wants.
  defp remember(isrc, nil) do
    insert(%IsrcLookup{isrc: isrc, recording_mbid: nil, isrcs: nil})
  end

  defp remember(isrc, %{recording_mbid: mbid, isrcs: isrcs}) do
    insert(%IsrcLookup{isrc: isrc, recording_mbid: mbid, isrcs: isrcs})
  end

  defp insert(%IsrcLookup{} = row) do
    Repo.insert(%{row | looked_up_at: DateTime.utc_now()},
      on_conflict: :nothing,
      conflict_target: [:isrc]
    )
  end
end
