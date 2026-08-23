defmodule OnePlaylist.Matching.SignalsTest do
  @moduledoc """
  The per-comparison signals, and the invariant bounding them.

  Barcode normalization used to live here too, and moved out with the function
  itself — see `OnePlaylist.Music.BarcodeTest`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  use Bond.Test

  alias OnePlaylist.Matching.Signals
  alias OnePlaylist.Music.Track

  doctest OnePlaylist.Matching.Signals

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
