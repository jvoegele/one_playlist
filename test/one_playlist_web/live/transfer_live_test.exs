defmodule OnePlaylistWeb.TransferLiveTest do
  @moduledoc """
  The transfer screens.

  The report view is the one worth testing carefully: `docs/reference/domain.md`
  argues it is the feature that differentiates this product, and a report that
  quietly omitted the unmatched rows would look perfectly healthy.
  """

  use OnePlaylistWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Req.Test, only: [set_req_test_from_context: 1]

  alias OnePlaylist.AuthFixtures
  alias OnePlaylist.Repo
  alias OnePlaylist.Transfers
  alias OnePlaylist.Transfers.Progress
  alias OnePlaylist.Transfers.Transfer
  alias OnePlaylist.Transfers.TransferItem

  setup :set_req_test_from_context

  setup %{conn: conn} do
    user_id = AuthFixtures.user_id_fixture()

    %{conn: log_in_user(conn, user_id), user_id: user_id}
  end

  defp transfer_fixture(user_id, attrs \\ %{}) do
    {:ok, transfer} =
      %Transfer{}
      |> Transfer.create_changeset(
        Map.merge(
          %{
            user_id: user_id,
            source_provider: :tidal,
            source_playlist_id: "src",
            source_playlist_name: "Road Trip",
            destination_provider: :tidal,
            threshold: 0.75
          },
          attrs
        )
      )
      |> Repo.insert()

    transfer
  end

  defp item_fixture(transfer, attrs) do
    %TransferItem{}
    |> TransferItem.changeset(
      Map.merge(
        %{
          transfer_id: transfer.id,
          user_id: transfer.user_id,
          position: 0,
          source_track_id: "s1",
          source_title: "Song",
          outcome: :matched
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp complete(transfer, counts) do
    {:ok, transfer} =
      Transfers.record_progress(transfer, Map.merge(%{status: :completed}, counts))

    transfer
  end

  describe "index" do
    test "says so plainly when there is nothing", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/transfers")

      assert html =~ "No transfers yet"
    end

    test "lists a transfer", %{conn: conn, user_id: user_id} do
      transfer_fixture(user_id)

      {:ok, _live, html} = live(conn, ~p"/transfers")

      assert html =~ "Road Trip"
    end

    test "does not show another user's transfers", %{conn: conn} do
      transfer_fixture(AuthFixtures.user_id_fixture(), %{source_playlist_name: "Not Yours"})

      {:ok, _live, html} = live(conn, ~p"/transfers")

      refute html =~ "Not Yours"
    end
  end

  describe "show" do
    test "renders the counters and the per-track report", %{conn: conn, user_id: user_id} do
      transfer =
        user_id
        |> transfer_fixture()
        |> complete(%{total_tracks: 2, matched_count: 1, added_count: 1, unmatched_count: 1})

      item_fixture(transfer, %{
        position: 0,
        source_title: "Found It",
        outcome: :matched,
        strategy: "isrc",
        confidence: "exact_isrc"
      })

      item_fixture(transfer, %{
        position: 1,
        source_track_id: "s2",
        source_title: "Lost It",
        outcome: :unmatched,
        reason: "no_candidates"
      })

      {:ok, _live, html} = live(conn, ~p"/transfers/#{transfer.id}")

      assert html =~ "Found It"
      assert html =~ "Lost It"
      assert html =~ "exact_isrc"

      assert html =~ "nothing found on the destination",
             "an unmatched track must say why, in words a person can act on"
    end

    test "filters to the unmatched rows", %{conn: conn, user_id: user_id} do
      transfer =
        user_id
        |> transfer_fixture()
        |> complete(%{total_tracks: 2, matched_count: 1, unmatched_count: 1})

      item_fixture(transfer, %{position: 0, source_title: "Found It", outcome: :matched})

      item_fixture(transfer, %{
        position: 1,
        source_track_id: "s2",
        source_title: "Lost It",
        outcome: :unmatched,
        reason: "all_rejected",
        candidates_considered: 3
      })

      {:ok, live, _html} = live(conn, ~p"/transfers/#{transfer.id}")

      html = live |> element("button", "Unmatched") |> render_click()

      assert html =~ "Lost It"
      assert html =~ "3 found, each a different recording"
      refute html =~ "Found It"
    end

    test "updates live when the transfer progresses", %{conn: conn, user_id: user_id} do
      # The reason progress is broadcast rather than polled: the run happens in
      # an Oban worker, in a process this LiveView never sees.
      transfer = transfer_fixture(user_id)

      {:ok, live, html} = live(conn, ~p"/transfers/#{transfer.id}")
      assert html =~ "pending"

      complete(transfer, %{total_tracks: 5, matched_count: 5, added_count: 5})

      assert render(live) =~ "completed"
    end

    test "a failure is shown rather than swallowed", %{conn: conn, user_id: user_id} do
      transfer = transfer_fixture(user_id)

      {:ok, _failed} =
        Transfers.record_progress(transfer, %{
          status: :failed,
          last_error: "your TIDAL connection has expired"
        })

      {:ok, _live, html} = live(conn, ~p"/transfers/#{transfer.id}")

      assert html =~ "failed"
      assert html =~ "your TIDAL connection has expired"
    end

    test "a transfer that does not exist redirects rather than crashing", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/transfers"}}} =
               live(conn, ~p"/transfers/#{Ecto.UUID.generate()}")
    end
  end

  describe "authentication" do
    test "signed-out visitors are sent to sign in" do
      conn = Phoenix.ConnTest.build_conn()

      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/transfers")
    end
  end

  # `create_changeset/2` does not cast `status`, deliberately: a transfer is
  # created pending and the pipeline moves it. `progress_changeset/2` is what
  # the runner uses, so it is what a test should use too.
  defp with_status(transfer, status) do
    {:ok, updated} = OnePlaylist.Transfers.record_progress(transfer, %{status: status})
    updated
  end

  describe "correcting a match by hand" do
    # The candidates are stored on the report row, so this needs no provider
    # stub to render — which is the point of storing them.
    defp report_with_alternatives(user_id, attrs \\ %{}) do
      transfer = transfer_fixture(user_id, attrs)

      candidates = [
        %{
          "provider_id" => "d-live",
          "title" => "Corduroy (Live)",
          "artist" => "Pearl Jam",
          "album" => "Live On Two Legs",
          "artwork_url" => "https://resources.tidal.com/images/aaa/160x160.jpg",
          "score" => 0.94,
          "confidence" => "high",
          "strategy" => "text",
          "version_conflict" => true,
          "duration_conflict" => false,
          "editorial_conflict" => false,
          "duration_delta_seconds" => 41
        },
        %{
          "provider_id" => "d-studio",
          "title" => "Corduroy",
          "artist" => "Pearl Jam",
          "album" => "Vitalogy",
          "artwork_url" => "https://resources.tidal.com/images/bbb/160x160.jpg",
          "score" => 0.71,
          "confidence" => "low",
          "strategy" => "text",
          "version_conflict" => false,
          "duration_conflict" => false,
          "editorial_conflict" => false,
          "duration_delta_seconds" => 1
        }
      ]

      items = [
        %{
          transfer_id: transfer.id,
          user_id: user_id,
          source_track_id: "s0",
          position: 0,
          source_title: "Corduroy",
          source_artist: "Pearl Jam",
          outcome: :unmatched,
          destination_track_id: nil,
          confidence: nil,
          score: nil,
          strategy: nil,
          reason: "below_threshold",
          candidates: candidates
        }
      ]

      counted = %{
        transfer
        | total_tracks: 1,
          matched_count: 0,
          added_count: 0,
          unmatched_count: 1
      }

      {:ok, finished} = Transfers.record_run(transfer, counted, items)
      {:ok, finished} = Transfers.record_progress(finished, %{status: :completed})
      finished
    end

    test "an unmatched row offers what was rejected, and why", %{conn: conn, user_id: user_id} do
      transfer = report_with_alternatives(user_id)

      {:ok, view, html} = live(conn, ~p"/transfers/#{transfer.id}")

      refute html =~ "Corduroy (Live)", "the alternatives should be behind a click"
      assert html =~ "Fix this"

      html = view |> element("button[phx-value-position='0']", "Fix this") |> render_click()

      assert html =~ "Corduroy (Live)"
      assert html =~ "Vitalogy"

      # The reason is the whole value of showing them. A list of rejected tracks
      # with no explanation reads as though the engine were simply broken.
      assert html =~ "a different version", "the veto outranks the score and is reported first"
      assert html =~ "scored 0.71"

      # An album title is the title of a work, so it is set in italics wherever
      # it appears — the candidate list included.
      assert html =~ "<em>Vitalogy</em>"
      assert html =~ "<em>Live On Two Legs</em>"
    end

    test "an album title is italicised on the row as well as in the list", %{
      conn: conn,
      user_id: user_id
    } do
      transfer = report_fixture(user_id, 1)

      {:ok, _view, html} = live(conn, ~p"/transfers/#{transfer.id}")

      assert html =~ "<em>An Album</em>", "the source album"
      assert html =~ "<em>A Destination Album</em>", "and the album it matched to"
    end

    test "a row that matched exactly offers nothing, because there is nothing to decide", %{
      conn: conn,
      user_id: user_id
    } do
      transfer = report_fixture(user_id, 3)

      {:ok, _view, html} = live(conn, ~p"/transfers/#{transfer.id}")

      refute html =~ "Fix this"
    end

    test "choosing one adds it, and the report says a person decided", %{
      conn: conn,
      user_id: user_id
    } do
      {:ok, _connection} =
        OnePlaylist.Providers.connect(user_id, :tidal, %{
          provider_user_id: "67373615",
          access_token: "at",
          refresh_token: "rt",
          access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
          country: "US"
        })

      added = start_supervised!({Agent, fn -> [] end})

      Req.Test.stub(OnePlaylist.Providers.Tidal, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Agent.update(added, &[body | &1])

        Req.Test.json(conn, %{})
      end)

      transfer = report_with_alternatives(user_id)

      {:ok, transfer} =
        Transfers.record_progress(transfer, %{destination_playlist_id: "dest-1"})

      conn = log_in_user(conn, AuthFixtures.session_fixture(user_id: user_id))
      {:ok, view, _html} = live(conn, ~p"/transfers/#{transfer.id}")

      _ = view |> element("button[phx-value-position='0']", "Fix this") |> render_click()

      html =
        view
        |> element("button[phx-value-candidate='1']")
        |> render_click()

      assert Agent.get(added, & &1) != [], "the chosen track has to reach the destination"
      assert hd(Agent.get(added, & &1)) =~ "d-studio"

      assert html =~ "Added Corduroy"

      # The counters move together, and the row now says who decided.
      assert html =~ "manual"

      assert [%{outcome: :matched} = fixed] = Transfers.items(transfer)
      assert fixed.destination_track_id == "d-studio"
      assert fixed.strategy == "manual"

      assert {:ok, updated} = Transfers.fetch(user_id, transfer.id)
      assert updated.unmatched_count == 0
      assert updated.matched_count == 1
      assert updated.added_count == 1
    end

    test "a cover is shown where the service publishes one", %{conn: conn, user_id: user_id} do
      transfer = report_with_alternatives(user_id)

      {:ok, view, html} = live(conn, ~p"/transfers/#{transfer.id}")

      # TIDAL declares :artwork, so a row with no cover gets a placeholder
      # rather than nothing — a blank square there means "this track has none",
      # which is information.
      assert html =~ "bg-base-300"

      html = view |> element("button[phx-value-position='0']", "Fix this") |> render_click()

      assert html =~ "resources.tidal.com", "the candidate's cover"
      assert html =~ ~s(loading="lazy"), "a hundred-row report must not fetch a hundred images"
    end

    test "and no space is reserved for one where the service has none", %{
      conn: conn,
      user_id: user_id
    } do
      # Navidrome's cover endpoint wants credentials on the request, so it
      # honestly has no artwork this application can use. A column of grey
      # squares down the report would say nothing at all.
      transfer =
        report_with_alternatives(user_id, %{
          source_provider: :navidrome,
          destination_provider: :navidrome
        })

      {:ok, _view, html} = live(conn, ~p"/transfers/#{transfer.id}")

      refute html =~ ~s(class="w-10 h-10 rounded shrink-0 bg-base-300"),
             "no placeholder where the service publishes no covers"
    end

    test "a row that already matched offers no correction, because the wrong track stays", %{
      conn: conn,
      user_id: user_id
    } do
      # There is no `remove_tracks/4` on the adapter, so adding the right track
      # to a row that already matched would leave both in the playlist. Checked
      # server-side rather than only by hiding the button.
      transfer = report_with_alternatives(user_id)

      [item] = Transfers.items(transfer)

      {1, _} =
        OnePlaylist.Repo.update_all(
          from(i in OnePlaylist.Transfers.TransferItem, where: i.id == ^item.id),
          set: [outcome: :matched, destination_track_id: "d-live"]
        )

      {:ok, view, html} = live(conn, ~p"/transfers/#{transfer.id}")

      refute html =~ "Fix this"

      html = render_hook(view, "choose", %{"position" => "0", "candidate" => "1"})

      assert html =~ "no longer among the alternatives"

      assert [%{destination_track_id: "d-live"}] = Transfers.items(transfer),
             "the row must be untouched"
    end

    test "a forged candidate index cannot add an arbitrary track", %{conn: conn, user_id: user_id} do
      # The index arrives from the browser. The row's own candidate list is the
      # authority on what may be chosen, so an index outside it must resolve to
      # nothing rather than to something.
      transfer = report_with_alternatives(user_id)

      {:ok, view, _html} = live(conn, ~p"/transfers/#{transfer.id}")
      _ = view |> element("button[phx-value-position='0']", "Fix this") |> render_click()

      html = render_hook(view, "choose", %{"position" => "0", "candidate" => "99"})

      assert html =~ "no longer among the alternatives"
    end
  end

  describe "a report too big for one page" do
    # 5,000 track playlists are the case this exists for; 150 is enough to cross
    # the boundary without making the test slow.
    @page_size 100

    defp report_fixture(user_id, count) do
      transfer = transfer_fixture(user_id)

      items =
        for position <- 0..(count - 1) do
          %{
            transfer_id: transfer.id,
            user_id: user_id,
            source_track_id: "s#{position}",
            position: position,
            source_title: "Track #{position}",
            source_artist: "Somebody",
            source_album: "An Album",
            outcome: :matched,
            destination_track_id: "d#{position}",
            destination_title: "Track #{position}",
            destination_artist: "Somebody",
            destination_album: "A Destination Album",
            confidence: "exact",
            score: 1.0,
            strategy: "isrc",
            reason: nil
          }
        end

      counted = %{
        transfer
        | total_tracks: count,
          matched_count: count,
          added_count: count,
          unmatched_count: 0
      }

      {:ok, finished} = Transfers.record_run(transfer, counted, items)
      {:ok, finished} = Transfers.record_progress(finished, %{status: :completed})
      finished
    end

    # The tbody is `id="items"`, which does not carry the hyphen, so this counts
    # report rows and not the container.
    defp row_count(html), do: length(String.split(html, ~s(id="item-))) - 1

    test "shows one page and offers the rest", %{conn: conn, user_id: user_id} do
      transfer = report_fixture(user_id, 150)

      {:ok, view, html} = live(conn, ~p"/transfers/#{transfer.id}")

      assert row_count(html) == @page_size,
             "the whole report in the initial payload is what this change exists to stop"

      assert html =~ "Showing 100 of 150"
      assert html =~ "Load more"

      html = view |> element("button", "Load more") |> render_click()

      assert row_count(html) == 150, "the rest should append, not replace"
      refute html =~ "Load more", "there is nothing left to ask for"
    end

    test "a report that fits on one page offers nothing", %{conn: conn, user_id: user_id} do
      transfer = report_fixture(user_id, 20)

      {:ok, _view, html} = live(conn, ~p"/transfers/#{transfer.id}")

      assert row_count(html) == 20
      refute html =~ "Load more"
    end

    test "changing the filter starts again at the top", %{conn: conn, user_id: user_id} do
      transfer = report_fixture(user_id, 150)

      {:ok, view, _html} = live(conn, ~p"/transfers/#{transfer.id}")
      _ = view |> element("button", "Load more") |> render_click()

      # Every row is `:matched`, so this filter holds the same 150 rows. If the
      # offset carried over from the previous filter, the first page would start
      # at row 100 instead of row 0.
      html = view |> element("button[phx-value-outcome='matched']") |> render_click()

      assert row_count(html) == @page_size
      assert html =~ "Track 0"
      refute html =~ "Track 149"
    end
  end

  # The state a real run's `Progress` would be in after resolving these, so a
  # test asserting on the tab counts is asserting on the numbers the Runner
  # would actually send rather than on numbers the test made up. The batch and
  # interval are set high enough that nothing flushes: what is broadcast is
  # chosen by the caller, not by the batching rules, which have their own tests.
  defp tallied(items, total) do
    Enum.reduce(
      items,
      Progress.new(total, batch: 1_000_000, interval: 1_000_000, now: 0),
      fn item, progress ->
        {[], progress} = Progress.add(progress, item, 0)
        progress
      end
    )
  end

  # Fills in every field a report row is drawn by, so the literal maps below can
  # name only what each test is about. The *real* shape is guaranteed by
  # `Runner.provisional_item/3`'s `shaped_like_a_report_row` postcondition, not
  # by these fixtures — which is the right place for it, since a fixture that
  # kept itself correct would not have caught anything.
  defp report(transfer, items, total) do
    blank = Map.new(TransferItem.display_fields(), &{&1, nil})
    items = Enum.map(items, &Map.merge(blank, &1))

    Transfers.report_progress(transfer, tallied(items, total), items)
  end

  # Every field the report row is drawn by, matching what
  # `Runner.provisional_item/3` really sends. Built from
  # `TransferItem.display_fields/0` so a new column cannot leave this fixture
  # passing while the real thing crashes.
  defp matched_item(position, title \\ nil) do
    defaults = Map.new(TransferItem.display_fields(), &{&1, nil})

    Map.merge(defaults, %{
      position: position,
      source_track_id: "s#{position}",
      source_title: title || "Track #{position}",
      source_artist: "Somebody",
      source_album: "An Album",
      outcome: :matched,
      destination_track_id: "d#{position}",
      destination_title: title || "Track #{position}",
      destination_artist: "Somebody",
      confidence: "exact",
      score: 1.0,
      strategy: "isrc",
      candidates: [],
      reason: nil
    })
  end

  describe "progress" do
    test "a running transfer shows a bar that moves", %{conn: conn, user_id: user_id} do
      # Before this the page said only "running" for the whole matching pass,
      # which for a 58 track import is a minute or more of no information.
      transfer = user_id |> transfer_fixture() |> with_status(:running)

      {:ok, view, html} = live(conn, ~p"/transfers/#{transfer.id}")

      assert html =~ "Starting…", "no report yet reads as starting, not as zero of zero"

      Transfers.report_progress(transfer, tallied(Enum.map(0..22, &matched_item/1), 58), [])

      html = render(view)

      assert html =~ "Matching track 23 of 58"
      assert html =~ "40%"
    end

    test "rows appear as their tracks resolve", %{conn: conn, user_id: user_id} do
      # The point: without this, a 58 track import shows an empty table for the
      # whole matching pass and then every row at once.
      transfer = user_id |> transfer_fixture() |> with_status(:running)

      {:ok, view, _html} = live(conn, ~p"/transfers/#{transfer.id}")

      report(
        transfer,
        [
          %{
            position: 0,
            source_title: "Corduroy",
            source_artist: "Pearl Jam",
            outcome: :matched,
            destination_track_id: "t1",
            confidence: "exact_isrc",
            score: 1.0,
            strategy: "isrc",
            reason: nil
          }
        ],
        2
      )

      html = render(view)

      assert html =~ "Corduroy"
      assert html =~ "Pearl Jam"
    end

    test "a provisional row is replaced, not duplicated", %{conn: conn, user_id: user_id} do
      # Both are keyed on the track's position in the source playlist, so the
      # persisted report lands on the same DOM element the live row created.
      transfer = user_id |> transfer_fixture() |> with_status(:running)

      {:ok, view, _html} = live(conn, ~p"/transfers/#{transfer.id}")

      for _ <- 1..3 do
        report(
          transfer,
          [
            %{
              position: 0,
              source_title: "Corduroy",
              source_artist: "Pearl Jam",
              outcome: :matched,
              destination_track_id: "t1",
              confidence: "exact_isrc",
              score: 1.0,
              strategy: "isrc",
              reason: nil
            }
          ],
          1
        )
      end

      html = render(view)

      assert html |> String.split("Corduroy") |> length() == 2, "one row, not three"
    end

    test "the persisted report replaces the live rows rather than joining them", %{
      conn: conn,
      user_id: user_id
    } do
      transfer = user_id |> transfer_fixture() |> with_status(:running)

      {:ok, view, _html} = live(conn, ~p"/transfers/#{transfer.id}")

      # What a run reports as it goes. `provisional_item/3` says `:matched` for
      # anything that resolved, because whether the track was already in the
      # destination is not known until every track has resolved.
      report(
        transfer,
        [
          %{
            position: 0,
            source_title: "Corduroy",
            source_artist: "Pearl Jam",
            outcome: :matched,
            destination_track_id: "t1",
            confidence: "exact",
            score: 1.0,
            strategy: "isrc",
            reason: nil
          }
        ],
        1
      )

      assert render(view) =~ "Corduroy"

      # And what the run turns out to have found: it was there already.
      counted = %{
        transfer
        | total_tracks: 1,
          matched_count: 1,
          added_count: 0,
          unmatched_count: 0
      }

      {:ok, finished} =
        OnePlaylist.Transfers.record_run(transfer, counted, [
          %{
            transfer_id: transfer.id,
            user_id: user_id,
            source_track_id: "s1",
            position: 0,
            source_title: "Corduroy",
            source_artist: "Pearl Jam",
            outcome: :already_present,
            destination_track_id: "t1",
            confidence: "exact",
            score: 1.0,
            strategy: "isrc",
            reason: nil
          }
        ])

      {:ok, finished} = OnePlaylist.Transfers.record_progress(finished, %{status: :completed})
      send(view.pid, {:transfer_updated, finished})

      html = render(view)

      # Both rows are keyed on the position, so a report that joined the
      # provisional row instead of replacing it shows the track twice.
      assert length(String.split(html, ~s(id="item-0"))) == 2,
             "the report should replace the provisional row, not sit beside it"

      # The filter the real row belongs to, which the provisional one did not.
      _ = view |> element("button[phx-value-outcome='matched']") |> render_click()
      refute render(view) =~ "Corduroy", "a stale provisional row would still be here"
    end

    test "the tabs count what the run has found, not what it has persisted", %{
      conn: conn,
      user_id: user_id
    } do
      # The counters on the transfer row are written once, at the end. Reading
      # the tabs from them meant "All 0 / Unmatched 0 / Added 0" sitting above a
      # progress bar that said 3 of 10.
      transfer = user_id |> transfer_fixture() |> with_status(:running)

      {:ok, view, _html} = live(conn, ~p"/transfers/#{transfer.id}")

      resolved = [
        matched_item(0),
        matched_item(1),
        %{matched_item(2) | outcome: :unmatched, reason: "no_candidates"}
      ]

      report(transfer, resolved, 10)

      html = render(view)

      assert html =~ "All 10", "the tab should count the playlist, not the empty report"
      assert html =~ "Matched 2"
      assert html =~ "Unmatched 1"

      # "Added" would be a lie while a run is matching: nothing has been written
      # to the destination yet, and some of these may turn out to be there
      # already.
      refute html =~ "Added", "nothing has been added yet"
    end

    test "a finished report counts what was already at the destination", %{
      conn: conn,
      user_id: user_id
    } do
      transfer = transfer_fixture(user_id)

      items = [
        %{
          transfer_id: transfer.id,
          user_id: user_id,
          source_track_id: "s0",
          position: 0,
          source_title: "Written",
          source_artist: "Somebody",
          outcome: :matched,
          destination_track_id: "d0",
          confidence: "exact",
          score: 1.0,
          strategy: "isrc",
          reason: nil
        },
        %{
          transfer_id: transfer.id,
          user_id: user_id,
          source_track_id: "s1",
          position: 1,
          source_title: "Skipped",
          source_artist: "Somebody",
          outcome: :already_present,
          destination_track_id: "d1",
          confidence: "exact",
          score: 1.0,
          strategy: "isrc",
          reason: nil
        }
      ]

      counted = %{
        transfer
        | total_tracks: 2,
          matched_count: 2,
          added_count: 1,
          unmatched_count: 0
      }

      {:ok, finished} = Transfers.record_run(transfer, counted, items)
      {:ok, finished} = Transfers.record_progress(finished, %{status: :completed})

      {:ok, _view, html} = live(conn, ~p"/transfers/#{finished.id}")

      assert html =~ "All 2"
      assert html =~ "Added 1"

      # `matched - added`, which is the only place this number exists: there is
      # no `already_present_count` column, because it is derivable.
      assert html =~ "Already there 1", "the tab carried no number at all before"
    end

    test "a long run does not grow the page without bound", %{conn: conn, user_id: user_id} do
      transfer = user_id |> transfer_fixture() |> with_status(:running)

      {:ok, view, _html} = live(conn, ~p"/transfers/#{transfer.id}")

      # 150 tracks resolving, delivered the way `Progress` delivers them. This
      # is the shape of the 5,000 track case, at a size a test can afford.
      # Delivered the way `Progress` delivers them, with the tallies carrying
      # everything resolved so far rather than restarting at each batch.
      for batch <- Enum.chunk_every(0..149, 25) do
        resolved_so_far = Enum.map(0..List.last(batch), &matched_item/1)
        items = Enum.map(batch, &matched_item/1)

        Transfers.report_progress(transfer, tallied(resolved_so_far, 150), items)
      end

      html = render(view)

      # The window keeps the newest rows and drops the oldest, which is the
      # right end to keep: a run in flight is watched at its leading edge.
      assert length(String.split(html, ~s(id="item-))) - 1 <= 100,
             "an unwindowed run puts every resolved row in the DOM and keeps it there"

      assert html =~ "Track 149", "the newest row must be present"
      refute html =~ ~s(>Track 0<), "the oldest should have been dropped"

      # And the server side of the same bound: this map is held by the LiveView
      # process for the whole run, so its growth is a memory leak in everything
      # but name. Reaching into the socket is the only way to see it.
      assigns = :sys.get_state(view.pid).socket.assigns

      assert map_size(assigns.provisional) <= 100
      assert assigns.progress == %{resolved: 150, total: 150, matched: 150, unmatched: 0}
    end

    test "a live row respects the filter", %{conn: conn, user_id: user_id} do
      # Watching "unmatched" during a run should show the failures, not
      # everything that happens to resolve.
      transfer = user_id |> transfer_fixture() |> with_status(:running)

      {:ok, view, _html} = live(conn, ~p"/transfers/#{transfer.id}")

      # A first result, so the table and its tabs exist. Before anything has
      # resolved there is nothing to filter, and the tabs are correctly absent.
      report(
        transfer,
        [
          %{
            position: 0,
            source_title: "A Miss",
            source_artist: "Somebody",
            outcome: :unmatched,
            destination_track_id: nil,
            confidence: nil,
            score: nil,
            strategy: nil,
            reason: "no_match"
          }
        ],
        3
      )

      _ = view |> element("button[phx-value-outcome='unmatched']") |> render_click()

      report(
        transfer,
        [
          %{
            position: 1,
            source_title: "A Match",
            source_artist: "Somebody",
            outcome: :matched,
            destination_track_id: "t1",
            confidence: "high",
            score: 0.9,
            strategy: "text",
            reason: nil
          }
        ],
        3
      )

      html = render(view)

      assert html =~ "A Miss", "the failures are what this filter is for"
      refute html =~ "A Match"
    end

    test "a finished transfer shows counters instead", %{conn: conn, user_id: user_id} do
      # A full bar says less than "54 matched, 4 not found" does.
      transfer = user_id |> transfer_fixture() |> with_status(:completed)

      {:ok, _view, html} = live(conn, ~p"/transfers/#{transfer.id}")

      refute html =~ "Matching track"
      refute html =~ "Starting…"
    end
  end

  describe "provider names" do
    test "are the names the services use for themselves", %{conn: conn, user_id: user_id} do
      # Not "file → tidal".
      transfer =
        transfer_fixture(user_id, %{source_provider: :file, destination_provider: :tidal})

      {:ok, _view, html} = live(conn, ~p"/transfers/#{transfer.id}")

      assert html =~ "File → TIDAL"
    end
  end

  describe "deleting" do
    test "removes the transfer and sends the user back to the list", %{
      conn: conn,
      user_id: user_id
    } do
      transfer = transfer_fixture(user_id, %{source_playlist_name: "Road Trip"})

      {:ok, view, _html} = live(conn, ~p"/transfers/#{transfer.id}")

      assert {:error, {:live_redirect, %{to: "/transfers"}}} =
               view |> element("button[phx-click='delete']") |> render_click()

      assert OnePlaylist.Transfers.fetch(user_id, transfer.id) == :error
    end

    test "asks first", %{conn: conn, user_id: user_id} do
      # A transfer takes provider calls to rebuild and its report is not
      # reproducible, so the one irreversible action on the page should cost a
      # deliberate click.
      transfer = transfer_fixture(user_id)

      {:ok, _view, html} = live(conn, ~p"/transfers/#{transfer.id}")

      assert html =~ "data-confirm"
    end
  end

  describe "authorisation" do
    # These are about a *signed-in* user reaching something that is not theirs,
    # which is a different question from being signed in at all — and the one
    # this application got wrong. Ecto connects as `postgres`, which holds
    # BYPASSRLS, so the `auth.uid()` policies in the migrations do not catch a
    # query that forgets to scope. Nothing does, except a test like this.

    test "a transfer belonging to somebody else is not readable", %{conn: conn} do
      # The regression. `TransferLive.Show.mount/3` used to fetch by id alone
      # and render whatever came back, so any signed-in user could read any
      # transfer at /transfers/<uuid> — playlist name, providers, status, and
      # the whole per-track report. Confirmed against the running application
      # before it was fixed, not hypothesised.
      victim = AuthFixtures.user_id_fixture()
      theirs = transfer_fixture(victim, %{source_playlist_name: "Victim's private playlist"})

      attacker = AuthFixtures.user_id_fixture()
      conn = log_in_user(conn, attacker)

      assert {:error, {:live_redirect, %{to: "/transfers"}}} =
               live(conn, ~p"/transfers/#{theirs.id}")
    end

    test "somebody else's transfer is indistinguishable from one that does not exist", %{
      conn: conn
    } do
      # Answering differently would confirm that an id names a real transfer,
      # which is the only thing an attacker needs to learn from this endpoint.
      victim = AuthFixtures.user_id_fixture()
      theirs = transfer_fixture(victim)

      conn = log_in_user(conn, AuthFixtures.user_id_fixture())

      real = live(conn, ~p"/transfers/#{theirs.id}")
      imaginary = live(conn, ~p"/transfers/#{Ecto.UUID.generate()}")

      assert real == imaginary
    end

    test "a user can still read their own transfer", %{conn: conn, user_id: user_id} do
      # The other half: a veto that also blocks the legitimate case is not a fix.
      mine = transfer_fixture(user_id, %{source_playlist_name: "My playlist"})

      {:ok, _view, html} = live(conn, ~p"/transfers/#{mine.id}")

      assert html =~ "My playlist"
    end
  end
end
