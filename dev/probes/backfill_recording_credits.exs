# Fills `musicbrainz_artists` for recordings identified before the column
# existed, and measures how far the catalogue disagrees with our sources.
#
#     mix run --no-start dev/probes/backfill_recording_credits.exs
#
# Standalone rather than through `bin/remote`, because it reads a field the
# `Recording` struct has only just gained and a running server cannot reload a
# struct definition — see the warning in `CLAUDE.md`.
#
# ## Why a backfill is needed at all
#
# `Enrichment.learned/3` now keeps the artist credit off the recording lookup it
# was already making, so every recording identified from here on gets one for
# free. The 646 already identified do not: `due/1` re-offers a *failure* when the
# engine fingerprint changes, and these did not fail. They would be re-asked
# after `@stale_after_days`, which is thirty days away and not worth waiting for.
#
# ## What it will not do
#
# Writes `musicbrainz_artists` and nothing else — not `artists`, which is what
# the source said and is never overwritten, and not the enrichment attempt,
# because this is not an attempt. It is one field being filled from an answer
# MusicBrainz already gave.
#
# ## The number worth reading
#
# Not how many were filled — that is just the row count — but how many
# **disagree** with the credit their source supplied. That is the real size of
# the Roon album-artist problem, which until now has been argued from a single
# example.

import Ecto.Query

alias OnePlaylist.Library.Recording
alias OnePlaylist.Matching.Normalize
alias OnePlaylist.MusicBrainz
alias OnePlaylist.MusicBrainz.Client
alias OnePlaylist.Repo

for app <- [:telemetry, :postgrex, :ecto_sql, :req, :fuse, :external_service, :nebulex] do
  {:ok, _started} = Application.ensure_all_started(app)
end

{:ok, _repo} = Repo.start_link(pool_size: 2)
{:ok, _cache} = OnePlaylist.Cache.start_link([])
{:ok, _flight} = OnePlaylist.Cache.Singleflight.start_link([])
{:ok, _service} = OnePlaylist.MusicBrainz.Service.start_link([])

# Assert the new field is really loaded before spending eleven minutes on it.
# A probe against a stale struct measures the past and says nothing about it.
%Recording{} = struct(Recording, musicbrainz_artists: ["probe"])

pending =
  Recording
  |> where([r], not is_nil(r.musicbrainz_recording_id) and is_nil(r.musicbrainz_artists))
  |> order_by([r], asc: r.id)
  |> Repo.all()

IO.puts("#{length(pending)} identified recordings without a catalogue credit\n")

credit = fn artists -> artists |> List.wrap() |> Enum.map_join(" ", &Normalize.text/1) end

results =
  pending
  |> Enum.with_index(1)
  |> Enum.map(fn {recording, index} ->
    if rem(index, 25) == 0, do: IO.puts(:stderr, "  #{index}/#{length(pending)}…")

    # Through `MusicBrainz.recording/2`, so the answers this spends a request on
    # are *kept*. The first run of this probe predated that cache and threw 646
    # lookups away; a second run now costs nothing.
    case MusicBrainz.recording(recording.musicbrainz_recording_id) do
      {:ok, %{} = details} ->
        theirs = Client.artist_credit(details)

        {:ok, _updated} =
          recording
          |> Ecto.Changeset.change(musicbrainz_artists: theirs)
          |> Repo.update()

        cond do
          theirs == [] -> :no_credit
          credit.(theirs) == credit.(recording.artists) -> :agrees
          true -> {:differs, recording, theirs}
        end

      _unavailable ->
        :unavailable
    end
  end)

differs = for {:differs, r, theirs} <- results, do: {r, theirs}

IO.puts("\ndisagreements — where the catalogue credits it to somebody else\n")

differs
|> Enum.sort_by(fn {r, _t} -> {r.album || "", r.title || ""} end)
|> Enum.take(40)
|> Enum.each(fn {r, theirs} ->
  IO.puts("  #{r.title}  [#{r.album}]")
  IO.puts("    source:     #{Enum.join(r.artists, ", ")}")
  IO.puts("    catalogue:  #{Enum.join(theirs, ", ")}")
end)

%{
  asked: length(pending),
  agrees: Enum.count(results, &(&1 == :agrees)),
  differs: length(differs),
  no_credit: Enum.count(results, &(&1 == :no_credit)),
  unavailable: Enum.count(results, &(&1 == :unavailable))
}
