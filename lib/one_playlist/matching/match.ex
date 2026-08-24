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
  *across* strategies and not only within one. The bands themselves, and why
  the inexact rungs are capped below `1.0`, are in
  `OnePlaylist.Matching.Confidence` — which owns the table rather than
  repeating it here.
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
  A match a person made, having looked at what the engine offered and disagreed.

  Scores `1.0` under the `:manual` strategy, which reads as `:chosen`. That is
  the honest number rather than a flattering one: the score exists to say how
  much a *reader* should doubt the answer, and there is nothing to doubt about a
  track somebody picked by hand. Naming the strategy `:manual` is what keeps it
  from being mistaken for an identifier match in the report.

  `evidence` says who decided, for the same reason every other rung records what
  it compared: a wrong track in a playlist is only debuggable if the report says
  where it came from.

      iex> alias OnePlaylist.Matching.Match
      iex> alias OnePlaylist.Music.Track
      iex> source = Track.new(%{provider: :file, provider_id: "0", title: "Corduroy"})
      iex> chosen = Track.new(%{provider: :tidal, provider_id: "77", title: "Corduroy"})
      iex> match = Match.chosen_by_hand(source, chosen)
      iex> {match.strategy, match.confidence, match.score}
      {:manual, :chosen, 1.0}
  """
  # One-hop delegation: `new/1` builds the struct and takes the entry check, and
  # the exit check on this function's own result still fires — so a `:manual`
  # band that did not admit 1.0 would be caught here. The third legitimate shape
  # in `docs/reference/contracts.md`.
  @bond_warn_skipped_invariants false
  @spec chosen_by_hand(Track.t(), Track.t()) :: t()
  def chosen_by_hand(%Track{} = source, %Track{} = chosen) do
    new(
      source: source,
      track: chosen,
      score: 1.0,
      strategy: :manual,
      evidence: [decided_by: :user]
    )
  end

  @doc """
  A track a destination accepted verbatim, because it could hold anything.

  Not a match in the sense every other strategy means. Nothing was compared:
  the destination is `OnePlaylist.Providers.Library`, which has no catalogue to
  fail to find the track in, so it stored what it was given. `accepted` is that
  destination's own representation, with an id of its own.

  Scores `1.0` under `:stored`, which reads as `:stored`. That is the honest
  number rather than a flattering one — there is nothing to doubt about a
  recording that *is* the source track — and naming the strategy is what keeps
  it from being mistaken for an identifier match in the report.

      iex> alias OnePlaylist.Matching.Match
      iex> alias OnePlaylist.Music.Track
      iex> source = Track.new(%{provider: :tidal, provider_id: "9", title: "Corduroy"})
      iex> held = Track.new(%{provider: :library, provider_id: "r-1", title: "Corduroy"})
      iex> match = Match.stored(source, held)
      iex> {match.strategy, match.confidence, match.track.provider}
      {:stored, :stored, :library}
  """
  # One-hop delegation, the third legitimate shape in
  # `docs/reference/contracts.md`: `new/1` takes the entry check and this
  # function's own exit check still fires.
  @bond_warn_skipped_invariants false
  @spec stored(Track.t(), Track.t()) :: t()
  def stored(%Track{} = source, %Track{} = accepted) do
    new(
      source: source,
      track: accepted,
      score: 1.0,
      strategy: :stored,
      evidence: [stored: :verbatim]
    )
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
  # documented as answering a question could only ever answer `true`. Measured,
  # not assumed — with a pattern-matched head, `score_in_band?/1` on an
  # out-of-band match raises `Bond.InvariantError` instead of returning `false`.
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
