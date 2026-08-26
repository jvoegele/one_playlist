defmodule OnePlaylist.Repo.Migrations.AddSourceIsrcToTransferItems do
  use Ecto.Migration

  @moduledoc """
  What the source track's ISRC was, kept on the report row.

  The report already records what the source *said* — title, credit, album,
  artwork — and stopped short of the one field that identifies the recording.
  Two things want it.

  **The report itself.** An unmatched row whose source carried a perfectly good
  ISRC is a different story from one that carried none: the first says the
  destination does not hold that code, which is the reissue case
  `Strategy.IsrcFamily` exists for; the second says there was never anything
  exact to match on. Today both read as "unmatched".

  **Bringing unmatched tracks into the library.** A recording built from a report
  row is deduplicated by `OnePlaylist.Library.find_or_create/1`, which joins on a
  canonical ISRC first and falls back to title, album and credit. Without the
  code the fallback is the only key available, so a track the library already
  holds arrives as a second copy — the exact failure that function is written
  against.

  Nullable, and most rows will stay that way: roughly 40% of a real self-hosted
  library carries no ISRC at all, and every row written before this has none.
  """

  def change do
    alter table(:transfer_items) do
      add :source_isrc, :string
    end
  end
end
