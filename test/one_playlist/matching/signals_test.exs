defmodule OnePlaylist.Matching.SignalsTest do
  @moduledoc """
  Barcode normalization, which is load-bearing in a way that is easy to miss.

  Its output feeds an **exact equality** test in
  `OnePlaylist.Matching.Strategy.UpcPosition` and a cache key in
  `OnePlaylist.Catalogue`. A subtly wrong normalization does not produce a wrong
  match; it produces *no* match, silently, for every cross-service comparison —
  and a cache that never hits.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  use Bond.Test

  alias OnePlaylist.Matching.Signals
  alias OnePlaylist.Music.Track

  doctest OnePlaylist.Matching.Signals

  describe "normalize_barcode/1" do
    test "strips the zero padding that distinguishes an EAN-13 from a UPC-12" do
      # The documented case: TIDAL reports "00602547670052" for a barcode other
      # catalogues print as "602547670052".
      assert Signals.normalize_barcode("00602547670052") == "602547670052"
      assert Signals.normalize_barcode("602547670052") == "602547670052"
    end

    test "keeps trailing zeros" do
      # Not hypothetical, and the reason `String.trim_leading/2` is used rather
      # than `String.trim/2`: the latter reads as tidier and would silently
      # truncate every barcode ending in zero, turning an exact identifier into
      # a near-miss that matches nothing.
      assert Signals.normalize_barcode("602547670050") == "602547670050"
      assert Signals.normalize_barcode("00602547670000") == "602547670000"
    end

    test "removes separators" do
      assert Signals.normalize_barcode("6-025 476.70052") == "602547670052"
    end

    test "anything with no digits at all is nil" do
      assert Signals.normalize_barcode("") == nil
      assert Signals.normalize_barcode("no digits here") == nil
      assert Signals.normalize_barcode("0000") == nil
      assert Signals.normalize_barcode(nil) == nil
    end

    property "is idempotent" do
      # The property a cache key needs: normalizing an already-normalized value
      # must not change it, or the same release keys two cache entries.
      check all(raw <- string(:alphanumeric, max_length: 20)) do
        once = Signals.normalize_barcode(raw)

        assert Signals.normalize_barcode(once) == once
      end
    end

    property "zero padding never changes the answer" do
      check all(
              digits <- string(?1..?9, min_length: 1, max_length: 1),
              rest <- string(?0..?9, min_length: 1, max_length: 12),
              padding <- integer(0..4)
            ) do
        barcode = digits <> rest
        padded = String.duplicate("0", padding) <> barcode

        assert Signals.normalize_barcode(padded) == Signals.normalize_barcode(barcode)
      end
    end

    property "the result is digits only, and never starts with zero" do
      check all(raw <- string(:printable, max_length: 24)) do
        case Signals.normalize_barcode(raw) do
          nil -> :ok
          normalized -> assert normalized =~ ~r/^[1-9][0-9]*$/
        end
      end
    end
  end

  describe "the invariant" do
    test "a similarity outside 0..1 is rejected" do
      # The bug this exists for is not a crash. A 1.5 is a float, nothing
      # raises, and it goes straight into the weighted mean both rungs use —
      # dragging a non-match over the confidence threshold so a transfer adds
      # the wrong recording and reports it as a match.
      for field <- [:title, :artists, :album, :duration] do
        assert_invariant_violation(
          Signals.vetoed?(struct!(Signals, [{field, 1.5}])),
          label: :similarities_are_proportions
        )

        assert_invariant_violation(
          Signals.vetoed?(struct!(Signals, [{field, -0.2}])),
          label: :similarities_are_proportions
        )
      end
    end

    test "nil is allowed, because it means something different from zero" do
      # "could not be compared" is not "not similar". An absent album must not
      # score as a mismatch, or every track missing one is penalised for it.
      assert Signals.vetoed?(%Signals{title: nil, artists: nil, album: nil, duration: nil}) ==
               false
    end

    test "a bare %Signals{} satisfies its own invariant" do
      # Meyer's base case: `%Signals{}` is always constructible, so the defstruct
      # defaults are part of the contract whether or not they were meant to be.
      # Every default here is the "nothing to say" value, and every one is valid.
      refute Signals.vetoed?(%Signals{})
      assert Signals.editorial_penalty(%Signals{}) == nil
    end

    test "holds for a real comparison" do
      # The exit check on compare/2 — the only place the invariant guards output
      # rather than input, and the one that would catch a similarity function
      # that started returning something out of range.
      a = %Track{
        provider: :tidal,
        provider_id: "1",
        title: "Hey Grandma",
        artists: ["Moby Grape"]
      }

      b = %Track{
        provider: :navidrome,
        provider_id: "2",
        title: "Hey Grandma",
        artists: ["Moby Grape"]
      }

      assert %Signals{} = Signals.compare(a, b)
    end
  end

  describe "vetoed?/1" do
    test "a discriminating conflict vetoes regardless of how well everything else agrees" do
      # The point of a veto: no amount of title and artist agreement makes a
      # karaoke version the studio recording.
      perfect_but_live = %Signals{
        title: 1.0,
        title_exact: true,
        artists: 1.0,
        artists_agree: true,
        album: 1.0,
        duration: 1.0,
        discriminating_conflict: true
      }

      assert Signals.vetoed?(perfect_but_live)
    end
  end

  describe "editorial_penalty/1" do
    test "is only ever a penalty, never a reward" do
      # Was written out identically in both scoring rungs. Agreement about
      # editorial tags is usually agreement that neither side labelled anything,
      # so scoring it as similarity would reward silence — two untagged tracks
      # would earn a point for having nothing to say.
      assert Signals.editorial_penalty(%Signals{editorial_conflict: true}) == 0.0
      assert Signals.editorial_penalty(%Signals{editorial_conflict: false}) == nil
    end
  end
end
