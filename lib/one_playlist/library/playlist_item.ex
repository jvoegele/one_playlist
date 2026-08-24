defmodule OnePlaylist.Library.PlaylistItem do
  @moduledoc """
  One recording's place in one library playlist.

  The join that makes the recording store shareable: a recording belongs to
  nobody, and *this* is where it becomes something a particular user has. See
  `docs/reference/domain.md` §5.

  `position` is a dense integer and deliberately not unique — a playlist may
  hold the same recording twice, and appending wants `max(position) + 1`. Hand
  reordering (§5, L2) will want fractional or lexicographic ranks instead.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "library_playlist_items" do
    field :playlist_id, Ecto.UUID
    field :user_id, Ecto.UUID
    field :recording_id, Ecto.UUID
    field :position, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = item, attrs) do
    item
    |> cast(attrs, [:playlist_id, :user_id, :recording_id, :position])
    |> validate_required([:playlist_id, :user_id, :recording_id, :position])
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end
end
