defmodule OnePlaylist.Library.IdentitiesTest do
  @moduledoc """
  The identity spine — `docs/reference/domain.md` §5's L5.

  What is worth testing is not that a row round-trips but that the spine refuses
  to learn the wrong things. A wrong identity is applied silently to every future
  transfer of a recording and nothing re-derives it, so the interesting cases are
  all about what does **not** get in.
  """

  use OnePlaylist.DataCase, async: true
  use Bond.Test

  alias OnePlaylist.Library.Identities
  alias OnePlaylist.Library.Identity
  alias OnePlaylist.Matching.Match
  alias OnePlaylist.Music.Track

  # `ZZ` is an unassigned ISRC country code, so a fixture cannot collide with
  # music in the dev database this shares. See `OnePlaylist.LibraryTest`.
  defp unique_isrc do
    "ZZZ9925" <>
      String.pad_leading(to_string(rem(System.unique_integer([:positive]), 100_000)), 5, "0")
  end

  defp track(attrs \\ %{}) do
    struct!(
      %Track{
        provider: :tidal,
        provider_id: "t-#{System.unique_integer([:positive])}",
        title: "Corduroy",
        artists: ["Pearl Jam"],
        album: "Vitalogy",
        isrc: unique_isrc()
      },
      attrs
    )
  end

  describe "anchor/1" do
    test "an ISRC-bearing track becomes a recording the spine can hang off" do
      assert recording = Identities.anchor(track())
      assert recording.id
    end

    test "the same ISRC anchors to the same recording, however it arrives" do
      # The whole reason the hub is worth having: a TIDAL track and a Navidrome
      # track that are the same recording must land on one row, or the spine
      # records two half-answers instead of one whole one.
      isrc = unique_isrc()

      from_tidal = Identities.anchor(track(%{isrc: isrc}))
      from_navidrome = Identities.anchor(track(%{isrc: isrc, provider: :navidrome}))

      assert from_tidal.id == from_navidrome.id
    end

    test "a track with no ISRC anchors to nothing, rather than to a guess" do
      # Not a failure. `Library.find_or_create/1` joins only on a canonical ISRC
      # because merging two recordings that turn out to be one is reversible and
      # splitting one that was never two is not — so a track with no ISRC
      # teaches the spine nothing rather than filling it with duplicates.
      refute Identities.anchor(track(%{isrc: nil}))
    end
  end

  describe "record/4" do
    test "remembers where a recording lives at a service" do
      recording = Identities.anchor(track())
      found = track(%{provider: :navidrome, provider_id: "al-9f21", title: "Corduroy"})

      assert :ok = Identities.record(recording, found, :isrc, 1.0)

      assert %Match{} = match = Identities.recall(recording, track(), :navidrome)
      assert match.track.provider_id == "al-9f21"
      assert match.track.provider == :navidrome
    end

    test "refuses evidence weaker than an exact identifier" do
      # The rule the whole module exists to hold. A `:high` text match is good
      # enough to put a track in a playlist, where a person sees the result. It
      # is not good enough to assert as a fact about the world's music, for
      # ever, unreviewed.
      recording = Identities.anchor(track())
      found = track(%{provider: :navidrome, provider_id: "al-1"})

      assert_precondition_violation(Identities.record(recording, found, :text, 0.95),
        label: :evidence_is_at_least_trustworthy
      )
    end

    test "accepts every rung at or above an exact barcode" do
      recording = Identities.anchor(track())

      for {strategy, score} <- [
            {:isrc, 1.0},
            {:upc_position, 1.0},
            {:isrc_family, 0.97},
            {:manual, 1.0},
            {:stored, 1.0}
          ] do
        assert :ok =
                 Identities.record(
                   recording,
                   track(%{provider: :navidrome, provider_id: "al-#{score}"}),
                   strategy,
                   score
                 )
      end
    end

    test "records nothing for a track with no id at the service" do
      recording = Identities.anchor(track())

      assert :ok = Identities.record(recording, track(%{provider_id: nil}), :isrc, 1.0)
      assert :ok = Identities.record(recording, track(%{provider_id: ""}), :isrc, 1.0)

      assert Identities.for_recording(recording) == []
    end

    test "records nothing against a recording that could not be anchored" do
      assert :ok = Identities.record(nil, track(), :isrc, 1.0)
    end

    test "records nothing for the library itself" do
      # A library track's `provider_id` *is* the recording's id, so the row would
      # restate its own primary key. A real import wrote 128 of them before this
      # clause existed, and nothing ever read one: a destination that accepts any
      # track skips the spine entirely.
      recording = Identities.anchor(track())

      assert :ok =
               Identities.record(
                 recording,
                 %Track{provider: :library, provider_id: recording.id, title: "Corduroy"},
                 :stored,
                 1.0
               )

      assert Identities.for_recording(recording) == []
    end

    test "one answer per service, and better evidence replaces weaker" do
      recording = Identities.anchor(track())

      Identities.record(
        recording,
        track(%{provider: :navidrome, provider_id: "weak"}),
        :isrc_family,
        0.95
      )

      Identities.record(
        recording,
        track(%{provider: :navidrome, provider_id: "strong"}),
        :isrc,
        1.0
      )

      assert [%Identity{provider_id: "strong"}] =
               Identities.for_recording(recording) |> Enum.filter(&(&1.provider == :navidrome))
    end

    test "weaker evidence does not displace stronger" do
      # A spine that answers with whatever it learned most recently is not a
      # spine. The `where` on the upsert is what holds this, so it is also true
      # of two transfers racing.
      recording = Identities.anchor(track())

      Identities.record(
        recording,
        track(%{provider: :navidrome, provider_id: "strong"}),
        :isrc,
        1.0
      )

      Identities.record(
        recording,
        track(%{provider: :navidrome, provider_id: "weak"}),
        :isrc_family,
        0.95
      )

      assert [%Identity{provider_id: "strong"}] =
               Identities.for_recording(recording) |> Enum.filter(&(&1.provider == :navidrome))
    end
  end

  describe "an identity that names nothing" do
    test "cannot be turned into a track, because recall would claim an impossible match" do
      # `to_track/1` rather than `changeset/2`: a changeset is handed an *empty*
      # struct and returns a `%Ecto.Changeset{}`, so the invariant only ever
      # sees the blank input and cannot fire there. `validate_required/2`
      # covers the write path anyway — an empty string reads as missing.
      #
      # What the invariant guards is everywhere else: a struct that reached
      # memory naming nothing would produce a `%Track{}` with no id, the
      # destination would be asked to add nothing, and the report would claim a
      # match that cannot exist.
      assert_invariant_violation(
        Identity.to_track(%Identity{provider: :navidrome, provider_id: ""}),
        label: :names_a_track_at_the_service
      )
    end

    test "an empty id is refused on the way in, too" do
      recording = Identities.anchor(track())

      changeset =
        Identity.changeset(%Identity{}, %{
          recording_id: recording.id,
          provider: :navidrome,
          provider_id: "",
          strategy: "isrc",
          score: 1.0,
          first_seen_at: DateTime.utc_now(),
          last_confirmed_at: DateTime.utc_now()
        })

      refute changeset.valid?
      assert {"can't be blank", _meta} = changeset.errors[:provider_id]
    end
  end

  describe "recall/3" do
    test "replays why the two tracks correspond, not just that they do" do
      recording = Identities.anchor(track())
      found = track(%{provider: :navidrome, provider_id: "al-1"})

      Identities.record(recording, found, :isrc_family, 0.97)

      assert %Match{} = match = Identities.recall(recording, track(), :navidrome)
      assert match.strategy == :isrc_family
      assert match.confidence == :linked_isrc
      assert match.evidence[:recalled] == true
    end

    test "answers nothing for a service the recording has never been seen at" do
      recording = Identities.anchor(track())

      refute Identities.recall(recording, track(), :navidrome)
    end

    test "will not answer with the source track itself" do
      # Happens on a same-provider transfer, where what the spine knows about
      # the source is trivially also true of the destination. Answering would
      # skip the search to "match" a track to itself — a real shortcut, but a
      # different feature from recall.
      source = track()
      recording = Identities.anchor(source)

      Identities.record(recording, source, :isrc, 1.0)

      refute Identities.recall(recording, source, source.provider)
    end

    test "still answers for a different id at the same service" do
      # The exclusion above is about the source track, not about the service. A
      # recording genuinely located at TIDAL under another id is a real memory.
      source = track()
      recording = Identities.anchor(source)

      Identities.record(recording, track(%{provider: :tidal, provider_id: "other"}), :isrc, 1.0)

      assert %Match{} = match = Identities.recall(recording, source, :tidal)
      assert match.track.provider_id == "other"
    end

    test "carries enough to report the match without asking the service" do
      # The economic claim: recall costs no request, so the snapshot has to hold
      # everything a report row shows.
      recording = Identities.anchor(track())

      found =
        track(%{
          provider: :navidrome,
          provider_id: "al-1",
          title: "Corduroy",
          album: "Vitalogy",
          artwork_url: "https://example.test/c.jpg",
          duration_seconds: 285
        })

      Identities.record(recording, found, :isrc, 1.0)

      assert %Match{track: recalled} = Identities.recall(recording, track(), :navidrome)

      assert recalled.title == "Corduroy"
      assert recalled.album == "Vitalogy"
      assert recalled.artwork_url == "https://example.test/c.jpg"
      assert recalled.duration_seconds == 285
    end
  end

  describe "forget/2" do
    test "removes what a service no longer holds" do
      recording = Identities.anchor(track())

      Identities.record(
        recording,
        track(%{provider: :navidrome, provider_id: "gone"}),
        :isrc,
        1.0
      )

      assert Identities.forget(recording, :navidrome) == 1
      refute Identities.recall(recording, track(), :navidrome)
    end

    test "forgetting what was never known is not an error" do
      assert Identities.forget(Identities.anchor(track()), :navidrome) == 0
      assert Identities.forget(nil, :navidrome) == 0
    end
  end
end
