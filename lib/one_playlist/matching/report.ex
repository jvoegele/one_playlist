defmodule OnePlaylist.Matching.Report do
  @moduledoc """
  What happened when a set of tracks was matched.

  Every source track lands in exactly one of `matched` or `unmatched` — that is
  the point of the type, and it is enforced by a contract on
  `OnePlaylist.Matching.match_all/2` rather than left as an intention. A
  transfer report that does not add up is the failure this whole application is
  organised against.

  `unmatched` holds `OnePlaylist.Matching.TrackNotMatched` errors rather than
  bare tracks, so each carries its own reason: not found at all, found but not
  confident enough, or too little information to search with.
  """

  use Bond

  alias OnePlaylist.Matching.Match
  alias OnePlaylist.Matching.TrackNotMatched

  @type t :: %__MODULE__{
          matched: [Match.t()],
          unmatched: [TrackNotMatched.t()],
          threshold: float()
        }

  @enforce_keys [:threshold]
  defstruct matched: [], unmatched: [], threshold: 0.0

  # `OnePlaylist.Matching.threshold/1` already asserts this about the value it
  # *returns*, and this is not that assertion repeated — it is the same law
  # lifted to where it belongs, on the type, so it holds for every report
  # however the report was built.
  #
  # The two cover different surfaces, which is what stops this being the "two
  # guards" mistake in `docs/reference/contracts.md`. `match/3` resolves a
  # threshold and never builds a report, so only the postcondition guards that
  # path; a report assembled by hand — a fixture, a future caller, a second
  # construction site — never goes near `threshold/1`, so only the invariant
  # guards that one. Neither is reachable from the other, and each has its own
  # test.
  #
  # The consequence of a bad threshold is total and silent: at `75.0` no score
  # can clear it, so every track is reported unmatched, the transfer completes,
  # and the destination playlist is empty. `match_rate/1` then divides by a
  # total made entirely of failures and answers `0.0`, which reads as a
  # catalogue that contains none of the user's music rather than as a
  # misconfiguration.
  #
  # The `defstruct` default of `0.0` satisfies it, per Meyer's base case: a bare
  # `%Report{}` is not constructible anyway — `:threshold` is enforced — but the
  # default is part of the contract regardless of whether it can be reached.
  @invariant threshold_is_a_proportion:
               is_float(subject.threshold) and subject.threshold >= 0.0 and
                 subject.threshold <= 1.0

  @doc "How many tracks were considered."
  @spec total(t()) :: non_neg_integer()
  def total(%__MODULE__{} = report),
    do: length(report.matched) + length(report.unmatched)

  @doc """
  The proportion that matched, as a float in `0.0..1.0`.

  An empty report rates `1.0`: nothing was asked for and nothing was lost.
  Returning `0.0` would report a perfect transfer of no tracks as a total
  failure.
  """
  @spec match_rate(t()) :: float()
  def match_rate(%__MODULE__{} = report) do
    case total(report) do
      0 -> 1.0
      count -> length(report.matched) / count
    end
  end

  @doc "Matches grouped by confidence, for a review screen."
  @spec by_confidence(t()) :: %{Match.confidence() => [Match.t()]}
  def by_confidence(%__MODULE__{} = report),
    do: Enum.group_by(report.matched, & &1.confidence)

  @doc """
  The matches a person should look at before the transfer runs.

  Everything that cleared the threshold but is below `minimum` — the middle
  band that `docs/reference/domain.md` argues should be reviewed rather than
  either trusted or discarded.
  """
  @spec needs_review(t(), Match.confidence()) :: [Match.t()]
  def needs_review(%__MODULE__{} = report, minimum \\ :high),
    do: Enum.reject(report.matched, &Match.at_least?(&1, minimum))

  @doc """
  Matches where more than one candidate scored identically.

  Worth surfacing separately: the engine picked one deterministically and
  recorded why, but a tie means the evidence did not actually distinguish them.
  The first live ISRC lookup this project ran returned two catalogue entries
  for one identifier, so this is the common case rather than the exotic one.
  """
  @spec ambiguous(t()) :: [Match.t()]
  def ambiguous(%__MODULE__{} = report),
    do: Enum.filter(report.matched, &(&1.alternatives > 0))
end
