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
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers
  alias OnePlaylist.Repo
  alias OnePlaylist.Storage
  alias OnePlaylist.Transfers.Progress
  alias OnePlaylist.Transfers.Transfer
  alias OnePlaylist.Transfers.TransferItem
  alias OnePlaylist.Transfers.TransferOverride
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

  This is what makes a progress bar possible at all. The only other thing
  broadcast between "queued" and "completed" is the destination playlist being
  created, which is one message for a run of any length.

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
  Every correction made against a transfer, keyed by the track's position.

  Read by `OnePlaylist.Transfers.Runner` before it matches anything, which is
  what makes a correction survive a re-run. A map rather than a list because
  that is how the runner uses it: one lookup per track, against a table that is
  usually empty and never large.
  """
  @spec overrides(Transfer.t()) :: %{non_neg_integer() => TransferOverride.t()}
  def overrides(%Transfer{} = transfer) do
    query = from(o in TransferOverride, where: o.transfer_id == ^transfer.id)

    {:ok, found} = Repo.as_user(transfer.user_id, fn -> Repo.all(query) end)

    Map.new(found, &{&1.position, &1})
  end

  @doc """
  Records a correction, and puts the chosen track in the destination.

  The order matters and is not the obvious one. The track is written to the
  destination playlist **first**, and only a confirmed write is recorded. The
  other way round produces a report claiming a track was added that never was,
  which is the exact failure this application exists to make impossible.

  Both halves then happen together: the override row, the report row, and the
  transfer's counters move in one transaction, so a report can never disagree
  with the summary above it.

  Re-running the transfer afterwards is safe and is the point. The runner reads
  the override before matching, resolves the track to the same destination id,
  finds it already in the playlist, and records `:already_present` — the same
  answer a re-run gives for anything it added last time.

  ## Correcting a row that already matched

  The wrong track is *in* the destination, so the right one replacing it means
  taking the wrong one out — which is what `remove_tracks/4` is for.

  `:already_present` is removed from too, and that is worth justifying, because
  the name suggests a track the user had rather than one of ours. It is not:
  `destination_playlist_id` is set in exactly one place, where
  `OnePlaylist.Transfers.Runner` *creates* the destination — no path in this
  application transfers into a playlist somebody else made. So everything in it
  arrived through this transfer, and a re-run is precisely what turns last run's
  `:matched` into this run's `:already_present`. Refusing to remove those would leave a wrong track that
  this application put there, on the report row that says it was corrected —
  which is the report disagreeing with the playlist, the failure this whole
  application is organised against.

  The residual case is a user adding that same recording to our playlist by
  hand, where the removal takes their copy too. That is why what gets removed
  is the report row's own `destination_track_id` and nothing wider.

  The order is add, then remove, and the asymmetry is deliberate. Both failures
  are possible and one is much worse:

  | If this fails | Playlist | Report |
  | --- | --- | --- |
  | the add | unchanged | unchanged — nothing is recorded |
  | the remove | holds both | says the new one, truthfully |

  Removing first inverts that: a failed add would leave the playlist holding
  neither while the report still names the old track, which is a report claiming
  a track is somewhere it is not. An extra track nobody asked for is visible,
  recoverable and honest; a lying report is none of those. A failed removal is
  therefore reported to the user rather than rolled back.
  """
  # `already_added?` is the one thing worth asserting here and it cannot be
  # asserted: whether the destination accepted the write is a fact about a
  # remote service. What *can* be stated is that this function never invents an
  # outcome for a track the caller did not name.
  @pre position_is_real: is_integer(position) and position >= 0
  @spec override(Session.t(), Transfer.t(), non_neg_integer(), map()) ::
          {:ok, Transfer.t()} | {:ok, Transfer.t(), :not_removed} | {:error, term()}
  def override(%Session{} = session, %Transfer{} = transfer, position, chosen) do
    with {:ok, connection} <-
           Providers.fetch_usable_connection(session.user_id, transfer.destination_provider),
         {:ok, adapter} <- Providers.adapter(transfer.destination_provider),
         {:ok, track} <- chosen_track(transfer, chosen),
         {:ok, superseded} <- superseded_track(transfer, position, track),
         {:ok, _count} <-
           adapter.add_tracks(connection, transfer.destination_playlist_id, [track], []) do
      removal = withdraw(adapter, connection, transfer, superseded)

      case {persist_override(transfer, position, track), removal} do
        {{:ok, updated}, :ok} -> {:ok, updated}
        {{:ok, updated}, :not_removed} -> {:ok, updated, :not_removed}
        {{:error, _reason} = error, _removal} -> error
      end
    end
  end

  # What this transfer put at that position and is about to stop pointing at, or
  # `nil` when there is nothing to take out.
  #
  # Any row naming a destination track, which is `:matched` or
  # `:already_present` — see the docstring for why the second is ours too. An
  # `:unmatched` row named nothing and put nothing there.
  defp superseded_track(%Transfer{} = transfer, position, %Track{} = chosen) do
    case items(transfer, position: position) do
      [%TransferItem{destination_track_id: id}] when is_binary(id) and id != "" ->
        # Choosing the track that is already there is a no-op rather than a
        # remove and re-add of the same thing.
        if id == chosen.provider_id, do: {:ok, nil}, else: {:ok, track_at(transfer, id)}

      [%TransferItem{}] ->
        {:ok, nil}

      [] ->
        {:error, :no_such_track}
    end
  end

  defp track_at(%Transfer{} = transfer, id),
    do: %Track{provider: transfer.destination_provider, provider_id: id}

  defp withdraw(_adapter, _connection, _transfer, nil), do: :ok

  defp withdraw(adapter, connection, %Transfer{} = transfer, %Track{} = superseded) do
    case adapter.remove_tracks(connection, transfer.destination_playlist_id, [superseded], []) do
      {:ok, _removed} ->
        :ok

      {:error, reason} ->
        # Not fatal, for the reason the docstring gives: the report is about to
        # be true, and the cost is one extra track in the playlist. Logged and
        # reported to the caller so it is not silent.
        Logger.warning(
          "transfer #{transfer.id}: could not remove the superseded track " <>
            "#{superseded.provider_id}: #{inspect(reason)}"
        )

        :not_removed
    end
  end

  defp chosen_track(%Transfer{} = transfer, %{"provider_id" => id} = chosen)
       when is_binary(id) and id != "" do
    {:ok,
     %Track{
       provider: transfer.destination_provider,
       provider_id: id,
       title: chosen["title"],
       artists: List.wrap(chosen["artist"])
     }}
  end

  defp chosen_track(_transfer, _chosen), do: :error

  defp persist_override(%Transfer{} = transfer, position, %Track{} = track) do
    attrs = %{
      transfer_id: transfer.id,
      user_id: transfer.user_id,
      position: position,
      destination_track_id: track.provider_id,
      destination_title: track.title,
      destination_artist: List.first(track.artists)
    }

    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :override,
      TransferOverride.changeset(%TransferOverride{}, attrs),
      on_conflict: {:replace, [:destination_track_id, :destination_title, :destination_artist]},
      conflict_target: [:transfer_id, :position]
    )
    |> Ecto.Multi.run(:item, fn repo, _changes ->
      update_item_to_manual(repo, transfer, position, track)
    end)
    |> Ecto.Multi.run(:transfer, fn repo, %{item: previous_outcome} ->
      recount(repo, transfer, previous_outcome)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{transfer: updated}} -> {:ok, broadcast(updated)}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # Returns the outcome the row *had*, which is what the counters have to be
  # adjusted from. A correction applied to an already-matched row moves a
  # different number than one applied to an unmatched row, and getting that
  # wrong breaks `Transfer`'s ledger invariant rather than silently skewing a
  # summary — which is exactly what that invariant is for.
  defp update_item_to_manual(repo, %Transfer{} = transfer, position, %Track{} = track) do
    query =
      from(i in TransferItem, where: i.transfer_id == ^transfer.id and i.position == ^position)

    case repo.one(query) do
      nil ->
        {:error, :no_such_track}

      %TransferItem{} = item ->
        {1, _returned} =
          repo.update_all(from(i in TransferItem, where: i.id == ^item.id),
            set: [
              outcome: :matched,
              destination_track_id: track.provider_id,
              destination_title: track.title,
              destination_artist: List.first(track.artists),
              strategy: "manual",
              confidence: "chosen",
              score: 1.0,
              reason: nil
            ]
          )

        {:ok, item.outcome}
    end
  end

  defp recount(repo, %Transfer{} = transfer, previous_outcome) do
    counted =
      case previous_outcome do
        # The common case: a track nobody could match is now matched and added.
        :unmatched ->
          Transfer.record_correction(transfer)

        # It resolved before and still does, but to a track the destination
        # already held rather than one this run wrote. Now this run has written
        # one, so `added_count` moves and nothing else does.
        :already_present ->
          Transfer.record_write(transfer)

        # Already matched *and* written. The correction changes which track was
        # added, not how many were, so no counter moves.
        :matched ->
          transfer
      end

    # The counters go through `attrs`, not through the struct. `record_correction/1`
    # returns an updated `%Transfer{}`, but `progress_changeset/2` builds its
    # changes by casting the map — so passing the corrected struct as the *data*
    # and only `status` as the attrs writes the status and silently discards
    # every counter. The report then shows a matched row above a summary still
    # claiming it is unmatched.
    changeset =
      Transfer.progress_changeset(transfer, %{
        status: counted.status,
        matched_count: counted.matched_count,
        added_count: counted.added_count,
        unmatched_count: counted.unmatched_count
      })

    repo.update(changeset)
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
  # Written because it was violated — see `OnePlaylist.Repo`, and the regression
  # test.
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
  name is the whole point: the failure this pair guards against is a
  user-facing LiveView reaching for whatever looks like the ordinary way to
  load a row.
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
  # The scoping law for the transfer list. Proven by mutation: dropping both the
  # `where` and `Repo.as_user/3` fires it — neither alone does, since each scope
  # suffices on its own.
  @post all_belong_to_the_user: forall(transfer <- result, transfer.user_id == user_id)
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

  Every row belongs to the transfer asked about, and the order is the source
  playlist's — which is the whole readability of the report, since a reader
  compares it against the playlist they can see. Both are asserted below.

  `:outcome` is the column worth filtering on: `:unmatched` is the list a person
  resolves by hand, and `:already_present` is what a re-run looks like.

  `:position` narrows to one row, which is what a correction needs: the
  candidate list on that row is the authority on what a person may choose.

  `:limit` and `:offset` take a window. Unwindowed by default, which is right
  for a CSV export and wrong for a page — see `OnePlaylistWeb.TransferLive.Show`.
  """
  # Proven by mutation: dropping the `where` fires `all_from_this_transfer` once
  # a second transfer has a report, and dropping the `order_by` fires
  # `ordered_by_source_position` on any report whose rows were not inserted in
  # order.
  @post all_from_this_transfer: forall(item <- result, item.transfer_id == transfer.id)
  @post ordered_by_source_position:
          result |> Enum.map(& &1.position) |> Enum.sort() ==
            Enum.map(result, & &1.position)
  @spec items(Transfer.t(), keyword()) :: [TransferItem.t()]
  def items(%Transfer{} = transfer, opts \\ []) do
    query =
      from(i in TransferItem, where: i.transfer_id == ^transfer.id, order_by: i.position)

    query = Enum.reduce(opts, query, &narrow/2)

    # Scoped by `transfer_id`, and scoped again by the policy on
    # `transfer_items`. The owner comes from the transfer rather than a separate
    # argument: a caller holding a `%Transfer{}` has already been through
    # `fetch/2`, so its `user_id` is the authority here.
    {:ok, items} = Repo.as_user(transfer.user_id, fn -> Repo.all(query) end)

    items
  end

  defp narrow({_option, nil}, query), do: query
  defp narrow({:outcome, outcome}, query), do: where(query, [i], i.outcome == ^outcome)
  defp narrow({:position, position}, query), do: where(query, [i], i.position == ^position)

  # A window rather than everything. A report is ordered by `position` and its
  # rows never move once written, so offset paging cannot skip or repeat a row
  # the way it can over a table somebody is still inserting into.
  defp narrow({:limit, value}, query) when is_integer(value) and value >= 0,
    do: limit(query, ^value)

  defp narrow({:offset, value}, query) when is_integer(value) and value >= 0,
    do: offset(query, ^value)

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

  **The report and the counters must already agree** before either is written —
  `report_agrees_with_counters`, and the caller's obligation rather than this
  function's promise. `Runner.finish/4` folds over the same resolutions twice,
  once accumulating integers onto the transfer and once building a row per track,
  and nothing else holds the two in step. A fold that miscounts shows "8/10
  matched" above a report with nine matched rows: neither number is obviously the
  wrong one, and nothing raises.
  """
  # Strictly stronger than `Runner.run/1`'s `reported_every_track`, which counts
  # rows and stops — ten rows against ten tracks passes that even when seven are
  # unmatched and the counter says three. Cheaper, too: both values are in hand
  # and it needs no query.
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
        # against.
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
