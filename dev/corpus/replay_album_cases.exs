# Scores `Normalize.album/1` against the harvested album corpus.
#
#     mix run --no-start dev/corpus/replay_album_cases.exs
#
# Offline and instant: `dev/corpus/album_cases.json` is labelled by MusicBrainz's
# own release groups, so nothing here asks anybody anything. See
# `dev/corpus/harvest_albums.py` for where the labels come from.
#
# ## The two directions are not equally bad
#
# A **false positive** — calling two different albums the same — is what puts
# *Vitalogy*'s cover on a *Vs.* track, or lets a pseudo-album adopt a real
# record's identity. It is the failure this corpus exists to prevent, and it is
# reported case by case rather than as a number.
#
# A **false negative** — failing to see that two titles name one album — costs a
# cover or a barcode. Worth reducing, never worth trading a false positive for.
#
# The baseline is exact equality after `Normalize.text/1`, which is what the
# comparison was before `album/1` existed. It cannot produce a false positive at
# all, so the only question about any rule that loosens it is what it costs in
# that direction.
alias OnePlaylist.Matching.Normalize

cases = "dev/corpus/album_cases.json" |> File.read!() |> Jason.decode!()

judge = fn case_, decide ->
  said_same = decide.(case_["left"], case_["right"])

  cond do
    said_same and case_["same_album"] -> :correct
    said_same -> :false_positive
    case_["same_album"] -> :false_negative
    true -> :correct
  end
end

score = fn decide ->
  cases
  |> Enum.map(&{&1, judge.(&1, decide)})
  |> Enum.group_by(fn {_case, verdict} -> verdict end, fn {case_, _verdict} -> case_ end)
end

percent = fn count, total ->
  if total == 0, do: "—", else: "#{Float.round(count * 100 / total, 1)}%"
end

report = fn name, decide ->
  by_verdict = score.(decide)
  correct = length(Map.get(by_verdict, :correct, []))
  false_positives = Map.get(by_verdict, :false_positive, [])
  false_negatives = Map.get(by_verdict, :false_negative, [])

  positives = Enum.count(cases, & &1["same_album"])

  %{
    rule: name,
    accuracy: percent.(correct, length(cases)),
    recall:
      percent.(positives - length(false_negatives), positives),
    false_positives: length(false_positives),
    false_negatives: length(false_negatives),
    worst:
      false_positives
      |> Enum.take(8)
      |> Enum.map(&"#{&1["left"]}  ==  #{&1["right"]}  (#{&1["artist"]})")
  }
end

exact = fn left, right -> Normalize.text(left) == Normalize.text(right) end
core = fn left, right -> Normalize.album(left) == Normalize.album(right) end

%{
  pairs: length(cases),
  same_album: Enum.count(cases, & &1["same_album"]),
  different_albums: Enum.count(cases, &(not &1["same_album"])),
  baseline_exact_text: report.("Normalize.text/1 equality", exact),
  album_core: report.("Normalize.album/1 equality", core)
}
|> IO.inspect(limit: :infinity, printable_limit: :infinity)
