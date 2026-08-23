defmodule OnePlaylist.Transfers.Source do
  @moduledoc """
  The tracks an uploaded playlist file parsed into.

  One row per transfer whose source is a file, written in the request that
  received the upload and read by the worker that runs the transfer.

  ## Why the tracks are here rather than fetched when the job runs

  A provider source is streamed when the worker runs, because the worker holds
  the user's provider credentials and can. A file source cannot work that way:
  `OnePlaylist.Storage` reaches Supabase as the signed-in user so the bucket
  policies apply, and a worker has no session to be — GoTrue refresh tokens live
  in the browser's cookie, not in this database. Reading the file from a job
  would mean the service key, and that bypasses every storage policy at once.

  So the file is parsed where there *is* a session, and the result lands here.

  The better half of that trade is the ordering rather than the privilege. A
  malformed file is reported while the person is still looking at the upload
  form, naming the row that is wrong, instead of failing a background job they
  have to go and find.

  The uploaded file itself still goes to Storage, on `transfers.source_playlist_id`.
  This is the working copy; that is the record of what was actually uploaded.
  """

  use Ecto.Schema
  use Bond

  import Ecto.Changeset

  alias OnePlaylist.Music.Track

  @typedoc "The parsed source of a file-backed transfer."
  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type :binary_id

  schema "transfer_sources" do
    field :transfer_id, :binary_id, primary_key: true
    field :user_id, :binary_id
    field :tracks, {:array, :map}
    field :format, :string
    field :track_count, :integer

    timestamps(type: :utc_datetime_usec)
  end

  # `track_count` is stored rather than derived so a listing can say "58 tracks"
  # without loading the tracks — which is the whole reason this is a separate
  # table. That makes it a number that can disagree with the thing it counts, so
  # the database has a check constraint and this has an invariant: two places,
  # because the constraint catches a bad write and this catches a bad value
  # before it becomes one.
  @invariant count_matches_the_tracks:
               is_nil(subject.tracks) or subject.track_count == length(subject.tracks)

  @required ~w(transfer_id user_id tracks format track_count)a

  @doc """
  Builds a source row from parsed tracks.

  `track_count` is derived here rather than accepted, because a caller with a
  list in hand has no business being trusted to count it.
  """
  @spec changeset(Ecto.UUID.t(), Ecto.UUID.t(), [Track.t()], atom()) :: Ecto.Changeset.t()
  def changeset(transfer_id, user_id, tracks, format) when is_list(tracks) do
    %__MODULE__{}
    |> cast(
      %{
        transfer_id: transfer_id,
        user_id: user_id,
        tracks: Enum.map(tracks, &Track.to_map/1),
        format: to_string(format),
        track_count: length(tracks)
      },
      @required
    )
    |> validate_required(@required)
    |> validate_length(:tracks, min: 1)
    |> foreign_key_constraint(:transfer_id)
  end

  @doc """
  The stored tracks, back as `OnePlaylist.Music.Track` structs, in file order.
  """
  @spec tracks(t()) :: [Track.t()]
  def tracks(%__MODULE__{tracks: tracks}), do: Enum.map(tracks, &Track.from_map/1)
end
