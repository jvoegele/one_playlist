defmodule OnePlaylist.Library.Identity do
  @moduledoc """
  One recording, as one service knows it.

  A row of the identity spine — `docs/reference/domain.md` §5's L5. See the
  migration for why this hangs off a recording rather than off a pair of
  services, and `OnePlaylist.Library.Identities` for what may be written here.

  The snapshot fields describe the track *at that service*, which is not
  necessarily what the recording is called here: a service may title a track
  differently, and the report should show what the destination actually holds.
  """

  use Ecto.Schema
  use Bond

  import Ecto.Changeset

  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers.Connection

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "recording_identities" do
    field :recording_id, :binary_id

    # Derived, not restated. This list was written out once and then not widened
    # when Spotify arrived, which cost the spine every Spotify identity in
    # silence — see the migration `widen_identity_providers`. `file` is not in
    # `providers/0` at all, and `Identities.record/4` refuses it besides.
    field :provider, Ecto.Enum, values: Connection.providers()
    field :provider_id, :string

    field :title, :string
    field :artists, {:array, :string}, default: []
    field :album, :string
    field :artwork_url, :string
    field :duration_seconds, :integer

    field :strategy, :string
    field :score, :float

    field :first_seen_at, :utc_datetime_usec
    field :last_confirmed_at, :utc_datetime_usec
  end

  @fields ~w(recording_id provider provider_id title artists album artwork_url
             duration_seconds strategy score first_seen_at last_confirmed_at)a

  @required ~w(recording_id provider provider_id strategy score
               first_seen_at last_confirmed_at)a

  # An identity that names no track at the service is not an identity, and is
  # worse than absent: `recall/3` would answer with a track whose `provider_id`
  # is empty, the destination would be asked to add nothing, and the report
  # would claim a match that cannot exist.
  #
  # This is the *only* statement of that rule — `changeset/2` deliberately does
  # not also validate the length. Two guards for one law leave neither
  # falsifiable, which `docs/reference/contracts.md` names as the mistake to
  # avoid; with one, a changeset carrying an empty id fires it.
  @invariant names_a_track_at_the_service:
               is_nil(subject.provider_id) or subject.provider_id != ""

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = identity, attrs) do
    identity
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> validate_number(:score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end

  @doc """
  The identity as the destination's own track.

  What makes recall free: everything a transfer needs to add the track and
  report what it added, without asking the service anything. See the migration's
  note on the snapshot columns.
  """
  @spec to_track(t()) :: Track.t()
  def to_track(%__MODULE__{} = identity) do
    %Track{
      provider: identity.provider,
      provider_id: identity.provider_id,
      title: identity.title,
      artists: identity.artists || [],
      album: identity.album,
      artwork_url: identity.artwork_url,
      duration_seconds: identity.duration_seconds
    }
  end
end
