defmodule OnePlaylistWeb.ConnectionLiveTest do
  @moduledoc """
  The connections screen.

  Two things here are worth testing for their own sake rather than as coverage:
  that a credential is proved before it is stored, and that a rejected one is
  not echoed back into the page. Both fail *quietly* — the first as a transfer
  that breaks days later, the second as a password sitting in the DOM.
  """

  use OnePlaylistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Req.Test, only: [set_req_test_from_context: 1]

  alias OnePlaylist.AuthFixtures
  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Navidrome

  @password "hunter2"

  setup :set_req_test_from_context

  setup %{conn: conn} do
    user_id = AuthFixtures.user_id_fixture()

    %{conn: log_in_user(conn, user_id), user_id: user_id}
  end

  defp ok(body), do: %{"subsonic-response" => Map.merge(%{"status" => "ok"}, body)}

  defp failed(code, message) do
    %{
      "subsonic-response" => %{
        "status" => "failed",
        "error" => %{"code" => code, "message" => message}
      }
    }
  end

  defp stub_accepts do
    Req.Test.stub(Navidrome, fn conn ->
      Req.Test.json(conn, ok(%{"user" => %{"username" => "admin"}}))
    end)
  end

  defp fill_in(live, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          "server_url" => "http://music.local:4533",
          "username" => "admin",
          "password" => @password
        },
        overrides
      )

    live
    |> form("#subsonic-connect-form", subsonic: params)
    |> render_submit()
  end

  defp open_form(live) do
    live |> element("button", "Connect") |> render_click()
    live
  end

  describe "the page" do
    test "offers every provider that has an adapter", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/connections")

      assert html =~ "TIDAL"
      assert html =~ "Subsonic server"
    end

    test "sends TIDAL through OAuth and Subsonic through a form", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/connections")

      assert html =~ ~s|href="/auth/tidal"|
      refute html =~ "Server address", "the form is behind a click, not always open"

      assert open_form(live) |> render() =~ "Server address"
    end

    test "says why the other services are absent", %{conn: conn} do
      # Not decoration. Without it the page reads as "we only built two", when
      # the reason is a paid membership, a five-user cap and a closed API.
      {:ok, _live, html} = live(conn, ~p"/connections")

      assert html =~ "Apple Music"
      assert html =~ "Spotify"
    end
  end

  describe "connecting a Subsonic server" do
    test "stores the connection once the server accepts the credential", %{
      conn: conn,
      user_id: user_id
    } do
      stub_accepts()

      {:ok, live, _html} = live(conn, ~p"/connections")

      live |> open_form() |> fill_in()
      html = render_async(live)

      assert html =~ "music.local"
      assert {:ok, connection} = Providers.fetch_connection(user_id, :navidrome)
      assert connection.access_token == @password
    end

    test "a rejected credential is reported and nothing is stored", %{
      conn: conn,
      user_id: user_id
    } do
      Req.Test.stub(Navidrome, fn conn ->
        Req.Test.json(conn, failed(40, "Wrong username or password"))
      end)

      {:ok, live, _html} = live(conn, ~p"/connections")

      live |> open_form() |> fill_in(%{"password" => "wrong"})
      html = render_async(live)

      # Not APIError's own wording, which is "reconnect to continue" — right for
      # a transfer failing on a credential that used to work, and meaningless on
      # the form where the credential was just typed for the first time.
      assert html =~ "rejected that username and password"
      refute html =~ "reconnect to continue"
      assert Providers.list_connections(user_id) == []
    end

    test "a server that cannot be reached blames the server, not the retrying", %{conn: conn} do
      # ExternalService wraps the failure in a RetriesExhausted whose own message
      # is about giving up. Showing that instead of "connection refused" tells
      # the user nothing they can act on.
      Req.Test.stub(Navidrome, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      {:ok, live, _html} = live(conn, ~p"/connections")

      live |> open_form() |> fill_in()
      html = render_async(live)

      assert html =~ "connection refused"
      refute html =~ "retries", "the user did not ask us to retry and cannot fix it"
    end

    test "an invalid URL is caught before anything is sent", %{conn: conn} do
      Req.Test.stub(Navidrome, fn _conn ->
        flunk("a URL with no scheme must not become a request")
      end)

      {:ok, live, _html} = live(conn, ~p"/connections")

      html = live |> open_form() |> fill_in(%{"server_url" => "localhost:4533"})

      assert html =~ "must start with http:// or https://"
    end

    test "the password is never sent back down the wire", %{conn: conn} do
      # A failed submit is exactly when a form wants to be helpful and re-fill
      # itself. For this field that would put the password into the rendered
      # HTML — the page source, the payload of every later patch, and anything
      # logging in between.
      #
      # This is a claim about what the *server* renders. The box on screen still
      # shows what the user typed, because that is a DOM property the server
      # never touched; verified in the browser, and deliberate.
      Req.Test.stub(Navidrome, fn conn ->
        Req.Test.json(conn, failed(40, "Wrong username or password"))
      end)

      {:ok, live, _html} = live(conn, ~p"/connections")

      invalid_url = live |> open_form() |> fill_in(%{"server_url" => "nope"})
      refute invalid_url =~ @password

      fill_in(live)
      refute render_async(live) =~ @password
    end
  end

  describe "disconnecting" do
    setup %{user_id: user_id} do
      stub_accepts()

      {:ok, connection} =
        Providers.connect_subsonic(user_id, %OnePlaylist.Providers.SubsonicCredentials{
          server_url: "http://music.local:4533",
          username: "admin",
          password: @password
        })

      %{connection: connection}
    end

    test "removes the connection", %{conn: conn, user_id: user_id} do
      {:ok, live, html} = live(conn, ~p"/connections")
      assert html =~ "Connected"

      html = live |> element("button", "Disconnect") |> render_click()

      assert html =~ "Connect"
      assert Providers.list_connections(user_id) == []
    end

    test "refuses a provider the schema has never heard of", %{conn: conn, user_id: user_id} do
      # The provider arrives from the client. `String.to_atom/1` on it would let
      # anyone with a websocket grow the atom table until the node dies.
      {:ok, live, _html} = live(conn, ~p"/connections")

      html = render_click(live, "disconnect", %{"provider" => "not_a_provider"})

      assert html =~ "not a service this application knows"
      assert [_still_there] = Providers.list_connections(user_id)
    end
  end

  describe "authentication" do
    test "signed-out visitors are sent to sign in" do
      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               live(Phoenix.ConnTest.build_conn(), ~p"/connections")
    end
  end
end
