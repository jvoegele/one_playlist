defmodule OnePlaylistWeb.PlaylistLiveTest do
  @moduledoc """
  The two screens that make the library something a person can use: the list of
  everything they have, and the editor for one library playlist.

  What is worth testing here is the two things these pages do that no other
  screen in this application does — they *change* a user's own data, and they
  put several services on one page where each can fail on its own.
  """

  use OnePlaylistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Req.Test, only: [set_req_test_from_context: 1]

  alias OnePlaylist.AuthFixtures
  alias OnePlaylist.Library
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers

  setup :set_req_test_from_context

  setup %{conn: conn} do
    user_id = AuthFixtures.user_id_fixture()

    %{conn: log_in_user(conn, user_id), user_id: user_id}
  end

  defp track(title, attrs \\ %{}) do
    struct!(
      %Track{
        provider: :tidal,
        provider_id: "t-#{System.unique_integer([:positive])}",
        title: title,
        artists: ["Pearl Jam"]
      },
      attrs
    )
  end

  defp playlist_with(user_id, name, titles) do
    {:ok, playlist} = Library.create_playlist(user_id, name)
    Library.append(user_id, playlist.id, Enum.map(titles, &track/1))

    playlist
  end

  describe "my playlists" do
    test "lists the library, and says so when it is empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/playlists")

      assert html =~ "One Playlist"
      assert html =~ "Nothing here yet"
    end

    test "shows each library playlist with its size", %{conn: conn, user_id: user_id} do
      playlist_with(user_id, "Road Trip", ~w(One Two))

      {:ok, _view, html} = live(conn, ~p"/playlists")

      assert html =~ "Road Trip"
      assert html =~ "2 tracks"
    end

    test "one track is singular, because a list nobody proof-reads still says it", %{
      conn: conn,
      user_id: user_id
    } do
      playlist_with(user_id, "Just One", ~w(One))

      {:ok, _view, html} = live(conn, ~p"/playlists")

      assert html =~ "1 track"
      refute html =~ "1 tracks"
    end

    test "creating one goes straight to its editor", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/playlists")

      view |> element("button", "New playlist") |> render_click()

      assert {:error, {:live_redirect, %{to: path}}} =
               view
               |> form("form[phx-submit='create']", %{"name" => "Road Trip"})
               |> render_submit()

      assert path =~ ~r{^/playlists/[0-9a-f-]+$}
    end

    test "a service group fails on its own rather than taking the page", %{
      conn: conn,
      user_id: user_id
    } do
      # The reason each group is its own `assign_async`. One service being down
      # must not stop a user seeing the playlists they hold here.
      {:ok, _connection} =
        Providers.connect(user_id, :tidal, %{
          provider_user_id: "67373615",
          access_token: "at",
          refresh_token: "rt",
          access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
          scopes: ["playlists.read"],
          country: "US"
        })

      Req.Test.stub(OnePlaylist.Providers.Tidal, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"errors" => [%{"code" => "OOPS"}]})
      end)

      playlist_with(user_id, "Road Trip", ~w(One))

      {:ok, view, _html} = live(conn, ~p"/playlists")
      html = render_async(view)

      assert html =~ "Could not read your TIDAL playlists"
      assert html =~ "Road Trip", "the library half is unaffected"
    end
  end

  describe "editing a playlist" do
    setup %{user_id: user_id} do
      %{playlist: playlist_with(user_id, "Road Trip", ~w(One Two Three))}
    end

    test "lists the entries in order", %{conn: conn, playlist: playlist} do
      {:ok, _view, html} = live(conn, ~p"/playlists/#{playlist.id}")

      assert html =~ "Road Trip"
      assert html =~ "3 tracks"

      for title <- ~w(One Two Three), do: assert(html =~ title)
    end

    test "moving an entry down reorders it", %{conn: conn, user_id: user_id, playlist: playlist} do
      [first, _second, _third] = Library.entries(user_id, playlist.id)

      {:ok, view, _html} = live(conn, ~p"/playlists/#{playlist.id}")

      view
      |> element("button[phx-value-entry='#{first.id}'][phx-value-direction='down']")
      |> render_click()

      assert Library.entries(user_id, playlist.id) |> Enum.map(& &1.track.title) ==
               ~w(Two One Three)
    end

    test "the first entry cannot be moved up, and the last cannot be moved down", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      [first, _second, last] = Library.entries(user_id, playlist.id)

      {:ok, _view, html} = live(conn, ~p"/playlists/#{playlist.id}")

      assert html =~ ~r{phx-value-entry="#{first.id}" phx-value-direction="up" disabled}
      assert html =~ ~r{phx-value-entry="#{last.id}" phx-value-direction="down" disabled}
    end

    test "removing an entry takes only that one", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      [_first, second, _third] = Library.entries(user_id, playlist.id)

      {:ok, view, _html} = live(conn, ~p"/playlists/#{playlist.id}")

      view
      |> element("button[phx-click='remove'][phx-value-entry='#{second.id}']")
      |> render_click()

      assert Library.entries(user_id, playlist.id) |> Enum.map(& &1.track.title) == ~w(One Three)
    end

    test "renaming shows the new name", %{conn: conn, user_id: user_id, playlist: playlist} do
      {:ok, view, _html} = live(conn, ~p"/playlists/#{playlist.id}")

      view |> element("button[phx-click='rename']") |> render_click()

      html =
        view |> form("form[phx-submit='save_name']", %{"name" => "Long Drive"}) |> render_submit()

      assert html =~ "Long Drive"
      assert {:ok, %{name: "Long Drive"}} = Library.fetch_playlist(user_id, playlist.id)
    end

    test "deleting goes back to the list and keeps the recordings", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      held = OnePlaylist.Repo.aggregate(OnePlaylist.Library.Recording, :count)

      {:ok, view, _html} = live(conn, ~p"/playlists/#{playlist.id}")

      assert {:error, {:live_redirect, %{to: "/playlists"}}} =
               view |> element("button[phx-click='delete']") |> render_click()

      assert Library.fetch_playlist(user_id, playlist.id) == :error

      assert OnePlaylist.Repo.aggregate(OnePlaylist.Library.Recording, :count) == held,
             "deleting a playlist is not a licence to delete music"
    end

    test "an empty playlist points at the two ways to fill it", %{conn: conn, user_id: user_id} do
      {:ok, empty} = Library.create_playlist(user_id, "Empty")

      {:ok, _view, html} = live(conn, ~p"/playlists/#{empty.id}")

      assert html =~ "Nothing in here yet"
      assert html =~ "Transfer a playlist in"
      assert html =~ "import a file"
    end
  end

  describe "somebody else's playlist" do
    test "redirects rather than rendering it", %{conn: conn} do
      theirs = playlist_with(AuthFixtures.user_id_fixture(), "Not Yours", ~w(One))

      assert {:error, {:live_redirect, %{to: "/playlists"}}} =
               live(conn, ~p"/playlists/#{theirs.id}")
    end

    test "a playlist that does not exist is the same answer", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/playlists"}}} =
               live(conn, ~p"/playlists/#{Ecto.UUID.generate()}")
    end
  end

  describe "authentication" do
    test "signed-out visitors are sent to sign in" do
      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               live(Phoenix.ConnTest.build_conn(), ~p"/playlists")
    end
  end
end
