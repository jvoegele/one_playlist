defmodule OnePlaylist.Transfers.TransferItemTest do
  @moduledoc """
  Report rows — the product's differentiator, and the place a silent failure
  looks most like success.
  """

  use ExUnit.Case, async: true
  use Bond.Test
  use Errata

  alias OnePlaylist.Matching.Match
  alias OnePlaylist.Matching.TrackNotMatched
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Transfers.TransferItem

  doctest OnePlaylist.Transfers.TransferItem

  defp source do
    %Track{provider: :tidal, provider_id: "s1", title: "Omaha", artists: ["Moby Grape"]}
  end

  defp match_to(provider_id) do
    Match.new(
      source: source(),
      track: %Track{provider: :navidrome, provider_id: provider_id, title: "Omaha"},
      score: 1.0,
      strategy: :isrc
    )
  end

  describe "matched/4" do
    test "a row that resolved names what it resolved to" do
      # Falsifiable by data, not only by mutation: `provider_id` is
      # `to_string(resource["id"])` in the mappers, and `to_string(nil)` is `""`.
      # A provider omitting an id on one entry produces a row that says
      # "matched" and names nothing — the report claiming success with no
      # evidence, which is this application's defining failure mode.
      assert_postcondition_violation(
        TransferItem.matched(%{}, 0, match_to(""), true),
        label: :names_what_it_matched
      )
    end

    test "added? decides between the two resolved outcomes and nothing else" do
      assert TransferItem.matched(%{}, 0, match_to("d1"), true).outcome == :matched
      assert TransferItem.matched(%{}, 0, match_to("d1"), false).outcome == :already_present
    end
  end

  describe "unmatched/4" do
    test "a row that failed says why" do
      row = TransferItem.unmatched(%{}, 0, source(), no_candidates())

      assert row.outcome == :unmatched
      assert row.reason == "no_candidates"
    end

    test "the reason is what makes the report worth reading" do
      # "nothing was found" and "four were found and none was good enough" are
      # different problems with different fixes, and only the second is worth
      # offering the user a manual choice for.
      row = TransferItem.unmatched(%{}, 1, source(), all_rejected())

      assert row.reason == "all_rejected"
      assert row.candidates_considered == 3
    end
  end

  defp no_candidates do
    Errata.create(TrackNotMatched, reason: :no_candidates, context: %{source_id: "s1"})
  end

  defp all_rejected do
    Errata.create(TrackNotMatched,
      reason: :all_rejected,
      context: %{source_id: "s1", candidates_considered: 3}
    )
  end
end
