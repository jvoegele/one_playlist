defmodule OnePlaylist.Transfers do
  @moduledoc """
  Queueing playlist transfers, and reading what happened.

  A transfer is a **row first and a job second**. `create/1` persists it and
  enqueues an `OnePlaylist.Transfers.TransferWorker` in the same transaction, so
  a queued transfer and its record cannot disagree: either both exist or
  neither does. That is the whole reason Oban is Postgres-backed here rather
  than something faster and separate.

  Execution lives in `OnePlaylist.Transfers.Runner`; this module is the
  boundary — create, query, and wait.
  """

  import Ecto.Query

  alias OnePlaylist.Repo
  alias OnePlaylist.Transfers.Transfer
  alias OnePlaylist.Transfers.TransferItem
  alias OnePlaylist.Transfers.TransferWorker

  use Bond

  require Logger
  require WaitForIt

  @topic "transfers"

  @doc """
  Subscribes the caller to a transfer's progress.

  The transfer runs in an Oban worker, in a different process and potentially on
  a different node, so a LiveView showing it cannot observe the run directly.
  Every state change is broadcast instead.

  This is the push half of the pair `await/2` is the pull half of: a LiveView
  wants to be told, a script wants to block.
  """
  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(transfer_id),
    do: Phoenix.PubSub.subscribe(OnePlaylist.PubSub, "#{@topic}:#{transfer_id}")

  # A failed broadcast is not a failed transfer: the run has already been
  # persisted, and every watcher can still read it. Matched rather than
  # discarded so the difference between "handled" and "ignored" is visible.
  defp broadcast(%Transfer{} = transfer) do
    case Phoenix.PubSub.broadcast(
           OnePlaylist.PubSub,
           "#{@topic}:#{transfer.id}",
           {:transfer_updated, transfer}
         ) do
      :ok ->
        transfer

      {:error, reason} ->
        Logger.warning("transfer #{transfer.id} progress not broadcast: #{inspect(reason)}")

        transfer
    end
  end

  @doc """
  Creates a transfer and queues it, atomically.

  Returns the persisted transfer. The job is inserted in the same transaction,
  so a crash between the two is not a state this application can be in.
  """
  @spec create(map()) :: {:ok, Transfer.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    changeset =
      Transfer.create_changeset(%Transfer{}, Map.put_new(attrs, :threshold, default_threshold()))

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:transfer, changeset)
    |> Ecto.Multi.run(:job, fn _repo, %{transfer: transfer} ->
      %{transfer_id: transfer.id}
      |> TransferWorker.new()
      |> Oban.insert()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{transfer: transfer}} -> {:ok, transfer}
      {:error, :transfer, changeset, _changes} -> {:error, changeset}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc "Fetches a transfer by id."
  @spec fetch(Ecto.UUID.t()) :: {:ok, Transfer.t()} | :error
  def fetch(id) do
    case Repo.get(Transfer, id) do
      nil -> :error
      transfer -> {:ok, transfer}
    end
  end

  @doc "A user's transfers, most recent first."
  @spec list(Ecto.UUID.t()) :: [Transfer.t()]
  def list(user_id) do
    Repo.all(from(t in Transfer, where: t.user_id == ^user_id, order_by: [desc: t.inserted_at]))
  end

  @doc """
  The per-track report, in source playlist order.

  `outcome` is the column worth filtering on: `:unmatched` is the list a person
  resolves by hand, and `:already_present` is what a re-run looks like.
  """
  @spec items(Transfer.t(), keyword()) :: [TransferItem.t()]
  def items(%Transfer{} = transfer, opts \\ []) do
    query = from(i in TransferItem, where: i.transfer_id == ^transfer.id, order_by: i.position)

    query =
      case Keyword.get(opts, :outcome) do
        nil -> query
        outcome -> where(query, [i], i.outcome == ^outcome)
      end

    Repo.all(query)
  end

  @doc "How many report rows a transfer has."
  @spec count_items(Transfer.t()) :: non_neg_integer()
  def count_items(%Transfer{} = transfer),
    do: Repo.aggregate(from(i in TransferItem, where: i.transfer_id == ^transfer.id), :count)

  @doc """
  Waits for a transfer to finish, and returns it.

  The transfer runs in an Oban worker, in another process, so a caller that
  wants the outcome has to wait for it — a LiveView showing a spinner, a test
  asserting on a completed run, a synchronous API call.

  `WaitForIt.wait/2` rather than a sleep loop: it polls with backoff, gives up
  on a deadline, and says which of the two happened. A `Process.sleep/1` long
  enough to be reliable is always far longer than the wait usually needs, and
  the difference is dead time in every test that uses it.

  ## Options

    * `:timeout` — how long to wait. Defaults to 30 seconds.
    * `:frequency` — how often to re-check. Defaults to 50ms.
  """
  @spec await(Transfer.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, Transfer.t()} | {:error, :timeout}
  def await(transfer_or_id, opts \\ [])

  def await(%Transfer{id: id}, opts), do: await(id, opts)

  def await(id, opts) when is_binary(id) do
    timeout = Keyword.get(opts, :timeout, :timer.seconds(30))
    frequency = Keyword.get(opts, :frequency, 50)

    # `case_wait` rather than `wait`: the condition and the value wanted are the
    # same expression, and this binds out of it instead of re-querying once the
    # wait succeeds.
    #
    # The `else` clause is doing real work. `WaitForIt` documents that on timeout
    # each form behaves as its Elixir counterpart would on a final non-matching
    # evaluation — so without `else` this raises `CaseClauseError`, and a
    # catch-all clause *inside* the `do` block would match on the first
    # evaluation and end the wait immediately.
    WaitForIt.case_wait finished(id), timeout: timeout, frequency: frequency do
      {:ok, %Transfer{} = transfer} -> {:ok, transfer}
    else
      _never_finished -> {:error, :timeout}
    end
  end

  @doc """
  The transfer, if it has stopped; `:error` while it is still going.

  Public because `await/2` waits on it, and a condition a caller cannot
  evaluate itself is a poor thing to build a wait around.
  """
  @spec finished(Ecto.UUID.t()) :: {:ok, Transfer.t()} | :error
  def finished(id) do
    with {:ok, transfer} <- fetch(id),
         true <- Transfer.finished?(transfer) do
      {:ok, transfer}
    else
      _still_running -> :error
    end
  end

  @doc """
  Records progress on a transfer, before or during a run.

  Used by the runner for the one write that must land before any track is
  transferred: the destination playlist's id.
  """
  @spec record_progress(Transfer.t(), map()) :: {:ok, Transfer.t()} | {:error, Ecto.Changeset.t()}
  def record_progress(%Transfer{} = transfer, attrs) do
    transfer
    |> Transfer.progress_changeset(Map.put_new(attrs, :status, transfer.status))
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> broadcast(updated)
      {:error, _changeset} -> :ok
    end)
  end

  @doc """
  Persists a finished run: its counters, its status, and its whole report.

  One transaction, because a report and the counters that summarise it
  disagreeing is precisely the failure mode this application exists to avoid —
  and a half-written report is worse than none, since it looks complete.

  The items are upserted on `(transfer_id, position)`, which is what makes a
  re-run rewrite its report rather than append a second copy of it.
  """
  # The claim the docstring above makes, stated where it can be checked.
  #
  # `counted` and `items` are built by two separate folds over the same
  # resolutions in `Runner.finish/4` — one accumulating integers onto the
  # transfer, the other building a row per track. Nothing held them in step. A
  # fold that miscounts produces a report and a summary that disagree, and the
  # summary is what the transfer list shows: "8/10 matched" above a report with
  # nine matched rows in it. Neither number is obviously the wrong one, and
  # nothing raises.
  #
  # A precondition rather than a postcondition because the caller is the one
  # with the bug, and because it names it *before* the write rather than after —
  # a half-written report is worse than none, since it looks complete.
  #
  # Strictly stronger than `Runner.run/1`'s `reported_every_track`, which counts
  # the rows and stops there: ten rows against ten tracks passes that assertion
  # even when seven are unmatched and the counter says three. This is also the
  # cheaper of the two, since both values are already in hand and it needs no
  # query.
  @pre report_agrees_with_counters: TransferItem.tally(items) == Transfer.tally(counted)
  @spec record_run(Transfer.t(), Transfer.t(), [map()]) ::
          {:ok, Transfer.t()} | {:error, term()}
  def record_run(%Transfer{} = transfer, %Transfer{} = counted, items) do
    now = DateTime.utc_now()

    entries =
      Enum.map(items, fn item ->
        item
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:inserted_at, now)
      end)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:items, fn repo, _changes ->
      {count, _returned} =
        repo.insert_all(TransferItem, entries,
          on_conflict: {:replace_all_except, [:id, :inserted_at]},
          conflict_target: [:transfer_id, :position]
        )

      {:ok, count}
    end)
    |> Ecto.Multi.update(
      :transfer,
      Transfer.progress_changeset(transfer, %{
        status: :completed,
        # Cleared, because a successful run supersedes whatever the last failed
        # attempt said. Without this a retried transfer renders as `completed`
        # *and* shows the error that the retry fixed — a report that contradicts
        # itself, which is the failure mode this application is organised
        # against. Found by looking at the screen.
        last_error: nil,
        total_tracks: counted.total_tracks,
        matched_count: counted.matched_count,
        added_count: counted.added_count,
        unmatched_count: counted.unmatched_count,
        completed_at: now
      })
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{transfer: updated}} -> {:ok, broadcast(updated)}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc "Marks a transfer failed, keeping the reason where a person can read it."
  @spec record_failure(Transfer.t(), term()) :: {:ok, Transfer.t()} | {:error, Ecto.Changeset.t()}
  def record_failure(%Transfer{} = transfer, reason) do
    record_progress(transfer, %{status: :failed, last_error: describe(reason)})
  end

  @doc "Marks a transfer as started."
  @spec record_start(Transfer.t()) :: {:ok, Transfer.t()} | {:error, Ecto.Changeset.t()}
  def record_start(%Transfer{} = transfer),
    do: record_progress(transfer, %{status: :running, started_at: DateTime.utc_now()})

  defp describe(reason) when is_exception(reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason)

  defp default_threshold do
    OnePlaylist.Matching.threshold()
  end
end
