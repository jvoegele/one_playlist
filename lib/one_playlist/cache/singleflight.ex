defmodule OnePlaylist.Cache.Singleflight do
  @moduledoc """
  Runs one function per key at a time, however many callers ask at once.

  ## The problem it solves

  A cache miss under load is not one miss. Ten users transferring the same
  popular album at the same moment all miss, all call the provider, and all
  learn the same fact — nine requests spent on nothing, at exactly the moment
  the system is busiest. That is a quota amplifier, and for a provider whose
  rate limit is unpublished and whose circuit breaker is shared across every
  user of this application, it is the failure that spreads.

  So the first caller for a key becomes its **owner** and does the work. Every
  other caller for that key waits and is handed the owner's result.

  ## The work runs in the caller, not here

  This process never evaluates the function. The owner runs it in its own
  process and reports back, which matters for three reasons:

    * `ExternalService`'s rate limiting, breaker and bulkhead account against
      the calling process. Running the fetch here would move every provider
      call into one process and make this the bottleneck it exists to prevent.
    * A slow provider call would block every other key's coordination.
    * `Req.Test` stubs are resolved per-process, so a fetch moved into a task
      would stop seeing the stub the test registered — the suite would pass for
      the wrong reason, or fail confusingly.

  ## What happens when an owner dies

  Waiters are told, rather than left. The owner is monitored, and a crash or
  exit releases everyone waiting on that key with `{:error, :owner_exited}`.
  Leaving them to time out would turn one crashed request into N hung ones.

  A caller that gives up waiting simply stops waiting; the owner still
  completes and still populates the cache, so the work is not wasted.
  """

  use GenServer
  use Bond.Server

  require Logger

  @default_timeout :timer.seconds(30)

  # The state records one fact twice: a key's monitor reference lives both on
  # its `in_flight` entry and as a key of `monitors`, which exists so a `:DOWN`
  # can find the key it belongs to. Nothing else keeps the two in step, and
  # drift is silent in both directions — a `release/3` that forgot to delete
  # from `monitors` would leak a reference per completed fetch forever, and a
  # stale entry there would make a later, unrelated `:DOWN` release a key that
  # is legitimately in flight.
  #
  # This is `docs/reference/contracts.md`'s "two implementations of one rule"
  # shape, applied to state rather than to code — and unlike the cache this
  # coordinates, it is genuinely assertable, because a GenServer's state is
  # touched by one process and no interleaving can be observed mid-callback.
  @state_invariant one_monitor_per_in_flight_key:
                     map_size(state.monitors) == map_size(state.in_flight),
                   monitors_point_back_at_their_keys: monitors_agree?(state)

  # A message coordinates at most one key: an acquire adds one, a completion or
  # a `:DOWN` removes one, and anything else changes nothing. A `release/3`
  # rewritten to filter or reset the map — the shape that looks like tidying up
  # — would strand every other in-flight fetch's waiters until their timeouts,
  # which is exactly the failure this module exists to prevent, caused by the
  # module itself.
  @transition_invariant at_most_one_key_per_message:
                          abs(map_size(new_state.in_flight) - map_size(old_state.in_flight)) <= 1

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Runs `fun` for `key`, or waits for whoever is already running it.

  `fun` should return `{:ok, value}` or `{:error, reason}`; whatever it returns
  is what every waiter receives.

  The default timeout is #{div(@default_timeout, 1000)} seconds, chosen to
  exceed the longest a guarded provider call can take — a client receive
  timeout multiplied by the retry budget. A timeout shorter than the work it
  waits on would coalesce nothing and merely fail differently.
  """
  @spec run(term(), (-> result), timeout()) :: result when result: term()
  def run(key, fun, timeout \\ @default_timeout) when is_function(fun, 0) do
    case GenServer.call(__MODULE__, {:acquire, key}, timeout) do
      :owner ->
        try do
          result = fun.()
          GenServer.cast(__MODULE__, {:done, key, result})
          result
        catch
          kind, reason ->
            # Release the waiters before propagating, or they wait out the full
            # timeout for a result that is never coming.
            GenServer.cast(__MODULE__, {:done, key, {:error, :owner_exited}})
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:wait, ref} ->
        receive do
          {^ref, result} -> result
        after
          timeout -> {:error, :timeout}
        end
    end
  catch
    # No coordinator, so there is nothing to coalesce against. Doing the work
    # is strictly better than failing: the point of this module is to spend
    # less, not to be load-bearing.
    :exit, {:noproc, _call} ->
      fun.()
  end

  @doc """
  Whether every monitor reference in the state agrees with the key it indexes.

  Public because the state invariant names it, and an assertion rendered into
  the documentation should reference something a reader can look up.
  """
  @spec monitors_agree?(map()) :: boolean()
  def monitors_agree?(state) do
    Enum.all?(state.monitors, fn {monitor, key} ->
      match?(%{monitor: ^monitor}, Map.get(state.in_flight, key))
    end)
  end

  @impl true
  def init(_opts), do: {:ok, %{in_flight: %{}, monitors: %{}}}

  @impl true
  def handle_call({:acquire, key}, {pid, _tag} = from, state) do
    case Map.fetch(state.in_flight, key) do
      {:ok, %{waiters: waiters} = entry} ->
        ref = make_ref()
        {caller, _tag} = from
        entry = %{entry | waiters: [{caller, ref} | waiters]}

        {:reply, {:wait, ref}, put_in(state.in_flight[key], entry)}

      :error ->
        monitor = Process.monitor(pid)
        entry = %{owner: pid, monitor: monitor, waiters: []}

        {:reply, :owner,
         %{
           state
           | in_flight: Map.put(state.in_flight, key, entry),
             monitors: Map.put(state.monitors, monitor, key)
         }}
    end
  end

  @impl true
  def handle_cast({:done, key, result}, state), do: {:noreply, release(state, key, result)}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Map.fetch(state.monitors, monitor) do
      {:ok, key} ->
        # `:normal` here means the owner finished without reporting — it was
        # killed between the work and the cast, or it raised past the catch.
        Logger.debug("singleflight owner for #{inspect(key)} went down: #{inspect(reason)}")

        {:noreply, release(state, key, {:error, :owner_exited})}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp release(state, key, result) do
    case Map.pop(state.in_flight, key) do
      {nil, _in_flight} ->
        state

      {entry, in_flight} ->
        Process.demonitor(entry.monitor, [:flush])

        for {waiter, ref} <- entry.waiters, do: send(waiter, {ref, result})

        %{state | in_flight: in_flight, monitors: Map.delete(state.monitors, entry.monitor)}
    end
  end
end
