defmodule OnePlaylist.Providers.OAuthFlow do
  @moduledoc """
  How a provider's OAuth round trip works, as a behaviour.

  Extracted once there were two, and deliberately not before: TIDAL's flow was
  the only one for months and generalising from it alone would have produced an
  abstraction shaped like PKCE. Spotify is a **confidential** client with no
  verifier at all, so the pair together show which parts genuinely vary.

  ## What varies is *what a flow needs to remember between its two legs*

  Not the number of steps, and not the order. Every OAuth round trip here is:
  redirect out, come back with a code, exchange it, find out who authorized,
  store a connection. What differs is the value carried across:

    * **TIDAL** stashes a PKCE `code_verifier` — a secret whose hash went to the
      provider — and hands it back at the exchange.
    * **Spotify** stashes nothing but the CSRF nonce, because the client secret
      does the verifier's job and never leaves the server.

  So `c:authorization_url/1` answers a `session` map of whatever it needs back,
  and `c:exchange_code/2` is handed that map. `OnePlaylistWeb.OAuthController`
  stores and returns it without reading it. A future flow needing something
  else — an OIDC nonce, a PAR request id — adds a key and changes nothing else.

  ## `state` is not part of that map, because it is not the flow's business

  Every flow needs a CSRF nonce and every flow checks it the same way, so the
  controller owns it and the contract below states its two laws once for
  everybody. Leaving it to each flow is how one of them eventually forgets, and
  a URL built without `state` completes the round trip perfectly while accepting
  anybody's authorization code.

  ## Where an implementation lives

  In the provider's own `OAuth` module — `OnePlaylist.Providers.Tidal.OAuth` and
  `OnePlaylist.Providers.Spotify.OAuth`. There is no separate "flow" module,
  because the thing that knows how to build an authorize URL is the thing that
  knows the provider's OAuth, and splitting them would put two halves of one
  subject in two files.
  """

  use Bond.Behaviour

  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.Tokens

  @typedoc """
  What `c:authorization_url/1` answers.

  `session` is opaque to the controller: whatever a flow needs handed back at
  `c:exchange_code/2`, and nothing else needs to know what is in it.
  """
  @type authorization :: %{url: String.t(), state: String.t(), session: map()}

  @doc "The provider this flow authorizes."
  @callback provider() :: Connection.provider()

  @doc """
  The URL to redirect a user to, the CSRF nonce, and whatever must be kept.

  Answers a configuration error rather than a URL when the provider's
  credentials are absent, so a missing secret is reported as what it is instead
  of surfacing as a redirect with a blank `client_id`.
  """
  # The CSRF laws, stated once for every provider rather than once per provider.
  #
  # Both are invisible in the happy path, which is what makes them contracts. A
  # URL built without `state` completes the whole round trip and looks correct,
  # while accepting an authorization code from anybody — the victim's account
  # silently ends up connected to the attacker's music service, which for this
  # application means the attacker's playlists become readable and writable by
  # somebody else's scheduled syncs.
  #
  # 32 bytes of `:crypto.strong_rand_bytes/1` is 43 base64url characters, so the
  # bound is expressed as the encoded length a reader can count in a URL.
  #
  # Proven by mutation in each implementation: dropping `"state"` from the query
  # fires the first, and shortening the nonce fires the second.
  @post whenever(
          {:ok, authorization} <- result,
          # Fully qualified: an inherited contract is compiled into the
          # *implementing* module, where a bare `state_in/1` resolves to nothing.
          state_reaches_the_provider:
            OnePlaylist.Providers.OAuthFlow.state_in(authorization.url) ==
              authorization.state,
          state_is_unguessable: String.length(authorization.state) >= 32
        )
  @callback authorization_url(opts :: keyword()) ::
              {:ok, authorization()} | {:error, Exception.t()}

  @doc """
  Exchanges an authorization code for tokens.

  `session` is whatever `c:authorization_url/1` asked to keep, read back out of
  the browser session. A flow that needs nothing ignores it.
  """
  @callback exchange_code(code :: String.t(), session :: map()) ::
              {:ok, Tokens.t()} | {:error, Exception.t()}

  @doc """
  Who authorized, as attributes for `OnePlaylist.Providers.connect/3`.

  Does the provider's "who am I" call and shapes the answer. Both halves belong
  to the flow rather than to the controller: TIDAL answers a JSON:API resource
  whose identity is under `attributes`, Spotify a flat object, and a controller
  that knew the difference would be a controller with two providers in it.
  """
  # Two laws, and each names a failure that is silent rather than loud.
  #
  # `identifies_the_account` because `provider_user_id` is the account's identity
  # and `to_string(nil)` is `""` — a flow that read the wrong key would give
  # every connection for that provider the same blank id, and
  # `Providers.connect/3` would happily reconnect one user's account over
  # another's.
  #
  # `carries_the_tokens` because this callback both *uses* an access token and
  # *returns* one, which is exactly the shape that lets a refactor return the
  # wrong one — the connect would succeed and store a credential that belongs to
  # a different exchange.
  @post whenever(
          {:ok, attrs} <- result,
          identifies_the_account:
            is_binary(attrs.provider_user_id) and attrs.provider_user_id != "",
          carries_the_tokens: attrs.access_token == tokens.access_token
        )
  @callback connection_attrs(tokens :: Tokens.t()) :: {:ok, map()} | {:error, Exception.t()}

  @doc """
  The `state` carried by an authorization URL, or `nil`.

  Public because `c:authorization_url/1` names it in a postcondition, and an
  assertion rendered into the documentation should reference something a reader
  can look up.
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
end
