defmodule OnePlaylist.Syncs.Sweeper do
  @moduledoc """
  The job that fires due syncs.

  Runs every fifteen minutes and queues a transfer for every sync whose
  `next_run_at` has passed. That is the whole of the scheduler: `Oban` runs it,
  `OnePlaylist.Syncs.run/2` moves each sync forward, and the transfer pipeline
  does the rest.

  ## Fifteen minutes, against an hourly floor

  The sweep interval is not the cadence — it is the *resolution* of the cadence.
  A sync asked to run hourly runs at worst fifteen minutes late, which nobody
  notices, and the sweep costs one indexed query against a partial index.

  A minute-by-minute sweep would buy punctuality nobody asked for; an hourly one
  would make "every hour" mean "every two hours" whenever a sync's slot fell
  just after a sweep. Fifteen is the smallest number where the error is a
  rounding difference rather than a doubling.

  ## The batch is a budget

  `@batch` syncs a sweep. Each one queues a transfer, and a transfer is a
  rate-limited conversation with a provider — so the number that matters is not
  how many are due but how many the `transfers` queue can actually get through
  before the next sweep. With two workers and a playlist taking a minute or
  more, fifty is already generous, and a backlog drains oldest-first over
  successive sweeps because `due/2` orders by `next_run_at`.

  ## Nothing here retries

  `max_attempts: 1`. A sweep that fails is followed by another in fifteen
  minutes, and the syncs it missed are still due — the schedule *is* the retry.
  Retrying the sweep itself would only risk queueing a second transfer for a
  sync that was already moved forward.
  """

  use Oban.Worker, queue: :transfers, max_attempts: 1

  alias OnePlaylist.Syncs

  require Logger

  @batch 50

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    due = Syncs.due(now, @batch)

    ran = Enum.count(due, &ran?(&1, now))

    if due != [] do
      Logger.info("sync sweep: #{ran} of #{length(due)} due sync(s) queued")
    end

    :ok
  end

  # One failing sync must not stop the sweep: the others are due too, and a sync
  # pointed at a provider that has revoked its token would otherwise block every
  # sync in the table behind it. `run/2` has already moved this one forward, so
  # it is not retried until its next slot either way.
  #
  # Rescued as well as matched, because an error tuple is not the only way a
  # sync fails. `Sync.next_run_after/2` demands a cadence at or above the floor
  # and a row written before a floor moved would not have one — a precondition
  # violation, which is a raise. Catching only `{:error, _}` would let that one
  # row abandon every sync behind it.
  defp ran?(sync, now) do
    case Syncs.run(sync, now) do
      {:ok, _transfer} ->
        true

      {:error, reason} ->
        Logger.warning("sync #{sync.id} could not be queued: #{inspect(reason)}")
        false
    end
  rescue
    error ->
      Logger.warning("sync #{sync.id} raised: #{Exception.message(error)}")
      false
  end
end
