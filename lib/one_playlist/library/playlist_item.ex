defmodule OnePlaylist.Library.PlaylistItem do
  @moduledoc """
  One track in one library playlist, and the user's own copy of it.

  Not a pointer. An item carries what its source said the track was — title,
  credit, album, version, length, ISRC — and its owner may correct any of it.
  The `recording_id` beside that is a *link* to what the catalogue knows: the
  MusicBrainz identity, the release, the cover.

  ## Why the metadata lives here rather than on the recording

  A recording belongs to nobody and is shared by everyone who has it, which is
  what makes it the asset `docs/reference/domain.md` §5 argues for. That is also
  why it cannot be the place a person's corrections go: fixing a credit on your
  playlist would change everybody's.

  Splitting them fixed three things that were not about editing at all — see the
  migration `playlist_items_own_their_metadata`. The shortest of them: a wrong
  match used to *destroy* a track, because deciding two arrivals were one
  recording was the same act as deciding what the playlist held. Now the item
  survives its own mis-linking.

  `OnePlaylist.Transfers.TransferItem` has always worked this way, keeping
  `source_title` beside `destination_title`, because a report has to show what
  was asked for even when the answer is wrong. A playlist item is that object
  with a longer life.

  ## What is still the recording's

  Cover art, the barcode, the MusicBrainz identity — everything a catalogue
  knows and a source does not. `to_track/2` is where the two halves are put back
  together, and it says which side wins each field.

  `position` is a dense integer and deliberately not unique: a playlist may hold
  the same recording twice, and appending wants `max(position) + 1`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias OnePlaylist.Library.Recording
  alias OnePlaylist.Music.Track

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "library_playlist_items" do
    field :playlist_id, Ecto.UUID
    field :user_id, Ecto.UUID
    field :recording_id, Ecto.UUID
    field :position, :integer

    # The source's account of the track, and its owner's to correct.
    field :title, :string
    field :artists, {:array, :string}, default: []
    field :album, :string
    field :version, :string
    field :duration_seconds, :integer
    field :isrc, :string

    timestamps(type: :utc_datetime_usec)
  end

  @owned ~w(title artists album version duration_seconds isrc)a

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = item, attrs) do
    item
    |> cast(attrs, [:playlist_id, :user_id, :recording_id, :position | @owned])
    # `recording_id` is deliberately absent: an item may say it does not know
    # what recording it is, which is the whole of
    # `playlist_item_link_is_breakable`.
    |> validate_required([:playlist_id, :user_id, :position, :title])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:duration_seconds, greater_than_or_equal_to: 0)
  end

  @doc """
  The fields an item's owner may correct.

  Public because the edit form and its tests both need to agree with the
  changeset about what is editable, and a list written out twice is a list that
  drifts.
  """
  @spec owned() :: [atom()]
  def owned, do: @owned

  @doc """
  The item and its recording, as one track.

  Each field comes from the side that knows it:

    * **the item** — title, credit, album and version, because those are what
      the source said and what its owner may have corrected. A catalogue
      disagreeing about a title is not a reason to overrule the person whose
      playlist it is.
    * **the recording** — cover art and barcode, which a source rarely carries
      and a catalogue always does.
    * **either, item first** — ISRC and length. The item's own claim wins where
      it has one, and the recording fills the gap where enrichment has since
      learned something the source never knew.

  `provider_id` is the **recording's** id, not the item's, and that is
  deliberate: it is what `OnePlaylist.Providers.Library.playlist_track_ids/3`
  reports and therefore what a transfer diffs against. Two items of one
  recording produce two tracks with one id, which is exactly what the counting
  in `Transfers.Runner.write_missing/5` expects.
  """
  @spec to_track(t(), Recording.t() | nil) :: Track.t()
  def to_track(%__MODULE__{} = item, recording) do
    %Track{
      provider: :library,
      provider_id: item.recording_id,
      title: item.title,
      artists: item.artists || [],
      album: item.album,
      version: item.version,
      isrc: item.isrc,
      duration_seconds: item.duration_seconds
    }
    |> with_recording(recording)
  end

  @doc """
  Lays what a catalogue knows over a track that already says what it is.

  Split out of `to_track/2` because there are two callers and only one of them
  holds an item. A live enrichment update carries the **recording** and the row
  it redraws already has its merged track, so it needs the second half of the
  merge without the first.

  Doing that by rebuilding from the recording alone was a real bug: a person who
  had corrected *Throw Your Arms Around Me*'s album to *Crucible* watched it
  revert to *Crucible - The Songs of Hunters & Collectors* the moment enrichment
  finished, and come back on the next page load. The row was briefly showing the
  recording's account of the track instead of the item's.

  Idempotent, which is what makes it safe to apply to an already-merged track:
  every field it fills is one the track had no value for.
  """
  @spec with_recording(Track.t(), Recording.t() | nil) :: Track.t()
  def with_recording(%Track{} = track, nil), do: track

  def with_recording(%Track{} = track, %Recording{} = recording) do
    %Track{
      track
      | isrc: track.isrc || recording.isrc,
        duration_seconds: track.duration_seconds || recording.duration_seconds,
        album_upc: recording.album_upc,
        artwork_url: recording.artwork_url,
        explicit: recording.explicit
    }
  end
end
