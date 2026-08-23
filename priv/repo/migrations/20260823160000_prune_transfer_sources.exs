defmodule OnePlaylist.Repo.Migrations.PruneTransferSources do
  @moduledoc """
  Nightly pruning of the parsed tracks behind finished imports.

  ## What is being thrown away, and what is not

  `transfer_sources` is a **cache of a parse**, not a record. The record of what
  somebody uploaded is the file itself, in Supabase Storage, named by
  `transfers.source_playlist_id`. The row exists because a worker cannot read
  Storage — it has no session, and GoTrue refresh tokens live in the browser's
  cookie rather than this database — so the request that received the upload
  parses it and leaves the result where the job can reach it.

  Once a transfer has finished, that result has done its work. A re-run would
  happen from a request, which *does* have a session, and can re-parse the file
  it still has. So the bulky column goes and the record stays.

  Unfinished transfers are never pruned, however old. A job that has been stuck
  for a month still needs its tracks, and deleting them would turn a stalled
  transfer into one that fails with `SourceMissing`.

  ## This does not prune Supabase Storage, and cannot

  Worth stating plainly, because "pruning" sounds like it covers the files.
  `storage.objects` carries a `protect_delete` trigger that refuses any direct
  `DELETE`:

      ERROR: Direct deletion from storage tables is not allowed.
             Use the Storage API instead.
      HINT:  This prevents accidental data loss from orphaned objects.

  So no scheduled SQL can remove a stored file, and objects accumulate. Doing it
  the Supabase-native way would mean `pg_net` calling the Storage API with a
  service key held in Vault, which is three unexercised surfaces at once and a
  service key in the database; doing it the ordinary way means an Oban job.
  Neither is decided, and pretending otherwise here would be worse than a note.
  """

  use Ecto.Migration

  # A week. The tracks are worth keeping while a person might still look at the
  # transfer and run it again without waiting for a re-parse, and worth nothing
  # after that. Shorter than the catalogue cache's thirty days because this
  # decays faster: a report goes stale as soon as it has been read.
  @finished_ttl_days 7

  def up do
    # A function rather than an inline cron command, following the catalogue
    # cache: pruning stays callable, testable and grep-able whether or not a
    # scheduler ever runs it.
    execute """
            create or replace function public.prune_transfer_sources(older_than interval)
            returns bigint
            language plpgsql
            security invoker
            set search_path = public, pg_temp
            as $$
            declare
              removed bigint;
            begin
              delete from public.transfer_sources s
                using public.transfers t
               where s.transfer_id = t.id
                 and t.status in ('completed', 'failed')
                 and t.updated_at < now() - older_than;

              get diagnostics removed = row_count;

              return removed;
            end;
            $$
            """,
            "drop function if exists public.prune_transfer_sources(interval)"

    # Best-effort, for the reason the catalogue cache gives: `pg_cron` installs
    # only into the database named by `cron.database_name`, so a hosted project
    # that has not enabled it would otherwise fail this migration over a nightly
    # tidy-up. The function is the part that matters.
    execute """
            do $$
            begin
              create extension if not exists pg_cron;

              perform cron.schedule(
                'prune-transfer-sources',
                '43 4 * * *',
                $cron$select public.prune_transfer_sources(interval '#{@finished_ttl_days} days')$cron$
              );
            exception when others then
              raise notice 'pg_cron not scheduled (%). Parsed import tracks will not be pruned automatically; call public.prune_transfer_sources() instead.', sqlerrm;
            end
            $$
            """,
            """
            do $$
            begin
              perform cron.unschedule('prune-transfer-sources');
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
      perform cron.unschedule('prune-transfer-sources');
    exception when others then
      null;
    end
    $$
    """

    execute "drop function if exists public.prune_transfer_sources(interval)"
  end
end
