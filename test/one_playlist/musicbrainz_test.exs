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
  alias OnePlaylist.MusicBrainz.Recording
  alias OnePlaylist.MusicBrainz.WorkLookup

  # The real pair, from the transfer that motivated all of this: Roon's 2007
  # soundtrack code and TIDAL's 2017 reissue code for one recording.
  @roon "USJY50700001"
  @tidal "USJY51700100"
  @recording "ea8c7b4c-bd88-4029-96ba-fb483eb29e8b"

  setup :set_req_test_from_context

  setup do
    {:ok, _cleared} = Cache.delete_all()
    Repo.delete_all(IsrcLookup)
    Repo.delete_all(WorkLookup)
    Repo.delete_all(Recording)

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

  describe "recording/2" do
    defp stub_recording(calls \\ nil, status \\ 200) do
      Req.Test.stub(Client, fn conn ->
        if calls, do: Agent.update(calls, &(&1 + 1))

        if status == 200 do
          Req.Test.json(conn, %{
            "id" => @recording,
            "title" => "Setting Forth",
            "length" => 187_000,
            "isrcs" => [@roon, @tidal],
            "artist-credit" => [%{"name" => "Eddie Vedder"}],
            "releases" => [%{"id" => "r-1", "title" => "Into the Wild"}]
          })
        else
          Plug.Conn.send_resp(conn, status, ~s({"error":"boom"}))
        end
      end)
    end

    test "asks once, then remembers — in both tiers" do
      # The gap this closed. `family/2`, `works/3` and `release/2` all read
      # through the cache; the recording lookup went to the network on every
      # single `Enrichment.describe/3`, so a recording identified in January was
      # fetched again in February to learn nothing.
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      stub_recording(calls)

      assert {:ok, %{"title" => "Setting Forth"}} = MusicBrainz.recording(@recording)
      assert {:ok, %{"title" => "Setting Forth"}} = MusicBrainz.recording(@recording)

      assert Agent.get(calls, & &1) == 1, "the second call should not reach MusicBrainz"

      # And with the per-node tier gone, which is what a deploy looks like.
      {:ok, _cleared} = Cache.delete_all()

      assert {:ok, %{"title" => "Setting Forth"}} = MusicBrainz.recording(@recording)
      assert Agent.get(calls, & &1) == 1, "L2 should have answered"
    end

    test "keeps the whole document, because `choose_release/2` reads all of it" do
      # The reason this is not a table of promoted columns alone. A recording's
      # `releases` array — with each release's group, barcode and title nested
      # inside it — is what picks which release describes the recording, and
      # `inc=work-rels` carries relationships nothing has a shape for yet.
      stub_recording()

      assert {:ok, document} = MusicBrainz.recording(@recording)
      assert [%{"id" => "r-1", "title" => "Into the Wild"}] = document["releases"]

      assert %Recording{} = row = Repo.get(Recording, @recording)
      assert row.document["releases"] == document["releases"]
    end

    test "promotes what something already reads" do
      # Queryable as catalogue rather than as a blob — the half of "world
      # knowledge should be first class" that costs nothing.
      stub_recording()
      {:ok, _document} = MusicBrainz.recording(@recording)

      assert %Recording{
               title: "Setting Forth",
               length_ms: 187_000,
               artist_credit: "Eddie Vedder"
             } = row = Repo.get(Recording, @recording)

      assert @roon in row.isrcs and @tidal in row.isrcs
    end

    test "propagates a failure instead of remembering it as an answer" do
      # Where this deliberately differs from `release/2`, which swallows. A
      # release that cannot be fetched costs a barcode; a recording that cannot
      # be fetched is the entire answer, and `Enrichment.describe/3` has to tell
      # "MusicBrainz is down" from "MusicBrainz has nothing" — an outage written
      # down as a completed attempt is a recording never asked about again.
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      stub_recording(calls, 500)

      assert {:error, _reason} = MusicBrainz.recording(@recording)
      refute Repo.get(Recording, @recording), "a failure is not a fact"

      assert {:error, _again} = MusicBrainz.recording(@recording)
      assert Agent.get(calls, & &1) > 1, "and it is asked again next time"
    end

    test "answers nothing for a blank id without asking" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      stub_recording(calls)

      assert MusicBrainz.recording(nil) == {:ok, nil}
      assert Agent.get(calls, & &1) == 0
    end
  end

  describe "works/3" do
    defp stub_works(titles, calls \\ nil) do
      Req.Test.stub(Client, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        if calls, do: Agent.update(calls, &[conn.query_params["query"] | &1])

        Req.Test.json(conn, %{
          "works" =>
            Enum.map(titles, fn {title, score} -> %{"title" => title, "score" => score} end)
        })
      end)
    end

    test "answers with the titles that carry a catalogue number" do
      stub_works([{"Brandenburgisches Konzert Nr. 2 F-Dur, BWV 1047", 100}])

      assert ["Brandenburgisches Konzert Nr. 2 F-Dur, BWV 1047"] =
               MusicBrainz.works("Brandenburg Concerto no. 2", "Johann Sebastian Bach")
    end

    test "asks by surname, not by the full name" do
      # "Brandenburg Concerto no. 2 johann sebastian bach" returns works *about*
      # Bach — "Johann Sebastian Bach auf Rügen" — and no catalogue number at
      # all. The surname alone returns the concerto.
      {:ok, calls} = Agent.start_link(fn -> [] end)
      stub_works([{"Brandenburgisches Konzert Nr. 2 F-Dur, BWV 1047", 100}], calls)

      MusicBrainz.works("Brandenburg Concerto no. 2", "Johann Sebastian Bach")

      assert [query] = Agent.get(calls, & &1)
      assert query =~ "bach"
      refute query =~ "johann"
    end

    test "drops weakly-scoring results" do
      # MusicBrainz answers every query with something: a search for "Woo"
      # returns 48,000 works. The floor is what makes an answer an answer.
      stub_works([{"Something Vaguely Similar, BWV 999", 40}])

      assert MusicBrainz.works("Prelude", "Somebody") == []
    end

    test "asks once, then remembers, in both tiers" do
      {:ok, calls} = Agent.start_link(fn -> [] end)
      stub_works([{"Concerto grosso in C major, HWV 318", 100}], calls)

      MusicBrainz.works("Concerto Alexander Feast", "George Frideric Handel")
      MusicBrainz.works("Concerto Alexander Feast", "George Frideric Handel")

      assert length(Agent.get(calls, & &1)) == 1

      {:ok, _cleared} = Cache.delete_all()

      assert MusicBrainz.works("Concerto Alexander Feast", "George Frideric Handel") != []
      assert length(Agent.get(calls, & &1)) == 1, "L2 should have answered"
    end

    test "remembers that MusicBrainz had nothing" do
      # A playlist is mostly not classical, and every pop title reaching this
      # would otherwise re-ask a one-per-second service to be told nothing.
      {:ok, calls} = Agent.start_link(fn -> [] end)
      stub_works([], calls)

      assert MusicBrainz.works("Woo", "Rihanna") == []
      assert MusicBrainz.works("Woo", "Rihanna") == []

      assert length(Agent.get(calls, & &1)) == 1
      assert [%WorkLookup{catalogue_titles: nil}] = Repo.all(WorkLookup)
    end

    test "a failure is not remembered" do
      Req.Test.stub(Client, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert MusicBrainz.works("Brandenburg Concerto no. 2", "Bach") == []
      assert Repo.all(WorkLookup) == []
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

  describe "who owns retrying" do
    @tag timeout: 60_000
    test "a 503 is attempted as many times as ExternalService says, and no more" do
      # Req's default is `:safe_transient` — three attempts of its own inside
      # each guarded call. Left on, `MusicBrainz.Service`'s three attempts
      # become twelve requests, and the extra nine never pass the rate limiter,
      # because the limiter wraps the whole function and Req retries inside it.
      #
      # Against a service allowing one request a second, that is a client which
      # hammers a busy server exactly when it has asked to be left alone. It
      # happened: a run of probes drove MusicBrainz to 503 and the log read
      # `retry: got response with status 503, will retry in 0ms`.
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Client, fn conn ->
        Agent.update(calls, &(&1 + 1))
        Plug.Conn.send_resp(conn, 503, "busy")
      end)

      MusicBrainz.family(@roon)

      # Three, from `OnePlaylist.MusicBrainz.Service`'s `max_attempts`. Restore
      # Req's default at that call site and this reads **12** — measured, which
      # is why the number is named here rather than described.
      assert Agent.get(calls, & &1) <= 3
    end
  end
end
