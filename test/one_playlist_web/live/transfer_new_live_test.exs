defmodule OnePlaylistWeb.TransferNewLiveTest do
  @moduledoc """
  Choosing what to transfer, and where to.

  This page had no tests at all, which is how it shipped hard coded to
  TIDAL → TIDAL at five separate call sites while the application's entire
  premise is moving a playlist between two *different* services.
  """

  use OnePlaylistWeb.ConnCase, async: false

  import OnePlaylist.AuthFixtures
  import Phoenix.LiveViewTest
  import Req.Test, only: [set_req_test_from_context: 1]

  alias OnePlaylist.Providers
  alias OnePlaylist.Transfers

  @password "hunter2"

  setup :set_req_test_from_context

  defp connect_tidal(user_id) do
    {:ok, connection} =
      Providers.connect(user_id, :tidal, %{
        provider_user_id: "67373615",
        display_name: "TIDAL",
        access_token: "at",
        refresh_token: "rt",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
        country: "US"
      })

    connection
  end

  defp connect_navidrome(user_id) do
    {:ok, connection} =
      Providers.connect_subsonic(user_id, %OnePlaylist.Providers.SubsonicCredentials{
        server_url: "http://music.local:4533",
        username: "admin",
        password: @password
      })

    connection
  end

  defp stub_tidal do
    Req.Test.stub(OnePlaylist.Providers.Tidal, fn conn ->
      Req.Test.json(Plug.Conn.fetch_query_params(conn), %{
        "data" => [
          %{
            "type" => "playlists",
            "id" => "tidal-1",
            "attributes" => %{"name" => "Road Trip 2026", "numberOfItems" => 12}
          }
        ],
        "links" => %{}
      })
    end)
  end

  # Subsonic answers HTTP 200 for everything, including failures, and wraps its
  # payload in `subsonic-response` — see `docs/reference/domain.md`.
  defp stub_navidrome do
    Req.Test.stub(OnePlaylist.Providers.Navidrome, fn conn ->
      Req.Test.json(Plug.Conn.fetch_query_params(conn), %{
        "subsonic-response" => %{
          "status" => "ok",
          "version" => "1.16.1",
          "playlists" => %{
            "playlist" => [
              %{"id" => "nav-1", "name" => "Shelf", "songCount" => 30}
            ]
          }
        }
      })
    end)
  end

  describe "with nothing connected but the library" do
    test "still offers a form, because the library is always somewhere to go", %{conn: conn} do
      conn = log_in_user(conn, user_id_fixture())

      {:ok, _view, html} = live(conn, ~p"/transfers/new")

      refute html =~ "No music service connected"
      assert html =~ ~s(id="source")
      assert html =~ "One Playlist"
    end

    test "says so when there is genuinely nothing", %{conn: conn} do
      # Reachable because `ensure_library/1` failing is logged rather than
      # raised, so a session can exist without one.
      user_id = user_id_fixture()
      conn = log_in_user(conn, user_id)

      {:ok, _removed} = Providers.disconnect(user_id, :library)

      {:ok, _view, html} = live(conn, ~p"/transfers/new")

      assert html =~ "No music service connected"
      refute html =~ ~s(id="source")
    end
  end

  describe "with two connected services" do
    setup %{conn: conn} do
      user_id = user_id_fixture()

      stub_navidrome()
      connect_navidrome(user_id)
      connect_tidal(user_id)
      stub_tidal()

      %{conn: log_in_user(conn, user_id), user_id: user_id}
    end

    test "offers both ends by name, not by internal atom", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/transfers/new")
      html = render_async(view)

      assert html =~ ~s(id="source")
      assert html =~ ~s(id="destination")

      assert html =~ "TIDAL"
      assert html =~ "Navidrome"

      refute html =~ ">tidal<", "the internal atom should never reach the page"
    end

    test "transfers from the chosen source to the chosen destination", %{
      conn: conn,
      user_id: user_id
    } do
      {:ok, view, _html} = live(conn, ~p"/transfers/new")
      render_async(view)

      # Whichever service came first, drive both ends explicitly so this asserts
      # the choice rather than the default.
      view
      |> form("form[phx-change='source']", %{"provider" => "navidrome"})
      |> render_change()

      view
      |> form("form[phx-change='destination']", %{"provider" => "tidal"})
      |> render_change()

      render_async(view)

      view |> element("button[phx-value-id='nav-1']") |> render_click()
      view |> element("button", "Transfer to TIDAL") |> render_click()

      assert [transfer] = Transfers.list(user_id)

      assert transfer.source_provider == :navidrome
      assert transfer.destination_provider == :tidal
      assert transfer.source_playlist_id == "nav-1"
      assert transfer.source_playlist_name == "Shelf"

      assert transfer.destination_playlist_name == "Shelf",
             "across services the original name is right; (copy) would be noise"
    end

    test "and in the other direction, so neither end is quietly fixed", %{
      conn: conn,
      user_id: user_id
    } do
      # The mirror of the test above, and not redundant with it: with only the
      # first, hard coding the *destination* back to `:tidal` still passes.
      {:ok, view, _html} = live(conn, ~p"/transfers/new")
      render_async(view)

      view |> form("form[phx-change='source']", %{"provider" => "tidal"}) |> render_change()

      view
      |> form("form[phx-change='destination']", %{"provider" => "navidrome"})
      |> render_change()

      render_async(view)

      view |> element("button[phx-value-id='tidal-1']") |> render_click()
      view |> element("button", "Transfer to Navidrome") |> render_click()

      assert [transfer] = Transfers.list(user_id)

      assert transfer.source_provider == :tidal
      assert transfer.destination_provider == :navidrome
      assert transfer.source_playlist_id == "tidal-1"
    end

    test "changing the source reloads its playlists and drops the selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/transfers/new")
      render_async(view)

      view
      |> form("form[phx-change='source']", %{"provider" => "tidal"})
      |> render_change()

      render_async(view)
      view |> element("button[phx-value-id='tidal-1']") |> render_click()

      html =
        view
        |> form("form[phx-change='source']", %{"provider" => "navidrome"})
        |> render_change()

      html = if html =~ "Shelf", do: html, else: render_async(view)

      assert html =~ "Shelf", "the new source's playlists should be listed"
      refute html =~ "Road Trip 2026", "the previous source's should be gone"

      # A playlist id belongs to the service it came from. Carrying one across
      # would queue a transfer asking Navidrome for a TIDAL id.
      assert html =~ ~s(disabled),
             "the Transfer button should be disabled again with nothing selected"
    end

    test "a copy within one service is named so it can be told apart", %{
      conn: conn,
      user_id: user_id
    } do
      {:ok, view, _html} = live(conn, ~p"/transfers/new")
      render_async(view)

      for end_ <- ~w(source destination) do
        view |> form("form[phx-change='#{end_}']", %{"provider" => "tidal"}) |> render_change()
      end

      render_async(view)

      view |> element("button[phx-value-id='tidal-1']") |> render_click()
      view |> element("button", "Transfer to TIDAL") |> render_click()

      assert [transfer] = Transfers.list(user_id)
      assert transfer.source_provider == :tidal
      assert transfer.destination_provider == :tidal

      assert transfer.destination_playlist_name == "Road Trip 2026 (copy)",
             "two playlists of the same name in one library are indistinguishable"
    end

    test "a forged provider is refused rather than queued", %{conn: conn} do
      # The LiveView is linked to the test process, so its refusal arrives as an
      # exit signal rather than as a return value.
      Process.flag(:trap_exit, true)

      {:ok, view, _html} = live(conn, ~p"/transfers/new")
      render_async(view)

      # Sent as a raw event rather than through `form/3`, which refuses a value
      # the page never rendered — correctly, and so it cannot express this. A
      # forged provider does not come from the form either.
      #
      # `:spotify` is a real atom in `Connection.providers/0` and not a service
      # this user has connected, so it survives `to_existing_atom` and has to be
      # refused by the check against the user's own connections.
      assert catch_exit(render_hook(view, "destination", %{"provider" => "spotify"}))
    end
  end
end
