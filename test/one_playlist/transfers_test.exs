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
  alias OnePlaylist.Library
  alias OnePlaylist.Library.Identities
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers
  alias OnePlaylist.Transfers
  alias OnePlaylist.Transfers.PlaylistTooLarge
  alias OnePlaylist.Transfers.Runner
  alias OnePlaylist.Transfers.Transfer
  alias OnePlaylist.Transfers.TransferItem
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

    {:ok, _library} = Providers.ensure_library(user_id)

    %{user: user_id, connection: connection}
  end

  # The source: three recordings in a library playlist, each with an ISRC so
  # matching is exact and the tests are about the pipeline rather than the
  # ladder.
  #
  # A **library** source rather than a second TIDAL playlist, and the reason
  # matters: source and destination on one service is a case the runner now
  # short-circuits entirely — `same_service?/3` — so a same-provider fixture
  # would silently stop exercising search, matching, candidates and overrides,
  # which is most of what this file is about. The library adapter needs no HTTP
  # stub, so this costs nothing and is more representative than TIDAL to TIDAL
  # ever was.
  defp source_playlist(user_id) do
    {:ok, playlist} = Library.create_playlist(user_id, "Copied")

    tracks =
      for id <- ~w(s1 s2 s3) do
        %Track{
          provider: :tidal,
          provider_id: "src-#{id}-#{System.unique_integer([:positive])}",
          title: "Song #{id}",
          isrc: isrc(id)
        }
      end

    3 = Library.append(user_id, playlist.id, tracks)

    playlist
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

  # Two plausible-looking tracks, neither of them the one asked for.
  defp wrong_candidate_document(source_id) do
    %{
      "data" =>
        for suffix <- ~w(a b) do
          %{
            "id" => "wrong-#{source_id}#{suffix}",
            "type" => "tracks",
            "attributes" => %{
              "title" => "Something Else #{suffix}",
              "isrc" => String.pad_trailing("ISRCX#{suffix}", 12, "9")
            }
          }
        end,
      "included" => []
    }
  end

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
    rejected = Keyword.get(opts, :rejected, [])

    Req.Test.stub(OnePlaylist.Providers.Tidal, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      path = conn.request_path

      cond do
        # A TIDAL *source* playlist, used only by the same-service tests. Every
        # other test in this file sources from the library, so that the runner
        # does not short-circuit the matching they exist to exercise.
        conn.method == "GET" and path == "/v2/playlists/same-src/relationships/items" ->
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
          Agent.update(state, &%{&1 | searches: &1.searches + 1})
          isrc = get_in(conn.query_params, ["filter", "isrc"])
          # Downcased because an ISRC is canonically upper case now, and this
          # fixture derives its ids from one. `Music.Isrc.normalize/1` upcases
          # at the parsing boundaries, so what arrives here is `ISRCS1000000`
          # where the fixture's own ids are `s1`.
          source_id =
            isrc |> Kernel.||("") |> String.replace(~r/^ISRC|0+$/, "") |> String.downcase()

          cond do
            source_id in unmatchable ->
              Req.Test.json(conn, %{"data" => [], "included" => []})

            # Found, and none of them right. The ISRC does not match the one
            # asked for, so rung 1 declines and the text rung scores a title
            # that has nothing to do with the source. This is the case the
            # override screen exists for, and it is distinct from finding
            # nothing at all.
            source_id in rejected ->
              Req.Test.json(conn, wrong_candidate_document(source_id))

            true ->
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

        # A text search. Reached when an ISRC lookup misses, which is now a
        # fallback rather than an answer: an ISRC names a recording *as issued*,
        # and a reissue carries a different one. The unmatchable fixtures below
        # find nothing here either, which is what makes them unmatchable.
        conn.method == "GET" and path == "/v2/searchResults" ->
          Req.Test.json(conn, %{"data" => [], "included" => []})

        true ->
          flunk("unexpected #{conn.method} #{path}")
      end
    end)
  end

  defp provider_state(opts \\ []) do
    {:ok, state} =
      Agent.start_link(fn ->
        %{added: [], add_calls: 0, playlists_created: 0, searches: 0}
      end)

    stub_provider(state, opts)
    state
  end

  defp transfer_for(user, attrs \\ %{}) do
    source = Map.get_lazy(attrs, :source_playlist_id, fn -> source_playlist(user).id end)

    {:ok, transfer} =
      Transfers.create(
        Map.merge(
          %{
            user_id: user,
            source_provider: :library,
            source_playlist_id: source,
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

  describe "create_batch/2" do
    defp batch_common(user) do
      %{user_id: user, source_provider: :tidal, destination_provider: :navidrome}
    end

    defp batch_members(count) do
      for n <- 1..count do
        %{
          source_playlist_id: "src-#{n}",
          source_playlist_name: "Playlist #{n}",
          destination_playlist_name: "Playlist #{n}"
        }
      end
    end

    test "queues one transfer per playlist, all sharing a batch", %{user: user} do
      assert {:ok, transfers} = Transfers.create_batch(batch_common(user), batch_members(3))

      assert length(transfers) == 3
      assert [_one] = transfers |> Enum.map(& &1.batch_id) |> Enum.uniq()

      assert Enum.map(transfers, & &1.source_playlist_id) == ~w(src-1 src-2 src-3),
             "in the order the playlists were given, so the list reads like the picker"

      for transfer <- transfers do
        assert_enqueued(worker: TransferWorker, args: %{transfer_id: transfer.id})
      end
    end

    test "all of them or none", %{user: user} do
      # The docstring's claim, and the reason it is one transaction: a partial
      # batch leaves some playlists queued and some not, with nothing on screen
      # saying which — the user would have to compare names by hand to find out
      # what to retry. Failing whole is recoverable by pressing the button again.
      members = batch_members(2) ++ [%{source_playlist_id: nil, source_playlist_name: nil}]

      assert {:error, _changeset} = Transfers.create_batch(batch_common(user), members)

      assert Transfers.list(user) == []
      refute_enqueued(worker: TransferWorker)
    end

    test "an empty selection is not an error, and queues nothing", %{user: user} do
      # `{:ok, []}` rather than a refusal: "transfer nothing" is a coherent thing
      # to have asked for, and the caller has a flash for it.
      assert {:ok, []} = Transfers.create_batch(batch_common(user), [])

      refute_enqueued(worker: TransferWorker)
    end
  end

  describe "a first run" do
    test "one user's two reports do not bleed into each other", %{user: user} do
      # `items/2` is scoped by `transfer_id` *and* by the policy on
      # `transfer_items`, and nothing exercised the first until
      # `all_from_this_transfer` went in and no mutation could make it fire: one
      # transfer per user meant dropping the `where` returned the same rows.
      #
      # Two reports for one user is also the ordinary case for anybody using the
      # application twice, which is reason enough on its own.
      provider_state()

      {:ok, first} = Runner.run(transfer_for(user))
      {:ok, second} = Runner.run(transfer_for(user))

      refute first.id == second.id

      assert Enum.all?(Transfers.items(first), &(&1.transfer_id == first.id))
      assert Enum.all?(Transfers.items(second), &(&1.transfer_id == second.id))
      assert length(Transfers.items(first)) == 3
    end

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

      # By title rather than by id: a library source names its tracks with the
      # recording's own uuid, which is the point of `Recording.to_track/1`.
      assert item.source_title == "Song s2"
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

  describe "a playlist bigger than one transfer may move" do
    setup do
      # Safe in this file specifically: it is `async: false`, and ExUnit runs
      # sync tests after every async one has finished. In an async file this is
      # the mutation that cost a day twice — see `CLAUDE.md`.
      previous = Application.get_env(:one_playlist, Transfers, [])
      Application.put_env(:one_playlist, Transfers, Keyword.put(previous, :max_tracks, 2))
      on_exit(fn -> Application.put_env(:one_playlist, Transfers, previous) end)
    end

    test "is refused before a single track is matched", %{user: user} do
      state = provider_state()
      transfer = transfer_for(user)

      assert {:error, %PlaylistTooLarge{} = error} = Runner.run(transfer)
      assert error.context.limit == 2

      assert Agent.get(state, & &1.added) == [],
             "refused before a single track was matched, let alone written"
    end

    test "and Oban is told not to retry it", %{user: user} do
      # Re-reading a playlist twenty times to refuse it twenty times is real
      # rate limit spent on a certainty. The transfer still records as failed,
      # which is what the user sees either way.
      _state = provider_state()
      transfer = transfer_for(user)

      assert {:cancel, %PlaylistTooLarge{}} =
               perform_job(TransferWorker, %{transfer_id: transfer.id})

      assert {:ok, failed} = Transfers.fetch(user, transfer.id)
      assert failed.status == :failed
      assert failed.last_error =~ "more tracks than a single transfer can move"

      assert failed.total_tracks == 0,
             "nothing was counted, because nothing was read past the limit"
    end

    test "a playlist exactly at the limit still runs" do
      # The boundary is the interesting half. Reading `limit + 1` to detect
      # "over" makes an off-by-one here refuse a playlist that fits.
      Application.put_env(:one_playlist, Transfers, max_tracks: 3)

      user = AuthFixtures.user_id_fixture()
      {:ok, _library} = Providers.ensure_library(user)

      {:ok, _connection} =
        Providers.connect(user, :tidal, %{
          provider_user_id: "67373615",
          access_token: "at",
          refresh_token: "rt",
          access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
          scopes: ["playlists.read", "playlists.write", "search.read"],
          country: "US"
        })

      _state = provider_state()
      transfer = transfer_for(user)

      assert {:ok, completed} = Runner.run(transfer)
      assert completed.status == :completed
      assert completed.total_tracks == 3
    end
  end

  describe "a transfer within one service" do
    test "copies the ids straight across, without searching for anything", %{user: user} do
      # The track came from the catalogue it is going to, so its own id is
      # already the answer. Nothing to search, nothing to score.
      state = provider_state()

      # A TIDAL source playlist this time, so source and destination are one
      # service — the case every other test in this file deliberately avoids.
      {:ok, transfer} =
        Transfers.create(%{
          user_id: user,
          source_provider: :tidal,
          source_playlist_id: "same-src",
          destination_provider: :tidal,
          destination_playlist_name: "Copy"
        })

      assert {:ok, completed} = Runner.run(transfer)

      assert completed.matched_count == 3
      assert Agent.get(state, & &1.added) == ~w(s1 s2 s3), "the source ids, verbatim"

      assert Agent.get(state, & &1.searches) == 0,
             "a track already in the destination catalogue must not be searched for"

      rows = Transfers.items(completed)

      assert Enum.all?(rows, &(&1.strategy == "same_service"))
      assert Enum.all?(rows, &(&1.confidence == "same_service"))
    end

    test "a self-hosted provider does not get the shortcut" do
      # The trap this capability exists for. Two Subsonic connections are two
      # *different servers*: both say `:subsonic`, and an id from one names
      # nothing on the other — or something else entirely. Reasoning about "the
      # same service" from the provider name alone would be wrong for every
      # self-hosted provider this application ever adds.
      refute :global_ids in OnePlaylist.Providers.Navidrome.capabilities()
      assert :global_ids in OnePlaylist.Providers.Tidal.capabilities()
      assert :global_ids in OnePlaylist.Providers.Library.capabilities()
    end
  end

  describe "a playlist that holds the same track twice" do
    test "writes it twice, and adds nothing on a second run", %{user: user} do
      # A playlist may legitimately hold one track twice, and the pipeline used
      # to deduplicate by destination id — so the second copy vanished. Counting
      # what the source asks for against what the destination holds answers both
      # halves at once: two written the first time, none the second.
      {:ok, source} = Library.create_playlist(user, "Twice")

      twin = %Track{
        provider: :tidal,
        provider_id: "src-twin",
        title: "Song s1",
        isrc: isrc("s1")
      }

      2 = Library.append(user, source.id, [twin, twin])

      state = provider_state()

      {:ok, first} =
        Runner.run(transfer_for(user, %{source_playlist_id: source.id}))

      assert first.added_count == 2
      assert Agent.get(state, & &1.added) == ~w(ds1 ds1), "both copies, not one"

      {:ok, again} = Runner.run(transfer_for(user, %{source_playlist_id: source.id}))

      assert again.added_count == 0, "a re-run must still add nothing"
      assert Agent.get(state, & &1.added) == ~w(ds1 ds1)
    end

    test "a second copy added later is written, though the first is already there",
         %{user: user} do
      # The partial overlap, and the only shape that tells counting apart from
      # set comparison. Both of the tests around this one are satisfied by
      # either implementation: with an empty destination both write everything,
      # and with a fully-stocked one both write nothing.
      #
      # Here the destination holds *one* and the source asks for *two*. Counting
      # writes the difference; set comparison sees the id present and writes
      # nothing, and the second copy is silently lost with the report calling it
      # matched. Found by mutation — `write_missing/5`'s postcondition could not
      # be made to fire low until this existed.
      {:ok, source} = Library.create_playlist(user, "Grew by one")

      twin = %Track{
        provider: :tidal,
        provider_id: "src-twin",
        title: "Song s1",
        isrc: isrc("s1")
      }

      1 = Library.append(user, source.id, [twin])

      state = provider_state()

      {:ok, first} = Runner.run(transfer_for(user, %{source_playlist_id: source.id}))

      assert first.added_count == 1
      assert Agent.get(state, & &1.added) == ~w(ds1)

      1 = Library.append(user, source.id, [twin])

      {:ok, second} = Runner.run(transfer_for(user, %{source_playlist_id: source.id}))

      assert second.added_count == 1, "the copy the destination is short of"
      assert Agent.get(state, & &1.added) == ~w(ds1 ds1)
    end

    test "two different recordings sharing a title both land", %{user: user} do
      # The case that prompted this. "Hard to Imagine" appears twice in a real
      # playlist — once from Lost Dogs, once from the Chicago Cab soundtrack —
      # and they are two distinct studio recordings.
      {:ok, source} = Library.create_playlist(user, "Two sessions")

      versions =
        for {album, id} <- [{"Lost Dogs", "s1"}, {"Chicago Cab", "s2"}] do
          %Track{
            provider: :tidal,
            provider_id: "src-#{id}",
            title: "Hard to Imagine",
            album: album,
            isrc: isrc(id)
          }
        end

      2 = Library.append(user, source.id, versions)

      state = provider_state()

      {:ok, run} = Runner.run(transfer_for(user, %{source_playlist_id: source.id}))

      assert run.added_count == 2
      assert Agent.get(state, & &1.added) == ~w(ds1 ds2), "two recordings, two writes"
    end
  end

  describe "the identity spine" do
    test "a recording already located at the destination is not searched for again", %{
      user: user
    } do
      # L5's whole claim, and the only test that can show it: recall costs no
      # request at all. `docs/reference/domain.md` §5.
      state = provider_state()
      transfer = transfer_for(user)

      # What an earlier transfer would have learned. Anchored on the same ISRC
      # the fixture gives source track `s1`, and naming an id the source track
      # does not have — a same-service identity that is a real memory rather
      # than the source restating itself.
      recording =
        Identities.anchor(%Track{
          provider: :tidal,
          provider_id: "earlier",
          isrc: isrc("s1"),
          title: "Song s1"
        })

      :ok =
        Identities.record(
          recording,
          %Track{provider: :tidal, provider_id: "remembered", title: "Song s1"},
          :isrc,
          1.0
        )

      {:ok, completed} = Runner.run(transfer)

      assert "remembered" in Agent.get(state, & &1.added),
             "the remembered id should have been written, not one found by searching"

      assert Agent.get(state, & &1.searches) == 2,
             "three tracks, and only the two the spine had never seen were searched for"

      assert completed.matched_count == 3
    end

    test "a transfer teaches the spine where both ends of it live", %{user: user} do
      _state = provider_state()

      {:ok, _completed} = Runner.run(transfer_for(user))

      recording = Identities.anchor(%Track{provider: :tidal, provider_id: "x", isrc: isrc("s1")})

      assert [%{provider: :tidal, provider_id: id}] = Identities.for_recording(recording)

      assert id in ~w(s1 ds1),
             "either end is a true identity at TIDAL; one row per service is the rule"
    end

    test "a text match is not strong enough to become a fact", %{user: user} do
      # The asymmetry the spine turns on: `:high` is good enough to put a track
      # in a playlist, where a person sees the result, and not good enough to
      # assert about the world's music for ever.
      _state = provider_state(rejected: ~w(s2))

      {:ok, _completed} = Runner.run(transfer_for(user))

      recording = Identities.anchor(%Track{provider: :tidal, provider_id: "x", isrc: isrc("s2")})

      refute Enum.any?(Identities.for_recording(recording), &(&1.provider_id == "ws2")),
             "the wrong candidate the text rung saw must not have been remembered"
    end
  end

  describe "correcting a match by hand" do
    setup %{user: user} do
      # One track the engine cannot match, so there is something to correct.
      state = provider_state(rejected: ~w(s2))
      transfer = transfer_for(user)

      {:ok, completed} = Runner.run(transfer)

      assert completed.unmatched_count == 1
      assert [item] = Transfers.items(completed, outcome: :unmatched)

      %{
        state: state,
        transfer: completed,
        item: item,
        session: OnePlaylist.AuthFixtures.session_fixture(user_id: user)
      }
    end

    test "the candidates it rejected are kept, so there is something to choose from", %{
      item: item
    } do
      # The whole point of the feature: an unmatched row that offers nothing is
      # a dead end, and re-searching at review time asks the provider the same
      # question that already failed.
      assert item.candidates != [],
             "an unmatched track should carry what was considered and refused"

      assert [%{"provider_id" => _} | _] = item.candidates
    end

    test "an exact identifier match keeps none, because nobody overrides those", %{
      transfer: transfer
    } do
      matched = Transfers.items(transfer, outcome: :matched)

      assert matched != []

      assert Enum.all?(matched, &(&1.candidates == [])),
             "five candidates per track for a 5,000 track transfer is megabytes nobody opens"
    end

    test "writes the chosen track and moves the counters together", %{
      session: session,
      transfer: transfer,
      item: item,
      state: state
    } do
      chosen = %{"provider_id" => "ds2", "title" => "Song s2", "artist" => "Somebody"}

      assert {:ok, corrected} = Transfers.override(session, transfer, item.position, chosen)

      assert "ds2" in Agent.get(state, & &1.added),
             "a correction that does not reach the destination is a report that lies"

      # Re-read rather than trusting the returned struct. `Repo.update/1` answers
      # with its changeset's data merged with its changes, so a changeset that
      # carried the corrected counters as *data* and none of them as *changes*
      # returns exactly the right numbers and writes none of them. That is not a
      # hypothetical: it is what this did until the LiveView test re-read the
      # row and found the summary unchanged.
      assert {:ok, corrected} = Transfers.fetch(corrected.user_id, corrected.id)

      assert corrected.unmatched_count == transfer.unmatched_count - 1
      assert corrected.matched_count == transfer.matched_count + 1
      assert corrected.added_count == transfer.added_count + 1
      assert corrected.total_tracks == transfer.total_tracks

      # The law `record_run/3` enforces before every write, checked at the one
      # point where no run is involved and so nothing else enforces it: the
      # summary and the report have to describe the same transfer.
      assert Transfer.tally(corrected) ==
               corrected |> Transfers.items() |> OnePlaylist.Transfers.TransferItem.tally(),
             "a correction must leave the counters agreeing with the report"

      assert [%{outcome: :matched} = fixed] =
               Transfers.items(corrected) |> Enum.filter(&(&1.position == item.position))

      assert fixed.destination_track_id == "ds2"
      assert fixed.strategy == "manual"
      assert fixed.confidence == "chosen"
      refute fixed.reason
    end

    test "and the correction survives the next run", %{
      session: session,
      transfer: transfer,
      item: item
    } do
      # The reason overrides are a table rather than a column. `record_run/3`
      # rewrites every report row, so a correction stored on the row it corrects
      # would be silently destroyed here.
      chosen = %{"provider_id" => "ds2", "title" => "Song s2", "artist" => "Somebody"}
      {:ok, corrected} = Transfers.override(session, transfer, item.position, chosen)

      assert {:ok, rerun} = Runner.run(corrected)

      assert [%{} = still_fixed] =
               Transfers.items(rerun) |> Enum.filter(&(&1.position == item.position))

      assert still_fixed.destination_track_id == "ds2"
      assert still_fixed.strategy == "manual"

      assert still_fixed.outcome == :already_present,
             "the track is in the destination now, so a re-run adds nothing"

      assert rerun.unmatched_count == 0
    end

    test "correcting a row that a re-run left already present counts the new write", %{
      session: session,
      transfer: transfer,
      item: item
    } do
      # The subtle ledger case. A re-run turns last run's `:matched` into
      # `:already_present`, which resolves but was not written by *that* run.
      # Correcting it writes one, so `added_count` moves and nothing else does —
      # and `added_at_most_matched` is what catches getting that wrong.
      chosen = %{"provider_id" => "ds2", "title" => "Song s2", "artist" => "Somebody"}
      {:ok, corrected} = Transfers.override(session, transfer, item.position, chosen)
      {:ok, rerun} = Runner.run(corrected)

      assert [%{outcome: :already_present}] =
               Transfers.items(rerun) |> Enum.filter(&(&1.position == item.position))

      before = {rerun.matched_count, rerun.added_count, rerun.unmatched_count}

      other = %{"provider_id" => "ds1", "title" => "Song s1", "artist" => "Somebody"}
      {:ok, again} = Transfers.override(session, rerun, item.position, other)

      {matched, added, unmatched} = before

      assert {again.matched_count, again.added_count, again.unmatched_count} ==
               {matched, added + 1, unmatched},
             "it resolved before and still does; what changed is that this run wrote one"

      assert TransferItem.tally(Transfers.items(again)) == Transfer.tally(again),
             "the report and the counters must still agree"
    end

    test "a correction naming no track is refused", %{
      session: session,
      transfer: transfer,
      item: item
    } do
      assert :error = Transfers.override(session, transfer, item.position, %{"provider_id" => ""})
    end
  end

  describe "transferring into the library" do
    # The inversion `docs/reference/domain.md` §5 describes, exercised through
    # the whole pipeline rather than at the adapter. The library has no
    # catalogue, so a track it does not hold is not a track that cannot be
    # transferred — and an `:unmatched` row is impossible.
    setup %{user: user_id} do
      {:ok, library} = Providers.ensure_library(user_id)

      %{library: library}
    end

    test "a recording the library has never seen is stored, not reported missing", %{
      user: user_id
    } do
      Req.Test.stub(OnePlaylist.Providers.Tidal, fn conn ->
        Req.Test.json(conn, source_document())
      end)

      {:ok, transfer} =
        Transfers.create(%{
          user_id: user_id,
          source_provider: :tidal,
          source_playlist_id: "src",
          destination_provider: :library,
          destination_playlist_name: "From TIDAL",
          threshold: 0.75
        })

      assert {:ok, run} = Runner.run(transfer)

      assert run.total_tracks == 3
      assert run.matched_count == 3
      assert run.added_count == 3

      assert run.unmatched_count == 0,
             "a destination that can hold anything cannot fail to hold a track"

      rows = Transfers.items(run)

      assert Enum.map(rows, & &1.outcome) == [:matched, :matched, :matched]

      assert Enum.map(rows, & &1.strategy) == ~w(stored stored stored),
             "the report has to say nothing was compared, rather than claim a match"

      assert Enum.all?(rows, &(&1.confidence == "stored"))
    end

    test "two different recordings sharing a title are not merged", %{user: user_id} do
      # Found on a real import and it lost data. "Hard to Imagine" appears twice
      # in one playlist — once from Lost Dogs, once from the Chicago Cab
      # soundtrack, two separate studio sessions — and the second matched the
      # first at 0.8950 on the strength of a shared title, was reported
      # `already_present`, and vanished from the playlist entirely.
      #
      # Against a catalogue a wrong match is one visible, correctable row.
      # Against the library it *merges two recordings*: the track stops existing
      # as itself and no split undoes it. So a destination that accepts anything
      # matches at identifier strength, whatever the transfer asked for.
      {:ok, first} =
        Library.create_playlist(user_id, "Two sessions")

      same_title = fn album ->
        %Track{
          provider: :file,
          provider_id: "f-#{System.unique_integer([:positive])}",
          title: "Hard to Imagine",
          artists: ["Pearl Jam"],
          album: album
        }
      end

      Library.append(user_id, first.id, [same_title.("Lost Dogs")])

      {:ok, library} = Providers.fetch_usable_connection(user_id, :library)

      # The second arrival, resolved the way the runner resolves it.
      {:ok, adapter} = Providers.adapter(:library)

      {:ok, candidates} =
        adapter.search_tracks(library, same_title.("Chicago Cab"), [])

      assert candidates != [], "the title search still offers it, which is right"

      assert {:error, _declined} =
               OnePlaylist.Matching.match(same_title.("Chicago Cab"), candidates,
                 threshold: :exact_upc
               ),
             "but nothing below an identifier may conclude they are the same recording"
    end

    test "the destination ids are the library's own, so the write confirms", %{user: user_id} do
      # The reason `accept_track/3` returns a track rather than the runner
      # reusing the source: `confirm_written/5` re-reads the destination and
      # looks for the ids it recorded. A source id would never be there.
      Req.Test.stub(OnePlaylist.Providers.Tidal, fn conn ->
        Req.Test.json(conn, source_document())
      end)

      {:ok, transfer} =
        Transfers.create(%{
          user_id: user_id,
          source_provider: :tidal,
          source_playlist_id: "src",
          destination_provider: :library,
          destination_playlist_name: "From TIDAL",
          threshold: 0.75
        })

      {:ok, run} = Runner.run(transfer)

      held = Library.tracks(user_id, run.destination_playlist_id)

      assert Enum.map(held, & &1.provider) == [:library, :library, :library]

      assert Enum.map(Transfers.items(run), & &1.destination_track_id) |> Enum.sort() ==
               Enum.map(held, & &1.provider_id) |> Enum.sort()
    end

    test "no MusicBrainz request is spent on a destination that will store anything", %{
      user: user_id
    } do
      # The fallbacks in `decide/4` rescue a match against a *catalogue*. A
      # library will hold the track either way, so a request that cannot change
      # the outcome must not be spent on the import path — MusicBrainz allows
      # one a second, and a 153-track import once paid it per track to learn
      # nothing. Identity is enrichment's business.
      Req.Test.stub(OnePlaylist.Providers.Tidal, fn conn ->
        Req.Test.json(conn, source_document())
      end)

      Req.Test.stub(OnePlaylist.MusicBrainz.Service, fn _conn ->
        flunk("a library destination must not reach MusicBrainz during a transfer")
      end)

      {:ok, transfer} =
        Transfers.create(%{
          user_id: user_id,
          source_provider: :tidal,
          source_playlist_id: "src",
          destination_provider: :library,
          destination_playlist_name: "From TIDAL",
          threshold: 0.75
        })

      assert {:ok, run} = Runner.run(transfer)
      assert run.unmatched_count == 0
    end

    test "running it twice deduplicates rather than doubling the library", %{user: user_id} do
      # Both halves at once: the recordings are recognised the second time, and
      # the playlist diff means nothing is appended again.
      Req.Test.stub(OnePlaylist.Providers.Tidal, fn conn ->
        Req.Test.json(conn, source_document())
      end)

      {:ok, transfer} =
        Transfers.create(%{
          user_id: user_id,
          source_provider: :tidal,
          source_playlist_id: "src",
          destination_provider: :library,
          destination_playlist_name: "From TIDAL",
          threshold: 0.75
        })

      {:ok, first} = Runner.run(transfer)
      {:ok, second} = Runner.run(first)

      assert second.added_count == 0, "a re-run writes nothing"
      assert second.matched_count == 3

      assert Enum.map(Transfers.items(second), & &1.outcome) ==
               [:already_present, :already_present, :already_present]

      assert length(Library.tracks(user_id, second.destination_playlist_id)) == 3,
             "and the playlist is not doubled"

      assert Enum.map(Transfers.items(second), & &1.strategy) == ~w(isrc isrc isrc),
             "the second time there is something to match against, so it matches"
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
