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

  # Possible since Bond 1.15.0, which made `@invariant` usable on an
  # `Ecto.Schema` at all.
  #
  # Deliberately one assertion, and deliberately not the obvious ones. The
  # field-presence laws — a `user_id`, a non-blank `access_token` — are true of
  # every *persisted* connection and false of `%Connection{}`, which is exactly
  # what `Providers.connect/3` hands to `changeset/2`. An invariant that fails on
  # the module's own construction path is the base-case mistake Meyer warns
  # about, and no amount of it being "morally true of real rows" fixes that.
  #
  # What is left is genuinely a property of every value. The counter is how "this
  # connection keeps failing" is eventually noticed; a negative one means no
  # threshold ever triggers, and nothing raises — the signal simply never
  # arrives. `record_failure/2`'s `counter_advances_by_one` is the matching
  # *transition* law and stays where it is.
  @invariant failures_never_negative: subject.consecutive_failures >= 0

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

  # How each service writes its own name. Facts rather than styling: TIDAL
  # capitalises itself, Apple Music is two words, and rendering them from the
  # atom would produce "Apple_music" or "Tidal" — neither of which is the
  # service's name.
  @display_names %{
    spotify: "Spotify",
    apple_music: "Apple Music",
    youtube_music: "YouTube Music",
    tidal: "TIDAL",
    deezer: "Deezer",
    plex: "Plex",
    jellyfin: "Jellyfin",
    navidrome: "Navidrome",
    subsonic: "Subsonic",
    # Not a service, and here because a transfer's *source* can be one — see
    # `OnePlaylist.Transfers.Transfer.source_provider/0`. Anywhere a source is
    # shown, this is the other thing it might say.
    file: "File"
  }

  @doc """
  The name a service uses for itself.

  For display anywhere a provider is named. Falls back to the atom for anything
  unrecognised, so a provider added to `@providers` and forgotten here shows up
  as its own name rather than as blank.

      iex> alias OnePlaylist.Providers.Connection
      iex> {Connection.display_name(:tidal), Connection.display_name(:apple_music)}
      {"TIDAL", "Apple Music"}
      iex> Connection.display_name(:file)
      "File"
  """
  # No connection to check, and none to build.
  @bond_warn_skipped_invariants false
  @spec display_name(atom()) :: String.t()
  def display_name(provider), do: Map.get(@display_names, provider, to_string(provider))

  @doc "Every provider this application knows how to connect to."
  # No connection to check: this answers what the `provider` field may hold,
  # which is a fact about the type rather than about a value of it.
  @bond_warn_skipped_invariants false
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
  def changeset(%__MODULE__{} = connection, attrs) do
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
  Whether this connection was granted a scope.

  A question about a connection that was being asked inside
  `OnePlaylist.Providers.Tidal`, spelled `"search.read" in (connection.scopes || [])`.
  It belongs here: `scopes` is this struct's field, the `|| []` was working
  around this struct's nilable column, and the next OAuth provider will ask the
  same question.

  Not hypothetical. The TIDAL account connected to this project had to be
  re-authorized to grant `search.read`, because without it TIDAL answers
  `400 INVALID_RESOURCE_ID` — an error naming neither scopes nor the parameter
  it is really complaining about. Asking before calling is what turns that into
  a message telling the user to reconnect.

      iex> alias OnePlaylist.Providers.Connection
      iex> Connection.grants?(%Connection{scopes: ["playlists.read", "search.read"]}, "search.read")
      true
      iex> Connection.grants?(%Connection{scopes: ["playlists.read"]}, "search.read")
      false

  A connection with no recorded scopes grants nothing, rather than raising —
  the column is nilable, and an older row may predate scope capture entirely:

      iex> alias OnePlaylist.Providers.Connection
      iex> Connection.grants?(%Connection{scopes: nil}, "search.read")
      false
  """
  # Stated because the *absence* of a scope has to be distinguishable from a
  # connection that never recorded any. Answering `true` for an unknown scope
  # set would send the call anyway and surface TIDAL's unhelpful 400; answering
  # `false` sends the user to reconnect, which is the action that fixes it.
  @post unrecorded_scopes_grant_nothing: is_nil(connection.scopes) ~> (result == false)
  @spec grants?(t(), String.t()) :: boolean()
  def grants?(%__MODULE__{} = connection, scope) when is_binary(scope),
    do: scope in (connection.scopes || [])

  @doc """
  Whether the connection can be used to call the provider right now.

  Deliberately does not consider expiry: an expired access token is refreshable,
  which is a different situation from a revoked one.
  """
  @spec usable?(connection :: %__MODULE__{}) :: boolean()
  # `token != ""` is load-bearing, not defensive. An empty string is a binary, so
  # the guard alone answered `true` for a connection carrying no credential at
  # all — `fetch_usable_connection/2` handed it back as healthy and every call
  # 401'd, blaming the provider.
  #
  # This is deliberately *not* an `@invariant` forbidding a blank token. Such a
  # row is reachable — `OnePlaylist.Providers.SubsonicCredentials` documents the
  # same hazard from the other side, and `providers_test.exs` pins that a blank
  # refresh token must fail cleanly rather than crash, because "a contract does
  # not retroactively clean a database". Answering `false` sends the user down
  # the reconnect path; raising would take the request down instead.
  def usable?(%__MODULE__{status: :active, access_token: token})
      when is_binary(token) and token != "",
      do: true

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
  # The bare parameter is deliberate and must stay: this predicate is named by
  # the preconditions on `expired?/2` and `needs_refresh?/3`, and a function
  # written to be called *from* an assertion has to answer rather than raise.
  # Matching `%__MODULE__{}` here would earn the entry check Bond is asking for
  # and cost the ability to return `false` — see the same note on
  # `OnePlaylist.Providers.Tokens.well_formed?/1`.
  @bond_warn_skipped_invariants false
  @spec now_after_creation?(t(), DateTime.t()) :: boolean()
  def now_after_creation?(connection, now) do
    (is_struct(now, DateTime) and is_struct(connection.inserted_at, DateTime))
    ~> (DateTime.compare(now, connection.inserted_at) != :lt)
  end
end
