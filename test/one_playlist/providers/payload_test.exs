defmodule OnePlaylist.Providers.PayloadTest do
  @moduledoc """
  The boundary between a stranger's JSON and the values the matching engine
  compares.

  Each of these was a private helper duplicated across the two provider mappers.
  Gathering them means the law each one upholds is stated once and inherited by
  every provider, present and future — which is the whole argument for the
  module existing.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  use Bond.Test

  alias OnePlaylist.Providers.Payload

  doctest OnePlaylist.Providers.Payload

  describe "text/1" do
    test "the empty string is the value this exists to remove" do
      # An ISRC is compared for exact equality by the most trusted rung of the
      # ladder, so two tracks both carrying "" match each other perfectly — a
      # false positive arriving from two providers that left a field empty.
      assert Payload.text("") == nil
    end

    test "anything that is not a string is nothing" do
      for value <- [nil, 42, [], %{}, :atom, ["a"]] do
        assert Payload.text(value) == nil, "#{inspect(value)} is not text"
      end
    end
  end

  describe "count/1 and position/1 differ on zero" do
    test "zero is a count but not a position" do
      # A release has no track 0. Rung 2 pairs a barcode with a position, so a
      # zero would be compared against real positions.
      assert Payload.count(0) == 0
      assert Payload.position(0) == nil
    end

    test "neither accepts a negative" do
      # The bug on record: TIDAL's numberOfItems passed straight through, and a
      # negative reached Playlist.track_count, where transfer reports count
      # against it.
      assert Payload.count(-3) == nil
      assert Payload.position(-1) == nil
    end
  end

  describe "timestamp/1" do
    test "unparseable input is nil rather than an exception" do
      # A missing timestamp costs a column in a listing; raising costs the whole
      # library read.
      for value <- ["not a date", "", nil, 42, "2026-13-45T99:99:99Z"] do
        assert Payload.timestamp(value) == nil, "#{inspect(value)} is not a timestamp"
      end
    end
  end

  describe "the contracts hold over arbitrary provider values" do
    property "nothing raises, and every promise is kept" do
      # contracts.md: at a parsing boundary, assert what you emit and never what
      # you received. These functions must be *total* over anything a provider
      # can put in a JSON field — the contracts are the oracle.
      check all(
              value <-
                one_of([
                  term(),
                  string(:printable),
                  integer(),
                  constant(nil),
                  list_of(string(:alphanumeric), max_length: 3)
                ])
            ) do
        assert Payload.text(value) == nil or is_binary(Payload.text(value))
        assert Payload.count(value) == nil or Payload.count(value) >= 0
        assert Payload.position(value) == nil or Payload.position(value) > 0
        assert Payload.timestamp(value) == nil or is_struct(Payload.timestamp(value), DateTime)
      end
    end
  end
end
