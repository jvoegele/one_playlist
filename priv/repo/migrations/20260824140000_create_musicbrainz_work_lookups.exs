defmodule OnePlaylist.Repo.Migrations.CreateMusicbrainzWorkLookups do
  @moduledoc """
  Which catalogue number a classical work goes by, remembered.

  ## The fact this stores

  A classical title identifies its piece by catalogue number — `BWV 1047`,
  `RV 531`, `K. 525` — and a great many titles omit it. "Brandenburg Concerto
  no. 2 in F major" names the work exactly and gives no number, while every
  catalogue TIDAL carries writes `BWV 1047`. `OnePlaylist.Matching.Strategy.Work`
  then has nothing to match on.

  MusicBrainz knows. Its `work` search answers "Brandenburg Concerto no. 2 Bach"
  with *Brandenburgisches Konzert Nr. 2 F-Dur, BWV 1047*, and the number is in
  the title where `OnePlaylist.Music.Work` already reads it.

  It also crosses numbering systems, which nothing local can do: Scarlatti's
  *Sonata in D minor, L 413* comes back as *K 9*, and the catalogue offers it
  under the Kirkpatrick number.

  ## Keyed by the question, not the answer

  The key is the normalized query — the title and the composer — because that is
  what a caller has. Two different works asked about the same way would collide,
  which is why the query includes the composer and why a miss is stored rather
  than retried.

  ## Ownerless, and read only by the application

  Same shape as `musicbrainz_isrc_lookups` and `catalogue_release_lookups`: these
  rows belong to nobody, `anon` and `authenticated` are granted nothing, and a
  client able to write here could make the matching engine believe any two works
  were the same.

  Negatives expire nightly. MusicBrainz is edited continuously, and a work it
  does not know today may exist next month.
  """

  use Ecto.Migration

  @negative_ttl_days 30

  def up do
    create table(:musicbrainz_work_lookups, primary_key: false) do
      # The normalized question: folded title and composer.
      add :query, :text, primary_key: true

      # Every catalogue number the best-scoring works carry, as the strings they
      # were written in — "bwv 1047" — so `Music.Work.parse/1` reads them back
      # with the same code that reads a track title. Null means MusicBrainz
      # answered and had nothing.
      add :catalogue_titles, {:array, :text}

      add :looked_up_at, :utc_datetime_usec, null: false
    end

    execute "alter table public.musicbrainz_work_lookups enable row level security",
            "alter table public.musicbrainz_work_lookups disable row level security"

    execute "revoke all on table public.musicbrainz_work_lookups from anon, authenticated",
            "grant all on table public.musicbrainz_work_lookups to anon, authenticated"

    execute """
            create or replace function public.prune_musicbrainz_work_lookups(older_than interval)
            returns bigint
            language plpgsql
            security invoker
            set search_path = public, pg_temp
            as $$
            declare
              removed bigint;
            begin
              delete from public.musicbrainz_work_lookups
                where catalogue_titles is null
                  and looked_up_at < now() - older_than;

              get diagnostics removed = row_count;

              return removed;
            end;
            $$
            """,
            "drop function if exists public.prune_musicbrainz_work_lookups(interval)"

    execute """
            do $$
            begin
              create extension if not exists pg_cron;

              perform cron.schedule(
                'prune-musicbrainz-work-lookups',
                '53 5 * * *',
                $cron$select public.prune_musicbrainz_work_lookups(interval '#{@negative_ttl_days} days')$cron$
              );
            exception when others then
              raise notice 'pg_cron not scheduled (%). Negative MusicBrainz work lookups will not expire automatically.', sqlerrm;
            end
            $$
            """,
            """
            do $$
            begin
              perform cron.unschedule('prune-musicbrainz-work-lookups');
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
      perform cron.unschedule('prune-musicbrainz-work-lookups');
    exception when others then
      null;
    end
    $$
    """

    execute "drop function if exists public.prune_musicbrainz_work_lookups(interval)"

    drop table(:musicbrainz_work_lookups)
  end
end
