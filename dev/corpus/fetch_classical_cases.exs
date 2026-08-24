# Captures what TIDAL offers for each classical source, for offline iteration.
#
#     bin/remote dev/corpus/fetch_classical_cases.exs
#
# The counterpart to `fetch_credit_cases.exs`. There is no ISRC oracle here —
# only 16 of 294 classical tracks in the library carry one — so every case is
# unlabelled and the point is to see *what is offered*, not to score anything
# yet.
import Ecto.Query

alias OnePlaylist.Music.Track
alias OnePlaylist.Providers
alias OnePlaylist.Providers.Connection
alias OnePlaylist.Providers.Tidal

owner =
  OnePlaylist.Repo.one!(
    from c in Connection,
      where: c.provider == :tidal and c.status == :active,
      select: c.user_id,
      limit: 1
  )

{:ok, connection} = Providers.fetch_usable_connection(owner, :tidal)

sources = "dev/corpus/classical_sources.json" |> File.read!() |> Jason.decode!()

capture = fn t ->
  %{
    "provider_id" => t.provider_id,
    "isrc" => t.isrc,
    "title" => t.title,
    "version" => t.version,
    "album" => t.album,
    "artists" => t.artists,
    "duration_seconds" => t.duration_seconds
  }
end

cases =
  Enum.map(sources, fn source ->
    query =
      Track.from_map(%{
        "provider" => "file",
        "provider_id" => "s",
        "isrc" => nil,
        "title" => source["title"],
        "album" => source["album"],
        "artists" => [source["artist"]],
        "duration_seconds" => source["duration_seconds"]
      })

    candidates =
      try do
        case Tidal.search_tracks(connection, query, limit: 10) do
          {:ok, tracks} -> Enum.map(tracks, capture)
          {:error, _reason} -> []
        end
      rescue
        _error -> []
      end

    Map.put(source, "candidates", candidates)
  end)

File.write!("dev/corpus/classical_cases.json", Jason.encode!(cases, pretty: true))

%{
  cases: length(cases),
  with_candidates: Enum.count(cases, &(&1["candidates"] != [])),
  median_candidates:
    cases |> Enum.map(&length(&1["candidates"])) |> Enum.sort() |> Enum.at(div(length(cases), 2))
}
