defmodule OnePlaylistWeb.TidalAuthController do
  @moduledoc """
  The TIDAL OAuth round trip: redirect out, handle the callback, store the
  connection.

  ## What the session holds, and why

  Two values are stashed before redirecting and consumed on return:

    * `code_verifier` — the PKCE secret. It never leaves this server; only its
      SHA-256 hash went to TIDAL. Whoever holds the verifier can complete the
      exchange, so it lives in the signed session and is deleted the moment it
      is used.
    * `state` — a CSRF nonce. Without checking it, an attacker can hand a
      victim's browser a callback URL carrying the *attacker's* authorization
      code, and the victim's account silently ends up connected to the
      attacker's TIDAL account. Comparison is constant-time.

  Both are deleted on every exit path, success or failure, so a stale verifier
  cannot be replayed against a later attempt.
  """

  use OnePlaylistWeb, :controller

  import OnePlaylistWeb.UserAuth, only: [current_user_id: 1]

  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Tidal.Client
  alias OnePlaylist.Providers.Tidal.OAuth

  require Logger

  @verifier_key "tidal_code_verifier"
  @state_key "tidal_oauth_state"

  @doc "Starts the flow by redirecting to TIDAL."
  def start(conn, _params) do
    case OAuth.authorization_url() do
      {:ok, %{url: url, code_verifier: verifier, state: state}} ->
        conn
        |> put_session(@verifier_key, verifier)
        |> put_session(@state_key, state)
        |> redirect(external: url)

      {:error, error} ->
        conn
        |> put_flash(:error, Errata.display_message(error) || "Could not start TIDAL sign-in.")
        |> redirect(to: ~p"/")
    end
  end

  @doc "Handles TIDAL's redirect back."
  # The user declined, or TIDAL refused. Handled before anything else so a
  # denial reads as a normal outcome rather than an error.
  def callback(conn, %{"error" => error} = params) do
    Logger.info("TIDAL authorization declined: #{error} #{params["error_description"]}")

    conn
    |> clear_oauth_session()
    |> put_flash(:info, "TIDAL was not connected.")
    |> redirect(to: ~p"/")
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    expected_state = get_session(conn, @state_key)
    verifier = get_session(conn, @verifier_key)

    conn = clear_oauth_session(conn)

    cond do
      is_nil(expected_state) or is_nil(verifier) ->
        # No pending flow. Usually a stale tab or a refreshed callback URL.
        fail(conn, "That TIDAL sign-in link has expired. Please try again.")

      not secure_compare(state, expected_state) ->
        Logger.warning("TIDAL callback state mismatch — possible CSRF attempt")
        fail(conn, "That TIDAL sign-in could not be verified. Please try again.")

      true ->
        complete(conn, code, verifier)
    end
  end

  def callback(conn, _params) do
    fail(conn, "That TIDAL sign-in link was incomplete. Please try again.")
  end

  defp complete(conn, code, verifier) do
    with {:ok, tokens} <- OAuth.exchange_code(code, verifier),
         {:ok, user} <- Client.current_user(tokens.access_token),
         {:ok, connection} <- store(conn, user, tokens) do
      conn
      |> put_flash(:info, "Connected to TIDAL as #{connection.display_name || "your account"}.")
      |> redirect(to: ~p"/")
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.error("Could not store TIDAL connection: #{inspect(changeset.errors)}")
        fail(conn, "Could not save your TIDAL connection.")

      {:error, error} ->
        # `Errata.report/2` emits telemetry with the error's full context and
        # classification, redacted — this is the seam a Sentry handler attaches
        # to. See docs/reference/jv-libraries.md.
        Errata.report(error, log: :error)
        fail(conn, Errata.display_message(error) || "Could not connect to TIDAL.")
    end
  end

  # TIDAL returns a JSON:API resource whose identity lives in `id` and
  # `attributes`. Verified live: `attributes.username` and `attributes.country`
  # are both populated for a real account. `display_name/1` still falls through
  # several attribute names, because which of them a given account carries
  # depends on how it was registered.
  defp store(conn, user, tokens) do
    Providers.connect(current_user_id(conn), :tidal, %{
      provider_user_id: to_string(user["id"]),
      display_name: display_name(user),
      # Captured now because most TIDAL endpoints take it as `countryCode`, and
      # fetching it later would mean a round trip to /users/me before every
      # other round trip.
      country: get_in(user, ["attributes", "country"]),
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      access_token_expires_at: tokens.expires_at,
      scopes: tokens.scopes
    })
  end

  defp display_name(%{"attributes" => attributes}) when is_map(attributes) do
    attributes["username"] || attributes["firstName"] || attributes["email"]
  end

  defp display_name(_user), do: nil

  defp fail(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/")
  end

  defp clear_oauth_session(conn) do
    conn
    |> delete_session(@verifier_key)
    |> delete_session(@state_key)
  end

  # `Plug.Crypto.secure_compare/2` raises on differing lengths, which would leak
  # length through an exception; guard first so a mismatch is always a plain
  # `false`.
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and Plug.Crypto.secure_compare(a, b)
  end

  defp secure_compare(_a, _b), do: false
end
