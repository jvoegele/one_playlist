defmodule OnePlaylist.Repo.Migrations.AddIsrcDisputedToLibraryRecordings do
  use Ecto.Migration

  @moduledoc """
  This recording's ISRC names different music, and we know it.

  ## The state that had nowhere to live

  `enrichment_outcome: :identifier_disagreed` says the ISRC resolved to a
  recording that is plainly not ours — Roon's export writes *Vitalogy*'s codes
  onto *Vs.* tracks, and four recordings in one real library carry one. Until
  now that outcome also **stopped** enrichment: the text and release paths were
  never tried, so a wrong code in the source cost the recording every chance of
  being identified at all.

  It should not. The code being wrong says nothing about the title, the credit
  or the album, which are the source's own and usually fine. So enrichment now
  falls through and asks the way it would have if there had been no code — and
  measured against `dev/corpus/enrichment_cases.json`, two of those four are
  identified by the text path alone.

  Which creates the state this column records. A recording can now end up
  **identified, while its ISRC is known to be wrong**, and `enrichment_outcome`
  cannot hold that: it becomes `:identified` and the disagreement is forgotten.

  ## Why the identity spine has to know

  `OnePlaylist.Library.Identities` anchors a cross-service identity on a
  **canonical ISRC** — that is the rule that makes duplicate recordings
  structurally impossible there. Anchoring on a code we have already caught
  naming other music would assert, about every future transfer and unreviewed,
  that some other recording is this one.

  So the flag is read there rather than here: a disputed ISRC is not an anchor.
  The recording keeps the code, because it is what the source said and this
  application does not overwrite that — see `enrich/1`'s
  `nothing_was_overwritten` postcondition — it simply stops trusting it.

  `false` for everything existing, which is the truthful default: an ISRC nobody
  has caught out is not thereby disputed.
  """

  def change do
    alter table(:library_recordings) do
      add :isrc_disputed, :boolean, null: false, default: false
    end

    # "Which of my tracks carry a code that names something else?" — the
    # playlist header counts them, and it is the one enrichment outcome a person
    # can actually fix. Partial, because the answer is almost always no.
    create index(:library_recordings, [:isrc_disputed],
             where: "isrc_disputed",
             name: :library_recordings_disputed_isrc_index
           )
  end
end
