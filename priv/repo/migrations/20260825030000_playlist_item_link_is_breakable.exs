defmodule OnePlaylist.Repo.Migrations.PlaylistItemLinkIsBreakable do
  use Ecto.Migration

  @moduledoc """
  A playlist item may say it is not sure what recording it is.

  Phase 1 gave an item its own account of the track. This makes the *link* to a
  recording the user's to break, which is the half that changes behaviour.

  Until now `recording_id` was `NOT NULL`, so a wrong link could only be
  replaced, never removed — and there was no way to replace it either. A person
  looking at a track matched to the wrong recording had no move available except
  deleting the track and re-adding it, which loses its place in the playlist.

  ## Why `NULL` rather than a self-link or a tombstone

  The alternatives are worse in the same way. A recording that means "unknown"
  is a row every query has to remember to exclude, and a boolean beside a
  still-populated `recording_id` is two facts that can disagree. `NULL` is the
  database's own word for "no answer here", and it makes every reader that
  forgets fail loudly rather than quietly showing a stale link.

  Reads become `LEFT JOIN` — see `OnePlaylist.Library.entries/2` — and
  `PlaylistItem.to_track/2` already accepted a `nil` recording, because phase 1
  built it that way for exactly this step.

  The foreign key stays `ON DELETE RESTRICT`. Nothing in the application deletes
  a recording, and an unlinked item is a deliberate act rather than a
  consequence of one.
  """

  def change do
    alter table(:library_playlist_items) do
      modify :recording_id, :binary_id, null: true, from: {:binary_id, null: false}
    end

    # "Which of my items has nobody decided about?" — the question the screen
    # asks to show its unlinked rows, and the sweep would ask to re-link them.
    create index(:library_playlist_items, [:playlist_id],
             where: "recording_id is null",
             name: :library_playlist_items_unlinked_index
           )
  end
end
