# Does every album agree with itself about which release it is?
#
#     bin/remote dev/measure/album_agreement.exs
#
# Reports each disagreeing album, what `Albums.choose/2` would settle it on, and
# how much of the album that release accounts for. **Writes nothing.**
#
# To actually resolve them, evaluate `OnePlaylist.Library.Albums.resolve_spanning()`
# in a probe of its own. There is no `--write` flag here because there cannot be
# one: `bin/remote` takes a path and the server evaluates the file, so a flag on
# the command line lands in the *caller's* argv and `System.argv/0` on the server
# reads whatever `mix phx.server` was started with. This script asked for one and
# silently reported `wrote: false`.
#
# The numbers this produced when `OnePlaylist.Library.Albums` was written, on a
# 654-recording library: eight albums disagreed, every one of them resolved to a
# single release covering **all** of its tracks, and seven of the eight winners
# carry a barcode. See that module's moduledoc for why a per-recording rule
# cannot reach the same answer.

alias OnePlaylist.Library.Albums
alias OnePlaylist.Library.Recording
alias OnePlaylist.MusicBrainz
alias OnePlaylist.Repo

import Ecto.Query

# `Phoenix.CodeReloader` does nothing when `mix compile` has already run in
# another shell, so the probe would measure whatever the server booted with.
# See the `bin/remote` warnings in CLAUDE.md.
for mod <- [Albums, MusicBrainz, OnePlaylist.MusicBrainz.Client, Recording] do
  :code.purge(mod)
  :code.load_file(mod)
end

# Fail loudly rather than measure the past.
true = function_exported?(Albums, :choose, 2)

report =
  for {album, artist} <- Albums.spanning() do
    recordings =
      Recording
      |> where([r], r.album == ^album and not is_nil(r.musicbrainz_recording_id))
      |> where([r], fragment("?[1]", r.artists) == ^artist)
      |> Repo.all()

    before =
      recordings |> Enum.map(& &1.musicbrainz_release_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    candidates = before |> Enum.map(&MusicBrainz.release/1) |> Enum.reject(&is_nil/1)
    release = Albums.choose(recordings, candidates)

    covered = release && Albums.coverage(release, recordings)

    %{
      album: String.slice(album, 0, 40),
      tracks: length(recordings),
      was: length(before),
      settles_on: release && String.slice(release.mbid, 0, 8),
      covers: "#{covered || 0}/#{length(recordings)}",
      barcode: (release && release.barcode) || "-"
    }
  end

%{
  albums: length(report),
  fully_covered: Enum.count(report, &(&1.covers == "#{&1.tracks}/#{&1.tracks}")),
  with_barcode: Enum.count(report, &(&1.barcode not in ["-", "", nil])),
  detail: report
}
