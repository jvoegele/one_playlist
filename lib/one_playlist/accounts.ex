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

  @typedoc """
  A redirect-based sign-in, begun and not yet finished.

  `url` is where to send the browser. `code_verifier` is the PKCE secret whose
  hash went along in that URL; it must be kept — in the session cookie — until
  the browser comes back, and handed to `exchange_code/2`. Nothing else can
  finish the flow, which is what makes the verifier the CSRF defence as well:
  an authorization code planted in a victim's browser is useless without the
  verifier that only the attacker's session holds.
  """
  @type sign_in_start :: %{url: String.t(), code_verifier: String.t()}

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
  Emails a sign-in link and a six-digit code to an address.

  The email is sent by GoTrue from the project's templates —
  `supabase/templates/` locally, and the same files pasted into the dashboard in
  production. It carries **two credentials for one attempt**:

    * a link to `{{ .SiteURL }}/auth/callback` with `token_hash={{ .TokenHash }}`,
      which `verify_magic_link/1` finishes. The hash is verified server-side
      against GoTrue, so the link works from any browser or device — the one
      that asked for it or another — because nothing about the attempt is held
      in a cookie.
    * `{{ .Token }}`, the six-digit code the same template shows, which
      `verify_email_code/2` finishes. For the person reading the email on a
      phone and signing in on a laptop, where even a device-independent link is
      the wrong shape.

  **Which template GoTrue picks depends on the project, not only the address.**
  Locally, with `enable_confirmations = false`, every magic link — to a known
  address or a brand-new one — goes out as `magic_link` (observed 2026-09-02).
  With confirmations *on*, the production setting, a new address is created
  unconfirmed and gets the `confirmation` template instead, the same email a
  password sign-up gets. Both templates here carry the same link and code, so
  the difference is invisible to the person and to `callback/2` — and a
  password sign-up's confirmation email lands on the same callback and signs
  the person in.

  ## Deliberately not PKCE

  Supabase's client libraries default to a PKCE magic link: the challenge goes
  with the request, the email links to GoTrue, and GoTrue redirects back with a
  `code` that only the browser holding the verifier can exchange. Two reasons not
  to here. It fails in exactly the case above — the link opened anywhere other
  than the browser that requested it — and that is the *common* case for email,
  not the edge. And the SDK cannot do it anyway: in 1.0.0 `sign_in_with_otp/2`
  generates a verifier, never returns it, and never puts the challenge in the
  request body either. See `docs/supabase-sdk-issues.md`.

  So this is the flow Supabase documents for server-rendered applications, and
  the client is the default `:implicit` one — which sends no challenge and is
  harmless, since no `code` ever comes back to be exchanged.

  Also how somebody **signs up** without a password: GoTrue creates the account
  on the first link, because `should_create_user` defaults to true.

  No `redirect_to` is sent. The templates build the link from `{{ .SiteURL }}`,
  which is per-environment configuration GoTrue already holds, so there is
  nothing for a request to add — and a link that does not depend on the request
  is one a *confirmation* email, which no request of ours shapes, can carry too.
  """
  # A filter, like `sign_in/2`: the address is typed by a person and a bad one
  # comes back as an error the form renders.
  @spec send_magic_link(String.t()) :: :ok | {:error, Errata.Error.t()}
  def send_magic_link(email) when is_binary(email) do
    with {:ok, client} <- client() do
      case Supabase.Auth.sign_in_with_otp(client, %{email: email}) do
        :ok -> :ok
        # The SDK's phone branch, which an email request never takes. Matched so
        # the function's answer is total rather than a `CaseClauseError` if the
        # SDK ever changes what an email send returns.
        {:ok, _message_id} -> :ok
        {:error, error} -> {:error, classify(error, :magic_link)}
      end
    end
  end

  @doc """
  Finishes a magic link: exchanges the `token_hash` from the emailed link for a
  session.

  Single use and time-limited (`otp_expiry`, an hour locally). A second click
  answers `:link_expired`, which is also what a forged or truncated hash
  answers — GoTrue does not distinguish them, and neither does this.
  """
  @spec verify_magic_link(String.t()) :: {:ok, Session.t()} | {:error, Errata.Error.t()}
  def verify_magic_link(token_hash) when is_binary(token_hash) do
    with {:ok, client} <- client() do
      client
      |> Supabase.Auth.verify_otp(%{token_hash: token_hash, type: :email})
      |> handle_session_result(:magic_link)
    end
  end

  @doc """
  Finishes a magic link the other way: the six-digit code from the same email,
  typed in beside the address it was sent to.

  A wrong code and an expired one are both `:link_expired`. That is GoTrue's
  answer — `otp_expired` for either — and it is the right one to pass on: the
  code is six digits, and a form that distinguished "wrong" from "expired" would
  be confirming to a guesser that the address has a live attempt.
  """
  @spec verify_email_code(String.t(), String.t()) ::
          {:ok, Session.t()} | {:error, Errata.Error.t()}
  def verify_email_code(email, code) when is_binary(email) and is_binary(code) do
    with {:ok, client} <- client() do
      client
      |> Supabase.Auth.verify_otp(%{email: email, token: String.trim(code), type: :email})
      |> handle_session_result(:email_code)
    end
  end

  @doc """
  Begins a Google sign-in, through Supabase Auth.

  No network call: the SDK builds GoTrue's `/authorize` URL and a PKCE pair, and
  the browser does the rest. GoTrue sends the user to Google, takes Google's
  answer at *its* callback, and redirects to `callback_url` with a `code` that
  `exchange_code/2` turns into a session — provided the caller kept the
  `code_verifier`.

  ## What this is, and is not

  A way of obtaining a **GoTrue session**, exactly as email and password are.
  It is not a music-service connection: GoTrue receives Google's access token,
  shows it once in the session response, and neither stores nor refreshes it
  (`docs/reference/supabase.md` §4). YouTube Music, if it is ever built, will be
  an `OnePlaylist.Providers.OAuthFlow` like Spotify's, with tokens this
  application holds and renews itself — the same reason Supabase's own Spotify
  provider was rejected for that job.

  This is the one place a `:pkce` client is asked for; `OnePlaylist.Supabase.client/1`
  says why the shared one is not.
  """
  # Both halves of the pair are asserted because both fail *later* and
  # silently at the point of creation: a blank verifier is stored in the cookie
  # without complaint and the exchange answers `bad_code_verifier` a minute
  # later, and a URL without the challenge starts an implicit-flow sign-in whose
  # tokens come back in a fragment the server never sees — the user completes
  # Google's consent screen and lands on the callback with nothing.
  #
  # No input falsifies any of these from outside: `callback_url` reaches none.
  # Proven by mutation instead — blanking the verifier fires `verifier_present`,
  # stripping the challenge from the URL fires `challenge_travels`, and asking
  # for `:github` fires `names_google`.
  @post whenever(
          {:ok, start} <- result,
          verifier_present: is_binary(start.code_verifier) and start.code_verifier != "",
          challenge_travels: String.contains?(start.url, "code_challenge="),
          names_google: String.contains?(start.url, "provider=google")
        )
  @spec begin_google_sign_in(String.t()) :: {:ok, sign_in_start()} | {:error, Errata.Error.t()}
  def begin_google_sign_in(callback_url) when is_binary(callback_url) do
    with {:ok, client} <- client(flow_type: :pkce) do
      credentials = %{provider: :google, options: %{redirect_to: callback_url}}

      case Supabase.Auth.sign_in_with_oauth(client, credentials) do
        {:ok, %{url: url, code_verifier: verifier}} ->
          {:ok, %{url: url, code_verifier: verifier}}

        other ->
          # A parse failure on a literal `:google`, or a client the SDK decided
          # was not PKCE after all. Neither is the user's doing.
          Logger.error("could not begin a Google sign-in: #{inspect(other)}")
          {:error, AuthUnavailable.new(reason: :unexpected_response)}
      end
    end
  end

  @doc """
  Finishes a redirect-based sign-in: the `code` GoTrue sent the browser back
  with, and the verifier kept from `begin_google_sign_in/1`.

  `:link_expired` covers the code being spent, the flow state having aged out,
  and the verifier not matching — which is what a CSRF attempt looks like from
  here, and is refused for the same reason it is refused everywhere else.
  """
  @spec exchange_code(String.t(), String.t()) :: {:ok, Session.t()} | {:error, Errata.Error.t()}
  def exchange_code(code, code_verifier) when is_binary(code) and is_binary(code_verifier) do
    with {:ok, client} <- client() do
      client
      |> Supabase.Auth.exchange_code_for_session(code, code_verifier)
      |> handle_session_result(:exchange)
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

  Verified claims always carry a **`sub`** — the user id `auth.uid()` reads. It
  is the one field that must be there: `OnePlaylist.Repo.as_user/3` sets it as a
  Postgres claim, `auth.uid()` casts it to `uuid`, and a missing or blank one
  casts to NULL rather than raising. Every `auth.uid() = user_id` comparison is
  then NULL, which is not true, which silently returns zero rows — a signed-in
  user who appears to own nothing.
  """
  # Exercised only by the `:supabase`-tagged tests, which need a configured
  # local stack — so it does not appear in the default coverage table. It runs on
  # every real call, which is the path that matters.
  @post whenever(
          {:ok, claims} <- result,
          names_a_subject: is_binary(claims["sub"]) and claims["sub"] != ""
        )
  @spec claims(String.t()) :: {:ok, map()} | {:error, Errata.Error.t()}
  def claims(access_token) when is_binary(access_token) do
    with {:ok, client} <- client() do
      verify_claims(client, access_token)
    end
  end

  # `Supabase.Auth.get_claims/3` **raises** on most malformed tokens rather than
  # answering an error. It does return `{:error, :invalid_jwt_format}` for input
  # whose three segments decode but do not describe a JWT — so the branch is
  # reachable, and the failure is worse for being inconsistent: `"abc"` raises
  # `ArgumentError`, `"a.b.c"` raises `CaseClauseError`, `"aaaa.bbbb.cccc"`
  # raises `Jason.DecodeError`. See docs/supabase-sdk-issues.md.
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
  defp client(opts \\ []) do
    case OnePlaylist.Supabase.client(opts) do
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

  defp handle_session_result(result, context \\ :sign_in)

  defp handle_session_result({:ok, %Supabase.Auth.Session{} = session}, _context),
    do: {:ok, Session.from_gotrue(session)}

  defp handle_session_result({:error, error}, context), do: {:error, classify(error, context)}

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

  # One remedy for all four — start again — so one reason. `otp_expired` is
  # GoTrue's answer to a wrong six-digit code as well as a stale one; the three
  # flow-state codes are the PKCE exchange's ways of saying the same thing, and
  # `bad_code_verifier` is also what a CSRF attempt looks like from here.
  defp from_gotrue_code(code, _error)
       when code in ~w(otp_expired bad_code_verifier flow_state_not_found flow_state_expired),
       do:
         SignInFailed.new(
           reason: :link_expired,
           message: "that link or code has expired or was already used — request a new one"
         )

  # The project has the method switched off. Configuration, not the user, and
  # named as such so a missing Google client id does not read as "wrong password".
  defp from_gotrue_code(code, _error)
       when code in ~w(provider_disabled email_provider_disabled otp_disabled),
       do:
         AuthUnavailable.new(
           reason: :method_disabled,
           message: "that way of signing in is not enabled on this server"
         )

  # GoTrue's own words are the useful ones here — "Unable to validate email
  # address: invalid format" — and they name nothing sensitive.
  defp from_gotrue_code(code, error) when code in ~w(validation_failed email_address_invalid),
    do: SignInFailed.new(reason: :invalid_credentials, message: error_message(error))

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
