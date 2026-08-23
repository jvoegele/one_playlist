defmodule OnePlaylist.MatchingTest do
  @moduledoc """
  The matching engine, organised around the failure modes it exists to prevent.

  `docs/reference/domain.md` lists the ways a playlist transfer goes wrong. The
  `"failure modes"` block below is that list, one test each. It is the closest
  thing this project has to a specification of what "match quality" means, and
  a reported mismatch should arrive here as a new test before it is fixed
  anywhere else.
  """

  use ExUnit.Case, async: true
  use Bond.Test
  use Errata

  alias OnePlaylist.Matching
  alias OnePlaylist.Matching.Match
  alias OnePlaylist.Matching.Report
  alias OnePlaylist.MusicFixtures

  import OnePlaylist.MusicFixtures, only: [track: 1]

  describe "the ladder" do
    test "an ISRC match wins, and is exact" do
      source = track(isrc: "GBAYE0601477")
      candidate = track(isrc: "GBAYE0601477", provider_id: "c1")

      assert {:ok, match} = Matching.match(source, [candidate])
      assert match.strategy == :isrc
      assert match.confidence == :exact_isrc
      assert match.score == 1.0
    end

    test "ISRC formatting differences do not prevent a match" do
      source = track(isrc: "GB-AYE-06-01477")
      candidate = track(isrc: "gbaye0601477", provider_id: "c1")

      assert {:ok, %{strategy: :isrc}} = Matching.match(source, [candidate])
    end

    test "a malformed ISRC is not compared at all" do
      # Two tracks whose "ISRC" is the same nonsense are not thereby the same
      # recording. Falls through to the text rung, which is the correct answer.
      source = track(isrc: "unknown")
      candidate = track(isrc: "unknown", provider_id: "c1")

      assert {:ok, match} = Matching.match(source, [candidate])
      assert match.strategy == :text
    end

    test "a higher rung shuts out the ones below it" do
      # The candidate with a matching ISRC wins even though the other agrees on
      # every text field and this one does not.
      by_isrc =
        track(
          isrc: "GBAYE0601477",
          title: "Ayer",
          artists: ["Los Beatles"],
          provider_id: "isrc-match"
        )

      by_text = track(provider_id: "text-match")
      source = track(isrc: "GBAYE0601477")

      assert {:ok, match} = Matching.match(source, [by_text, by_isrc])
      assert match.track.provider_id == by_isrc.provider_id
      assert match.strategy == :isrc
    end

    test "the text rung is exact after normalization" do
      source = track(title: "Björk’s Song (feat. Thom Yorke)", artists: ["Björk"])

      candidate =
        track(title: "Bjorks Song", artists: ["Bjork", "Thom Yorke"], provider_id: "c1")

      assert {:ok, match} = Matching.match(source, [candidate])
      assert match.strategy == :text
    end

    test "the fuzzy rung catches a near miss the text rung will not" do
      source = track(title: "Bohemian Rhapsody", artists: ["Queen"], duration_seconds: 355)

      candidate =
        track(
          title: "Bohemian Rapsody",
          artists: ["Queen"],
          duration_seconds: 355,
          provider_id: "c1"
        )

      assert {:ok, match} = Matching.match(source, [candidate], threshold: :low)
      assert match.strategy == :fuzzy
    end

    test "UPC and position match exactly when both are present" do
      source = track(album_upc: "00602547670052", track_number: 3, volume_number: 1)

      candidate =
        track(
          album_upc: "602547670052",
          track_number: 3,
          title: "Completely Different",
          artists: ["Someone Else"],
          provider_id: "c1"
        )

      assert {:ok, match} = Matching.match(source, [candidate])
      assert match.strategy == :upc_position
      assert match.confidence == :exact_upc
    end

    test "the same position on a different disc is not the same track" do
      source = track(album_upc: "00602547670052", track_number: 3, volume_number: 1)

      candidate =
        track(
          album_upc: "602547670052",
          track_number: 3,
          volume_number: 2,
          title: "Completely Different",
          artists: ["Someone Else"],
          provider_id: "c1"
        )

      assert {:error, _error} = Matching.match(source, [candidate])
    end
  end

  describe "failure modes from docs/reference/domain.md" do
    test "a karaoke version does not match the original" do
      # The headline case. Same title, same artist, same duration: every text
      # signal says yes, and it is the wrong track.
      source = track(title: "Yesterday")
      karaoke = track(title: "Yesterday (Karaoke Version)", provider_id: "c1")

      assert {:error, error} = Matching.match(source, [karaoke])
      assert Errata.reason(error) == :all_rejected
      assert Errata.display_message(error) =~ "different recording"
    end

    test "a live take does not match the studio recording" do
      source = track(title: "Yesterday")
      live = track(title: "Yesterday - Live at the BBC", provider_id: "c1")

      assert {:error, _error} = Matching.match(source, [live])
    end

    test "an instrumental does not match the vocal version" do
      source = track(title: "Yesterday")
      instrumental = track(title: "Yesterday (Instrumental)", provider_id: "c1")

      assert {:error, _error} = Matching.match(source, [instrumental])
    end

    test "a cover does not match, even credited to the same artist" do
      source = track(title: "Yesterday")
      cover = track(title: "Yesterday (In the Style of The Beatles)", provider_id: "c1")

      assert {:error, _error} = Matching.match(source, [cover])
    end

    test "two live takes do match each other" do
      # The veto is about *disagreement*, not about the tag being present.
      source = track(title: "Yesterday (Live)")
      candidate = track(title: "Yesterday - Live", provider_id: "c1")

      assert {:ok, _match} = Matching.match(source, [candidate])
    end

    test "a remaster does match, at reduced confidence" do
      # Editorial rather than discriminating: providers label remasters
      # inconsistently, so vetoing would reject far more true matches than it
      # would catch false ones.
      source = track(title: "Hey Jude")
      remaster = track(title: "Hey Jude - Remastered 2015", provider_id: "c1")

      assert {:ok, match} = Matching.match(source, [remaster])

      assert {:ok, clean} = Matching.match(source, [track(title: "Hey Jude", provider_id: "c2")])
      assert match.score < clean.score
    end

    test "a featured artist in the title matches one in the artist list" do
      source = track(title: "Empire State of Mind (feat. Alicia Keys)", artists: ["JAY-Z"])

      candidate =
        track(
          title: "Empire State of Mind",
          artists: ["Jay-Z", "Alicia Keys"],
          provider_id: "c1"
        )

      assert {:ok, %{strategy: :text}} = Matching.match(source, [candidate])
    end

    test "an inverted artist name still matches" do
      source = track(artists: ["The Beatles"])
      candidate = track(artists: ["Beatles, The"], provider_id: "c1")

      assert {:ok, %{strategy: :text}} = Matching.match(source, [candidate])
    end

    test "a different artist with the same title does not match" do
      source = track(title: "Yesterday", artists: ["The Beatles"])
      candidate = track(title: "Yesterday", artists: ["Boyz II Men"], provider_id: "c1")

      assert {:error, _error} = Matching.match(source, [candidate])
    end

    test "a backing-band credit still matches the frontman alone" do
      # One recording credited two ways, which services disagree about
      # constantly. The definite article is what identifies it: "X and **the**
      # Ys" is a backing band, so the band goes beside the featured credits and
      # only "bruce springsteen" has to agree.
      #
      # This used to work because `artists_agree?/2` accepted a subset in either
      # direction, over every name at once. That was too generous — see the
      # collaboration test below — and the cost was noted in this comment at the
      # time: "it also matches a genuine solo recording to a band one, which is
      # why duration and album still have to corroborate". They cannot. This
      # rung's band floor is 0.80, above the default threshold, so corroboration
      # only moves a match between 0.80 and 0.98 and can never decline one.
      source = track(artists: ["Bruce Springsteen and the E Street Band"], title: "Badlands")
      candidate = track(artists: ["Bruce Springsteen"], title: "Badlands", provider_id: "c1")

      assert {:ok, match} = Matching.match(source, [candidate])
      assert match.strategy == :text
    end

    test "a collaboration does not match either artist's solo recording" do
      # From a real transfer. A live "Powderfinger" credited to Neil Young &
      # Pearl Jam matched the studio recording on Rust Never Sleeps, credited to
      # Neil Young alone, and landed in a Pearl Jam playlist at `medium`.
      #
      # Nothing else could have caught it. The source came from a CSV with no
      # duration and no barcode, and album similarity was 0.53 — higher than the
      # 0.50 of a legitimate Vitalogy-to-greatest-hits pairing, so no album rule
      # can separate them. The credit is the only signal that distinguishes a
      # collaboration from a solo take.
      source =
        track(
          artists: ["Neil Young & Pearl Jam"],
          title: "Powderfinger",
          album: "1995-06-24: Broken Mirror: Golden Gate Park"
        )

      candidate =
        track(
          artists: ["Neil Young"],
          title: "Powderfinger",
          album: "Rust Never Sleeps",
          provider_id: "c1"
        )

      assert {:error, _error} = Matching.match(source, [candidate])
    end

    test "a guest credit one service spells out and another omits still matches" do
      # The case the subset rule existed for, kept without it: a guest is
      # recorded as a guest rather than as a second headline act, so the names
      # that have to agree are the same on both sides.
      source = track(artists: ["Pearl Jam feat. Eddie Vedder"], title: "Corduroy")
      candidate = track(artists: ["Pearl Jam"], title: "Corduroy", provider_id: "c1")

      assert {:ok, match} = Matching.match(source, [candidate])
      assert match.strategy == :text
    end

    test "a track with no counterpart is reported, not dropped" do
      source = track(title: "Voice Memo 4", artists: ["Me"], isrc: nil)

      assert {:error, error} = Matching.match(source, [])
      assert Errata.reason(error) == :no_candidates
      assert Errata.context(error).candidates_considered == 0
      refute Errata.retryable?(error)
    end

    test "a track with nothing to search by says so specifically" do
      source = track(title: nil, isrc: nil)

      assert {:error, error} = Matching.match(source, [])
      assert Errata.reason(error) == :unsearchable
      assert Errata.display_message(error) =~ "too little information"
    end
  end

  describe "duplicate candidates" do
    test "a tie is broken by popularity, then deterministically by id" do
      source = track(isrc: "GBAYE0601477")

      candidates = [
        track(isrc: "GBAYE0601477", provider_id: "b", popularity: 0.5),
        track(isrc: "GBAYE0601477", provider_id: "a", popularity: 0.9)
      ]

      assert {:ok, match} = Matching.match(source, candidates)
      assert match.track.provider_id == "a"

      # Reversing the input must not change the answer.
      assert {:ok, reversed} = Matching.match(source, Enum.reverse(candidates))
      assert reversed.track.provider_id == "a"
    end

    test "with popularity equal, the lowest id wins, both ways round" do
      source = track(isrc: "GBAYE0601477")

      candidates = [
        track(isrc: "GBAYE0601477", provider_id: "z"),
        track(isrc: "GBAYE0601477", provider_id: "a")
      ]

      for order <- [candidates, Enum.reverse(candidates)] do
        assert {:ok, match} = Matching.match(source, order)
        assert match.track.provider_id == "a"
      end
    end

    test "the count of equally good candidates is recorded" do
      source = track(isrc: "GBAYE0601477")

      candidates =
        for id <- ~w(a b c), do: track(isrc: "GBAYE0601477", provider_id: id)

      assert {:ok, match} = Matching.match(source, candidates)

      assert match.alternatives == 2,
             "a review screen needs to know the choice between these was arbitrary"
    end

    test "a candidate scoring alone has no alternatives" do
      source = track(isrc: "GBAYE0601477")
      candidates = [track(isrc: "GBAYE0601477", provider_id: "a")]

      assert [only] = Matching.rank(source, candidates)
      assert only.alternatives == 0
    end
  end

  describe "thresholds" do
    test "a match below the threshold is an error carrying how close it came" do
      source = track(title: "Bohemian Rhapsody", artists: ["Queen"])
      candidate = track(title: "Bohemian Rapsody", artists: ["Queen"], provider_id: "c1")

      assert {:error, error} = Matching.match(source, [candidate], threshold: :high)

      context = Errata.context(error)
      assert Errata.reason(error) == :below_threshold
      assert context.candidates_considered == 1
      assert is_float(context.best_score)
      assert context.best_candidate_id == "c1"
      assert context.threshold > context.best_score
    end

    test "lowering the threshold recovers it" do
      source = track(title: "Bohemian Rhapsody", artists: ["Queen"])
      candidate = track(title: "Bohemian Rapsody", artists: ["Queen"], provider_id: "c1")

      assert {:error, _error} = Matching.match(source, [candidate], threshold: :high)
      assert {:ok, _match} = Matching.match(source, [candidate], threshold: :low)
    end

    test "a threshold may be a raw float as well as a name" do
      assert Matching.threshold(threshold: 0.42) == 0.42
      assert Matching.threshold(threshold: :high) == 0.9
      assert Matching.threshold(threshold: :exact_isrc) == 1.0
    end

    test "confidence names order as they read" do
      assert Match.at_least?(:exact_isrc, :high)
      assert Match.at_least?(:high, :medium)
      assert Match.at_least?(:medium, :low)
      refute Match.at_least?(:low, :high)
    end
  end

  describe "match_all/2 and the report" do
    test "every track lands on exactly one side of the ledger" do
      pairs = [
        {track(isrc: "GBAYE0601477", provider_id: "s1"),
         [track(isrc: "GBAYE0601477", provider_id: "c1")]},
        {track(provider_id: "s2", title: "Nothing Like This"), []},
        {track(provider_id: "s3"), [track(provider_id: "c3")]}
      ]

      report = Matching.match_all(pairs)

      assert Report.total(report) == 3
      assert length(report.matched) == 2
      assert length(report.unmatched) == 1
    end

    test "the same track twice is reported twice" do
      # A playlist may legitimately contain a track more than once. The first
      # version of the ledger contract asserted uniqueness and accused correct
      # code the first time this happened.
      source = track(isrc: "GBAYE0601477", provider_id: "s1")
      candidate = track(isrc: "GBAYE0601477", provider_id: "c1")

      report = Matching.match_all([{source, [candidate]}, {source, [candidate]}])

      assert Report.total(report) == 2
      assert length(report.matched) == 2
    end

    test "an empty report is a complete transfer of nothing" do
      report = Matching.match_all([])

      assert Report.total(report) == 0
      assert Report.match_rate(report) == 1.0
    end

    test "match_rate reflects what was lost" do
      pairs = [
        {track(provider_id: "s1"), [track(provider_id: "c1")]},
        {track(provider_id: "s2", title: "Unfindable"), []}
      ]

      assert Matching.match_all(pairs) |> Report.match_rate() == 0.5
    end

    test "the middle band is surfaced for review rather than trusted" do
      # A misspelling reaches only the fuzzy rung, which scores in the bottom
      # band by construction — exactly the material domain.md argues should be
      # shown to a person rather than either transferred or discarded.
      source = track(title: "Bohemian Rhapsody", artists: ["Queen"])
      candidate = track(title: "Bohemian Rapsody", artists: ["Queen"], provider_id: "c1")

      report = Matching.match_all([{source, [candidate]}], threshold: :low)

      assert [match] = Report.needs_review(report, :high)
      assert match.confidence in [:medium, :low]
    end

    test "ambiguous matches are listed separately" do
      source = track(isrc: "GBAYE0601477", provider_id: "s1")

      candidates =
        for id <- ~w(a b), do: track(isrc: "GBAYE0601477", provider_id: id)

      report = Matching.match_all([{source, candidates}])

      assert [_ambiguous] = Report.ambiguous(report)
    end
  end

  describe "rank/3" do
    test "returns the winning rung's candidates, best first" do
      source = track(isrc: "GBAYE0601477")

      candidates = [
        track(isrc: "GBAYE0601477", provider_id: "a", popularity: 0.1),
        track(isrc: "GBAYE0601477", provider_id: "b", popularity: 0.9),
        # Not an ISRC match, so the winning rung never sees it.
        track(provider_id: "c")
      ]

      ranked = Matching.rank(source, candidates)

      assert Enum.map(ranked, & &1.track.provider_id) == ~w(b a)
    end

    test "is empty when no rung has an opinion" do
      assert Matching.rank(track(title: nil, isrc: nil), []) == []
    end
  end

  describe "contracts" do
    test "the ladder is contracted against returning a track nobody offered" do
      # `chosen_from_candidates` cannot be provoked through the public API —
      # correct code cannot return a track it was not given. It is verified by
      # mutation instead (see the commit), and this pins the property it states
      # so a future rewrite has something to fail.
      source = track(isrc: "GBAYE0601477")
      candidates = [track(isrc: "GBAYE0601477", provider_id: "c1")]

      assert {:ok, match} = Matching.match(source, candidates)
      assert match.track in candidates
      assert match.source == source
    end

    test "searching for a track with nothing to search by is a caller error" do
      connection = %OnePlaylist.Providers.Connection{
        provider: :tidal,
        provider_user_id: "1",
        access_token: "at",
        scopes: ["playlists.read"],
        status: :active,
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
      }

      assert_precondition_violation(
        OnePlaylist.Providers.Tidal.search_tracks(
          connection,
          MusicFixtures.track(title: nil, isrc: nil)
        ),
        label: :searchable
      )
    end
  end

  describe "unlabelled versions of one song" do
    # The only genuine errors the cross-service measurement found, reproduced
    # from the data that produced them. Kraftwerk's catalogue carries several
    # versions of each track under one title, and *neither* MusicBrainz nor
    # TIDAL labels them — so there is no `(Live)` or `(Radio Edit)` for the
    # discriminating veto to fire on, and title, artist and album all agree.
    #
    # Real numbers: MusicBrainz has "Neonlicht" at 535s, TIDAL lists one at
    # 344s. Before this, that scored `:medium` and was accepted by default.

    test "a 191-second disagreement is not a confident match" do
      source = track(title: "Neonlicht", artists: ["Kraftwerk"], duration_seconds: 535)
      other_version = track(title: "Neonlicht", artists: ["Kraftwerk"], duration_seconds: 344)

      assert {:error, error} = Matching.match(source, [other_version])

      # `:below_threshold`, not `:no_match` — the distinction is the whole
      # design. The text rung declines, but the candidate is not discarded:
      # fuzzy still scores it, and the report can show the user the near miss
      # and its score rather than "nothing found".
      assert error.reason == :below_threshold
    end

    test "the right version is still chosen when it is offered" do
      # The veto must not cost a correct match. Given both versions, the ladder
      # takes the one whose length agrees.
      source = track(title: "Neonlicht", artists: ["Kraftwerk"], duration_seconds: 535)
      wrong = track(title: "Neonlicht", artists: ["Kraftwerk"], duration_seconds: 344)
      right = track(title: "Neonlicht", artists: ["Kraftwerk"], duration_seconds: 533)

      assert {:ok, match} = Matching.match(source, [wrong, right])
      assert match.track.duration_seconds == 533
    end

    test "a remaster's few seconds of difference still matches" do
      # The line has to fall between "different master" and "different
      # recording". Two seconds is the former.
      source = track(title: "Das Model", artists: ["Kraftwerk"], duration_seconds: 218)
      remaster = track(title: "Das Model", artists: ["Kraftwerk"], duration_seconds: 220)

      assert {:ok, match} = Matching.match(source, [remaster])
      assert match.strategy == :text
    end

    test "an unknown duration does not reject anything" do
      # Absent evidence is not contrary evidence — the same rule rung 2 follows.
      source = track(title: "Die Roboter", artists: ["Kraftwerk"], duration_seconds: 373)
      untimed = track(title: "Die Roboter", artists: ["Kraftwerk"], duration_seconds: nil)

      assert {:ok, match} = Matching.match(source, [untimed])
      assert match.strategy == :text
    end
  end
end
