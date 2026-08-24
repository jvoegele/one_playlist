defmodule OnePlaylist.Repo.Migrations.AddReleaseToLibraryRecordings do
  use Ecto.Migration

  @moduledoc """
  Which MusicBrainz *release* a recording's metadata was taken from.

  A recording appears on many releases — the original pressing, a reissue, a
  regional edition, a compilation — and they disagree about barcode and cover
  art. Enrichment previously took whichever one MusicBrainz happened to list
  first, which is no order at all, so eight tracks from one album resolved to
  three different releases and the album contradicted itself: two barcodes, one
  cover on two tracks and none on the other six.

  Recording the choice fixes that in two ways. It makes the decision auditable
  rather than implicit in a barcode, and it lets a later track from the same
  album find the release its siblings already agreed on — the only durable way
  to keep an album consistent, since an in-memory cache forgets on restart.

  The index is on `album` for exactly that lookup.
  """

  def change do
    alter table(:library_recordings) do
      add :musicbrainz_release_id, :uuid
    end

    # "Which release did this album already settle on?" — partial, because a row
    # with no album or no chosen release can never answer it.
    create index(:library_recordings, [:album],
             name: :library_recordings_album_release_index,
             where: "album is not null and musicbrainz_release_id is not null"
           )
  end
end
