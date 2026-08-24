# What a search fallback would attach, before it is built.
#
# `Enrichment.identify/1` asks MusicBrainz for the recording an ISRC names and
# stops there. When MusicBrainz does not index that ISRC — which is the case for
# 7 of the dev library's 10 unidentified recordings — it never falls back to
# searching by name, so a recording MusicBrainz demonstrably holds is reported
# as not found.
#
# Adding the fallback is obvious. What it would *attach* is not, and this
# project's rule is to measure a matching change rather than argue it. So this
# runs the fallback without writing anything and prints what each recording
# would have got.
#
# It also measures one candidate rule. When a recording carries an ISRC and
# MusicBrainz has no such code, a candidate carrying a *different* ISRC is
# positive evidence of being a different recording: MusicBrainz knows that
# recording's identifier, and it is not ours. Rejecting those is the cheapest
# corroboration available here, and the column says what it costs.
#
# Read-only. One or two requests per recording at one a second.
alias OnePlaylist.Library.Recording
alias OnePlaylist.Matching
alias OnePlaylist.MusicBrainz.Client
alias OnePlaylist.Repo

import Ecto.Query

Phoenix.CodeReloader.reload(OnePlaylistWeb.Endpoint)

chosen = fn recording, candidates ->
  case Matching.match(Recording.to_track(recording), candidates, threshold: :high) do
    {:ok, match} ->
      %{
        title: match.track.title,
        artists: match.track.artists,
        album: match.track.album,
        isrc: match.track.isrc,
        secs: match.track.duration_seconds,
        score: Float.round(match.score, 4),
        via: match.strategy
      }

    {:error, _declined} ->
      nil
  end
end

try do
  unidentified =
    Recording
    |> where([r], is_nil(r.musicbrainz_recording_id) and not is_nil(r.enriched_at))
    |> order_by(asc: :title)
    |> Repo.all()

  results =
    Enum.map(unidentified, fn recording ->
      case Client.search_recordings(recording.title, List.first(recording.artists || []), limit: 10) do
        {:ok, candidates} ->
          # The rule under test: a candidate whose ISRC is known and differs from
          # ours is a different recording.
          corroborated =
            if recording.isrc do
              Enum.reject(candidates, &(&1.isrc && &1.isrc != recording.isrc))
            else
              candidates
            end

          %{
            stored: %{
              title: recording.title,
              artists: recording.artists,
              album: recording.album,
              isrc: recording.isrc,
              secs: recording.duration_seconds
            },
            candidates: length(candidates),
            as_is: chosen.(recording, candidates),
            with_isrc_rule: chosen.(recording, corroborated)
          }

        {:error, reason} ->
          %{stored: %{title: recording.title}, error: inspect(reason)}
      end
    end)

  found = fn key -> Enum.count(results, &(&1[key] != nil)) end

  %{
    recordings: length(results),
    would_identify_as_is: found.(:as_is),
    would_identify_with_isrc_rule: found.(:with_isrc_rule),
    detail: results
  }
rescue
  e -> %{error: e.__struct__, message: Exception.message(e)}
end
