defmodule OnePlaylist.MusicBrainzTest do
  @moduledoc """
  Resolving what else a recording is called.

  The provider call is stubbed with `Req.Test`; what is being tested is the
  cache, the shape of the answer, and the refusal to guess when MusicBrainz
  cannot be reached.
  """

  use OnePlaylist.DataCase, async: false

  import Req.Test, only: [set_req_test_from_context: 1]

  alias OnePlaylist.Cache
  alias OnePlaylist.MusicBrainz
  alias OnePlaylist.MusicBrainz.Client
  alias OnePlaylist.MusicBrainz.IsrcLookup

  # The real pair, from the transfer that motivated all of this: Roon's 2007
  # soundtrack code and TIDAL's 2017 reissue code for one recording.
  @roon "USJY50700001"
  @tidal "USJY51700100"
  @recording "ea8c7b4c-bd88-4029-96ba-fb483eb29e8b"

  setup :set_req_test_from_context

  setup do
    {:ok, _cleared} = Cache.delete_all()
    Repo.delete_all(IsrcLookup)

    Application.put_env(:one_playlist, :musicbrainz_req_options, plug: {Req.Test, Client})
    on_exit(fn -> Application.delete_env(:one_playlist, :musicbrainz_req_options) end)
  end

  defp stub_family(calls \\ nil) do
    Req.Test.stub(Client, fn conn ->
      if calls, do: Agent.update(calls, &(&1 + 1))

      Req.Test.json(conn, %{
        "isrc" => @roon,
        "recordings" => [
          %{"id" => @recording, "title" => "Setting Forth", "isrcs" => [@roon, @tidal]}
        ]
      })
    end)
  end

  describe "family/2" do
    test "answers with every ISRC naming the same recording" do
      stub_family()

      assert family = MusicBrainz.family(@roon)

      assert @tidal in family
      assert @roon in family, "a family that dropped its own key would not match its own track"
    end

    test "normalises before asking, so one fact is one cache row" do
      # MusicBrainz answers 400 for a hyphenated ISRC, and an unnormalised key
      # would be a second private copy of a fact already stored.
      stub_family()

      assert MusicBrainz.family("usjy5-070-0001") == MusicBrainz.family(@roon)
      assert [%IsrcLookup{isrc: @roon}] = Repo.all(IsrcLookup)
    end

    test "asks once, then remembers — in both tiers" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      stub_family(calls)

      MusicBrainz.family(@roon)
      MusicBrainz.family(@roon)

      assert Agent.get(calls, & &1) == 1, "the second call should not reach MusicBrainz"

      # And again with the in-memory tier gone, which is what a deploy looks
      # like. L2 has to answer without a request.
      {:ok, _cleared} = Cache.delete_all()

      assert @tidal in MusicBrainz.family(@roon)
      assert Agent.get(calls, & &1) == 1, "L2 should have answered"
    end

    test "remembers that MusicBrainz has never heard of an ISRC" do
      # The case that costs the most if it is not remembered: a playlist of
      # bootlegs is exactly the playlist whose ISRCs are unknown, and re-asking
      # spends a one-per-second budget to be told nothing twice.
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Client, fn conn ->
        Agent.update(calls, &(&1 + 1))
        Plug.Conn.send_resp(conn, 404, ~s({"error":"Not Found"}))
      end)

      assert MusicBrainz.family("GBAYE0601477") == []
      assert MusicBrainz.family("GBAYE0601477") == []

      assert Agent.get(calls, & &1) == 1
      assert [%IsrcLookup{recording_mbid: nil, isrcs: nil}] = Repo.all(IsrcLookup)
    end

    test "a failure is not remembered, and is not an error to the caller" do
      # An outage is a fact about MusicBrainz, not about the ISRC. Caching it
      # would turn a minute's unavailability into a month of wrong answers.
      Req.Test.stub(Client, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert MusicBrainz.family(@roon) == []
      assert Repo.all(IsrcLookup) == []
    end

    test "answers nothing for a value that is not an ISRC" do
      Req.Test.stub(Client, fn _conn -> flunk("should not have asked") end)

      assert MusicBrainz.family("not-an-isrc") == []
      assert MusicBrainz.family(nil) == []
    end
  end

  describe "prune_negatives/1" do
    test "removes only the negatives, and only the old ones" do
      old = DateTime.add(DateTime.utc_now(), -40, :day)

      Repo.insert!(%IsrcLookup{isrc: "AAAA00000001", isrcs: nil, looked_up_at: old})

      Repo.insert!(%IsrcLookup{
        isrc: "AAAA00000002",
        isrcs: nil,
        looked_up_at: DateTime.utc_now()
      })

      Repo.insert!(%IsrcLookup{
        isrc: "AAAA00000003",
        recording_mbid: @recording,
        isrcs: ["AAAA00000003"],
        looked_up_at: old
      })

      assert MusicBrainz.prune_negatives("30 days") == 1

      remaining = Repo.all(IsrcLookup) |> Enum.map(& &1.isrc) |> Enum.sort()
      assert remaining == ["AAAA00000002", "AAAA00000003"]
    end
  end
end
