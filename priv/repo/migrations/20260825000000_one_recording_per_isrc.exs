defmodule OnePlaylist.Repo.Migrations.OneRecordingPerIsrc do
  use Ecto.Migration

  @moduledoc """
  One recording per ISRC, enforced rather than intended.

  `OnePlaylist.Library.find_or_create/1` reads and then inserts, which is
  correct in isolation and a race in company: two callers that miss at the same
  moment both insert, and the shared store gains two rows for one recording.
  Nothing after that can tell them apart, and merging them is destructive where
  the duplication was not.

  Observed rather than theorised. Two runs of one transfer overlapped and
  produced exactly two of every recording, inserted sub-millisecond apart —
  identical in every column including the ISRC each had just failed to find.

  The store is **ownerless and shared**, so this is not an exotic scenario. Two
  users transferring the same track at the same moment race on the same row, and
  they do not have to know about each other to do it.

  A partial index because a recording without an ISRC cannot be found this way
  either and would only make the index bigger — the same reasoning the lookup
  index in `create_library` gives.

  Nothing enforces the *other* dedup key, the title-album-credit triple. It has
  no single column to constrain and would need a generated one; the race there
  costs a duplicate row rather than a wrong answer, and duplicates are the
  direction this store is deliberately willing to fail in.
  """

  def up do
    # Any left by a race before the constraint existed. Membership is repointed
    # rather than deleted: a playlist naming the loser must keep its entry.
    execute """
    with ranked as (
      select id, isrc, row_number() over (partition by isrc order by inserted_at, id) as rn
      from public.library_recordings
      where isrc is not null
    ),
    keepers as (select isrc, id from ranked where rn = 1)
    update public.library_playlist_items i
    set recording_id = k.id
    from ranked r join keepers k on k.isrc = r.isrc
    where i.recording_id = r.id and r.rn > 1
    """

    execute """
    delete from public.library_recordings where id in (
      select id from (
        select id, row_number() over (partition by isrc order by inserted_at, id) as rn
        from public.library_recordings where isrc is not null
      ) ranked where rn > 1
    )
    """

    create unique_index(:library_recordings, [:isrc],
             where: "isrc is not null",
             name: :library_recordings_one_per_isrc
           )
  end

  def down do
    drop index(:library_recordings, [:isrc], name: :library_recordings_one_per_isrc)
  end
end
