defmodule OnePlaylist.Library.Playlist do
  @moduledoc """
  A playlist One Playlist holds itself, owned by one user.

  The user-owned half of the library — `OnePlaylist.Library.Recording` is the
  half that belongs to nobody. See `docs/reference/domain.md` §5.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias OnePlaylist.Music

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "library_playlists" do
    field :user_id, Ecto.UUID
    field :name, :string
    field :description, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = playlist, attrs) do
    playlist
    |> cast(attrs, [:user_id, :name, :description])
    |> validate_required([:user_id, :name])
    |> validate_length(:name, min: 1)
  end

  @doc """
  The playlist as every adapter reports one.

  `track_count` is passed in rather than derived here: counting is a query, and
  the caller doing it once for a page of playlists beats this doing it per row.
  """
  @spec to_playlist(t(), non_neg_integer() | nil) :: Music.Playlist.t()
  def to_playlist(%__MODULE__{} = playlist, track_count \\ nil) do
    %Music.Playlist{
      provider: :library,
      provider_id: playlist.id,
      name: playlist.name,
      description: playlist.description,
      track_count: track_count,
      created_at: playlist.inserted_at,
      updated_at: playlist.updated_at,
      owned: true
    }
  end
end
