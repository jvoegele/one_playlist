defmodule OnePlaylist.Library.AlbumsTest do
  @moduledoc """
  Making an album agree with itself about which release it is.

  The interesting cases are all about *which* release wins and what gets written
  when it does. Enrichment resolves a recording at a time and cannot see the
  album; the whole point of this module is that the widest-covering release wins
  even when a track-at-a-time rule would have taken another — so that is what
  the first test proves, in the shape the dev library actually failed in.

  The rest is the correcting rule: this is the one operation allowed to replace
  a value `Enrichment.enrich/1` may only fill, and `only_adopted_the_release?/3`
  is where the narrowness of that permission is checked.
  """

  use OnePlaylist.DataCase, async: true
  use Bond.Test

  alias OnePlaylist.Library.Albums
  alias OnePlaylist.Library.Recording
  alias OnePlaylist.MusicBrainz.Release

  # The dev database is shared with `dev`, so a fixture album must not collide
  # with music somebody imported. See `OnePlaylist.LibraryTest`.
  defp unique_album(name) do
    "#{name} ZZ#{System.unique_integer([:positive])}"
  end

  defp recording(attrs) do
    Repo.insert!(
      struct(
        %Recording{
          title: "Untitled",
          artists: ["Pearl Jam"],
          musicbrainz_recording_id: Ecto.UUID.generate()
        },
        attrs
      )
    )
  end

  defp release(attrs) do
    struct(
      %Release{mbid: Ecto.UUID.generate(), title: "Riot Act", tracks: []},
      attrs
    )
  end

  # `musicbrainz_releases` is read through `MusicBrainz.release/1`, so a row in
  # the cache is what stops `resolve/2` reaching for the network.
  defp cache(attrs) do
    Repo.insert!(struct(release(attrs), looked_up_at: DateTime.utc_now()))
  end

  defp track(title, opts \\ []) do
    %{
      "title" => title,
      "position" => Keyword.get(opts, :position, 1),
      "recording_mbid" => Keyword.get(opts, :recording_mbid),
      "length_ms" => Keyword.get(opts, :length_ms)
    }
  end

  describe "choose/2 — the album picks the release most of it is on" do
    test "the widest cover wins, even against an earlier release" do
      # The shape `Riot Act` failed in, and the reason this module exists.
      # MusicBrainz lists `narrow` against eight of the album's ten tracks and
      # `wide` against all ten. Enrichment's per-recording rule picked `narrow`
      # because the first track to be enriched happened to draw it, and nothing
      # ever revisited that. Here the album decides instead.
      recordings = for n <- 1..10, do: %Recording{title: "Track #{n}", artists: ["Pearl Jam"]}

      wide = release(date: "2009", tracks: for(n <- 1..10, do: track("Track #{n}")))
      narrow = release(date: "2002", tracks: for(n <- 1..8, do: track("Track #{n}")))

      assert Albums.choose(recordings, [narrow, wide]).mbid == wide.mbid

      # And the order the candidates arrive in cannot change the answer.
      assert Albums.choose(recordings, [wide, narrow]).mbid == wide.mbid
    end

    test "a tie goes to the release that states a barcode" do
      # Both account for the whole album, so neither is better evidence about
      # *which* pressing — but one of them tells us the album's barcode and the
      # other does not. `Riot Act`'s two candidates are exactly this.
      recordings = [%Recording{title: "Ghost", artists: ["Pearl Jam"]}]

      silent = release(date: "2002", barcode: nil, tracks: [track("Ghost")])
      stating = release(date: "2002", barcode: "696998682528", tracks: [track("Ghost")])

      assert Albums.choose(recordings, [silent, stating]).mbid == stating.mbid
      assert Albums.choose(recordings, [stating, silent]).mbid == stating.mbid
    end

    test "an empty barcode counts as no barcode" do
      # MusicBrainz returns `""` for a release known to have none, which is not
      # the same value as `nil` and would otherwise sort as though it were data.
      recordings = [%Recording{title: "Ghost", artists: ["Pearl Jam"]}]

      blank = release(date: "2002", barcode: "", tracks: [track("Ghost")])
      stating = release(date: "2002", barcode: "696998682528", tracks: [track("Ghost")])

      assert Albums.choose(recordings, [blank, stating]).mbid == stating.mbid
    end

    test "nothing is chosen when no candidate accounts for anything" do
      recordings = [%Recording{title: "Ghost", artists: ["Pearl Jam"]}]

      assert Albums.choose(recordings, [release(tracks: [track("Wishlist")])]) == nil
      assert Albums.choose(recordings, []) == nil
    end
  end

  describe "covers?/2 — both tests are needed" do
    test "a release naming the recording by MBID covers it" do
      mbid = Ecto.UUID.generate()
      rec = %Recording{title: "Anything At All", musicbrainz_recording_id: mbid}

      # Deliberately a different title, so only the MBID can be doing the work.
      assert Albums.covers?(release(tracks: [track("Something Else", recording_mbid: mbid)]), rec)
    end

    test "a release naming it by title covers it when the MBID does not carry" do
      # The `Ten Redux` case: a remaster is a different recording entity, so the
      # MBID does not survive the reissue but the title does. Measured on the
      # dev library, the winner named two of six tracks by MBID and five by
      # title — either test alone leaves the album split.
      rec = %Recording{title: "Black", musicbrainz_recording_id: Ecto.UUID.generate()}

      assert Albums.covers?(release(tracks: [track("Black", recording_mbid: nil)]), rec)
    end

    test "a wildly different length does not stop it, and that is deliberate" do
      # Coverage asks whether this *pressing carries this track*, which a
      # duration cannot answer. Five of `Vs.`'s nineteen tracks were rejected by
      # a duration check that seemed obviously right, and in every case the
      # library's imported value was the wrong one. See the moduledoc.
      rec = %Recording{title: "Blood", duration_seconds: 63}

      assert Albums.covers?(release(tracks: [track("Blood", length_ms: 171_000)]), rec)
    end

    test "neither test matching is not coverage" do
      rec = %Recording{title: "Blood", musicbrainz_recording_id: Ecto.UUID.generate()}

      refute Albums.covers?(release(tracks: [track("Rats")]), rec)
      refute Albums.covers?(release(tracks: []), rec)
    end

    test "a recording with no title is not covered by a track with no title" do
      # Both normalize to `""`, which would otherwise make every untitled track
      # cover every untitled recording.
      refute Albums.covers?(release(tracks: [track("")]), %Recording{title: nil})
    end
  end

  describe "adopt/2 — the correcting rule, and its limits" do
    test "the release and its barcode are written, and nothing else is" do
      before =
        recording(
          title: "Ghost",
          album: "Riot Act",
          album_upc: "111111111111",
          musicbrainz_release_id: Ecto.UUID.generate(),
          duration_seconds: 200
        )

      chosen = release(barcode: "696998682528", tracks: [track("Ghost")])

      assert {:ok, adopted} = Albums.adopt(before, chosen)
      assert adopted.musicbrainz_release_id == chosen.mbid
      assert adopted.album_upc == "696998682528"

      # The user's own fields are untouched, which is the whole permission.
      assert adopted.title == before.title
      assert adopted.album == before.album
      assert adopted.duration_seconds == before.duration_seconds
      assert Albums.only_adopted_the_release?(before, adopted, chosen)
    end

    test "a UPC with no release beside it came from the source and stays" do
      # The provenance proxy `Enrichment.reset/1` uses: a recording holding a
      # release id got its barcode from that release, and one without got it
      # from whatever imported the track. Overwriting the second is the exact
      # thing `enrich/1` refuses to do, reached by the back door.
      before =
        recording(
          title: "Ghost",
          album_upc: "111111111111",
          musicbrainz_release_id: nil
        )

      chosen = release(barcode: "696998682528", tracks: [track("Ghost")])

      assert {:ok, adopted} = Albums.adopt(before, chosen)
      assert adopted.musicbrainz_release_id == chosen.mbid
      assert adopted.album_upc == "111111111111"
      assert Albums.only_adopted_the_release?(before, adopted, chosen)
    end

    test "a recording with no UPC at all is given the release's" do
      before = recording(title: "Ghost", album_upc: nil, musicbrainz_release_id: nil)
      chosen = release(barcode: "696998682528", tracks: [track("Ghost")])

      assert {:ok, adopted} = Albums.adopt(before, chosen)
      assert adopted.album_upc == "696998682528"
    end

    test "a release with no barcode leaves the UPC alone rather than nulling it" do
      before = recording(title: "Ghost", album_upc: "111111111111")
      chosen = release(barcode: nil, tracks: [track("Ghost")])

      assert {:ok, adopted} = Albums.adopt(before, chosen)
      assert adopted.album_upc == "111111111111"
      assert Albums.only_adopted_the_release?(before, adopted, chosen)
    end
  end

  describe "only_adopted_the_release?/3 — the postcondition can say no" do
    test "a changed title is not an adoption" do
      before = recording(title: "Ghost", album: "Riot Act")
      chosen = release(barcode: "696998682528")

      forged = %{before | title: "Ghast", musicbrainz_release_id: chosen.mbid}

      refute Albums.only_adopted_the_release?(before, forged, chosen)
    end

    test "a barcode from somewhere other than the release is not an adoption" do
      before = recording(title: "Ghost", musicbrainz_release_id: Ecto.UUID.generate())
      chosen = release(barcode: "696998682528")

      forged = %{before | musicbrainz_release_id: chosen.mbid, album_upc: "999999999999"}

      refute Albums.only_adopted_the_release?(before, forged, chosen)
    end

    test "adopting a release other than the chosen one is not an adoption" do
      before = recording(title: "Ghost")
      chosen = release(barcode: nil)

      forged = %{before | musicbrainz_release_id: Ecto.UUID.generate()}

      refute Albums.only_adopted_the_release?(before, forged, chosen)
    end
  end

  describe "resolve/2 — end to end" do
    setup do
      album = unique_album("Riot Act")

      # Two pressings of one album, both already in the release cache so no
      # request is made. `wide` lists every track; `narrow` lists eight of ten,
      # which is what let the album split in the first place.
      wide = Ecto.UUID.generate()
      narrow = Ecto.UUID.generate()

      cache(
        mbid: wide,
        title: album,
        date: "2002",
        barcode: "696998682528",
        tracks: for(n <- 1..10, do: track("Track #{n}", position: n))
      )

      cache(
        mbid: narrow,
        title: album,
        date: "2002",
        barcode: "111111111111",
        tracks: for(n <- 1..8, do: track("Track #{n}", position: n))
      )

      # The split enrichment produced: the first eight took `narrow`, and the
      # two it does not list fell through to their own best.
      recordings =
        for n <- 1..10 do
          recording(
            title: "Track #{n}",
            album: album,
            album_upc: if(n <= 8, do: "111111111111", else: "696998682528"),
            musicbrainz_release_id: if(n <= 8, do: narrow, else: wide)
          )
        end

      %{album: album, wide: wide, narrow: narrow, recordings: recordings}
    end

    test "the album settles on one release", %{album: album, wide: wide} do
      assert %{release: release, recordings: 10, covered: 10, changed: 8} =
               Albums.resolve(album, "Pearl Jam")

      assert release.mbid == wide

      settled =
        Recording
        |> where([r], r.album == ^album)
        |> select([r], r.musicbrainz_release_id)
        |> Repo.all()
        |> Enum.uniq()

      assert settled == [wide]
    end

    test "and its barcode with it", %{album: album} do
      Albums.resolve(album, "Pearl Jam")

      upcs =
        Recording
        |> where([r], r.album == ^album)
        |> select([r], r.album_upc)
        |> Repo.all()
        |> Enum.uniq()

      assert upcs == ["696998682528"]
    end

    test "running it again writes nothing", %{album: album} do
      assert %{changed: 8} = Albums.resolve(album, "Pearl Jam")
      assert %{changed: 0, covered: 10} = Albums.resolve(album, "Pearl Jam")
    end

    test "the album stops being reported as spanning", %{album: album} do
      assert {album, "Pearl Jam"} in Albums.spanning()

      Albums.resolve(album, "Pearl Jam")

      refute {album, "Pearl Jam"} in Albums.spanning()
    end

    test "an album nobody has identified is left entirely alone" do
      album = unique_album("Nothing Known")
      rec = recording(title: "Track 1", album: album, musicbrainz_recording_id: nil)

      assert %{release: nil, recordings: 0, covered: 0, changed: 0} =
               Albums.resolve(album, "Pearl Jam")

      assert Repo.get!(Recording, rec.id).musicbrainz_release_id == nil
    end

    test "a release that turns out not to be this album's is refused" do
      # What `Pearl Jam - Non-Album Tracks` looks like from here: a bucket
      # rather than an album, whose tracks genuinely appear on unrelated
      # releases. Forcing them together is the error this module undoes.
      album = unique_album("Non-Album Tracks")
      other = Ecto.UUID.generate()

      cache(
        mbid: other,
        title: "Some Entirely Different Record",
        date: "1998",
        tracks: [track("Track 1")]
      )

      rec = recording(title: "Track 1", album: album, musicbrainz_release_id: other)

      assert %{release: nil, covered: 0, changed: 0} = Albums.resolve(album, "Pearl Jam")
      assert Repo.get!(Recording, rec.id).musicbrainz_release_id == other
    end

    test "a release of this album that no longer lists the track is refused too" do
      # The case `release_earns_its_place` is actually on, and it needs its own
      # setup: the test above never reaches the contract, because `eligible/2`
      # discards a differently-titled release before `choose/2` sees it. Here the
      # release *is* this album by title and simply does not carry the track —
      # an edit at MusicBrainz, or a recording that was never on this pressing.
      album = unique_album("Riot Act")
      stale = Ecto.UUID.generate()

      cache(mbid: stale, title: album, date: "2002", tracks: [track("Some Other Song")])

      rec = recording(title: "Ghost", album: album, musicbrainz_release_id: stale)

      assert %{release: nil, recordings: 1, covered: 0, changed: 0} =
               Albums.resolve(album, "Pearl Jam")

      assert Repo.get!(Recording, rec.id).musicbrainz_release_id == stale
    end
  end

  describe "the contracts can fire" do
    test "choosing a release that accounts for nothing is refused" do
      # `covers_something`, which no input can falsify while `choose/2` filters.
      # Deleting that filter is the mutation, and it fires: `ranking/2` alone
      # happily returns a release covering none of the album, and `resolve/2`
      # goes on to report the album settled on it.
      recordings = [%Recording{title: "Ghost", artists: ["Pearl Jam"]}]
      unrelated = release(date: "2002", barcode: "696998682528", tracks: [track("Wishlist")])

      assert Albums.choose(recordings, [unrelated]) == nil
    end

    test "the widest cover is not merely the one the sort happened to return" do
      # `nothing_covers_more` recomputes coverage independently of `ranking/2`'s
      # composite key. The two agree here; they stop agreeing the moment the key
      # is reordered to sort on the barcode first, which is a plausible edit —
      # `Ten Redux`'s narrower candidate carries a barcode too.
      recordings = for n <- 1..6, do: %Recording{title: "Track #{n}"}

      wide = release(barcode: nil, tracks: for(n <- 1..6, do: track("Track #{n}")))
      narrow = release(barcode: "886444194181", tracks: [track("Track 1"), track("Track 2")])

      chosen = Albums.choose(recordings, [narrow, wide])

      assert chosen.mbid == wide.mbid
      assert Albums.coverage(chosen, recordings) == 6
      assert Albums.coverage(narrow, recordings) == 2
    end
  end
end
