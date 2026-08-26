defmodule OnePlaylistWeb.SpotifyAuthController do
  @moduledoc """
  The Spotify OAuth round trip: redirect out, handle the callback, store the
  connection.

  ## One session value, where TIDAL keeps two

  `OnePlaylistWeb.TidalAuthController` stashes a PKCE `code_verifier` alongside
  the `state` nonce. Spotify is driven as a confidential client — see
  `OnePlaylist.Providers.Spotify.OAuth` — so there is no verifier, and the
  client secret takes its place. The secret never enters the session because it
  never leaves the server at all.

  What remains is `state`, and it is doing the whole job on its own:

    * a CSRF nonce. Without checking it, an attacker can hand a victim's browser
      a callback URL carrying the *attacker's* authorization code, and the
      victim's account silently ends up connected to the attacker's Spotify
      account — which for this application means the attacker's playlists become
      readable and writable by somebody else's scheduled syncs. Comparison is
      constant-time.

  It is deleted on every exit path, success or failure, so a stale nonce cannot
  be replayed against a later attempt.
  """

  use OnePlaylistWeb, :controller

  import OnePlaylistWeb.UserAuth, only: [current_user_id: 1]

  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Spotify.Client
  alias OnePlaylist.Providers.Spotify.OAuth

  require Logger

  @state_key "spotify_oauth_state"

  @doc "Starts the flow by redirecting to Spotify."
  def start(conn, _params) do
    case OAuth.authorization_url() do
      {:ok, %{url: url, state: state}} ->
        conn
        |> put_session(@state_key, state)
        |> redirect(external: url)

      {:error, error} ->
        conn
        |> put_flash(:error, Errata.display_message(error) || "Could not start Spotify sign-in.")
        |> redirect(to: ~p"/")
    end
  end

  @doc "Handles Spotify's redirect back."
  # The user declined, or Spotify refused. Handled before anything else so a
  # denial reads as a normal outcome rather than an error.
  def callback(conn, %{"error" => error} = params) do
    Logger.info("Spotify authorization declined: #{error} #{params["error_description"]}")

    conn
    |> clear_oauth_session()
    |> put_flash(:info, "Spotify was not connected.")
    |> redirect(to: ~p"/")
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    expected_state = get_session(conn, @state_key)

    conn = clear_oauth_session(conn)

    cond do
      is_nil(expected_state) ->
        # No pending flow. Usually a stale tab or a refreshed callback URL.
        fail(conn, "That Spotify sign-in link has expired. Please try again.")

      not secure_compare(state, expected_state) ->
        Logger.warning("Spotify callback state mismatch — possible CSRF attempt")
        fail(conn, "That Spotify sign-in could not be verified. Please try again.")

      true ->
        complete(conn, code)
    end
  end

  def callback(conn, _params) do
    fail(conn, "That Spotify sign-in link was incomplete. Please try again.")
  end

  defp complete(conn, code) do
    with {:ok, tokens} <- OAuth.exchange_code(code),
         {:ok, user} <- Client.current_user(tokens.access_token),
         {:ok, connection} <- store(conn, user, tokens) do
      conn
      |> put_flash(:info, "Connected to Spotify as #{connection.display_name || "your account"}.")
      |> redirect(to: ~p"/")
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.error("Could not store Spotify connection: #{inspect(changeset.errors)}")
        fail(conn, "Could not save your Spotify connection.")

      {:error, error} ->
        # `Errata.report/2` emits telemetry with the error's full context and
        # classification, redacted — this is the seam a Sentry handler attaches
        # to. See docs/reference/jv-libraries.md.
        Errata.report(error, log: :error)
        fail(conn, Errata.display_message(error) || "Could not connect to Spotify.")
    end
  end

  # `GET /me` returns a flat object: `id`, `display_name`, `country`, `product`.
  #
  # `display_name` can be `null` for an account that never set one, which is why
  # the flash above falls back rather than interpolating it directly.
  defp store(conn, user, tokens) do
    Providers.connect(current_user_id(conn), :spotify, %{
      provider_user_id: to_string(user["id"]),
      display_name: user["display_name"],
      # Captured now because `create_playlist` needs the id in its path and
      # every read takes the country as `market`. Fetching either later would
      # mean a round trip to /me before every other round trip.
      #
      # `country` needs the `user-read-private` scope; without it Spotify omits
      # the field rather than failing, and `market` then goes unsent — which
      # degrades catalogue visibility silently. That is why the scope is
      # requested even though nothing displays the value.
      country: user["country"],
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      access_token_expires_at: tokens.expires_at,
      scopes: tokens.scopes
    })
  end

  defp fail(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/")
  end

  defp clear_oauth_session(conn), do: delete_session(conn, @state_key)

  # `Plug.Crypto.secure_compare/2` raises on differing lengths, which would leak
  # length through an exception; guard first so a mismatch is always a plain
  # `false`.
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and Plug.Crypto.secure_compare(a, b)
  end

  defp secure_compare(_a, _b), do: false
end
