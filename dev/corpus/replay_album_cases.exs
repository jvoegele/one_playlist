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
#
# Three rules are scored, in the order they were adopted: the baseline,
# `album/1` equality, and `same_album?/2` — which adds the asymmetric case where
# one title *is* the other's core. The last is what the engine uses.
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
subtitle = fn left, right -> Normalize.same_album?(left, right) end

# The shipped rule: the same, refusing a head that is the artist's own name.
# `dev/corpus/album_cases.json` carries the artist for exactly this kind of
# question.
guarded = fn case_ ->
  fn left, right -> Normalize.same_album?(left, right, artists: [case_["artist"]]) end
end

%{
  pairs: length(cases),
  same_album: Enum.count(cases, & &1["same_album"]),
  different_albums: Enum.count(cases, &(not &1["same_album"])),
  baseline_exact_text: report.("Normalize.text/1 equality", exact),
  album_core: report.("Normalize.album/1 equality", core),
  same_album_unguarded: report.("same_album?/2, no artist", subtitle),
  same_album: report.("same_album?/3 with the artist guard", fn l, r ->
    case_ = Enum.find(cases, &(&1["left"] == l and &1["right"] == r))
    Normalize.same_album?(l, r, artists: [case_ && case_["artist"]])
  end)
}
|> IO.inspect(limit: :infinity, printable_limit: :infinity)
