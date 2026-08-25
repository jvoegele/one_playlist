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
# Everything the ladder reads, so a replay is a pure function of this file plus
# the engine:
#
#   * the source's own fields;
#   * the candidate lists from both searches `by_name/1` makes, the
#     release-qualified one and the broad one;
#   * the **release search** and the releases it named, with their track lists —
#     what `by_release_tracks/2` consults. Without these the newest and most
#     intricate rung had four unit tests and a live count, and no replayable
#     score at all.
#
# Release data is captured for **every** case rather than only for the ones that
# reach that rung today. Capturing what the current engine happens to need would
# bake today's decisions into the corpus, and the point of a corpus is to
# outlive them.
#
# ## Two sources
#
# The library, which is one person's collection and skewed to a few artists; and
# `dev/playlists/*.csv`, Roon exports carrying 353 distinct artists. The second
# is there for diversity — an engine tuned on one library learns that library.
#
# A CSV row has no MBID, so its label comes from the same place: an ISRC
# MusicBrainz indexes resolves to a recording exactly, and that answer is ground
# truth for the text path.

import Ecto.Query

alias OnePlaylist.Library.Recording
alias OnePlaylist.MusicBrainz.Client
alias OnePlaylist.Matching.Normalize
alias OnePlaylist.Repo

# The dev server holds port 4000, so the application cannot be started here.
# Start exactly what a search needs.
for app <- [:telemetry, :postgrex, :ecto_sql, :req, :fuse, :external_service, :nebulex] do
  {:ok, _started} = Application.ensure_all_started(app)
end

{:ok, _repo} = Repo.start_link(pool_size: 2)
{:ok, _cache} = OnePlaylist.Cache.start_link([])
{:ok, _flight} = OnePlaylist.Cache.Singleflight.start_link([])
{:ok, _service} = OnePlaylist.MusicBrainz.Service.start_link([])

# Enough of each to be worth the wall-clock, and small enough to re-harvest
# without ceremony. The labelled half is sampled; the unidentified half is taken
# whole, since there are only ever a few dozen and each one is a question
# somebody actually asked.
labelled_limit = 120

# Diversity rather than volume: 353 distinct artists sit in those exports, and an
# engine measured only against one person's library learns that library. Capped
# because every case is up to seven rate-limited requests, most of which the
# release cache absorbs on the second track from an album.
playlist_sample = 120

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

release_documents = fn source ->
  album = source.album
  credit = List.first(source.artists || [])

  with true <- is_binary(album) and album != "",
       {:ok, releases} <- Client.search_releases(album, credit, limit: 3) do
    ids = releases |> Enum.map(& &1["id"]) |> Enum.reject(&is_nil/1) |> Enum.take(3)

    documents =
      Map.new(ids, fn id ->
        # Through `MusicBrainz.release/2` rather than the client, so a release
        # already fetched for an earlier track on the same album costs nothing.
        # A playlist is mostly albums, so this matters more than it looks.
        case OnePlaylist.MusicBrainz.release(id) do
          nil ->
            {id, nil}

          release ->
            {id,
             %{
               "title" => release.title,
               "secondary_types" => release.secondary_types,
               "tracks" => release.tracks
             }}
        end
      end)

    %{
      "release_search" => Enum.map(releases, &%{"id" => &1["id"], "title" => &1["title"]}),
      "releases" => documents
    }
  else
    _nothing -> %{"release_search" => [], "releases" => %{}}
  end
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

  Map.merge(
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
    },
    release_documents.(recording)
  )
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

# The Roon exports, sampled deterministically across every file so no single
# playlist dominates. Their label is an ISRC lookup, which is the same oracle the
# library half uses — an exact identifier nobody scored.
from_playlists =
  "dev/playlists/*.csv"
  |> Path.wildcard()
  |> Enum.flat_map(fn path ->
    case path |> File.read!() |> OnePlaylist.Formats.Csv.parse() do
      {:ok, tracks} -> tracks
      _unreadable -> []
    end
  end)
  |> Enum.filter(&is_binary(&1.isrc))
  |> Enum.uniq_by(& &1.isrc)
  # Every nth, rather than the first n, so the sample spans the files instead of
  # being the top of the first one.
  |> then(fn tracks ->
    step = max(div(length(tracks), playlist_sample), 1)
    tracks |> Enum.take_every(step) |> Enum.take(playlist_sample)
  end)

IO.puts(
  "harvesting #{length(labelled)} labelled + #{length(unidentified)} unidentified " <>
    "+ #{length(from_playlists)} from playlists…"
)

total = length(labelled) + length(unidentified) + length(from_playlists)

# Progress, because without it this is a black box for the best part of an hour
# and the only way to guess how far along it is, is to watch rows appear in
# `musicbrainz_releases` — which counts cache misses rather than cases.
progress = fn index ->
  if rem(index, 10) == 0 do
    IO.puts(:stderr, "  #{index}/#{total} cases…")
  end
end

cases =
  (labelled ++ unidentified ++ from_playlists)
  |> Enum.with_index(1)
  |> Enum.map(fn {source, index} ->
    progress.(index)

    label =
      case source do
        %Recording{musicbrainz_recording_id: mbid} -> mbid
        %OnePlaylist.Music.Track{isrc: isrc} -> OnePlaylist.MusicBrainz.recording_mbid(isrc)
      end

    capture.(source, label)
  end)

File.write!(
  "dev/corpus/enrichment_cases.json",
  Jason.encode!(cases, pretty: true)
)

%{
  written: "dev/corpus/enrichment_cases.json",
  labelled: Enum.count(cases, fn c -> c["expected_mbid"] end),
  unlabelled: Enum.count(cases, fn c -> is_nil(c["expected_mbid"]) end),
  with_release_data: Enum.count(cases, fn c -> map_size(c["releases"] || %{}) > 0 end),
  searches_that_failed: Enum.count(cases, fn c -> is_nil(c["broad_candidates"]) end)
}
|> IO.inspect()
