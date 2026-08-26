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

  ## The threshold is always a proportion

  `threshold_is_a_proportion` holds for every report however it was built, which
  is a different surface from `OnePlaylist.Matching.threshold/1`'s postcondition:
  `match/3` resolves a threshold and never builds a report, while a report
  assembled by hand never goes near `threshold/1`. Neither is reachable from the
  other.

  The consequence of a bad one is total and silent. At `75.0` no score can clear
  it, so every track is reported unmatched, the transfer completes, and the
  destination playlist is empty — and `match_rate/1` then divides by a total made
  entirely of failures and answers `0.0`, which reads as a catalogue containing
  none of the user's music rather than as a misconfiguration.
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

  # The `defstruct` default of `0.0` satisfies it, per Meyer's base case. A bare
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

  Always a proportion — what the function *means*, and what a caller comparing
  two reports relies on.
  """
  # Not omitted as implied by the arithmetic: `length(matched)` and `total/1` are
  # two counts a plausible rewrite could take from different places, and the
  # inverted-division typo is the obvious one.
  @post is_a_proportion: result >= 0.0 and result <= 1.0
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
