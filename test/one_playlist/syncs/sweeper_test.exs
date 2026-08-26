defmodule OnePlaylist.Syncs.SweeperTest do
  @moduledoc """
  The sweeper, driven directly.

  It has one job and two ways to get it wrong: run something that is not due,
  or stop at the first sync that fails. Both are tested here; the rest of what
  happens after a sync is queued belongs to `OnePlaylist.SyncsTest` and the
  transfer pipeline.
  """

  use OnePlaylist.DataCase, async: false
  use Oban.Testing, repo: OnePlaylist.Repo, prefix: "oban"

  alias OnePlaylist.AuthFixtures
  alias OnePlaylist.Providers
  alias OnePlaylist.Syncs
  alias OnePlaylist.Syncs.Sweeper
  alias OnePlaylist.Syncs.Sync
  alias OnePlaylist.Transfers.Transfer

  setup do
    user_id = AuthFixtures.user_id_fixture()
    {:ok, _library} = Providers.ensure_library(user_id)

    {:ok, _connection} =
      Providers.connect(user_id, :tidal, %{
        provider_user_id: "67373615",
        access_token: "at",
        refresh_token: "rt",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
        scopes: ["playlists.read", "playlists.write"],
        country: "US"
      })

    %{user: user_id}
  end

  defp sync_fixture(user_id, attrs \\ %{}) do
    {:ok, sync} =
      Syncs.create(
        Map.merge(
          %{
            user_id: user_id,
            source_provider: :library,
            source_playlist_id: "src-#{System.unique_integer([:positive])}",
            destination_provider: :tidal,
            interval_minutes: 60
          },
          attrs
        )
      )

    sync
  end

  defp transfers_for(sync_id) do
    Transfer |> where([t], t.sync_id == ^sync_id) |> Repo.all()
  end

  test "queues a transfer for a due sync", %{user: user} do
    sync = sync_fixture(user)

    assert :ok = perform_job(Sweeper, %{})

    assert [%Transfer{}] = transfers_for(sync.id)
  end

  test "leaves a sync that is not due alone", %{user: user} do
    sync = sync_fixture(user)

    {:ok, _later} =
      sync
      |> Sync.run_changeset(%{next_run_at: DateTime.add(DateTime.utc_now(), 3600)})
      |> Repo.update()

    assert :ok = perform_job(Sweeper, %{})

    assert [] = transfers_for(sync.id)
  end

  test "leaves a disabled sync alone", %{user: user} do
    sync = sync_fixture(user)
    {:ok, _off} = Syncs.set_enabled(user, sync.id, false)

    assert :ok = perform_job(Sweeper, %{})

    assert [] = transfers_for(sync.id)
  end

  # The one that would be missed: a sweep is a loop, and the natural way to
  # write it — `Enum.map` over `run/2` with a `{:ok, _}` match — stops the whole
  # sweep at the first sync that fails. One user's bad row would then block
  # every other user's schedule.
  #
  # The failure used here is a **raise**, not an error tuple, and that is the
  # point: `Sync.next_run_after/2` demands a cadence at or above the floor, so a
  # row written before the floor moved trips a precondition. Written by hand
  # through `update_all` because the changeset refuses it — which is exactly how
  # such a row would come to exist.
  test "a sync that raises does not stop the sweep", %{user: user} do
    broken = sync_fixture(user)
    healthy = sync_fixture(user)

    {1, _} =
      Repo.update_all(from(s in Sync, where: s.id == ^broken.id), set: [interval_minutes: 5])

    assert :ok = perform_job(Sweeper, %{})

    assert [] = transfers_for(broken.id)
    assert [%Transfer{}] = transfers_for(healthy.id)
  end

  test "a second sweep in the same window queues nothing more", %{user: user} do
    sync = sync_fixture(user)

    assert :ok = perform_job(Sweeper, %{})
    assert :ok = perform_job(Sweeper, %{})

    assert length(transfers_for(sync.id)) == 1
  end
end
