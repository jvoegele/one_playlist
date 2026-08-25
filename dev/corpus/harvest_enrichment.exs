# Captures what MusicBrainz offers enrichment, so the text path can be scored
# offline.
#
#     mix run --no-start dev/corpus/harvest_enrichment.exs
#
# Standalone rather than through `bin/remote`, deliberately: this reads fields
# that were added to `Music.Track` recently, and a running server cannot reload
# a struct definition — see the warning in `CLAUDE.md`. A probe against a stale
# struct fails with `badkey` if you are lucky and measures the past if you are
# not.
#
# The gap this fills: all four existing corpora replay **TIDAL** candidates and
# measure the transfer ladder. Nothing measured enrichment, so every change to
# it was evaluated by re-running the live pipeline over a real library and
# counting — minutes of rate-limited requests, not repeatable, and it drove
# MusicBrainz to 503 twice in one afternoon.
#
# ## Where the labels come from
#
# The same trick `dev/measure/match_rate.exs` uses, in the other direction.
#
# A recording identified by **ISRC** is identified by an exact identifier: the
# code is in the source's own tags and MusicBrainz answers with the recording
# that carries it. Nobody scored anything, so that MBID is ground truth. Those
# recordings then make a labelled corpus for the *text* path: given the
# candidates a title-and-artist search returns, does scoring reach the same
# recording the identifier already proved?
#
# That is the question enrichment cannot answer about itself, because the text
# path only runs when there is no ISRC — precisely when there is no label.
#
# Recordings that are still **unidentified** are captured too, unlabelled. They
# cannot say whether a change is correct, only whether it unlocks anything, and
# the replay reports them separately for exactly that reason.
#
# ## What is captured
#
# For each recording: its own fields, and the candidate lists from both searches
# `by_name/1` makes — the release-qualified one and the broad one. Everything
# scoring reads, and nothing it does not, so a replay is a pure function of this
# file plus the engine.

import Ecto.Query

alias OnePlaylist.Library.Recording
alias OnePlaylist.MusicBrainz.Client
alias OnePlaylist.Matching.Normalize
alias OnePlaylist.Repo

# The dev server holds port 4000, so the application cannot be started here.
# Start exactly what a search needs.
for app <- [:telemetry, :postgrex, :ecto_sql, :req, :fuse, :external_service] do
  {:ok, _started} = Application.ensure_all_started(app)
end

{:ok, _repo} = Repo.start_link(pool_size: 2)
{:ok, _service} = OnePlaylist.MusicBrainz.Service.start_link([])

# Enough of each to be worth the wall-clock, and small enough to re-harvest
# without ceremony. The labelled half is sampled; the unidentified half is taken
# whole, since there are only ever a few dozen and each one is a question
# somebody actually asked.
labelled_limit = 120

track_to_map = fn track ->
  %{
    "provider_id" => track.provider_id,
    "title" => track.title,
    "artists" => track.artists,
    "album" => track.album,
    "album_titles" => track.album_titles,
    "title_variants" => track.title_variants,
    "live_release?" => track.live_release?,
    "duration_seconds" => track.duration_seconds,
    "isrc" => track.isrc,
    "album_upc" => track.album_upc,
    "version" => track.version
  }
end

search = fn recording, opts ->
  title = Normalize.title(recording.title).title
  credit = List.first(recording.artists || [])

  case Client.search_recordings(title, credit, opts) do
    {:ok, candidates} -> Enum.map(candidates, track_to_map)
    {:error, _reason} -> nil
    :error -> nil
  end
end

capture = fn recording, label ->
  broad = search.(recording, limit: 10)

  qualified =
    if is_binary(recording.album) and recording.album != "" do
      search.(recording, album: recording.album, limit: 10)
    end

  %{
    "title" => recording.title,
    "artists" => recording.artists,
    "album" => recording.album,
    "isrc" => recording.isrc,
    "duration_seconds" => recording.duration_seconds,
    "version" => recording.version,
    # The MBID an *identifier* proved, or nil for the unlabelled half.
    "expected_mbid" => label,
    "qualified_candidates" => qualified,
    "broad_candidates" => broad
  }
end

# Identified, carrying an ISRC, and identified *because* of it — `enrichment_outcome`
# does not record which path won, so the ISRC's presence is the proxy. A
# recording with an ISRC that MusicBrainz indexes is one the identifier path
# resolved; the text path is not consulted when that succeeds.
labelled =
  Recording
  |> where([r], not is_nil(r.musicbrainz_recording_id) and not is_nil(r.isrc))
  |> order_by([r], asc: r.id)
  |> limit(^labelled_limit)
  |> Repo.all()

unidentified =
  Recording
  |> where([r], is_nil(r.musicbrainz_recording_id))
  |> order_by([r], asc: r.id)
  |> Repo.all()

IO.puts("harvesting #{length(labelled)} labelled + #{length(unidentified)} unidentified…")

cases =
  Enum.map(labelled, &capture.(&1, &1.musicbrainz_recording_id)) ++
    Enum.map(unidentified, &capture.(&1, nil))

File.write!(
  "dev/corpus/enrichment_cases.json",
  Jason.encode!(cases, pretty: true)
)

%{
  written: "dev/corpus/enrichment_cases.json",
  labelled: Enum.count(cases, fn c -> c["expected_mbid"] end),
  unlabelled: Enum.count(cases, fn c -> is_nil(c["expected_mbid"]) end),
  searches_that_failed: Enum.count(cases, fn c -> is_nil(c["broad_candidates"]) end)
}
|> IO.inspect()
