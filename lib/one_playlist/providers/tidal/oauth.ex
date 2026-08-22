defmodule OnePlaylist.Providers.Tidal.OAuth do
  @moduledoc """
  TIDAL's OAuth 2.0 Authorization Code flow with PKCE.

  TIDAL is **not** one of Supabase Auth's built-in social providers, so unlike
  Spotify this flow is ours to drive end to end. That is more code, and also
  strictly better for this application's purposes: the tokens arrive here
  directly instead of appearing once in a Supabase session and vanishing.
  See `docs/reference/supabase.md`.

  PKCE is not optional. TIDAL's documentation is explicit that private playlists
  and anything under `/me` work only under the PKCE flow — which is precisely
  what a transfer tool needs.

  ## The flow

      1. `authorization_url/1`  → redirect the user to TIDAL, keep the verifier
      2. user authorizes, TIDAL redirects back with `?code=...&state=...`
      3. `exchange_code/2`      → tokens
      4. `refresh/1`            → new access token, before the old one expires

  Endpoints and error shapes below were verified against the live service on
  2026-08-22, not taken from documentation.
  """

  alias OnePlaylist.Providers.Tidal
  alias OnePlaylist.Providers.Tidal.Service
  alias OnePlaylist.Providers.TokenRefreshFailed
  alias OnePlaylist.Providers.Tokens

  use Bond
  use Errata

  @doc """
  Builds the URL to redirect a user to, plus the PKCE verifier and state.

  The caller must stash `:code_verifier` and `:state` (in the session) and hand
  the verifier back to `exchange_code/2`. They are returned rather than stored
  here so this module stays free of session concerns.
  """
  # PKCE's entire security value rests on one relationship: what travels to
  # TIDAL must be the *hash* of the secret we keep, never the secret itself.
  # Send the verifier as the challenge and the flow still works end to end — the
  # exchange succeeds, tests pass, nothing looks wrong — while the protection
  # PKCE exists to provide is gone. That is precisely the class of bug a
  # postcondition is for: silent, security-relevant, and invisible in the
  # happy path.
  #
  # The length bound is RFC 7636 §4.1, which a provider may or may not enforce.
  @post whenever(
          {:ok, authorization} <- result,
          challenge_is_hashed:
            challenge_in(authorization.url) ==
              Base.url_encode64(:crypto.hash(:sha256, authorization.code_verifier),
                padding: false
              ),
          verifier_never_sent: challenge_in(authorization.url) != authorization.code_verifier,
          verifier_length_per_rfc7636: String.length(authorization.code_verifier) in 43..128
        )
  @spec authorization_url(keyword()) ::
          {:ok, %{url: String.t(), code_verifier: String.t(), state: String.t()}}
          | {:error, Errata.error()}
  def authorization_url(opts \\ []) do
    with {:ok, config} <- config() do
      verifier = random_url_safe(64)
      state = random_url_safe(32)
      scopes = Keyword.get(opts, :scopes, config[:scopes])

      query =
        URI.encode_query(%{
          "response_type" => "code",
          "client_id" => config[:client_id],
          "redirect_uri" => config[:redirect_uri],
          "scope" => Enum.join(scopes, " "),
          "code_challenge_method" => "S256",
          "code_challenge" => code_challenge(verifier),
          "state" => state
        })

      {:ok,
       %{
         url: "#{config[:login_url]}/authorize?#{query}",
         code_verifier: verifier,
         state: state
       }}
    end
  end

  @doc "Exchanges an authorization code for tokens."
  @spec exchange_code(String.t(), String.t()) :: {:ok, Tokens.t()} | {:error, Errata.error()}
  def exchange_code(code, code_verifier) do
    with {:ok, config} <- config() do
      post_token(config, %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => config[:redirect_uri],
        "code_verifier" => code_verifier
      })
    end
  end

  @doc """
  Exchanges a refresh token for a fresh access token.

  TIDAL may or may not return a new refresh token; when it does not, the caller
  keeps the existing one. Losing it silently would end the connection at the
  next expiry, so `:refresh_token` is `nil` here rather than absent, and
  `OnePlaylist.Providers.refresh/1` is what decides to keep the old value.
  """
  @spec refresh(String.t()) :: {:ok, Tokens.t()} | {:error, Errata.error()}
  def refresh(refresh_token) do
    with {:ok, config} <- config() do
      post_token(config, %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token
      })
    end
  end

  # Both ways tokens enter this application funnel through here — the initial
  # `exchange_code/2` at connect, and `refresh/1` thereafter. `refresh_tokens/1`
  # inherits equivalent guarantees from `OnePlaylist.Providers.Adapter`, but
  # `exchange_code/2` is not behind that behaviour, so without this the connect
  # path is the one unguarded route by which an already-expired or blank token
  # could be stored and look healthy.
  #
  # A postcondition on a private function is fine: Bond exempts them from the
  # Precondition Availability rule, since a postcondition is a promise the
  # function makes rather than an obligation on its caller.
  #
  # `usable` used to sit beside this, asserting a non-blank access token. It is
  # now an invariant of `OnePlaylist.Providers.Tokens`, which fires when
  # `from_oauth_response/2` builds the struct — earlier, in the module that owns
  # the type, and strictly stronger: it also rejects the blank *refresh* token
  # that `Providers.refresh/1`'s `||` fallback would otherwise store.
  #
  # Freshness stays here, because it is not an invariant. See the moduledoc of
  # `OnePlaylist.Providers.Tokens`.
  @post whenever({:ok, tokens} <- result, fresh: Tokens.fresh?(tokens))
  defp post_token(config, params) do
    params = Map.put(params, "client_id", config[:client_id])

    result =
      Service.call(fn ->
        [
          base_url: config[:auth_url],
          url: "/oauth2/token",
          method: :post,
          form: params,
          receive_timeout: :timer.seconds(10),
          finch: [pool_timeout: :timer.seconds(5)],
          # ExternalService owns retrying — see the note in Tidal.Client.
          retry: false
        ]
        |> Keyword.merge(auth_option(config))
        |> Keyword.merge(config[:req_options] || [])
        |> Req.new()
        |> Req.request()
        |> classify_token_response()
      end)

    with {:ok, body} <- result do
      {:ok, Tokens.from_oauth_response(body)}
    end
  end

  # A server-side application is a confidential client, so TIDAL expects the
  # secret over HTTP Basic *in addition to* PKCE. A public client (no secret
  # configured) sends only the PKCE verifier.
  defp auth_option(config) do
    case config[:client_secret] do
      secret when is_binary(secret) and secret != "" ->
        [auth: {:basic, "#{config[:client_id]}:#{secret}"}]

      _absent ->
        []
    end
  end

  # Verified against the live endpoint: failures come back as
  # `{"error":"invalid_grant","error_description":"...","status":400,...}`.
  defp classify_token_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp classify_token_response({:ok, %{status: status, body: body}}) when status in 400..499 do
    reason =
      case body do
        %{"error" => "invalid_grant"} -> :invalid_grant
        %{"error" => "invalid_client"} -> :invalid_grant
        _other when status == 429 -> :rate_limited
        _other -> :malformed_response
      end

    # A dead grant must not be retried: the answer will not change, and
    # hammering it is how an integration wedges itself. Returning it rather than
    # asking for a retry also leaves the circuit breaker alone, which is right —
    # one user's revoked token says nothing about TIDAL's health.
    {:error, token_error(reason, body)}
  end

  defp classify_token_response({:ok, %{status: status}}) when status >= 500,
    do: {:retry, token_error(:provider_unavailable, %{"status" => status})}

  defp classify_token_response({:error, exception}),
    do: {:retry, token_error(:provider_unavailable, %{"reason" => Exception.message(exception)})}

  defp token_error(reason, body) do
    Errata.create(TokenRefreshFailed,
      reason: reason,
      context: %{
        provider: :tidal,
        error: body["error"],
        error_description: body["error_description"]
      }
    )
  end

  @doc """
  The resolved TIDAL configuration, or a clear error when credentials are absent.

  Reported as a configuration problem rather than left to surface as a confusing
  redirect to TIDAL with a blank `client_id`.
  """
  @spec config() :: {:ok, keyword()} | {:error, Errata.error()}
  def config do
    config = Application.get_env(:one_playlist, Tidal, [])

    if present?(config[:client_id]) do
      {:ok, config}
    else
      {:error,
       Errata.create(Tidal.NotConfigured,
         context: %{missing: "TIDAL_CLIENT_ID"}
       )}
    end
  end

  @doc """
  The `code_challenge` carried by an authorization URL, or `nil`.

  Public because `authorization_url/1` names it in a postcondition, and an
  assertion that appears in generated documentation should reference something a
  reader can look up. See `OnePlaylist.Providers.Connection.now_after_creation?/2`
  for the same reasoning applied to a precondition.
  """
  @spec challenge_in(String.t()) :: String.t() | nil
  def challenge_in(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.get(:query)
    |> Kernel.||("")
    |> URI.decode_query()
    |> Map.get("code_challenge")
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp code_challenge(verifier) do
    :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
  end

  defp random_url_safe(bytes) do
    bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
