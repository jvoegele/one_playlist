# Scores the current engine against the credit corpus, without an API call.
#
#     bin/remote dev/corpus/replay_credit_cases.exs
#
# The counterpart to `dev/measure/replay.exs`, over the cases that corpus does
# not contain: collaborations, backing bands, guest credits and version markers.
# A random hundred tracks has almost none of them, which is why an engine change
# that was clearly wrong about credits measured as neutral there.

alias OnePlaylist.Matching
alias OnePlaylist.Music.Track

cases = "dev/corpus/credit_cases.json" |> File.read!() |> Jason.decode!()

to_track = fn c ->
  %Track{
    provider: :tidal,
    provider_id: c["provider_id"],
    isrc: c["isrc"],
    title: c["title"],
    version: c["version"],
    album: c["album"],
    album_upc: c["album_upc"],
    artists: c["artists"] || [],
    duration_seconds: c["duration_seconds"]
  }
end

judged =
  for kase <- cases, is_map(kase["expect"]) do
    source = %Track{
      provider: :file,
      provider_id: "s",
      isrc: nil,
      title: kase["title"],
      album: kase["album"],
      artists: [kase["artist"]],
      duration_seconds: kase["duration_seconds"]
    }

    wanted = kase["expect"]["match"]
    candidates = Enum.map(kase["candidates"], to_track)

    outcome =
      case Matching.match(source, candidates) do
        {:ok, %{track: %{provider_id: ^wanted}}} -> :correct
        {:ok, _other} -> :WRONG
        {:error, _reason} -> :missed
      end

    {kase["category"], outcome, kase["artist"], kase["title"]}
  end

by_category =
  judged
  |> Enum.group_by(&elem(&1, 0))
  |> Map.new(fn {category, rows} ->
    {category, rows |> Enum.frequencies_by(&elem(&1, 1)) |> Enum.sort()}
  end)

%{
  judged: length(judged),
  overall: judged |> Enum.frequencies_by(&elem(&1, 1)) |> Enum.sort(),
  by_category: by_category,
  wrong: for({_c, :WRONG, a, t} <- judged, do: "#{a} - #{t}"),
  missed: for({_c, :missed, a, t} <- judged, do: "#{a} - #{t}")
}
