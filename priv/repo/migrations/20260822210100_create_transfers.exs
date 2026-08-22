defmodule OnePlaylist.Repo.Migrations.CreateTransfers do
  use Ecto.Migration

  @moduledoc """
  A transfer, and a row per track explaining what happened to it.

  `transfer_items` is the feature `docs/reference/domain.md` argues is worth
  more than another platform integration: a per-track report with the reason,
  resolvable by hand. It is also what makes "never silently drop a track" a
  property of the database rather than an intention — a source track with no
  row is a bug the schema can be asked about.
  """

  def up do
    create table(:transfers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, on_delete: :delete_all, type: :uuid, prefix: "auth"),
        null: false

      add :source_provider, :text, null: false
      add :source_playlist_id, :text, null: false
      add :source_playlist_name, :text

      add :destination_provider, :text, null: false
      # Filled in once the destination playlist exists. Nullable because a
      # transfer is created before it has one, and **load-bearing on retry**:
      # a resumed transfer that found this set must not create a second
      # playlist. See OnePlaylist.Transfers.Runner.
      add :destination_playlist_id, :text
      add :destination_playlist_name, :text

      add :status, :text, null: false, default: "pending"
      add :threshold, :float, null: false

      # The ledger. `matched + unmatched == total` is asserted as a contract on
      # the struct, not merely hoped for, and `added <= matched` because a
      # matched track may already have been present at the destination.
      add :total_tracks, :integer, null: false, default: 0
      add :matched_count, :integer, null: false, default: 0
      add :added_count, :integer, null: false, default: 0
      add :unmatched_count, :integer, null: false, default: 0

      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:transfers, [:user_id, :inserted_at])

    execute """
            alter table public.transfers
              add constraint transfers_status_check
              check (status in ('pending','running','completed','failed'))
            """,
            "alter table public.transfers drop constraint transfers_status_check"

    execute """
            alter table public.transfers
              add constraint transfers_counts_non_negative
              check (total_tracks >= 0 and matched_count >= 0 and added_count >= 0 and unmatched_count >= 0)
            """,
            "alter table public.transfers drop constraint transfers_counts_non_negative"

    create table(:transfer_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :transfer_id, references(:transfers, on_delete: :delete_all, type: :binary_id),
        null: false

      # Denormalized from the parent transfer so an RLS policy can compare
      # against auth.uid() directly. The alternative is an EXISTS subquery
      # evaluated per row, which is the pattern Supabase's own RLS performance
      # guidance says to avoid on a table that will hold thousands of rows per
      # transfer.
      add :user_id, references(:users, on_delete: :delete_all, type: :uuid, prefix: "auth"),
        null: false

      add :position, :integer, null: false

      add :source_track_id, :text, null: false
      add :source_title, :text
      add :source_artist, :text

      add :outcome, :text, null: false
      add :destination_track_id, :text
      add :confidence, :text
      add :score, :float
      add :strategy, :text
      # Why it did not match, for the rows where that is the interesting part.
      add :reason, :text
      add :candidates_considered, :integer

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Position is the source playlist's own ordering, so this is both the report's
    # sort key and what makes re-running a transfer idempotent at the row level:
    # the second run upserts the same rows rather than appending a second copy of
    # the report.
    create unique_index(:transfer_items, [:transfer_id, :position])

    create index(:transfer_items, [:transfer_id, :outcome])

    execute """
            alter table public.transfer_items
              add constraint transfer_items_outcome_check
              check (outcome in ('matched','unmatched','already_present'))
            """,
            "alter table public.transfer_items drop constraint transfer_items_outcome_check"

    # --- Authorization -------------------------------------------------------
    #
    # Both tables are user-owned, so this is the `auth.uid()` shape from
    # `create_provider_connections` rather than the ownerless shape from
    # `create_catalogue_release_lookups`. See CLAUDE.md.
    for table <- ~w(transfers transfer_items) do
      execute "alter table public.#{table} enable row level security",
              "alter table public.#{table} disable row level security"

      execute "revoke all on table public.#{table} from anon, authenticated",
              "grant all on table public.#{table} to anon, authenticated"

      # A transfer report is worth reading in the browser, so `authenticated`
      # gets `select` here where the connections table grants it grudgingly.
      # Writes stay server-side: the pipeline owns the counters, and a client
      # able to edit them could make a report say anything.
      execute "grant select on table public.#{table} to authenticated",
              "revoke select on table public.#{table} from authenticated"

      execute """
              create policy "own #{table} select" on public.#{table}
                for select to authenticated using ((select auth.uid()) = user_id)
              """,
              ~s|drop policy "own #{table} select" on public.#{table}|
    end
  end

  def down do
    drop table(:transfer_items)
    drop table(:transfers)
  end
end
