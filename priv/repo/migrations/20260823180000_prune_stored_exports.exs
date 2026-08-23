defmodule OnePlaylist.Repo.Migrations.PruneStoredExports do
  @moduledoc """
  Nightly deletion of old export files, from inside Postgres.

  ## Why this needs three extensions to do one thing

  `storage.objects` carries a `protect_delete` trigger that refuses any direct
  `DELETE` — *"Direct deletion from storage tables is not allowed. Use the
  Storage API instead."* — because a row there is only half of a stored file;
  the other half is a blob in the backing store, and deleting the row alone
  orphans it.

  So a scheduled tidy-up has to make an HTTP request. `pg_cron` runs it,
  `pg_net` makes the request, and `supabase_vault` holds the credential it needs.

  ## The credential is a service role key, and it is not in this file

  Deleting somebody's object through the API means authenticating as somebody
  who may. No user's token will do: they expire in an hour and live in a
  browser's cookie. The service role key will, and it bypasses every RLS policy
  in the database, which is exactly why it is confined to this one scheduled
  function rather than being available to the application.

  Two things make that acceptable rather than merely convenient. `vault.decrypted_secrets`
  is readable by `postgres` and `service_role` only, so a compromised
  `authenticated` session cannot reach it. And this function is the only thing
  that reads it: `OnePlaylist.Storage` uses the signed-in user's own token, so
  the four bucket policies still apply to everything the application does.

  **The secrets are created out of band**, because a migration is committed and
  a service key must not be. Both are looked up by name, and the function
  reports and returns zero when they are absent, so a checkout without them
  migrates and simply prunes nothing. See `CLAUDE.md` for the two commands.

  ## Exports only

  An export is regenerable and short-lived: the signed URL that made it useful
  expires in an hour, and nothing in the application lists past ones. After a
  week it is dead weight.

  An import is the opposite. It is the record of what somebody uploaded, named
  by `transfers.source_playlist_id`, and it is what a re-run re-parses. It is
  pruned when its transfer is, which is currently never — a deliberate gap, not
  an oversight.
  """

  use Ecto.Migration

  # A week, matching `prune_transfer_sources`. Long enough that somebody who
  # exported on Monday can still be sent the file on Friday, short enough that
  # storage does not grow without bound.
  @export_ttl_days 7

  # One night's work. A backlog drains over several runs rather than putting ten
  # thousand paths in one request body, and a failed batch is retried tomorrow
  # because the objects are still there to be found.
  @batch_size 100

  def up do
    execute "create extension if not exists pg_net", "select 1"

    execute """
            create or replace function public.prune_stored_exports(older_than interval)
            returns bigint
            language plpgsql
            security invoker
            set search_path = public, pg_temp
            as $$
            declare
              base_url text;
              service_key text;
              doomed text[];
            begin
              select decrypted_secret into base_url
                from vault.decrypted_secrets where name = 'one_playlist_storage_url';

              select decrypted_secret into service_key
                from vault.decrypted_secrets where name = 'one_playlist_service_key';

              if base_url is null or service_key is null then
                raise notice 'Storage pruning is not configured (missing vault secret one_playlist_storage_url or one_playlist_service_key). No files were removed.';
                return 0;
              end if;

              -- Selected here rather than in the delete, because the delete is an
              -- HTTP call: there is nothing to join against and nothing to
              -- return rows from.
              select array_agg(name) into doomed
                from (
                  select name
                    from storage.objects
                   where bucket_id = 'playlists'
                     and (storage.foldername(name))[2] = 'exports'
                     and created_at < now() - older_than
                   order by created_at
                   limit #{@batch_size}
                ) old;

              if doomed is null then
                return 0;
              end if;

              -- Fire and forget. pg_net is asynchronous by design: this returns
              -- a request id, and the response lands in net._http_response
              -- afterwards. So the number below is what was *asked* for, not
              -- what was deleted — and a failed request needs no handling here,
              -- because the objects are still there and tomorrow's run finds
              -- them again.
              perform net.http_delete(
                url := base_url || '/storage/v1/object/playlists',
                headers := jsonb_build_object(
                  'Authorization', 'Bearer ' || service_key,
                  'Content-Type', 'application/json'
                ),
                body := jsonb_build_object('prefixes', to_jsonb(doomed))
              );

              return array_length(doomed, 1);
            end;
            $$
            """,
            "drop function if exists public.prune_stored_exports(interval)"

    # Best-effort, like the other two schedules: pg_cron installs only into the
    # database named by `cron.database_name`, and a hosted project that has not
    # enabled it should not fail this migration over a nightly tidy-up.
    execute """
            do $$
            begin
              create extension if not exists pg_cron;

              perform cron.schedule(
                'prune-stored-exports',
                '11 5 * * *',
                $cron$select public.prune_stored_exports(interval '#{@export_ttl_days} days')$cron$
              );
            exception when others then
              raise notice 'pg_cron not scheduled (%). Old export files will not be removed automatically; call public.prune_stored_exports() instead.', sqlerrm;
            end
            $$
            """,
            """
            do $$
            begin
              perform cron.unschedule('prune-stored-exports');
            exception when others then
              null;
            end
            $$
            """
  end

  def down do
    execute """
    do $$
    begin
      perform cron.unschedule('prune-stored-exports');
    exception when others then
      null;
    end
    $$
    """

    execute "drop function if exists public.prune_stored_exports(interval)"
  end
end
