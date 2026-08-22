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

  alias OnePlaylist.Music.Track

  @typedoc "Which rung of the ladder produced this."
  @type strategy :: :isrc | :upc_position | :text | :fuzzy

  @typedoc "The coarse name for a score."
  @type confidence :: :exact_isrc | :exact_upc | :high | :medium | :low | :none

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
  Builds a match, deriving `confidence` from `score` and `strategy`.

  Callers pass the raw fields; the band and the name are worked out here so
  every rung agrees about what a score means.
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    match = struct!(__MODULE__, fields)

    %{match | confidence: confidence_for(match.score, match.strategy)}
  end

  @doc """
  The name for a score produced by a given strategy.

      iex> alias OnePlaylist.Matching.Match
      iex> Match.confidence_for(1.0, :isrc)
      :exact_isrc
      iex> Match.confidence_for(0.93, :text)
      :high
      iex> Match.confidence_for(0.4, :fuzzy)
      :none
  """
  @spec confidence_for(float(), strategy()) :: confidence()
  def confidence_for(1.0, :isrc), do: :exact_isrc
  def confidence_for(1.0, :upc_position), do: :exact_upc

  def confidence_for(score, _strategy) when is_float(score) do
    cond do
      score >= 0.90 -> :high
      score >= 0.75 -> :medium
      score >= 0.50 -> :low
      true -> :none
    end
  end

  @doc """
  Scales a strategy's raw `0.0..1.0` opinion into that strategy's band.

  This is what makes scores comparable across rungs: a perfect fuzzy match
  cannot outrank a mediocre text match, because a rung's confidence is bounded
  by how much the *kind* of evidence it uses is worth.
  """
  @spec in_band(float(), strategy()) :: float()
  def in_band(raw, strategy) when is_float(raw) do
    {floor, ceiling} = Map.fetch!(@bands, strategy)

    floor + raw * (ceiling - floor)
  end

  @doc "The band a strategy scores within, as `{floor, ceiling}`."
  @spec band(strategy()) :: {float(), float()}
  def band(strategy), do: Map.fetch!(@bands, strategy)

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
    do: at_least?(confidence, minimum)

  def at_least?(confidence, minimum) when is_atom(confidence) and is_atom(minimum),
    do: rank(confidence) >= rank(minimum)

  @doc "Confidence names, worst first. Useful for building a threshold control."
  @spec confidences() :: [confidence()]
  def confidences, do: @ordering

  defp rank(confidence), do: Enum.find_index(@ordering, &(&1 == confidence))
end
