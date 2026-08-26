defmodule OnePlaylist.Providers.SpotifyTest do
  @moduledoc """
  The Spotify adapter against a stubbed Web API.

  Three things here are genuinely new to this application rather than a second
  copy of what TIDAL already proved:

    * **Offset pagination driven by a `next` URL**, where TIDAL uses an opaque
      cursor. Including the case where `next` points back at the page just
      fetched, which would spin a background job forever.
    * **Removal by URI**, the third removal model this codebase speaks and the
      first that needs no per-entry identifier at all.
    * **Development Mode's 403**, which is indistinguishable from a scope
      refusal except by reading the message — and the two have opposite fixes.
  """

  use OnePlaylist.DataCase, async: false

  import OnePlaylist.AuthFixtures
  import Req.Test, only: [set_req_test_from_context: 1]

  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Spotify

  setup :set_req_test_from_context

  setup do
    user_id = user_id_fixture()

    {:ok, connection} =
      Providers.connect(user_id, :spotify, %{
        provider_user_id: "jason",
        display_name: "Jason",
        country: "US",
        access_token: "at",
        refresh_token: "rt",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
        scopes: ~w(playlist-read-private playlist-modify-private user-read-private)
      })

    %{user: user_id, connection: connection}
  end

  defp track_object(id) do
    %{
      "id" => id,
      "type" => "track",
      "name" => "Song #{id}",
      "duration_ms" => 200_000,
      "track_number" => 1,
      "disc_number" => 1,
      "external_ids" => %{"isrc" => "GBAYE060149#{String.last(id)}"},
      "artists" => [%{"name" => "Somebody"}],
      "album" => %{"id" => "alb", "name" => "An Album", "images" => []}
    }
  end

  defp item(track), do: %{"track" => track}

  describe "stream_playlists/2" do
    test "follows the next link across pages", %{connection: connection} do
      Req.Test.stub(Spotify, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.query_params["page"] == "2" do
          Req.Test.json(conn, %{
            "items" => [%{"id" => "p2", "name" => "Second", "owner" => %{"id" => "jason"}}],
            "next" => nil
          })
        else
          Req.Test.json(conn, %{
            "items" => [%{"id" => "p1", "name" => "First", "owner" => %{"id" => "jason"}}],
            "next" => "https://api.spotify.com/v1/me/playlists?page=2"
          })
        end
      end)

      assert {:ok, stream} = Spotify.stream_playlists(connection, [])
      assert Enum.map(stream, & &1.provider_id) == ~w(p1 p2)
    end

    # Termination is decided by the remote service, which is a poor place to
    # leave it. A `next` pointing at the page just fetched would spin forever,
    # and a background job would spin with it.
    test "stops when next points back at the same page", %{connection: connection} do
      Req.Test.stub(Spotify, fn conn ->
        Req.Test.json(conn, %{
          "items" => [%{"id" => "p1", "name" => "Loop", "owner" => %{"id" => "jason"}}],
          "next" => "https://api.spotify.com/v1/me/playlists?page=same"
        })
      end)

      assert {:ok, stream} = Spotify.stream_playlists(connection, [])
      assert length(Enum.to_list(stream)) == 2
    end

    # `/me/playlists` returns followed playlists alongside owned ones, and only
    # the owned ones can be written to.
    test "says which playlists the user owns", %{connection: connection} do
      Req.Test.stub(Spotify, fn conn ->
        Req.Test.json(conn, %{
          "items" => [
            %{"id" => "mine", "name" => "Mine", "owner" => %{"id" => "jason"}},
            %{"id" => "theirs", "name" => "Theirs", "owner" => %{"id" => "stranger"}}
          ],
          "next" => nil
        })
      end)

      assert {:ok, stream} = Spotify.stream_playlists(connection, [])
      assert [mine, theirs] = Enum.to_list(stream)
      assert mine.owned
      refute theirs.owned
    end
  end

  describe "playlist_track_ids/3" do
    test "keeps order and duplicates, and drops what has no id", %{connection: connection} do
      Req.Test.stub(Spotify, fn conn ->
        Req.Test.json(conn, %{
          "items" => [
            item(track_object("t1")),
            item(%{"id" => nil, "type" => "track", "is_local" => true}),
            item(track_object("t1")),
            item(nil)
          ],
          "next" => nil
        })
      end)

      assert {:ok, ids} = Spotify.playlist_track_ids(connection, "p1", [])
      assert ids == ~w(t1 t1)
    end

    test "sends the account's market", %{connection: connection} do
      Req.Test.stub(Spotify, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["market"] == "US"

        Req.Test.json(conn, %{"items" => [], "next" => nil})
      end)

      assert {:ok, []} = Spotify.playlist_track_ids(connection, "p1", [])
    end
  end

  describe "remove_tracks/4" do
    # The third removal model. TIDAL needs a track id *and* an item id; Subsonic
    # needs a zero-based index and no id at all; Spotify takes a URI. That the
    # adapter boundary absorbs all three without the caller knowing is the point
    # of having one.
    test "removes by uri and counts occurrences", %{connection: connection} do
      test_pid = self()

      Req.Test.stub(Spotify, fn conn ->
        cond do
          conn.method == "DELETE" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:removed, Jason.decode!(body)})
            Req.Test.json(conn, %{"snapshot_id" => "snap-2"})

          String.ends_with?(conn.request_path, "/tracks") ->
            Req.Test.json(conn, %{
              "items" => [
                item(track_object("t1")),
                item(track_object("t2")),
                item(track_object("t1"))
              ],
              "next" => nil
            })

          true ->
            Req.Test.json(conn, %{"snapshot_id" => "snap-1"})
        end
      end)

      # Counted from what the playlist holds, not from what was asked for: one
      # id accounts for two entries here, because Spotify removes every
      # occurrence of a uri.
      assert {:ok, 2} =
               Spotify.remove_tracks(
                 connection,
                 "p1",
                 [%Track{provider: :spotify, provider_id: "t1"}],
                 []
               )

      assert_received {:removed, body}
      assert body["tracks"] == [%{"uri" => "spotify:track:t1"}]
      assert body["snapshot_id"] == "snap-1"
    end

    test "a track the playlist does not hold removes nothing", %{connection: connection} do
      Req.Test.stub(Spotify, fn conn ->
        if conn.method == "DELETE" do
          flunk("nothing should have been removed")
        else
          Req.Test.json(conn, %{"items" => [item(track_object("t1"))], "next" => nil})
        end
      end)

      assert {:ok, 0} =
               Spotify.remove_tracks(
                 connection,
                 "p1",
                 [%Track{provider: :spotify, provider_id: "gone"}],
                 []
               )
    end

    # The behaviour's `nothing_asked_removes_nothing`, which exists because an
    # implementation computing positions by *difference* answers "remove
    # everything" when asked to remove nothing.
    test "removing nothing removes nothing", %{connection: connection} do
      Req.Test.stub(Spotify, fn conn ->
        if conn.method == "DELETE", do: flunk("asked for a removal")
        Req.Test.json(conn, %{"items" => [item(track_object("t1"))], "next" => nil})
      end)

      assert {:ok, 0} = Spotify.remove_tracks(connection, "p1", [], [])
    end
  end

  describe "add_tracks/4" do
    test "sends uris rather than bare ids", %{connection: connection} do
      test_pid = self()

      Req.Test.stub(Spotify, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:added, Jason.decode!(body)})
        Req.Test.json(conn, %{"snapshot_id" => "snap"})
      end)

      tracks = for id <- ~w(t1 t2), do: %Track{provider: :spotify, provider_id: id}

      assert {:ok, 2} = Spotify.add_tracks(connection, "p1", tracks, [])
      assert_received {:added, %{"uris" => ~w(spotify:track:t1 spotify:track:t2)}}
    end
  end

  describe "create_playlist/3" do
    # Spotify has no "current user" form of this endpoint, and its own default
    # for a new playlist is public. A transfer tool that published somebody's
    # playlists to their followers by omission would be a bad surprise.
    test "creates a private playlist under the connected account", %{connection: connection} do
      test_pid = self()

      Req.Test.stub(Spotify, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:created, conn.request_path, Jason.decode!(body)})

        Req.Test.json(conn, %{"id" => "new", "name" => "Copied", "owner" => %{"id" => "jason"}})
      end)

      assert {:ok, playlist} = Spotify.create_playlist(connection, "Copied", [])
      assert playlist.provider_id == "new"

      assert_received {:created, path, body}
      assert path =~ "/users/jason/playlists"
      assert body["public"] == false
    end
  end

  describe "development mode" do
    # The distinction exists because the fixes are opposite: a scope refusal is
    # "reconnect and grant more", and this one is "you cannot use this at all
    # until the app's owner adds you". Telling a user to reconnect for a problem
    # no reconnection can fix is the outcome it prevents.
    test "an allowlist refusal is not a scope problem", %{connection: connection} do
      Req.Test.stub(Spotify, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{
          "error" => %{
            "status" => 403,
            "message" => "User not registered in the Developer Dashboard"
          }
        })
      end)

      assert {:error, error} = Spotify.playlist_track_ids(connection, "p1", [])
      assert Errata.reason(error) == :not_allowlisted
      assert Errata.display_message(error) =~ "allowlist"
    end

    test "an ordinary 403 stays a plain refusal", %{connection: connection} do
      Req.Test.stub(Spotify, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{
          "error" => %{"status" => 403, "message" => "Insufficient client scope"}
        })
      end)

      assert {:error, error} = Spotify.playlist_track_ids(connection, "p1", [])
      assert Errata.reason(error) == :forbidden
    end
  end

  describe "capabilities" do
    test "declares what varies between services" do
      assert Providers.supports?(:spotify, :remove_tracks)
      assert Providers.supports?(:spotify, :artwork)
      # Two Spotify accounts see the same catalogue under the same ids, so a
      # Spotify → Spotify transfer copies them across without searching.
      assert Providers.supports?(:spotify, :global_ids)
      # A fixed catalogue: a recording Spotify does not have cannot be added to
      # it, only found or not found.
      refute Providers.supports?(:spotify, :accepts_any_track)
    end
  end
end
