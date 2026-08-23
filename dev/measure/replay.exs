# Re-scores the captured match-rate measurement against the current engine.
#
#     bin/remote dev/measure/replay.exs
#
# `match_rate.exs` records, for every source track, the full candidate list
# TIDAL offered. This replays those candidates through the matching ladder as
# it stands right now, so a change to the engine can be evaluated in a second
# and without a single API call.
#
# Two things it can do that the live measurement cannot:
#
#   * **Compare.** The live run costs ~15 minutes of rate-limited search and
#     gives one number. This gives the same number for any engine, so the
#     question "did that change help?" has an answer rather than an opinion.
#   * **Repeat.** TIDAL's catalogue and popularity ordering move. Two live runs
#     a week apart differ for reasons that have nothing to do with our code.
#
# What it cannot do is measure *recall* — whether the right track was offered
# at all. That is fixed at capture time, and on this corpus it is the larger
# remaining loss (14 of 100). See `docs/reference/domain.md`.
#
# The oracle is the one `match_rate.exs` defines, restated here so the two
# cannot silently diverge: a match is `certain` when the chosen track's ISRC is
# one MusicBrainz lists for that recording, `duration_corroborated` when the
# ISRC is unknown to MusicBrainz but the lengths agree within 3 seconds, and
# `WRONG` otherwise.

alias OnePlaylist.Matching
alias OnePlaylist.Music.Track

read_json = fn path -> path |> File.read!() |> Jason.decode!() end

# The corpus is the source *and* the oracle; the results file contributes only
# the candidate lists it captured. Zipped by position, which `fetch_musicbrainz`
# and `match_rate` both preserve — asserted below rather than assumed, because a
# silent misalignment would produce a plausible number that means nothing.
corpus = read_json.("dev/measure/musicbrainz_corpus.json")
captured = read_json.("dev/measure/match_rate_results.json")

paired = Enum.zip(corpus, captured)

true =
  Enum.all?(paired, fn {recording, result} ->
    recording["title"] == result["title"] and recording["album"] == result["album"]
  end)

to_track = fn candidate ->
  %Track{
    provider: :tidal,
    provider_id: candidate["provider_id"],
    isrc: candidate["isrc"],
    title: candidate["title"],
    version: candidate["version"],
    album: candidate["album"],
    album_upc: candidate["album_upc"],
    track_number: candidate["track_number"],
    volume_number: candidate["volume_number"],
    artists: candidate["artists"],
    duration_seconds: candidate["duration_seconds"],
    popularity: candidate["popularity"],
    explicit: candidate["explicit"]
  }
end

# The ISRC is withheld from the source exactly as the live run withholds it —
# otherwise rung 1 answers everything and the measurement is of nothing.
replayed =
  Enum.map(paired, fn {recording, result} ->
    source = %Track{
      provider: :musicbrainz,
      provider_id: recording["musicbrainz_id"],
      isrc: nil,
      title: recording["title"],
      album: recording["album"],
      artists: recording["artists"],
      duration_seconds: recording["duration_seconds"]
    }

    candidates = Enum.map(result["offered_candidates"] || [], to_track)
    known_isrcs = MapSet.new(recording["isrcs"] || [])

    outcome =
      case Matching.match(source, candidates) do
        {:ok, match} ->
          chosen = match.track
          delta = abs((chosen.duration_seconds || 0) - (recording["duration_seconds"] || 0))

          cond do
            chosen.isrc in known_isrcs -> :certain
            delta <= 3 -> :duration_corroborated
            true -> :WRONG
          end

        {:error, _error} ->
          :none
      end

    {recording["title"], outcome}
  end)

tally = replayed |> Enum.frequencies_by(&elem(&1, 1)) |> Enum.sort()
wrong = for {title, :WRONG} <- replayed, do: title

%{tally: tally, wrong: wrong, n: length(replayed)}
