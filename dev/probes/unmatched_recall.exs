# Why five labelled recordings were never offered, and what would offer them.
#
# All five came back with a full page of candidates and the right one nowhere in
# it. Pearl Jam has thousands of recordings in MusicBrainz — every bootleg of
# every show — so a query of `recording:"<title>" AND artist:"Pearl Jam"` has
# more true matches than it can return, and relevance puts the wanted one
# outside the window.
#
# Three ways out, measured rather than argued:
#
#   1. **A bigger window.** One request either way; only the page size changes.
#   2. **Naming the release.** MusicBrainz indexes it, and the stored album is
#      the one piece of corroboration these tracks have.
#   3. Both.
#
# Read-only. Four requests per row at one a second.
alias OnePlaylist.Matching.Normalize
alias OnePlaylist.MusicBrainz.Service

Phoenix.CodeReloader.reload(OnePlaylistWeb.Endpoint)

agent = "OnePlaylist/0.1 ( https://github.com/jvoegele/one_playlist )"

# The wanted recordings, from `dev/Unmatched PJ Favorites.csv`.
cases = [
  {"Hard to Imagine", "Chicago Cab", "3b3750c4-75bf-4bd0-8f20-d823ef4ee222"},
  {"Improv", "Live: 05-03-03 - State College, Pennsylvania",
   "78aeb743-21e5-4cef-acfb-c55103d3f67c"},
  {"Yellow Ledbetter", "Lost Dogs: Rarities and B Sides",
   "947f2876-1043-461a-a4d6-1e05bf911021"},
  {"Footsteps", "Lost Dogs: Rarities and B Sides", "059ea5ab-72d4-433b-a480-0b5b209cf0b5"},
  {"Even Flow (Extended Version)", "rearviewmirror (greatest hits 1991-2003)",
   "1d90ed46-8ed6-4f7b-9b42-cfc963601c51"},
  # The one that was offered and vetoed, fetched so the veto can be explained.
  {"I Got You (Live)", "2000.06.20 - Verona, Italy (Live)",
   "e8ef88f6-facf-4f0e-bb75-40569dcac261"}
]

ask = fn query, limit ->
  # `Service.call/1` hands back whatever the function returns, so the function
  # returns `{:ok, tagged}` and this unwraps one layer.
  {:ok, tagged} =
    Service.call(fn ->
      [
        base_url: "https://musicbrainz.org/ws/2",
        url: "/recording",
        params: [query: query, fmt: "json", limit: limit],
        headers: [{"user-agent", agent}],
        receive_timeout: 15_000
      ]
      |> Req.new()
      |> Req.get()
      |> case do
        {:ok, %{status: 200, body: body}} -> {:ok, {:ok, Map.get(body, "recordings", [])}}
        {:ok, %{status: 503}} -> :retry
        {:ok, %{status: s}} -> {:ok, {:failed, "HTTP #{s}"}}
      {:error, e} -> {:ok, {:failed, Exception.message(e)}}
      end
    end)

  tagged
end

# Where in the results the wanted recording appears, if at all.
# Never conflates "the request failed" with "a short list": the first version of
# this probe reported a 503 as `absent of 1`, which reads exactly like a real
# result and is not one.
rank_of = fn
  {:failed, why}, _want ->
    "REQUEST FAILED (#{why})"

  {:ok, recordings}, want ->
    case Enum.find_index(recordings, &(&1["id"] == want)) do
      nil -> "absent of #{length(recordings)}"
      index -> "##{index + 1} of #{length(recordings)}"
    end
end

escape = fn text -> String.replace(text, ~r/(["\\])/, "\\\\\\1") end

try do
  results =
    Enum.map(cases, fn {title, album, want} ->
      bare = Normalize.title(title).title
      base = ~s(recording:"#{escape.(bare)}" AND artist:"Pearl Jam")
      # Unquoted, so it matches on tokens: the stored album is often longer than
      # the release MusicBrainz holds — "Lost Dogs: Rarities and B Sides" against
      # "Lost Dogs" — and a phrase query would match neither way round.
      with_release = base <> " AND release:(#{escape.(Normalize.text(album))})"

      at_10 = ask.(base, 10)
      at_100 = ask.(base, 100)
      released = ask.(with_release, 25)

      %{
        title: title,
        limit_10: rank_of.(at_10, want),
        limit_100: rank_of.(at_100, want),
        with_release: rank_of.(released, want)
      }
    end)

  %{
    fixed_by_a_bigger_window: Enum.count(results, &String.starts_with?(&1.limit_100, "#")),
    fixed_by_naming_the_release: Enum.count(results, &String.starts_with?(&1.with_release, "#")),
    detail: results
  }
rescue
  e -> %{error: e.__struct__, message: Exception.message(e)}
end
