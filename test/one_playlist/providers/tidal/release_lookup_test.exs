defmodule OnePlaylist.Providers.Tidal.ReleaseLookupTest do
  @moduledoc """
  Rung 2 for TIDAL: finding a release by barcode and taking the track at a
  position.

  `test/support/fixtures/tidal_album_items.json` is a real
  `/v2/albums/{id}/relationships/items` document saved on 2026-08-22 — 14
  items, each with `meta.trackNumber` and `meta.volumeNumber`.

  The request-counting tests are the point of most of this file. This path
  costs two requests per track where every other path costs one, so what it
  spends is a behaviour worth pinning, not an implementation detail.
  """

  use OnePlaylist.DataCase, async: false

  use Errata

  import Req.Test, only: [set_req_test_from_context: 1]

  alias OnePlaylist.Matching
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.Tidal
  alias OnePlaylist.Cache
  alias OnePlaylist.Providers.Tidal.Mapper

  # `async: false` because both cache tiers are shared state and these tests
  # count requests — a memo left by a concurrent test would make the count
  # wrong. L1 is cleared rather than isolated, since isolating it would mean not
  # testing the thing it exists for; L2 is rolled back by the sandbox.
  setup :set_req_test_from_context

  setup do
    {:ok, _cleared} = Cache.delete_all()
    :ok
  end

  @album_items File.read!("test/support/fixtures/tidal_album_items.json") |> Jason.decode!()

  defp connection do
    %Connection{
      provider: :tidal,
      provider_user_id: "67373615",
      access_token: "at",
      country: "US",
      scopes: ["search.read"],
      status: :active,
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
    }
  end

  # A source that knows its release and its slot on it, as Spotify and Apple
  # Music both supply natively.
  defp positioned(overrides \\ []) do
    defaults = [
      provider: :spotify,
      provider_id: "src",
      isrc: nil,
      title: "Ticket To Ride",
      artists: ["The Beatles"],
      album_upc: "602547670052",
      track_number: 1,
      volume_number: 1,
      duration_seconds: 140
    ]

    struct!(Track, Keyword.merge(defaults, overrides))
  end

  # Serves the barcode lookup and the item list, counting each.
  defp stub_release(counter, opts \\ []) do
    album_id = Keyword.get(opts, :album_id, "55130681")
    items = Keyword.get(opts, :items, @album_items)

    Req.Test.stub(Tidal, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      cond do
        conn.request_path == "/v2/albums" ->
          :counters.add(counter, 1, 1)
          assert get_in(conn.query_params, ["filter", "barcodeId"]) == "602547670052"

          case album_id do
            nil -> Req.Test.json(conn, %{"data" => []})
            id -> Req.Test.json(conn, %{"data" => [%{"id" => id, "type" => "albums"}]})
          end

        String.contains?(conn.request_path, "/relationships/items") ->
          :counters.add(counter, 2, 1)
          Req.Test.json(conn, items)

        conn.request_path == "/v2/searchResults" ->
          :counters.add(counter, 3, 1)
          Req.Test.json(conn, %{"data" => [], "included" => []})

        true ->
          flunk("unexpected request to #{conn.request_path}")
      end
    end)
  end

  describe "Mapper.tracks_from_album_items/2" do
    test "reads positions from meta rather than counting list order" do
      tracks = Mapper.tracks_from_album_items(@album_items, "602547670052")

      assert length(tracks) == 14
      assert Enum.map(tracks, & &1.track_number) == Enum.to_list(1..14)
      assert Enum.all?(tracks, &(&1.volume_number == 1))
      assert Enum.all?(tracks, &(&1.album_upc == "602547670052"))
    end

    test "a gap in `included` drops that track and renumbers nothing" do
      missing_id = @album_items["data"] |> Enum.at(2) |> Map.fetch!("id")

      pruned =
        Map.update!(@album_items, "included", fn included ->
          Enum.reject(included, &(&1["type"] == "tracks" and &1["id"] == missing_id))
        end)

      tracks = Mapper.tracks_from_album_items(pruned, "602547670052")

      assert length(tracks) == 13
      assert Enum.map(tracks, & &1.track_number) == [1, 2] ++ Enum.to_list(4..14)
    end

    test "positions come from meta even when they disagree with list order" do
      # The test above cannot tell the two implementations apart, and a mutation
      # proved it: on this album `meta.trackNumber` happens to equal the list
      # position for every item, so counting by index gives the same answer.
      #
      # A multi-volume release is where they diverge, and it is the case the
      # module documents as the hazard — disc 2 restarts at track 1, so index
      # counting produces 1,2,3,4 where the truth is 1,2,1,2. Rung 2 would then
      # match disc 2 track 1 against disc 1 track 3, at score 1.0.
      two_volumes = %{
        "data" => [
          %{
            "id" => "a",
            "type" => "tracks",
            "meta" => %{"trackNumber" => 1, "volumeNumber" => 1}
          },
          %{
            "id" => "b",
            "type" => "tracks",
            "meta" => %{"trackNumber" => 2, "volumeNumber" => 1}
          },
          %{
            "id" => "c",
            "type" => "tracks",
            "meta" => %{"trackNumber" => 1, "volumeNumber" => 2}
          },
          %{"id" => "d", "type" => "tracks", "meta" => %{"trackNumber" => 2, "volumeNumber" => 2}}
        ],
        "included" =>
          for id <- ~w(a b c d) do
            %{"id" => id, "type" => "tracks", "attributes" => %{"title" => "Track #{id}"}}
          end
      }

      tracks = Mapper.tracks_from_album_items(two_volumes, "x")

      assert Enum.map(tracks, &{&1.volume_number, &1.track_number}) ==
               [{1, 1}, {1, 2}, {2, 1}, {2, 2}]
    end

    test "an item with no track number is skipped rather than guessed at" do
      unnumbered =
        Map.update!(@album_items, "data", fn [first | rest] ->
          [Map.put(first, "meta", %{}) | rest]
        end)

      tracks = Mapper.tracks_from_album_items(unnumbered, "x")

      assert length(tracks) == 13
      refute 1 in Enum.map(tracks, & &1.track_number)
    end

    test "an empty or unexpected document is a value, not a crash" do
      assert Mapper.tracks_from_album_items(%{}) == []

      assert Mapper.tracks_from_album_items(%{"data" => [%{"id" => "x", "type" => "tracks"}]}) ==
               []
    end
  end

  describe "Tidal.search_tracks/3 by release and position" do
    test "finds the track at the source's position, in two requests" do
      counter = :counters.new(3, [])
      stub_release(counter)

      assert {:ok, [candidate]} = Tidal.search_tracks(connection(), positioned())

      assert candidate.track_number == 1
      assert :counters.get(counter, 1) == 1, "one barcode lookup"
      assert :counters.get(counter, 2) == 1, "one item list"
      assert :counters.get(counter, 3) == 0, "text search should not have been needed"
    end

    test "the barcode lookup is remembered across tracks" do
      # The lever that makes this path affordable. Twelve tracks from one
      # release cost twelve item lists but only one barcode lookup.
      counter = :counters.new(3, [])
      stub_release(counter)

      for number <- 1..12 do
        assert {:ok, [_candidate]} =
                 Tidal.search_tracks(connection(), positioned(track_number: number))
      end

      assert :counters.get(counter, 1) == 1, "the barcode should be looked up once"
      assert :counters.get(counter, 2) == 12
    end

    test "a barcode TIDAL does not carry is remembered as absent" do
      # The more valuable half of the cache: without it, every track on an
      # unknown release re-asks and re-learns the same nothing.
      counter = :counters.new(3, [])
      stub_release(counter, album_id: nil)

      for _ <- 1..5, do: Tidal.search_tracks(connection(), positioned())

      assert :counters.get(counter, 1) == 1
      assert :counters.get(counter, 3) == 5, "each track should still fall back to text"
    end

    test "falls back to text when the release lists nothing at that position" do
      counter = :counters.new(3, [])
      stub_release(counter)

      assert {:ok, []} = Tidal.search_tracks(connection(), positioned(track_number: 99))

      assert :counters.get(counter, 3) == 1, "a structural miss must not end the search"
    end

    test "a source with a barcode but no position goes straight to text" do
      counter = :counters.new(3, [])
      stub_release(counter)

      assert {:ok, []} = Tidal.search_tracks(connection(), positioned(track_number: nil))

      assert :counters.get(counter, 1) == 0
      assert :counters.get(counter, 3) == 1
    end

    test "an ISRC still wins, and costs one request" do
      Req.Test.stub(Tidal, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.request_path == "/v2/tracks"
        assert get_in(conn.query_params, ["filter", "isrc"]) == "GBAYE0601477"

        Req.Test.json(conn, %{"data" => [], "included" => []})
      end)

      assert {:ok, []} = Tidal.search_tracks(connection(), positioned(isrc: "GBAYE0601477"))
    end
  end

  describe "the rung, end to end" do
    test "a track with no ISRC resolves exactly by release and position" do
      counter = :counters.new(3, [])
      stub_release(counter)

      source = positioned()

      assert {:ok, candidates} = Tidal.search_tracks(connection(), source)
      assert {:ok, match} = Matching.match(source, candidates)

      assert match.strategy == :upc_position
      assert match.confidence == :exact_upc
      assert match.score == 1.0
    end

    test "a disagreeing duration withdraws the exact claim" do
      # The guard against a confidently wrong answer. Two services can list
      # different items for one barcode, and then position 1 is a different
      # recording on each — which at 1.0 would go straight through unreviewed.
      counter = :counters.new(3, [])
      stub_release(counter)

      source = positioned(duration_seconds: 400)

      assert {:ok, candidates} = Tidal.search_tracks(connection(), source)

      refute match?({:ok, %{strategy: :upc_position}}, Matching.match(source, candidates))
    end

    test "the candidate is still scored on its merits after the claim is withdrawn" do
      # Withdrawing the exact claim must not discard the candidate: the lower
      # rungs still see it, and the title still agrees.
      #
      # Which rung catches it is the policy `Strategy.Text` documents. A
      # duration this far apart is a `duration_conflict`, so the text rung —
      # whose band floor is above the default threshold, leaving it no way to
      # express doubt — declines, and fuzzy scores it in the `0.0`–`0.79` band
      # instead. Hence `threshold: :low` here: at the default this is correctly
      # *not* a match.
      counter = :counters.new(3, [])
      stub_release(counter)

      first_title =
        @album_items["included"]
        |> Enum.find(&(&1["type"] == "tracks" and &1["id"] == "55130682"))
        |> get_in(["attributes", "title"])

      source = positioned(title: first_title, duration_seconds: 400)

      assert {:ok, candidates} = Tidal.search_tracks(connection(), source)
      assert {:ok, match} = Matching.match(source, candidates, threshold: :low)

      assert match.strategy == :fuzzy
    end

    test "an unknown duration does not withdraw the claim" do
      # Absent evidence is not contrary evidence.
      counter = :counters.new(3, [])
      stub_release(counter)

      source = positioned(duration_seconds: nil)

      assert {:ok, candidates} = Tidal.search_tracks(connection(), source)
      assert {:ok, match} = Matching.match(source, candidates)

      assert match.strategy == :upc_position
    end
  end
end
