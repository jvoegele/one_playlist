defmodule OnePlaylist.Accounts do
  @moduledoc """
  Signing users in and out, through Supabase Auth (GoTrue).

  The only module that talks to `Supabase.Auth`. Everything above it —
  `OnePlaylistWeb.UserAuth`, the controllers, the LiveViews — deals in
  `OnePlaylist.Accounts.Session` and this module's two error types, and knows
  nothing about the SDK.

  ## Why this layer exists at all, given the SDK has a Plug

  `supabase_auth` ships `Supabase.Auth.Plug` and `Supabase.Auth.LiveView`, and
  this application deliberately uses neither. The session, the plug and the
  `on_mount` stay in `OnePlaylistWeb.UserAuth` because that is the layer which
  has to put the access token's claims into the Postgres session for RLS —
  Ecto connects as `postgres`, which holds `BYPASSRLS`, so the policies in
  `priv/repo/migrations` are inert until something deliberately steps down to
  `authenticated` and sets `request.jwt.claims`. Handing session management to a
  dependency would put a seam we need in a place we do not control.

  The SDK is used for what it is good at: the GoTrue API calls, the JWKS
  verification behind `Supabase.Auth.get_claims/3`, and the parsing.

  ## Errors are classified, not passed through

  `Supabase.Error` reports the **HTTP status class** — `:bad_request`,
  `:unprocessable_entity` — because `supabase_auth` installs no GoTrue-specific
  error parser. GoTrue's actual `error_code` (`invalid_credentials`,
  `email_not_confirmed`, `weak_password`) is left in `metadata.resp_body`.

  A status class is not something a sign-in form can act on, so `classify/2`
  digs the real code out and turns it into
  `OnePlaylist.Accounts.SignInFailed` (the user can fix it) or
  `OnePlaylist.Accounts.AuthUnavailable` (they cannot). That split is the whole
  reason this function exists — see `docs/reference/supabase.md`.
  """

  use Bond

  alias OnePlaylist.Accounts.AuthUnavailable
  alias OnePlaylist.Accounts.Session
  alias OnePlaylist.Accounts.SignInFailed

  require Logger

  @typedoc "Either a live session, or an account awaiting email confirmation."
  @type sign_up_result :: {:ok, Session.t()} | {:ok, :confirmation_required}

  @doc """
  Signs a user in with an email address and a password.

  The returned session carries the access and refresh tokens; storing it is
  `OnePlaylistWeb.UserAuth`'s job, not this module's.
  """
  # No precondition on the email's shape. This is a **filter** in Meyer's sense
  # (*OOSC* §11.6) — it faces a person typing into a form, where a malformed
  # address is the expected input rather than a caller's bug, and it comes back
  # as an error the form can render. See docs/reference/contracts.md.
  @spec sign_in(String.t(), String.t()) :: {:ok, Session.t()} | {:error, Errata.Error.t()}
  def sign_in(email, password) when is_binary(email) and is_binary(password) do
    with {:ok, client} <- client() do
      client
      |> Supabase.Auth.sign_in_with_password(%{email: email, password: password})
      |> handle_session_result()
    end
  end

  @doc """
  Registers a new account.

  Answers `{:ok, :confirmation_required}` rather than a session when the project
  has email confirmation switched on, because GoTrue then creates the user but
  issues no tokens. The local stack sets `enable_confirmations = false`, so this
  returns a live session there and the other branch is what production does —
  which is exactly the sort of difference worth naming in the type rather than
  discovering on deploy.
  """
  @spec sign_up(String.t(), String.t()) :: sign_up_result() | {:error, Errata.Error.t()}
  def sign_up(email, password) when is_binary(email) and is_binary(password) do
    with {:ok, client} <- client() do
      case Supabase.Auth.sign_up(client, %{email: email, password: password}) do
        # GoTrue answers sign-up with `{user, session}`. A nil session is not a
        # failure: it is the confirmation-required path.
        {:ok, %{session: nil}} ->
          {:ok, :confirmation_required}

        {:ok, %{session: %Supabase.Auth.Session{} = session}} ->
          {:ok, Session.from_gotrue(session)}

        {:ok, %Supabase.Auth.Session{} = session} ->
          {:ok, Session.from_gotrue(session)}

        {:error, error} ->
          {:error, classify(error, :sign_up)}
      end
    end
  end

  @doc """
  Revokes the session at GoTrue.

  Always answers `:ok`. Signing out locally must succeed even when the remote
  revocation cannot: the alternative is a user who clicks "sign out", sees an
  error, and stays signed in — which is worse in exactly the situation where
  signing out matters most. The remote failure is logged and the caller drops
  the cookie regardless.
  """
  @spec sign_out(Session.t()) :: :ok
  def sign_out(%Session{} = session) do
    # `_ =` because the whole expression is deliberately discarded: whatever it
    # answers, this function answers `:ok`. Dialyzer is right to ask.
    _ =
      with {:ok, client} <- client(),
           # `sign_out` lives under `Supabase.Auth.Admin` in the SDK, which reads
           # as though it needs the service role key. It does not — it is
           # `POST /logout` with the *user's own* access token. See
           # docs/reference/supabase.md.
           {:error, error} <-
             Supabase.Auth.Admin.sign_out(client, Session.to_gotrue(session), :local) do
        _ =
          Logger.warning("could not revoke the session at Supabase Auth: #{inspect(error.code)}")
      end

    :ok
  end

  @doc """
  Exchanges the refresh token for a new session.

  A new refresh token comes back with it — the local stack sets
  `enable_refresh_token_rotation = true` — so the result replaces the old
  session wholesale rather than updating the access token in place. Keeping the
  old refresh token would present a used one on the next renewal, which GoTrue
  treats as theft after `refresh_token_reuse_interval` and answers by revoking
  the whole family.
  """
  # The postcondition states the property that makes rotation safe, and the one
  # a partial update would break: what comes back is a *different* credential
  # pair, not the same session with a later expiry.
  @post whenever(
          {:ok, renewed} <- result,
          identity_is_preserved: renewed.user_id == session.user_id,
          rotated: renewed.refresh_token != session.refresh_token
        )
  @spec refresh(Session.t()) :: {:ok, Session.t()} | {:error, Errata.Error.t()}
  def refresh(%Session{} = session) do
    with {:ok, client} <- client() do
      client
      |> Supabase.Auth.refresh_session(session.refresh_token)
      |> handle_session_result()
    end
  end

  @doc """
  The session, renewed first if it is close enough to expiry to matter.

  What every request path calls. Answers the session unchanged in the common
  case, so it is cheap to call on each request, and the caller can tell whether
  to rewrite the cookie by comparing identity.
  """
  @spec ensure_fresh(Session.t(), DateTime.t()) ::
          {:ok, Session.t()} | {:error, Errata.Error.t()}
  def ensure_fresh(%Session{} = session, now \\ DateTime.utc_now()) do
    if Session.needs_refresh?(session, now), do: refresh(session), else: {:ok, session}
  end

  @doc """
  Verifies an access token and returns its claims.

  Local, for the ES256 keys a modern Supabase project issues: the SDK fetches
  the project's JWKS once and verifies against it in process, so establishing
  identity from a token costs no network round trip. Legacy HS256 projects fall
  back to asking GoTrue, which is one of several reasons not to use them.

  Not on the sign-in path — a token that arrived over TLS straight from GoTrue
  and lives in a signed, encrypted cookie is already trustworthy. This is for
  the paths where a token arrives from somewhere less certain, and for reading
  the claims RLS will be given.
  """
  @spec claims(String.t()) :: {:ok, map()} | {:error, Errata.Error.t()}
  def claims(access_token) when is_binary(access_token) do
    with {:ok, client} <- client() do
      verify_claims(client, access_token)
    end
  end

  # `Supabase.Auth.get_claims/3` **raises** on a malformed token rather than
  # answering an error. Its `decode_jwt_parts/1` is written as though it
  # returns `{:error, :invalid_jwt_format}`, but the `JOSE.JWT.peek/1` it calls
  # first throws on input that is not three base64url segments, so that branch
  # is unreachable. Reported in docs/reference/supabase.md.
  #
  # This function exists precisely to judge tokens whose provenance is not
  # certain, so it must answer rather than raise — a caller cannot be asked to
  # rescue from a function that reports failure as `{:error, _}` most of the
  # time.
  defp verify_claims(client, access_token) do
    case Supabase.Auth.get_claims(client, access_token) do
      {:ok, %{claims: claims}} -> {:ok, claims}
      {:error, error} -> {:error, classify(error, :claims)}
    end
  rescue
    error ->
      Logger.info("rejected a malformed access token: #{inspect(error.__struct__)}")
      {:error, SignInFailed.new(reason: :invalid_credentials, message: "that token is not valid")}
  end

  # A single place to fail when the stack is not configured, so every public
  # function above reports `:not_configured` rather than raising an Agent
  # `:noproc` from wherever it happened to call first.
  defp client do
    case OnePlaylist.Supabase.client() do
      {:ok, client} ->
        {:ok, client}

      # The only other shape `OnePlaylist.Supabase.client/0` produces. Building
      # the struct itself cannot fail for any other reason — it is config
      # already in memory — so there is no third clause to write.
      {:error, :not_configured} ->
        {:error,
         AuthUnavailable.new(
           reason: :not_configured,
           message: "Supabase is not configured on this server"
         )}
    end
  end

  defp handle_session_result({:ok, %Supabase.Auth.Session{} = session}),
    do: {:ok, Session.from_gotrue(session)}

  defp handle_session_result({:error, error}), do: {:error, classify(error, :sign_in)}

  # Turns the SDK's status-class error into one the UI can act on, in two tiers.
  #
  # GoTrue's own `error_code` is the precise answer and is tried first. It is not
  # always present — `Supabase.Error.code` carries only the HTTP status class,
  # because `supabase_auth` installs no GoTrue-specific error parser — so the
  # status class is the fallback. Splitting the two tiers apart is what keeps
  # either from having to know about the other.
  defp classify(%Supabase.Error{} = error, context) do
    from_gotrue_code(error_code(error), error) || from_http_status(error, context)
  end

  # Anything that is not a `Supabase.Error` at all — the SDK failing before it
  # got a response, most likely.
  defp classify(other, context) do
    Logger.error("unexpected Supabase Auth failure during #{context}: #{inspect(other)}")
    AuthUnavailable.new(reason: :unexpected_response)
  end

  # The reasons a user can act on, each differently: retype the password, look
  # in your inbox, choose a stronger one, sign in instead of signing up, wait.
  # `nil` means "GoTrue did not say", which hands over to the status class.
  defp from_gotrue_code("invalid_credentials", _error),
    do: SignInFailed.new(reason: :invalid_credentials)

  defp from_gotrue_code("email_not_confirmed", _error),
    do:
      SignInFailed.new(
        reason: :email_not_confirmed,
        message: "check your email for a confirmation link"
      )

  defp from_gotrue_code("weak_password", error),
    do: SignInFailed.new(reason: :weak_password, message: error_message(error))

  defp from_gotrue_code("user_already_exists", _error),
    do: SignInFailed.new(reason: :already_registered)

  defp from_gotrue_code("signup_disabled", _error),
    do: SignInFailed.new(reason: :signups_disabled)

  defp from_gotrue_code("over_email_send_rate_limit", _error),
    do: SignInFailed.new(reason: :rate_limited)

  defp from_gotrue_code(_unrecognised, _error), do: nil

  defp from_http_status(%Supabase.Error{code: :too_many_requests}, _context),
    do: SignInFailed.new(reason: :rate_limited)

  defp from_http_status(%Supabase.Error{code: status}, _context)
       when status in [:bad_request, :unauthorized, :unprocessable_entity],
       do: SignInFailed.new(reason: :invalid_credentials)

  # Deliberately loud. Reaching here means GoTrue said something this mapping
  # has never seen, and quietly calling it "bad credentials" would hide a real
  # outage behind a login form telling everybody their password is wrong.
  defp from_http_status(%Supabase.Error{code: status} = error, context) do
    Logger.error(
      "unhandled Supabase Auth error during #{context}: " <>
        "#{inspect(status)} #{inspect(error_code(error))}"
    )

    AuthUnavailable.new(reason: :unexpected_response)
  end

  # GoTrue puts its own code in `error_code`, and older builds used `error`.
  # The body may arrive decoded or raw depending on the response's content type.
  defp error_code(%Supabase.Error{metadata: metadata}) do
    case body(metadata) do
      %{"error_code" => code} when is_binary(code) -> code
      %{"error" => code} when is_binary(code) -> code
      _otherwise -> nil
    end
  end

  defp error_message(%Supabase.Error{} = error) do
    case body(error.metadata) do
      %{"msg" => msg} when is_binary(msg) -> msg
      %{"message" => msg} when is_binary(msg) -> msg
      _otherwise -> error.message
    end
  end

  defp body(%{resp_body: body}) when is_map(body), do: body

  defp body(%{resp_body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _otherwise -> %{}
    end
  end

  defp body(_metadata), do: %{}
end
