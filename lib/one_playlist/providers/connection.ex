defmodule OnePlaylist.Providers.Connection do
  @moduledoc """
  A user's authorization to act on their behalf at one music service.

  The access and refresh tokens are `OnePlaylist.Encrypted.Binary`, so they are
  ciphertext in Postgres and plaintext only inside this application. Nothing
  here may be logged, inspected into an error context, or serialized — see
  `inspect/2` below and the `:redact` configuration in `config/config.exs`.
  """

  use Ecto.Schema
  use Bond

  import Ecto.Changeset

  alias OnePlaylist.Encrypted

  @providers ~w(spotify apple_music youtube_music tidal deezer plex jellyfin navidrome subsonic)a
  @statuses ~w(active expired revoked reauth_required)a

  @typedoc "A user's authorization at one music service."
  @type t :: %__MODULE__{}

  @typedoc "A music service this application can connect to."
  @type provider ::
          :spotify
          | :apple_music
          | :youtube_music
          | :tidal
          | :deezer
          | :plex
          | :jellyfin
          | :navidrome
          | :subsonic

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Inspect, only: [:id, :user_id, :provider, :status, :access_token_expires_at]}
  schema "provider_connections" do
    field :user_id, :binary_id
    field :provider, Ecto.Enum, values: @providers
    field :provider_user_id, :string
    field :display_name, :string

    field :access_token, Encrypted.Binary, redact: true
    field :refresh_token, Encrypted.Binary, redact: true
    field :access_token_expires_at, :utc_datetime_usec

    field :scopes, {:array, :string}, default: []
    field :status, Ecto.Enum, values: @statuses, default: :active

    field :last_refreshed_at, :utc_datetime_usec
    field :last_error, :string
    field :consecutive_failures, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every provider this application knows how to connect to."
  @spec providers() :: [provider()]
  def providers, do: @providers

  @required ~w(user_id provider provider_user_id)a
  @optional ~w(display_name access_token refresh_token access_token_expires_at
               scopes status last_refreshed_at last_error consecutive_failures)a

  @doc """
  Builds a changeset for creating or updating a connection.

  Note what is *not* validated here: that the tokens work. That is only knowable
  by calling the provider, so it is the refresh path's job, not the changeset's.
  """
  def changeset(connection, attrs) do
    connection
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:consecutive_failures, greater_than_or_equal_to: 0)
    |> validate_length(:provider_user_id, min: 1)
    |> unique_constraint([:user_id, :provider])
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Whether the access token has expired as of `now`.

  A connection with no recorded expiry is *not* treated as expired: some
  providers issue tokens that do not expire, and guessing otherwise would send
  us refreshing on every call.
  """
  @pre valid_now: is_struct(now, DateTime)
  @post total: is_boolean(result)
  @spec expired?(t :: %__MODULE__{}, now :: DateTime.t()) :: boolean()
  def expired?(%__MODULE__{access_token_expires_at: nil}, _now), do: false

  def expired?(%__MODULE__{access_token_expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt

  @doc """
  Whether the access token should be refreshed `skew` before it actually
  expires.

  Refreshing early is the whole point: a token that expires between our check
  and the provider receiving the request is indistinguishable from a revoked
  one at the call site.
  """
  @pre valid_now: is_struct(now, DateTime)
  @pre non_negative_skew: is_integer(skew_seconds) and skew_seconds >= 0
  # An *active* connection whose token has already expired must be refreshed.
  #
  # Stated as an implication rather than an equality because the converse is
  # false: a token expiring in ten minutes needs no refresh at a 60s skew.
  #
  # The `status == :active` half of the antecedent is not decoration — the first
  # clause deliberately returns `false` for an expired token on a connection
  # that needs re-authorization, because refreshing cannot revive a dead grant.
  # Bond rejected the weaker version of this postcondition on exactly that case.
  @post active_and_expired_must_refresh:
          (connection.status == :active and expired?(connection, now)) ~> result
  @spec needs_refresh?(
          connection :: %__MODULE__{},
          now :: DateTime.t(),
          skew_seconds :: non_neg_integer()
        ) ::
          boolean()
  def needs_refresh?(connection, now, skew_seconds \\ 60)

  # Bond requires the same top-level parameter names across every clause of a
  # contracted function, so these keep `skew_seconds` even while ignoring it.
  def needs_refresh?(%__MODULE__{status: status}, _now, _skew_seconds) when status != :active,
    do: false

  def needs_refresh?(%__MODULE__{access_token_expires_at: nil}, _now, _skew_seconds), do: false

  def needs_refresh?(%__MODULE__{} = connection, now, skew_seconds),
    do: expired?(connection, DateTime.add(now, skew_seconds, :second))

  @doc """
  Whether the connection can be used to call the provider right now.

  Deliberately does not consider expiry: an expired access token is refreshable,
  which is a different situation from a revoked one.
  """
  @post total: is_boolean(result)
  @spec usable?(connection :: %__MODULE__{}) :: boolean()
  def usable?(%__MODULE__{status: :active, access_token: token}) when is_binary(token), do: true
  def usable?(%__MODULE__{}), do: false
end
