defmodule OnePlaylist.Transfers.Transfer do
  @moduledoc """
  One playlist being moved from one service to another, and its ledger.

  ## The counters are the report

  Four numbers, and a contract that keeps them honest:

      matched + unmatched == total
      added <= matched

  The first is the conservation law this whole application is organised
  around — a transfer that finished, reported success, and lost a track is the
  failure `docs/reference/contracts.md` opens with. Stated as an
  `@invariant`, it holds on every value this module produces, so a counter
  update that forgets its opposite number cannot be persisted.

  The second is not redundant with it. `added` counts what was *written*, and
  a matched track already present at the destination is matched but not added —
  which is exactly what idempotency means here, and why a re-run of a completed
  transfer adds nothing while still matching everything.

  ## Why the counters are updated through functions

  `record_matched/2` and friends exist so the law has somewhere to be checked.
  A changeset that set `matched_count` directly would bypass it, and the
  arithmetic would live at each call site — which is how two of these four
  numbers end up disagreeing.

  > #### This wants to be an `@invariant`, and cannot be {: .info}
  >
  > A struct `@invariant` is the natural home: the law is about every value of
  > the type, not about three particular functions. But Bond weaves invariant
  > checks into *every* public function of the declaring module, and on an
  > `Ecto.Schema` that includes the generated `__schema__/2` — which then fails
  > to compile with `undefined variable "bond_arg_1"`.
  >
  > So the law is stated as postconditions on the three functions that produce a
  > transfer, which covers the same ground for anything this module builds. See
  > `docs/library-feedback.md`.
  """

  use Ecto.Schema
  use Bond

  import Ecto.Changeset

  alias OnePlaylist.Providers.Connection

  @statuses ~w(pending running completed failed)a

  @type status :: :pending | :running | :completed | :failed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          source_provider: Connection.provider() | nil,
          source_playlist_id: String.t() | nil,
          destination_provider: Connection.provider() | nil,
          destination_playlist_id: String.t() | nil,
          status: status(),
          threshold: float() | nil,
          total_tracks: non_neg_integer(),
          matched_count: non_neg_integer(),
          added_count: non_neg_integer(),
          unmatched_count: non_neg_integer()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "transfers" do
    field :user_id, Ecto.UUID

    field :source_provider, Ecto.Enum, values: Connection.providers()
    field :source_playlist_id, :string
    field :source_playlist_name, :string

    field :destination_provider, Ecto.Enum, values: Connection.providers()
    field :destination_playlist_id, :string
    field :destination_playlist_name, :string

    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :threshold, :float

    field :total_tracks, :integer, default: 0
    field :matched_count, :integer, default: 0
    field :added_count, :integer, default: 0
    field :unmatched_count, :integer, default: 0

    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :last_error, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The statuses a transfer can be in."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "A transfer that has stopped, successfully or not."
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{status: status}), do: status in [:completed, :failed]

  @doc "Changeset for creating a transfer."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [
      :user_id,
      :source_provider,
      :source_playlist_id,
      :source_playlist_name,
      :destination_provider,
      :destination_playlist_id,
      :destination_playlist_name,
      :threshold
    ])
    |> validate_required([
      :user_id,
      :source_provider,
      :source_playlist_id,
      :destination_provider,
      :threshold
    ])
    |> validate_number(:threshold, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end

  @doc """
  Zeroes the counters, keeping everything else.

  A run computes the ledger from scratch — it re-reads the source, re-resolves
  every track and re-diffs the destination — so a *re*-run must start from zero
  rather than adding to what the previous run recorded.

  This is not a hypothetical tidiness. Without it the second run of a
  three-track transfer reports six matched out of three total, and the
  `ledger_balances` postcondition on `record_matched/2` catches it on the very
  first track. That is how this function came to exist.
  """
  @spec reset_counters(t()) :: t()
  def reset_counters(%__MODULE__{} = transfer),
    do: %{transfer | matched_count: 0, added_count: 0, unmatched_count: 0, total_tracks: 0}

  @doc """
  Records how many tracks the source playlist turned out to hold.

  Separate from creation because a transfer is queued before anything has read
  the source, and the count is the first thing the run establishes.
  """
  @post ledger_balances: balanced?(result)
  @spec with_total(t(), non_neg_integer()) :: t()
  def with_total(%__MODULE__{} = transfer, total) when is_integer(total) and total >= 0,
    do: %{transfer | total_tracks: total}

  @doc """
  Records one track resolved to a destination track.

  `added?` distinguishes a track written from one already present — the
  difference between a first run and a re-run, and the reason `added_count` is
  not simply `matched_count`.
  """
  @post ledger_balances: balanced?(result),
        added_at_most_matched: result.added_count <= result.matched_count,
        counted_exactly_one: result.matched_count == transfer.matched_count + 1
  @spec record_matched(t(), boolean()) :: t()
  def record_matched(%__MODULE__{} = transfer, added?) do
    %{
      transfer
      | matched_count: transfer.matched_count + 1,
        added_count: transfer.added_count + if(added?, do: 1, else: 0)
    }
  end

  @doc "Records one track that could not be resolved confidently."
  @post ledger_balances: balanced?(result),
        counted_exactly_one: result.unmatched_count == transfer.unmatched_count + 1
  @spec record_unmatched(t()) :: t()
  def record_unmatched(%__MODULE__{} = transfer),
    do: %{transfer | unmatched_count: transfer.unmatched_count + 1}

  @doc """
  The proportion of the source that reached the destination.

  A transfer with nothing in it rates `1.0`: nothing was asked for and nothing
  was lost. The same choice as `OnePlaylist.Matching.Report.match_rate/1`, and
  for the same reason — reporting a perfect transfer of no tracks as a total
  failure is the less useful lie.
  """
  @spec match_rate(t()) :: float()
  def match_rate(%__MODULE__{total_tracks: 0}), do: 1.0

  def match_rate(%__MODULE__{} = transfer),
    do: transfer.matched_count / transfer.total_tracks

  @doc """
  The counters, in the shape `OnePlaylist.Transfers.TransferItem.tally/1`
  produces.

  Exists so the two can be compared. A transfer's counters and its report are
  accumulated by separate folds over the same resolutions, and until this pair
  existed nothing checked that they came out agreeing — see the precondition on
  `OnePlaylist.Transfers.record_run/3`.
  """
  @spec tally(t()) :: %{
          total: non_neg_integer(),
          matched: non_neg_integer(),
          added: non_neg_integer(),
          unmatched: non_neg_integer()
        }
  def tally(%__MODULE__{} = transfer) do
    %{
      total: transfer.total_tracks,
      matched: transfer.matched_count,
      added: transfer.added_count,
      unmatched: transfer.unmatched_count
    }
  end

  @doc """
  Whether a transfer's counters are consistent with each other.

  Public because the postconditions above name it, and an assertion rendered
  into the documentation should reference something a reader can look up.

  `<=` rather than `==` because a transfer legitimately passes through partial
  states while a run is in progress. The stronger equality belongs where the run
  is over, and is asserted there — on
  `OnePlaylist.Transfers.Runner.run/1`.
  """
  @spec balanced?(t()) :: boolean()
  def balanced?(%__MODULE__{} = transfer) do
    counted = transfer.matched_count + transfer.unmatched_count

    counted >= 0 and transfer.added_count >= 0 and transfer.total_tracks >= 0 and
      (transfer.total_tracks == 0 or counted <= transfer.total_tracks)
  end

  @doc "Changeset for persisting the counters and status a run produced."
  @spec progress_changeset(t(), map()) :: Ecto.Changeset.t()
  def progress_changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [
      :status,
      :destination_playlist_id,
      :destination_playlist_name,
      :source_playlist_name,
      :total_tracks,
      :matched_count,
      :added_count,
      :unmatched_count,
      :started_at,
      :completed_at,
      :last_error
    ])
    |> validate_required([:status])
  end
end
