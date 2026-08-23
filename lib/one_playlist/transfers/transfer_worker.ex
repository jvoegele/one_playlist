defmodule OnePlaylist.Transfers.TransferWorker do
  @moduledoc """
  The Oban job that runs one transfer.

  Deliberately thin. Everything interesting is in
  `OnePlaylist.Transfers.Runner`, which is a plain function over a transfer and
  can be called directly in a test without a queue in the way.

  ## Retries are safe because the runner is

  `max_attempts: 3`, and a retry re-runs the whole transfer rather than
  resuming from a checkpoint. That is only sound because
  `OnePlaylist.Transfers.Runner.run/1` re-reads the destination and adds what is
  missing — so attempt two of a transfer that died halfway adds the remaining
  tracks and nothing else. A runner that appended blindly would turn Oban's
  retries into duplicate tracks in somebody's playlist.

  ## Uniqueness

  One in-flight job per transfer. Without it, a caller that enqueued twice — a
  double-clicked button, a retried API call — would have two workers resolving
  the same playlist against the same destination, and while the diff would keep
  them from duplicating tracks, they would both spend a full run's worth of
  provider quota to discover that.
  """

  use Oban.Worker,
    queue: :transfers,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      # Only jobs that have not finished. A transfer that completed can be run
      # again — that is what makes a re-transfer possible after someone edits
      # the source playlist.
      # `:incomplete` rather than listing states by hand: Oban warns that an
      # explicit list misses `:suspended`, and a uniqueness rule that silently
      # stops covering a state added in a later version is worse than none.
      states: Oban.Job.states() -- [:completed, :discarded, :cancelled]
    ]

  alias OnePlaylist.Transfers

  require Errata
  alias OnePlaylist.Transfers.Runner

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"transfer_id" => transfer_id}}) do
    case Transfers.fetch_unscoped(transfer_id) do
      {:ok, transfer} ->
        run(transfer)

      :error ->
        # The row is gone — the user deleted it, or the account was removed.
        # Discarding rather than retrying: no number of attempts will bring it
        # back, and a job that retries forever against a missing row is noise
        # in every queue dashboard from now on.
        Logger.warning("transfer #{transfer_id} no longer exists; discarding job")

        {:cancel, :transfer_not_found}
    end
  end

  defp run(transfer) do
    {:ok, transfer} = Transfers.record_start(transfer)

    case Runner.run(transfer) do
      {:ok, _completed} ->
        :ok

      {:error, reason} ->
        {:ok, _failed} = Transfers.record_failure(transfer, reason)

        # An error that says it is not retryable is taken at its word. Retrying
        # one costs real money in rate limit: `PlaylistTooLarge` re-reads the
        # whole playlist before refusing it, so twenty attempts is twenty reads
        # of something that will be exactly as large every time. The row still
        # says `failed`, which is what the user sees either way.
        #
        # Everything else is returned as an error so Oban retries. The row
        # already says `failed`, which is the honest state between attempts: if
        # this is the last one it stays that way, and if a retry succeeds it is
        # overwritten with the completed run.
        if retryable?(reason), do: {:error, reason}, else: {:cancel, reason}
    end
  end

  # `Errata.retryable?/1` raises on anything that is not an Errata error, and
  # plenty of what reaches here is not — a `Req` transport error, an
  # `Ecto.Changeset`, an exception from a mapper. Those keep the old behaviour
  # of being retried, because for them a retry is exactly the right answer.
  defp retryable?(reason) when Errata.is_error(reason), do: Errata.retryable?(reason)
  defp retryable?(_reason), do: true
end
