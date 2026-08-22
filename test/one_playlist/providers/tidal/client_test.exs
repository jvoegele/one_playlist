defmodule OnePlaylist.Providers.Tidal.ClientTest do
  use ExUnit.Case, async: true

  alias OnePlaylist.Providers.Tidal
  alias OnePlaylist.Providers.Tidal.APIError
  alias OnePlaylist.Providers.Tidal.Client

  use Errata

  # The JSON:API error body TIDAL actually returns, captured from the live
  # service rather than invented.
  @unauthorized %{
    "errors" => [
      %{
        "code" => "UNAUTHORIZED",
        "detail" => "Invalid or missing Authorization Header",
        "meta" => %{"category" => "AUTHENTICATION_ERROR"}
      }
    ]
  }

  describe "current_user/1" do
    test "unwraps the JSON:API data member" do
      Req.Test.stub(Tidal, fn conn ->
        assert conn.request_path == "/v2/users/me"
        assert ["Bearer at-1"] = Plug.Conn.get_req_header(conn, "authorization")
        assert ["application/vnd.api+json"] = Plug.Conn.get_req_header(conn, "accept")

        Req.Test.json(conn, %{
          "data" => %{
            "id" => "123456",
            "type" => "users",
            "attributes" => %{"username" => "jason", "country" => "US"}
          }
        })
      end)

      assert {:ok, user} = Client.current_user("at-1")
      assert user["id"] == "123456"
      assert user["attributes"]["username"] == "jason"
    end
  end

  describe "error classification" do
    test "401 is not retried" do
      counter = :counters.new(1, [])

      Req.Test.stub(Tidal, fn conn ->
        :counters.add(counter, 1, 1)
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(@unauthorized)
      end)

      assert {:error, %APIError{} = error} = Client.current_user("expired")

      assert :counters.get(counter, 1) == 1,
             "a token does not become valid by asking again, so 401 must not retry"

      assert Errata.reason(error) == :unauthorized
      refute Errata.retryable?(error)
      assert Errata.context(error).tidal_code == "UNAUTHORIZED"
      assert Errata.context(error).category == "AUTHENTICATION_ERROR"
      assert Errata.display_message(error) =~ "reconnect"
    end

    test "404 is not retried" do
      counter = :counters.new(1, [])

      Req.Test.stub(Tidal, fn conn ->
        :counters.add(counter, 1, 1)
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"errors" => [%{"code" => "GONE"}]})
      end)

      assert {:error, error} = Client.current_user("at")
      assert :counters.get(counter, 1) == 1
      assert Errata.reason(error) == :not_found
      assert Errata.http_status(error) == 404
    end

    test "429 is retried" do
      counter = :counters.new(1, [])

      Req.Test.stub(Tidal, fn conn ->
        :counters.add(counter, 1, 1)
        conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"errors" => [%{"code" => "BUSY"}]})
      end)

      assert {:error, %ExternalService.RetriesExhausted{} = exhausted} = Client.current_user("at")
      assert :counters.get(counter, 1) == 3

      assert %APIError{} = cause = Errata.cause(exhausted)
      assert Errata.reason(cause) == :rate_limited
      assert Errata.retryable?(cause)
    end

    test "5xx is retried, and a later success is returned" do
      counter = :counters.new(1, [])

      Req.Test.stub(Tidal, fn conn ->
        if :counters.get(counter, 1) < 2 do
          :counters.add(counter, 1, 1)
          Plug.Conn.send_resp(conn, 503, "")
        else
          Req.Test.json(conn, %{"data" => %{"id" => "ok"}})
        end
      end)

      assert {:ok, user} = Client.current_user("at")
      assert user["id"] == "ok"
      assert :counters.get(counter, 1) == 2, "it should have failed twice, then succeeded"
    end

    test "a transport failure is retried" do
      counter = :counters.new(1, [])

      Req.Test.stub(Tidal, fn conn ->
        :counters.add(counter, 1, 1)
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %ExternalService.RetriesExhausted{}} = Client.current_user("at")
      assert :counters.get(counter, 1) == 3
    end
  end

  describe "stream_playlists/3" do
    test "targets the numeric user id, since TIDAL rejects `me` on this path" do
      Req.Test.stub(Tidal, fn conn ->
        assert conn.request_path == "/v2/userCollections/67373615/relationships/playlists"
        Req.Test.json(conn, %{"data" => [], "links" => %{}})
      end)

      assert Client.stream_playlists("at", "67373615") |> Enum.to_list() == []
    end

    test "follows the cursor across pages and stops at the end" do
      pages = :counters.new(1, [])

      Req.Test.stub(Tidal, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        :counters.add(pages, 1, 1)

        # Plug parses `page[cursor]=abc` as nested params, so this is
        # `%{"page" => %{"cursor" => "abc"}}` rather than a flat key.
        case get_in(conn.query_params, ["page", "cursor"]) do
          nil ->
            Req.Test.json(conn, %{
              "data" => [%{"id" => "p1"}, %{"id" => "p2"}],
              "links" => %{
                "next" => "/userCollections/me/relationships/playlists?page%5Bcursor%5D=abc"
              }
            })

          "abc" ->
            Req.Test.json(conn, %{"data" => [%{"id" => "p3"}], "links" => %{}})
        end
      end)

      assert Client.stream_playlists("at", "67373615") |> Enum.to_list() |> Enum.map(& &1["id"]) ==
               ~w(p1 p2 p3)

      assert :counters.get(pages, 1) == 2
    end

    test "is lazy — an unconsumed stream makes no request" do
      Req.Test.stub(Tidal, fn _conn -> flunk("no request should have been made") end)

      _stream = Client.stream_playlists("at", "67373615")
      :ok
    end

    test "taking fewer items than a page still stops after one request" do
      requests = :counters.new(1, [])

      Req.Test.stub(Tidal, fn conn ->
        :counters.add(requests, 1, 1)

        Req.Test.json(conn, %{
          "data" => [%{"id" => "p1"}, %{"id" => "p2"}],
          "links" => %{"next" => "/x?page%5Bcursor%5D=abc"}
        })
      end)

      assert Client.stream_playlists("at", "67373615") |> Enum.take(1) |> Enum.map(& &1["id"]) ==
               ["p1"]

      assert :counters.get(requests, 1) == 1
    end

    test "a cursor that never advances terminates instead of looping forever" do
      requests = :counters.new(1, [])

      # A server that always hands back the same `next` link. Termination is the
      # remote service's decision, so the stream must not depend on it being
      # well behaved — without a guard this spins until the test times out.
      Req.Test.stub(Tidal, fn conn ->
        :counters.add(requests, 1, 1)

        Req.Test.json(conn, %{
          "data" => [%{"id" => "same"}],
          "links" => %{"next" => "/x?page%5Bcursor%5D=stuck"}
        })
      end)

      assert Client.stream_playlists("at", "67373615") |> Enum.to_list() |> length() == 2
      assert :counters.get(requests, 1) == 2
    end
  end
end
