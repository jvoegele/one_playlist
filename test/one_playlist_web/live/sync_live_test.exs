defmodule OnePlaylistWeb.SyncLiveTest do
  @moduledoc """
  The syncs page, and the cadence control that creates one.

  Two things are worth testing here and the rest is the domain's:

    * **A cadence turns a transfer into a schedule.** That is the one path from
      the UI into `OnePlaylist.Syncs`, and it is easy to break silently — a
      transfer would still be queued and the user would never learn the sync was
      not made.
    * **Pausing keeps the sync's place.** The button is one line; the promise it
      makes is the reason `set_enabled/3` does not touch `next_run_at`.
  """

  use OnePlaylistWeb.ConnCase, async: false

  import OnePlaylist.AuthFixtures
  import Phoenix.LiveViewTest
  import Req.Test, only: [set_req_test_from_context: 1]

  alias OnePlaylist.Providers
  alias OnePlaylist.Repo
  alias OnePlaylist.Syncs

  setup :set_req_test_from_context

  defp stub_tidal do
    Req.Test.stub(OnePlaylist.Providers.Tidal, fn conn ->
      Req.Test.json(Plug.Conn.fetch_query_params(conn), %{
        "data" => [
          %{
            "type" => "playlists",
            "id" => "tidal-1",
            "attributes" => %{"name" => "Road Trip 2026", "numberOfItems" => 12}
          }
        ],
        "links" => %{}
      })
    end)
  end

  setup %{conn: conn} do
    user_id = user_id_fixture()
    stub_tidal()

    {:ok, _connection} =
      Providers.connect(user_id, :tidal, %{
        provider_user_id: "67373615",
        display_name: "TIDAL",
        access_token: "at",
        refresh_token: "rt",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
        country: "US"
      })

    %{conn: log_in_user(conn, user_id), user_id: user_id}
  end

  defp sync_fixture(user_id, attrs \\ %{}) do
    {:ok, sync} =
      Syncs.create(
        Map.merge(
          %{
            user_id: user_id,
            source_provider: :library,
            source_playlist_id: "src-#{System.unique_integer([:positive])}",
            source_playlist_name: "Road Trip 2026",
            destination_provider: :tidal,
            interval_minutes: 60 * 24
          },
          attrs
        )
      )

    sync
  end

  describe "the list" do
    test "says so when there is nothing", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/syncs")

      assert html =~ "Nothing is being synced yet"
    end

    test "names the playlist, the destination and the cadence", %{conn: conn, user_id: user_id} do
      sync_fixture(user_id)

      {:ok, _view, html} = live(conn, ~p"/syncs")

      assert html =~ "Road Trip 2026"
      assert html =~ "TIDAL"
      assert html =~ "Every day"
      refute html =~ ">tidal<", "the internal atom should never reach the page"
    end

    test "badges a mirroring sync, and only that one", %{conn: conn, user_id: user_id} do
      sync_fixture(user_id, %{mode: :add})

      {:ok, _view, html} = live(conn, ~p"/syncs")
      refute html =~ "Mirror"

      sync_fixture(user_id, %{mode: :replace, source_playlist_name: "Mirrored"})

      {:ok, _view, html} = live(conn, ~p"/syncs")
      assert html =~ "Mirror"
    end

    test "shows nobody else's", %{conn: conn, user_id: user_id} do
      sync_fixture(user_id, %{source_playlist_name: "Mine"})
      sync_fixture(user_id_fixture(), %{source_playlist_name: "Theirs"})

      {:ok, _view, html} = live(conn, ~p"/syncs")

      assert html =~ "Mine"
      refute html =~ "Theirs"
    end
  end

  describe "pausing" do
    test "keeps the sync's place in the schedule", %{conn: conn, user_id: user_id} do
      sync = sync_fixture(user_id)

      {:ok, view, _html} = live(conn, ~p"/syncs")

      html = view |> element("button[phx-click=toggle]") |> render_click()

      assert html =~ "Paused"
      assert html =~ "Resume"

      paused = Repo.get(Syncs.Sync, sync.id)
      refute paused.enabled
      assert paused.next_run_at == sync.next_run_at
    end

    test "resuming turns it back on", %{conn: conn, user_id: user_id} do
      sync = sync_fixture(user_id)
      {:ok, _paused} = Syncs.set_enabled(user_id, sync.id, false)

      {:ok, view, _html} = live(conn, ~p"/syncs")

      html = view |> element("button[phx-click=toggle]") |> render_click()

      refute html =~ "Paused"
      assert Repo.get(Syncs.Sync, sync.id).enabled
    end
  end

  describe "deleting" do
    test "removes the sync and says the transfers survive", %{conn: conn, user_id: user_id} do
      sync = sync_fixture(user_id)

      {:ok, view, _html} = live(conn, ~p"/syncs")

      html = view |> element("button[phx-click=delete]") |> render_click()

      assert html =~ "Nothing is being synced yet"
      assert is_nil(Repo.get(Syncs.Sync, sync.id))
    end
  end

  describe "the cadence control on /transfers/new" do
    test "offers a schedule alongside the one-off transfer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/transfers/new")
      html = render_async(view)

      assert html =~ ~s(id="cadence")
      assert html =~ "Just once"
      assert html =~ "Every week"
    end

    test "the button says what it is about to do", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/transfers/new")
      render_async(view)

      view |> element("button[phx-value-id=tidal-1]") |> render_click()

      assert render(view) =~ "Transfer to"

      html =
        view
        |> element("#cadence-form")
        |> render_change(%{"cadence" => "weekly"})

      assert html =~ "Sync to"
    end

    test "a cadence creates a sync and runs it now", %{conn: conn, user_id: user_id} do
      {:ok, view, _html} = live(conn, ~p"/transfers/new")
      render_async(view)

      view |> element("#cadence-form") |> render_change(%{"cadence" => "daily"})
      view |> element("button[phx-value-id=tidal-1]") |> render_click()
      view |> element("button[phx-click=transfer]") |> render_click()

      assert [sync] = Syncs.list(user_id)
      assert sync.interval_minutes == 60 * 24
      assert sync.source_playlist_id == "tidal-1"
      refute is_nil(sync.last_transfer_id), "the first run should have happened immediately"
    end

    # Mirroring is only offered once a cadence is chosen: a one-off transfer
    # has no later run to remove anything on.
    test "the mirror option appears only with a cadence", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/transfers/new")
      render_async(view)

      refute render(view) =~ "Mirror the source"

      html = view |> element("#cadence-form") |> render_change(%{"cadence" => "weekly"})

      assert html =~ "Mirror the source"
    end

    test "a mirrored sync is created in replace mode", %{conn: conn, user_id: user_id} do
      {:ok, view, _html} = live(conn, ~p"/transfers/new")
      render_async(view)

      view |> element("#cadence-form") |> render_change(%{"cadence" => "weekly"})
      view |> element("#mode-form") |> render_change(%{"mirror" => "true"})
      view |> element("button[phx-value-id=tidal-1]") |> render_click()
      view |> element("button[phx-click=transfer]") |> render_click()

      assert [sync] = Syncs.list(user_id)
      assert sync.mode == :replace
    end

    test "without the mirror box a sync only ever adds", %{conn: conn, user_id: user_id} do
      {:ok, view, _html} = live(conn, ~p"/transfers/new")
      render_async(view)

      view |> element("#cadence-form") |> render_change(%{"cadence" => "weekly"})
      view |> element("button[phx-value-id=tidal-1]") |> render_click()
      view |> element("button[phx-click=transfer]") |> render_click()

      assert [sync] = Syncs.list(user_id)
      assert sync.mode == :add
    end

    # Dropping back to a one-off must not leave a destructive setting armed,
    # ready to apply the next time a cadence is picked.
    test "going back to just once disarms mirroring", %{conn: conn, user_id: user_id} do
      {:ok, view, _html} = live(conn, ~p"/transfers/new")
      render_async(view)

      view |> element("#cadence-form") |> render_change(%{"cadence" => "weekly"})
      view |> element("#mode-form") |> render_change(%{"mirror" => "true"})
      view |> element("#cadence-form") |> render_change(%{"cadence" => "once"})
      view |> element("#cadence-form") |> render_change(%{"cadence" => "daily"})

      view |> element("button[phx-value-id=tidal-1]") |> render_click()
      view |> element("button[phx-click=transfer]") |> render_click()

      assert [sync] = Syncs.list(user_id)
      assert sync.mode == :add
    end

    # The default must stay `:once`. A user who never touches the control is
    # asking for a transfer, and silently scheduling one would be the worst
    # possible default for a feature that spends provider quota forever.
    test "no cadence means no sync", %{conn: conn, user_id: user_id} do
      {:ok, view, _html} = live(conn, ~p"/transfers/new")
      render_async(view)

      view |> element("button[phx-value-id=tidal-1]") |> render_click()
      view |> element("button[phx-click=transfer]") |> render_click()

      assert Syncs.list(user_id) == []
    end
  end
end
