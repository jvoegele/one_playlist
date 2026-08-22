defmodule OnePlaylist.Matching.SimilarityPropertyTest do
  @moduledoc """
  The scoring primitives, with their own contracts as the oracle.

  Every function in `OnePlaylist.Matching.Similarity` carries the same
  postcondition — the result stays inside `0.0..1.0` — and every one of them
  computes it differently: a Winkler prefix bonus added to a Jaro distance, a
  ratio over set sizes, a linear taper, a weighted mean over a filtered list.
  Four separate opportunities to leave the interval, and the example tests
  reach only the values someone thought to write down.

  `contract_holds/2` needs no expectations here precisely because the contract
  already states the law. The work is choosing generators that produce *valid*
  inputs — which for these functions is easy, since they are total.

  The bands matter because these numbers are compared against each other:
  a score above `1.0` does not raise, it outranks an exact ISRC match.
  """

  use ExUnit.Case, async: true
  use Bond.PropertyTest

  alias OnePlaylist.Matching.Similarity

  # Weighted heavily toward variations on **one** word, and that weighting is
  # the whole point rather than a convenience.
  #
  # `contract_holds/2` draws each argument independently, so it cannot produce a
  # correlated pair — similarity has to come from the pool being tight. A first
  # version mixed one family of variants with unrelated random strings and
  # reached the prefix-bonus branch 11 times in 300: the property passed while
  # the only arithmetic that can leave the unit interval went essentially
  # unexercised. The guard below is what caught that.
  defp text_generator do
    StreamData.frequency([
      {7, StreamData.member_of(~w(yesterday yesterdayy yesterda yesterdai yesterdays yesterdy))},
      {2, StreamData.string(:alphanumeric, max_length: 20)},
      {1, StreamData.constant("")}
    ])
  end

  defp token_set_generator do
    StreamData.map(
      StreamData.list_of(StreamData.member_of(~w(the beatles queen bjork jay z)), max_length: 6),
      &MapSet.new/1
    )
  end

  defp duration_generator do
    StreamData.one_of([StreamData.constant(nil), StreamData.integer(0..600)])
  end

  # Weights are non-negative and scores are either absent or in range — the
  # shape every caller actually passes. Generating negative weights would test
  # a contract the function does not make.
  defp signals_generator do
    StreamData.list_of(
      StreamData.tuple({
        StreamData.one_of([StreamData.constant(nil), StreamData.float(min: 0.0, max: 1.0)]),
        StreamData.integer(0..5)
      }),
      max_length: 6
    )
  end

  contract_holds(&Similarity.jaro_winkler/2, args: [text_generator(), text_generator()])

  contract_holds(&Similarity.dice/2, args: [token_set_generator(), token_set_generator()])

  contract_holds(&Similarity.duration_proximity/2,
    args: [duration_generator(), duration_generator()]
  )

  contract_holds(&Similarity.weighted_mean/1, args: [signals_generator()])

  describe "the generators reach the branches that can break the bound" do
    property "jaro_winkler is driven above the Winkler threshold, not only below it" do
      # Guards the property above. The prefix bonus — the only arithmetic that
      # can leave the unit interval — applies only when Jaro exceeds 0.7, so a
      # generator that never produced similar strings would exercise the safe
      # path exclusively and prove nothing.
      boosted =
        StreamData.tuple({text_generator(), text_generator()})
        |> Enum.take(300)
        |> Enum.count(fn {left, right} ->
          left != "" and right != "" and String.jaro_distance(left, right) > 0.7
        end)

      assert boosted > 20,
             "only #{boosted}/300 generated pairs reached the prefix-bonus branch"
    end

    property "weighted_mean is driven with a mix of present and absent signals" do
      # The bug the contract guards is dividing by the declared weight rather
      # than the used weight, which only shows when some signals are absent.
      mixed =
        signals_generator()
        |> Enum.take(300)
        |> Enum.count(fn signals ->
          Enum.any?(signals, &match?({nil, _weight}, &1)) and
            Enum.any?(signals, &match?({score, _weight} when is_float(score), &1))
        end)

      assert mixed > 20, "only #{mixed}/300 generated signal lists mixed present with absent"
    end
  end
end
