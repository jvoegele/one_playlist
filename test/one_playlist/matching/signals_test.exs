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

  alias OnePlaylist.Matching.Signals

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
end
