defmodule OnePlaylist.Providers.NavidromeTest do
  @moduledoc """
  The Subsonic adapter, tested for the ways it can be wrong *quietly*.

  Every case here was chosen because it fails without failing: a wrong answer,
  an empty result or a silently dropped track, rather than an exception. Two of
  them were real bugs found by running against a live Navidrome, and both had
  already passed a live smoke test before anyone noticed.
  """

  use ExUnit.Case, async: true
  use Bond.Test
  use Errata

  import Req.Test, only: [set_req_test_from_context: 1]

  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.Navidrome
  alias OnePlaylist.Providers.Subsonic.Client
  alias OnePlaylist.Providers.Subsonic.Mapper

  setup :set_req_test_from_context

  defp connection do
    %Connection{
      provider: :navidrome,
      provider_user_id: "admin",
      server_url: "http://music.local:4533",
      access_token: "hunter2",
      # The two nils that make this connection never need refreshing.
      refresh_token: nil,
      access_token_expires_at: nil,
      status: :active
    }
  end

  defp song(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "s1",
        "title" => "Hey Grandma",
        "album" => "Moby Grape",
        "artist" => "Moby Grape",
        "duration" => 165,
        "track" => 1,
        "isrc" => ["DESK90390301"]
      },
      overrides
    )
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

  describe "authentication" do
    test "sends a salted token and never the password" do
      # `p=` is accepted by Subsonic and is the password in the clear. Sending it
      # would leak into proxy logs and bug reports for no benefit.
      params = Client.auth_params(connection())

      assert params[:u] == "admin"

      assert params[:t] ==
               :crypto.hash(:md5, "hunter2#{params[:s]}") |> Base.encode16(case: :lower)

      refute Keyword.has_key?(params, :p),
             "the password must never be sent, even hex-encoded"
    end

    test "the salt changes every request" do
      assert Client.auth_params(connection())[:s] != Client.auth_params(connection())[:s]
    end

    test "there is nothing to refresh, and it says so" do
      assert {:error, error} = Navidrome.refresh_tokens("anything")
      assert Errata.reason(error) == :reauth_required
    end
  end

  describe "failures arrive as HTTP 200" do
    test "a wrong password is an error, not an empty result" do
      # The single largest shape difference from every other provider here. A
      # client written for TIDAL would see 200 and report success with no
      # tracks — a transfer that quietly matched nothing.
      Req.Test.stub(Navidrome, fn conn ->
        Req.Test.json(conn, failed(40, "Wrong username or password"))
      end)

      assert {:error, error} = Navidrome.whoami(connection())
      assert Errata.reason(error) == :unauthorized

      refute Errata.retryable?(error),
             "retrying a bad password locks the user out of their own server"

      assert Errata.display_message(error) =~ "reconnect"
    end

    test "a missing playlist is not found rather than empty" do
      Req.Test.stub(Navidrome, fn conn ->
        Req.Test.json(conn, failed(70, "Playlist not found"))
      end)

      assert {:error, error} = Navidrome.playlist_track_ids(connection(), "gone")
      assert Errata.reason(error) == :not_found
    end

    test "a generic server error is retryable, unlike an auth failure" do
      assert OnePlaylist.Providers.Subsonic.APIError.reason_for(0) == :server_error
      assert OnePlaylist.Providers.Subsonic.APIError.reason_for(41) == :token_auth_unsupported
      assert OnePlaylist.Providers.Subsonic.APIError.reason_for(9999) == :unexpected
    end
  end

  describe "Mapper.track/1" do
    test "flattens the ISRC array to a scalar" do
      # Subsonic sends `"isrc": ["DESK90390301"]` where TIDAL sends a string.
      # Left as a list it would never equal a TIDAL ISRC, and rung 1 of the
      # ladder — the most valuable one — would silently never fire.
      assert %Track{isrc: "DESK90390301"} = Mapper.track(song())
    end

    test "tolerates a scalar ISRC from a different Subsonic server" do
      assert %Track{isrc: "X"} = Mapper.track(song(%{"isrc" => "X"}))
    end

    test "an absent or empty ISRC is nil, not an empty string" do
      assert %Track{isrc: nil} = Mapper.track(song(%{"isrc" => []}))
      assert %Track{isrc: nil} = Mapper.track(song() |> Map.delete("isrc"))
      assert %Track{isrc: nil} = Mapper.track(song(%{"isrc" => [""]}))
    end

    test "prefers structured artists over the pre-joined display string" do
      track =
        Mapper.track(
          song(%{
            "artist" => "Simon & Garfunkel",
            "artists" => [%{"name" => "Paul Simon"}, %{"name" => "Art Garfunkel"}]
          })
        )

      assert track.artists == ["Paul Simon", "Art Garfunkel"]
    end

    test "falls back to the display string when there is nothing structured" do
      assert %Track{artists: ["Moby Grape"]} = Mapper.track(song() |> Map.delete("artists"))
    end

    test "duration is already seconds" do
      assert %Track{duration_seconds: 165} = Mapper.track(song())
    end

    test "an unexpected shape is a value, not a crash" do
      assert %Track{provider_id: "x"} = Mapper.track(%{"id" => "x"})
    end
  end

  describe "repeated query parameters" do
    test "every track in an append reaches the server" do
      # A real bug, and the worst kind. Req's put_params merges with
      # List.keystore/4, so same-named parameters *replace* each other — and
      # Subsonic expresses a collection as a repeated parameter. A six-track
      # append arrived as a one-track append, the server answered ok, and the
      # adapter reported six because it counted what it was given.
      Req.Test.stub(Navidrome, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        ids =
          conn.query_string |> URI.query_decoder() |> Enum.filter(&(elem(&1, 0) == "songIdToAdd"))

        assert Enum.map(ids, &elem(&1, 1)) == ~w(a b c d e f),
               "all six must survive the query string"

        Req.Test.json(conn, ok(%{}))
      end)

      tracks = for id <- ~w(a b c d e f), do: %Track{provider: :navidrome, provider_id: id}

      assert {:ok, 6} = Navidrome.add_tracks(connection(), "pl-1", tracks)
    end

    test "an empty append makes no request" do
      Req.Test.stub(Navidrome, fn _conn -> flunk("nothing to add, nothing to send") end)

      assert {:ok, 0} = Navidrome.add_tracks(connection(), "pl-1", [])
    end
  end

  describe "search_tracks/3" do
    test "searches by text, because Subsonic has no ISRC filter" do
      # Unlike TIDAL, rung 1 cannot be a direct lookup here. Even a track with
      # an ISRC has to be found by text and then compared.
      Req.Test.stub(Navidrome, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.request_path == "/rest/search3"
        assert conn.query_params["query"] == "Hey Grandma Moby Grape"

        Req.Test.json(conn, ok(%{"searchResult3" => %{"song" => [song()]}}))
      end)

      source = %Track{
        provider: :tidal,
        provider_id: "t1",
        isrc: "DESK90390301",
        title: "Hey Grandma",
        artists: ["Moby Grape"]
      }

      assert {:ok, [candidate]} = Navidrome.search_tracks(connection(), source)
      assert candidate.provider == :navidrome
      assert candidate.isrc == "DESK90390301"
    end

    test "honours the caller's limit" do
      Req.Test.stub(Navidrome, fn conn ->
        songs = for id <- 1..10, do: song(%{"id" => "s#{id}"})
        Req.Test.json(conn, ok(%{"searchResult3" => %{"song" => songs}}))
      end)

      source = %Track{provider: :tidal, provider_id: "t1", title: "Hey Grandma"}

      assert {:ok, candidates} = Navidrome.search_tracks(connection(), source, limit: 3)
      assert length(candidates) == 3
    end

    test "a track with nothing to search by is a caller error" do
      assert_precondition_violation(
        Navidrome.search_tracks(connection(), %Track{
          provider: :tidal,
          provider_id: "t1",
          title: nil,
          isrc: nil
        }),
        label: :searchable
      )
    end
  end

  describe "the server URL" do
    test "a trailing slash does not double the path" do
      # The classic self-hosted footgun: a user pastes the URL from their
      # browser bar and every request becomes //rest/...
      Req.Test.stub(Navidrome, fn conn ->
        assert conn.request_path == "/rest/getPlaylists"
        Req.Test.json(conn, ok(%{"playlists" => %{"playlist" => []}}))
      end)

      trailing = %{connection() | server_url: "http://music.local:4533/"}

      assert {:ok, _stream} = Navidrome.stream_playlists(trailing, [])
    end
  end

  describe "the behaviour" do
    test "is registered, and agrees with the registry about who it is" do
      assert {:ok, Navidrome} = OnePlaylist.Providers.adapter(:navidrome)
      assert Navidrome.provider() == :navidrome
    end
  end
end
