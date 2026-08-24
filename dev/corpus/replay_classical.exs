# Scores the engine against the classical corpus, without an API call.
#
#     bin/remote dev/corpus/replay_classical.exs
#
# There is no ISRC oracle here — only 16 of 294 classical tracks in the library
# carry one — so this reports *what the engine did*, not whether it was right.
# The chosen title is printed beside the source so a human can tell.
alias OnePlaylist.Matching
alias OnePlaylist.Music.Track

cases = "dev/corpus/classical_cases.json" |> File.read!() |> Jason.decode!()

to_track = fn c ->
  %Track{
    provider: :tidal, provider_id: c["provider_id"], isrc: c["isrc"], title: c["title"],
    version: c["version"], album: c["album"], artists: c["artists"] || [],
    duration_seconds: c["duration_seconds"]
  }
end

results =
  Enum.map(cases, fn k ->
    source = %Track{
      provider: :file, provider_id: "s", isrc: nil, title: k["title"],
      album: k["album"], artists: [k["artist"]], duration_seconds: k["duration_seconds"]
    }

    case Matching.match(source, Enum.map(k["candidates"], to_track)) do
      {:ok, m} -> {to_string(m.strategy), k["title"], m.track.title, m.track.album}
      {:error, e} -> {to_string(Errata.reason(e)), k["title"], nil, nil}
    end
  end)

%{
  cases: length(results),
  outcomes: results |> Enum.frequencies_by(&elem(&1, 0)) |> Enum.sort(),
  work_matches:
    for {"work", src, dest, album} <- results do
      "#{String.slice(src, 0, 44)}  ->  #{String.slice(dest, 0, 44)} [#{String.slice(album || "", 0, 22)}]"
    end
}
