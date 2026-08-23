# Builds a corpus of recordings catalogued by *somebody else*.
#
#     MIX_ENV=test mix run dev/measure/fetch_musicbrainz.exs
#
# Every match-quality number this project has produced so far is soft in the
# same way: both sides came from the same metadata. TIDAL→TIDAL compares one
# cataloguer's spellings against themselves, and the Navidrome library's tags
# were *generated from* the TIDAL corpus. See docs/reference/domain.md.
#
# MusicBrainz fixes that. It is an open catalogue written by a different
# community over twenty years, and — the part that makes an honest measurement
# possible at all — it records **ISRCs**. So a recording taken from here carries
# its own identity, independent of anything TIDAL says, and that identity can
# serve as the oracle for whether a text match found the right recording.
#
# ## The selection rule, stated before the numbers were seen
#
# Ten releases, chosen for *spread* rather than for expected success:
#
#   * across six decades, so era-specific cataloguing conventions are covered;
#   * across genres, because jazz and hip-hop credit performers very differently;
#   * including diacritics (Björk, Sigur Rós, Beyoncé), non-English titles
#     (Buena Vista Social Club, Kraftwerk) and typographic apostrophes
#     (Fleetwood Mac) — the cases `OnePlaylist.Matching.Normalize` exists for;
#   * including albums with heavy `feat.` crediting (Kendrick Lamar, Beyoncé),
#     which is the single most common reason a true match fails on text.
#
# All ten are well known, and that is deliberate rather than flattering: an
# obscure release absent from TIDAL would measure *catalogue coverage* and be
# scored as a matching failure. Keeping coverage near-certain isolates the thing
# being measured.
#
# MusicBrainz asks for one request per second and a User-Agent identifying the
# caller. Both are honoured below.

Application.ensure_all_started(:req)

releases = [
  {"Fleetwood Mac", "Rumours"},
  {"Miles Davis", "Kind of Blue"},
  {"Nirvana", "Nevermind"},
  {"Björk", "Homogenic"},
  {"Sigur Rós", "Ágætis byrjun"},
  {"Daft Punk", "Discovery"},
  {"Kendrick Lamar", "To Pimp a Butterfly"},
  {"Beyoncé", "Lemonade"},
  {"Buena Vista Social Club", "Buena Vista Social Club"},
  {"Kraftwerk", "Die Mensch-Maschine"}
]

user_agent = "one_playlist-research/0.1 ( jason@jvoegele.com )"
base = "https://musicbrainz.org/ws/2"

get = fn path, params ->
  Process.sleep(1_100)

  Req.get!(base <> path,
    params: params ++ [fmt: "json"],
    headers: [{"user-agent", user_agent}],
    receive_timeout: 30_000
  ).body
end

# The first release the search returns whose tracks mostly carry ISRCs. Stated
# as a rule so the corpus is reproducible rather than hand-curated: a release
# without ISRCs cannot serve as an oracle, and picking by hand is how a corpus
# quietly becomes a set of cases that happen to work.
best_release = fn artist, album ->
  query = ~s(release:"#{album}" AND artist:"#{artist}")
  found = get.("/release/", [query: query, limit: 5])["releases"] || []

  Enum.find_value(found, fn candidate ->
    detail = get.("/release/#{candidate["id"]}", inc: "recordings+artist-credits+isrcs")
    tracks = Enum.flat_map(detail["media"] || [], & &1["tracks"] || [])
    with_isrc = Enum.count(tracks, &((&1["recording"]["isrcs"] || []) != []))

    if tracks != [] and with_isrc / length(tracks) >= 0.8, do: {detail, tracks}
  end)
end

rows =
  Enum.flat_map(releases, fn {artist, album} ->
    IO.puts("fetching #{artist} — #{album}")

    case best_release.(artist, album) do
      nil ->
        IO.puts("  no release with ISRCs found")
        []

      {detail, tracks} ->
        IO.puts("  #{length(tracks)} tracks")

        Enum.map(tracks, fn track ->
          recording = track["recording"]

          %{
            "title" => recording["title"],
            "artists" =>
              Enum.map(recording["artist-credit"] || detail["artist-credit"] || [], & &1["name"]),
            "album" => detail["title"],
            "position" => track["position"],
            "duration_seconds" => recording["length"] && div(recording["length"], 1000),
            "isrcs" => recording["isrcs"] || [],
            "musicbrainz_id" => recording["id"]
          }
        end)
    end
  end)

path = "dev/measure/musicbrainz_corpus.json"
File.write!(path, Jason.encode!(rows, pretty: true))

IO.puts("\nwrote #{length(rows)} recordings to #{path}")
IO.puts("distinct albums: #{rows |> Enum.map(& &1["album"]) |> Enum.uniq() |> length()}")
