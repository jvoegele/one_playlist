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
  # `use Bond` makes the predicate vocabulary available inside assertions; this
  # brings `~>` into ordinary function bodies too, so a predicate written to
  # serve a contract can be expressed the same way the contract is.
  #
  # Scoped to `~>` on purpose. `Bond.Predicates` also exports `|||`, which is
  # exclusive-or despite reading as "or" — Bond's own guides flag it as a trap.
  # It has no business being in scope in code that is not an assertion.
  import Bond.Predicates, only: [~>: 2]

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
    # The provider's idea of the account's country. Most TIDAL endpoints take it
    # as `countryCode` and return different catalogue availability without it.
    field :country, :string

    # Where a self-hosted provider lives. `nil` for every hosted service, whose
    # base URL is a constant in config — a TIDAL connection carrying one would
    # be a bug rather than a customisation.
    field :server_url, :string

    # The secret presented on every call. For an OAuth provider that is a bearer
    # token with an expiry beside it; for Subsonic it is the account **password**,
    # which never expires and has no refresh token — see `needs_refresh?/3`,
    # which answers `false` for a nil expiry precisely so that case needs no
    # special handling anywhere else.
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
  @optional ~w(display_name country server_url access_token refresh_token access_token_expires_at
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
  # No `is_boolean(result)` postcondition here: it restates the @spec, which
  # Dialyzer checks for free, and Bond.Coverage confirmed it could never fail.
  @pre valid_now: is_struct(now, DateTime)
  @pre now_after_creation: now_after_creation?(connection, now)
  @spec expired?(connection :: %__MODULE__{}, now :: DateTime.t()) :: boolean()
  def expired?(%__MODULE__{access_token_expires_at: nil} = _connection, _now), do: false

  def expired?(%__MODULE__{access_token_expires_at: expires_at} = _connection, now),
    do: DateTime.compare(expires_at, now) != :gt

  @doc """
  Whether the access token should be refreshed `skew` before it actually
  expires.

  Refreshing early is the whole point: a token that expires between our check
  and the provider receiving the request is indistinguishable from a revoked
  one at the call site.
  """
  @pre valid_now: is_struct(now, DateTime)
  @pre now_after_creation: now_after_creation?(connection, now)
  @pre non_negative_skew: is_integer(skew_seconds) and skew_seconds >= 0
  # The upper bound is the assertion that earns its place. A skew is seconds,
  # and the classic way to get it wrong is to pass milliseconds: `300_000`
  # instead of `300`. Nothing about that is a type error, and nothing fails —
  # every token simply looks due for refresh on every call, so the application
  # quietly hammers the provider with refreshes it does not need until the rate
  # limiter or the breaker notices.
  #
  # A day is the ceiling because access tokens are short-lived by construction:
  # TIDAL's last four hours. A skew longer than any plausible token lifetime
  # means `needs_refresh?/3` is a constant function, which is never intended.
  @pre skew_under_a_day: skew_seconds <= 86_400
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
  @spec usable?(connection :: %__MODULE__{}) :: boolean()
  def usable?(%__MODULE__{status: :active, access_token: token}) when is_binary(token), do: true
  def usable?(%__MODULE__{}), do: false

  @doc """
  Whether `now` is a coherent clock reading for `connection`.

  Callers do not normally need this: passing `DateTime.utc_now()` satisfies it.
  It is public and documented because `expired?/2` and `needs_refresh?/3` name
  it in a **precondition**, and a precondition is an obligation on the caller —
  one they can only discharge if they can see and evaluate it. Bond enforces the
  callable half of that (it warns when a precondition calls a private function,
  per Meyer's Precondition Availability rule); the visible half is this docstring.

  A `now` earlier than the connection's `inserted_at` is rejected: "was this
  token expired at a moment before the connection existed" has no answer, so
  such a value means the caller passed the wrong one. The usual culprits are an
  epoch default or a badly parsed timestamp — neither is a type error, and both
  make every token look expired.

      iex> alias OnePlaylist.Providers.Connection
      iex> connection = %Connection{inserted_at: ~U[2026-08-01 00:00:00.000000Z]}
      iex> Connection.now_after_creation?(connection, ~U[2026-08-22 12:00:00.000000Z])
      true
      iex> Connection.now_after_creation?(connection, ~U[1970-01-01 00:00:00.000000Z])
      false

  A connection that was never persisted has no `inserted_at`, which is a
  legitimate state, so any clock is accepted:

      iex> alias OnePlaylist.Providers.Connection
      iex> Connection.now_after_creation?(%Connection{}, ~U[1970-01-01 00:00:00.000000Z])
      true
  """
  #
  # Stated as the implication it is, which is what the precondition means:
  # *if* both operands are DateTimes, *then* `now` may not precede creation.
  #
  # `~>` is a macro and short-circuits, so the consequent is never evaluated
  # when the antecedent is false — which is what makes this safe. Its named
  # equivalent `implies?/2` is a plain function and would evaluate both sides,
  # calling `DateTime.compare(now, nil)` and raising, turning an assertion that
  # should be vacuously true into one that cannot be evaluated at all. That
  # distinction is easy to miss: the two are documented as behaving identically,
  # and for total operands they do.
  #
  # `inserted_at` is nil for a connection that was never persisted, which is a
  # legitimate state, so it is satisfied rather than rejected.
  @spec now_after_creation?(t(), DateTime.t()) :: boolean()
  def now_after_creation?(connection, now) do
    (is_struct(now, DateTime) and is_struct(connection.inserted_at, DateTime))
    ~> (DateTime.compare(now, connection.inserted_at) != :lt)
  end
end
