defmodule OnePlaylistWeb.OAuthControllerTest do
  @moduledoc """
  The shared OAuth round trip, driven through both flows.

  TIDAL carries the detailed cases, because it is the flow with something to
  lose across the two legs — a PKCE verifier. Spotify's block is deliberately
  short and asks only what the *sharing* could break: that a confidential flow
  with an empty `session` still completes, and that the controller does not
  quietly assume a verifier exists.

  The cross-provider block is new with the extraction and could not have existed
  before: one controller serving two providers can confuse them, and two
  controllers could not.
  """

  use OnePlaylistWeb.ConnCase, async: true

  import Req.Test, only: [set_req_test_from_context: 1]

  # Several test files stub Req under this same name and all run async. Without
  # per-test ownership they overwrite one another, and a test intermittently
  # gets a response meant for a different one. Same idea as the Ecto sandbox:
  # private ownership for async tests, shared for sync ones.
  setup :set_req_test_from_context

  import OnePlaylist.AuthFixtures

  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Spotify
  alias OnePlaylist.Providers.Tidal

  setup %{conn: conn} do
    user_id = user_id_fixture()
    %{conn: log_in_user(conn, user_id), user_id: user_id}
  end

  describe "GET /auth/tidal" do
    test "redirects to TIDAL and stashes the PKCE verifier and state", %{conn: conn} do
      conn = get(conn, ~p"/auth/tidal")

      assert redirected_to(conn, 302) =~ "https://login.tidal.com/authorize"

      %{"code_verifier" => verifier} = get_session(conn, "oauth_session")
      state = get_session(conn, "oauth_state")

      assert is_binary(verifier)
      assert is_binary(state)
      assert get_session(conn, "oauth_provider") == "tidal"

      # The verifier must not be what we sent TIDAL — only its hash may travel.
      query = conn |> redirected_to() |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      refute query["code_challenge"] == verifier
      assert query["state"] == state
    end

    test "requires a signed-in user" do
      conn = build_conn() |> get(~p"/auth/tidal")

      assert redirected_to(conn) == ~p"/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "signed in"
    end
  end

  describe "GET /auth/tidal/callback" do
    test "stores a connection on success", %{conn: conn, user_id: user_id} do
      Req.Test.stub(Tidal, fn c ->
        case c.request_path do
          "/v1/oauth2/token" ->
            Req.Test.json(c, %{
              "access_token" => "at-live",
              "refresh_token" => "rt-live",
              "expires_in" => 3600,
              "scope" => "playlists.read playlists.write"
            })

          "/v2/users/me" ->
            Req.Test.json(c, %{
              "data" => %{"id" => "98765", "attributes" => %{"username" => "jason"}}
            })
        end
      end)

      conn = start_flow(conn)
      state = get_session(conn, "oauth_state")

      conn = get(conn, ~p"/auth/tidal/callback?code=the-code&state=#{state}")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "jason"

      assert {:ok, connection} = Providers.fetch_connection(user_id, :tidal)
      assert connection.access_token == "at-live"
      assert connection.refresh_token == "rt-live"
      assert connection.provider_user_id == "98765"
      assert connection.display_name == "jason"

      # The one-shot secrets must not survive the exchange.
      assert get_session(conn, "oauth_session") == nil
      assert get_session(conn, "oauth_state") == nil
      assert get_session(conn, "oauth_provider") == nil
    end

    test "rejects a mismatched state", %{conn: conn, user_id: user_id} do
      Req.Test.stub(Tidal, fn _c -> flunk("must not exchange a code it cannot verify") end)

      conn = start_flow(conn)
      conn = get(conn, ~p"/auth/tidal/callback?code=attacker-code&state=wrong-state")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "could not be verified"
      assert {:error, _} = Providers.fetch_connection(user_id, :tidal)
    end

    test "rejects a callback with no flow in progress", %{conn: conn} do
      Req.Test.stub(Tidal, fn _c -> flunk("no verifier, so nothing to exchange") end)

      conn = get(conn, ~p"/auth/tidal/callback?code=c&state=s")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"
    end

    test "handles the user declining", %{conn: conn, user_id: user_id} do
      conn = start_flow(conn)
      conn = get(conn, ~p"/auth/tidal/callback?error=access_denied")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "not connected"
      assert {:error, _} = Providers.fetch_connection(user_id, :tidal)

      # A declined attempt must still clear the pending flow, or the verifier
      # lingers and can be replayed against a later callback.
      assert get_session(conn, "oauth_session") == nil
    end

    test "reports a failed token exchange without storing anything",
         %{conn: conn, user_id: user_id} do
      Req.Test.stub(Tidal, fn c ->
        c
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_grant", "error_description" => "bad code"})
      end)

      conn = start_flow(conn)
      state = get_session(conn, "oauth_state")
      conn = get(conn, ~p"/auth/tidal/callback?code=stale&state=#{state}")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) != nil
      assert {:error, _} = Providers.fetch_connection(user_id, :tidal)
    end

    test "does not store a connection when the token cannot be used",
         %{conn: conn, user_id: user_id} do
      # The exchange succeeds but /users/me rejects the token. Storing it anyway
      # would leave a connection that looks healthy and is not.
      Req.Test.stub(Tidal, fn c ->
        case c.request_path do
          "/v1/oauth2/token" ->
            Req.Test.json(c, %{"access_token" => "at", "expires_in" => 3600})

          "/v2/users/me" ->
            c
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(%{"errors" => [%{"code" => "UNAUTHORIZED"}]})
        end
      end)

      conn = start_flow(conn)
      state = get_session(conn, "oauth_state")
      conn = get(conn, ~p"/auth/tidal/callback?code=c&state=#{state}")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) != nil
      assert {:error, _} = Providers.fetch_connection(user_id, :tidal)
    end
  end

  describe "a confidential flow" do
    # Spotify's `session` is empty, which is the whole difference between the
    # two flows. What this asks is whether the sharing broke that: a controller
    # that assumed a verifier would fail here and nowhere else.
    test "completes with nothing stashed but the nonce", %{conn: conn, user_id: user_id} do
      Req.Test.stub(Spotify, fn c ->
        case c.request_path do
          "/api/token" ->
            Req.Test.json(c, %{
              "access_token" => "at-spotify",
              "refresh_token" => "rt-spotify",
              "expires_in" => 3600,
              "scope" => "playlist-read-private"
            })

          "/v1/me" ->
            Req.Test.json(c, %{"id" => "122670790", "display_name" => "Jason", "country" => "US"})
        end
      end)

      conn = get(conn, ~p"/auth/spotify")

      assert redirected_to(conn, 302) =~ "https://accounts.spotify.com/authorize"
      assert get_session(conn, "oauth_session") == %{}
      assert get_session(conn, "oauth_provider") == "spotify"

      state = get_session(conn, "oauth_state")
      conn = get(conn, ~p"/auth/spotify/callback?code=the-code&state=#{state}")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Jason"

      assert {:ok, connection} = Providers.fetch_connection(user_id, :spotify)
      assert connection.provider_user_id == "122670790"
      assert connection.country == "US"
    end
  end

  describe "one controller, two providers" do
    # Neither of these could exist before the extraction: two controllers cannot
    # confuse each other's flows, and one can.
    test "refuses a callback for a provider whose flow was never started",
         %{conn: conn, user_id: user_id} do
      Req.Test.stub(Spotify, fn _c -> flunk("must not exchange a code from another flow") end)

      # Start TIDAL, come back at Spotify's callback carrying TIDAL's nonce.
      conn = start_flow(conn)
      state = get_session(conn, "oauth_state")

      conn = get(conn, ~p"/auth/spotify/callback?code=the-code&state=#{state}")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "could not be verified"
      assert {:error, _} = Providers.fetch_connection(user_id, :spotify)
      assert {:error, _} = Providers.fetch_connection(user_id, :tidal)
    end

    test "starting a second flow replaces the first", %{conn: conn} do
      conn = start_flow(conn)
      tidal_state = get_session(conn, "oauth_state")

      conn = get(conn, ~p"/auth/spotify")

      assert get_session(conn, "oauth_provider") == "spotify"
      refute get_session(conn, "oauth_state") == tidal_state
      assert get_session(conn, "oauth_session") == %{}
    end

    # A provider with no OAuth flow at all. `:navidrome` is a real atom in
    # `Connection.providers/0` and is connected by a form, so it survives
    # `to_existing_atom` and has to be refused by the registry.
    test "refuses a provider that has no OAuth flow", %{conn: conn} do
      conn = get(conn, ~p"/auth/navidrome")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) != nil
    end

    # And one that is not a provider at all, which must not raise on the way to
    # being refused — `to_existing_atom` raises for an atom the VM has never
    # seen, and a 500 on a forged URL is a worse answer than a flash.
    test "refuses a segment that names nothing", %{conn: conn} do
      conn = get(conn, ~p"/auth/not-a-provider")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) != nil
    end
  end

  defp start_flow(conn), do: get(conn, ~p"/auth/tidal")
end
