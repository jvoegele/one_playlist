defmodule OnePlaylist.Matching.Confidence do
  @moduledoc """
  The scale a match is graded on: the bands, the names, and their order.

  Split out of `OnePlaylist.Matching.Match`, which held two things at once. A
  match is an *instance* — this source, that track, this score. This module is
  the *rules* by which any match is judged, and the two have different lifetimes:
  the rules are consulted before a match exists (`confidence_for/2` is what
  `Match.new/1` calls to derive the name it stores) and long after
  (`Report.needs_review/2` compares one).

  Bond made the split visible. Four functions in `Match` had to suppress its
  `warn_skipped_invariants` linter because none of them took or returned a
  `%Match{}` — a module declaring an invariant, with most of its API not about
  the struct. See `docs/reference/contracts.md`.

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

  @typedoc "Which rung of the ladder produced a score."
  @type strategy :: :isrc | :upc_position | :text | :fuzzy

  @typedoc "The coarse name for a score."
  @type t :: :exact_isrc | :exact_upc | :high | :medium | :low | :none

  # Ordered worst-to-best so `Enum.find/2` from the top reads naturally, and so
  # `rank/1` can use the index directly.
  @ordering [:none, :low, :medium, :high, :exact_upc, :exact_isrc]

  @bands %{
    isrc: {1.0, 1.0},
    upc_position: {1.0, 1.0},
    text: {0.80, 0.98},
    fuzzy: {0.0, 0.79}
  }

  @doc """
  Confidence names, worst first. Useful for building a threshold control.

      iex> alias OnePlaylist.Matching.Confidence
      iex> Confidence.all()
      [:none, :low, :medium, :high, :exact_upc, :exact_isrc]
  """
  @spec all() :: [t()]
  def all, do: @ordering

  @doc """
  Every strategy the scale knows how to band.

      iex> alias OnePlaylist.Matching.Confidence
      iex> Enum.sort(Confidence.strategies())
      [:fuzzy, :isrc, :text, :upc_position]
  """
  @spec strategies() :: [strategy()]
  def strategies, do: Map.keys(@bands)

  @doc """
  The name for a score produced by a given strategy.

      iex> alias OnePlaylist.Matching.Confidence
      iex> {Confidence.for_score(1.0, :isrc), Confidence.for_score(0.93, :text)}
      {:exact_isrc, :high}
      iex> Confidence.for_score(0.4, :fuzzy)
      :none
  """
  # An unrecognised name is not a lesser confidence — it is one that beats
  # everything. `rank/1` is `Enum.find_index/2`, which answers `nil`, and under
  # Elixir's term ordering an atom sorts above every number, so `nil >= 5` is
  # `true`. A typo here would therefore clear every threshold ever set: nothing
  # would be flagged for review and `Matching.threshold/1` would resolve to the
  # first score it tried.
  #
  # Measured before this contract existed: `at_least?(:hgih, :exact_isrc)`
  # returned `true`.
  @post known_confidence: result in all()
  @spec for_score(float(), strategy()) :: t()
  def for_score(1.0, :isrc), do: :exact_isrc
  def for_score(1.0, :upc_position), do: :exact_upc

  def for_score(score, _strategy) when is_float(score) do
    cond do
      score >= 0.90 -> :high
      score >= 0.75 -> :medium
      score >= 0.50 -> :low
      true -> :none
    end
  end

  @doc """
  The band a strategy scores within, as `{floor, ceiling}`.

      iex> alias OnePlaylist.Matching.Confidence
      iex> Confidence.band(:text)
      {0.80, 0.98}
  """
  @spec band(strategy()) :: {float(), float()}
  def band(strategy), do: Map.fetch!(@bands, strategy)

  @doc """
  Scales a strategy's raw `0.0..1.0` opinion into that strategy's band.

  This is what makes scores comparable across rungs: a perfect fuzzy match
  cannot outrank a mediocre text match, because a rung's confidence is bounded
  by how much the *kind* of evidence it uses is worth.

      iex> alias OnePlaylist.Matching.Confidence
      iex> Confidence.in_band(1.0, :fuzzy)
      0.79
      iex> Confidence.in_band(0.0, :text)
      0.8
  """
  # The law `Match`'s invariant depends on, stated where the scaling happens.
  # The two are complementary rather than duplicated: this catches a scaling
  # that leaves the band, and the invariant catches a match assembled *without*
  # scaling at all — `Match.new(score: raw, strategy: :fuzzy)`, which is a
  # separate call and easy to forget.
  @pre raw_is_a_proportion: raw >= 0.0 and raw <= 1.0
  @post within_the_band:
          (fn {floor, ceiling} -> result >= floor and result <= ceiling end).(band(strategy))
  @spec in_band(float(), strategy()) :: float()
  def in_band(raw, strategy) when is_float(raw) do
    {floor, ceiling} = band(strategy)

    floor + raw * (ceiling - floor)
  end

  @doc """
  Whether one confidence is at least as strong as another.

      iex> alias OnePlaylist.Matching.Confidence
      iex> Confidence.at_least?(:high, :medium)
      true
      iex> Confidence.at_least?(:low, :high)
      false
  """
  # A precondition rather than a tolerant `rank/1` that treats the unknown as
  # lowest, because there is no sensible answer to "is this thing I have never
  # heard of at least `:high`?" — and silently answering `false` would hide the
  # typo that produced it just as effectively as the `true` this replaced.
  #
  # Discharged everywhere it is called: `Match.at_least?/2` passes a stored
  # confidence, which `for_score/2` guarantees; `Matching.threshold/1` validates
  # a requested one against `all/0` before resolving it.
  @pre both_are_known: confidence in all() and minimum in all()
  @spec at_least?(t(), t()) :: boolean()
  def at_least?(confidence, minimum), do: rank(confidence) >= rank(minimum)

  defp rank(confidence), do: Enum.find_index(@ordering, &(&1 == confidence))
end
