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
  alias OnePlaylist.Library.Recording
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers
  alias OnePlaylist.Repo

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

    test "the arrow keys reorder from the drag handle", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      # Dragging alone is reordering nobody can do without a mouse, so the handle
      # is a real button and the arrow keys work on it.
      [first, _second, _third] = Library.entries(user_id, playlist.id)

      {:ok, view, _html} = live(conn, ~p"/playlists/#{playlist.id}")

      view |> element("#handle-#{first.id}") |> render_keydown(%{"key" => "ArrowDown"})

      assert Library.entries(user_id, playlist.id) |> Enum.map(& &1.track.title) ==
               ~w(Two One Three)
    end

    test "an arrow key at either end is not a failure", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      [first, _second, last] = Library.entries(user_id, playlist.id)

      {:ok, view, _html} = live(conn, ~p"/playlists/#{playlist.id}")

      view |> element("#handle-#{first.id}") |> render_keydown(%{"key" => "ArrowUp"})
      view |> element("#handle-#{last.id}") |> render_keydown(%{"key" => "ArrowDown"})

      assert Library.entries(user_id, playlist.id) |> Enum.map(& &1.track.title) ==
               ~w(One Two Three)
    end

    test "a key that is not an arrow does nothing", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      # No `phx-key`, so every keystroke on a focused handle reaches the server.
      {:ok, view, _html} = live(conn, ~p"/playlists/#{playlist.id}")

      [first, _second, _third] = Library.entries(user_id, playlist.id)

      view |> element("#handle-#{first.id}") |> render_keydown(%{"key" => "Tab"})

      assert Library.entries(user_id, playlist.id) |> Enum.map(& &1.track.title) ==
               ~w(One Two Three)
    end

    test "dropping an entry after another moves it there", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      [first, _second, last] = Library.entries(user_id, playlist.id)

      {:ok, view, _html} = live(conn, ~p"/playlists/#{playlist.id}")

      view
      |> element("#entries")
      |> render_hook("place", %{"entry" => first.id, "target" => last.id, "side" => "after"})

      assert Library.entries(user_id, playlist.id) |> Enum.map(& &1.track.title) ==
               ~w(Two Three One)
    end

    test "dropping an entry before another moves it there", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      [first, _second, last] = Library.entries(user_id, playlist.id)

      {:ok, view, _html} = live(conn, ~p"/playlists/#{playlist.id}")

      view
      |> element("#entries")
      |> render_hook("place", %{"entry" => last.id, "target" => first.id, "side" => "before"})

      assert Library.entries(user_id, playlist.id) |> Enum.map(& &1.track.title) ==
               ~w(Three One Two)
    end

    test "a drop naming an entry from another playlist changes nothing", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      # The client says what was dropped where, so what it says has to be
      # checked. An id from elsewhere is not among this playlist's entries and is
      # simply not found — no error, and nothing moves in either playlist.
      elsewhere = playlist_with(user_id, "Elsewhere", ~w(Alpha))
      [alpha] = Library.entries(user_id, elsewhere.id)
      [first, _second, _third] = Library.entries(user_id, playlist.id)

      {:ok, view, _html} = live(conn, ~p"/playlists/#{playlist.id}")

      view
      |> element("#entries")
      |> render_hook("place", %{"entry" => alpha.id, "target" => first.id, "side" => "before"})

      assert Library.entries(user_id, playlist.id) |> Enum.map(& &1.track.title) ==
               ~w(One Two Three)

      assert Library.entries(user_id, elsewhere.id) |> Enum.map(& &1.track.title) == ~w(Alpha)
    end

    test "dropping an entry onto itself changes nothing", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      [first, _second, _third] = Library.entries(user_id, playlist.id)

      {:ok, view, _html} = live(conn, ~p"/playlists/#{playlist.id}")

      view
      |> element("#entries")
      |> render_hook("place", %{"entry" => first.id, "target" => first.id, "side" => "after"})

      assert Library.entries(user_id, playlist.id) |> Enum.map(& &1.track.title) ==
               ~w(One Two Three)
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

  describe "how far enrichment has got" do
    setup %{user_id: user_id} do
      %{playlist: playlist_with(user_id, "Road Trip", ~w(One Two Three))}
    end

    defp set_outcome(user_id, playlist, index, attrs) do
      entry = user_id |> Library.entries(playlist.id) |> Enum.at(index)

      Recording
      |> Repo.get!(entry.track.provider_id)
      |> Ecto.Changeset.change(attrs)
      |> Repo.update!()
    end

    defp set_enrichment(user_id, playlist, states) do
      user_id
      |> Library.entries(playlist.id)
      |> Enum.zip(states)
      |> Enum.each(fn {entry, state} ->
        {isrc, enriched_at, mbid} =
          case state do
            {isrc, enriched_at} -> {isrc, enriched_at, nil}
            {_isrc, _enriched_at, _mbid} = full -> full
          end

        Recording
        |> Repo.get!(entry.track.provider_id)
        |> Ecto.Changeset.change(
          isrc: isrc,
          enriched_at: enriched_at,
          musicbrainz_recording_id: mbid
        )
        |> Repo.update!()
      end)
    end

    test "says how many are still waiting while any are", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      now = DateTime.utc_now()

      set_enrichment(user_id, playlist, [
        {"ZZZ9925000001", now},
        {nil, nil},
        {nil, nil}
      ])

      {:ok, _view, html} = live(conn, ~p"/playlists/#{playlist.id}")

      assert html =~ "1 of 3 identified by ISRC"
      assert html =~ "2 still being looked up"
    end

    test "a recording MusicBrainz has no ISRC for is not 'still being looked up'", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      # The bug this pins. Missing an ISRC and not having been asked are
      # different states, and inferring the second from the first told a user
      # whose playlist was fully resolved that it was still working — for ever.
      now = DateTime.utc_now()

      set_enrichment(user_id, playlist, [
        {"ZZZ9925000002", now},
        {nil, now},
        {nil, now}
      ])

      {:ok, _view, html} = live(conn, ~p"/playlists/#{playlist.id}")

      assert html =~ "1 of 3 identified by ISRC"
      refute html =~ "still being looked up"
      assert html =~ "MusicBrainz has no ISRC for the other 2"
    end

    test "says nothing extra once every entry carries an ISRC", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      now = DateTime.utc_now()

      set_enrichment(user_id, playlist, [
        {"ZZZ9925000003", now},
        {"ZZZ9925000004", now},
        {"ZZZ9925000005", now}
      ])

      {:ok, _view, html} = live(conn, ~p"/playlists/#{playlist.id}")

      assert html =~ "3 of 3 identified by ISRC"
      refute html =~ "still being looked up"
      refute html =~ "MusicBrainz has no ISRC"
    end
  end

  describe "what a row says about one recording" do
    setup %{user_id: user_id} do
      %{playlist: playlist_with(user_id, "Road Trip", ~w(One Two Three))}
    end

    defp entry_ids(user_id, playlist),
      do: Library.entries(user_id, playlist.id) |> Enum.map(& &1.id)

    test "distinguishes waiting, not found, and identified", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      now = DateTime.utc_now()

      set_enrichment(user_id, playlist, [
        # asked, identified, carries an ISRC — the ordinary case, says nothing
        {"ZZZ9925000010", now, "aaaaaaaa-1111-2222-3333-444444444444"},
        # asked, MusicBrainz has no such recording
        {nil, now, nil},
        # never asked
        {nil, nil, nil}
      ])

      {:ok, _view, html} = live(conn, ~p"/playlists/#{playlist.id}")

      assert html =~ "no confident match at MusicBrainz"
      assert html =~ "waiting to be looked up"
      assert html =~ "Identified at MusicBrainz"
    end

    test "shows how many are still being looked up, and hides it when none are", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      now = DateTime.utc_now()

      set_enrichment(user_id, playlist, [{nil, now, nil}, {nil, nil, nil}, {nil, nil, nil}])

      {:ok, _view, html} = live(conn, ~p"/playlists/#{playlist.id}")

      assert html =~ "looking up 2 of 3 at MusicBrainz"

      set_enrichment(user_id, playlist, [{nil, now, nil}, {nil, now, nil}, {nil, now, nil}])

      {:ok, _view, done} = live(conn, ~p"/playlists/#{playlist.id}")

      refute done =~ "looking up", "the indicator removes itself rather than reading 0 of 3"
    end

    test "a row redraws itself when its recording is enriched", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      # The whole point of the broadcast: a background job finishing changes the
      # screen without a reload and without a query per track.
      set_enrichment(user_id, playlist, [{nil, nil, nil}, {nil, nil, nil}, {nil, nil, nil}])

      {:ok, view, html} = live(conn, ~p"/playlists/#{playlist.id}")

      assert html =~ "looking up 3 of 3 at MusicBrainz"

      [first | _rest] = Library.entries(user_id, playlist.id)

      enriched =
        Recording
        |> Repo.get!(first.track.provider_id)
        |> Ecto.Changeset.change(
          enriched_at: DateTime.utc_now(),
          musicbrainz_recording_id: "aaaaaaaa-1111-2222-3333-444444444444",
          enrichment_outcome: :identified
        )
        |> Repo.update!()

      send(view.pid, {:recording_enriched, enriched})

      assert render(view) =~ "looking up 2 of 3 at MusicBrainz"
    end

    test "says which kind of not-found it was", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      # The distinction a user asked for after reading "not found at
      # MusicBrainz" for a recording MusicBrainz plainly holds. One is a gap in
      # the catalogue; the other is a decision this application made.
      now = DateTime.utc_now()

      set_enrichment(user_id, playlist, [{nil, now, nil}, {nil, now, nil}, {nil, now, nil}])

      set_outcome(user_id, playlist, 0, %{enrichment_outcome: :no_candidates})

      set_outcome(user_id, playlist, 1, %{
        enrichment_outcome: :declined,
        enrichment_candidates: 12
      })

      set_outcome(user_id, playlist, 2, %{enrichment_outcome: :unnameable})

      {:ok, _view, html} = live(conn, ~p"/playlists/#{playlist.id}")

      assert html =~ "MusicBrainz has no such recording"
      assert html =~ "12 found at MusicBrainz, none certain enough"
      assert html =~ "too little to search MusicBrainz with"
    end

    test "a recording enriched before the reason was recorded says only what is known", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      now = DateTime.utc_now()

      set_enrichment(user_id, playlist, [{nil, now, nil}, {nil, now, nil}, {nil, now, nil}])

      {:ok, _view, html} = live(conn, ~p"/playlists/#{playlist.id}")

      assert html =~ "no confident match at MusicBrainz"
      refute html =~ "none certain enough", "no number is better than an invented one"
    end

    test "an identified recording MusicBrainz has no ISRC for says so", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      # Identified but without an ISRC is its own state, and the one most likely
      # to be misread as a failure. It is not: the recording is resolved.
      now = DateTime.utc_now()

      set_enrichment(user_id, playlist, [
        {nil, now, "bbbbbbbb-1111-2222-3333-444444444444"},
        {nil, now, "bbbbbbbb-1111-2222-3333-444444444444"},
        {nil, now, "bbbbbbbb-1111-2222-3333-444444444444"}
      ])

      {:ok, _view, html} = live(conn, ~p"/playlists/#{playlist.id}")

      assert html =~ "MusicBrainz has no ISRC for this recording"
      refute html =~ "no confident match at MusicBrainz"
      refute html =~ "waiting to be looked up"
    end

    test "expanding a row shows what enrichment found, and collapsing hides it", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      now = DateTime.utc_now()
      mbid = "cccccccc-1111-2222-3333-444444444444"

      set_enrichment(user_id, playlist, [
        {"ZZZ9925000011", now, mbid},
        {nil, nil, nil},
        {nil, nil, nil}
      ])

      [first | _rest] = entry_ids(user_id, playlist)

      {:ok, view, html} = live(conn, ~p"/playlists/#{playlist.id}")

      refute html =~ mbid, "detail is hidden until asked for"

      expanded =
        view
        |> element(~s{button[phx-value-entry="#{first}"][phx-click="toggle_detail"]})
        |> render_click()

      assert expanded =~ mbid
      assert expanded =~ "ZZZ9925000011"
      assert expanded =~ "Looked up"

      collapsed =
        view
        |> element(~s{button[phx-value-entry="#{first}"][phx-click="toggle_detail"]})
        |> render_click()

      refute collapsed =~ mbid
    end

    test "an unenriched row's detail says it is queued rather than showing blanks", %{
      conn: conn,
      user_id: user_id,
      playlist: playlist
    } do
      set_enrichment(user_id, playlist, [{nil, nil, nil}, {nil, nil, nil}, {nil, nil, nil}])

      [first | _rest] = entry_ids(user_id, playlist)

      {:ok, view, _html} = live(conn, ~p"/playlists/#{playlist.id}")

      expanded =
        view
        |> element(~s{button[phx-value-entry="#{first}"][phx-click="toggle_detail"]})
        |> render_click()

      assert expanded =~ "not looked up yet"
      assert expanded =~ "enrichment runs one recording a second"
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
