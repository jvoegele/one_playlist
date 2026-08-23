defmodule OnePlaylist.Transfers.TransferItem do
  @moduledoc """
  What happened to one track, and why.

  One row per track of the source playlist — which is the point. "Never
  silently drop a track" is a claim about the whole application, and this table
  is where it becomes checkable: a source track with no row here is a bug the
  database can be asked about, rather than an absence nobody notices.

  Three outcomes, and the distinction between the last two is the one that
  makes a report worth reading:

  | Outcome | Means |
  | --- | --- |
  | `:matched` | Resolved and written to the destination. |
  | `:already_present` | Resolved, and the destination already had it. |
  | `:unmatched` | Not resolved confidently. `reason` says which kind. |

  `:already_present` is what idempotency looks like from the report's side. A
  re-run of a completed transfer turns every `:matched` into
  `:already_present` and adds nothing — and a user looking at the report can
  see that is what happened, rather than wondering why the second run "did
  nothing".
  """

  use Ecto.Schema
  use Bond

  import Ecto.Changeset

  alias OnePlaylist.Matching.Match
  alias OnePlaylist.Music.Track

  @outcomes ~w(matched already_present unmatched)a

  @type outcome :: :matched | :already_present | :unmatched

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          transfer_id: Ecto.UUID.t() | nil,
          position: non_neg_integer() | nil,
          source_track_id: String.t() | nil,
          outcome: outcome() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "transfer_items" do
    field :transfer_id, :binary_id
    field :user_id, Ecto.UUID

    field :position, :integer

    field :source_track_id, :string
    field :source_title, :string
    field :source_artist, :string

    field :outcome, Ecto.Enum, values: @outcomes
    field :destination_track_id, :string
    field :confidence, :string
    field :score, :float
    field :strategy, :string
    field :reason, :string
    field :candidates_considered, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The outcomes an item can record."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc """
  Counts a set of report rows by what happened to them.

  The shape matches `OnePlaylist.Transfers.Transfer.tally/1` exactly, and that is
  the point: the counters on a transfer and the rows of its report are built by
  two separate folds over the same resolutions, and this is what lets them be
  compared rather than assumed to agree. See the precondition on
  `OnePlaylist.Transfers.record_run/3`.

  Accepts rows in either representation — the plain maps `matched/4` and
  `unmatched/4` return before they are written, and the `%TransferItem{}` structs
  that come back out of the database.

      iex> alias OnePlaylist.Transfers.TransferItem
      iex> TransferItem.tally([%{outcome: :matched}, %{outcome: :already_present}, %{outcome: :unmatched}])
      %{total: 3, matched: 2, added: 1, unmatched: 1}

  A row whose outcome is missing or unrecognised counts toward `total` and
  nothing else, which is deliberate: the comparison then fails and says so,
  rather than the tally raising from inside an assertion.
  """
  @spec tally(Enumerable.t()) :: %{
          total: non_neg_integer(),
          matched: non_neg_integer(),
          added: non_neg_integer(),
          unmatched: non_neg_integer()
        }
  def tally(items) do
    Enum.reduce(items, %{total: 0, matched: 0, added: 0, unmatched: 0}, fn item, acc ->
      acc = %{acc | total: acc.total + 1}

      case Map.get(item, :outcome) do
        # `matched_count` counts everything that resolved; `added_count` only
        # what was actually written. The difference is what a re-run looks like.
        :matched -> %{acc | matched: acc.matched + 1, added: acc.added + 1}
        :already_present -> %{acc | matched: acc.matched + 1}
        :unmatched -> %{acc | unmatched: acc.unmatched + 1}
        _absent_or_unrecognised -> acc
      end
    end)
  end

  @doc """
  The row for a track that resolved.

  `added?` decides between `:matched` and `:already_present`; everything else
  is copied off the `OnePlaylist.Matching.Match` so the report can explain the
  decision without re-running it.
  """
  # A report row is this application's product. `docs/reference/domain.md` argues
  # that explaining *what happened to every track* is what distinguishes it from
  # the incumbents, so a row that records an outcome without the evidence for it
  # is the feature failing quietly rather than a cosmetic problem.
  #
  # `names_what_it_matched` is the one that can fail on data. `provider_id` comes
  # from a mapper, and `to_string(nil)` is `""` — a provider that omits an id on
  # one entry yields a row saying "matched" while naming nothing, which is
  # exactly the shape `ids_are_usable_keys` guards on the adapter boundary.
  #
  # `outcome_is_a_resolution` is the specification of `added?`: a resolved track
  # is `:matched` when this run wrote it and `:already_present` when the
  # destination already had it, and never anything else. That distinction is what
  # makes a re-run legible in the report, per the table above.
  @post outcome_is_a_resolution: result.outcome in [:matched, :already_present],
        names_what_it_matched:
          is_binary(result.destination_track_id) and result.destination_track_id != ""
  @spec matched(map(), non_neg_integer(), Match.t(), boolean()) :: map()
  def matched(base, position, %Match{} = match, added?) do
    base
    |> common(position, match.source)
    |> Map.merge(%{
      outcome: if(added?, do: :matched, else: :already_present),
      destination_track_id: match.track.provider_id,
      confidence: to_string(match.confidence),
      score: match.score,
      strategy: to_string(match.strategy)
    })
  end

  @doc """
  The row for a track that did not resolve.

  Carries the reason and how many candidates were considered, because
  "nothing was found" and "four were found and none was good enough" are
  different problems with different fixes — and only the second is worth
  offering the user a manual choice for.
  """
  # The claim the docstring above makes, stated where it can be checked. An
  # unmatched row whose `reason` is blank renders as a track that failed for no
  # stated cause — which is precisely the row a user opens the report to read,
  # and the difference between "nothing was found" and "four were found and none
  # was good enough" is the difference between a dead end and a manual choice.
  @post outcome_is_unresolved: result.outcome == :unmatched,
        says_why: is_binary(result.reason) and result.reason != ""
  @spec unmatched(map(), non_neg_integer(), Track.t(), Exception.t()) :: map()
  def unmatched(base, position, %Track{} = source, error) do
    context = Errata.context(error)

    base
    |> common(position, source)
    |> Map.merge(%{
      outcome: :unmatched,
      reason: to_string(Errata.reason(error)),
      score: context[:best_score],
      confidence: context[:best_confidence] && to_string(context[:best_confidence]),
      candidates_considered: context[:candidates_considered]
    })
  end

  @doc false
  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :transfer_id,
      :user_id,
      :position,
      :source_track_id,
      :source_title,
      :source_artist,
      :outcome,
      :destination_track_id,
      :confidence,
      :score,
      :strategy,
      :reason,
      :candidates_considered
    ])
    |> validate_required([:transfer_id, :user_id, :position, :source_track_id, :outcome])
  end

  defp common(base, position, %Track{} = source) do
    Map.merge(base, %{
      position: position,
      source_track_id: source.provider_id,
      source_title: source.title,
      # The first credited artist only. The report is a list a person scans;
      # the full credit is on the source track if anyone needs it.
      source_artist: List.first(source.artists || [])
    })
  end
end
