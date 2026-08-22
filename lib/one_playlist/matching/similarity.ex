defmodule OnePlaylist.Matching.Similarity do
  @moduledoc """
  The numeric comparisons the matching strategies are built from.

  Every function here returns a score in `0.0..1.0`, or `nil` when the inputs
  do not support an opinion.

  ## `nil` is not zero

  That distinction is the whole reason these return `nil` at all. A track with
  no duration is not a track whose duration disagrees; an album with no barcode
  is not an album with a different barcode. Scoring absent evidence as `0.0`
  would push every track missing a field towards "no match", which is precisely
  backwards — those are the tracks that need the remaining signals *most*,
  because they are the ones ISRC already failed on.

  Callers therefore combine only the signals that produced a number, and absent
  evidence neither helps nor harms.
  """

  use Bond

  # Under this, two strings share so little that a prefix bonus would be
  # flattering noise rather than evidence. The value is Winkler's own.
  @winkler_threshold 0.7
  @winkler_scaling 0.1
  @winkler_prefix_limit 4

  # Providers round durations differently and masters genuinely differ by a
  # second or two, so a small gap is worth nothing against a match. Past the
  # far bound the recordings are different lengths, which usually means a
  # different recording — an edit, an extended mix, or the wrong track.
  @duration_exact_seconds 2
  @duration_useless_seconds 15

  @doc """
  Jaro-Winkler similarity: Jaro, with a bonus for a shared prefix.

  The prefix bonus is what makes this the right choice for titles and artist
  names specifically. Errors in this domain cluster at the *end* of a string —
  a suffix, an edition, a truncation — while two recordings that disagree from
  the first character are rarely the same thing.

      iex> alias OnePlaylist.Matching.Similarity
      iex> Similarity.jaro_winkler("hey jude", "hey jude") == 1.0
      true
      iex> Similarity.jaro_winkler("", "anything")
      0.0
  """
  # Winkler's bonus is added to a value that may already be 1.0, so an
  # implementation that forgets to scale it by `(1 - jaro)` returns something
  # above 1.0 — which does not raise, and silently outranks an exact ISRC match
  # once these scores are compared against each other.
  @post in_unit_interval: result >= 0.0 and result <= 1.0
  @spec jaro_winkler(String.t(), String.t()) :: float()
  def jaro_winkler(left, right) when is_binary(left) and is_binary(right) do
    jaro = String.jaro_distance(left, right)

    if jaro > @winkler_threshold do
      prefix = common_prefix_length(left, right, @winkler_prefix_limit)
      jaro + prefix * @winkler_scaling * (1 - jaro)
    else
      jaro
    end
  end

  @doc """
  Sørensen-Dice similarity between two sets: twice the overlap over the total.

  Set-based rather than sequential, which is the point — it makes word order
  and repetition stop mattering, so `"Simon & Garfunkel"` and
  `"Garfunkel, Simon"` compare as identical rather than as an anagram.

      iex> alias OnePlaylist.Matching.Similarity
      iex> Similarity.dice(MapSet.new(["a", "b"]), MapSet.new(["b", "a"]))
      1.0
      iex> Similarity.dice(MapSet.new([]), MapSet.new([]))
      nil
  """
  @post in_unit_interval: is_float(result) ~> (result >= 0.0 and result <= 1.0)
  @spec dice(MapSet.t(), MapSet.t()) :: float() | nil
  def dice(left, right) do
    total = MapSet.size(left) + MapSet.size(right)

    # Two empty sets are not similar, they are uninformative. Returning 1.0
    # here would make two tracks with no artists credited a perfect match.
    if total == 0 do
      nil
    else
      2 * MapSet.size(MapSet.intersection(left, right)) / total
    end
  end

  @doc """
  How much two durations agree, or `nil` if either is unknown.

  Full marks within #{@duration_exact_seconds} seconds, nothing at all beyond
  #{@duration_useless_seconds}, and a straight line between.

      iex> alias OnePlaylist.Matching.Similarity
      iex> Similarity.duration_proximity(180, 181)
      1.0
      iex> Similarity.duration_proximity(180, 300)
      0.0
      iex> Similarity.duration_proximity(180, nil)
      nil
  """
  @post in_unit_interval: is_float(result) ~> (result >= 0.0 and result <= 1.0)
  @spec duration_proximity(integer() | nil, integer() | nil) :: float() | nil
  def duration_proximity(left, right)

  def duration_proximity(left, right) when is_integer(left) and is_integer(right) do
    difference = abs(left - right)

    cond do
      difference <= @duration_exact_seconds ->
        1.0

      difference >= @duration_useless_seconds ->
        0.0

      true ->
        span = @duration_useless_seconds - @duration_exact_seconds
        1.0 - (difference - @duration_exact_seconds) / span
    end
  end

  def duration_proximity(_left, _right), do: nil

  @doc """
  A weighted mean over `{score, weight}` pairs, ignoring the `nil` scores.

  This is where "`nil` is not zero" is actually enforced: a signal that had
  nothing to say is dropped along with its weight, rather than dragging the
  mean down. `nil` comes back when nothing had anything to say at all.
  """
  # The bug this catches is dividing by the *declared* total weight rather than
  # the weight actually used. With any signal absent that yields a number below
  # every input — a track missing only its duration scoring worse than one that
  # disagrees on duration outright.
  @post in_unit_interval: is_float(result) ~> (result >= 0.0 and result <= 1.0)
  @spec weighted_mean([{float() | nil, number()}]) :: float() | nil
  def weighted_mean(signals) do
    present = Enum.reject(signals, fn {score, _weight} -> is_nil(score) end)
    total_weight = Enum.sum_by(present, fn {_score, weight} -> weight end)

    if total_weight == 0 do
      nil
    else
      weighted = Enum.sum_by(present, fn {score, weight} -> score * weight end)
      weighted / total_weight
    end
  end

  defp common_prefix_length(left, right, limit) do
    left
    |> String.graphemes()
    |> Enum.zip(String.graphemes(right))
    |> Enum.take(limit)
    |> Enum.take_while(fn {l, r} -> l == r end)
    |> length()
  end
end
