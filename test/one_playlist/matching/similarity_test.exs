defmodule OnePlaylist.Matching.SimilarityTest do
  use ExUnit.Case, async: true

  alias OnePlaylist.Matching.Similarity

  doctest OnePlaylist.Matching.Similarity

  describe "jaro_winkler/2" do
    test "identical strings score 1.0" do
      assert Similarity.jaro_winkler("hey jude", "hey jude") == 1.0
    end

    test "a shared prefix beats a shared suffix" do
      # The reason Winkler rather than plain Jaro. Metadata errors cluster at
      # the end of a string — a suffix, an edition, a truncation — so agreement
      # at the front is worth more.
      prefix = Similarity.jaro_winkler("yesterday", "yesterdax")
      suffix = Similarity.jaro_winkler("yesterday", "xesterday")

      assert prefix > suffix
    end

    test "unrelated strings score low" do
      assert Similarity.jaro_winkler("yesterday", "bohemian rhapsody") < 0.6
    end

    test "never exceeds 1.0 even for a long shared prefix" do
      # The bound the contract states. A Winkler bonus added without scaling by
      # `(1 - jaro)` breaks exactly here.
      assert Similarity.jaro_winkler("yesterdayyy", "yesterday") <= 1.0
    end
  end

  describe "dice/2" do
    test "order does not matter" do
      assert Similarity.dice(MapSet.new(~w(simon garfunkel)), MapSet.new(~w(garfunkel simon))) ==
               1.0
    end

    test "partial overlap scores between" do
      score = Similarity.dice(MapSet.new(~w(a b)), MapSet.new(~w(b c)))

      assert score > 0.0 and score < 1.0
    end

    test "two empty sets are unknown, not identical" do
      # Returning 1.0 here would make every pair of tracks with no artists
      # credited a perfect match.
      assert Similarity.dice(MapSet.new(), MapSet.new()) == nil
    end

    test "one empty set is a real disagreement" do
      assert Similarity.dice(MapSet.new(["a"]), MapSet.new()) == 0.0
    end
  end

  describe "duration_proximity/2" do
    test "within the tolerance is full marks" do
      assert Similarity.duration_proximity(180, 180) == 1.0
      assert Similarity.duration_proximity(180, 182) == 1.0
    end

    test "tapers rather than stepping" do
      near = Similarity.duration_proximity(180, 185)
      far = Similarity.duration_proximity(180, 192)

      assert near > far
      assert far > 0.0
    end

    test "beyond the far bound scores nothing" do
      assert Similarity.duration_proximity(180, 300) == 0.0
    end

    test "is symmetric" do
      assert Similarity.duration_proximity(180, 190) == Similarity.duration_proximity(190, 180)
    end

    test "an unknown duration is nil, not zero" do
      # The distinction the whole module is built on. `0.0` would say the
      # durations disagree, pushing a track with a missing field towards "no
      # match" — precisely the tracks that need the other signals most.
      assert Similarity.duration_proximity(180, nil) == nil
      assert Similarity.duration_proximity(nil, 180) == nil
      assert Similarity.duration_proximity(nil, nil) == nil
    end
  end

  describe "weighted_mean/1" do
    test "weights are respected" do
      assert Similarity.weighted_mean([{1.0, 3}, {0.0, 1}]) == 0.75
    end

    test "an absent signal costs its weight too, not just its value" do
      # The bug this guards: dividing by the declared total weight rather than
      # the weight actually used. With the second signal absent, dividing by 4
      # gives 0.25 — below both inputs, and below what a *disagreeing* second
      # signal would have produced.
      assert Similarity.weighted_mean([{1.0, 3}, {nil, 1}]) == 1.0
    end

    test "all absent is unknown" do
      assert Similarity.weighted_mean([{nil, 3}, {nil, 1}]) == nil
      assert Similarity.weighted_mean([]) == nil
    end

    test "the result never leaves the unit interval" do
      assert Similarity.weighted_mean([{1.0, 5}, {1.0, 5}]) == 1.0
      assert Similarity.weighted_mean([{0.0, 5}, {0.0, 5}]) == 0.0
    end
  end
end
