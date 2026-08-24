defmodule OnePlaylist.Repo.Migrations.AddEnrichmentOutcome do
  use Ecto.Migration

  @moduledoc """
  Why enrichment did not identify a recording.

  `enriched_at` says whether MusicBrainz was asked and
  `musicbrainz_recording_id` says whether it answered, and between them they
  cannot distinguish the two cases a reader most wants told apart:

    * **Nothing came back.** MusicBrainz genuinely holds no such recording — a
      bootleg, a medley, a store-invented bucket.
    * **Candidates came back and none was certain enough.** The right recording
      is very often among them, ranked first, and declined because the stored
      album carries a subtitle the catalogue does not use.

  Collapsing those into one marker made the screen say *not found at
  MusicBrainz* for a record MusicBrainz plainly holds, which reads as a matching
  bug and was reported as one. The wording was corrected first; this is what
  lets it say **which**.

  `enrichment_candidates` is the count behind the second case, so a row can say
  "twelve found, none certain" rather than leaving the reader to wonder whether
  it was one near miss or a page of noise.

  Both are enrichment's own bookkeeping rather than facts about the music, so
  they are overwritten on every attempt — unlike every other column it fills,
  which it only ever fills a gap in.
  """

  def change do
    alter table(:library_recordings) do
      # Deliberately not an enum type in Postgres: the set will grow as
      # enrichment learns more ways to fail, and an `alter type` under load is a
      # worse problem than an unconstrained text column that `Ecto.Enum` already
      # validates on the way in.
      add :enrichment_outcome, :text
      add :enrichment_candidates, :integer
    end
  end
end
