defmodule OnePlaylist.Repo.Migrations.AddReplaceMode do
  use Ecto.Migration

  @moduledoc """
  Replace mode: a sync that mirrors its source rather than only adding to it.

  The second half of scheduled sync, and the half that deletes. Soundiiz and
  TuneMyMusic both draw the same line — *Add* keeps everything the destination
  has ever held, *Replace* makes it a mirror — and a user who reorganises a
  source playlist by removing things gets no benefit from the first.

  ## The mode is on the transfer, not only on the sync

  `syncs.mode` is the standing instruction. `transfers.mode` is what a
  particular run was told to do, and it is a separate column for three reasons:

    * `OnePlaylist.Transfers.Runner` is handed a transfer and nothing else, so
      the alternative is a lookup through `sync_id` on every run;
    * a transfer is the durable record of what happened, and "this run was
      allowed to delete" is part of that record — reading it back off the sync
      would report today's setting, not the one in force at the time;
    * it makes replace testable, and later offerable, without a schedule.

  Both default to `add`. A column that decides whether music gets deleted
  defaults to the answer that deletes nothing.

  ## What was removed is kept on the transfer, not in a table

  `removed_count` is exact. `removed_tracks` is a capped JSON list of what they
  were — id, title, artist — so the report can name them rather than only count
  them, which for a destructive operation is the difference between a record and
  a rumour.

  A table was the other option and earns nothing here: this list is read by one
  page, the transfer's own, and never queried across transfers. It is the same
  shape and the same reasoning as `transfer_items.candidates`.

  Deliberately **not** `transfer_items` rows. Those are indexed by the position
  of a *source* track and are covered by `run/1`'s contract that every source
  track gets exactly one — a removed track has no source position, and giving it
  one would break a law that is doing real work.
  """

  def up do
    execute "create type public.transfer_mode as enum ('add', 'replace')",
            "drop type public.transfer_mode"

    alter table(:syncs) do
      add :mode, :transfer_mode, null: false, default: "add"
    end

    alter table(:transfers) do
      add :mode, :transfer_mode, null: false, default: "add"
      add :removed_count, :integer, null: false, default: 0
      add :removed_tracks, :jsonb, null: false, default: "[]"
    end
  end

  def down do
    alter table(:transfers) do
      remove :removed_tracks
      remove :removed_count
      remove :mode
    end

    alter table(:syncs) do
      remove :mode
    end

    execute "drop type public.transfer_mode"
  end
end
