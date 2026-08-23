defmodule OnePlaylist.Providers.Tidal.SearchTest do
  @moduledoc """
  Text search, against a response captured from the live service.

  `test/support/fixtures/tidal_search_document.json` is a real
  `/v2/searchResults` document — 20 tracks, 17 albums, 5 artists — saved
  unedited on 2026-08-22. Testing the mapper against an invented document
  would only prove it can parse what its author imagined, and the shape here
  is indirect enough that that is a real risk: the tracks are not in `data`,
  they are identified by a relationship on the single resource that is.
  """

  use ExUnit.Case, async: true
  use Errata

  import Req.Test, only: [set_req_test_from_context: 1]

  alias OnePlaylist.Matching
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.Tidal
  alias OnePlaylist.Providers.Tidal.Client
  alias OnePlaylist.Providers.Tidal.Mapper

  # Several test files stub Req under this same name and all run async. Without
  # per-test ownership they overwrite one another, and a test intermittently
  # gets a response meant for a different one. Same idea as the Ecto sandbox:
  # private ownership for async tests, shared for sync ones.
  setup :set_req_test_from_context

  @document File.read!("test/support/fixtures/tidal_search_document.json") |> Jason.decode!()

  defp connection(scopes) do
    %Connection{
      provider: :tidal,
      provider_user_id: "67373615",
      access_token: "at",
      country: "US",
      scopes: scopes,
      status: :active,
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
    }
  end

  describe "Mapper.tracks_from_search/1 against the captured document" do
    test "resolves the tracks the relationship points at" do
      tracks = Mapper.tracks_from_search(@document)

      assert length(tracks) == 20
      assert Enum.all?(tracks, &match?(%Track{provider: :tidal}, &1))
    end

    test "preserves TIDAL's relevance order" do
      # Order comes from the relationship, not from `included`, which is an
      # unordered bag. Sorting by it would be a silent behaviour change.
      expected = Mapper.search_track_ids(@document)

      assert Enum.map(Mapper.tracks_from_search(@document), & &1.provider_id) == expected
    end

    test "the nested include really does supply artists and albums" do
      # The reason `include=tracks.artists,tracks.albums` is used rather than
      # `include=tracks`: without the nested part these fields are all nil and
      # every candidate is unscoreable on text.
      tracks = Mapper.tracks_from_search(@document)

      assert Enum.count(tracks, &(&1.artists != [])) > 15
      assert Enum.count(tracks, &is_binary(&1.album)) > 15
      assert Enum.any?(tracks, &is_binary(&1.album_upc))
      assert Enum.all?(tracks, &is_binary(&1.title))
    end

    test "an empty or unexpected document is a value, not a crash" do
      assert Mapper.tracks_from_search(%{}) == []
      assert Mapper.tracks_from_search(%{"data" => []}) == []
      assert Mapper.tracks_from_search(%{"data" => [%{"id" => "x"}]}) == []
    end

    test "identifiers with no resource in `included` are dropped, not invented" do
      # Happens for a track unavailable in the account's country: the id is
      # listed and the resource is not returned.
      without_included = Map.delete(@document, "included")

      assert Mapper.tracks_from_search(without_included) == []
      assert Mapper.search_track_ids(without_included) != []
    end
  end

  describe "Client.search_tracks/3" do
    test "asks for a filtered collection, not a path segment" do
      # The distinction that cost eight request variants to find. A rewrite to
      # `/searchResults/{query}` returns 400 from the live service and would
      # pass any test that only stubbed a 200.
      Req.Test.stub(Tidal, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.request_path == "/v2/searchResults"
        assert get_in(conn.query_params, ["filter", "query"]) == "hey jude the beatles"
        assert conn.query_params["include"] == "tracks.artists,tracks.albums"
        assert conn.query_params["countryCode"] == "US"

        Req.Test.json(conn, @document)
      end)

      assert {:ok, tracks} = Client.search_tracks("at", "hey jude the beatles", country: "US")
      assert length(tracks) == 20
    end

    test "an API error propagates rather than becoming an empty result" do
      Req.Test.stub(Tidal, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"errors" => [%{"code" => "INVALID_RESOURCE_ID"}]})
      end)

      assert {:error, error} = Client.search_tracks("at", "anything")
      assert Errata.context(error).tidal_code == "INVALID_RESOURCE_ID"
    end
  end

  describe "Tidal.search_tracks/3" do
    test "uses the ISRC filter when the track has one" do
      asked = start_supervised!({Agent, fn -> [] end})

      Req.Test.stub(Tidal, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        Agent.update(asked, &[conn.request_path | &1])

        if conn.request_path == "/v2/tracks" do
          assert get_in(conn.query_params, ["filter", "isrc"]) == "GBAYE0601477"
          Req.Test.json(conn, %{"data" => [], "included" => []})
        else
          Req.Test.json(conn, %{"data" => [], "included" => []})
        end
      end)

      track = %Track{
        provider: :tidal,
        provider_id: "s1",
        isrc: "GBAYE0601477",
        title: "Yesterday"
      }

      assert {:ok, []} = Tidal.search_tracks(connection(["search.read"]), track)

      assert "/v2/tracks" in Agent.get(asked, & &1),
             "the identifier rung is tried first, and with the right filter"
    end

    test "a lower-case ISRC is normalised before it reaches the provider" do
      # The regression. TIDAL rejects a lower-case ISRC outright, and Roon writes
      # them that way — 57 of 58 tracks in a real import failed, every one that
      # had an ISRC. The parsing boundaries normalise now, and this is the
      # backstop for a track built anywhere else.
      Req.Test.stub(Tidal, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.request_path == "/v2/tracks" do
          assert get_in(conn.query_params, ["filter", "isrc"]) == "GBAYE0601477"
        end

        Req.Test.json(conn, %{"data" => [], "included" => []})
      end)

      track = %Track{
        provider: :file,
        provider_id: "1",
        isrc: "gb-aye-06-01477",
        title: "Yesterday"
      }

      assert {:ok, []} = Tidal.search_tracks(connection(["search.read"]), track)
    end

    test "a failed ISRC lookup falls back to text rather than ending the search" do
      # An empty result stays authoritative — an ISRC names one recording, so a
      # catalogue without it does not have that recording. A *failed* lookup is
      # different, and used not to be treated differently: a rate limit or a
      # rejected identifier ended the search with no candidates at all, and the
      # track came back unmatched having never been searched for by name.
      Req.Test.stub(Tidal, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.request_path == "/v2/tracks" do
          Plug.Conn.send_resp(conn, 429, ~s({"errors":[{"detail":"slow down"}]}))
        else
          assert conn.request_path == "/v2/searchResults"
          Req.Test.json(conn, @document)
        end
      end)

      track = %Track{
        provider: :file,
        provider_id: "1",
        isrc: "GBAYE0601477",
        title: "Yesterday",
        artists: ["The Beatles"]
      }

      assert {:ok, [_candidate | _rest]} = Tidal.search_tracks(connection(["search.read"]), track)
    end

    test "an ISRC the destination does not carry falls back to text" do
      # The regression, with the identifiers that produced it. Roon exports
      # Eddie Vedder's "Setting Forth" as `USJY50700001`, the 2007 soundtrack;
      # TIDAL has the same recording as `USJY51700100`, the 2017 reissue. An
      # ISRC names a recording *as issued*, so a reissue carries a new one and a
      # miss says nothing about whether the catalogue has the recording.
      #
      # Before this, the track was reported "nothing found on the destination"
      # while sitting in the catalogue under a different number.
      Req.Test.stub(Tidal, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.request_path == "/v2/tracks" do
          Req.Test.json(conn, %{"data" => [], "included" => []})
        else
          assert conn.request_path == "/v2/searchResults"
          Req.Test.json(conn, @document)
        end
      end)

      track = %Track{
        provider: :file,
        provider_id: "1",
        isrc: "USJY50700001",
        title: "Setting Forth",
        artists: ["Eddie Vedder"]
      }

      assert {:ok, [_candidate | _rest]} =
               Tidal.search_tracks(connection(["search.read"]), track)
    end

    test "falls back to text, querying title and artists together" do
      Req.Test.stub(Tidal, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.request_path == "/v2/searchResults"
        assert get_in(conn.query_params, ["filter", "query"]) == "Yesterday The Beatles"

        Req.Test.json(conn, @document)
      end)

      track = %Track{
        provider: :tidal,
        provider_id: "s1",
        title: "Yesterday",
        artists: ["The Beatles"]
      }

      assert {:ok, tracks} = Tidal.search_tracks(connection(["search.read"]), track)
      assert length(tracks) == 10, "the default limit should be applied"
    end

    test "the query keeps version markers rather than normalizing them away" do
      # Normalization exists to compare two strings already describing the same
      # recording. Stripping "(Live)" here would ask TIDAL for the studio
      # version and then reject everything it sent back.
      Req.Test.stub(Tidal, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert get_in(conn.query_params, ["filter", "query"]) =~ "(Live)"

        Req.Test.json(conn, @document)
      end)

      track = %Track{
        provider: :tidal,
        provider_id: "s1",
        title: "Yesterday (Live)",
        artists: ["The Beatles"]
      }

      assert {:ok, _tracks} = Tidal.search_tracks(connection(["search.read"]), track)
    end

    test "honours an explicit limit" do
      Req.Test.stub(Tidal, fn conn -> Req.Test.json(conn, @document) end)

      track = %Track{provider: :tidal, provider_id: "s1", title: "Yesterday"}

      assert {:ok, tracks} = Tidal.search_tracks(connection(["search.read"]), track, limit: 3)
      assert length(tracks) == 3
    end

    test "a connection without search.read says which scope is missing" do
      # TIDAL's own refusal names neither the scope nor the parameter, so the
      # check happens here where the answer is actually known.
      Req.Test.stub(Tidal, fn _conn -> flunk("no request should be made without the scope") end)

      track = %Track{provider: :tidal, provider_id: "s1", title: "Yesterday"}

      assert {:error, error} = Tidal.search_tracks(connection(["playlists.read"]), track)
      assert Errata.reason(error) == :insufficient_scope
      assert Errata.context(error).required_scope == "search.read"
      assert Errata.display_message(error) =~ "permissions"
    end
  end

  describe "search feeding the matching engine" do
    test "a track with no ISRC is found by text and matched confidently" do
      # The path this whole feature exists for, end to end against a real
      # response: search by text, score the candidates, pick one.
      Req.Test.stub(Tidal, fn conn -> Req.Test.json(conn, @document) end)

      source = %Track{
        provider: :spotify,
        provider_id: "src",
        title: "Hey Jude",
        artists: ["The Beatles"],
        isrc: nil
      }

      assert {:ok, candidates} = Tidal.search_tracks(connection(["search.read"]), source)
      assert {:ok, match} = Matching.match(source, candidates)

      assert match.strategy in [:text, :fuzzy]
      assert match.track.title =~ "Hey Jude"
      assert match.track in candidates
    end
  end
end
