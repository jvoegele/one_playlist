defmodule OnePlaylist.Repo.Migrations.CreateRecordingEnrichments do
  use Ecto.Migration

  @moduledoc """
  Enrichment's record of what it did, off the row that says what the music is.

  `docs/reference/domain.md` §6 is the argument. `library_recordings` holds three
  kinds of claim with three different authorities: what the music **is** (the
  world's answer), where it **appears** (one release's answer, of many), and how
  this application **tried to find out** (ours). The third had no business on a
  shared, ownerless row whose own moduledoc calls it "a fact about a piece of
  music… the same answer for every user", and it is the only one of the three
  that churns.

  Four columns move. `isrc_disputed` deliberately does **not**, and §6's own
  table was wrong to group it with these: a disputed code is a durable claim
  about the ISRC, read by `OnePlaylist.Library.Identities` when it refuses to
  anchor on one, and it has to survive a later attempt that succeeds. That
  survival is the whole reason the column exists apart from `enrichment_outcome`,
  and moving it into a table of attempts would reintroduce the forgetting it was
  created to prevent.

  ## What the split buys, beyond tidiness

  `Enrichment.write/2` had to carry an exception list. Enrichment fills gaps and
  never corrects — except for `@bookkeeping`, which is overwritten on every
  attempt "because last time's reason is not this time's". With the bookkeeping
  in its own row that exception disappears: `write/2` becomes an unconditional
  fill-gaps, and the rule the moduledoc states is the rule the code performs.

  `reset/1` improves for the same reason. "Look at this again from scratch" was
  clearing six columns from two different lists; it is now clearing the two
  identity fields and **deleting the attempt**, which is what the operation
  actually means.

  And a recording's `updated_at` stops moving when nothing about the music has
  changed, which makes it answer a question worth asking.

  ## One row per recording, one index away from one row per attempt

  A `unique_index` on `recording_id` rather than a primary key on it. The 1:1
  shape is what the current readers want — `due/1` asks for the state of the
  last attempt, and history would make every read a lateral join for a feature
  nothing has asked for yet.

  But history is the thing this table could give that columns never could: when
  a recording became identified, and under which engine. Dropping the unique
  index is the whole change, which is why the surrogate key is here rather than
  the obvious `primary_key: :recording_id`. Per §6's rule, that waits for
  something that needs it.

  ## Ownerless, like the recording it hangs off

  The shape from `create_recording_identities`. That an attempt was made is no
  more anybody's private business than the recording is, and the screens that
  show "not identified yet" read it as any signed-in user.
  """

  def up do
    create table(:recording_enrichments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :recording_id,
          references(:library_recordings, type: :binary_id, on_delete: :delete_all),
          null: false

      # `enriched_at` renamed on the way across, because the old name says the
      # wrong thing and its own comment said so: this is when MusicBrainz was
      # last *asked*, "whether or not it had anything to say". A row exists here
      # for every completed attempt, including the ones that learned nothing.
      add :attempted_at, :utc_datetime_usec, null: false

      add :outcome, :text
      add :candidates, :integer
      add :engine, :text
    end

    # One row per recording. See the moduledoc for why this is an index and not
    # the primary key.
    create unique_index(:recording_enrichments, [:recording_id])

    # `due/1` orders by this and takes a limit, oldest first.
    create index(:recording_enrichments, [:attempted_at])

    execute """
            insert into public.recording_enrichments
              (id, recording_id, attempted_at, outcome, candidates, engine)
            select gen_random_uuid(), id, enriched_at, enrichment_outcome,
                   enrichment_candidates, enrichment_engine
            from public.library_recordings
            where enriched_at is not null
            """,
            """
            update public.library_recordings r
              set enriched_at = e.attempted_at,
                  enrichment_outcome = e.outcome,
                  enrichment_candidates = e.candidates,
                  enrichment_engine = e.engine
            from public.recording_enrichments e
            where e.recording_id = r.id
            """

    execute "alter table public.recording_enrichments enable row level security",
            "alter table public.recording_enrichments disable row level security"

    execute "revoke all on table public.recording_enrichments from anon, authenticated",
            "grant all on table public.recording_enrichments to anon, authenticated"

    execute "grant select on table public.recording_enrichments to authenticated",
            "revoke select on table public.recording_enrichments from authenticated"

    execute """
            create policy "enrichment attempts are public metadata"
              on public.recording_enrichments
              for select to authenticated using (true)
            """,
            ~s|drop policy "enrichment attempts are public metadata" on public.recording_enrichments|

    alter table(:library_recordings) do
      remove :enriched_at, :utc_datetime_usec
      remove :enrichment_outcome, :text
      remove :enrichment_candidates, :integer
      remove :enrichment_engine, :text
    end
  end

  def down do
    alter table(:library_recordings) do
      add :enriched_at, :utc_datetime_usec
      add :enrichment_outcome, :text
      add :enrichment_candidates, :integer
      add :enrichment_engine, :text
    end

    execute """
    update public.library_recordings r
      set enriched_at = e.attempted_at,
          enrichment_outcome = e.outcome,
          enrichment_candidates = e.candidates,
          enrichment_engine = e.engine
    from public.recording_enrichments e
    where e.recording_id = r.id
    """

    drop table(:recording_enrichments)
  end
end
