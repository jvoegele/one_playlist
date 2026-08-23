# The honest cross-service match rate.
#
#     bin/remote dev/measure/match_rate.exs
#
# Source metadata from MusicBrainz (dev/measure/fetch_musicbrainz.exs);
# candidates from the live TIDAL catalogue. Two different organisations
# catalogued these recordings independently, which is the thing every previous
# measurement in this project lacked.
#
# ## The oracle
#
# The source ISRC is **withheld from the engine** — the Track handed to the
# matcher carries `isrc: nil`, so `Tidal.search_tracks/3` takes the text path
# rather than the identifier lookup, and every rung above text is unavailable.
#
# The ISRC is then used, and only then, to score the answer: a match is correct
# when the TIDAL candidate's ISRC appears in the MusicBrainz recording's ISRC
# set. The engine never sees the value it is being judged against, which is what
# separates this from measuring a system against its own output.
#
# Set membership rather than equality because one recording legitimately carries
# several ISRCs — one per release it appeared on. Fleetwood Mac's "Dreams" has
# seven. Equality would score a correct match as wrong whenever the two services
# happened to reference different releases of the same recording.
#
# ## What is separated out, and why it matters
#
# A miss has two quite different causes, and reporting them together would flatter
# or damn the engine arbitrarily:
#
#   * **Not offered.** TIDAL's text search never returned the right recording, so
#     no ladder could have found it. That is search recall, not matching.
#   * **Not chosen.** The right recording *was* among the candidates and the
#     engine did not pick it, or picked another. That is the engine's fault.
#
# The second number is the one nobody has measured here, and the one that says
# whether the product works.
#
# ## Why ISRC alone is only a floor
#
# The first run of this script scored 16 matches wrong, and reading them showed
# most were not wrong at all. Six were Björk's *Homogenic*, matched title-for-
# title at 0.980 — a perfect text score — to a TIDAL entry whose ISRC is simply
# not among the ones MusicBrainz records for that recording. The two catalogues
# reference different releases of the same performance, and an ISRC identifies a
# *release's* track rather than the performance.
#
# So ISRC membership proves a match correct and cannot prove one wrong. A second,
# independent signal is needed to tell "different recording" from "same recording,
# different release", and duration is the obvious one: two masters of one
# performance agree to within a couple of seconds, while a different take, a live
# version or an edit does not.
#
# Reported as a band rather than a point, because that is what the evidence
# supports:
#
#   * `:isrc_confirmed`         — the identifier agrees. Certainly right.
#   * `:duration_corroborated`  — identifier differs, length agrees within 3s.
#                                 Almost certainly the same performance.
#   * `:contradicted`           — length disagrees materially. Probably wrong.

alias OnePlaylist.Matching
alias OnePlaylist.Music.Track
alias OnePlaylist.Providers
alias OnePlaylist.Providers.Tidal

corpus = "dev/measure/musicbrainz_corpus.json" |> File.read!() |> Jason.decode!()

{:ok, connection} =
  Providers.Connection
  |> OnePlaylist.Repo.all()
  |> Enum.find(&(&1.provider == :tidal))
  |> case do
    nil -> {:error, :no_tidal_connection}
    c -> Providers.ensure_fresh(c)
  end

classify = fn row, candidates, result ->
  truth = MapSet.new(row["isrcs"])
  offered? = Enum.any?(candidates, &(&1.isrc && MapSet.member?(truth, &1.isrc)))

  # Three seconds. Wide enough for the fade differences between two masters of
  # one performance, narrow enough to separate a single edit from an album cut.
  agrees_on_length? = fn chosen ->
    source_length = row["duration_seconds"]

    is_integer(source_length) and is_integer(chosen.duration_seconds) and
      abs(source_length - chosen.duration_seconds) <= 3
  end

  outcome =
    case result do
      {:ok, match} ->
        cond do
          match.track.isrc && MapSet.member?(truth, match.track.isrc) -> :isrc_confirmed
          agrees_on_length?.(match.track) -> :duration_corroborated
          true -> :contradicted
        end

      {:error, _error} ->
        :no_match
    end

  %{
    title: row["title"],
    album: row["album"],
    artists: row["artists"],
    offered?: offered?,
    outcome: outcome,
    candidates: length(candidates),
    source_seconds: row["duration_seconds"],
    chose_seconds: match?({:ok, _}, result) && elem(result, 1).track.duration_seconds,
    score: match?({:ok, _}, result) && elem(result, 1).score,
    strategy: match?({:ok, _}, result) && elem(result, 1).strategy,
    confidence: match?({:ok, _}, result) && elem(result, 1).confidence,
    chose: match?({:ok, _}, result) && elem(result, 1).track.title,
    chose_isrc: match?({:ok, _}, result) && elem(result, 1).track.isrc
  }
end

results =
  Enum.map(corpus, fn row ->
    # The ISRC is withheld here. Everything else the provider gave us is kept.
    source = %Track{
      provider: :musicbrainz,
      provider_id: row["musicbrainz_id"],
      isrc: nil,
      title: row["title"],
      album: row["album"],
      artists: row["artists"],
      duration_seconds: row["duration_seconds"]
    }

    case Tidal.search_tracks(connection, source, limit: 25) do
      {:ok, candidates} ->
        classify.(row, candidates, Matching.match(source, candidates))

      {:error, error} ->
        %{
          title: row["title"],
          album: row["album"],
          outcome: :search_failed,
          offered?: false,
          candidates: 0,
          error: inspect(error)
        }
    end
  end)

File.write!("dev/measure/match_rate_results.json", Jason.encode!(results, pretty: true))

tally = Enum.frequencies_by(results, & &1.outcome)
total = length(results)
at = &Map.get(tally, &1, 0)
pct = &Float.round(&1 / total * 100, 1)

%{
  total: total,
  outcomes: tally,
  # The floor: only what the identifier proves.
  certainly_right: pct.(at.(:isrc_confirmed)),
  # The band: adding the matches an independent signal corroborates.
  probably_right: pct.(at.(:isrc_confirmed) + at.(:duration_corroborated)),
  # What is left, and the honest upper bound on how wrong the engine can be.
  possibly_wrong: pct.(at.(:contradicted)),
  found_nothing: pct.(at.(:no_match)),
  tidal_search_offered_the_isrc_match: pct.(Enum.count(results, & &1.offered?))
}
