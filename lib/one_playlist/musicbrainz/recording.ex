defmodule OnePlaylist.MusicBrainz.Recording do
  @moduledoc """
  A MusicBrainz recording as this application keeps it.

  The counterpart to `OnePlaylist.MusicBrainz.Release`, and the row behind
  `OnePlaylist.MusicBrainz.recording/2`. See the migration for why it never
  expires and why it holds both promoted columns and the whole document.

  ## Not `OnePlaylist.Library.Recording`

  Two different things with one good name, so it is worth being explicit. This is
  **the world's** recording — what MusicBrainz says, keyed by its own id, owned
  by nobody and the same answer for every user. `Library.Recording` is a row
  *this application holds*, which may name one of these and may not.

  `docs/reference/domain.md` §6 is about the seam between them.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:mbid, Ecto.UUID, autogenerate: false}
  schema "musicbrainz_recordings" do
    field :title, :string
    field :length_ms, :integer
    field :isrcs, {:array, :string}, default: []
    field :artist_credit, :string

    # The lookup response, whole. `releases` with their groups and barcodes,
    # `relations` from `inc=work-rels`, and anything MusicBrainz adds later.
    field :document, :map

    field :looked_up_at, :utc_datetime_usec
  end
end
