defmodule OnePlaylistWeb.ExportLiveTest do
  @moduledoc """
  The export page.

  The provider read is stubbed with `Req.Test`, so most of this needs no
  Supabase. The one test that stores a file is tagged, because storing is the
  half `Exports` exists to do.
  """

  use OnePlaylistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Req.Test, only: [set_req_test_from_context: 1]
  import OnePlaylist.AuthFixtures

  alias OnePlaylist.Providers

  setup :set_req_test_from_context

  defp connect_tidal(user_id) do
    {:ok, _connection} =
      Providers.connect(user_id, :tidal, %{
        provider_user_id: "67373615",
        display_name: "TIDAL",
        access_token: "at",
        refresh_token: "rt",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
        country: "US"
      })
  end

  # One playlist, then its tracks. Enough for the page to render and for an
  # export to have something to write.
  defp stub_tidal do
    Req.Test.stub(OnePlaylist.Providers.Tidal, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      body =
        cond do
          String.contains?(conn.request_path, "/items") ->
            %{
              "data" => [%{"type" => "tracks", "id" => "t1"}],
              "included" => [
                %{
                  "type" => "tracks",
                  "id" => "t1",
                  "attributes" => %{
                    "title" => "Corduroy",
                    "isrc" => "USSM11100234",
                    "duration" => "PT4M38S"
                  }
                }
              ],
              "links" => %{}
            }

          true ->
            %{
              "data" => [
                %{
                  "type" => "playlists",
                  "id" => "p1",
                  "attributes" => %{"name" => "Road Trip 2026", "numberOfItems" => 1}
                }
              ],
              "links" => %{}
            }
        end

      Req.Test.json(conn, body)
    end)
  end

  describe "with nothing connected but the library" do
    # Every user has one, so this is what a brand-new account actually sees.
    # Exporting a library playlist to CSV needs no external service at all, so
    # the page is usable rather than a dead end — which is the point of the
    # library existing.
    test "offers the library rather than telling you to connect something", %{conn: conn} do
      conn = log_in_user(conn, session_fixture())

      {:ok, _view, html} = live(conn, ~p"/exports/new")

      refute html =~ "No music service connected"
      assert html =~ "One Playlist"
    end

    test "the empty state is still reachable, because ensuring a library can fail", %{
      conn: conn
    } do
      # `UserAuth.put_user_session/2` logs and continues if the library cannot be
      # made, rather than refusing the sign-in — so a user with no connections at
      # all is a state this page still has to render.
      user_id = user_id_fixture()
      conn = log_in_user(conn, session_fixture(user_id: user_id))

      {:ok, _removed} = Providers.disconnect(user_id, :library)

      {:ok, _view, html} = live(conn, ~p"/exports/new")

      assert html =~ "No music service connected"
    end
  end

  describe "with a connected service" do
    setup %{conn: conn} do
      user_id = user_id_fixture()
      connect_tidal(user_id)
      stub_tidal()

      %{conn: log_in_user(conn, session_fixture(user_id: user_id)), user_id: user_id}
    end

    test "lists the playlists with something to click", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/exports/new")

      html = render_async(view)

      assert html =~ "Road Trip 2026"
      assert html =~ "Export CSV"
    end

    test "a failed export is reported rather than left spinning", %{conn: conn} do
      # The session's tokens are fixtures, so Storage refuses the write. What
      # matters is that the page says so and the button comes back.
      {:ok, view, _html} = live(conn, ~p"/exports/new")
      render_async(view)

      html =
        view
        |> element("button[phx-value-id='p1']")
        |> render_click()

      html = if html =~ "export-error", do: html, else: render_async(view)

      assert html =~ "export-error"
      refute html =~ "Exporting…"
    end
  end

  describe "end to end" do
    @tag :supabase
    test "an export becomes a downloadable file", %{conn: conn} do
      unless OnePlaylist.Supabase.configured?(), do: flunk("Supabase is not configured")

      email = "exportlive-#{System.system_time(:nanosecond)}@one-playlist.test"
      {:ok, session} = OnePlaylist.Accounts.sign_up(email, "a-perfectly-fine-password")
      connect_tidal(session.user_id)
      stub_tidal()

      {:ok, view, _html} = live(log_in_user(conn, session), ~p"/exports/new")
      render_async(view)

      _ = view |> element("button[phx-value-id='p1']") |> render_click()
      html = render_async(view)

      assert html =~ "export-ready"

      # The downloaded name keeps its spaces; the stored key does not. That
      # split is the whole reason `signed_url/3` takes `:download`.
      assert html =~ "Road Trip 2026.csv"
      assert html =~ "token="
    end
  end
end
