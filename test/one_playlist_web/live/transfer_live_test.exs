defmodule OnePlaylistWeb.TransferLiveTest do
  @moduledoc """
  The transfer screens.

  The report view is the one worth testing carefully: `docs/reference/domain.md`
  argues it is the feature that differentiates this product, and a report that
  quietly omitted the unmatched rows would look perfectly healthy.
  """

  use OnePlaylistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OnePlaylist.AuthFixtures
  alias OnePlaylist.Repo
  alias OnePlaylist.Transfers
  alias OnePlaylist.Transfers.Transfer
  alias OnePlaylist.Transfers.TransferItem

  setup %{conn: conn} do
    user_id = AuthFixtures.user_id_fixture()

    %{conn: log_in(conn, user_id), user_id: user_id}
  end

  defp log_in(conn, user_id) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> OnePlaylistWeb.UserAuth.log_in_user(user_id)
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
    test "signed-out visitors are turned away" do
      conn = Phoenix.ConnTest.build_conn()

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/transfers")
    end
  end
end
