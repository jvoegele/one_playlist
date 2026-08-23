defmodule OnePlaylist.TransfersTest do
  @moduledoc """
  The transfer pipeline, organised around the promises it makes.

  Three of them, and each has a test that fails if it is broken:

    * **Nothing is silently dropped.** Every source track gets a report row,
      and the counters agree with the rows.
    * **A retry does not duplicate.** Running a completed transfer again adds
      nothing and creates no second playlist.
    * **A crash mid-run is recoverable.** A transfer that died after creating
      its destination resumes into the same playlist.

  The runner is driven directly rather than through Oban. It is a plain
  function over a transfer, which is why the worker is three lines — and a test
  that has to drain a queue to find out whether a diff was computed correctly
  is testing the wrong thing.
  """

  use OnePlaylist.DataCase, async: false
  use Oban.Testing, repo: OnePlaylist.Repo, prefix: "oban"
  use Bond.Test
  use Errata

  import Req.Test, only: [set_req_test_from_context: 1]

  alias OnePlaylist.AuthFixtures
  alias OnePlaylist.Cache
  alias OnePlaylist.Providers
  alias OnePlaylist.Transfers
  alias OnePlaylist.Transfers.Runner
  alias OnePlaylist.Transfers.Transfer
  alias OnePlaylist.Transfers.TransferWorker

  setup :set_req_test_from_context

  setup do
    {:ok, _cleared} = Cache.delete_all()

    user_id = AuthFixtures.user_id_fixture()

    {:ok, connection} =
      Providers.connect(user_id, :tidal, %{
        provider_user_id: "67373615",
        access_token: "at",
        refresh_token: "rt",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
        scopes: ["playlists.read", "playlists.write", "search.read"],
        country: "US"
      })

    %{user: user_id, connection: connection}
  end

  # A source playlist of three tracks, each with an ISRC so matching is exact
  # and the tests are about the pipeline rather than about the ladder.
  defp source_document do
    %{
      "data" => for(id <- ~w(s1 s2 s3), do: %{"id" => id, "type" => "tracks"}),
      "included" =>
        for id <- ~w(s1 s2 s3) do
          %{
            "id" => id,
            "type" => "tracks",
            "attributes" => %{"title" => "Song #{id}", "isrc" => isrc(id)}
          }
        end
    }
  end

  # Exactly twelve alphanumerics. `Strategy.Isrc.normalize/1` rejects anything
  # else, so a shorter fixture silently demotes every match to the text rung —
  # which is what the first version of this file did, while its own comment
  # claimed the matches were exact.
  defp isrc(id), do: String.pad_trailing("ISRC#{id}", 12, "0")

  defp candidate_document(source_id) do
    %{
      "data" => [
        %{
          "id" => "d#{source_id}",
          "type" => "tracks",
          "attributes" => %{"title" => "Song #{source_id}", "isrc" => isrc(source_id)}
        }
      ],
      "included" => []
    }
  end

  # A TIDAL stand-in that records every write, so a test can assert on what the
  # pipeline actually did rather than on what it reported doing.
  defp stub_provider(state, opts) do
    # Source ids for which the destination has no candidate at all, so a test can
    # drive the unmatched branch without a second stub.
    unmatchable = Keyword.get(opts, :unmatchable, [])

    Req.Test.stub(OnePlaylist.Providers.Tidal, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      path = conn.request_path

      cond do
        # The source playlist's tracks.
        conn.method == "GET" and path == "/v2/playlists/source-1/relationships/items" ->
          Req.Test.json(conn, source_document())

        # The destination playlist's current contents.
        conn.method == "GET" and String.contains?(path, "/relationships/items") ->
          Req.Test.json(conn, %{
            "data" =>
              Agent.get(state, & &1.added) |> Enum.map(&%{"id" => &1, "type" => "tracks"}),
            "links" => %{}
          })

        # Candidate lookup by ISRC.
        conn.method == "GET" and path == "/v2/tracks" ->
          isrc = get_in(conn.query_params, ["filter", "isrc"])
          # Downcased because an ISRC is canonically upper case now, and this
          # fixture derives its ids from one. `Music.Isrc.normalize/1` upcases
          # at the parsing boundaries, so what arrives here is `ISRCS1000000`
          # where the fixture's own ids are `s1`.
          source_id =
            isrc |> Kernel.||("") |> String.replace(~r/^ISRC|0+$/, "") |> String.downcase()

          if source_id in unmatchable do
            Req.Test.json(conn, %{"data" => [], "included" => []})
          else
            Req.Test.json(conn, candidate_document(source_id))
          end

        conn.method == "POST" and path == "/v2/playlists" ->
          Agent.update(state, &%{&1 | playlists_created: &1.playlists_created + 1})

          Req.Test.json(conn, %{
            "data" => %{
              "id" => "dest-1",
              "type" => "playlists",
              "attributes" => %{"name" => "Copied"}
            }
          })

        conn.method == "POST" and String.contains?(path, "/relationships/items") ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          ids = Jason.decode!(body)["data"] |> Enum.map(& &1["id"])

          Agent.update(state, fn s ->
            %{s | added: s.added ++ ids, add_calls: s.add_calls + 1}
          end)

          Req.Test.json(conn, %{})

        true ->
          flunk("unexpected #{conn.method} #{path}")
      end
    end)
  end

  defp provider_state(opts \\ []) do
    {:ok, state} = Agent.start_link(fn -> %{added: [], add_calls: 0, playlists_created: 0} end)
    stub_provider(state, opts)
    state
  end

  defp transfer_for(user, attrs \\ %{}) do
    {:ok, transfer} =
      Transfers.create(
        Map.merge(
          %{
            user_id: user,
            source_provider: :tidal,
            source_playlist_id: "source-1",
            source_playlist_name: "Copied",
            destination_provider: :tidal
          },
          attrs
        )
      )

    transfer
  end

  describe "create/1" do
    test "persists the transfer and queues a job atomically", %{user: user} do
      transfer = transfer_for(user)

      assert transfer.status == :pending
      assert transfer.threshold

      assert_enqueued(worker: TransferWorker, args: %{transfer_id: transfer.id})
    end

    test "an invalid transfer queues nothing", %{user: user} do
      assert {:error, changeset} =
               Transfers.create(%{user_id: user, source_provider: :tidal, threshold: 0.5})

      refute changeset.valid?
      refute_enqueued(worker: TransferWorker)
    end
  end

  describe "a first run" do
    test "transfers every track and reports on each one", %{user: user} do
      state = provider_state()
      transfer = transfer_for(user)

      assert {:ok, completed} = Runner.run(transfer)

      assert completed.status == :completed
      assert completed.total_tracks == 3
      assert completed.matched_count == 3
      assert completed.added_count == 3
      assert completed.unmatched_count == 0

      assert Agent.get(state, & &1.added) == ~w(ds1 ds2 ds3)

      items = Transfers.items(completed)
      assert length(items) == 3
      assert Enum.map(items, & &1.position) == [0, 1, 2]
      assert Enum.all?(items, &(&1.outcome == :matched))
      assert Enum.all?(items, &(&1.confidence == "exact_isrc"))
    end

    test "writes in one batched call rather than one per track", %{user: user} do
      # Three tracks is under the batch size, so this is one call. A pipeline
      # that wrote per track would spend a transfer's retry budget on a
      # provider that returned four 429s out of five rapid single writes.
      state = provider_state()

      assert {:ok, _completed} = Runner.run(transfer_for(user))
      assert Agent.get(state, & &1.add_calls) == 1
    end

    test "every source track is accounted for, whatever happens to it", %{user: user} do
      # One track with no candidate at all, to prove the ledger balances across
      # both outcomes rather than only the happy one.
      _state = provider_state(unmatchable: ["s2"])

      assert {:ok, completed} = Runner.run(transfer_for(user))

      assert completed.total_tracks == 3
      assert completed.matched_count + completed.unmatched_count == 3
      assert completed.matched_count == 2
      assert completed.unmatched_count == 1

      assert [item] = Transfers.items(completed, outcome: :unmatched)
      assert item.source_track_id == "s2"
      assert item.reason == "no_candidates"
      assert item.candidates_considered == 0

      assert Transfers.count_items(completed) == 3,
             "an unmatched track still gets a row: that is the whole promise"
    end
  end

  describe "running again" do
    test "adds nothing and creates no second playlist", %{user: user} do
      state = provider_state()
      transfer = transfer_for(user)

      assert {:ok, first} = Runner.run(transfer)
      assert first.added_count == 3

      assert {:ok, second} = Runner.run(first)

      assert second.matched_count == 3, "the tracks still match on a re-run"
      assert second.added_count == 0, "and none of them is added twice"

      assert Agent.get(state, & &1.added) == ~w(ds1 ds2 ds3)
      assert Agent.get(state, & &1.playlists_created) == 1
    end

    test "the report says why the second run did nothing", %{user: user} do
      _state = provider_state()
      transfer = transfer_for(user)

      {:ok, first} = Runner.run(transfer)
      {:ok, second} = Runner.run(first)

      assert Transfers.items(second, outcome: :already_present) |> length() == 3

      assert Transfers.items(second) |> length() == 3,
             "the report is rewritten, not appended to"
    end
  end

  describe "a retry after a failure" do
    test "clears the error the failed attempt left behind", %{user: user} do
      _state = provider_state()
      transfer = transfer_for(user)

      {:ok, failed} = Transfers.record_failure(transfer, "the call was throttled")
      assert failed.status == :failed
      assert failed.last_error

      assert {:ok, completed} = Runner.run(failed)

      assert completed.status == :completed

      refute completed.last_error,
             "a completed transfer showing the error a retry fixed is a report " <>
               "that contradicts itself"
    end
  end

  describe "resuming" do
    test "a transfer that died after creating its playlist reuses it", %{user: user} do
      state = provider_state()

      # The state a crash between `create_playlist` and the writes leaves behind.
      transfer = transfer_for(user)

      {:ok, interrupted} =
        Transfers.record_progress(transfer, %{destination_playlist_id: "dest-1"})

      assert {:ok, completed} = Runner.run(interrupted)

      assert completed.added_count == 3

      assert Agent.get(state, & &1.playlists_created) == 0,
             "a resumed transfer must not create a second destination playlist"
    end
  end

  describe "await/2" do
    test "returns a transfer that has already finished", %{user: user} do
      _state = provider_state()
      transfer = transfer_for(user)

      {:ok, completed} = Runner.run(transfer)

      assert {:ok, awaited} = Transfers.await(completed, timeout: 1_000)
      assert awaited.id == completed.id
      assert awaited.status == :completed
    end

    test "times out rather than blocking forever on one that has not", %{user: user} do
      transfer = transfer_for(user)

      assert {:error, :timeout} = Transfers.await(transfer, timeout: 150, frequency: 25)
    end

    test "returns as soon as a concurrently-running transfer finishes", %{user: user} do
      _state = provider_state()
      transfer = transfer_for(user)
      parent = self()

      Task.start(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        Process.sleep(80)
        Runner.run(transfer)
      end)

      # The reason `await/2` exists rather than a sleep: it returns when the
      # work is done, not when a guessed interval has elapsed.
      assert {:ok, completed} = Transfers.await(transfer, timeout: 5_000, frequency: 20)
      assert completed.status == :completed
    end
  end

  describe "the worker" do
    test "runs the transfer and marks it started", %{user: user} do
      _state = provider_state()
      transfer = transfer_for(user)

      assert :ok = perform_job(TransferWorker, %{transfer_id: transfer.id})

      {:ok, completed} = Transfers.fetch_unscoped(transfer.id)
      assert completed.status == :completed
      assert completed.started_at
      assert completed.completed_at
    end

    test "a vanished transfer is cancelled rather than retried forever" do
      assert {:cancel, :transfer_not_found} =
               perform_job(TransferWorker, %{transfer_id: Ecto.UUID.generate()})
    end
  end

  describe "the ledger contract" do
    test "a run that lost a track would be caught", %{user: user} do
      # `every_track_accounted_for` cannot be provoked through the public API —
      # correct code cannot drop one. It is mutation-verified instead (see the
      # commit); this pins the property so a rewrite has something to fail.
      _state = provider_state()

      assert {:ok, completed} = Runner.run(transfer_for(user))

      assert completed.matched_count + completed.unmatched_count == completed.total_tracks
      assert Transfers.count_items(completed) == completed.total_tracks
    end

    test "a transfer cannot have added more tracks than it matched" do
      # The second law, and not implied by the first: `added` counts what was
      # *written*, so a matched track already present at the destination is
      # matched but not added. More added than matched would mean the report
      # claims to have written tracks it never matched — which is what a re-run
      # accumulating on top of a completed transfer would look like.
      impossible = %Transfer{total_tracks: 3, matched_count: 1, added_count: 2}

      assert_invariant_violation(Transfer.finished?(impossible),
        label: :added_at_most_matched
      )
    end

    test "counters cannot be advanced without their opposite number" do
      # An `@invariant` since Bond 1.15.0, which made invariants usable on an
      # `Ecto.Schema` at all. It was three duplicated postconditions before that,
      # and the law is about every value of the type rather than about the
      # functions that happen to build one — so this is now an invariant
      # violation, and it also fires for a transfer read back from the database
      # or built by hand, which no postcondition could reach.
      #
      # The struct below satisfies the invariant on the way *in* — 2 counted of 2
      # total — and breaks it on the way out, at 3 of 2.
      transfer = %Transfer{total_tracks: 2, matched_count: 2, unmatched_count: 0}

      assert_invariant_violation(Transfer.record_matched(transfer, true),
        label: :ledger_balances
      )
    end
  end

  describe "fetch/2" do
    test "returns a user's own transfer", %{user: user} do
      transfer = transfer_for(user)

      assert {:ok, ^transfer} = Transfers.fetch(user, transfer.id)
    end

    test "will not return somebody else's", %{user: user} do
      transfer = transfer_for(user)
      stranger = AuthFixtures.user_id_fixture()

      assert Transfers.fetch(stranger, transfer.id) == :error
    end

    test "answers the same for a stranger's transfer and a missing one", %{user: user} do
      transfer = transfer_for(user)
      stranger = AuthFixtures.user_id_fixture()

      assert Transfers.fetch(stranger, transfer.id) ==
               Transfers.fetch(stranger, Ecto.UUID.generate())
    end

    test "the query that shipped the bug is now refused by Postgres", %{user: user} do
      # The original defect, reproduced deliberately: `get_by` with no `user_id`,
      # which is what `TransferLive.Show.mount/3` effectively did. Run inside
      # `Repo.as_user/3` it comes back `nil`, because the `own transfers select`
      # policy filters the row before Ecto ever sees it.
      #
      # This is the difference the RLS work bought. Verified by mutation too:
      # deleting `user_id:` from `fetch/2`'s real query leaves every test in this
      # file and in transfer_live_test.exs passing.
      transfer = transfer_for(user)
      stranger = AuthFixtures.user_id_fixture()

      {:ok, leaked} =
        Repo.as_user(stranger, fn -> Repo.get_by(Transfer, id: transfer.id) end)

      assert leaked == nil

      # And the same unscoped query as the owner still finds it, so this is
      # authorisation rather than the table being unreadable.
      {:ok, found} = Repo.as_user(user, fn -> Repo.get_by(Transfer, id: transfer.id) end)
      assert found.id == transfer.id
    end

    test "fetch_unscoped/1 deliberately does not care", %{user: user} do
      # The escape hatch the worker needs, tested so its behaviour is a decision
      # on the record rather than an accident nobody looks at.
      transfer = transfer_for(user)

      assert {:ok, ^transfer} = Transfers.fetch_unscoped(transfer.id)
    end

    test "the ownership property holds for every transfer a user can reach", %{user: user} do
      # `belongs_to_the_caller` cannot be provoked through the public API —
      # correct code cannot return somebody else's row — so it is mutation
      # verified (see the commit: dropping `user_id` from the `get_by` makes it
      # fire) and pinned here, the same way `every_track_accounted_for` is.
      #
      # What this adds over the two tests above is *quantification*: they check
      # one stranger against one transfer, and this checks the property across
      # everything the user actually owns.
      mine = Enum.map(1..3, fn n -> transfer_for(user, %{source_playlist_id: "src-#{n}"}) end)
      stranger = AuthFixtures.user_id_fixture()

      for transfer <- mine do
        assert {:ok, fetched} = Transfers.fetch(user, transfer.id)
        assert fetched.user_id == user
        assert Transfers.fetch(stranger, transfer.id) == :error
      end
    end
  end

  describe "delete/2" do
    setup %{user: user} do
      %{session: OnePlaylist.AuthFixtures.session_fixture(user_id: user)}
    end

    test "removes the transfer and everything hanging off it", %{user: user, session: session} do
      transfer = transfer_for(user)

      {:ok, _source} =
        transfer.id
        |> OnePlaylist.Transfers.Source.changeset(
          user,
          [%OnePlaylist.Music.Track{provider: :file, provider_id: "1", title: "A"}],
          :csv
        )
        |> Repo.insert()

      assert :ok = Transfers.delete(session, transfer.id)

      assert Transfers.fetch(user, transfer.id) == :error
      assert Repo.get(OnePlaylist.Transfers.Source, transfer.id) == nil
    end

    test "will not delete somebody else's", %{user: user} do
      transfer = transfer_for(user)
      stranger = OnePlaylist.AuthFixtures.session_fixture()

      assert Transfers.delete(stranger, transfer.id) == :error
      assert {:ok, _still_there} = Transfers.fetch(user, transfer.id)
    end

    test "answers the same for a stranger's transfer and a missing one", %{user: user} do
      transfer = transfer_for(user)
      stranger = OnePlaylist.AuthFixtures.session_fixture()

      assert Transfers.delete(stranger, transfer.id) ==
               Transfers.delete(stranger, Ecto.UUID.generate())
    end

    test "a provider-sourced transfer needs no file removed", %{user: user, session: session} do
      # `source_playlist_id` is a provider's playlist id here, not a storage
      # path. Handing it to Storage would ask to delete an object that never
      # existed, under a path with somebody else's prefix.
      transfer = transfer_for(user, %{source_provider: :tidal, source_playlist_id: "p1"})

      assert :ok = Transfers.delete(session, transfer.id)
    end
  end
end
