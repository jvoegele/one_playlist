defmodule OnePlaylist.Matching do
  @moduledoc """
  Given a track on one service, find the same recording on another.

  This is the technical core of the product. Everything else — OAuth, token
  refresh, pagination, rate limiting — is plumbing in service of getting two
  lists of tracks into the same room so this module can compare them.

  ## The ladder

  Strategies are tried in order of how much their kind of evidence is worth,
  and **the first rung to produce any opinion at all wins**. If ISRC matched
  anything, the text rung is never consulted; a candidate the ISRC rung
  rejected does not get a second hearing from a weaker rung. That is what makes
  the ladder a ladder rather than an ensemble, and it is deliberate: mixing a
  weak signal into a strong one can only make the strong one worse.

  | Rung | Module | Evidence |
  | --- | --- | --- |
  | 1 | `OnePlaylist.Matching.Strategy.Isrc` | Recording identifier |
  | 1b | `OnePlaylist.Matching.Strategy.IsrcFamily` | Another identifier for the same recording |
  | 2 | `OnePlaylist.Matching.Strategy.UpcPosition` | Release barcode plus position |
  | 3 | `OnePlaylist.Matching.Strategy.Work` | The same movement of the same classical work |
  | 3 | `OnePlaylist.Matching.Strategy.Text` | Exact after normalization |
  | 5 | `OnePlaylist.Matching.Strategy.Fuzzy` | Approximate similarity |

  Rung 4 of `docs/reference/domain.md` — duration proximity — is not a rung
  here. It never identifies a track on its own; it is a tiebreaker and a
  corroborator, so it lives inside `OnePlaylist.Matching.Signals` and feeds
  rungs 3 and 5. Rung 6, embedding similarity over pgvector, is not built. It
  slots in as another module in `strategies/0` when the cheaper rungs are shown
  to be insufficient, which is a measurement this project has not yet made.

  ## Ties are resolved, not hidden

  Two candidates scoring identically is the normal case, not the exotic one:
  the first live ISRC lookup run against TIDAL returned two catalogue entries
  for one identifier. The tie is broken deterministically — by popularity, then
  by provider id, so the same inputs always give the same answer — and the
  count of equally-good candidates is recorded on the match as `alternatives`,
  so a review screen can show that the choice was arbitrary.

  ## Nothing is ever silently dropped

  `match/3` returns a typed `OnePlaylist.Matching.TrackNotMatched` carrying the
  source track, how many candidates were considered and how close the best one
  came. `match_all/2` collects those alongside the matches into an
  `OnePlaylist.Matching.Report` whose two halves are contracted to add up.
  """

  use Bond
  use Errata

  alias OnePlaylist.Matching.Confidence
  alias OnePlaylist.Matching.Match
  alias OnePlaylist.Matching.Report
  alias OnePlaylist.Matching.Signals
  alias OnePlaylist.Matching.Strategy
  alias OnePlaylist.Matching.TrackNotMatched
  alias OnePlaylist.Music.Track

  @strategies [
    Strategy.Isrc,
    # Between the two identifier rungs on purpose: a code the recording is also
    # known by outranks a barcode plus a track number, and is outranked by the
    # code agreeing outright. See `Strategy.IsrcFamily`.
    Strategy.IsrcFamily,
    Strategy.UpcPosition,
    # Above the text rungs because a catalogue number is nearly an identifier
    # and a title is not: comparing the words around `Op. 8 No. 1` ranked a
    # recording of `Op. 8 No. 4` higher. See `Strategy.Work`.
    Strategy.Work,
    Strategy.Text,
    Strategy.Fuzzy
  ]

  @default_threshold :medium

  @doc """
  The best match for `source` among `candidates`, or why there wasn't one.

  ## Options

    * `:threshold` — the minimum acceptable result, as a
      `t:OnePlaylist.Matching.Match.confidence/0` or a float. Defaults to
      `#{inspect(@default_threshold)}`, overridable in config.
    * `:strategies` — the ladder to use, in order. Defaults to `strategies/0`.
  """
  # Conservation, and the most important contract in the module. A ranking bug,
  # a stale accumulator in the ladder fold, or a rung that builds a Match from
  # the wrong side of its own comparison all produce a *plausible* match to a
  # track that was never a candidate. Nothing raises, the transfer completes,
  # and a track the user never had appears in their playlist.
  @post whenever({:ok, match} <- result),
    chosen_from_candidates: match.track in candidates,
    source_preserved: match.source == source,
    meets_threshold: match.score >= threshold(opts)
  # The veto in `Strategy.Text` and `Strategy.Fuzzy` is the rule that stops a
  # karaoke version matching the original, and it is one `not` away from being
  # silently inverted. Restated here, over the returned pair, so removing it in
  # either rung fires — the two implementations of one rule that
  # `docs/reference/contracts.md` describes as the shape worth looking for.
  #
  # Deliberately not applied to the identifier rungs: they trust the identifier
  # over the text, which is correct, and a provider that mislabels a version on
  # a correctly-ISRC'd track must not become a crash here.
  @post whenever({:ok, match} <- result),
    veto_respected:
      (match.strategy in [:text, :fuzzy])
      ~> not Signals.vetoed?(Signals.compare(match.source, match.track))
  @spec match(Track.t(), [Track.t()], keyword()) ::
          {:ok, Match.t()} | {:error, TrackNotMatched.t()}
  def match(%Track{} = source, candidates, opts \\ []) when is_list(candidates) do
    ranked = rank(source, candidates, opts)
    minimum = threshold(opts)

    case ranked do
      [%Match{score: score} = best | _rest] when score >= minimum ->
        {:ok, best}

      _below_threshold_or_empty ->
        {:error, not_matched(source, candidates, ranked, minimum)}
    end
  end

  @doc """
  Every candidate the winning rung had an opinion about, best first.

  Only the winning rung's candidates appear — see the ladder note in the
  module documentation. Useful directly for a "pick the right one yourself"
  screen, where the rejected candidates are as informative as the chosen one.
  """
  # A comparator with its arguments the wrong way round is a one-character bug
  # that makes `match/3` return the *worst* candidate it found. Every score is
  # still real, the confidence still reads plausibly, and no test that only
  # checks "a match was returned" would notice.
  @post ordered_best_first: descending?(result)
  @spec rank(Track.t(), [Track.t()], keyword()) :: [Match.t()]
  def rank(%Track{} = source, candidates, opts \\ []) when is_list(candidates) do
    opts
    |> Keyword.get(:strategies, strategies())
    |> Enum.find_value([], fn strategy ->
      case opinions(strategy, source, candidates) do
        [] -> nil
        opinions -> to_matches(opinions, source, strategy.strategy())
      end
    end)
  end

  @doc """
  Matches many tracks at once, collecting successes and failures together.

  Takes `{source, candidates}` pairs rather than a flat list because candidates
  are fetched per track — see `c:OnePlaylist.Providers.Adapter.search_tracks/3`.
  """
  # The ledger law. `docs/reference/contracts.md` names this shape as the one
  # the transfer engine will want most, and this is the first place it applies:
  # a report whose halves do not add up to what was asked for is precisely the
  # "finished, reported success, and was wrong" failure the product exists to
  # avoid. A `flat_map` that drops an error, or an accumulator reversed onto
  # itself, is caught here and nowhere else.
  #
  # Stated as multiset equality rather than as a count plus a uniqueness check.
  # The first version of this asserted that no source appeared twice, and it was
  # unsound: **a playlist may legitimately contain the same track twice**, so it
  # accused correct code the first time it ran against a repeated track. Sorting
  # both sides compares what was reported against what was asked for without
  # caring about order, and rejects a drop, a duplication and a substitution
  # alike — strictly stronger than the pair it replaced, and sound.
  @post every_track_accounted_for_exactly_once:
          Enum.sort(source_ids(result)) == Enum.sort(source_ids(pairs))
  @spec match_all([{Track.t(), [Track.t()]}], keyword()) :: Report.t()
  def match_all(pairs, opts \\ []) when is_list(pairs) do
    {matched, unmatched} =
      pairs
      |> Enum.map(fn {source, candidates} -> match(source, candidates, opts) end)
      |> Enum.split_with(&match?({:ok, _match}, &1))

    %Report{
      threshold: threshold(opts),
      matched: Enum.map(matched, fn {:ok, match} -> match end),
      unmatched: Enum.map(unmatched, fn {:error, error} -> error end)
    }
  end

  @doc "The ladder, in order."
  @spec strategies() :: [module()]
  def strategies,
    do: Application.get_env(:one_playlist, __MODULE__, [])[:strategies] || @strategies

  @doc """
  The minimum score a match must reach, from options or configuration.

  Accepts a `t:OnePlaylist.Matching.Match.confidence/0` name or a raw float, so
  a user-facing control can offer "high / medium / low" while a caller that has
  measured something can be precise.

  Public because `match/3` names it in a postcondition, and an assertion
  rendered into the documentation should reference something a reader can look
  up — the same reason
  `OnePlaylist.Providers.Tidal.Mapper.item_ids/1` is public.
  """
  # A magnitude bug, and the most consequential one in this application.
  #
  # `to_score/1` passes a float straight through and turns an integer into
  # `value / 1`, so a caller or a config file writing `threshold: 75` — meaning
  # 75%, which is how everyone says it — gets `75.0`. Every score is at most
  # `1.0`, so **nothing ever matches again**: every transfer completes, every
  # track is reported unmatched, and the destination playlist is empty. Nothing
  # raises, nothing is logged, and the report looks like an honest account of a
  # catalogue that happens to contain none of the user's music.
  #
  # Unlike the assertions on `Normalize`, this one is falsifiable by *data*: it
  # fires on `config :one_playlist, OnePlaylist.Matching, threshold: 75` with no
  # code change at all. The DB path is separately validated by
  # `Transfer.create_changeset/2`; config and direct callers had nothing.
  #
  # The precondition catches the *other* way to ask for an impossible threshold,
  # and it is genuinely complementary rather than a second guard on one thing.
  # A misspelled confidence — `threshold: :hgih` — resolves through
  # `to_score/1`'s `Enum.find/3` default to `1.0`, which is in range, so the
  # postcondition below waves it through. The effect is the same catastrophe by
  # a different road: only a flawless score passes, so all but exact-identifier
  # matches are reported unmatched. Neither assertion sees what the other does —
  # `is_number(75)` satisfies the precondition, `:hgih` satisfies the
  # postcondition.
  #
  # The 1.0 default is not itself a bug: a *valid* confidence no text score can
  # reach, like `:exact_isrc`, correctly resolves to 1.0. That is exactly why the
  # check has to be on what was asked for rather than on what came back.
  @pre threshold_request_is_meaningful: valid_threshold_request?(opts)
  @post is_a_proportion: result >= 0.0 and result <= 1.0
  @spec threshold(keyword()) :: float()
  def threshold(opts \\ []) do
    opts
    |> Keyword.get(:threshold, configured_threshold())
    |> to_score()
  end

  @doc """
  Whether a threshold request names something this module can resolve.

  Public because `threshold/1` names it in a **precondition**, and a
  precondition is an obligation on the caller — one they can only discharge if
  they can see and evaluate it. The same reasoning as
  `OnePlaylist.Providers.Connection.now_after_creation?/2`.

  Reads the configured default too, because a threshold can be misspelled in
  `config/*.exs` just as easily as at a call site, and the configuration path
  has nobody else checking it.

      iex> alias OnePlaylist.Matching
      iex> Matching.valid_threshold_request?(threshold: :high)
      true
      iex> Matching.valid_threshold_request?(threshold: :hgih)
      false
      iex> Matching.valid_threshold_request?(threshold: 0.8)
      true
  """
  @spec valid_threshold_request?(keyword()) :: boolean()
  def valid_threshold_request?(opts) do
    case Keyword.get(opts, :threshold, configured_threshold()) do
      confidence when is_atom(confidence) -> confidence in Confidence.all()
      number -> is_number(number)
    end
  end

  @doc """
  Whether matches are ordered best-first.

  Public for the same reason `threshold/1` is: `rank/3` asserts it.
  """
  @spec descending?([Match.t()]) :: boolean()
  def descending?(matches) do
    matches
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [left, right] -> left.score >= right.score end)
  end

  @doc """
  Identifies the source track of every entry, for either side of the ledger.

  Accepts a report or the `{source, candidates}` pairs it was built from, so
  `match_all/2` can compare the two directly. Public for the same reason
  `threshold/1` is: it is named in an assertion.
  """
  @spec source_ids(Report.t() | [{Track.t(), [Track.t()]}]) :: [{atom(), String.t()}]
  def source_ids(%Report{} = report) do
    matched = Enum.map(report.matched, & &1.source)
    unmatched = Enum.map(report.unmatched, &Errata.context(&1).source)

    Enum.map(matched ++ unmatched, &Track.identity/1)
  end

  def source_ids(pairs) when is_list(pairs),
    do: Enum.map(pairs, fn {source, _candidates} -> Track.identity(source) end)

  defp opinions(strategy, source, candidates) do
    Enum.flat_map(candidates, fn candidate ->
      case strategy.score(source, candidate) do
        {raw, evidence} -> [{candidate, raw, evidence}]
        nil -> []
      end
    end)
  end

  defp to_matches(opinions, source, strategy) do
    scored =
      Enum.map(opinions, fn {candidate, raw, evidence} ->
        {candidate, Confidence.in_band(raw, strategy), evidence}
      end)

    # How many other candidates scored exactly the same, per score. Computed for
    # every match rather than only the winner: `rank/3` is also the input to a
    # "choose it yourself" screen, where knowing that two *rejected* candidates
    # were indistinguishable is as useful as knowing it about the chosen one.
    at_score = Enum.frequencies_by(scored, fn {_candidate, score, _evidence} -> score end)

    scored
    |> Enum.sort_by(&tiebreak/1)
    |> Enum.map(fn {candidate, score, evidence} ->
      Match.new(
        source: source,
        track: candidate,
        score: score,
        strategy: strategy,
        evidence: evidence,
        alternatives: Map.fetch!(at_score, score) - 1
      )
    end)
  end

  # Descending score, then descending popularity, then ascending provider id.
  # The last is what makes this total: without it two candidates with equal
  # score and no popularity would order by whatever the enumeration happened to
  # produce, and the same transfer run twice could pick differently.
  defp tiebreak({candidate, score, _evidence}) do
    {-score, -(candidate.popularity || 0), candidate.provider_id}
  end

  defp not_matched(source, candidates, ranked, minimum) do
    {reason, best} =
      case {candidates, ranked} do
        # Nothing came back from the search at all.
        {[], _ranked} -> {:no_candidates, nil}
        # Candidates came back and every rung declined all of them — which for
        # the text and fuzzy rungs means the version veto fired. Distinct from
        # "not found", and the more informative of the two.
        {_candidates, []} -> {:all_rejected, nil}
        {_candidates, [best | _rest]} -> {:below_threshold, best}
      end

    Errata.create(TrackNotMatched,
      reason: if(searchable?(source), do: reason, else: :unsearchable),
      context: %{
        source: source,
        candidates_considered: length(candidates),
        best_score: best && best.score,
        best_confidence: (best && best.confidence) || :none,
        best_candidate_id: best && best.track.provider_id,
        threshold: minimum
      }
    )
  end

  @doc """
  Whether there is enough of a track here to go looking for it.

  A track with neither an identifier nor a title cannot be searched for at all
  — which is a different report line from "searched for and not found", and a
  different fix. Local files and some podcast entries land here.

  Public because `c:OnePlaylist.Providers.Adapter.search_tracks/3` names it in a
  precondition, and Bond's Precondition Availability Rule asks that a caller be
  able to check a precondition before calling. A private helper, or a public one
  hidden with `@doc false`, would leave the caller unable to satisfy the rule it
  is being held to.
  """
  @spec searchable?(Track.t()) :: boolean()
  def searchable?(%Track{isrc: isrc, title: title}),
    do: is_binary(isrc) or (is_binary(title) and String.trim(title) != "")

  defp to_score(value) when is_float(value), do: value
  defp to_score(value) when is_integer(value), do: value / 1

  defp to_score(confidence) when is_atom(confidence) do
    # The lowest score that still earns this name. Derived by asking `Match`
    # rather than repeating its boundaries, so the two cannot drift.
    0..100
    |> Enum.map(&(&1 / 100))
    |> Enum.find(1.0, &Confidence.at_least?(Confidence.for_score(&1, :text), confidence))
  end

  defp configured_threshold do
    Application.get_env(:one_playlist, __MODULE__, [])[:threshold] || @default_threshold
  end
end
