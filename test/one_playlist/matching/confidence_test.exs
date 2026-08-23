defmodule OnePlaylist.Matching.ConfidenceTest do
  @moduledoc """
  The scale a match is graded on, split out of `Match` — which held the rules
  and an instance judged by them at the same time.
  """

  use ExUnit.Case, async: true
  use Bond.Test

  alias OnePlaylist.Matching.Confidence

  doctest OnePlaylist.Matching.Confidence

  describe "at_least?/2" do
    test "an unrecognised confidence is refused rather than outranking everything" do
      # The bug this precondition exists for, measured before it: `rank/1` is
      # `Enum.find_index/2`, which answers `nil` for an unknown name, and under
      # Elixir's term ordering an atom sorts above every number — so
      # `nil >= 5` is `true` and `at_least?(:hgih, :exact_isrc)` returned true.
      # A typo would have cleared every threshold ever set.
      assert_precondition_violation(Confidence.at_least?(:hgih, :exact_isrc),
        label: :both_are_known
      )

      assert_precondition_violation(Confidence.at_least?(:high, :nonsense),
        label: :both_are_known
      )
    end

    test "the ordering runs from none up to exact_isrc" do
      assert Confidence.at_least?(:exact_isrc, :exact_upc)
      assert Confidence.at_least?(:exact_upc, :high)
      assert Confidence.at_least?(:high, :medium)
      assert Confidence.at_least?(:medium, :low)
      assert Confidence.at_least?(:low, :none)
      refute Confidence.at_least?(:none, :low)
    end

    test "every name is at least itself" do
      for confidence <- Confidence.all() do
        assert Confidence.at_least?(confidence, confidence)
      end
    end
  end

  describe "for_score/2" do
    test "only identifier rungs can reach the exact names" do
      # Reserving 1.0 for identifiers is what keeps `:exact_isrc` meaning what
      # it says: text can never be certain, however perfectly it matches,
      # because two different recordings can carry identical metadata.
      assert Confidence.for_score(1.0, :isrc) == :exact_isrc
      assert Confidence.for_score(1.0, :upc_position) == :exact_upc
      assert Confidence.for_score(1.0, :text) == :high
    end

    test "every score of every strategy yields a name the scale knows" do
      for strategy <- Confidence.strategies(), n <- 0..100 do
        assert Confidence.for_score(n / 100, strategy) in Confidence.all()
      end
    end
  end

  describe "in_band/2" do
    test "a perfect fuzzy match cannot outrank a mediocre text match" do
      # The whole point of banding: a rung's confidence is bounded by how much
      # the *kind* of evidence it uses is worth.
      assert Confidence.in_band(1.0, :fuzzy) < Confidence.in_band(0.0, :text)
    end

    test "a raw score outside 0..1 is a caller's bug" do
      assert_precondition_violation(Confidence.in_band(1.5, :text), label: :raw_is_a_proportion)
    end

    test "every strategy's scaling stays inside its own band" do
      for strategy <- Confidence.strategies(), n <- 0..100 do
        {floor, ceiling} = Confidence.band(strategy)
        scaled = Confidence.in_band(n / 100, strategy)

        assert scaled >= floor and scaled <= ceiling
      end
    end
  end
end
