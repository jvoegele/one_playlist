defmodule OnePlaylist.Repo.Migrations.CreateTransferSources do
  @moduledoc """
  The tracks an uploaded playlist file parsed into, kept for the worker.

  ## Why the tracks are persisted at all

  A transfer runs in an Oban job, and `OnePlaylist.Storage` reaches Supabase as
  the signed-in user so that the bucket policies apply. A worker has no session
  to be: GoTrue refresh tokens live in the browser's cookie, not in this
  database, so a worker could only read the uploaded file with the service key —
  bypassing every storage policy at once.

  So the file is parsed in the request, where there *is* a session, and the
  result is stored here. The worker reads rows it already has access to and
  never touches Storage.

  That ordering is worth more than the privilege it avoids. Parsing at upload
  means a malformed file is reported while the person is still looking at the
  form — "row 47 has no title" — instead of failing a background job they have
  to go and find.

  ## Why a table rather than a column on `transfers`

  One row per transfer either way, so the shape is the same. The difference is
  that `OnePlaylist.Transfers.list/1` selects every column of `transfers`, and a
  ten-thousand-track playlist is a couple of megabytes of JSON. Putting it here
  means the listing never loads it, and no future `Repo.all(Transfer)` starts
  doing so by accident.
  """

  use Ecto.Migration

  def change do
    create table(:transfer_sources, primary_key: false) do
      # The transfer is the identity: one uploaded file, one transfer. `on_delete`
      # rather than a nullable column, because a source without its transfer is
      # not a thing this application has any use for.
      add :transfer_id, references(:transfers, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false

      # Denormalised from `transfers` so the RLS policy can be written without a
      # join. A policy that had to join would run per row and could not use the
      # `(select auth.uid())` form the other tables use.
      add :user_id, :binary_id, null: false

      # The parsed tracks, in file order. `:map` per element rather than a
      # relational table: the worker needs all of them at once and nothing
      # queries an individual source track, so rows would be machinery without a
      # question to answer.
      add :tracks, {:array, :map}, null: false

      # What the file was, for the report and for showing a person what they
      # uploaded. The storage path lives on `transfers.source_playlist_id`.
      add :format, :text, null: false
      add :track_count, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:transfer_sources, [:user_id])

    execute "alter table public.transfer_sources add constraint transfer_sources_count_matches " <>
              "check (track_count = cardinality(tracks))",
            "alter table public.transfer_sources drop constraint transfer_sources_count_matches"

    # The pattern every table in `public` follows here, and for the reason
    # `docs/reference/supabase.md` gives: a new table starts partially granted to
    # `anon` and `authenticated` rather than protected.
    execute "alter table public.transfer_sources enable row level security",
            "alter table public.transfer_sources disable row level security"

    execute "revoke all on table public.transfer_sources from anon, authenticated",
            "grant all on table public.transfer_sources to anon, authenticated"

    # `select` only, matching `transfers` and `transfer_items`: a person may read
    # what they uploaded, and the application writes it. Nothing a client could
    # edit here would be an improvement — these rows are what the matching engine
    # is handed.
    execute "grant select on table public.transfer_sources to authenticated",
            "revoke select on table public.transfer_sources from authenticated"

    execute """
            create policy "own transfer_sources select" on public.transfer_sources
              for select to authenticated using ((select auth.uid()) = user_id)
            """,
            ~s|drop policy "own transfer_sources select" on public.transfer_sources|
  end
end
