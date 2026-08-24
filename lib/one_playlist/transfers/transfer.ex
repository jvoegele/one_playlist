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

  ## Value laws are invariants; transition laws are postconditions

  The two laws above are about **every value** of this type, so they are an
  `@invariant` — including for a transfer read back from the database or built
  by a test, neither of which passes through the functions below.

  `balanced?/1` uses `<=` rather than `==` precisely so that it is true of an
  in-flight transfer as well as a finished one. The stronger equality is not a
  property of the type — a half-run transfer would violate it — so it lives
  where the run is over, on `OnePlaylist.Transfers.Runner.run/1`.

  What stays a postcondition is `counted_exactly_one`, which is a claim about a
  *transition* rather than a value: it relates the result to the argument, which
  is something no invariant can see.

  (This needs **bond 1.15.0 or later**. Earlier versions cannot weave an
  `@invariant` onto an `Ecto.Schema` at all — weaving reaches the generated
  `__schema__/2` and fails to compile. See `docs/library-feedback.md`.)
  """

  use Ecto.Schema
  use Bond

  import Ecto.Changeset

  alias OnePlaylist.Providers.Connection

  # The conservation law this application is organised around, stated where it
  # belongs: on the type, not on the three functions that happen to build one.
  #
  # `balanced?/1` is deliberately reachable from here. Meyer's Assertion
  # Evaluation rule means its own woven invariant is suppressed while this
  # assertion runs, so there is no recursion — and the predicate stays public
  # because an assertion rendered into the documentation should name something a
  # reader can look up.
  #
  # A bare `%Transfer{}` satisfies both: every counter defaults to zero, which is
  # Meyer's base case for a struct invariant and the thing most often gotten
  # wrong.
  @invariant ledger_balances: balanced?(subject),
             # Not implied by the first. `added` counts what was *written*, and a
             # matched track already present at the destination is matched but
             # not added — which is what idempotency means here, and why a re-run
             # adds nothing while still matching everything.
             added_at_most_matched: subject.added_count <= subject.matched_count

  @statuses ~w(pending running completed failed)a

  @type status :: :pending | :running | :completed | :failed

  @typedoc """
  Where a transfer's tracks come from.

  Wider than `t:OnePlaylist.Providers.Connection.provider/0` by exactly one
  value. A destination is a `Connection.provider()` and nothing else, because
  exporting to a file needs no matching and lives in `OnePlaylist.Exports`.
  """
  @type source_provider :: Connection.provider() | :file

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          source_provider: source_provider() | nil,
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

    # `:file` is a source and never a destination, and the asymmetry is the
    # design rather than an omission. Importing a file means matching sparse
    # metadata against a real catalogue, which is what this pipeline is for.
    # Exporting to a file means no matching at all — no catalogue to search,
    # nothing to be idempotent about, a report that would say `matched` on every
    # row — so it lives in `OnePlaylist.Exports` instead.
    #
    # Not in `Connection.providers()`, because a file is not something a user
    # connects to. The column is plain `text` with no check constraint, so this
    # list is enforced by Ecto alone and needed no migration.
    field :source_provider, Ecto.Enum, values: Connection.providers() ++ [:file]
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
  # Genuinely not about a transfer: it answers what the `status` field may hold,
  # which is a fact about the type rather than about any value of it. There is no
  # struct to check on the way in or out, so the invariant has nothing to say.
  @bond_warn_skipped_invariants false
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "A transfer that has stopped, successfully or not."
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{status: status}), do: status in [:completed, :failed]

  @doc "Changeset for creating a transfer."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = transfer, attrs) do
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
  `ledger_balances` invariant catches it on the very first track that
  `record_matched/2` counts.
  """
  @spec reset_counters(t()) :: t()
  def reset_counters(%__MODULE__{} = transfer),
    do: %{transfer | matched_count: 0, added_count: 0, unmatched_count: 0, total_tracks: 0}

  @doc """
  Records how many tracks the source playlist turned out to hold.

  Separate from creation because a transfer is queued before anything has read
  the source, and the count is the first thing the run establishes.
  """
  @spec with_total(t(), non_neg_integer()) :: t()
  def with_total(%__MODULE__{} = transfer, total) when is_integer(total) and total >= 0,
    do: %{transfer | total_tracks: total}

  @doc """
  Records one track resolved to a destination track.

  `added?` distinguishes a track written from one already present — the
  difference between a first run and a re-run, and the reason `added_count` is
  not simply `matched_count`.
  """
  # `ledger_balances` and `added_at_most_matched` are the module `@invariant` and
  # are not repeated here. What is left is the transition claim, which an
  # invariant cannot express: it relates the result to the argument.
  @post counted_exactly_one: result.matched_count == transfer.matched_count + 1
  @spec record_matched(t(), boolean()) :: t()
  def record_matched(%__MODULE__{} = transfer, added?) do
    %{
      transfer
      | matched_count: transfer.matched_count + 1,
        added_count: transfer.added_count + if(added?, do: 1, else: 0)
    }
  end

  @doc "Records one track that could not be resolved confidently."
  @post counted_exactly_one: result.unmatched_count == transfer.unmatched_count + 1
  @spec record_unmatched(t()) :: t()
  def record_unmatched(%__MODULE__{} = transfer),
    do: %{transfer | unmatched_count: transfer.unmatched_count + 1}

  @doc """
  Moves one track from unmatched to matched and added.

  What a correction does to the ledger. The track was reported as unmatched, a
  person chose a destination track for it by hand, and that track has been
  written — so all three counters move at once and the total does not.

  Only for a track that was genuinely unmatched. Correcting one that already
  matched changes *which* track was added rather than how many were, and moves
  no counter at all.
  """
  # The three counters are separate columns, so nothing but this makes them move
  # together. Stated as two postconditions rather than one because they fail
  # separately: forgetting the decrement leaves the summary claiming an
  # unmatched track that the report now shows as matched, and forgetting the
  # increment loses the added track from the count of what was written.
  #
  # The module invariant catches neither on its own — `matched + unmatched` is
  # unchanged by moving one from one to the other, which is precisely why it
  # balances either way.
  @post one_fewer_unmatched: result.unmatched_count == transfer.unmatched_count - 1
  @post one_more_matched_and_added:
          result.matched_count == transfer.matched_count + 1 and
            result.added_count == transfer.added_count + 1
  @spec record_correction(t()) :: t()
  def record_correction(%__MODULE__{} = transfer) do
    %{
      transfer
      | unmatched_count: transfer.unmatched_count - 1,
        matched_count: transfer.matched_count + 1,
        added_count: transfer.added_count + 1
    }
  end

  @doc """
  Records that a track the destination already held is now one this run wrote.

  What correcting an `:already_present` row does to the ledger. The row resolved
  before and still resolves, so `matched_count` does not move; what changes is
  that this transfer has now written something for it, which `added_count`
  counts and `:already_present` deliberately did not.

  Distinct from `record_correction/1`, which moves a row that did not resolve at
  all, and from correcting a `:matched` row, which replaces one written track
  with another and moves nothing.
  """
  # `added_at_most_matched` is the module invariant and is the real guard here:
  # this is the one transition that raises `added_count` without raising
  # `matched_count`, so an off-by-one — calling it for a row that was already
  # `:matched` — pushes added past matched and is caught on the way out rather
  # than surfacing as "104% of the source" on the report.
  @post one_more_added: result.added_count == transfer.added_count + 1
  @post resolved_count_is_unchanged:
          result.matched_count == transfer.matched_count and
            result.unmatched_count == transfer.unmatched_count
  @spec record_write(t()) :: t()
  def record_write(%__MODULE__{} = transfer),
    do: %{transfer | added_count: transfer.added_count + 1}

  @doc """
  The proportion of the source that reached the destination.

  A transfer with nothing in it rates `1.0`: nothing was asked for and nothing
  was lost. The same choice as `OnePlaylist.Matching.Report.match_rate/1`, and
  for the same reason — reporting a perfect transfer of no tracks as a total
  failure is the less useful lie.
  """
  # A rate above 1.0 is not a rounding artefact, it is a ledger that does not add
  # up — and `OnePlaylistWeb.TransferLive.Show` renders it as "150% of the
  # source" rather than as an error. The counters are independent columns rather
  # than values derived from one list, so this is reachable from any write that
  # skips `record_matched/2`: a migration, a manual fix, a future writer. A
  # re-run accumulating onto the previous run's numbers gets there in one step —
  # six matched of three total — which is what `reset_counters/1` prevents.
  #
  # Raising here is the intended behaviour rather than a regrettable side
  # effect. The alternative is rendering a number this application knows to be
  # false, which is the one failure mode it is organised against — and now that
  # `record_run/3` checks the ledger before writing it, an inconsistent row is a
  # genuine "cannot happen" rather than an inconvenience.
  #
  # `>=` on the lower bound rather than `>`, because zero matched of ten is a
  # real and reportable outcome.
  @post is_a_proportion: result >= 0.0 and result <= 1.0
  @spec match_rate(t()) :: float()
  def match_rate(%__MODULE__{total_tracks: 0}), do: 1.0

  def match_rate(%__MODULE__{} = transfer),
    do: transfer.matched_count / transfer.total_tracks

  @doc """
  The counters, in the shape `OnePlaylist.Transfers.TransferItem.tally/1`
  produces.

  Exists so the two can be compared. A transfer's counters and its report are
  accumulated by separate folds over the same resolutions, and nothing else
  checks that they come out agreeing — see the precondition on
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

    # Each term, not only the sum. `counted >= 0` is satisfied by one matched
    # and minus one unmatched, which is not a transfer — it is a counter that
    # was decremented once too often. `record_correction/1` moves a track from
    # one column to another and is exactly the shape that can do it.
    transfer.matched_count >= 0 and transfer.unmatched_count >= 0 and
      transfer.added_count >= 0 and transfer.total_tracks >= 0 and
      (transfer.total_tracks == 0 or counted <= transfer.total_tracks)
  end

  @doc "Changeset for persisting the counters and status a run produced."
  @spec progress_changeset(t(), map()) :: Ecto.Changeset.t()
  def progress_changeset(%__MODULE__{} = transfer, attrs) do
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
