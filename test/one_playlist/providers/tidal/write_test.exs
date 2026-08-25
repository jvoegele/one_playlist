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

  describe "remove_tracks/4" do
    # The page a removal has to read first. `meta.itemId` is a per-item UUID,
    # distinct from the track id, and `a` appears twice with two different ones.
    defp items_page do
      %{
        "data" => [
          %{"id" => "a", "type" => "tracks", "meta" => %{"itemId" => "item-1"}},
          %{"id" => "b", "type" => "tracks", "meta" => %{"itemId" => "item-2"}},
          %{"id" => "a", "type" => "tracks", "meta" => %{"itemId" => "item-3"}}
        ],
        "links" => %{}
      }
    end

    test "sends the track id and the item id, because either alone is a 400" do
      # Verified live on 2026-08-24. `{id: <track id>, type: "tracks"}` and
      # `{id: <item id>, type: "tracks"}` both answer 400 "Must not be null";
      # only the pair works, and the error names neither field.
      Req.Test.stub(Tidal, fn conn ->
        case conn.method do
          "GET" ->
            Req.Test.json(conn, items_page())

          "DELETE" ->
            assert conn.request_path == "/v2/playlists/pl-1/relationships/items"

            {:ok, body, conn} = Plug.Conn.read_body(conn)

            assert Jason.decode!(body) == %{
                     "data" => [
                       %{
                         "id" => "b",
                         "type" => "tracks",
                         "meta" => %{"itemId" => "item-2"}
                       }
                     ]
                   }

            Req.Test.json(conn, %{})
        end
      end)

      assert {:ok, 1} = Tidal.remove_tracks(connection(), "pl-1", [track("b")])
    end

    test "removes every occurrence of a track the playlist holds twice" do
      # The caller's question is "this should not be here", not "one of these
      # should not be here" — which is what makes calling this twice harmless.
      Req.Test.stub(Tidal, fn conn ->
        case conn.method do
          "GET" ->
            Req.Test.json(conn, items_page())

          "DELETE" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)

            item_ids = Jason.decode!(body)["data"] |> Enum.map(&get_in(&1, ["meta", "itemId"]))

            assert item_ids == ["item-1", "item-3"],
                   "both occurrences of `a` must go, and by their own item ids"

            Req.Test.json(conn, %{})
        end
      end)

      assert {:ok, 2} = Tidal.remove_tracks(connection(), "pl-1", [track("a")])
    end

    test "a track that is not in the playlist sends no delete" do
      Req.Test.stub(Tidal, fn conn ->
        case conn.method do
          "GET" -> Req.Test.json(conn, items_page())
          "DELETE" -> flunk("nothing matched, so nothing should be deleted")
        end
      end)

      assert {:ok, 0} = Tidal.remove_tracks(connection(), "pl-1", [track("absent")])
    end

    test "an entry missing its item id is dropped rather than sent blank" do
      # `to_string(nil)` is `""`, and TIDAL answers a blank item id with the
      # same unhelpful 400 as an absent one — so the failure would read as "the
      # provider refused" rather than "we sent nonsense".
      Req.Test.stub(Tidal, fn conn ->
        case conn.method do
          "GET" ->
            Req.Test.json(conn, %{
              "data" => [%{"id" => "a", "type" => "tracks", "meta" => %{}}],
              "links" => %{}
            })

          "DELETE" ->
            flunk("an entry with no item id cannot be removed and must not be sent")
        end
      end)

      assert {:ok, 0} = Tidal.remove_tracks(connection(), "pl-1", [track("a")])
    end

    test "an empty list reads nothing and sends nothing" do
      Req.Test.stub(Tidal, fn conn ->
        case conn.method do
          "GET" -> Req.Test.json(conn, items_page())
          "DELETE" -> flunk("removing nothing must not delete anything")
        end
      end)

      assert {:ok, 0} = Tidal.remove_tracks(connection(), "pl-1", [])
    end

    test "a failed read is returned rather than counted as nothing removed" do
      Req.Test.stub(Tidal, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"errors" => [%{"code" => "GONE"}]})
      end)

      assert {:error, error} = Tidal.remove_tracks(connection(), "pl-1", [track("a")])
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

    test "a background write is never shed for want of patience" do
      # Both shedding paths, pinned. `external_service` draws the line at the
      # *call site*: background work sleeps because sleeping is the
      # back-pressure, a request path takes a finite budget because a client that
      # has given up is being served for nothing. Every caller of this service is
      # an Oban job.
      #
      # The default budget was actively harmful at this shape. A limiter check
      # never quotes more than one emission interval — per/limit, so 2000ms here
      # — and the default budget is one window, also 2000ms. One re-check
      # exhausted it, and a real transfer failed with "the call was throttled
      # beyond the configured rate limit wait time".
      explained = ExternalService.explain(OnePlaylist.Providers.Tidal.WriteService)

      assert explained =~ ~r/rate limit.*waits up to\s+as long as it takes/s,
             "a queued transfer should sleep for its quota, not be shed"

      refute explained =~ ~r/concurrency.*waits up to\s+nothing/s,
             "fixing the limiter and leaving the bulkhead moves the shedding " <>
               "rather than removing it"
    end

    test "the read path keeps a finite budget, because someone is waiting" do
      # The other half of the same rule. These calls serve a page load, and a
      # visitor who has navigated away is being served for nothing.
      explained = ExternalService.explain(OnePlaylist.Providers.Tidal.Service)

      refute explained =~ ~r/rate limit.*waits up to\s+as long as it takes/s
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

  describe "the write path's resilience, not just its happy path" do
    # `ExternalService.Test.Coverage` reported `Tidal.WriteService` called 66
    # times and never once retried, failed or rejected — every one of those
    # calls on the happy path. Writes are the half of TIDAL that matters most
    # here: a transfer that cannot read is a transfer that does nothing, and a
    # transfer that cannot write is a half-written playlist.
    #
    # These two tests are what turns that row from a warning into a number.

    test "a 5xx on a write is retried, and succeeds when the server recovers" do
      # `classify/1` calls a 5xx `{:retry, ...}`, which is what puts the attempt
      # under `WriteService`'s budget rather than failing the transfer outright.
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Tidal, fn conn ->
        case Agent.get_and_update(attempts, &{&1 + 1, &1 + 1}) do
          1 -> Plug.Conn.send_resp(conn, 503, ~s({"errors":[{"detail":"upstream"}]}))
          _recovered -> Req.Test.json(conn, created_playlist("Road Trip"))
        end
      end)

      assert {:ok, %Playlist{}} = Tidal.create_playlist(connection(), "Road Trip")
      assert Agent.get(attempts, & &1) == 2, "the first attempt was retried, not surfaced"
    end

    test "a write that keeps failing exhausts the budget and says so" do
      # The other end of the same path. `RetriesExhausted` is what a caller sees,
      # and `Providers.root_error/1` is what unwraps it to the API error that
      # names the actual problem — see its own tests.
      Req.Test.stub(Tidal, fn conn ->
        Plug.Conn.send_resp(conn, 503, ~s({"errors":[{"detail":"still down"}]}))
      end)

      assert {:error, error} = Tidal.create_playlist(connection(), "Road Trip")
      assert Errata.is_error(error)

      underlying = OnePlaylist.Providers.root_error(error)
      assert Errata.reason(underlying) == :server_error
    end
  end
end
