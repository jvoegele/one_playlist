defmodule OnePlaylist.Matching.SignalsTest do
  @moduledoc """
  The per-comparison signals, and the invariant bounding them.

  Barcode normalization is tested with the function itself, in
  `OnePlaylist.Music.BarcodeTest`, rather than here.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  use Bond.Test

  alias OnePlaylist.Matching.Normalize
  alias OnePlaylist.Matching.Signals
  alias OnePlaylist.Music.Track

  import OnePlaylist.MusicFixtures, only: [track: 1]

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
        credit_match: :same,
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

  describe "duration_conflict" do
    test "far-apart lengths are a conflict, not a weak signal" do
      # The distinction `Similarity.duration_proximity/2` already drew and the
      # weighted mean was throwing away: `nil` means one length is missing,
      # `0.0` means they are far apart. Only the second is evidence.
      near = Signals.compare(track(duration_seconds: 300), track(duration_seconds: 302))
      far = Signals.compare(track(duration_seconds: 300), track(duration_seconds: 480))
      unknown = Signals.compare(track(duration_seconds: 300), track(duration_seconds: nil))

      refute near.duration_conflict
      assert far.duration_conflict
      refute unknown.duration_conflict, "absent evidence is not contrary evidence"
    end

    test "it does not veto every rung" do
      # Deliberately outside `vetoed?`: it stops the text rung, which cannot
      # express doubt, and leaves fuzzy to score the candidate low. See the
      # note on `vetoed?/1`.
      far = Signals.compare(track(duration_seconds: 300), track(duration_seconds: 480))

      assert far.duration_conflict
      refute Signals.vetoed?(far)
    end
  end

  describe "the album a recording is on, when it is on several" do
    test "the best of them decides, not whichever was listed first" do
      # MusicBrainz returns every release a recording appears on, and the
      # matcher used to score against the head of that list. A tagger whose
      # album names any of the others was then declined over a difference that
      # is not one — the recording is on both records.
      source = track(album: "Sounds Eclectic")

      first_only = track(album: "Acoustic", album_titles: [])
      every_release = track(album: "Acoustic", album_titles: ["Acoustic", "Sounds Eclectic"])

      assert Signals.compare(source, first_only).album < 0.5
      assert Signals.compare(source, every_release).album == 1.0
    end

    test "and a set that resembles nothing still scores low" do
      # Widening the comparison is only safe while it stays a comparison. A
      # recording released on thirty compilations must not thereby match every
      # album string it is shown.
      source = track(album: "Vitalogy")

      wide =
        track(
          album: "Now That's What I Call Music 42",
          album_titles: ["Now That's What I Call Music 42", "Party Anthems", "Driving Rock"]
        )

      assert Signals.compare(source, wide).album < 0.6
    end

    test "an empty set is the ordinary provider, and behaves as it always did" do
      # Only MusicBrainz populates it. TIDAL and Subsonic give one album per
      # track, so this must reduce to exactly the previous comparison.
      assert Signals.compare(track(album: "Vitalogy"), track(album: "Vitalogy")).album == 1.0
      assert Signals.compare(track(album: "Vitalogy"), track(album: nil)).album == nil
      assert Signals.compare(track(album: nil), track(album: "Vitalogy")).album == nil
    end
  end

  describe "a subtitle marker against an \"Artist - Album\" separator" do
    test "a head that is the artist's own name licenses nothing" do
      # The failure the symmetric rule was rejected for, reproduced by the
      # asymmetric one until this guard: a store-invented bucket named
      # "Pearl Jam - Non-Album Tracks" matched a real release titled
      # "Pearl Jam", and a pseudo-album took the self-titled record's identity.
      # Found in a real library, not reasoned about.
      pseudo = track(album: "Pearl Jam - Non-Album Tracks", artists: ["Pearl Jam"])
      self_titled = track(album: "Pearl Jam", artists: ["Pearl Jam"])

      assert Signals.compare(pseudo, self_titled).album < 1.0
    end

    test "a head that is not the artist still reads as a subtitle" do
      # The same shape, and legitimate: these are one record.
      stored = track(album: "Touring Band 2000 - Instrumentals", artists: ["Pearl Jam"])
      release = track(album: "Touring Band 2000", artists: ["Pearl Jam"])

      assert Signals.compare(stored, release).album == 1.0
    end
  end

  describe "version tags a release implies, which its titles do not repeat" do
    test "a remix is invisible to every title comparison, and the release type sees it" do
      # `Normalize.title/1` strips a trailing parenthetical, which is right and
      # is what makes "(Remastered)" work — so "Call Me Maybe (Dark Intensity)"
      # normalizes to exactly "call me maybe". Every title, artist and album
      # signal agrees, and the recording is a different performance.
      #
      # Found in the enrichment corpus: it and "Angel (Angel Dust)" on the
      # Mezzanine remix tapes were the only two genuine errors in 234 cases, and
      # they are the same error.
      original = track(title: "Call Me Maybe", album: "Call Me Maybe")

      remix =
        track(title: "Call Me Maybe (Dark Intensity)", album: "Call Me Maybe Remixes")

      assert Normalize.title(original.title).title ==
               Normalize.title(remix.title).title,
             "the premise: the titles are indistinguishable once normalized"

      refute Signals.compare(original, remix) |> Signals.vetoed?()

      assert Signals.compare(original, %Track{remix | release_tags: [:remix]})
             |> Signals.vetoed?()
    end

    test "and a compilation or a soundtrack implies nothing" do
      # The two commonest secondary types by a distance — 53 and 11 of the
      # releases this project has cached, against 19 live. Neither says anything
      # about *which recording* it is, and mapping them would veto half the
      # catalogue.
      original = track(title: "Respect", album: "I Never Loved a Man the Way I Love You")
      on_compilation = track(title: "Respect", album: "Soul Classics", release_tags: [])

      refute Signals.compare(original, on_compilation) |> Signals.vetoed?()
    end
  end

  describe "the other names a catalogue files one recording under" do
    test "a source holding the track title matches a candidate named for the recording" do
      # A MusicBrainz *recording* has a title and each *track* on a release has
      # its own. On the State College bootleg, recording "I Wanna Go" is track
      # 10, titled "[improvisation]". A source holding either name holds a real
      # name for that music, and comparing against only one answers a narrower
      # question than the one being asked.
      source = track(title: "[improvisation]")

      without = track(title: "I Wanna Go", title_variants: [])
      with_variant = track(title: "I Wanna Go", title_variants: ["[improvisation]"])

      assert Signals.compare(source, without).title < 0.5
      assert Signals.compare(source, with_variant).title == 1.0
      assert Signals.compare(source, with_variant).title_exact
    end

    test "and a variant naming different music does not widen anything" do
      # Safe only because a variant is a title of the *same* recording — the
      # search response gives, per release, the one track that matches. If that
      # ever stopped being true this is the assertion that would notice.
      source = track(title: "[improvisation]")
      unrelated = track(title: "I Wanna Go", title_variants: ["Yellow Ledbetter"])

      assert Signals.compare(source, unrelated).title < 0.5
      refute Signals.compare(source, unrelated).title_exact
    end

    test "no variants is the ordinary provider, scoring as it always did" do
      source = track(title: "Corduroy")

      assert Signals.compare(source, track(title: "Corduroy")).title == 1.0
      assert Signals.compare(source, track(title: "Corduroy")).title_exact
    end
  end
end
