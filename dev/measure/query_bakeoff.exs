# Which query finds the track? A bake-off against the live TIDAL catalogue.
#
#     bin/remote dev/measure/query_bakeoff.exs
#
# `dev/measure/replay.exs` cannot answer this. It replays candidates captured
# once, so recall is fixed at capture time — the one number it explicitly says
# it cannot measure, and the one `CLAUDE.md` has named as the binding constraint
# all along: TIDAL's text search returns an ISRC-matching candidate for only
# **86%** of the corpus, and no amount of scoring work reaches the other 14%.
#
# Recall can only be measured by asking differently and seeing what comes back.
# So this asks the same hundred recordings for several phrasings and reports how
# often each one surfaces the right track.
#
# ## The oracle, unchanged
#
# The source ISRC is withheld from the query and used only to judge the answer:
# a phrasing succeeded when some candidate it returned carries an ISRC that
# MusicBrainz lists for that recording. Set membership rather than equality,
# because one recording legitimately carries several — see `match_rate.exs`.
#
# ## The hypothesis
#
# `Track.search_query/1` sends the **raw** title and every credited artist.
# Enrichment does not: `MusicBrainz.by_name/1` sends the *parsed* title, and its
# comment says why — *"The Face Of Love (with Eddie Vedder)" matches no
# recording; "the face of love" matches it exactly.* That lesson was learned
# against MusicBrainz and never applied to TIDAL.
#
# Whether it transfers is exactly the kind of thing this project measures rather
# than argues about, and one phrasing here has already been rejected once on
# evidence: querying the primary artist instead of the whole credit. It is
# included so the rejection is re-tested rather than remembered.
#
# ## Cost
#
# One search per phrasing per recording, against a service this project rate
# limits to eight a second — a few hundred requests, about a minute. Cheap
# enough to re-run whenever a phrasing is proposed.

alias OnePlaylist.Matching.Normalize
alias OnePlaylist.Music.Track
alias OnePlaylist.Providers
alias OnePlaylist.Providers.Tidal

corpus = "dev/measure/musicbrainz_corpus.json" |> File.read!() |> Jason.decode!()

{:ok, connection} =
  Providers.Connection
  |> OnePlaylist.Repo.all()
  |> Enum.find(&(&1.provider == :tidal))
  |> case do
    nil -> {:error, :no_tidal_connection}
    c -> Providers.ensure_fresh(c)
  end

# The phrasings. Each takes the source row and returns a query string, or `nil`
# to skip — a phrasing that cannot be formed for a row is not a miss.
phrasings = [
  {"current (raw title + every artist)",
   fn row -> Enum.join([row["title"] | row["artists"]], " ") end},
  {"parsed title + every artist",
   fn row -> Enum.join([Normalize.title(row["title"]).title | row["artists"]], " ") end},
  {"parsed title + first artist",
   fn row -> Enum.join([Normalize.title(row["title"]).title, List.first(row["artists"])], " ") end},
  {"parsed title alone", fn row -> Normalize.title(row["title"]).title end},
  {"raw title + first artist",
   fn row -> Enum.join([row["title"], List.first(row["artists"])], " ") end}
]

# A phrasing succeeds when TIDAL returns *any* candidate carrying an ISRC the
# source is known by. Nothing is scored: this is recall, and the ladder's
# opinion about the candidates is a different question measured elsewhere.
found? = fn query, truth ->
  case Tidal.Client.search_tracks(connection.access_token, query, limit: 25) do
    {:ok, candidates} ->
      Enum.any?(candidates, &(&1.isrc && MapSet.member?(truth, &1.isrc)))

    _unavailable ->
      false
  end
end

IO.puts("\nasking TIDAL #{length(corpus)} × #{length(phrasings)} times…\n")

results =
  Enum.map(phrasings, fn {name, build} ->
    hits =
      corpus
      |> Enum.with_index(1)
      |> Enum.count(fn {row, index} ->
        if rem(index, 25) == 0, do: IO.puts(:stderr, "  #{name}: #{index}/#{length(corpus)}")

        truth = MapSet.new(row["isrcs"])

        case build.(row) do
          query when is_binary(query) and query != "" -> found?.(String.trim(query), truth)
          _unusable -> false
        end
      end)

    {name, hits}
  end)

# What a *fallback* would add: the current phrasing, and the parsed one only
# where the current found nothing. That is the shape a fix would actually take —
# nobody replaces a working query, they add a retry — and its cost is one extra
# request per miss rather than one per track.
{_name, current} = List.first(results)

union =
  corpus
  |> Enum.count(fn row ->
    truth = MapSet.new(row["isrcs"])
    raw = Enum.join([row["title"] | row["artists"]], " ")
    parsed = Enum.join([Normalize.title(row["title"]).title | row["artists"]], " ")

    found?.(raw, truth) or (raw != parsed and found?.(parsed, truth))
  end)

IO.puts("\nrecall — an ISRC-matching candidate was returned\n")

Enum.each(results, fn {name, hits} ->
  IO.puts("  #{String.pad_trailing(name, 34)} #{hits}/#{length(corpus)}")
end)

IO.puts("")
IO.puts("  #{String.pad_trailing("current, then parsed on a miss", 34)} #{union}/#{length(corpus)}")
IO.puts("  (the shape a fix would take: one extra request per miss)\n")

%{baseline: current, best_single: results |> Enum.max_by(&elem(&1, 1)) |> elem(0), fallback: union}
