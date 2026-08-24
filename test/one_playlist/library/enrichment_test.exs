defmodule OnePlaylist.Library.EnrichmentTest do
  @moduledoc """
  Filling in what a recording does not know about itself.

  MusicBrainz is stubbed with `Req.Test`. What is being tested is the shape of
  the outcome: that gaps are filled, that nothing is overwritten, that a
  recording nobody can identify is not asked about forever, and — the case the
  whole design exists for — that a plausible wrong answer is declined.
  """

  use OnePlaylist.DataCase, async: false

  import Req.Test, only: [set_req_test_from_context: 1]

  alias OnePlaylist.Cache
  alias OnePlaylist.Library.Enrichment
  alias OnePlaylist.Library.Recording
  alias OnePlaylist.MusicBrainz.Client
  alias OnePlaylist.MusicBrainz.IsrcLookup

  @isrc "USSM11100234"
  @mbid "ea8c7b4c-bd88-4029-96ba-fb483eb29e8b"
  @release "9c5b2d61-4e8c-4f43-9b71-2c8bd0e1a5f0"

  setup :set_req_test_from_context

  setup do
    {:ok, _cleared} = Cache.delete_all()
    Repo.delete_all(IsrcLookup)

    Application.put_env(:one_playlist, :musicbrainz_req_options, plug: {Req.Test, Client})
    on_exit(fn -> Application.delete_env(:one_playlist, :musicbrainz_req_options) end)
  end

  defp recording(attrs) do
    Repo.insert!(struct(%Recording{title: "Corduroy", artists: ["Pearl Jam"]}, attrs))
  end

  # One stub for every endpoint, dispatching on the path the way the real
  # service does. `overrides` replaces any of the three bodies.
  defp stub_musicbrainz(overrides \\ %{}, counter \\ nil) do
    Req.Test.stub(Client, fn conn ->
      if counter, do: Agent.update(counter, &[conn.request_path | &1])

      # `request_path` carries the `/ws/2` prefix from the base URL, so these
      # match on the segment rather than on the whole path.
      cond do
        conn.request_path =~ "/isrc/" ->
          Req.Test.json(conn, overrides[:isrc] || isrc_body())

        conn.request_path =~ "/recording/" ->
          Req.Test.json(conn, overrides[:lookup] || lookup_body())

        search?(conn.request_path) ->
          Req.Test.json(conn, overrides[:search] || search_body())

        conn.request_path =~ "/release/" ->
          Req.Test.json(conn, overrides[:release] || %{"cover-art-archive" => %{"front" => true}})
      end
    end)
  end

  defp search?(path), do: String.ends_with?(path, "/recording")

  defp isrc_body do
    %{"isrc" => @isrc, "recordings" => [%{"id" => @mbid, "isrcs" => [@isrc]}]}
  end

  defp lookup_body do
    %{
      "id" => @mbid,
      "title" => "Corduroy",
      "length" => 285_000,
      "isrcs" => [@isrc],
      "artist-credit" => [%{"name" => "Pearl Jam"}],
      "releases" => [%{"id" => @release, "title" => "Vitalogy", "barcode" => "074646690123"}]
    }
  end

  defp search_body(recordings \\ nil) do
    %{
      "recordings" =>
        recordings ||
          [
            %{
              "id" => @mbid,
              "score" => 100,
              "title" => "Corduroy",
              "length" => 285_000,
              "artist-credit" => [%{"name" => "Pearl Jam"}],
              "releases" => [%{"id" => @release, "title" => "Vitalogy"}]
            }
          ]
    }
  end

  describe "enrich/1 with an ISRC" do
    test "fills in everything the recording did not know" do
      stub_musicbrainz()

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: @isrc}))

      assert enriched.musicbrainz_recording_id == @mbid
      assert enriched.album == "Vitalogy"
      assert enriched.album_upc == "074646690123"
      assert enriched.duration_seconds == 285
      assert enriched.artwork_url == "https://coverartarchive.org/release/#{@release}/front-250"
      assert enriched.enriched_at
    end

    test "never searches, because an identifier does not need arguing for" do
      {:ok, calls} = Agent.start_link(fn -> [] end)
      stub_musicbrainz(%{}, calls)

      {:ok, _enriched} = Enrichment.enrich(recording(%{isrc: @isrc}))

      refute Enum.any?(Agent.get(calls, & &1), &search?/1),
             "an ISRC identifies the recording outright; a search would be a wasted request"
    end

    test "leaves alone every field that already had a value" do
      # The failure this guards is quiet: a background job that assigned rather
      # than merged would rewrite a user's own titles and albums on a schedule.
      existing =
        recording(%{
          isrc: @isrc,
          title: "Corduroy (Remastered)",
          album: "Vitalogy [2011 Reissue]",
          duration_seconds: 999
        })

      stub_musicbrainz()

      {:ok, enriched} = Enrichment.enrich(existing)

      assert enriched.title == "Corduroy (Remastered)"
      assert enriched.album == "Vitalogy [2011 Reissue]"
      assert enriched.duration_seconds == 999
      assert enriched.album_upc == "074646690123", "the gaps should still be filled"
    end

    test "asks about a release's artwork once, however many recordings name it" do
      {:ok, calls} = Agent.start_link(fn -> [] end)
      stub_musicbrainz(%{}, calls)

      {:ok, _first} = Enrichment.enrich(recording(%{isrc: @isrc}))
      {:ok, _second} = Enrichment.enrich(recording(%{isrc: @isrc, title: "Nothingman"}))

      release_lookups = Agent.get(calls, &Enum.count(&1, fn path -> path =~ "/release/" end))

      assert release_lookups == 1, "an album's worth of recordings asks this question once"
    end

    test "stores no artwork URL when the archive has no cover" do
      # The URL is constructed rather than fetched, so storing one unasked
      # would put a broken image in every playlist that shows the track.
      stub_musicbrainz(%{release: %{"cover-art-archive" => %{"front" => false}}})

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: @isrc}))

      refute enriched.artwork_url
      assert enriched.album == "Vitalogy", "the rest should still have been filled in"
    end
  end

  describe "enrich/1 without an ISRC" do
    test "declines a plausible top hit that nothing corroborates" do
      # The case the whole design exists for. Verified live: MusicBrainz scores
      # a live Barcelona bootleg 100 for "Corduroy" by Pearl Jam. Taking the top
      # hit would attach that recording's identity — and then its ISRC, its
      # length, its artwork — to the studio track somebody imported.
      bootleg = [
        %{
          "id" => "11111111-2222-3333-4444-555555555555",
          "score" => 100,
          "title" => "Corduroy",
          "length" => 402_000,
          "artist-credit" => [%{"name" => "Pearl Jam"}],
          "releases" => [%{"id" => @release, "title" => "2000-06-01: Barcelona, Spain"}]
        }
      ]

      stub_musicbrainz(%{search: search_body(bootleg)})

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: nil, album: "Vitalogy"}))

      refute enriched.musicbrainz_recording_id
      refute enriched.isrc
      assert enriched.enriched_at, "declining is still an answer, and must be remembered"
    end

    test "accepts a candidate the album corroborates" do
      stub_musicbrainz()

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: nil, album: "Vitalogy"}))

      assert enriched.musicbrainz_recording_id == @mbid
      assert enriched.isrc == @isrc, "which is the whole point: it is matchable everywhere now"
    end

    test "declines when there is nothing to corroborate with at all" do
      # Not a tuned rule of enrichment's own: `Strategy.Text` scores an
      # uncorroborated match at 0.89 and `:high` is 0.90, so the ladder already
      # knows that a title and an artist are not enough.
      stub_musicbrainz()

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: nil, album: nil}))

      refute enriched.musicbrainz_recording_id
    end
  end

  describe "enrich/1 when MusicBrainz has nothing to say" do
    test "remembers the attempt, so an unknown recording is not asked about nightly" do
      Req.Test.stub(Client, fn conn ->
        Plug.Conn.send_resp(conn, 404, ~s({"error":"Not Found"}))
      end)

      {:ok, enriched} = Enrichment.enrich(recording(%{isrc: "GBAYE0601477"}))

      assert enriched.enriched_at
      refute enriched.musicbrainz_recording_id
    end

    test "does not remember an outage, because it says nothing about the recording" do
      Req.Test.stub(Client, fn conn ->
        if conn.request_path =~ "/isrc/" do
          Req.Test.json(conn, isrc_body())
        else
          Plug.Conn.send_resp(conn, 500, "")
        end
      end)

      stored = recording(%{isrc: @isrc})

      assert {:error, _reason} = Enrichment.enrich(stored)

      assert %Recording{enriched_at: nil} = Repo.get!(Recording, stored.id)
    end
  end

  describe "due/1" do
    test "offers the never-enriched before the merely stale" do
      # Recordings belong to nobody, so there is no user to scope this to and
      # the dev rows sharing the `postgres` database would otherwise fill the
      # answer. Settling them inside the sandbox is the scoping — it is rolled
      # back with the rest of the test.
      Repo.update_all(Recording, set: [enriched_at: DateTime.utc_now()])

      stale = DateTime.add(DateTime.utc_now(), -60 * 24 * 3600, :second)

      fresh = recording(%{title: "fresh", enriched_at: DateTime.utc_now()})
      old = recording(%{title: "old", enriched_at: stale})
      never = recording(%{title: "never"})

      ids = Enrichment.due(50) |> Enum.map(& &1.id)

      assert never.id in ids
      assert old.id in ids
      refute fresh.id in ids, "a recording asked about this minute is not due"

      assert Enum.find_index(ids, &(&1 == never.id)) <
               Enum.find_index(ids, &(&1 == old.id)),
             "a recording nothing is known about is worth more than a month-old answer"
    end
  end
end
