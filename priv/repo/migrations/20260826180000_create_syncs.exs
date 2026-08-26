defmodule OnePlaylist.Repo.Migrations.CreateSyncs do
  use Ecto.Migration

  @moduledoc """
  A standing instruction to keep one playlist mirrored into another.

  The retention feature both incumbents charge for, and the reason `wait_for_it`
  and Oban Cron are already in the stack. A transfer is a thing that happened
  once; a sync is a thing that keeps happening.

  ## A sync owns a destination, where a transfer creates one

  `transfers.destination_playlist_id` is filled in by the first run and reused by
  a retry, which is what makes a transfer resumable. A sync needs the same
  column for a different reason: every run after the first must write into the
  playlist the first run made, or a weekly sync leaves fifty-two copies behind.

  So `destination_playlist_id` starts `null` and is filled by the first
  successful run. Nothing else may set it — see `OnePlaylist.Syncs`.

  ## Cadence is minutes, and the column says so

  `interval_minutes` rather than a cadence enum. A `:daily` that has to become
  `:twice_daily` is a migration and a case statement; a number is neither, and
  the UI can still offer three choices. The floor is enforced in the changeset
  rather than by a constraint, because "no more often than hourly" is a policy
  about provider quota rather than a fact about the data.

  ## `next_run_at` is the queue

  Due-ness is a column rather than a computation over `last_run_at` and the
  interval, so the sweeper's query is an index scan on one condition. It also
  makes "run it now" expressible without lying about when it last ran: set
  `next_run_at` to the past and the sweeper picks it up on its next pass.

  Nullable, and `null` means **never scheduled** rather than *due now* — a sync
  created disabled has nothing pending, and a query looking for `<= now()` skips
  it without a special case.
  """

  def up do
    create table(:syncs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Referenced, like `transfers.user_id`, and for a sharper reason: a sync
      # is a *standing* instruction. An orphan transfer is a row nobody reads;
      # an orphan sync fires every fifteen minutes forever, against credentials
      # that went with the user.
      add :user_id, references(:users, prefix: "auth", type: :uuid, on_delete: :delete_all),
        null: false

      add :source_provider, :string, null: false
      add :source_playlist_id, :string, null: false
      add :source_playlist_name, :string

      add :destination_provider, :string, null: false
      # Filled by the first successful run and never again. See the moduledoc.
      add :destination_playlist_id, :string
      add :destination_playlist_name, :string

      add :interval_minutes, :integer, null: false
      add :enabled, :boolean, null: false, default: true

      add :last_run_at, :utc_datetime_usec
      add :next_run_at, :utc_datetime_usec
      # The most recent run, so the UI can link to a report without a join.
      add :last_transfer_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create index(:syncs, [:user_id])

    # The sweeper's only query: enabled, and due. Partial on both, because a
    # disabled sync and one scheduled for next week are equally uninteresting to
    # it and most rows are one or the other at any moment.
    create index(:syncs, [:next_run_at], where: "enabled and next_run_at is not null")

    # One standing instruction per source/destination pair. Two syncs of the
    # same playlist into the same place would race each other into one
    # destination, and the second would find its own writes already there and
    # report them as `already_present` — a report that reads like a bug in the
    # matching engine.
    create unique_index(
             :syncs,
             [:user_id, :source_provider, :source_playlist_id, :destination_provider]
           )

    # --- Authorization -------------------------------------------------------
    #
    # User-owned, so the `auth.uid()` shape. `select` only: a sync decides what
    # the application does on a schedule with the user's credentials, and a
    # client able to write one could point it anywhere.
    execute "alter table public.syncs enable row level security",
            "alter table public.syncs disable row level security"

    execute "revoke all on table public.syncs from anon, authenticated",
            "grant all on table public.syncs to anon, authenticated"

    execute "grant select on table public.syncs to authenticated",
            "revoke select on table public.syncs from authenticated"

    execute """
            create policy "own syncs select" on public.syncs
              for select to authenticated using ((select auth.uid()) = user_id)
            """,
            ~s|drop policy "own syncs select" on public.syncs|
  end

  def down do
    drop table(:syncs)
  end
end
