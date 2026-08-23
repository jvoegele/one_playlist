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

# A `decline` case is the one an ISRC oracle cannot produce: a person looked at
# what TIDAL offered and said none of it is the recording. They are the only
# cases that can catch a *wrong match against an absent truth* — the shape the
# Powderfinger bug had, and the shape the self-labelled cases are blind to.
declines =
  for kase <- cases, kase["expect"] == "decline" do
    source = %Track{
      provider: :file,
      provider_id: "s",
      isrc: nil,
      title: kase["title"],
      album: kase["album"],
      artists: [kase["artist"]],
      duration_seconds: kase["duration_seconds"]
    }

    outcome =
      case Matching.match(source, Enum.map(kase["candidates"], to_track)) do
        {:ok, _wrong} -> :FALSE_POSITIVE
        {:error, _reason} -> :correctly_declined
      end

    {kase["category"], outcome, kase["artist"], kase["title"]}
  end

equivalent? = fn source, chosen ->
  same_title =
    OnePlaylist.Matching.Normalize.title(source.title, source.version).title ==
      OnePlaylist.Matching.Normalize.title(chosen.title, chosen.version).title

  close =
    is_integer(source.duration_seconds) and is_integer(chosen.duration_seconds) and
      abs(source.duration_seconds - chosen.duration_seconds) <= 3

  same_title and close
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

    # `:equivalent` is the same allowance `dev/measure/replay.exs` makes with its
    # `duration_corroborated` bucket, and it is not generosity. An ISRC names a
    # recording *as issued*, so a catalogue holding the same recording on two
    # releases has two of them, and the oracle can only name one. Prince's
    # "Purple Rain" is the case that forced this: the engine chose a candidate
    # one second from the source and the labelled answer is seven seconds off.
    # Calling that wrong would be scoring the engine against the label's
    # arbitrariness rather than against the truth.
    #
    # The bar is deliberately tight — same title after normalization, within
    # three seconds — because a loose one would absorb the errors this corpus
    # exists to find.
    outcome =
      case Matching.match(source, candidates) do
        {:ok, %{track: %{provider_id: ^wanted}}} ->
          :correct

        {:ok, %{track: chosen}} ->
          if equivalent?.(source, chosen), do: :equivalent, else: :WRONG

        {:error, _reason} ->
          :missed
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
  declines: length(declines),
  declines_outcome: declines |> Enum.frequencies_by(&elem(&1, 1)) |> Enum.sort(),
  false_positives: for({_c, :FALSE_POSITIVE, a, t} <- declines, do: "#{a} - #{t}"),
  wrong: for({_c, :WRONG, a, t} <- judged, do: "#{a} - #{t}"),
  missed: for({_c, :missed, a, t} <- judged, do: "#{a} - #{t}")
}
