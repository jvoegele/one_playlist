defmodule OnePlaylist.Matching.MatchTest do
  @moduledoc """
  The law that makes a score comparable across rungs.

  `matching_property_test.exs` drives `Match.new/1` across every strategy and
  never sees the invariant fail — necessarily, because it always passes a score
  that has already been through `Confidence.in_band/2`. As its own comment says,
  that makes it a property about `in_band/2` rather than about the invariant.

  This is the other half: the mistake the invariant exists to catch, made on
  purpose.
  """

  use ExUnit.Case, async: true
  use Bond.Test

  alias OnePlaylist.Matching.Confidence
  alias OnePlaylist.Matching.Match

  import OnePlaylist.MusicFixtures, only: [track: 1]

  defp fields(overrides) do
    Keyword.merge(
      [source: track(title: "Corduroy"), track: track(title: "Corduroy"), strategy: :fuzzy],
      overrides
    )
  end

  describe "score_within_its_strategys_band" do
    test "a raw score handed straight to new/1 is rejected" do
      # `Match.new/1` is public and takes a bare keyword list, and the scaling
      # is a *separate* call. The next rung's author who forgets it produces a
      # match whose confidence reads plausibly and outranks rungs that are more
      # trustworthy — this product's worst failure mode wearing a believable
      # number.
      #
      # `:fuzzy` tops out at 0.79, so an unscaled 0.95 is exactly that mistake.
      assert_invariant_violation(Match.new(fields(score: 0.95)),
        label: :score_within_its_strategys_band
      )
    end

    test "and so is a score below its band" do
      # The other direction, which matters for the identifier rungs: `:isrc`
      # starts at 0.99, so a scaled-looking 0.5 would make an exact identifier
      # match rank below a text one.
      assert_invariant_violation(Match.new(fields(score: 0.5, strategy: :isrc)),
        label: :score_within_its_strategys_band
      )
    end

    test "the same score is fine once it has been scaled" do
      # The positive control. Without it this file proves only that some scores
      # are rejected, not that the band is the reason.
      scaled = Confidence.in_band(0.95, :fuzzy)

      assert %Match{} = match = Match.new(fields(score: scaled))
      assert match.confidence == Confidence.for_score(scaled, :fuzzy)
    end
  end
end
