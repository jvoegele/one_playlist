defmodule OnePlaylist.Accounts.Session do
  @moduledoc """
  A signed-in user, as GoTrue issued them.

  ## Why this is ours and not `Supabase.Auth.Session`

  The SDK has a perfectly good session struct, and this deliberately is not it.
  This value is written into the **session cookie**, and a cookie is a wire
  format: it outlives the deploy that wrote it. Putting a third-party struct in
  there makes a dependency upgrade a compatibility event — rename a field in
  `supabase_auth` and every live session either breaks or, worse, deserializes
  into something that still pattern-matches but is missing a key.

  So the cookie carries a struct this repository owns, with four fields it
  actually needs, and `from_gotrue/1` and `to_gotrue/1` are the only places that
  know the SDK's shape. `OnePlaylist.Accounts` converts at the boundary.

  It is also a smaller thing to store. `Supabase.Auth.Session` carries
  `provider_token` and `provider_refresh_token` — the third-party credentials
  `CLAUDE.md` says this application must capture, encrypt and persist *itself* —
  and those belong in `OnePlaylist.Providers.Connection`, encrypted at rest, not
  in a cookie.

  ## What the invariant is for

  Every assertion below describes a value that would be **stored happily and
  fail later**, which `docs/reference/contracts.md` names as the shape worth
  contracting. A session missing its refresh token is the sharpest: it works
  perfectly for up to an hour and then signs the user out mid-transfer, with
  nothing in the logs pointing at the moment it was built.

  Freshness is deliberately *not* an invariant, for the reason
  `OnePlaylist.Providers.Tokens` gives: a session that was valid when it was
  built becomes stale by the clock moving, and an invariant that accused it
  would be accusing correct code. Freshness is `fresh?/2` and `needs_refresh?/3`.

  ## Both tokens are redacted

  `@derive Inspect` keeps them out of `inspect/1`. This struct is assigned onto
  a `Plug.Conn` and a LiveView socket, both of which are printed in full by any
  crash report — and unlike `OnePlaylist.Providers.Connection`, there is no
  encrypted column standing behind it.
  """

  use Bond

  alias Supabase.Auth.Session, as: GoTrueSession
  alias Supabase.Auth.User, as: GoTrueUser

  # Access tokens are short-lived by design (`jwt_expiry = 3600` locally), so a
  # session is refreshed well before it expires rather than after it fails. Sixty
  # seconds covers clock skew between this host and GoTrue plus the round trip.
  @refresh_skew_seconds 60

  @derive {Inspect, only: [:user_id, :email, :expires_at]}
  defstruct user_id: nil, email: nil, access_token: nil, refresh_token: nil, expires_at: nil

  @typedoc """
  A `Supabase.Auth.Session` struct carrying only the fields we hold.

  Named rather than written inline because the distinction from
  `Supabase.Auth.Session.t()` is the point — see `to_gotrue/1` — and because a
  struct literal in a `@spec` is what Credo warns about while `t()` is what
  Dialyzer rejects. A type alias is the answer both accept.
  """
  @type partial_gotrue_session :: %GoTrueSession{}

  @typedoc "A signed-in user's GoTrue session."
  @type t :: %__MODULE__{
          user_id: String.t() | nil,
          email: String.t() | nil,
          access_token: String.t() | nil,
          refresh_token: String.t() | nil,
          expires_at: DateTime.t() | nil
        }

  # `user_id` is the whole point of the session: it is the foreign key every
  # `provider_connections` and `transfers` row hangs off, and the `sub` claim
  # that RLS policies read through `auth.uid()`. A blank one would scope queries
  # to nobody and silently return empty lists rather than failing.
  @invariant user_id_present: is_binary(subject.user_id) and subject.user_id != "",
             # A blank access token is accepted, looks signed in, and 401s on the
             # next GoTrue call with an error that blames the service.
             access_token_present: is_binary(subject.access_token) and subject.access_token != "",
             # Unlike a provider's OAuth response, where a missing refresh token
             # is a legitimate shape, GoTrue always issues one. Absent, the
             # session cannot be renewed and simply dies at `expires_at` — the
             # slow, silent failure this contract exists to catch at the source.
             refresh_token_present:
               is_binary(subject.refresh_token) and subject.refresh_token != "",
             # A nil expiry does not read as "expires soon", it reads as *never*:
             # `needs_refresh?/3` would answer `false` forever and the session
             # would be renewed exactly never.
             expiry_is_a_timestamp: is_struct(subject.expires_at, DateTime)

  @doc """
  Whether a value is a structurally well-formed session.

  The invariant's law in a form other modules' assertions can use, and the form
  `OnePlaylistWeb.UserAuth` validates a cookie with — a cookie written by an
  older deploy is *data from outside*, so it is checked rather than trusted.

  Takes a bare parameter rather than `%__MODULE__{} = session` on purpose: Bond
  attaches no entry check to it, so it answers the same way inside an assertion
  as outside one, and can return `false` instead of raising. See the same note
  on `OnePlaylist.Providers.Tokens.well_formed?/1`.

      iex> alias OnePlaylist.Accounts.Session
      iex> Session.well_formed?(:not_a_session)
      false
      iex> Session.well_formed?(%Session{user_id: "u", access_token: "at", refresh_token: "rt", expires_at: ~U[2030-01-01 00:00:00Z]})
      true
  """
  @bond_warn_skipped_invariants false
  @spec well_formed?(term()) :: boolean()
  def well_formed?(session) do
    is_struct(session, __MODULE__) and
      is_binary(session.user_id) and session.user_id != "" and
      is_binary(session.access_token) and session.access_token != "" and
      is_binary(session.refresh_token) and session.refresh_token != "" and
      is_struct(session.expires_at, DateTime)
  end

  @doc """
  Builds a session from what GoTrue returned.

  Raises `Bond.InvariantError` rather than answering an error tuple: every field
  it reads is one GoTrue documents as always present, so an absence is the SDK
  or the service behaving differently than believed, not a user mistake.

  `expires_at` is a Unix timestamp on the wire and a `DateTime` here, converted
  once at the boundary. GoTrue sends both `expires_in` (a duration) and
  `expires_at` (an instant); the instant is preferred because it is GoTrue's own
  clock rather than ours plus a guess about how long the response took to arrive.
  """
  @spec from_gotrue(GoTrueSession.t(), DateTime.t()) :: t()
  def from_gotrue(%GoTrueSession{} = session, now \\ DateTime.utc_now()) do
    %__MODULE__{
      user_id: session.user && session.user.id,
      email: session.user && session.user.email,
      access_token: session.access_token,
      refresh_token: session.refresh_token,
      expires_at: expires_at(session, now)
    }
  end

  defp expires_at(%GoTrueSession{expires_at: at}, _now) when is_integer(at) and at > 0 do
    DateTime.from_unix!(at)
  end

  defp expires_at(%GoTrueSession{expires_in: in_seconds}, now) when is_integer(in_seconds) do
    DateTime.add(now, in_seconds, :second)
  end

  defp expires_at(_session, now), do: now

  @doc """
  Rebuilds the SDK's session struct, for calls that need one.

  Only `access_token` and `refresh_token` are load-bearing — `Supabase.Auth`
  reads those and nothing else from the sessions it is handed — so the rest is
  filled to keep the struct valid rather than because anything consults it.

  The embedded user is filled from what we hold rather than left `nil`, since
  `Supabase.Auth.Session.t()` declares it non-nullable.

  The return is specced as the **struct** rather than as
  `Supabase.Auth.Session.t()`, and the difference is a deliberate piece of
  honesty. That type describes a session as GoTrue sends it, with a dozen
  further fields — `aud`, `created_at`, `is_anonymous` — that we do not have and
  would have to invent. This produces a struct carrying the two credentials its
  single caller reads, and says so, rather than claiming a completeness it does
  not have.
  """
  @spec to_gotrue(t()) :: partial_gotrue_session()
  def to_gotrue(%__MODULE__{} = session) do
    %GoTrueSession{
      access_token: session.access_token,
      refresh_token: session.refresh_token,
      expires_at: DateTime.to_unix(session.expires_at),
      expires_in: max(DateTime.diff(session.expires_at, DateTime.utc_now(), :second), 0),
      token_type: "bearer",
      user: %GoTrueUser{id: session.user_id, email: session.email}
    }
  end

  @doc """
  Whether the access token is still valid at `now`.

      iex> alias OnePlaylist.Accounts.Session
      iex> session = %Session{user_id: "u", access_token: "at", refresh_token: "rt", expires_at: ~U[2030-01-01 00:00:00Z]}
      iex> {Session.fresh?(session, ~U[2029-12-31 23:00:00Z]), Session.fresh?(session, ~U[2030-01-01 00:00:01Z])}
      {true, false}
  """
  @spec fresh?(t(), DateTime.t()) :: boolean()
  def fresh?(%__MODULE__{} = session, now \\ DateTime.utc_now()) do
    DateTime.after?(session.expires_at, now)
  end

  @doc """
  Whether the session should be renewed now, allowing for skew and round trip.

  Deliberately answers `true` *before* the token actually expires. Waiting for
  `fresh?/2` to turn false means the renewal races the failure it exists to
  prevent — and loses, for any request already in flight.

      iex> alias OnePlaylist.Accounts.Session
      iex> session = %Session{user_id: "u", access_token: "at", refresh_token: "rt", expires_at: ~U[2030-01-01 00:00:00Z]}
      iex> Session.needs_refresh?(session, ~U[2029-12-31 23:59:30Z])
      true
      iex> Session.needs_refresh?(session, ~U[2029-12-31 23:00:00Z])
      false
  """
  # The same magnitude trap `Connection.needs_refresh?/3` carries, for the same
  # reason: a skew is seconds, and passing milliseconds — `300_000` for `300` —
  # is not a type error and nothing fails. Every session simply looks due on
  # every request, so the application re-authenticates against GoTrue on each
  # page load until its rate limiter notices. A day is the ceiling because a
  # GoTrue access token lives an hour.
  @pre skew_is_seconds: is_integer(skew) and skew >= 0 and skew <= 86_400
  @spec needs_refresh?(t(), DateTime.t(), non_neg_integer()) :: boolean()
  def needs_refresh?(
        %__MODULE__{} = session,
        now \\ DateTime.utc_now(),
        skew \\ @refresh_skew_seconds
      ) do
    not DateTime.after?(session.expires_at, DateTime.add(now, skew, :second))
  end
end
