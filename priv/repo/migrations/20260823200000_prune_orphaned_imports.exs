defmodule OnePlaylist.Repo.Migrations.PruneOrphanedImports do
  @moduledoc """
  Nightly removal of uploaded files no transfer refers to any more.

  ## Two ways a file ends up with nobody pointing at it

  `OnePlaylist.Transfers.delete/2` removes the row first and the file second, on
  purpose: a transfer pointing at a file that is gone looks intact and cannot be
  re-run, while an orphaned file is recoverable. If that second step fails, this
  is what recovers it.

  The other way is older and was documented as acceptable when it was written.
  `OnePlaylist.Imports.import/4` stores the upload *outside* the transaction that
  creates the transfer, because Storage has no rollback — so a transfer insert
  that fails leaves a file behind. That loop closes here.

  It is not hypothetical either. The `:supabase`-tagged tests hit it every run:
  the Ecto sandbox rolls back the transfer while Storage keeps the object, which
  had left 106 of them by the time this migration was written.

  ## The grace period is doing real work

  An upload becomes an orphan for a moment in the ordinary case — the file is
  stored, and the transfer row does not exist until the transaction commits a
  moment later. A sweep with no grace period would race that window and delete a
  file somebody had just uploaded successfully.

  A day is far longer than needed and costs nothing, since these are files
  nobody is looking for.
  """

  use Ecto.Migration

  # Long enough that no upload in progress is ever a candidate.
  @grace_days 1

  # Same reasoning as `prune_stored_exports`: a backlog drains over several
  # nights rather than putting every path in one request body.
  @batch_size 100

  def up do
    execute """
            create or replace function public.prune_orphaned_imports(grace interval)
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

              -- `not exists` against the column that names the file. A transfer's
              -- `source_playlist_id` *is* the storage path for a file source, so
              -- this is an ownership question rather than a heuristic.
              select array_agg(name) into doomed
                from (
                  select o.name
                    from storage.objects o
                   where o.bucket_id = 'playlists'
                     and (storage.foldername(o.name))[2] = 'imports'
                     and o.created_at < now() - grace
                     and not exists (
                       select 1
                         from public.transfers t
                        where t.source_playlist_id = o.name
                     )
                   order by o.created_at
                   limit #{@batch_size}
                ) orphans;

              if doomed is null then
                return 0;
              end if;

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
            "drop function if exists public.prune_orphaned_imports(interval)"

    execute """
            do $$
            begin
              create extension if not exists pg_cron;

              perform cron.schedule(
                'prune-orphaned-imports',
                '29 5 * * *',
                $cron$select public.prune_orphaned_imports(interval '#{@grace_days} days')$cron$
              );
            exception when others then
              raise notice 'pg_cron not scheduled (%). Orphaned uploads will not be removed automatically; call public.prune_orphaned_imports() instead.', sqlerrm;
            end
            $$
            """,
            """
            do $$
            begin
              perform cron.unschedule('prune-orphaned-imports');
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
      perform cron.unschedule('prune-orphaned-imports');
    exception when others then
      null;
    end
    $$
    """

    execute "drop function if exists public.prune_orphaned_imports(interval)"
  end
end
