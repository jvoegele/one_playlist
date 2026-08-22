defmodule OnePlaylistWeb.TidalAuthControllerTest do
  use OnePlaylistWeb.ConnCase, async: true

  import OnePlaylist.AuthFixtures

  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Tidal

  setup %{conn: conn} do
    user_id = user_id_fixture()
    %{conn: sign_in(conn, user_id), user_id: user_id}
  end

  describe "GET /auth/tidal" do
    test "redirects to TIDAL and stashes the PKCE verifier and state", %{conn: conn} do
      conn = get(conn, ~p"/auth/tidal")

      assert redirected_to(conn, 302) =~ "https://login.tidal.com/authorize"

      verifier = get_session(conn, "tidal_code_verifier")
      state = get_session(conn, "tidal_oauth_state")

      assert is_binary(verifier)
      assert is_binary(state)

      # The verifier must not be what we sent TIDAL — only its hash may travel.
      query = conn |> redirected_to() |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      refute query["code_challenge"] == verifier
      assert query["state"] == state
    end

    test "requires a signed-in user" do
      conn = build_conn() |> get(~p"/auth/tidal")

      assert redirected_to(conn) == ~p"/"
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
      state = get_session(conn, "tidal_oauth_state")

      conn = get(conn, ~p"/auth/tidal/callback?code=the-code&state=#{state}")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "jason"

      assert {:ok, connection} = Providers.fetch_connection(user_id, :tidal)
      assert connection.access_token == "at-live"
      assert connection.refresh_token == "rt-live"
      assert connection.provider_user_id == "98765"
      assert connection.display_name == "jason"

      # The one-shot secrets must not survive the exchange.
      assert get_session(conn, "tidal_code_verifier") == nil
      assert get_session(conn, "tidal_oauth_state") == nil
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
      assert get_session(conn, "tidal_code_verifier") == nil
    end

    test "reports a failed token exchange without storing anything",
         %{conn: conn, user_id: user_id} do
      Req.Test.stub(Tidal, fn c ->
        c
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_grant", "error_description" => "bad code"})
      end)

      conn = start_flow(conn)
      state = get_session(conn, "tidal_oauth_state")
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
      state = get_session(conn, "tidal_oauth_state")
      conn = get(conn, ~p"/auth/tidal/callback?code=c&state=#{state}")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) != nil
      assert {:error, _} = Providers.fetch_connection(user_id, :tidal)
    end
  end

  defp start_flow(conn), do: get(conn, ~p"/auth/tidal")

  defp sign_in(conn, user_id) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_id", user_id)
  end
end
