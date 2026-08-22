defmodule OnePlaylist.Repo.Migrations.CreateProviderConnections do
  use Ecto.Migration

  @moduledoc """
  A user's authorization to act on their behalf at one music service.

  Tokens are stored as `:binary` because they are encrypted by
  `OnePlaylist.Vault` before they reach Postgres — the database never sees
  plaintext and cannot decrypt them.
  """

  def up do
    create table(:provider_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # References auth.users rather than a table of our own: Supabase Auth owns
      # the user record, and this FK is what lets RLS policies compare against
      # auth.uid(). `on_delete: :delete_all` so deleting a user takes their
      # provider authorizations with them.
      add :user_id, references(:users, on_delete: :delete_all, type: :uuid, prefix: "auth"),
        null: false

      add :provider, :text, null: false
      # The user's stable id at the provider. Kept so a reconnect can be matched
      # to the existing row even if the user's display name changed.
      add :provider_user_id, :text, null: false
      add :display_name, :text

      add :access_token, :binary
      add :refresh_token, :binary
      add :access_token_expires_at, :utc_datetime_usec

      add :scopes, {:array, :text}, null: false, default: []
      add :status, :text, null: false, default: "active"

      add :last_refreshed_at, :utc_datetime_usec
      add :last_error, :text
      add :consecutive_failures, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    # One connection per provider per user, for now. Supporting several accounts
    # of the same service is a later migration plus a query change; there is no
    # point paying for it before the product asks.
    create unique_index(:provider_connections, [:user_id, :provider])

    # The refresh scheduler's query: "which connections expire soon?" Partial,
    # because it never looks at connections that are not active.
    create index(:provider_connections, [:access_token_expires_at],
             where: "status = 'active'",
             name: :provider_connections_refresh_due_index
           )

    execute """
            alter table public.provider_connections
              add constraint provider_connections_provider_check
              check (provider in ('spotify','apple_music','youtube_music','tidal','deezer','plex','jellyfin','navidrome','subsonic'))
            """,
            "alter table public.provider_connections drop constraint provider_connections_provider_check"

    execute """
            alter table public.provider_connections
              add constraint provider_connections_status_check
              check (status in ('active','expired','revoked','reauth_required'))
            """,
            "alter table public.provider_connections drop constraint provider_connections_status_check"

    # --- Authorization -------------------------------------------------------
    #
    # See the migration convention in CLAUDE.md. A new table in `public` starts
    # out unprotected *and* partially granted to anon/authenticated by Supabase's
    # default privileges, so both halves have to be stated.
    #
    # Note this table is never read through PostgREST — the Phoenix application
    # is its only consumer, and it connects as the owner. The grants and policies
    # are defence in depth: if the table is ever exposed, or a key leaks, the
    # blast radius is one user's own rows, and the token columns are ciphertext
    # regardless.

    execute "alter table public.provider_connections enable row level security",
            "alter table public.provider_connections disable row level security"

    execute "revoke all on table public.provider_connections from anon, authenticated",
            "grant all on table public.provider_connections to anon, authenticated"

    # `anon` gets nothing at all: an unauthenticated caller has no business here.
    execute "grant select, insert, update, delete on table public.provider_connections to authenticated",
            "revoke select, insert, update, delete on table public.provider_connections from authenticated"

    for {action, clauses} <- [
          {"select", "using ((select auth.uid()) = user_id)"},
          {"insert", "with check ((select auth.uid()) = user_id)"},
          {"update",
           "using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)"},
          {"delete", "using ((select auth.uid()) = user_id)"}
        ] do
      # auth.uid() is wrapped in a subselect so Postgres hoists it into an
      # initPlan and evaluates it once per statement instead of once per row.
      execute """
              create policy "own connections #{action}" on public.provider_connections
                for #{action} to authenticated #{clauses}
              """,
              ~s|drop policy "own connections #{action}" on public.provider_connections|
    end

    # Housekeeping for the table Ecto created before this convention existed.
    execute "revoke all on table public.schema_migrations from anon, authenticated",
            "grant truncate, references, trigger on table public.schema_migrations to anon, authenticated"
  end

  def down do
    execute "grant truncate, references, trigger on table public.schema_migrations to anon, authenticated"
    drop table(:provider_connections)
  end
end
