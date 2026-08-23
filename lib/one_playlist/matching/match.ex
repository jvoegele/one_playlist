defmodule OnePlaylist.Matching.Match do
  @moduledoc """
  One track resolved to another, with the reasoning attached.

  ## Why a number *and* a name

  `score` is a float so candidates can be ranked and the user can set a real
  threshold. `confidence` is the coarse name for that number, because
  "0.87" means nothing to a person deciding whether to review a transfer, while
  "high" does.

  `strategy` and `evidence` are what make a wrong match debuggable after the
  fact. Without them a bad transfer produces a number and no way to find out
  which signal lied.

  ## Score bands

  Each rung of the ladder scores within its own band, so a score orders matches
  *across* strategies and not only within one:

  | Strategy | Band | Meaning |
  | --- | --- | --- |
  | `:isrc` | `1.0` | The same recording, by identifier. Not an opinion. |
  | `:upc_position` | `1.0` | The same track of the same release. Not an opinion. |
  | `:text` | `0.80`–`0.98` | Every compared field agreed after normalization. |
  | `:fuzzy` | `0.0`–`0.79` | Approximate. Review the middle of this range. |

  The ceiling below `1.0` on the inexact rungs is deliberate: **text can never
  be certain**, however perfectly it matches, because two different recordings
  can carry identical metadata. Reserving `1.0` for identifier rungs keeps
  `:exact_isrc` meaning what it says.
  """

  use Bond

  alias OnePlaylist.Matching.Confidence
  alias OnePlaylist.Music.Track

  @typedoc "Which rung of the ladder produced this."
  @type strategy :: Confidence.strategy()

  @typedoc "The coarse name for a score."
  @type confidence :: Confidence.t()

  @type t :: %__MODULE__{
          source: Track.t(),
          track: Track.t(),
          score: float(),
          confidence: confidence(),
          strategy: strategy(),
          evidence: keyword(),
          alternatives: non_neg_integer()
        }

  @enforce_keys [:source, :track, :score, :strategy]
  defstruct [
    :source,
    :track,
    :score,
    :confidence,
    :strategy,
    evidence: [],
    alternatives: 0
  ]

  # The law that makes a score comparable across rungs, stated on the type
  # rather than at the one place that currently upholds it.
  #
  # `Matching.to_matches/3` scales every raw score through `in_band/2`, so today
  # this cannot fail. It is not thereby vacuous: `new/1` is public and takes a
  # bare keyword list, so the next rung's author calling
  # `Match.new(score: raw, strategy: :fuzzy)` — forgetting the scaling, which is
  # a separate call and easy to miss — produces a match whose confidence reads
  # plausibly and outranks rungs that are more trustworthy. That is this
  # product's worst failure mode wearing a believable number, and an invariant
  # on the struct catches it wherever it is constructed rather than only where
  # it is constructed today.
  @invariant score_within_its_strategys_band: score_in_band?(subject)

  @doc """
  Builds a match, deriving `confidence` from `score` and `strategy`.

  Callers pass the raw fields; the band and the name are worked out here so
  every rung agrees about what a score means.
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    match = struct!(__MODULE__, fields)

    %{match | confidence: Confidence.for_score(match.score, match.strategy)}
  end

  @doc """
  Whether a match's score lies inside the band its strategy is allowed.

  Public because the invariant names it, and an assertion rendered into the
  documentation should reference something a reader can look up.

  A strategy with no band is a violation rather than an error: it means a rung
  reported a name that `Confidence.for_score/2` cannot interpret, and the
  resulting match would have no meaningful confidence at all.

      iex> alias OnePlaylist.Matching.Match
      iex> Match.score_in_band?(struct(Match, score: 0.9, strategy: :text))
      true
      iex> Match.score_in_band?(struct(Match, score: 0.2, strategy: :text))
      false
  """
  # Takes a bare parameter rather than `%__MODULE__{} = match`, and that is the
  # whole point rather than an oversight.
  #
  # A pattern-matched head gets an entry check, and the entry check evaluates
  # the invariant — which is *this function*. So the predicate would raise on
  # precisely the matches it exists to identify: its `false` branch would be
  # unreachable at every call site outside an assertion, and a public function
  # documented as answering a question could only ever answer `true`. Measured:
  # before this changed, `score_in_band?/1` on an out-of-band match raised
  # `Bond.InvariantError` instead of returning `false`.
  #
  # This is not the Assertion Evaluation rule at work — that rule handles the
  # call *from* the invariant correctly on its own. It is the narrower conflict
  # between an invariant and a predicate that tests the same invariant. See
  # `docs/reference/contracts.md`.
  @bond_warn_skipped_invariants false
  @spec score_in_band?(t()) :: boolean()
  def score_in_band?(%{score: score, strategy: strategy}) do
    if strategy in Confidence.strategies() do
      {floor, ceiling} = Confidence.band(strategy)

      is_float(score) and score >= floor and score <= ceiling
    else
      false
    end
  end

  @doc """
  Whether a match is at least as confident as `minimum`.

      iex> alias OnePlaylist.Matching.Match
      iex> Match.at_least?(:high, :medium)
      true
      iex> Match.at_least?(:low, :high)
      false
  """
  @spec at_least?(confidence() | t(), confidence()) :: boolean()
  def at_least?(%__MODULE__{confidence: confidence}, minimum),
    do: Confidence.at_least?(confidence, minimum)

  def at_least?(confidence, minimum) when is_atom(confidence) and is_atom(minimum),
    do: Confidence.at_least?(confidence, minimum)
end
