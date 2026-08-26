defmodule OnePlaylistWeb.OAuthController do
  @moduledoc """
  The OAuth round trip, for every provider that has one: redirect out, handle
  the callback, store the connection.

  One controller and one pair of routes, `/auth/:provider` and
  `/auth/:provider/callback`. What differs between providers lives in
  `OnePlaylist.Providers.OAuthFlow` implementations; nothing here knows which
  provider it is serving beyond looking one up.

  This replaced two controllers that were the same file twice — see that
  behaviour's moduledoc on why the extraction waited for a second flow.

  ## What the session holds, and why

  Three values, stashed before redirecting and consumed on return. All three are
  deleted on **every** exit path, success or failure, so a stale flow cannot be
  replayed against a later attempt.

    * `state` — a CSRF nonce, and for a confidential flow the only defence
      there is. Without checking it, an attacker can hand a victim's browser a
      callback URL carrying the *attacker's* authorization code, and the
      victim's account silently ends up connected to the attacker's music
      service — which for this application means the attacker's playlists become
      readable and writable by somebody else's scheduled syncs. Compared in
      constant time.

    * `session` — whatever the flow asked to keep. For TIDAL that is the PKCE
      `code_verifier`, a secret whose hash went to the provider and which never
      leaves this server. It is stored and handed back **without being read**,
      which is what lets a new flow need something different without touching
      this file.

    * `provider` — which flow is in progress. Checked against the URL on the way
      back, so a callback arriving at the wrong provider's route is refused
      rather than handed a code its flow cannot use. Cheap, and the alternative
      is a confusing token exchange failure.
  """

  use OnePlaylistWeb, :controller
  use Errata

  import OnePlaylistWeb.UserAuth, only: [current_user_id: 1]

  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Connection

  require Logger

  @state_key "oauth_state"
  @session_key "oauth_session"
  @provider_key "oauth_provider"

  @doc "Starts the flow by redirecting to the provider."
  def start(conn, %{"provider" => provider}) do
    with {:ok, flow} <- flow(provider),
         {:ok, authorization} <- flow.authorization_url() do
      conn
      |> put_session(@provider_key, provider)
      |> put_session(@state_key, authorization.state)
      |> put_session(@session_key, authorization.session)
      |> redirect(external: authorization.url)
    else
      {:error, error} ->
        conn
        |> put_flash(
          :error,
          Errata.display_message(error) || "Could not start #{name(provider)} sign-in."
        )
        |> redirect(to: ~p"/")
    end
  end

  @doc "Handles the provider's redirect back."
  # The user declined, or the provider refused. Handled before anything else so
  # a denial reads as a normal outcome rather than an error.
  def callback(conn, %{"provider" => provider, "error" => error} = params) do
    Logger.info("#{provider} authorization declined: #{error} #{params["error_description"]}")

    conn
    |> clear_oauth_session()
    |> put_flash(:info, "#{name(provider)} was not connected.")
    |> redirect(to: ~p"/")
  end

  def callback(conn, %{"provider" => provider, "code" => code, "state" => state}) do
    expected_state = get_session(conn, @state_key)
    expected_provider = get_session(conn, @provider_key)
    stashed = get_session(conn, @session_key) || %{}

    conn = clear_oauth_session(conn)

    cond do
      is_nil(expected_state) ->
        # No pending flow. Usually a stale tab or a refreshed callback URL.
        fail(conn, "That #{name(provider)} sign-in link has expired. Please try again.")

      expected_provider != provider ->
        # A callback for a flow that was never started here. Refused rather than
        # attempted, because the code belongs to a different provider entirely.
        Logger.warning("#{provider} callback for a #{expected_provider} flow — refusing")
        fail(conn, "That #{name(provider)} sign-in could not be verified. Please try again.")

      not secure_compare(state, expected_state) ->
        Logger.warning("#{provider} callback state mismatch — possible CSRF attempt")
        fail(conn, "That #{name(provider)} sign-in could not be verified. Please try again.")

      true ->
        complete(conn, provider, code, stashed)
    end
  end

  def callback(conn, %{"provider" => provider}) do
    fail(conn, "That #{name(provider)} sign-in link was incomplete. Please try again.")
  end

  defp complete(conn, provider, code, stashed) do
    with {:ok, flow} <- flow(provider),
         {:ok, tokens} <- flow.exchange_code(code, stashed),
         {:ok, attrs} <- flow.connection_attrs(tokens),
         {:ok, connection} <- Providers.connect(current_user_id(conn), flow.provider(), attrs) do
      conn
      |> put_flash(
        :info,
        "Connected to #{name(provider)} as #{connection.display_name || "your account"}."
      )
      |> redirect(to: ~p"/")
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.error("Could not store #{provider} connection: #{inspect(changeset.errors)}")
        fail(conn, "Could not save your #{name(provider)} connection.")

      {:error, error} ->
        # `Errata.report/2` emits telemetry with the error's full context and
        # classification, redacted — this is the seam a Sentry handler attaches
        # to. See docs/reference/jv-libraries.md.
        Errata.report(error, log: :error)
        fail(conn, Errata.display_message(error) || "Could not connect to #{name(provider)}.")
    end
  end

  # `to_existing_atom` rather than `to_atom`, and looked up in the registry
  # afterwards. The segment comes from a URL, so anything unrecognised is a
  # forged or stale request rather than a choice — and a rescue rather than a
  # guard because an atom that has never existed raises instead of returning.
  defp flow(provider) when is_binary(provider) do
    Providers.oauth_flow(String.to_existing_atom(provider))
  rescue
    ArgumentError ->
      {:error,
       Errata.create(OnePlaylist.Providers.ProviderNotSupported, context: %{provider: provider})}
  end

  # The service's own name, for a sentence a person reads. Falls back to the
  # path segment, which is the honest answer for a provider this application
  # does not know — it is what the user asked for.
  defp name(provider) when is_binary(provider) do
    case Enum.find(Connection.providers(), &(Atom.to_string(&1) == provider)) do
      nil -> provider
      known -> Connection.display_name(known)
    end
  end

  defp fail(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/")
  end

  defp clear_oauth_session(conn) do
    conn
    |> delete_session(@state_key)
    |> delete_session(@session_key)
    |> delete_session(@provider_key)
  end

  # `Plug.Crypto.secure_compare/2` raises on differing lengths, which would leak
  # length through an exception; guard first so a mismatch is always a plain
  # `false`.
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and Plug.Crypto.secure_compare(a, b)
  end

  defp secure_compare(_a, _b), do: false
end
