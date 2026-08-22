defmodule OnePlaylist.Providers.Tidal.AlbumCache do
  @moduledoc """
  Remembers which TIDAL album a barcode identifies.

  ## Why this exists, and why it is not a concurrency problem

  Rung 2 of the matching ladder costs two requests per track — find the album
  by barcode, then read its items. The obvious way to make that bearable is to
  run the requests concurrently, and it is the wrong lever. `ExternalService`
  already provides concurrency; parallelism reduces wall-clock while consuming
  **exactly the same quota**, and TIDAL publishes no rate limit while community
  reports put 429s as common on catalogue reads. Worse, the circuit breaker is
  shared across every user of this application, so one large transfer bursting
  catalogue reads degrades TIDAL for everyone.

  The lever that reduces the actual constraint is making fewer requests. Tracks
  cluster into albums — 38 distinct albums across the 60 tracks of
  `test/support/fixtures/tidal_isrc_corpus.json`, and far fewer on an
  album-oriented playlist — so remembering the first lookup removes most of the
  rest.

  ## No expiry, deliberately

  A barcode identifies a *release*, permanently. The mapping from one to a
  TIDAL album id cannot become wrong; at worst it can become incomplete, which
  a cache miss handles. So there is no TTL and no invalidation to get wrong.

  A negative result is cached too, and is the more valuable half: a barcode
  TIDAL does not carry would otherwise be looked up again for every track on
  that album, spending a request each time to learn the same nothing.

  ## Scope

  In memory, per node, lost on restart. That is the right size for what it
  does — the entries are two short strings and the benefit is within a transfer
  and across transfers on one machine.

  The cross-user, compounding version of this belongs in Postgres alongside the
  `(source, id) → (destination, id, confidence)` resolution cache that
  `docs/reference/domain.md` describes, because a barcode's album id is
  identical for every user and never invalidates. That is a larger design than
  this, and shares its shape; building it here first would mean building it
  twice.
  """

  use GenServer

  @table __MODULE__

  # Entries are tiny, but an unbounded cache on a long-running node is a leak
  # with a slow fuse. At the cap the table is emptied rather than evicted by
  # age: without a TTL there is no age to evict by, and for a pure memo of an
  # immutable mapping, starting over costs only the lookups it would have
  # saved.
  @max_entries 50_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The album id for a barcode, computing and remembering it on a miss.

  `lookup` is expected to return `{:ok, album_id | nil}` or `{:error, term}`.
  An error is **not** cached: a failed request says nothing about the
  catalogue, and remembering it would turn a transient outage into a permanent
  hole in matching.
  """
  @spec fetch(String.t(), (-> {:ok, String.t() | nil} | {:error, term()})) ::
          {:ok, String.t() | nil} | {:error, term()}
  def fetch(barcode, lookup) when is_binary(barcode) and is_function(lookup, 0) do
    case :ets.lookup(@table, barcode) do
      [{^barcode, album_id}] ->
        {:ok, album_id}

      [] ->
        with {:ok, album_id} <- lookup.() do
          put(barcode, album_id)
          {:ok, album_id}
        end
    end
  rescue
    # The table is gone, which in practice means the application is not started
    # — a plain `mix run` script, or a test that does not need it. Answering
    # from the source of truth is strictly better than failing.
    ArgumentError -> lookup.()
  end

  @doc "Remembers a barcode's album id, `nil` included."
  @spec put(String.t(), String.t() | nil) :: :ok
  def put(barcode, album_id) do
    if :ets.info(@table, :size) >= @max_entries, do: :ets.delete_all_objects(@table)

    :ets.insert(@table, {barcode, album_id})
    :ok
  end

  @doc """
  Empties the cache.

  For tests that count requests, where a memo from an earlier test would make
  the count wrong.
  """
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "How many barcodes are remembered."
  @spec size() :: non_neg_integer()
  def size do
    :ets.info(@table, :size)
  rescue
    ArgumentError -> 0
  end

  @impl true
  def init(_opts) do
    table = @table

    # Owned by this process so it dies with the supervision tree rather than
    # outliving it. Public because every request process reads it directly —
    # routing reads through a GenServer would make one process the bottleneck
    # for a cache whose entire purpose is to be cheap.
    #
    # The result is matched against the name rather than discarded: a named
    # table returns its own name, so this asserts the table is the one every
    # other function in this module goes on to address by that name.
    ^table =
      :ets.new(@table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{}}
  end
end
