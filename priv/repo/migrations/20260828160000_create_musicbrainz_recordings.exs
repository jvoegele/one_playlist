defmodule OnePlaylist.Repo.Migrations.CreateMusicbrainzRecordings do
  use Ecto.Migration

  @moduledoc """
  A MusicBrainz recording, kept once and read for ever after.

  The gap `musicbrainz_releases` had already closed for the other half of the
  same pipeline. `MusicBrainz.family/2`, `works/3` and `release/2` all read
  through the cache; `Client.recording/1` did not, and `Enrichment.describe/3`
  called it straight from the network on every single attempt.

  So a recording that had been identified in January was fetched again in
  February to learn nothing new. Re-enrichment paid it, "look up again" paid it,
  the corpus harvest paid it twice in one afternoon at half an hour each, and the
  credit backfill on 2026-08-28 spent 646 requests re-asking questions this
  application had already asked and thrown away.

  ## Why it is safe to keep for ever

  The same argument the release cache makes, and it holds for the same reason: a
  lookup **by MBID** cannot be a negative. The only ids ever passed here are ones
  MusicBrainz itself supplied — from an ISRC lookup, a search hit or a release's
  track list — so "not found" is not an answer this table has to represent, and
  a 404 is deliberately **not remembered**.

  What a recording says is near-immutable in the ways this application reads it:
  its title, its length, the codes it is issued under. `looked_up_at` is
  therefore for *refreshing*, never for pruning — exactly the note
  `musicbrainz_releases` carries.

  ## What this deliberately gives up

  `Enrichment.due/1` re-offers a recording "looked at long ago" on the grounds
  that "MusicBrainz is edited continuously, so an absence is only true for now".
  Serving that lookup from a permanent cache **defeats that half of the sweep**,
  and saying so here is cheaper than somebody rediscovering it as a bug.

  It is the right trade, for two reasons that do not generalise to the other
  half. The sweep's real purpose is *absences*, and an unidentified recording
  never reaches this table — its path is a search, which is not cached, so the
  case the sweep exists for still works exactly as before. And enrichment fills
  gaps and never corrects, so re-asking about an **identified** recording can
  only fill fields still empty; those were empty because MusicBrainz had nothing
  to say, which is precisely what the cached document faithfully repeats.

  What is genuinely lost is learning that MusicBrainz has *gained* something
  since. The answer to that is a deliberate refresh keyed on `looked_up_at` —
  the affordance this table and `musicbrainz_releases` both carry and neither
  yet uses — and not a TTL, which would throw away good answers to catch rare
  edits.

  ## Promoted columns and a kept document

  Both, and the split is deliberate rather than lazy.

  `title`, `length_ms`, `isrcs` and `artist_credit` are **promoted** because
  something already reads them: `agrees_by_name?/2` compares the title,
  `learned/3` takes the length, the ISRC and the credit. Promoting them makes the
  catalogue answerable — "what do we know about this recording" is a query rather
  than a JSON dig.

  `document` keeps the rest **losslessly**, and that is what makes this a
  behaviour-preserving change: `choose_release/2` reads a recording's whole
  `releases` array, with release-group ids, barcodes and titles nested inside it,
  and `inc=work-rels` carries relationships the classical rung may want. None of
  that has a settled shape yet, and `docs/reference/domain.md` §6's rule is not to
  invent one before there is a consumer. So the parts with a reader get columns
  and the parts without stay whole.

  The duplication that implies cannot drift: both are written from one response,
  in one insert, and neither is ever updated.

  ## Ownerless, and granted to nobody

  The shape of the other MusicBrainz caches rather than of `library_recordings`.
  Nothing in the application reads this as a signed-in user — enrichment is
  background work running privileged — so the table is protected by the absence
  of a grant, which `supabase/tests/rls.test.sql` asserts.
  """

  def up do
    create table(:musicbrainz_recordings, primary_key: false) do
      add :mbid, :uuid, primary_key: true

      add :title, :text
      add :length_ms, :integer
      add :isrcs, {:array, :text}, null: false, default: []
      add :artist_credit, :text

      # The whole lookup response. See the moduledoc.
      add :document, :jsonb, null: false

      add :looked_up_at, :utc_datetime_usec, null: false
    end

    # "Which recording carries this code" without unpacking the document. The
    # positive half of `musicbrainz_isrc_lookups` answers the same question, and
    # this is the catalogue's own copy of it.
    create index(:musicbrainz_recordings, [:isrcs], using: :gin)

    execute "alter table public.musicbrainz_recordings enable row level security",
            "alter table public.musicbrainz_recordings disable row level security"

    execute "revoke all on table public.musicbrainz_recordings from anon, authenticated",
            "grant all on table public.musicbrainz_recordings to anon, authenticated"
  end

  def down do
    drop table(:musicbrainz_recordings)
  end
end
