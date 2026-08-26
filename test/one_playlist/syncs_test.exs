defmodule OnePlaylist.SyncsTest do
  @moduledoc """
  Scheduled sync: the arithmetic, the scoping, and the two things that must not
  happen twice.

  A sync is a small module in front of machinery that is already tested, so this
  file deliberately does not re-test transfers. It tests the four promises that
  are new here:

    * **A run moves the schedule forward before it queues anything.** Without
      that the sweeper picks the same sync up on its next pass and two runs of
      the same playlist race each other.
    * **The destination is pinned once.** A weekly sync that created a new
      playlist every run would leave fifty-two behind in a year.
    * **The sweeper sees only what is due.** Disabled, unscheduled and
      not-yet-due syncs are all invisible to it, and each is invisible for a
      different reason.
    * **A user sees only their own.** Standard here, and it matters more than
      usual: a sync is a standing instruction to use somebody's credentials.

  The sweeper is driven directly. `perform/1` takes no arguments that matter, so
  a test that inserted an Oban job and drained a queue would be testing Oban.
  """

  use OnePlaylist.DataCase, async: false
  use Bond.Test

  alias OnePlaylist.AuthFixtures
  alias OnePlaylist.Providers
  alias OnePlaylist.Syncs
  alias OnePlaylist.Syncs.Sync
  alias OnePlaylist.Transfers.Transfer

  setup do
    user_id = AuthFixtures.user_id_fixture()
    {:ok, _library} = Providers.ensure_library(user_id)

    {:ok, connection} =
      Providers.connect(user_id, :tidal, %{
        provider_user_id: "67373615",
        access_token: "at",
        refresh_token: "rt",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
        scopes: ["playlists.read", "playlists.write"],
        country: "US"
      })

    %{user: user_id, connection: connection}
  end

  defp sync_fixture(user_id, attrs \\ %{}) do
    {:ok, sync} =
      Syncs.create(
        Map.merge(
          %{
            user_id: user_id,
            source_provider: :library,
            source_playlist_id: "src-#{System.unique_integer([:positive])}",
            source_playlist_name: "Weekly",
            destination_provider: :tidal,
            interval_minutes: 60 * 24
          },
          attrs
        )
      )

    sync
  end

  describe "create/1" do
    test "schedules the first run for now", %{user: user} do
      sync = sync_fixture(user)

      assert sync.enabled
      assert Sync.due?(sync, DateTime.utc_now())
    end

    test "refuses a cadence under the floor", %{user: user} do
      assert {:error, changeset} =
               Syncs.create(%{
                 user_id: user,
                 source_provider: :library,
                 source_playlist_id: "s",
                 destination_provider: :tidal,
                 interval_minutes: 5
               })

      assert %{interval_minutes: [_message]} = errors_on(changeset)
    end

    # The unique index is what stops two schedules racing each other into one
    # destination — see the migration.
    test "refuses a second sync of the same playlist to the same service", %{user: user} do
      sync = sync_fixture(user)

      assert {:error, changeset} =
               Syncs.create(%{
                 user_id: user,
                 source_provider: sync.source_provider,
                 source_playlist_id: sync.source_playlist_id,
                 destination_provider: sync.destination_provider,
                 interval_minutes: 60
               })

      assert %{user_id: ["is already being synced to that service"]} = errors_on(changeset)
    end

    # `destination_playlist_id` is not castable, and this is the reason: a
    # caller supplying one would point a schedule at a playlist nobody checked
    # they own.
    test "ignores a destination playlist id supplied by the caller", %{user: user} do
      sync = sync_fixture(user, %{destination_playlist_id: "somebody-elses-playlist"})

      assert is_nil(sync.destination_playlist_id)
    end
  end

  describe "list/1" do
    test "answers only the user's own syncs", %{user: user} do
      mine = sync_fixture(user)
      other = sync_fixture(AuthFixtures.user_id_fixture())

      ids = user |> Syncs.list() |> Enum.map(& &1.id)

      assert mine.id in ids
      refute other.id in ids
    end
  end

  describe "due/2" do
    test "answers syncs whose slot has passed, oldest first", %{user: user} do
      now = DateTime.utc_now()

      soon = sync_fixture(user)
      {:ok, soon} = advance(soon, DateTime.add(now, -60, :second))

      earlier = sync_fixture(user)
      {:ok, earlier} = advance(earlier, DateTime.add(now, -600, :second))

      ids = now |> Syncs.due(10) |> Enum.map(& &1.id)

      assert Enum.find_index(ids, &(&1 == earlier.id)) <
               Enum.find_index(ids, &(&1 == soon.id))
    end

    test "skips a disabled sync, and keeps its place", %{user: user} do
      sync = sync_fixture(user)
      {:ok, disabled} = Syncs.set_enabled(user, sync.id, false)

      refute Enum.any?(Syncs.due(DateTime.utc_now(), 10), &(&1.id == sync.id))
      assert disabled.next_run_at == sync.next_run_at
    end

    test "skips a sync scheduled for later", %{user: user} do
      sync = sync_fixture(user)
      {:ok, _later} = advance(sync, DateTime.add(DateTime.utc_now(), 3600, :second))

      refute Enum.any?(Syncs.due(DateTime.utc_now(), 10), &(&1.id == sync.id))
    end

    test "honours the limit", %{user: user} do
      for _ <- 1..3, do: sync_fixture(user)

      assert length(Syncs.due(DateTime.utc_now(), 2)) <= 2
    end
  end

  describe "run/2" do
    test "queues a transfer naming what the sync names", %{user: user} do
      sync = sync_fixture(user)

      assert {:ok, transfer} = Syncs.run(sync)

      assert transfer.user_id == sync.user_id
      assert transfer.source_playlist_id == sync.source_playlist_id
      assert transfer.destination_provider == sync.destination_provider
      assert transfer.sync_id == sync.id
    end

    # The overlap guard, stated where it can be checked — the contract on
    # `run/2` cannot say this, because saying it means reading the row back.
    test "moves the schedule forward before returning", %{user: user} do
      sync = sync_fixture(user)
      now = DateTime.utc_now()

      assert {:ok, _transfer} = Syncs.run(sync, now)

      reloaded = Repo.get(Sync, sync.id)

      refute Sync.due?(reloaded, now)
      assert reloaded.last_run_at == now
      assert DateTime.diff(reloaded.next_run_at, now) >= 60 * 60
    end

    test "a second sweep in the same moment finds nothing", %{user: user} do
      sync = sync_fixture(user)
      now = DateTime.utc_now()

      assert {:ok, _transfer} = Syncs.run(sync, now)

      refute Enum.any?(Syncs.due(now, 10), &(&1.id == sync.id))
    end

    test "records the transfer it queued", %{user: user} do
      sync = sync_fixture(user)

      assert {:ok, transfer} = Syncs.run(sync)
      assert Repo.get(Sync, sync.id).last_transfer_id == transfer.id
    end
  end

  describe "pin_destination/3" do
    test "records where the first run put its tracks", %{user: user} do
      sync = sync_fixture(user)

      assert {:ok, pinned} = Syncs.pin_destination(sync, "dest-1", "Weekly")

      assert pinned.destination_playlist_id == "dest-1"
      assert pinned.destination_playlist_name == "Weekly"
    end

    test "the first pin wins", %{user: user} do
      sync = sync_fixture(user)
      {:ok, pinned} = Syncs.pin_destination(sync, "dest-1", "Weekly")

      assert {:ok, again} = Syncs.pin_destination(pinned, "dest-2", "Weekly (2)")

      assert again.destination_playlist_id == "dest-1"
      assert Repo.get(Sync, sync.id).destination_playlist_id == "dest-1"
    end

    test "a later run transfers into the pinned playlist", %{user: user} do
      sync = sync_fixture(user)
      {:ok, pinned} = Syncs.pin_destination(sync, "dest-1", "Weekly")

      assert {:ok, transfer} = Syncs.run(pinned)
      assert transfer.destination_playlist_id == "dest-1"
    end
  end

  describe "Sync.next_run_after/2" do
    test "schedules forward from now, not from the slot that was missed" do
      now = ~U[2026-08-26 12:00:00.000000Z]
      sync = %Sync{interval_minutes: 60, next_run_at: ~U[2026-08-20 00:00:00.000000Z]}

      assert Sync.next_run_after(sync, now) == ~U[2026-08-26 13:00:00.000000Z]
    end

    # Falsifiable by input rather than by mutation, and the fault is the
    # caller's: a struct carrying a nonsensical cadence is one nothing here
    # built. See the comment on `next_run_after/2` for why this replaced a
    # postcondition that could not fail.
    test "refuses a cadence below the floor" do
      assert_precondition_violation(
        Sync.next_run_after(%Sync{interval_minutes: -60}, DateTime.utc_now()),
        label: :interval_is_a_cadence
      )

      assert_precondition_violation(
        Sync.next_run_after(%Sync{interval_minutes: 5}, DateTime.utc_now()),
        label: :interval_is_a_cadence
      )
    end
  end

  describe "delete/2" do
    test "leaves the transfers it produced", %{user: user} do
      sync = sync_fixture(user)
      {:ok, transfer} = Syncs.run(sync)

      assert :ok = Syncs.delete(user, sync.id)

      assert :error = Syncs.fetch(user, sync.id)
      assert %Transfer{} = kept = Repo.get(Transfer, transfer.id)
      assert is_nil(kept.sync_id)
    end

    test "refuses somebody else's", %{user: user} do
      theirs = sync_fixture(AuthFixtures.user_id_fixture())

      assert :error = Syncs.delete(user, theirs.id)
      assert %Sync{} = Repo.get(Sync, theirs.id)
    end
  end

  defp advance(sync, at) do
    sync |> Sync.run_changeset(%{next_run_at: at}) |> Repo.update()
  end
end
