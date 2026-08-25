defmodule OnePlaylist.Repo.Migrations.PlaylistItemsOwnTheirMetadata do
  use Ecto.Migration

  @moduledoc """
  A playlist item stops being a pointer and becomes a track.

  Until now an item was `(playlist, user, recording, position)` — it owned
  nothing but its place in a list, and every word shown for it came from the
  shared, ownerless recording. That made three separate things impossible or
  destructive.

  ## What it fixes, and none of it is about editing

  **A wrong match destroyed data.** `find_or_create/1` decides at import whether
  two arrivals are one recording, and that decision *was* the playlist. Two
  *Hard to Imagine* rows — one from *Lost Dogs*, one from the *Chicago Cab*
  soundtrack, two different studio sessions — collapsed into one row and one
  vanished from the playlist entirely. With the item holding its own metadata,
  both exist whatever the matcher concludes, and a wrong link is only a wrong
  link.

  **A conflict had nowhere to live.** An imported item said "Blood, on *Vs.*";
  its ISRC resolved, correctly, to *Pry, To* on *Vitalogy*. Those are two claims
  about one row and one of them had to lose. Apart, the item keeps saying what
  the source said and the *link* is the thing that is wrong — which is the thing
  a person wants to break by hand.

  **Editing needed a provenance model.** Distinguishing "the user set this" from
  "TIDAL set this" was going to be a column per field. It is two tables instead:
  the item is what a source said and a person may correct, the recording is what
  a catalogue knows.

  The deepest change is that **matching becomes an annotation rather than a
  destructive decision.**

  ## A full copy, not an overlay

  The obvious economy is to store only the fields a user has overridden and fall
  back to the recording. It fails on the case this exists for: an item unlinked
  from its recording would have nothing left to show. An item has to stand
  alone, so it carries the whole of what its source said.

  `OnePlaylist.Transfers.TransferItem` already works this way — `source_title`,
  `source_artist` and `source_album` beside the destination's — for the same
  reason, that a report must show what was asked for even when the answer is
  wrong or missing. A playlist item is that object with a longer life.

  ## What stays on the recording

  Everything a catalogue knows and a source does not: the MusicBrainz identity,
  the chosen release, cover art, the barcode. Those are facts about the music
  rather than about anybody's playlist, and they remain shared.

  `recording_id` stays `NOT NULL` here. Making the link breakable is the next
  step and is a change to behaviour; this one moves where the truth is kept and
  should be invisible.
  """

  def up do
    alter table(:library_playlist_items) do
      # What the source said, and what its owner may correct.
      add :title, :text
      add :artists, {:array, :text}, null: false, default: []
      add :album, :text
      add :version, :text
      add :duration_seconds, :integer
      add :isrc, :text

      # Editing arrives in a later step, and a row that can change wants to say
      # when it last did.
      add :updated_at, :utc_datetime_usec
    end

    # Every existing item takes its recording's metadata, which is exactly what
    # it was already displaying.
    execute """
            update public.library_playlist_items i
            set title = r.title,
                artists = r.artists,
                album = r.album,
                version = r.version,
                duration_seconds = r.duration_seconds,
                isrc = r.isrc,
                updated_at = i.inserted_at
            from public.library_recordings r
            where r.id = i.recording_id
            """,
            ""

    # After the backfill, because an item that names nothing is not a track.
    # Deliberately the only new constraint: the rest are a source's to leave
    # blank.
    execute "alter table public.library_playlist_items alter column title set not null",
            "alter table public.library_playlist_items alter column title drop not null"

    execute "alter table public.library_playlist_items alter column updated_at set not null",
            "alter table public.library_playlist_items alter column updated_at drop not null"

    # The lookup behind "which of my items are this recording?", which unlinking
    # and re-linking will both need, and which nothing indexed before.
    create index(:library_playlist_items, [:recording_id])
  end

  def down do
    drop index(:library_playlist_items, [:recording_id])

    alter table(:library_playlist_items) do
      remove :title
      remove :artists
      remove :album
      remove :version
      remove :duration_seconds
      remove :isrc
      remove :updated_at
    end
  end
end
