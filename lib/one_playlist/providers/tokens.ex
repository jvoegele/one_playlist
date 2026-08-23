defmodule OnePlaylist.Providers.Tokens do
  @moduledoc """
  A set of OAuth credentials as a provider just issued them.

  ## Why this is a struct

  It was a plain map, declared **twice** — once in
  `OnePlaylist.Providers.Adapter` and once in
  `OnePlaylist.Providers.Tidal.OAuth` — and the two declarations disagreed.
  `Adapter` marked `:refresh_token` and `:scopes` as *optional keys*; `OAuth`
  marked them as always present and possibly `nil`. Both were reasonable
  readings, and consumers split along the same line:

      # OnePlaylist.Providers.refresh/1 — defensive, keys may be absent
      tokens[:refresh_token] || connection.refresh_token

      # OnePlaylistWeb.TidalAuthController — direct, keys are always there
      refresh_token: tokens.refresh_token

  Both worked, because the only producer was TIDAL and TIDAL always sets every
  key. The second would have raised on the first adapter that did not — and
  "add a provider" is the roadmap, not a hypothetical. A struct settles it: the
  keys always exist, `nil` and `[]` are the absences, and dot access is correct
  everywhere.

  ## What the invariant is for, and what it is not for

  Three of the four assertions below catch a value that is *stored happily and
  fails later*, which is the worst shape a token bug can have — see
  `docs/reference/contracts.md`.

  What is deliberately **not** an invariant is freshness. A token set is fresh
  when it is issued and stale four hours later, without anything having changed
  about the struct. An invariant that consulted the clock would fail on a value
  that was perfectly valid when it was built, which
  `docs/reference/contracts.md` names as the worst thing a contract can do:
  accuse correct code. Freshness is a property of the *producer*, so it stays a
  postcondition on `c:OnePlaylist.Providers.Adapter.refresh_tokens/1`, and the
  question itself is `fresh?/2`.

  > #### Where the invariant actually fires {: .warning}
  >
  > On the way into and out of **this module's** public functions, and nowhere
  > else. An adapter that builds `%Tokens{}` by hand and returns it never calls
  > anything here, so the struct alone does not police the behaviour boundary —
  > the contracts on the `Adapter` callback still do that, and still must.
  > Building through `new/1` or `from_oauth_response/1` is what brings the
  > invariant to bear at construction.

  ## The tokens themselves are redacted

  `@derive Inspect` keeps both secrets out of `inspect/1`, which is what any
  crash report, `dbg/1` or stray `Logger` interpolation reaches for. This struct
  travels through a controller, a context and an Oban worker; the encryption on
  `OnePlaylist.Providers.Connection` protects them at rest and does nothing for
  a stack trace.
  """

  use Bond

  # Absences, not placeholders. `[]` for scopes because Meyer's base-case rule
  # asks that default field values satisfy the invariant, and because
  # `Enum.all?(nil, ...)` inside an assertion would raise
  # `Bond.AssertionEvaluationError` rather than fail honestly.
  #
  # `access_token` and `expires_at` cannot be given satisfying defaults — there
  # is no valid stand-in for "a real credential" — so a bare `%Tokens{}` does
  # violate the invariant, and that is the intended answer: an empty token set
  # is not a token set. Elixir always leaves `%Tokens{}` constructible, so the
  # entry check is what notices when somebody skips `new/1`.
  @derive {Inspect, only: [:expires_at, :scopes]}
  defstruct access_token: nil, refresh_token: nil, expires_at: nil, scopes: []

  @typedoc "OAuth credentials as issued by a provider."
  @type t :: %__MODULE__{
          access_token: String.t() | nil,
          refresh_token: String.t() | nil,
          expires_at: DateTime.t() | nil,
          scopes: [String.t()]
        }

  # A blank access token is stored, looks healthy, and 401s on the next call
  # with an error that points at the provider rather than at us. This is the law
  # the `:usable` postcondition on the adapter callback used to state, moved to
  # where the value is built.
  @invariant access_token_present: is_binary(subject.access_token) and subject.access_token != "",
             # A nil expiry does not mean "expires soon", it means **never**:
             # `Connection.needs_refresh?/3` answers `false` for it by design, so
             # a connection stored with one is never refreshed again and simply
             # dies at the real expiry, unrecoverably and silently.
             expiry_is_a_timestamp: is_struct(subject.expires_at, DateTime),
             # `""` is the value that slips past `refresh/1`'s
             # `tokens.refresh_token || connection.refresh_token` fallback,
             # because an empty string is truthy. It overwrites a working
             # refresh token with a useless one, satisfies that function's
             # `refresh_token_is_never_lost` postcondition (an empty string is
             # still a binary), and turns the next refresh into a *precondition
             # violation* rather than a handled error. Absent is fine; blank
             # never is.
             refresh_token_absent_or_real:
               is_nil(subject.refresh_token) or
                 (is_binary(subject.refresh_token) and subject.refresh_token != ""),
             # A type check, kept because violating it crashes somewhere else
             # and confusingly: `"search.read" in nil` raises
             # `Protocol.UndefinedError` from inside the matching engine, three
             # modules from the adapter that produced it.
             scopes_are_a_list: is_list(subject.scopes)

  @doc """
  Whether a value is a structurally well-formed token set.

  The same law the invariant above states, in a form other modules' assertions
  can use — and the reason a second form is needed at all is Meyer's **Assertion
  Evaluation rule** (*OOSC* 2nd ed., §11.14): while an assertion is being
  evaluated, calls made from it run with their own contracts suppressed.

  So an invariant cannot be reached from somewhere else's assertion. A
  `@post` on `c:OnePlaylist.Providers.Adapter.refresh_tokens/1` that calls
  `fresh?/2` gets the boolean and *not* the invariant behind it — measured, not
  assumed. That is correct behaviour rather than a limitation: Meyer's point is
  that assertions must sit on a higher plane than the code they protect, and
  checking the guard's credentials while he is screening today's visitors is too
  late. The time to establish that a function is fit to appear in an assertion is
  when you decide to use it there.

  The practical consequence is this function's shape. It deliberately takes a
  bare parameter rather than `%__MODULE__{} = tokens`, so Bond attaches no entry
  check and there is nothing to suppress: it answers the same way inside an
  assertion as outside one. A predicate written to be called *from* contracts has
  to be contract-free itself.

      iex> alias OnePlaylist.Providers.Tokens
      iex> Tokens.well_formed?(Tokens.new(access_token: "at", expires_at: ~U[2030-01-01 00:00:00Z]))
      true
      iex> Tokens.well_formed?(%Tokens{access_token: "", expires_at: ~U[2030-01-01 00:00:00Z]})
      false
      iex> Tokens.well_formed?(:not_a_token_set)
      false
  """
  @bond_warn_skipped_invariants false
  @spec well_formed?(term()) :: boolean()
  def well_formed?(tokens) do
    is_struct(tokens, __MODULE__) and
      is_binary(tokens.access_token) and tokens.access_token != "" and
      is_struct(tokens.expires_at, DateTime) and
      (is_nil(tokens.refresh_token) or
         (is_binary(tokens.refresh_token) and tokens.refresh_token != "")) and
      is_list(tokens.scopes)
  end

  @doc """
  Builds a token set from a keyword list or map.

  Raises `Bond.InvariantError` rather than returning an error tuple, because
  every caller is code in this application assembling a value it just received
  and classified — a violation here is a bug in an adapter, not a provider
  behaving badly.

      iex> alias OnePlaylist.Providers.Tokens
      iex> tokens = Tokens.new(access_token: "at", expires_at: ~U[2030-01-01 00:00:00Z])
      iex> {tokens.access_token, tokens.scopes, tokens.refresh_token}
      {"at", [], nil}

  `nil` scopes are normalized to `[]`, since "the provider told us nothing about
  scopes" and "the provider granted none" are the same thing to every caller:

      iex> alias OnePlaylist.Providers.Tokens
      iex> Tokens.new(access_token: "at", expires_at: ~U[2030-01-01 00:00:00Z], scopes: nil).scopes
      []
  """
  @spec new(Enumerable.t()) :: t()
  def new(fields) do
    attrs = Map.new(fields)

    %__MODULE__{
      access_token: attrs[:access_token],
      refresh_token: attrs[:refresh_token],
      expires_at: attrs[:expires_at],
      scopes: attrs[:scopes] || []
    }
  end

  @doc """
  Builds a token set from a standard OAuth 2.0 token response.

  The field names are RFC 6749 §5.1 — `access_token`, `refresh_token`,
  `expires_in`, `scope` — which is what TIDAL, Spotify, Google and Deezer all
  return. Keeping the translation here rather than in one provider's client
  means the next provider inherits it, including the two details that are easy
  to get wrong: `expires_in` is a *duration* and has to become an instant before
  it is stored, and `scope` is one space-delimited string rather than a list.

      iex> alias OnePlaylist.Providers.Tokens
      iex> tokens = Tokens.from_oauth_response(%{
      ...>   "access_token" => "at",
      ...>   "expires_in" => 3600,
      ...>   "scope" => "playlists.read search.read"
      ...> })
      iex> tokens.scopes
      ["playlists.read", "search.read"]

  A response with no `expires_in` is given one hour, the most common default and
  a deliberately conservative guess: too short only costs an early refresh,
  while too long means calls fail before anything thinks to refresh.
  """
  @default_lifetime_seconds 3600

  # Bond's linter is right that this head neither matches nor builds a
  # `%Tokens{}`, and wrong that the invariant is therefore skipped: every exit
  # from here is a `new/1` call, whose own exit check fires. Suppressed rather
  # than restructured, because building the struct inline here to satisfy the
  # linter would duplicate `new/1`'s normalization — which is the one thing
  # worth having in a single place.
  @bond_warn_skipped_invariants false
  @spec from_oauth_response(map(), DateTime.t()) :: t()
  def from_oauth_response(body, now \\ DateTime.utc_now()) when is_map(body) do
    new(
      access_token: body["access_token"],
      refresh_token: body["refresh_token"],
      expires_at: DateTime.add(now, body["expires_in"] || @default_lifetime_seconds, :second),
      scopes: String.split(body["scope"] || "", " ", trim: true)
    )
  end

  @doc """
  Whether the access token is still valid at `now`.

  Asked of a token set the moment it arrives — a provider answering with an
  already-expired token is worse than one answering with an error, since the
  expired one gets stored and looks healthy.

      iex> alias OnePlaylist.Providers.Tokens
      iex> tokens = Tokens.new(access_token: "at", expires_at: ~U[2030-01-01 00:00:00Z])
      iex> Tokens.fresh?(tokens, ~U[2029-12-31 23:00:00Z])
      true
      iex> Tokens.fresh?(tokens, ~U[2030-01-01 00:00:01Z])
      false

  This is *not* `OnePlaylist.Providers.Connection.needs_refresh?/3`, which asks
  a different question — "should we refresh this early?" — about a stored
  connection rather than an arriving credential, and answers `false` for a nil
  expiry where this answers, via the invariant, that there is no such token set.
  """
  @spec fresh?(t(), DateTime.t()) :: boolean()
  def fresh?(%__MODULE__{} = tokens, now \\ DateTime.utc_now()) do
    DateTime.after?(tokens.expires_at, now)
  end
end
