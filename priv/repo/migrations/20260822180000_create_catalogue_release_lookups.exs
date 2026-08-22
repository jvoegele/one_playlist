defmodule OnePlaylist.Repo.Migrations.CreateCatalogueReleaseLookups do
  use Ecto.Migration

  @moduledoc """
  L2 of the catalogue cache: which album a barcode is, at each provider.

  The first table in this application whose rows **belong to nobody**. Every
  other table so far answers "what is true for this user"; this one answers
  "what is true about the world's record catalogue", which is the same answer
  for every user and stays true after they leave. That difference decides both
  the authorization shape below and why it is worth persisting at all.

  It is also the shape `docs/reference/domain.md` calls the asset that
  compounds: a lookup paid for once is never paid for again, by anyone, on any
  node, across deploys.
  """

  # A negative entry — "this provider does not carry this barcode" — is worth
  # remembering, because otherwise every track on that release re-asks and
  # re-learns the same nothing. But unlike a positive one it can stop being
  # true: catalogues gain releases. So negatives expire and positives do not.
  @negative_ttl_days 30

  def up do
    create table(:catalogue_release_lookups, primary_key: false) do
      add :provider, :text, null: false
      # Normalized: digits only, leading zeros stripped. TIDAL reports barcodes
      # zero-padded to 13 digits where other catalogues print 12, and comparing
      # them as written makes every cross-service match fail silently. See
      # OnePlaylist.Matching.Signals.normalize_barcode/1.
      add :barcode, :text, null: false

      # NULL means "asked, and this provider does not have it". Distinct from a
      # missing row, which means "never asked".
      add :provider_album_id, :text

      add :looked_up_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    execute """
            alter table public.catalogue_release_lookups
              add constraint catalogue_release_lookups_pkey
              primary key (provider, barcode)
            """,
            "alter table public.catalogue_release_lookups drop constraint catalogue_release_lookups_pkey"

    # Only negative entries are ever pruned, so the index that supports pruning
    # need only cover them.
    create index(:catalogue_release_lookups, [:looked_up_at],
             where: "provider_album_id is null",
             name: :catalogue_release_lookups_negative_index
           )

    execute """
            alter table public.catalogue_release_lookups
              add constraint catalogue_release_lookups_provider_check
              check (provider in ('spotify','apple_music','youtube_music','tidal','deezer','plex','jellyfin','navidrome','subsonic'))
            """,
            "alter table public.catalogue_release_lookups drop constraint catalogue_release_lookups_provider_check"

    # --- Authorization -------------------------------------------------------
    #
    # Per the migration convention in CLAUDE.md, a new table in `public` starts
    # out unprotected *and* partially granted to anon/authenticated, so both
    # halves are stated even when the answer is "nothing".
    #
    # This is where a table of non-user data differs from every other one here.
    # There is no `auth.uid()` to compare against — no row belongs to anyone —
    # so the usual "own rows" policy has nothing to say. That leaves two honest
    # options:
    #
    #   * grant `select` to `authenticated` with `using (true)`, on the grounds
    #     that catalogue facts are public information; or
    #   * grant nothing, on the grounds that no client needs it.
    #
    # The second is correct today and is what is done. This table is server-side
    # infrastructure: the Phoenix application is its only consumer and connects
    # as the owner, so a grant would be surface without a use. If a client ever
    # does need it — a "why did this track not match?" panel reading straight
    # through PostgREST — the change is a `select` grant plus
    # `create policy … for select to authenticated using (true)`, and the
    # reasoning above is why that policy is safe here and would not be on any
    # other table in this schema.
    execute "alter table public.catalogue_release_lookups enable row level security",
            "alter table public.catalogue_release_lookups disable row level security"

    execute "revoke all on table public.catalogue_release_lookups from anon, authenticated",
            "grant all on table public.catalogue_release_lookups to anon, authenticated"

    # --- Housekeeping --------------------------------------------------------
    #
    # A function rather than an inline cron command, so that pruning is
    # callable, testable and grep-able whether or not a scheduler ever runs it.
    execute """
            create or replace function public.prune_catalogue_release_lookups(older_than interval)
            returns bigint
            language plpgsql
            security invoker
            set search_path = public, pg_temp
            as $$
            declare
              removed bigint;
            begin
              delete from public.catalogue_release_lookups
                where provider_album_id is null
                  and looked_up_at < now() - older_than;

              get diagnostics removed = row_count;

              return removed;
            end;
            $$
            """,
            "drop function if exists public.prune_catalogue_release_lookups(interval)"

    # pg_cron is one of the Supabase surfaces this project sets out to use
    # deliberately rather than read about, and expiring negative catalogue
    # entries is a genuine fit: periodic, database-local, and needing no
    # application process to be alive.
    #
    # Best-effort on purpose. `pg_cron` must be enabled for the database and
    # installs only into the one named by `cron.database_name`, so a hosted
    # project that has not enabled it would otherwise fail this migration for a
    # nightly tidy-up. The function above is the part that matters; the
    # schedule is a convenience, and the notice says so.
    execute """
            do $$
            begin
              create extension if not exists pg_cron;

              perform cron.schedule(
                'prune-catalogue-release-lookups',
                '17 4 * * *',
                $cron$select public.prune_catalogue_release_lookups(interval '#{@negative_ttl_days} days')$cron$
              );
            exception when others then
              raise notice 'pg_cron not scheduled (%). Negative catalogue entries will not be pruned automatically; call public.prune_catalogue_release_lookups() instead.', sqlerrm;
            end
            $$
            """,
            """
            do $$
            begin
              perform cron.unschedule('prune-catalogue-release-lookups');
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
      perform cron.unschedule('prune-catalogue-release-lookups');
    exception when others then
      null;
    end
    $$
    """

    execute "drop function if exists public.prune_catalogue_release_lookups(interval)"

    drop table(:catalogue_release_lookups)
  end
end
