defmodule OnePlaylist.Repo.Migrations.AddEnrichmentToLibraryRecordings do
  use Ecto.Migration

  @moduledoc """
  When a recording was last enriched — `docs/reference/domain.md` §5, L4.

  A timestamp rather than a boolean, and nullable rather than defaulted, so the
  column answers three questions instead of one: never tried (`null`), tried at
  a known time, and *how long ago*. The third is what lets a sweep come back to
  the oldest answers later, because MusicBrainz is edited continuously and a
  recording nothing was known about last month may be well described today.

  The same shape as the negative caches this application already keeps in
  `catalogue_release_lookups` and `musicbrainz_isrc_lookups`: an absence is an
  answer, and it is only true for now.
  """

  def change do
    alter table(:library_recordings) do
      add :enriched_at, :utc_datetime_usec
    end

    # The sweep's query: the least recently enriched first, nulls before them.
    create index(:library_recordings, [:enriched_at], name: :library_recordings_enrichment_index)
  end
end
