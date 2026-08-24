defmodule OnePlaylist.Catalogue do
  @moduledoc """
  Facts about the world's record catalogue, cached in two tiers.

  Currently one fact: which album a barcode is, at a given provider. The
  resolution cache `docs/reference/domain.md` describes —
  `(source, id) → (destination, id, confidence)` — is the same shape and
  belongs here beside it.

  ## Why two tiers

  | | Where | Cost of a hit | Survives |
  | --- | --- | --- | --- |
  | L1 | `OnePlaylist.Cache` (Nebulex, per node) | ~65 ns | nothing |
  | L2 | Postgres, shared | ~1 ms | deploys, restarts, other nodes |
  | — | the provider | 100–500 ms **and quota** | — |

  L1 alone does not scale, for reasons that get worse rather than better as the
  application succeeds:

    * it is per node, so scaling out means N caches learning the same global
      facts independently — adding capacity makes each one *less* effective;
    * it dies on every deploy, so a team shipping five times a day buys the
      working set back from a provider's quota five times a day;
    * the data is user-independent, and storing it per node is the opposite of
      the asset that compounds.

  L2 fixes all three, and it costs a single indexed primary-key read. A cold
  node refills from Postgres at millisecond cost instead of from a provider at
  quota cost.

  ## Negative results are cached, and only they expire

  "This provider does not carry this barcode" is worth remembering — otherwise
  every track on that release re-asks. But unlike a positive result it can stop
  being true, because catalogues gain releases. So negatives carry a TTL in L1
  and are pruned in L2 by `pg_cron`; positives do neither.

  ## What is not cached

  Errors. A failed request says nothing about the catalogue, and remembering
  one would turn a transient outage into a permanent hole in matching.
  """

  use Bond

  import Ecto.Query

  alias OnePlaylist.Cache
  alias OnePlaylist.Catalogue.ReleaseLookup
  alias OnePlaylist.Music.Barcode
  alias OnePlaylist.Repo

  require Logger

  # Long enough that a busy transfer never re-asks, short enough that a release
  # added to a catalogue today is findable within the week. L2's pruning is the
  # authority; this only bounds how long one node can hold a stale "no".
  @negative_ttl :timer.hours(24)

  @doc """
  The provider's album id for a barcode, or `nil` if it does not carry it.

  `lookup` is called only on a miss in both tiers, and only once per key even
  if a hundred callers miss together — see `OnePlaylist.Cache.read_through/3`.
  It must return `{:ok, album_id | nil}` or `{:error, reason}`.

      Catalogue.album_id(:tidal, "602547670052", fn ->
        Client.album_by_barcode(token, "602547670052", country: "US")
      end)
  """
  # An unnormalized barcode is not a wrong answer, it is a *different cache key*
  # for the same release — so a caller that skips normalization silently gets
  # its own private copy of every lookup, doubles the provider calls it was
  # meant to save, and writes a second row for a release that already has one.
  # Nothing raises and nothing is incorrect; the cache simply stops working, in
  # a way that only shows up as a bill.
  #
  # This is why preconditions stay enabled in production: it names the caller's
  # bug at the boundary, and it is the caller, not this module, that can fix it.
  @pre normalized_barcode: barcode == Barcode.normalize(barcode)
  @spec album_id(atom(), String.t(), (-> {:ok, String.t() | nil} | {:error, term()})) ::
          {:ok, String.t() | nil} | {:error, term()}
  def album_id(provider, barcode, lookup)
      when is_atom(provider) and is_binary(barcode) and is_function(lookup, 0) do
    Cache.read_through(
      key(provider, barcode),
      fn -> from_l2_or_provider(provider, barcode, lookup) end,
      ttl_for_pending()
    )
  end

  @doc """
  Forgets what was remembered about a barcode, in both tiers.

  For the case a cached id stops working. A barcode identifies a release
  permanently, but a *provider's id* for that release can change — a re-ingest,
  a delisting — and the symptom is a 404 on the follow-up request rather than
  anything visible at lookup time. The caller that sees that 404 is the only
  one who knows, so it is the one that says so.
  """
  @pre normalized_barcode: barcode == Barcode.normalize(barcode)
  @spec forget(atom(), String.t()) :: :ok
  def forget(provider, barcode) do
    # Matched rather than discarded: a delete that silently failed would leave
    # L1 serving the stale id that prompted the call, which is the one outcome
    # this function exists to prevent.
    case Cache.delete(key(provider, barcode)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("cache delete failed for #{barcode}: #{inspect(reason)}")
    end

    Repo.delete_all(
      from(l in ReleaseLookup,
        where: l.provider == ^to_string(provider) and l.barcode == ^barcode
      )
    )

    :ok
  end

  @doc """
  Deletes negative entries older than `older_than`, returning how many.

  The same work `pg_cron` is scheduled to do, callable from Elixir for a
  deployment where the extension is not available — see the migration.
  """
  @spec prune_negatives(String.t()) :: non_neg_integer()
  def prune_negatives(older_than \\ "30 days") do
    # `$1::text::interval` rather than `$1::interval`: with the latter, Postgrex
    # infers the parameter type from the function signature and refuses to
    # encode a string as an interval. Casting from text lets Postgres do the
    # parsing, which is where interval syntax belongs anyway.
    %{rows: [[removed]]} =
      Repo.query!("select public.prune_catalogue_release_lookups($1::text::interval)", [
        older_than
      ])

    removed
  end

  defp from_l2_or_provider(provider, barcode, lookup) do
    case fetch_l2(provider, barcode) do
      {:ok, album_id} ->
        {:ok, album_id}

      :miss ->
        with {:ok, album_id} <- lookup.() do
          remember(provider, barcode, album_id)
          {:ok, album_id}
        end
    end
  end

  defp fetch_l2(provider, barcode) do
    case Repo.get_by(ReleaseLookup, provider: to_string(provider), barcode: barcode) do
      nil -> :miss
      %ReleaseLookup{provider_album_id: album_id} -> {:ok, album_id}
    end
  end

  # `on_conflict: :nothing` rather than a replace: two nodes learning the same
  # fact at the same moment is expected and their answers agree, so the loser
  # has nothing to correct. It also keeps `looked_up_at` meaning "when we first
  # learned this", which is what the negative TTL wants.
  defp remember(provider, barcode, album_id) do
    Repo.insert(
      %ReleaseLookup{
        provider: to_string(provider),
        barcode: barcode,
        provider_album_id: album_id,
        looked_up_at: DateTime.utc_now()
      },
      on_conflict: :nothing,
      conflict_target: [:provider, :barcode]
    )
  end

  # A TTL cannot be decided before the value is known, and Nebulex takes it at
  # write time — so this bounds every entry at the negative TTL and lets the
  # positives be refreshed for free by L2 when they lapse. A positive that
  # expires from L1 costs one Postgres read, not one provider call, which is
  # the whole point of having L2.
  defp ttl_for_pending, do: [ttl: @negative_ttl]

  defp key(provider, barcode), do: {:release, provider, barcode}
end
