defmodule OnePlaylist.Repo.Migrations.AddMusicbrainzArtistsToRecordings do
  use Ecto.Migration

  @moduledoc """
  What the catalogue credits a recording to, beside what its source said.

  The Roon problem, named in `CLAUDE.md`'s backlog and in
  `docs/reference/domain.md` §3: Roon's CSV export writes the **album artist**
  into the track artist column, so every track on a compilation or tribute album
  arrives credited to its subject. *Crucible: The Songs of Hunters & Collectors*
  is twelve performers filed under "Hunters & Collectors", and *Throw Your Arms
  Around Me* — actually Eddie Vedder & Neil Finn — cannot be found from the
  credit it arrived with.

  ## Why a second column rather than a better value in the first

  `artists` is what a source said, and enrichment's rule is that gaps are filled
  and nothing is corrected. Rewriting it would be a correction, and the fact that
  §5 makes the *item* the owner of the displayed credit does not make it safe to
  discard the source's claim on the shared row — it only makes it invisible,
  which is worse.

  Two claims about one recording, kept apart, is also the shape
  `docs/reference/domain.md` §6 asks for. §6 argues the schema records *values*
  without recording *who said them*, and that the provenance model deferred by
  "a recording has many releases, and they disagree" is the answer. This is that
  model arriving one field at a time, for the field where the disagreement is
  known to be real and known to matter.

  Keeping both is also what lets a screen say *"MusicBrainz credits this to Eddie
  Vedder & Neil Finn"* and offer it, rather than silently swapping one answer for
  another behind somebody's back.

  ## It costs no requests

  `Client.recording/1` already sends `inc=artist-credits+…`, and
  `Enrichment.learned/3` already holds the whole response. The credit was being
  parsed away. So this fills for every recording enrichment identifies, on the
  request it was already making.

  An array of names rather than the credit phrase, because that is what `artists`
  is everywhere else and what `Signals` compares. The joinphrase — the " & " in
  "Eddie Vedder & Neil Finn" — is presentation, and nothing here compares on it.
  """

  def change do
    alter table(:library_recordings) do
      add :musicbrainz_artists, {:array, :text}
    end
  end
end
