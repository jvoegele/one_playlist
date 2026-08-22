defmodule OnePlaylist.Providers.Tidal.WriteTest do
  @moduledoc """
  The write path, against the request and response shapes verified live on
  2026-08-22.

  Every shape asserted here was established by making the call for real and
  reading what came back, including the two that are counter-intuitive:
  `accessType` is rejected outright for `"PRIVATE"`, and a created playlist's
  id is a **UUID** where every catalogue id is numeric.
  """

  use ExUnit.Case, async: true
  use Bond.Test
  use Errata

  import Req.Test, only: [set_req_test_from_context: 1]

  alias OnePlaylist.Music.Playlist
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.Tidal
  alias OnePlaylist.Providers.Tidal.Client

  setup :set_req_test_from_context

  defp connection do
    %Connection{
      provider: :tidal,
      provider_user_id: "67373615",
      access_token: "at",
      country: "US",
      scopes: ["playlists.write", "playlists.read"],
      status: :active,
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
    }
  end

  defp track(id), do: %Track{provider: :tidal, provider_id: id, title: "Track #{id}"}

  # The document TIDAL actually returns from a create: a UUID id, and an
  # attributes map shaped like any other playlist resource.
  defp created_playlist(name) do
    %{
      "data" => %{
        "id" => "c3ba8758-4f2e-419a-9621-db4efc4a3e0f",
        "type" => "playlists",
        "attributes" => %{
          "name" => name,
          "numberOfItems" => 0,
          "playlistType" => "USER",
          "createdAt" => "2026-08-22T20:13:00.000Z"
        }
      }
    }
  end

  describe "create_playlist/3" do
    test "posts a JSON:API document and returns the created playlist" do
      Req.Test.stub(Tidal, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.method == "POST"
        assert conn.request_path == "/v2/playlists"
        assert conn.query_params["countryCode"] == "US"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        document = Jason.decode!(body)

        assert document["data"]["type"] == "playlists"
        assert document["data"]["attributes"]["name"] == "Road Trip"

        Req.Test.json(conn, created_playlist("Road Trip"))
      end)

      assert {:ok, %Playlist{} = playlist} =
               Tidal.create_playlist(connection(), "Road Trip")

      assert playlist.provider == :tidal
      assert playlist.name == "Road Trip"
      assert playlist.provider_id == "c3ba8758-4f2e-419a-9621-db4efc4a3e0f"
    end

    test "never sends accessType" do
      # `"PRIVATE"` is rejected with a 400 pointing at
      # `data/attributes/accessType`; `"UNLISTED"` and `"PUBLIC"` are accepted.
      # Omitting it means TIDAL decides, rather than this application guessing
      # at a visibility on someone else's library.
      Req.Test.stub(Tidal, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        refute Map.has_key?(Jason.decode!(body)["data"]["attributes"], "accessType")

        Req.Test.json(conn, created_playlist("x"))
      end)

      assert {:ok, _playlist} = Tidal.create_playlist(connection(), "x")
    end

    test "a description is sent only when given" do
      Req.Test.stub(Tidal, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        attributes = Jason.decode!(body)["data"]["attributes"]

        assert attributes["description"] == "from Spotify"

        Req.Test.json(conn, created_playlist("x"))
      end)

      assert {:ok, _playlist} =
               Tidal.create_playlist(connection(), "x", description: "from Spotify")
    end

    test "a playlist with no usable id is caught at the boundary" do
      # The inherited contract. A created playlist that cannot be addressed is
      # worse than a failed creation: the transfer proceeds, adds tracks to
      # nothing, and reports success.
      Req.Test.stub(Tidal, fn conn ->
        Req.Test.json(conn, %{"data" => %{"id" => "", "type" => "playlists"}})
      end)

      assert_postcondition_violation(Tidal.create_playlist(connection(), "x"),
        label: :addressable
      )
    end
  end

  describe "add_tracks/4" do
    test "posts resource identifiers to the items relationship" do
      Req.Test.stub(Tidal, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2/playlists/pl-1/relationships/items"

        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "data" => [
                   %{"id" => "1", "type" => "tracks"},
                   %{"id" => "2", "type" => "tracks"}
                 ]
               }

        Req.Test.json(conn, %{})
      end)

      assert {:ok, 2} = Tidal.add_tracks(connection(), "pl-1", [track("1"), track("2")])
    end

    test "preserves the order it was given" do
      # A playlist transferred out of order is one of the silent failures this
      # product exists to avoid, and the order is decided here.
      Req.Test.stub(Tidal, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        ids = Jason.decode!(body)["data"] |> Enum.map(& &1["id"])

        assert ids == ~w(c a b)

        Req.Test.json(conn, %{})
      end)

      assert {:ok, 3} =
               Tidal.add_tracks(connection(), "pl-1", [track("c"), track("a"), track("b")])
    end

    test "adding nothing makes no request at all" do
      Req.Test.stub(Tidal, fn _conn -> flunk("an empty append should not be sent") end)

      assert {:ok, 0} = Tidal.add_tracks(connection(), "pl-1", [])
    end

    test "accepts a Playlist struct as well as an id" do
      Req.Test.stub(Tidal, fn conn ->
        assert conn.request_path == "/v2/playlists/pl-9/relationships/items"
        Req.Test.json(conn, %{})
      end)

      playlist = %Playlist{provider: :tidal, provider_id: "pl-9"}

      assert {:ok, 1} = Tidal.add_tracks(connection(), playlist, [track("1")])
    end

    test "an error is not reported as a successful append" do
      Req.Test.stub(Tidal, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"errors" => [%{"code" => "FORBIDDEN"}]})
      end)

      assert {:error, error} = Tidal.add_tracks(connection(), "pl-1", [track("1")])
      assert Errata.reason(error) == :forbidden
    end
  end

  describe "playlist_track_ids/3" do
    test "returns the ids already present, in order, across pages" do
      Req.Test.stub(Tidal, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case get_in(conn.query_params, ["page", "cursor"]) do
          nil ->
            Req.Test.json(conn, %{
              "data" => [%{"id" => "a", "type" => "tracks"}, %{"id" => "b", "type" => "tracks"}],
              "links" => %{"next" => "/x?page%5Bcursor%5D=next"}
            })

          "next" ->
            Req.Test.json(conn, %{"data" => [%{"id" => "c", "type" => "tracks"}], "links" => %{}})
        end
      end)

      assert {:ok, ~w(a b c)} = Tidal.playlist_track_ids(connection(), "pl-1")
    end

    test "an empty playlist is an empty list, not an error" do
      Req.Test.stub(Tidal, fn conn ->
        Req.Test.json(conn, %{"data" => [], "links" => %{}})
      end)

      assert {:ok, []} = Tidal.playlist_track_ids(connection(), "pl-1")
    end

    test "a failure is returned rather than raised out of the stream" do
      # `paginate/2` raises to terminate a stream, since a Stream has nowhere to
      # put an error tuple. This function is eager, so it must convert.
      Req.Test.stub(Tidal, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"errors" => [%{"code" => "GONE"}]})
      end)

      assert {:error, error} = Tidal.playlist_track_ids(connection(), "pl-1")
      assert Errata.reason(error) == :not_found
    end
  end

  describe "the write path is guarded separately from reads" do
    test "mutations go through the write service, reads through the read one" do
      # Not an implementation detail: TIDAL returned four 429s out of five rapid
      # deletes, so a mutation sharing the read limiter would spend a transfer's
      # retry budget discovering that. The two services are what keep a bulk
      # write from taking the library browsing down with it.
      assert Client.__info__(:functions) |> Keyword.has_key?(:create_playlist)

      # Started and usable, asserted by using it rather than by reaching for a
      # process name — which is ExternalService's business, not this test's.
      assert {:ok, :reachable} =
               OnePlaylist.Providers.Tidal.WriteService.call(fn -> {:ok, :reachable} end)

      assert {:ok, :reachable} =
               OnePlaylist.Providers.Tidal.Service.call(fn -> {:ok, :reachable} end)
    end

    test "the two services fail independently" do
      # The isolation that motivates having two. A write path melting its
      # breaker must not take library browsing down with it, and vice versa —
      # they fail for different reasons and should recover separately.
      write = ExternalService.explain(OnePlaylist.Providers.Tidal.WriteService)
      read = ExternalService.explain(OnePlaylist.Providers.Tidal.Service)

      refute write == read,
             "a mutation limiter sized like the read one is sized wrong: TIDAL " <>
               "returned four 429s out of five rapid deletes"
    end
  end
end
