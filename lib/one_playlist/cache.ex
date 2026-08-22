defmodule OnePlaylist.Cache do
  @moduledoc """
  L1 of the catalogue cache: in memory, per node, bounded.

  ## Why Nebulex here and not for L2

  `Nebulex.Adapters.Local` is a **generational** cache, and that is the whole
  reason for the dependency. The hand-rolled ETS table this replaced bounded
  itself by emptying completely at a cap, which is the worst possible behaviour
  once the working set exceeds the bound: a successful application would throw
  away everything it knew and buy it back from a provider's quota, over and
  over. Generational eviction drops the oldest generation instead, so a full
  cache loses a fraction and keeps the hot set — approximate LRU without
  per-read bookkeeping.

  It also bounds by memory as well as by count, which is the bound that
  actually matters, and neither is something worth hand-rolling badly.

  L2 deliberately does **not** go through Nebulex. `nebulex_adapters_ecto`
  exists but requires `nebulex ~> 2.5`, so using it would pin this project to
  an older Nebulex — and more importantly, L2 is not really a cache. It is the
  shared catalogue asset `docs/reference/domain.md` describes: it carries our
  RLS conventions, is pruned by `pg_cron`, and is meant to be queried directly.
  Hiding it behind an opaque cache adapter would fight all three. See
  `OnePlaylist.Catalogue`.

  ## Sizing

  Measured at **120 bytes per entry** for a barcode-to-id mapping, and 65 ns
  per lookup — ETS is nowhere near being the constraint. The configured bounds
  are in `config/config.exs` and are set by memory budget rather than by a
  guessed entry count.
  """

  use Nebulex.Cache,
    otp_app: :one_playlist,
    adapter: Nebulex.Adapters.Local

  alias OnePlaylist.Cache.Singleflight

  require Logger

  @doc """
  Reads `key`, computing and caching it on a miss — once, however many callers
  miss at the same moment.

  Nebulex has no request coalescing of its own, and a cache without it is a
  quota amplifier under exactly the load a cache is for: ten concurrent misses
  on one key become ten provider calls. `OnePlaylist.Cache.Singleflight`
  supplies that, and this is where the two are joined.

  `fun` returns `{:ok, value}` or `{:error, reason}`. Only `{:ok, value}` is
  cached — an error says nothing about the catalogue, and remembering one would
  turn a transient outage into a permanent hole.

  ## Options

  Passed through to `put/3`, so `:ttl` works here as it does there.
  """
  @spec read_through(term(), (-> {:ok, value} | {:error, term()}), keyword()) ::
          {:ok, value} | {:error, term()}
        when value: term()
  def read_through(key, fun, opts \\ []) when is_function(fun, 0) do
    case fetch(key) do
      {:ok, value} -> {:ok, value}
      {:error, _not_found} -> Singleflight.run(key, fn -> fill(key, fun, opts) end)
    end
  end

  # Runs inside the critical section, so it checks again first: between the miss
  # that sent us here and becoming the key's owner, another owner may have
  # finished and filled it — in which case the work is already done and paid
  # for.
  defp fill(key, fun, opts) do
    case fetch(key) do
      {:ok, value} -> {:ok, value}
      {:error, _still_missing} -> compute(key, fun, opts)
    end
  end

  defp compute(key, fun, opts) do
    with {:ok, value} <- fun.() do
      remember(key, value, opts)
      {:ok, value}
    end
  end

  # A cache that cannot write is slower, not wrong: the value was computed
  # correctly and the caller should have it. So a failed write is logged and
  # swallowed rather than turned into a failed request — but it is matched
  # explicitly, because the difference between "handled" and "ignored" should be
  # visible in the code rather than inferred from its absence.
  defp remember(key, value, opts) do
    case put(key, value, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("cache write failed for #{inspect(key)}: #{inspect(reason)}")

        :ok
    end
  end
end
