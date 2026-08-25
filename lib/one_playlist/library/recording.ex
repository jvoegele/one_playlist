defmodule OnePlaylist.Library.Recording do
  @moduledoc """
  A recording this application holds, described independently of any service.

  The row a library playlist points at, and — per `docs/reference/domain.md` §5
  — the thing that is meant to compound. A recording belongs to **nobody**: it
  is a fact about a piece of music, the same answer for every user, and it stays
  true after the user who first caused it to be stored has gone. That is why the
  table takes the ownerless shape from `catalogue_release_lookups` rather than
  the `auth.uid()` shape, and why two users importing the same track share one
  row rather than each getting their own.

  Nothing about who holds what leaks from that sharing: membership lives in
  `OnePlaylist.Library.PlaylistItem`, which is user-owned.

  ## It is not a `Music.Track`, and converts to one

  `OnePlaylist.Music.Track` is the currency the matching engine deals in and is
  deliberately provider-shaped: it carries a `provider` and a `provider_id`. A
  recording is the stored form. `to_track/1` is the boundary, and it reports
  `provider: :library` with this row's id — which is what lets the library be an
  ordinary destination whose ids mean something to `Runner`'s snapshot-and-diff.
  """

  use Ecto.Schema
  use Bond

  import Ecto.Changeset

  alias OnePlaylist.Music.Isrc
  alias OnePlaylist.Music.Track

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "library_recordings" do
    field :isrc, :string
    field :musicbrainz_recording_id, Ecto.UUID

    # Which release the album, barcode and cover came from. A recording appears
    # on many, and they disagree — see the migration, and
    # `OnePlaylist.Library.Enrichment` for how one is chosen.
    field :musicbrainz_release_id, Ecto.UUID

    field :title, :string
    field :artists, {:array, :string}, default: []
    field :album, :string
    field :album_upc, :string
    field :track_number, :integer
    field :volume_number, :integer
    field :version, :string
    field :duration_seconds, :integer
    field :explicit, :boolean
    field :artwork_url, :string

    # Where it came from the first time it was seen. Not an identity — the same
    # recording arrives from several services — but it says which catalogue
    # wrote the metadata, which is worth knowing when two services disagree
    # about a title.
    field :origin_provider, :string
    field :origin_provider_id, :string

    # When MusicBrainz was last asked about this recording, whether or not it
    # had anything to say. `nil` means never asked, which is what
    # `OnePlaylist.Library.Enrichment.due/1` looks for — an unanswerable
    # recording must not be re-asked about nightly forever.
    field :enriched_at, :utc_datetime_usec

    # Why enrichment did not identify this recording, and how much it had to
    # work with. Bookkeeping rather than a fact about the music — see the
    # migration and `OnePlaylist.Library.Enrichment`.
    field :enrichment_outcome, Ecto.Enum,
      values: [:identified, :no_candidates, :declined, :unnameable, :identifier_disagreed]

    # This recording's ISRC names different music, caught by `enrich/1`'s
    # agreement check. Kept apart from `enrichment_outcome` because a disputed
    # code survives a later identification — the recording can be identified by
    # *name* while its ISRC stays wrong, and the outcome column would have
    # forgotten that.
    #
    # Read by `OnePlaylist.Library.Identities`, which refuses to anchor a
    # cross-service identity on a code already caught naming something else.
    field :isrc_disputed, :boolean, default: false

    field :enrichment_candidates, :integer

    # A fingerprint of the engine that decided this recording's outcome, so a
    # decline made under older rules can be offered back. See the migration and
    # `OnePlaylist.Library.Enrichment.engine/0`.
    field :enrichment_engine, :string

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(isrc musicbrainz_recording_id musicbrainz_release_id title artists album album_upc track_number
             volume_number version duration_seconds explicit artwork_url
             origin_provider origin_provider_id enriched_at enrichment_outcome
             enrichment_candidates enrichment_engine)a

  @doc """
  Builds a recording from a track that arrived from anywhere.

  The metadata is copied verbatim with one exception: the ISRC is **canonicalised
  on the way in**, because it is the column every lookup compares on and every
  lookup normalises its query. Stored as the source wrote it, a Roon export's
  lower-case `ussm11100234` would never equal the `USSM11100234` a later search
  asks for, and the library would silently store a second copy of every recording
  it already had — deduplication failing in the one place it is the whole point.
  A value that is not an ISRC at all is stored as `nil` rather than as junk that
  compares equal to other junk.

  Enrichment (§5, L4) is what improves the rest later; nothing here goes looking,
  because this runs inside a transfer and a MusicBrainz lookup at one request a
  second does not belong on that path.
  """
  # The one exception in the docstring above, stated as a law, because getting
  # it wrong is invisible. `Library.find_or_create/1` joins on the ISRC and
  # *only* on the ISRC — never on a title, because a wrong join is not undoable
  # by adding. So a code stored as the source wrote it, `ussm11100234`, never
  # equals the `USSM11100234` a later arrival normalises before asking, and the
  # library quietly stores a second copy of a recording it already has.
  #
  # Nothing raises. Deduplication simply stops working, in the one table whose
  # entire value is that it deduplicates — the compounding asset of
  # `docs/reference/domain.md` §5, silently not compounding.
  #
  # `Isrc.normalize/1` is idempotent, so this says "whatever came out is already
  # canonical", which is the property the join needs and is true of `nil` too.
  # Proven by mutation: passing `track.isrc` through unnormalised fires it on
  # any lower-case fixture.
  @post isrc_is_canonical:
          Isrc.normalize(Ecto.Changeset.get_field(result, :isrc)) ==
            Ecto.Changeset.get_field(result, :isrc)
  @spec from_track(Track.t()) :: Ecto.Changeset.t()
  def from_track(%Track{} = track) do
    change(%__MODULE__{}, %{
      isrc: Isrc.normalize(track.isrc),
      title: track.title,
      artists: track.artists,
      album: track.album,
      album_upc: track.album_upc,
      track_number: track.track_number,
      volume_number: track.volume_number,
      version: track.version,
      duration_seconds: track.duration_seconds,
      explicit: track.explicit,
      artwork_url: track.artwork_url,
      origin_provider: to_string(track.provider),
      origin_provider_id: track.provider_id
    })
    |> validate_number(:duration_seconds, greater_than_or_equal_to: 0)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = recording, attrs) do
    recording
    |> cast(attrs, @fields)
    |> validate_number(:duration_seconds, greater_than_or_equal_to: 0)
  end

  @doc """
  The recording as the matching engine and the adapters see it.

  `provider_id` is this row's own id, which is what makes a library track
  addressable the way a TIDAL id is — see the moduledoc.
  """
  # The sentence above, checked. `Providers.Library.playlist_track_ids/3`
  # reports these ids and `Runner`'s snapshot-and-diff compares against them, so
  # a track carrying anything else here is a transfer that cannot tell what the
  # destination already holds — every run adding every track again, reported as
  # a success. The same law `PlaylistItem.to_track/2` carries, at the other end
  # of the same identity.
  #
  # Proven by mutation: `provider_id: recording.musicbrainz_recording_id` fires
  # it, and is exactly the plausible edit — that field is also an identity, and
  # is the more "correct-looking" of the two.
  @post addressable_as_this_row: result.provider_id == recording.id
  @spec to_track(t()) :: Track.t()
  def to_track(%__MODULE__{} = recording) do
    %Track{
      provider: :library,
      provider_id: recording.id,
      isrc: recording.isrc,
      title: recording.title,
      artists: recording.artists || [],
      album: recording.album,
      album_upc: recording.album_upc,
      track_number: recording.track_number,
      volume_number: recording.volume_number,
      version: recording.version,
      duration_seconds: recording.duration_seconds,
      explicit: recording.explicit,
      artwork_url: recording.artwork_url
    }
  end
end
