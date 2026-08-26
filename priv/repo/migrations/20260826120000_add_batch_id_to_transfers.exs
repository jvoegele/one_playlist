defmodule OnePlaylist.Repo.Migrations.AddBatchIdToTransfers do
  use Ecto.Migration

  @moduledoc """
  Which transfers were asked for together.

  Somebody moving from one service to another has forty playlists, and the
  application asked them to do it forty times. Selecting several at once creates
  **one transfer per playlist**, and this is what says they went together.

  ## One transfer each, rather than one transfer with several sources

  The destination is per-playlist: each source playlist becomes its own playlist
  at the destination. A single transfer holding several sources would need
  several `destination_playlist_id`s, which the table has no shape for — and
  every law already stated about a transfer would have to be reworked, because
  `total_tracks` and the counters would become sums across playlists and the
  per-track report is keyed on `(transfer_id, position)`, which collides the
  moment two playlists both have a track at position 0.

  Keeping them separate also isolates failure, which is the behaviour worth
  having: forty playlists where one hits a rate limit should land
  thirty-nine, not none.

  ## A column rather than a table

  A batch has no state of its own. Its source, its destination, when it was
  asked for and how far along it is are all derivable from its members, so a
  `transfer_batches` table would store only what it can already compute. If
  batch-level state is ever needed — a name, a cancel flag — that is a later
  migration and this column becomes its foreign key.

  Nullable, because every transfer made before this and every single-playlist
  transfer after it belongs to no batch. `nil` means "on its own", which is the
  honest reading rather than a special batch of one.
  """

  def change do
    alter table(:transfers) do
      add :batch_id, :uuid
    end

    # "Show me this batch", which is the only query the column exists for.
    # Partial, because a transfer with no batch can never answer it and most
    # rows will have none.
    create index(:transfers, [:batch_id], where: "batch_id is not null")
  end
end
