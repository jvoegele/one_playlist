defmodule OnePlaylist.Transfers.SurplusTest do
  @moduledoc """
  Which destination tracks a replace run is allowed to delete.

  This is the only code in the application that removes somebody's music, and
  every rule it follows is a rule about *not* doing that. So it is tested as a
  pure function over three values, with no provider, no database and no HTTP —
  the decision is the dangerous part, and the decision is entirely here.

  `OnePlaylist.TransfersTest` covers the same ground end to end, once. This
  covers the cases that end-to-end tests are bad at: the ones where the right
  answer is "remove nothing" for a reason that is easy to code away.
  """

  use ExUnit.Case, async: true
  use Bond.Test

  alias OnePlaylist.Matching.Match
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Transfers.Runner
  alias OnePlaylist.Transfers.Transfer

  defp track(id, title \\ "Song") do
    %Track{provider: :tidal, provider_id: id, title: title, artists: ["Somebody"]}
  end

  # A source track that matched to `destination_id`.
  defp matched(position, destination_id) do
    source = track("src-#{position}")

    {position, source,
     {:ok, %Match{source: source, track: track(destination_id), score: 1.0, strategy: :isrc}}}
  end

  defp unmatched(position) do
    {position, track("src-#{position}"), {:error, %RuntimeError{message: "nope"}}}
  end

  defp replace, do: %Transfer{mode: :replace}
  defp add, do: %Transfer{mode: :add}

  describe "add mode" do
    test "removes nothing, whatever the destination holds" do
      held = [track("d1"), track("d2")]

      assert {:ok, []} = Runner.surplus(add(), [matched(0, "d1")], held)
    end
  end

  describe "replace mode" do
    test "removes a track the source no longer accounts for" do
      held = [track("d1"), track("gone", "Deleted From Source")]

      assert {:ok, [removed]} = Runner.surplus(replace(), [matched(0, "d1")], held)
      assert removed.provider_id == "gone"
    end

    test "keeps everything the source still matches to" do
      held = [track("d1"), track("d2")]
      resolutions = [matched(0, "d1"), matched(1, "d2")]

      assert {:ok, []} = Runner.surplus(replace(), resolutions, held)
    end

    test "removes several at once" do
      held = [track("d1"), track("x"), track("y")]

      assert {:ok, removed} = Runner.surplus(replace(), [matched(0, "d1")], held)
      assert Enum.map(removed, & &1.provider_id) == ["x", "y"]
    end

    # `remove_tracks/4` takes out every occurrence, so asking twice would report
    # two removals for one track and the second call would remove nothing.
    test "asks once for a track the destination holds twice" do
      held = [track("dup"), track("dup"), track("d1")]

      assert {:ok, [removed]} = Runner.surplus(replace(), [matched(0, "d1")], held)
      assert removed.provider_id == "dup"
    end

    # The same limitation, seen from the other side and accepted: the mirror
    # cannot express "the source has this once and the destination twice".
    test "keeps a duplicate the source has only once" do
      held = [track("d1"), track("d1")]

      assert {:ok, []} = Runner.surplus(replace(), [matched(0, "d1")], held)
    end
  end

  describe "the safety rules" do
    # The one that matters most. A destination track is known to belong only
    # because some source track matched to it — so a run where matching went
    # wrong cannot tell "the source dropped this" from "the search failed".
    test "an unmatched row withholds the whole removal" do
      held = [track("d1"), track("gone")]
      resolutions = [matched(0, "d1"), unmatched(1)]

      assert {:ok, []} = Runner.surplus(replace(), resolutions, held)
    end

    test "even when the unmatched row is the only one" do
      held = [track("d1"), track("d2")]

      assert {:ok, []} = Runner.surplus(replace(), [unmatched(0)], held)
    end

    # An empty source is far more often a glitch or a deleted playlist than an
    # instruction to empty the mirror, and from here the two look identical.
    test "an empty source removes nothing" do
      held = [track("d1"), track("d2")]

      assert {:ok, []} = Runner.surplus(replace(), [], held)
    end

    test "an empty destination is not an error" do
      assert {:ok, []} = Runner.surplus(replace(), [matched(0, "d1")], [])
    end
  end

  describe "recording what went" do
    # The cap exists so that a replace run against a mirror somebody abandoned
    # cannot write an unbounded column. Tested here rather than through the
    # pipeline because no realistic end-to-end fixture removes a hundred tracks,
    # which is exactly why mutating the cap survived the whole suite until this.
    test "the count is exact past the cap, and the list is not" do
      removed = for n <- 1..150, do: track("d#{n}", "Song #{n}")

      recorded = Transfer.with_removals(%Transfer{}, removed)

      assert recorded.removed_count == 150
      assert length(recorded.removed_tracks) == 100
    end

    test "names each removal by what a person would recognise" do
      recorded = Transfer.with_removals(%Transfer{}, [track("d1", "Ceremony")])

      assert [%{"provider_id" => "d1", "title" => "Ceremony", "artist" => "Somebody"}] =
               recorded.removed_tracks
    end

    test "removing nothing records nothing" do
      recorded = Transfer.with_removals(%Transfer{removed_count: 3}, [])

      assert recorded.removed_count == 0
      assert recorded.removed_tracks == []
    end
  end
end
