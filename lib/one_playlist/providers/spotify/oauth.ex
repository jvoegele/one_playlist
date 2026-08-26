defmodule OnePlaylist.Providers.Spotify.OAuth do
  @moduledoc """
  Spotify's OAuth 2.0 Authorization Code flow, as a confidential client.

  ## Driven here rather than through Supabase Auth, deliberately

  Spotify *is* one of Supabase Auth's built-in social providers, and TIDAL is
  not — so unlike TIDAL there was a real choice here, and taking the built-in
  one would have served this project's second standing goal.

  It is not taken, because Supabase Auth does not keep provider tokens.
  `provider_token` and `provider_refresh_token` appear once in the session that
  created them and are then gone; nothing refreshes them and nothing stores
  them. That is survivable for "sign in with Spotify", which needs the token
  once. It is fatal for this application, whose whole premise is a *scheduled*
  transfer running against somebody's account next Tuesday. See
  `docs/reference/supabase.md`.

  There is also a second reason, smaller but real: signing in and connecting a
  music service are different acts. Somebody who signed up with email and later
  wants their Spotify playlists should not have to change how they log in.

  ## Confidential client, where TIDAL is public + PKCE

  TIDAL is driven as a public client with PKCE, because TIDAL's documentation
  requires PKCE for anything under `/me`. Spotify does not, and a Phoenix server
  can keep a secret — so this is the plain Authorization Code flow with the
  client secret over HTTP Basic, which is the correct shape for a client that
  can hold one.

  The practical difference is that there is no verifier to stash between the two
  legs of the flow: `state` alone carries across, and it is a CSRF nonce rather
  than a secret. `OnePlaylistWeb.SpotifyAuthController` is correspondingly
  smaller.

  ## The flow

      1. `authorization_url/1`  → redirect the user to Spotify, keep the state
      2. user authorizes, Spotify redirects back with `?code=...&state=...`
      3. `exchange_code/1`      → tokens
      4. `refresh/1`            → new access token, before the old one expires

  ## A refresh may or may not return a new refresh token

  Spotify's refresh response usually omits `refresh_token`, and sometimes
  includes a new one. Both are legal, and the second is the dangerous one: a
  client that ignores the field keeps using a token the service may have
  rotated away, and the connection dies at some later expiry with an
  `invalid_grant` that points at nothing in particular.

  So `Tokens.from_oauth_response/2` puts `nil` there when the field is absent
  and `OnePlaylist.Providers.refresh/1` keeps the stored value — the same
  arrangement TIDAL uses, and it is load-bearing for both.
  """

  alias OnePlaylist.Providers.Spotify
  alias OnePlaylist.Providers.Spotify.Service
  alias OnePlaylist.Providers.TokenRefreshFailed
  alias OnePlaylist.Providers.Tokens

  use Bond
  use Errata

  @doc """
  Builds the URL to redirect a user to, plus the state nonce.

  The caller must stash `:state` in the session and hand it back when the
  callback arrives. It is returned rather than stored here so this module stays
  free of session concerns.
  """
  # `state` is the whole CSRF defence for this flow — there is no PKCE verifier
  # beside it, as there is for TIDAL, so nothing else would catch a forged
  # callback. Two things have to be true of it and neither is visible in the
  # happy path: it must actually reach Spotify (a URL built without it completes
  # the flow perfectly while accepting anybody's authorization code), and it
  # must be long enough not to be guessed.
  #
  # 32 bytes of `:crypto.strong_rand_bytes/1` is 43 base64url characters, so the
  # bound is expressed as the encoded length a reader can count in a URL.
  #
  # Proven by mutation: dropping `"state"` from the query fires the first, and
  # `random_url_safe(8)` fires the second.
  @post whenever(
          {:ok, authorization} <- result,
          state_reaches_spotify: state_in(authorization.url) == authorization.state,
          state_is_unguessable: String.length(authorization.state) >= 32
        )
  @spec authorization_url(keyword()) ::
          {:ok, %{url: String.t(), state: String.t()}} | {:error, Errata.error()}
  def authorization_url(opts \\ []) do
    with {:ok, config} <- config() do
      state = random_url_safe(32)
      scopes = Keyword.get(opts, :scopes, config[:scopes])

      query =
        URI.encode_query(%{
          "response_type" => "code",
          "client_id" => config[:client_id],
          "redirect_uri" => config[:redirect_uri],
          "scope" => Enum.join(scopes, " "),
          "state" => state
        })

      {:ok, %{url: "#{config[:login_url]}/authorize?#{query}", state: state}}
    end
  end

  @doc """
  Exchanges an authorization code for tokens.

  `redirect_uri` is sent again here even though Spotify already has it from the
  authorize leg. That is the spec, and Spotify enforces it: the two must match
  byte for byte or the exchange fails with `invalid_grant` naming neither side.
  """
  @spec exchange_code(String.t()) :: {:ok, Tokens.t()} | {:error, Errata.error()}
  def exchange_code(code) do
    with {:ok, config} <- config() do
      post_token(config, %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => config[:redirect_uri]
      })
    end
  end

  @doc """
  Exchanges a refresh token for a fresh access token.

  See the moduledoc on why the answer may or may not carry a new refresh token,
  and who is responsible for keeping the old one when it does not.
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
  # `exchange_code/1` at connect, and `refresh/1` thereafter. `refresh_tokens/1`
  # inherits equivalent guarantees from `OnePlaylist.Providers.Adapter`, but
  # `exchange_code/1` is not behind that behaviour, so without this the connect
  # path is the one unguarded route by which an already-expired or blank token
  # could be stored and look healthy.
  #
  # Freshness only. A non-blank access token belongs to `Tokens`' own invariant,
  # which fires earlier and is stronger. Freshness cannot go there: it is a
  # property of the producer, not of the value.
  @post whenever({:ok, tokens} <- result, fresh: Tokens.fresh?(tokens))
  defp post_token(config, params) do
    result =
      Service.call(fn ->
        [
          base_url: config[:login_url],
          url: "/api/token",
          method: :post,
          form: params,
          # Basic rather than the credentials in the form body. Both are legal
          # per RFC 6749 and Spotify accepts either; Basic keeps the secret out
          # of anything that logs a request body.
          auth: {:basic, "#{config[:client_id]}:#{config[:client_secret]}"},
          receive_timeout: :timer.seconds(10),
          finch: [pool_timeout: :timer.seconds(5)],
          # ExternalService owns retrying — see the note in Spotify.Client.
          retry: false
        ]
        |> Keyword.merge(config[:req_options] || [])
        |> Req.new()
        |> Req.request()
        |> classify_token_response()
      end)

    with {:ok, body} <- result do
      {:ok, Tokens.from_oauth_response(body)}
    end
  end

  # Spotify's token endpoint answers failures as
  # `{"error":"invalid_grant","error_description":"Invalid refresh token"}` —
  # the OAuth 2.0 shape rather than the Web API's `{"error":{"status":…}}`, so
  # this cannot share `Client`'s classifier.
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
    # one user's revoked token says nothing about Spotify's health.
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
        provider: :spotify,
        error: body["error"],
        error_description: body["error_description"]
      }
    )
  end

  @doc """
  The resolved Spotify configuration, or a clear error when credentials are
  absent.

  Both halves are required, unlike TIDAL's, because this is a confidential
  client: a client id with no secret produces a token exchange that fails with
  `invalid_client` after the user has already authorized, which is the worst
  place to discover a configuration problem.
  """
  @spec config() :: {:ok, keyword()} | {:error, Errata.error()}
  def config do
    config = Application.get_env(:one_playlist, Spotify, [])

    case {present?(config[:client_id]), present?(config[:client_secret])} do
      {true, true} ->
        {:ok, config}

      {false, _secret} ->
        {:error, Errata.create(Spotify.NotConfigured, context: %{missing: "SPOTIFY_CLIENT_ID"})}

      {true, false} ->
        {:error,
         Errata.create(Spotify.NotConfigured, context: %{missing: "SPOTIFY_CLIENT_SECRET"})}
    end
  end

  @doc """
  The `state` carried by an authorization URL, or `nil`.

  Public because `authorization_url/1` names it in a postcondition, and an
  assertion that appears in generated documentation should reference something a
  reader can look up. See `OnePlaylist.Providers.Tidal.OAuth.challenge_in/1` for
  the same reasoning applied to PKCE.
  """
  @spec state_in(String.t()) :: String.t() | nil
  def state_in(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.get(:query)
    |> Kernel.||("")
    |> URI.decode_query()
    |> Map.get("state")
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp random_url_safe(bytes) do
    bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
