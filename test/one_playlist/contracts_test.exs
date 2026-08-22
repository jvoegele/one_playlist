defmodule OnePlaylist.ContractsTest do
  @moduledoc """
  Proof that the contracts added for the caching and matching layers can fire.

  `Bond.Coverage` reports an assertion that runs and never fails as a candidate
  for vacuity, and `docs/reference/contracts.md` treats that as a prompt rather
  than a verdict. These are the answer to it: each test drives one contract to
  failure through the public API, so the coverage table's `✓` is earned rather
  than assumed.

  The `Singleflight` invariants are not here, and cannot be: they constrain a
  GenServer's private state, which no caller can put into a bad shape. They are
  verified by mutation instead — see the commit.
  """

  # DataCase because the one non-violating case reaches L2.
  use OnePlaylist.DataCase, async: true
  use Bond.Test

  alias OnePlaylist.Catalogue
  alias OnePlaylist.Matching.Match
  alias OnePlaylist.MusicFixtures

  describe "Catalogue barcode normalization" do
    test "an unnormalized barcode is rejected before it can split the cache" do
      # A leading zero is not a wrong answer, it is a *different cache key* for
      # the same release: the caller silently gets its own private copy of every
      # lookup and writes a second row for a release that already has one.
      assert_precondition_violation(
        Catalogue.album_id(:tidal, "00602547670052", fn -> {:ok, "album"} end),
        label: :normalized_barcode
      )
    end

    test "anything that is not digits is rejected too" do
      assert_precondition_violation(
        Catalogue.album_id(:tidal, "602-547-670052", fn -> {:ok, "album"} end),
        label: :normalized_barcode
      )
    end

    test "forgetting is held to the same rule" do
      # Otherwise `forget/2` could miss the entry it was called to remove, and
      # the stale id that prompted the call would keep being served.
      assert_precondition_violation(Catalogue.forget(:tidal, "00602547670052"),
        label: :normalized_barcode
      )
    end

    test "a normalized barcode passes" do
      assert {:ok, "album"} =
               Catalogue.album_id(:tidal, "602547678811", fn -> {:ok, "album"} end)
    end
  end

  describe "Match score bands" do
    test "a score outside its strategy's band is caught wherever it is built" do
      # The bug: a future rung calling `Match.new(score: raw, ...)` and
      # forgetting `in_band/2`, which is a separate call. The result reads
      # plausibly and outranks rungs that are more trustworthy.
      assert_invariant_violation(
        Match.new(
          source: MusicFixtures.track([]),
          track: MusicFixtures.track([]),
          score: 0.5,
          strategy: :isrc
        ),
        label: :score_within_its_strategys_band
      )
    end

    test "a fuzzy score above the fuzzy ceiling is caught" do
      assert_invariant_violation(
        Match.new(
          source: MusicFixtures.track([]),
          track: MusicFixtures.track([]),
          score: 0.95,
          strategy: :fuzzy
        ),
        label: :score_within_its_strategys_band
      )
    end

    test "a strategy with no band at all is caught" do
      assert_invariant_violation(
        Match.new(
          source: MusicFixtures.track([]),
          track: MusicFixtures.track([]),
          score: 0.9,
          strategy: :vector
        ),
        label: :score_within_its_strategys_band
      )
    end

    test "a properly banded score passes" do
      match =
        Match.new(
          source: MusicFixtures.track([]),
          track: MusicFixtures.track([]),
          score: Match.in_band(1.0, :fuzzy),
          strategy: :fuzzy
        )

      assert match.score == 0.79
      assert match.confidence == :medium
    end
  end
end
