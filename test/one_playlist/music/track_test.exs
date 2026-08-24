defmodule OnePlaylist.Music.TrackTest do
  @moduledoc """
  The core domain struct, and the questions about a track that belong on it
  rather than in the modules that ask them.

  `search_query/1` is wanted identically by `Providers.Tidal` and
  `Providers.Navidrome`; `same_position?/2` reads fields Subsonic carries as
  well as TIDAL; `identity/1` is the key `Matching` builds its ledger from.
  Housing them here is also what makes the invariant possible — a module with
  no function taking or returning a `%Track{}` has nowhere for one to be
  checked.
  """

  use ExUnit.Case, async: true
  use Bond.Test

  alias OnePlaylist.Music.Track

  doctest OnePlaylist.Music.Track

  defp track(fields \\ []) do
    struct!(%Track{provider: :tidal, provider_id: "t1"}, fields)
  end

  describe "the invariant" do
    test "a track with no usable id is rejected" do
      # `to_string(nil)` is `""`, so a provider omitting an id yields a track
      # that compares equal to every other id-less track. Runner's
      # snapshot-and-diff then treats them as one and either duplicates a track
      # or silently skips one.
      assert_invariant_violation(Track.identity(%Track{provider: :tidal, provider_id: ""}),
        label: :identifiable
      )
    end

    test "a nil artist list is rejected before it becomes an improper list" do
      # `[title | nil]` is improper, so `Enum.filter/2` raises a
      # Protocol.UndefinedError naming nothing useful. The type check earns its
      # place by converting that into a named violation.
      assert_invariant_violation(Track.search_query(track(artists: nil)),
        label: :artists_is_a_list
      )
    end

    test "a negative duration is rejected" do
      # Not a shorter track — a value that scores as a near miss against real
      # durations in the matching engine.
      assert_invariant_violation(Track.identity(track(duration_seconds: -5)),
        label: :duration_is_never_negative
      )
    end

    test "a track built by a mapper satisfies it" do
      assert Track.identity(track(duration_seconds: 240, artists: ["Moby Grape"])) ==
               {:tidal, "t1"}
    end
  end

  describe "search_query/1" do
    test "an absent field leaves no trace" do
      # The invariant constrains the artist list, not its members, so a `nil`
      # among them is permitted here and must not reach the query.
      assert Track.search_query(track(title: "Omaha", artists: [nil, "Moby Grape"])) ==
               "Omaha Moby Grape"
    end

    test "a track with nothing to search by is the empty string, not a crash" do
      assert Track.search_query(track()) == ""
    end
  end

  describe "same_position?/2" do
    test "an unknown position never matches another unknown" do
      # The dangerous direction: two untagged tracks sharing a barcode would
      # otherwise pair off arbitrarily, which is a false positive rather than a
      # missed match.
      refute Track.same_position?(track(), track())
      refute Track.same_position?(track(track_number: 3), track())
    end

    test "a missing volume is disc one" do
      assert Track.same_position?(
               track(track_number: 3),
               track(track_number: 3, volume_number: 1)
             )

      refute Track.same_position?(
               track(track_number: 3, volume_number: 2),
               track(track_number: 3)
             )
    end
  end

  describe "primary_artist/1" do
    test "is the first credit, or nil" do
      assert Track.primary_artist(track(artists: ["Paul Simon", "Art Garfunkel"])) == "Paul Simon"
      assert Track.primary_artist(track()) == nil
    end
  end
end
