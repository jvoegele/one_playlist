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

alias OnePlaylist.Music.Work

worth_asking? = fn source, candidates ->
  not Work.identifies_work?(Work.parse(source.title)) and
    Enum.any?(candidates, &Work.identifies_work?(Work.parse("#{&1.title} #{&1.album}")))
end

results =
  Enum.map(cases, fn k ->
    source = %Track{
      provider: :file, provider_id: "s", isrc: nil, title: k["title"],
      album: k["album"], artists: [k["artist"]], duration_seconds: k["duration_seconds"]
    }

    candidates = Enum.map(k["candidates"], to_track)

    # Exactly what `Runner.retry_with_work/4` does: on failure, and only when the
    # source names no work while some candidate does, ask MusicBrainz and
    # re-match the candidates already in hand.
    case Matching.match(source, candidates) do
      {:ok, m} ->
        {to_string(m.strategy), k["title"], m.track.title, m.track.album}

      {:error, e} ->
        if worth_asking?.(source, candidates) do
          case OnePlaylist.MusicBrainz.works(source.title, k["artist"]) do
            [] ->
              {to_string(Errata.reason(e)), k["title"], nil, nil}

            titles ->
              case Matching.match(%{source | work_titles: titles}, candidates) do
                {:ok, m} -> {"work_via_mb", k["title"], m.track.title, m.track.album}
                {:error, e2} -> {to_string(Errata.reason(e2)), k["title"], nil, nil}
              end
          end
        else
          {to_string(Errata.reason(e)), k["title"], nil, nil}
        end
    end
  end)

%{
  cases: length(results),
  outcomes: results |> Enum.frequencies_by(&elem(&1, 0)) |> Enum.sort(),
  work_matches:
    for {strategy, src, dest, album} <- results, strategy in ["work", "work_via_mb"] do
      "#{String.slice(src, 0, 44)}  ->  #{String.slice(dest, 0, 44)} [#{String.slice(album || "", 0, 22)}]"
    end
}
