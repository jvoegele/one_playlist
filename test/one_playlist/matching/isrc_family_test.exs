defmodule OnePlaylist.Matching.Strategy.IsrcFamilyTest do
  @moduledoc """
  Rung 1b: a recording recognised by an identifier it is also known by.
  """

  use ExUnit.Case, async: true

  import OnePlaylist.MusicFixtures

  alias OnePlaylist.Matching

  # The real pair from the transfer that motivated this: Roon exports the 2007
  # soundtrack's code, TIDAL holds the 2017 reissue's, and they are one
  # recording.
  @roon "USJY50700001"
  @tidal "USJY51700100"

  describe "a reissue's identifier" do
    test "matches, and says where the certainty came from" do
      source =
        track(title: "Setting Forth", artists: ["Eddie Vedder"], isrc: @roon)
        |> Map.put(:isrc_family, [@roon, @tidal])

      candidate = track(title: "Setting Forth", isrc: @tidal, provider_id: "c1")

      assert {:ok, match} = Matching.match(source, [candidate])

      assert match.strategy == :isrc_family
      assert match.confidence == :linked_isrc

      assert match.score < 1.0,
             "a third party's judgment that two codes agree is not the codes agreeing"
    end

    test "loses to the identifier agreeing outright" do
      # Both rungs can answer; the stronger fact has to win, or the reported
      # confidence would depend on which rung ran first.
      source =
        track(title: "Setting Forth", isrc: @roon)
        |> Map.put(:isrc_family, [@roon, @tidal])

      exact = track(title: "Setting Forth", isrc: @roon, provider_id: "exact")
      linked = track(title: "Setting Forth", isrc: @tidal, provider_id: "linked")

      assert {:ok, match} = Matching.match(source, [linked, exact])

      assert match.track.provider_id == "exact"
      assert match.strategy == :isrc
    end

    test "is refused when the lengths disagree" do
      # The care this rung takes and the rung above does not. An exact
      # identifier is trusted over a mislabelled duration; a *linked* one has
      # not earned that, because the link is somebody's edit.
      source =
        track(title: "Setting Forth", isrc: @roon, duration_seconds: 97)
        |> Map.put(:isrc_family, [@roon, @tidal])

      wrong_length =
        track(title: "Setting Forth", isrc: @tidal, duration_seconds: 400, provider_id: "c1")

      assert {:error, _reason} = Matching.match(source, [wrong_length])
    end

    test "prefers the copy on the source's own release" do
      # A recording is commonly linked to several releases, and all of them are
      # in the family. Scored identically the winner was whichever the sort put
      # first — 2Pac's "How Do U Want It" resolved to a compilation while the
      # copy on the source's own album was on offer.
      #
      # The identifier says which *recording*. It says nothing about which copy,
      # and that is what the band exists to order.
      source =
        track(
          title: "How Do U Want It",
          album: "All Eyez on Me",
          duration_seconds: 287,
          # Twelve alphanumerics, or `Isrc.normalize/1` rejects them and this
          # rung never runs at all.
          isrc: "USAAA0000001"
        )
        |> Map.put(:isrc_family, ["USAAA0000001", "USAAA0000002", "USAAA0000003"])

      compilation =
        track(
          title: "How Do U Want It",
          album: "The Best of 2Pac",
          duration_seconds: 287,
          isrc: "USAAA0000002",
          provider_id: "compilation"
        )

      own_album =
        track(
          title: "How Do U Want It",
          album: "All Eyez on Me",
          duration_seconds: 288,
          isrc: "USAAA0000003",
          provider_id: "own-album"
        )

      assert {:ok, match} = Matching.match(source, [compilation, own_album])

      assert match.track.provider_id == "own-album"
      assert match.strategy == :isrc_family
    end

    test "does nothing without a family" do
      source = track(title: "Setting Forth", isrc: @roon)
      candidate = track(title: "Setting Forth", isrc: @tidal, provider_id: "c1")

      # Falls through to the text rung, which sees two different identifiers and
      # scores on the words alone.
      assert {:ok, match} = Matching.match(source, [candidate])
      refute match.strategy == :isrc_family
    end
  end
end
