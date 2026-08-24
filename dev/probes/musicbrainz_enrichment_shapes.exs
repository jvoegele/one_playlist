# What MusicBrainz actually returns for the three enrichment questions, before
# any of it is designed against.
#
#   1. With no ISRC, does a recording *search* carry one back?
#   2. What does a recording lookup by MBID give in one request?
#   3. Do the releases it embeds say whether Cover Art Archive has artwork?
#
# Four requests at one per second. Read-only.
alias OnePlaylist.MusicBrainz.Service

Phoenix.CodeReloader.reload(OnePlaylistWeb.Endpoint)

agent = "OnePlaylist/0.1 ( https://github.com/jvoegele/one_playlist )"

get = fn path, params ->
  Service.call(fn ->
    [
      base_url: "https://musicbrainz.org/ws/2",
      url: path,
      params: [{"fmt", "json"} | params],
      headers: [{"user-agent", agent}],
      receive_timeout: 15_000
    ]
    |> Req.new()
    |> Req.get()
    |> case do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:ok, %{"__status" => status}}
      {:error, e} -> {:ok, %{"__error" => Exception.message(e)}}
    end
  end)
end

keys = fn
  map when is_map(map) -> map |> Map.keys() |> Enum.sort()
  other -> other
end

try do
  # 1. Search by title and artist, the case a CSV import lands in.
  {:ok, search} =
    get.("/recording", [{"query", ~s(recording:"Corduroy" AND artist:"Pearl Jam")}, {"limit", 3}])

  first = search |> Map.get("recordings", []) |> List.first() || %{}

  # 2. Lookup by MBID, asking for everything enrichment might want at once.
  mbid = first["id"]

  {:ok, lookup} =
    get.("/recording/#{mbid}", [{"inc", "artist-credits+releases+isrcs+work-rels"}])

  releases = Map.get(lookup, "releases", [])
  release = List.first(releases) || %{}

  # 3. Does a *release* lookup say whether artwork exists, and is that in the
  #    embedded list or only on the release itself?
  {:ok, release_lookup} =
    if release["id"], do: get.("/release/#{release["id"]}", []), else: {:ok, %{}}

  %{
    search: %{
      result_keys: keys.(first),
      score: first["score"],
      title: first["title"],
      has_isrcs_field: Map.has_key?(first, "isrcs"),
      isrcs: first["isrcs"],
      length: first["length"],
      artist: get_in(first, ["artist-credit", Access.at(0), "name"])
    },
    lookup: %{
      mbid: mbid,
      result_keys: keys.(lookup),
      isrcs: Map.get(lookup, "isrcs"),
      length: Map.get(lookup, "length"),
      artist_credit: lookup |> Map.get("artist-credit", []) |> Enum.map(& &1["name"]),
      release_count: length(releases),
      first_release: %{
        keys: keys.(release),
        title: release["title"],
        date: release["date"],
        embedded_cover_art: Map.get(release, "cover-art-archive")
      },
      relations: lookup |> Map.get("relations", []) |> Enum.map(& &1["type"]) |> Enum.uniq()
    },
    release_lookup: %{
      cover_art_archive: Map.get(release_lookup, "cover-art-archive"),
      barcode: Map.get(release_lookup, "barcode")
    }
  }
rescue
  e -> %{error: e.__struct__, message: Exception.message(e)}
end
