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

  `family/2` answers with both, so `OnePlaylist.Matching.Strategy.Isrc` can
  recognise a candidate the direct lookup missed.

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
  alias OnePlaylist.Music.Isrc
  alias OnePlaylist.MusicBrainz.Client
  alias OnePlaylist.MusicBrainz.IsrcLookup
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
  # compares canonical identifiers. Stating it over the raw input made the
  # assertion fire on the very normalisation it was meant to permit.
  @post whenever([_ | _] <- result, contains_the_key: Isrc.normalize(isrc) in result)
  @spec family(String.t() | nil, keyword()) :: [String.t()]
  def family(isrc, opts \\ [])

  def family(isrc, opts) when is_binary(isrc) do
    case Isrc.normalize(isrc) do
      nil -> []
      canonical -> cached_family(canonical, opts)
    end
  end

  def family(_isrc, _opts), do: []

  @doc """
  Deletes negative entries older than `older_than`, returning how many.

  The same work `pg_cron` does nightly, callable from Elixir for a test or a
  console. See the migration for why the schedule is best-effort.
  """
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

  defp cached_family(isrc, opts) do
    case Cache.read_through({:musicbrainz_isrc, isrc}, fn -> resolve(isrc, opts) end,
           ttl: @l1_ttl
         ) do
      {:ok, isrcs} -> isrcs
      {:error, _reason} -> []
    end
  end

  defp resolve(isrc, opts) do
    case fetch_l2(isrc) do
      {:ok, isrcs} -> {:ok, isrcs}
      :miss -> ask(isrc, opts)
    end
  end

  defp fetch_l2(isrc) do
    case Repo.get(IsrcLookup, isrc) do
      nil -> :miss
      %IsrcLookup{isrcs: nil} -> {:ok, []}
      %IsrcLookup{isrcs: isrcs} -> {:ok, isrcs}
    end
  end

  defp ask(isrc, opts) do
    case Client.isrc_family(isrc, opts) do
      {:ok, nil} ->
        remember(isrc, nil)
        {:ok, []}

      {:ok, %{recording_mbid: mbid, isrcs: isrcs}} ->
        remember(isrc, %{recording_mbid: mbid, isrcs: isrcs})
        {:ok, isrcs}

      {:error, reason} ->
        # Not remembered. A failure is about MusicBrainz being unreachable
        # rather than about the ISRC, and caching it would turn a minute's
        # outage into a month of wrong answers.
        Logger.warning("musicbrainz lookup failed for #{isrc}: #{inspect(reason)}")
        {:ok, []}
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
