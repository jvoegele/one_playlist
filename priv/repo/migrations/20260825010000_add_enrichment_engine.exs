defmodule OnePlaylist.Repo.Migrations.AddEnrichmentEngine do
  use Ecto.Migration

  @moduledoc """
  Which version of the matching engine decided this recording's fate.

  A recording that declined did so under the rules in force that day. Those
  rules change — in one working day they changed five times, and each change
  left every earlier decline stale with nothing to say so. The nightly sweep
  re-offers a recording after thirty days or never, so a rule written this
  morning reached last week's declines a month later or not at all.

  The column holds a fingerprint of the modules whose behaviour decides an
  outcome, so `OnePlaylist.Library.Enrichment.due/1` can offer back anything
  that failed under a fingerprint other than today's.

  ## Only the ones that failed

  A recording that *was* identified is not re-offered, however much the rules
  move. Enrichment fills gaps and never overwrites, so running it again over an
  identified recording changes nothing and spends a request finding that out.

  That leaves a real gap and it is deliberate: a rule that gets **stricter** —
  the identifier guard added the day before this — should arguably re-examine
  what it once accepted, and this will not do that. Re-deciding a settled
  identity means discarding it first, which is `reset/1`, which is destructive
  and belongs in somebody's hands rather than in a nightly job.
  """

  def change do
    alter table(:library_recordings) do
      add :enrichment_engine, :text
    end

    # The sweep's query: what failed, under rules that are no longer current.
    # Partial, because a recording that succeeded is never offered by it.
    create index(:library_recordings, [:enrichment_engine],
             where: "musicbrainz_recording_id is null",
             name: :library_recordings_stale_engine_index
           )
  end
end
