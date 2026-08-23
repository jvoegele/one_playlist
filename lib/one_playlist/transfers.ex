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

  alias OnePlaylist.Accounts.Session
  alias OnePlaylist.Repo
  alias OnePlaylist.Storage
  alias OnePlaylist.Transfers.Progress
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
  Tells subscribers how far a run has got, without writing anything.

  Deliberately not persisted. The counters are written once at the end by
  `record_run/3`, and a row update per track would be ten thousand writes for a
  number nobody reads after the run finishes. A watcher that misses a message
  gets the next one; a watcher that arrives late reads the counters.

  This is what makes a progress bar possible at all: before it, the only thing
  broadcast between "queued" and "completed" was the destination playlist being
  created.

  `items` carries the rows a watcher can show straight away — the same shape
  `OnePlaylist.Transfers.TransferItem.matched/4` builds, minus the fields that
  are only known once the writes are done. They are *provisional*: whether a
  matched track was `:matched` or `:already_present` depends on what the
  destination turns out to hold, which is decided after every track has been
  resolved. So a row shown here can change when the run finishes, and the final
  report replaces it.

  A list rather than one row, because a per-track broadcast is fine for a 58
  track import and not for a 5,000 track one. `OnePlaylist.Transfers.Progress`
  decides how many arrive together and how often, and carries the running
  tallies so a watcher that joins mid-run gets the same numbers as one that was
  there from the start.
  """
  @spec report_progress(Transfer.t(), Progress.t(), [map()]) :: :ok
  def report_progress(%Transfer{} = transfer, %Progress{} = progress, items \\ []) do
    Phoenix.PubSub.broadcast(
      OnePlaylist.PubSub,
      "#{@topic}:#{transfer.id}",
      {:transfer_progress,
       %{
         transfer_id: transfer.id,
         resolved: progress.resolved,
         total: progress.total,
         matched: progress.matched,
         unmatched: progress.unmatched,
         items: items
       }}
    )
    |> case do
      :ok ->
        :ok

      {:error, reason} ->
        # A watcher not hearing about track 7 of 58 is not a failed transfer.
        Logger.warning("transfer #{transfer.id} progress not broadcast: #{inspect(reason)}")
        :ok
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

  @doc """
  Fetches one of a user's own transfers.

  Answers `:error` for a transfer belonging to somebody else, exactly as it does
  for one that does not exist. The two are deliberately indistinguishable: a
  distinct "not yours" would confirm that a given id names a real transfer, and
  a report's id is the only thing an attacker needs to guess.

  This is what any request carrying a user should call. `fetch_unscoped/1` is
  for callers that genuinely have no user.
  """
  # The security property, stated as a specification rather than left implicit
  # in a `where` clause. It is not a restatement of the query: `Repo.get_by/2`
  # would satisfy the *type* while returning anybody's row if the `user_id` key
  # were dropped in a refactor, and this is the assertion that notices.
  #
  # Written because it was violated. `TransferLive.Show.mount/3` called the
  # unscoped fetch and rendered whatever came back, so any signed-in user could
  # read any transfer — playlist name, providers, status and the whole per-track
  # report — from `/transfers/<uuid>`. See the regression test.
  @post whenever({:ok, transfer} <- result, belongs_to_the_caller: transfer.user_id == user_id)
  @spec fetch(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Transfer.t()} | :error
  def fetch(user_id, id) do
    # Under `Repo.as_user/3` the `user_id` in the `get_by` stops being the only
    # thing enforcing ownership: Postgres applies `own transfers select` to the
    # same query. That is the layer whose absence let the original bug ship — a
    # forgotten scope here now returns nothing rather than somebody else's row.
    {:ok, found} =
      Repo.as_user(user_id, fn -> Repo.get_by(Transfer, id: id, user_id: user_id) end)

    case found do
      nil -> :error
      transfer -> {:ok, transfer}
    end
  end

  @doc """
  Fetches a transfer without regard to who owns it.

  **Only for callers with no user to check against**, of which there are two:
  `OnePlaylist.Transfers.TransferWorker`, which runs from a queue rather than a
  request, and `finished/1`, which backs the `await/2` wait.

  Named to be conspicuous at the call site. The scoped `fetch/2` is the one
  almost everything should reach for, and making the dangerous form the longer
  name is the whole point — the bug this pair replaced was a user-facing
  LiveView calling a function that looked like the ordinary way to load a row.
  """
  @spec fetch_unscoped(Ecto.UUID.t()) :: {:ok, Transfer.t()} | :error
  def fetch_unscoped(id) do
    case Repo.get(Transfer, id) do
      nil -> :error
      transfer -> {:ok, transfer}
    end
  end

  @doc """
  Deletes one of a user's transfers, and the file it came from.

  `transfer_items` and `transfer_sources` go with it by foreign key. An uploaded
  source file does not, because Storage is not in this database and has no
  cascade.

  ## The row goes first, deliberately

  If the file were removed first and the row delete then failed, the user would
  keep a transfer that looks intact and cannot be re-run — a broken state that
  nothing detects. Removing the row first fails the other way: the file is
  orphaned, and `public.prune_orphaned_imports/1` sweeps it up nightly. One
  failure mode is silent and permanent, the other is noisy and self-healing.

  The Storage delete is therefore best effort, and its result is deliberately
  discarded.
  """
  # Runs privileged rather than under `Repo.as_user/3`, because `authenticated`
  # holds only `select` on `transfers` — the grants say a user reads their
  # transfers and the application writes them. The scoping is `fetch/2`'s, which
  # is where it belongs: nothing here can address a row `fetch/2` would not
  # return.
  # Re-asks rather than trusting the return, which is the point: `:ok` from this
  # function is a claim about the database, and a rewrite to `delete_all` with a
  # wrong `where` would satisfy the type while removing nothing. One extra query
  # on a rare operation.
  @post whenever(:ok <- result, the_transfer_is_gone: fetch(user_id, id) == :error)
  @spec delete(Session.t(), Ecto.UUID.t()) :: :ok | :error
  def delete(%Session{user_id: user_id} = session, id) do
    with {:ok, transfer} <- fetch(user_id, id),
         {:ok, _deleted} <- Repo.delete(transfer) do
      # `_ =` because the whole branch is discarded: whether the file went or
      # not, the transfer is deleted and this answers `:ok`. Best effort by
      # design — see the note above, an orphan is recoverable and a transfer
      # pointing at a file that is gone is not.
      _ =
        if transfer.source_provider == :file do
          Storage.delete(session, transfer.source_playlist_id)
        end

      :ok
    else
      _otherwise -> :error
    end
  end

  @doc "A user's transfers, most recent first."
  @spec list(Ecto.UUID.t()) :: [Transfer.t()]
  def list(user_id) do
    {:ok, transfers} =
      Repo.as_user(user_id, fn ->
        Repo.all(
          from(t in Transfer, where: t.user_id == ^user_id, order_by: [desc: t.inserted_at])
        )
      end)

    transfers
  end

  @doc """
  The per-track report, in source playlist order.

  `:outcome` is the column worth filtering on: `:unmatched` is the list a person
  resolves by hand, and `:already_present` is what a re-run looks like.

  `:limit` and `:offset` take a window. Unwindowed by default, which is right
  for a CSV export and wrong for a page — see `OnePlaylistWeb.TransferLive.Show`.
  """
  @spec items(Transfer.t(), keyword()) :: [TransferItem.t()]
  def items(%Transfer{} = transfer, opts \\ []) do
    query = from(i in TransferItem, where: i.transfer_id == ^transfer.id, order_by: i.position)

    query =
      case Keyword.get(opts, :outcome) do
        nil -> query
        outcome -> where(query, [i], i.outcome == ^outcome)
      end

    # A window rather than everything. A report is ordered by `position` and its
    # rows never move once written, so offset paging cannot skip or repeat a row
    # the way it can over a table somebody is still inserting into.
    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        value when is_integer(value) and value >= 0 -> limit(query, ^value)
      end

    query =
      case Keyword.get(opts, :offset) do
        nil -> query
        value when is_integer(value) and value >= 0 -> offset(query, ^value)
      end

    # Scoped by `transfer_id`, and scoped again by the policy on
    # `transfer_items`. The owner comes from the transfer rather than a separate
    # argument: a caller holding a `%Transfer{}` has already been through
    # `fetch/2`, so its `user_id` is the authority here.
    {:ok, items} = Repo.as_user(transfer.user_id, fn -> Repo.all(query) end)

    items
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
    with {:ok, transfer} <- fetch_unscoped(id),
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
