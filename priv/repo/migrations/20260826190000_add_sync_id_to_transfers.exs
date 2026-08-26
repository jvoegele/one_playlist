defmodule OnePlaylist.Repo.Migrations.AddSyncIdToTransfers do
  use Ecto.Migration

  @moduledoc """
  Which standing instruction produced a transfer, if any.

  ## Why the transfer points at the sync rather than the sync at the transfer

  `syncs.last_transfer_id` already exists and answers a different question — *the
  most recent run*, so the UI can link to a report without a join. This answers
  *every* run, which is the sync's history, and it has to live here because there
  are many transfers per sync.

  It also carries a second job. `OnePlaylist.Transfers.Runner` creates the
  destination playlist on the first run and must tell the sync what it made, or
  every later run makes another one. The runner is handed a transfer and nothing
  else, so without this column there is no route back.

  ## `nilify_all` rather than cascade

  Deleting a sync deletes the instruction, not the record of what it did. Those
  transfers happened, their reports are real, and a user deleting a schedule is
  not saying otherwise — `OnePlaylist.Syncs.delete/2` documents the same choice.

  ## Partial index

  Almost every transfer has no sync, and the only query is "this sync's runs".
  """

  def up do
    alter table(:transfers) do
      add :sync_id, references(:syncs, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:transfers, [:sync_id], where: "sync_id is not null")
  end

  def down do
    drop index(:transfers, [:sync_id], where: "sync_id is not null")

    alter table(:transfers) do
      remove :sync_id
    end
  end
end
