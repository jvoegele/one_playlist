defmodule OnePlaylist.Repo.Migrations.CreateMusicbrainzIsrcLookups do
  @moduledoc """
  Which ISRCs name the same recording, remembered.

  ## The fact this stores, and why it is worth storing

  An ISRC identifies a recording **as issued on a particular release**, so the
  same master carries a different code on every reissue. Roon exports Eddie
  Vedder's *Setting Forth* as `USJY50700001` — the 2007 soundtrack — and TIDAL
  holds it as `USJY51700100`, the 2017 reissue. Asking TIDAL for the first
  returns nothing at all, and the track was reported as "nothing found on the
  destination" while sitting in the catalogue under another number.

  MusicBrainz groups them. One request returns the recording and every ISRC it
  is known by, which turns a failed identifier lookup into a successful one
  without another provider call.

  ## Why a cache table rather than a dump

  MusicBrainz publishes its whole database, and it is 4–5 GB compressed. None of
  that is needed: the useful question is "what else is this recording called",
  asked only about the one ISRC in front of us, and only when the direct lookup
  has already missed — about one ISRC-bearing track in seven, measured.

  A row is an ISRC, a recording id and a short array. A million of them is on
  the order of 100 MB, which is a different proposition entirely.

  ## Ownerless, like `catalogue_release_lookups`

  These rows belong to nobody. "USJY50700001 and USJY51700100 name one
  recording" is true for every user, so the `auth.uid()` policy shape does not
  apply and there is nothing to scope. `anon` and `authenticated` are granted
  nothing at all: this is read and written by the application only, and a client
  able to write here could make the matching engine believe any two recordings
  were the same.

  ## Negative entries expire

  An ISRC MusicBrainz has never heard of is worth remembering so it is not asked
  about repeatedly, and worth forgetting eventually because MusicBrainz is
  edited continuously and today's gap is next month's entry. Same reasoning, and
  the same nightly `pg_cron` job shape, as the catalogue's negative lookups.
  """

  use Ecto.Migration

  # A month. Long enough that a transfer re-run costs nothing, short enough that
  # a recording added to MusicBrainz in the meantime is picked up.
  @negative_ttl_days 30

  def up do
    create table(:musicbrainz_isrc_lookups, primary_key: false) do
      # The ISRC asked about, in canonical form — twelve upper-case
      # alphanumerics. `OnePlaylist.Music.Isrc.normalize/1` is what guarantees
      # that, and an unnormalized key is a second private copy of the same fact
      # rather than a wrong answer.
      add :isrc, :text, primary_key: true

      # Null means MusicBrainz does not know this ISRC. That is an answer worth
      # keeping, and it is what the pruning below expires.
      add :recording_mbid, :uuid

      # Every ISRC the recording is known by, this one included. Null rather
      # than an empty array when the recording is unknown, so the two states
      # cannot be confused by a caller reading only this column.
      add :isrcs, {:array, :text}

      add :looked_up_at, :utc_datetime_usec, null: false
    end

    # --- Authorization -------------------------------------------------------
    #
    # The ownerless shape: protection by *absence of grant*, since there is no
    # owner to compare against. See `docs/reference/supabase.md`.
    execute "alter table public.musicbrainz_isrc_lookups enable row level security",
            "alter table public.musicbrainz_isrc_lookups disable row level security"

    execute "revoke all on table public.musicbrainz_isrc_lookups from anon, authenticated",
            "grant all on table public.musicbrainz_isrc_lookups to anon, authenticated"

    # --- Housekeeping --------------------------------------------------------
    execute """
            create or replace function public.prune_musicbrainz_isrc_lookups(older_than interval)
            returns bigint
            language plpgsql
            security invoker
            set search_path = public, pg_temp
            as $$
            declare
              removed bigint;
            begin
              delete from public.musicbrainz_isrc_lookups
                where recording_mbid is null
                  and looked_up_at < now() - older_than;

              get diagnostics removed = row_count;

              return removed;
            end;
            $$
            """,
            "drop function if exists public.prune_musicbrainz_isrc_lookups(interval)"

    # Best-effort, like every other schedule here: `pg_cron` installs only into
    # the database named by `cron.database_name`, and a project that has not
    # enabled it should not fail this migration over a nightly tidy-up.
    execute """
            do $$
            begin
              create extension if not exists pg_cron;

              perform cron.schedule(
                'prune-musicbrainz-isrc-lookups',
                '47 5 * * *',
                $cron$select public.prune_musicbrainz_isrc_lookups(interval '#{@negative_ttl_days} days')$cron$
              );
            exception when others then
              raise notice 'pg_cron not scheduled (%). Negative MusicBrainz lookups will not expire automatically; call public.prune_musicbrainz_isrc_lookups() instead.', sqlerrm;
            end
            $$
            """,
            """
            do $$
            begin
              perform cron.unschedule('prune-musicbrainz-isrc-lookups');
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
      perform cron.unschedule('prune-musicbrainz-isrc-lookups');
    exception when others then
      null;
    end
    $$
    """

    execute "drop function if exists public.prune_musicbrainz_isrc_lookups(interval)"

    drop table(:musicbrainz_isrc_lookups)
  end
end
