defmodule OnePlaylist.CatalogueTest do
  @moduledoc """
  The two-tier catalogue cache, tested for the things it exists to guarantee:
  that a fact is bought once, that it survives a node losing its memory, and
  that a hundred simultaneous misses do not become a hundred provider calls.

  Every test counts calls to the provider function, because the point of this
  module is not what it returns — it is what it *does not spend*.
  """

  use OnePlaylist.DataCase, async: false

  alias OnePlaylist.Cache
  alias OnePlaylist.Catalogue
  alias OnePlaylist.Catalogue.ReleaseLookup

  # Real barcodes throughout. `Catalogue.album_id/3` has a precondition that its
  # barcode is already normalized, and the first version of this file used
  # readable labels like "doomed" — which the precondition rejected, correctly.
  # A fixture that could not occur in production tests nothing that matters.
  setup do
    {:ok, _cleared} = Cache.delete_all()
    :ok
  end

  # A provider lookup that records every call, so the tests can assert on spend.
  defp counting(result) do
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      result
    end

    {fun, fn -> :counters.get(counter, 1) end}
  end

  describe "album_id/3" do
    test "asks the provider once, then never again" do
      {lookup, calls} = counting({:ok, "album-1"})

      for _ <- 1..10 do
        assert {:ok, "album-1"} = Catalogue.album_id(:tidal, "602547670111", lookup)
      end

      assert calls.() == 1
    end

    test "survives losing L1, which is the reason L2 exists" do
      {lookup, calls} = counting({:ok, "album-1"})

      assert {:ok, "album-1"} = Catalogue.album_id(:tidal, "602547670111", lookup)

      # A deploy, a restart, a second node: everything L1 knew is gone.
      {:ok, _cleared} = Cache.delete_all()

      assert {:ok, "album-1"} = Catalogue.album_id(:tidal, "602547670111", lookup)

      assert calls.() == 1,
             "a cold node must refill from Postgres, not from the provider's quota"
    end

    test "remembers that a provider does not carry a barcode" do
      # The more valuable half. Without it every track on an unknown release
      # re-asks and re-learns the same nothing.
      {lookup, calls} = counting({:ok, nil})

      for _ <- 1..5 do
        assert {:ok, nil} = Catalogue.album_id(:tidal, "602547670222", lookup)
      end

      assert calls.() == 1
    end

    test "a negative result survives losing L1 too" do
      {lookup, calls} = counting({:ok, nil})

      assert {:ok, nil} = Catalogue.album_id(:tidal, "602547670222", lookup)
      {:ok, _cleared} = Cache.delete_all()
      assert {:ok, nil} = Catalogue.album_id(:tidal, "602547670222", lookup)

      assert calls.() == 1
    end

    test "an error is not remembered" do
      # A failed request says nothing about the catalogue. Caching it would turn
      # a transient outage into a permanent hole in matching.
      {failing, failures} = counting({:error, :boom})

      assert {:error, :boom} = Catalogue.album_id(:tidal, "602547670333", failing)
      assert {:error, :boom} = Catalogue.album_id(:tidal, "602547670333", failing)
      assert failures.() == 2

      assert Repo.get_by(ReleaseLookup, provider: "tidal", barcode: "602547670333") == nil

      {:ok, "recovered"} =
        Catalogue.album_id(:tidal, "602547670333", fn -> {:ok, "recovered"} end)

      assert Repo.get_by(ReleaseLookup, provider: "tidal", barcode: "602547670333")
    end

    test "providers do not share an answer" do
      assert {:ok, "tidal-album"} =
               Catalogue.album_id(:tidal, "602547670444", fn -> {:ok, "tidal-album"} end)

      assert {:ok, "spotify-album"} =
               Catalogue.album_id(:spotify, "602547670444", fn -> {:ok, "spotify-album"} end)

      assert {:ok, "tidal-album"} =
               Catalogue.album_id(:tidal, "602547670444", fn -> flunk("cached") end)
    end

    test "what is written to L2 is what a later reader gets back" do
      assert {:ok, "album-9"} =
               Catalogue.album_id(:tidal, "602547670555", fn -> {:ok, "album-9"} end)

      row = Repo.get_by(ReleaseLookup, provider: "tidal", barcode: "602547670555")

      assert row.provider_album_id == "album-9"
      assert row.looked_up_at
    end
  end

  describe "singleflight" do
    test "a hundred simultaneous misses cost one provider call" do
      # The quota amplifier this exists to prevent: without coalescing, every
      # concurrent miss on one key is its own provider request, and they all
      # arrive at the moment the system is busiest.
      {lookup, calls} = counting({:ok, "album-1"})
      parent = self()

      slow = fn ->
        send(parent, :started)
        # Long enough that every other task is certainly waiting rather than
        # arriving after the first one finished.
        Process.sleep(50)
        lookup.()
      end

      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            Catalogue.album_id(:tidal, "602547679001", slow)
          end)
        end

      results = Task.await_many(tasks, 15_000)

      assert Enum.all?(results, &(&1 == {:ok, "album-1"}))
      assert calls.() == 1, "#{calls.()} provider calls for one key"
    end

    test "different keys are not serialized behind one another" do
      parent = self()

      tasks =
        for barcode <- 1..20 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

            Catalogue.album_id(:tidal, "60254768#{1000 + barcode}", fn ->
              Process.sleep(20)
              {:ok, "album-#{barcode}"}
            end)
          end)
        end

      {elapsed, results} = :timer.tc(fn -> Task.await_many(tasks, 15_000) end)

      assert length(results) == 20

      assert elapsed / 1000 < 400,
             "20 independent keys took #{round(elapsed / 1000)}ms — they are serializing"
    end

    test "an owner that is killed releases its waiters instead of hanging them" do
      parent = self()

      # `spawn_monitor` rather than `Task.async`: a task is linked, so killing
      # it would take the test process with it.
      {owner, owner_ref} =
        spawn_monitor(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

          Catalogue.album_id(:tidal, "602547679002", fn ->
            send(parent, :owner_in_flight)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :owner_in_flight, 2_000

      waiters =
        for _ <- 1..5 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            send(parent, :waiting)

            Catalogue.album_id(:tidal, "602547679002", fn -> {:ok, "late"} end)
          end)
        end

      for _ <- 1..5, do: assert_receive(:waiting, 2_000)

      # An untrappable kill, so the owner's own error handling cannot run and
      # only the coordinator's monitor is left to notice.
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 2_000

      # The timeout here is the assertion. Singleflight's own timeout is 30s, so
      # anything that returns within three seconds was *released*, not merely
      # given up on. One killed request must not become five hung ones.
      for result <- Task.await_many(waiters, 3_000) do
        assert match?({:ok, _album}, result) or match?({:error, _reason}, result)
      end
    end
  end

  describe "forget/2" do
    test "clears both tiers, so the next caller asks again" do
      # For the case a cached id stops working: a barcode is permanent, but a
      # provider's id for that release is not.
      {lookup, calls} = counting({:ok, "album-1"})

      assert {:ok, "album-1"} = Catalogue.album_id(:tidal, "602547670666", lookup)
      assert calls.() == 1

      :ok = Catalogue.forget(:tidal, "602547670666")

      assert Repo.get_by(ReleaseLookup, provider: "tidal", barcode: "602547670666") == nil
      assert {:ok, "album-1"} = Catalogue.album_id(:tidal, "602547670666", lookup)

      assert calls.() == 2, "forgetting must reach L1 as well, or L1 keeps serving the stale id"
    end
  end

  describe "prune_negatives/1" do
    test "removes stale negatives and leaves positives alone" do
      assert {:ok, nil} = Catalogue.album_id(:tidal, "602547679003", fn -> {:ok, nil} end)
      assert {:ok, "keep"} = Catalogue.album_id(:tidal, "602547679004", fn -> {:ok, "keep"} end)

      age(["602547679003", "602547679004"], days: 60)

      assert Catalogue.prune_negatives("30 days") == 1

      assert Repo.get_by(ReleaseLookup, provider: "tidal", barcode: "602547679003") == nil

      assert Repo.get_by(ReleaseLookup, provider: "tidal", barcode: "602547679004"),
             "a positive never stops being true, so it is never pruned"
    end

    test "leaves recent negatives alone" do
      assert {:ok, nil} = Catalogue.album_id(:tidal, "602547679005", fn -> {:ok, nil} end)

      assert Catalogue.prune_negatives("30 days") == 0
      assert Repo.get_by(ReleaseLookup, provider: "tidal", barcode: "602547679005")
    end

    test "the pg_cron job that calls this is scheduled" do
      # The schedule is best-effort in the migration, since pg_cron may not be
      # enabled on a hosted project. Where it is, it should be there.
      %{rows: rows} =
        Repo.query!("select schedule from cron.job where jobname = $1", [
          "prune-catalogue-release-lookups"
        ])

      assert [[schedule]] = rows
      assert schedule =~ ~r/^\d+ \d+ \* \* \*$/
    end
  end

  defp age(barcodes, days: days) do
    Repo.update_all(
      from(l in ReleaseLookup, where: l.barcode in ^barcodes),
      set: [looked_up_at: DateTime.add(DateTime.utc_now(), -days * 24 * 3600)]
    )
  end
end
