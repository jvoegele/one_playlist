defmodule OnePlaylist.Syncs do
  @moduledoc """
  Standing instructions to keep playlists mirrored, and the running of them.

  `docs/reference/domain.md` names scheduled sync as the retention feature both
  incumbents charge for. It is also the smallest feature in this application
  relative to its value, because everything it needs already exists:

    * `OnePlaylist.Transfers.Runner.run/1` is **idempotent** — it re-reads the
      destination and writes what is missing — so a sync run is an ordinary
      transfer and needs no pipeline of its own;
    * a transfer already resumes into a destination it created, which is exactly
      what every run after the first must do;
    * Oban already runs transfers, with the breaker, the rate limiters and the
      retry policy that go with them.

  So a sync is a row, a sweeper, and the arithmetic in between.

  ## Each run is a transfer, and that is the whole design

  `run/2` creates a `OnePlaylist.Transfers.Transfer` and queues it. The sync's
  history is therefore the ordinary transfers list: a per-track report per run,
  the batch and correction machinery, deletion, everything. A second reporting
  surface built beside it would have to reimplement all of that and would drift.

  ## Firing is Oban's rather than `pg_cron`'s, deliberately

  This project uses `pg_cron` for the four nightly pruning jobs, which is real
  work belonging in the database. Sync is not that work: it needs decrypted
  provider credentials, the `ExternalService` breakers and Oban's retry policy,
  all of which live in the BEAM. `pg_cron` could only reach them through
  `pg_net` and a webhook, which is Oban with a network hop and a second failure
  mode in front of it. CLAUDE.md's rule — never run both for the same workload —
  is what settles it.

  ## Overlap is prevented by the schedule, not by a lock

  `mark_running/2` moves `next_run_at` forward **before** the transfer is
  queued, so the sweeper's next pass cannot see the same sync twice. A run that
  then fails does not retry until the next slot, which is the right trade for a
  scheduled job: Oban already retries the transfer itself three times, and a
  sync that hammered a failing provider every sweep would spend a user's quota
  on an outage.
  """

  use Bond

  import Ecto.Query

  alias OnePlaylist.Repo
  alias OnePlaylist.Syncs.Sync
  alias OnePlaylist.Transfers

  @doc """
  Creates a sync and schedules its first run for now.

  Enabled and due immediately, because somebody setting one up wants to see it
  work rather than to find out tomorrow whether they configured it correctly.
  """
  @spec create(map()) :: {:ok, Sync.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Sync{}
    |> Sync.create_changeset(Map.put_new(attrs, :next_run_at, DateTime.utc_now()))
    |> Repo.insert()
  end

  @doc """
  A user's syncs, most recently made first.
  """
  # The same scoping law every user-owned list here carries. This one decides
  # what the application does on a schedule with somebody's credentials, so a
  # foreign row reaching it is a schedule the wrong person can pause or point
  # somewhere else.
  #
  # Two guards, and measurement says each is sufficient alone: dropping the
  # `where` and leaving `as_user/3` in place still returns only this user's
  # rows, because the RLS policy is doing exactly what it was written to do.
  # Defence in depth rather than an accidental double-guard, so the mutation
  # that proves the contract removes both at once — and does fire it.
  @post all_belong_to_the_user: forall(sync <- result, sync.user_id == user_id)
  @spec list(Ecto.UUID.t()) :: [Sync.t()]
  def list(user_id) do
    {:ok, syncs} =
      Repo.as_user(user_id, fn ->
        Sync
        |> where([s], s.user_id == ^user_id)
        |> order_by([s], desc: s.inserted_at)
        |> Repo.all()
      end)

    syncs
  end

  @doc """
  One of a user's own syncs, or `:error`.
  """
  @spec fetch(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Sync.t()} | :error
  def fetch(user_id, id) do
    {:ok, found} =
      Repo.as_user(user_id, fn -> Repo.get_by(Sync, id: id, user_id: user_id) end)

    case found do
      nil -> :error
      sync -> {:ok, sync}
    end
  end

  @doc """
  Turns a sync on or off, keeping its place in the schedule.

  Disabling deliberately leaves `next_run_at` alone: somebody pausing a sync for
  an afternoon should not have it fire the moment they turn it back on, and
  somebody pausing it for a month should not lose the cadence they chose.
  """
  @spec set_enabled(Ecto.UUID.t(), Ecto.UUID.t(), boolean()) ::
          {:ok, Sync.t()} | :error | {:error, Ecto.Changeset.t()}
  def set_enabled(user_id, id, enabled?) when is_boolean(enabled?) do
    with {:ok, sync} <- fetch(user_id, id) do
      sync |> Sync.run_changeset(%{enabled: enabled?}) |> Repo.update()
    end
  end

  @doc """
  Deletes a sync. The transfers it produced are untouched.

  They are a record of things that actually happened, and deleting the standing
  instruction is not a statement about them.
  """
  @spec delete(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | :error
  def delete(user_id, id) do
    with {:ok, sync} <- fetch(user_id, id) do
      {:ok, _deleted} = Repo.delete(sync)
      :ok
    end
  end

  @doc """
  Every sync ready to run at `now`, oldest due first.

  Unscoped by user on purpose: this is the sweeper's query and it runs as the
  application rather than as anybody. Oldest first so a backlog drains in the
  order it accumulated rather than starving whoever is unluckiest.
  """
  # The sweeper enqueues a transfer per row, and a transfer is a rate-limited
  # conversation with somebody's provider — so a bug here is not a wrong number
  # on a screen, it is every sync in the table firing at once. `limit` is the
  # caller's bound and this says it was honoured.
  #
  # `all_are_due` is the other half and the one with teeth: a sweeper that
  # picked up disabled or not-yet-due syncs would run schedules nobody asked
  # for, on a cadence nobody chose.
  #
  # Both proven by mutation: dropping `limit(^limit)` fires the first, and
  # dropping `s.enabled` from the `where` fires the second.
  @post no_more_than_asked_for: length(result) <= limit
  @post all_are_due: forall(sync <- result, Sync.due?(sync, now))
  @spec due(DateTime.t(), pos_integer()) :: [Sync.t()]
  def due(now, limit) do
    Sync
    |> where([s], s.enabled and not is_nil(s.next_run_at) and s.next_run_at <= ^now)
    |> order_by([s], asc: s.next_run_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Runs one sync: queues a transfer for it and moves it forward in the schedule.

  The schedule moves **first**, so the sweeper's next pass cannot pick the same
  sync up again while this run is still going — see the moduledoc on why that is
  a schedule rather than a lock.

  Answers `{:ok, transfer}`, or `{:error, reason}` with the sync already moved
  forward: a sync whose transfer could not be queued has still had its turn, and
  trying again immediately would only fail again.
  """
  # `moved_forward` is the overlap guard, stated where it can be checked. Without
  # it a sweep every five minutes against a sync whose transfer takes ten would
  # start a second run on top of the first, and both would resolve the same
  # playlist against the same destination — the diff would keep them from
  # duplicating tracks, and they would each spend a full run's provider quota to
  # discover that.
  #
  # That law is **not** the contract below, and cannot be: checking it means
  # reading the row back, and an assertion that touches the database is neither
  # pure nor cheap — Bond's rule, and the same reason `Providers.disconnect/2`
  # keeps its blast-radius law in a test. `syncs_test.exs` asserts the schedule
  # moved; this asserts what can be seen from here.
  #
  # And what can be seen from here is worth seeing. A sync queueing a transfer
  # for a *different* playlist, or for another user, is the worst thing this
  # module could do — it would run on a schedule, unattended, writing somebody
  # else's music into somebody's library, and the report would look ordinary.
  #
  # Proven by mutation: taking any field from a different sync fires it.
  @post whenever(
          {:ok, transfer} <- result,
          transfers_what_the_sync_names:
            transfer.user_id == sync.user_id and
              transfer.source_provider == sync.source_provider and
              transfer.source_playlist_id == sync.source_playlist_id and
              transfer.destination_provider == sync.destination_provider
        )
  @spec run(Sync.t(), DateTime.t()) :: {:ok, Transfers.Transfer.t()} | {:error, term()}
  def run(%Sync{} = sync, now \\ DateTime.utc_now()) do
    {:ok, moved} =
      sync
      |> Sync.run_changeset(%{last_run_at: now, next_run_at: Sync.next_run_after(sync, now)})
      |> Repo.update()

    case Transfers.create(transfer_attrs(moved)) do
      {:ok, transfer} ->
        {:ok, _noted} =
          moved |> Sync.run_changeset(%{last_transfer_id: transfer.id}) |> Repo.update()

        {:ok, transfer}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Records where a run put its tracks, so later runs write to the same playlist.

  Called by `OnePlaylist.Transfers.Runner` once a destination exists. Writes
  **once**: the first run creates the playlist and pins it, and a later run
  reporting a different id is a bug rather than a change of mind — see the
  migration.
  """
  # The pin is what stops a weekly sync leaving fifty-two playlists behind, and
  # it is a write that must never be repeated. Stated as "the first one wins"
  # rather than "it is not nil", because the second is satisfied by overwriting.
  #
  # Proven by mutation: removing the `is_nil` clause from the head lets a later
  # run overwrite the pin, and this fires the moment the ids differ.
  @post whenever(
          {:ok, pinned} <- result,
          keeps_the_first_destination:
            pinned.destination_playlist_id == (sync.destination_playlist_id || playlist_id)
        )
  @spec pin_destination(Sync.t(), String.t(), String.t() | nil) ::
          {:ok, Sync.t()} | {:error, Ecto.Changeset.t()}
  def pin_destination(%Sync{destination_playlist_id: nil} = sync, playlist_id, name)
      when is_binary(playlist_id) do
    sync
    |> Sync.run_changeset(%{
      destination_playlist_id: playlist_id,
      destination_playlist_name: name
    })
    |> Repo.update()
  end

  # Named `sync` like the clause above rather than `pinned`: Bond canonicalises a
  # contract's parameter names across every clause of the function, and two
  # clauses disagreeing at a position is a compile error.
  def pin_destination(%Sync{} = sync, _playlist_id, _name), do: {:ok, sync}

  # A transfer built from the standing instruction. The destination id is
  # carried across where there is one, which is what makes every run after the
  # first resume into the same playlist rather than making another.
  defp transfer_attrs(%Sync{} = sync) do
    %{
      sync_id: sync.id,
      mode: sync.mode,
      user_id: sync.user_id,
      source_provider: sync.source_provider,
      source_playlist_id: sync.source_playlist_id,
      source_playlist_name: sync.source_playlist_name,
      destination_provider: sync.destination_provider,
      destination_playlist_id: sync.destination_playlist_id,
      destination_playlist_name: sync.destination_playlist_name
    }
  end
end
