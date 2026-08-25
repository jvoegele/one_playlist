defmodule OnePlaylist.LibraryTest do
  @moduledoc """
  The library store, and the one place in this application where a failure to
  match is not a failure.

  Everywhere else a miss means the destination cannot hold the track. Here it
  means the library does not have it *yet*, so the interesting cases are the two
  halves of deduplication: recognising a recording it already has, and declining
  to recognise one it does not. The second is the dangerous direction — joining
  two different pieces of music is destructive where storing a second copy is
  merely untidy.
  """

  use OnePlaylist.DataCase, async: true

  alias OnePlaylist.AuthFixtures
  alias OnePlaylist.Library
  alias OnePlaylist.Library.PlaylistItem
  alias OnePlaylist.Library.Recording
  alias OnePlaylist.Music.Isrc
  alias OnePlaylist.Music.Track

  setup do
    %{user_id: AuthFixtures.user_id_fixture()}
  end

  # Recordings belong to nobody, so unlike everything else here they cannot be
  # scoped to the test's own user — and dev and test share the `postgres`
  # database, so a real ISRC or a real title in a fixture will sooner or later
  # collide with music somebody actually imported. (It did: two tests here began
  # failing the day a Pearl Jam library landed in dev.)
  #
  # So every identifying value is salted, once per test process, which keeps the
  # names readable while making them nobody else's. `isrc/1` is public to the
  # test so an assertion can name the same salted value the fixture stored.
  defp salt do
    case Process.get(:library_salt) do
      nil ->
        fresh = System.unique_integer([:positive])
        Process.put(:library_salt, fresh)
        fresh

      existing ->
        existing
    end
  end

  # The last five digits of an ISRC are its designation code, which is exactly
  # the part that distinguishes one recording from another within a registrant.
  # Held above 10000 so a salted code cannot land on one of the low designation
  # numbers real catalogues actually use.
  defp isrc(code) do
    canonical = Isrc.normalize(code) || code
    String.slice(canonical, 0, 7) <> to_string(rem(salt(), 90_000) + 10_000)
  end

  # The same ISRC written the way Roon writes them — lower case and hyphenated.
  # Derived from the salted value rather than written out, so the two spellings
  # stay two spellings of one code.
  defp scrambled(code) do
    <<cc::binary-2, reg::binary-3, year::binary-2, designation::binary-5>> = isrc(code)

    String.downcase("#{cc}-#{reg}-#{year}-#{designation}")
  end

  # Only ISRCs are salted, not titles: a title is compared, ordered and asserted
  # on all over this file, and salting it would make every one of those
  # assertions about the salt. The one test that searches by title uses a title
  # no real catalogue holds instead.
  defp track(attrs) do
    attrs =
      Map.update(attrs, :isrc, nil, fn
        nil -> nil
        code -> isrc(code)
      end)

    struct!(
      %Track{
        provider: :tidal,
        provider_id: "t-#{System.unique_integer([:positive])}",
        title: "Corduroy",
        artists: ["Pearl Jam"],
        album: "Vitalogy"
      },
      attrs
    )
  end

  describe "find_or_create/1" do
    test "an ISRC it already holds reuses the recording rather than storing a second" do
      # The compounding claim from domain.md §5: a recording resolved once is a
      # row, not a lookup repeated per transfer.
      first = Library.find_or_create(track(%{isrc: "USSM11100234"}))
      second = Library.find_or_create(track(%{isrc: "USSM11100234", title: "Corduroy "}))

      assert first.id == second.id

      assert Repo.aggregate(from(r in Recording, where: r.isrc == ^isrc("USSM11100234")), :count) ==
               1
    end

    test "an ISRC spelled differently is the same recording" do
      # Roon writes them lower case and hyphenated. Canonical form is what the
      # column holds, so the comparison has to be canonical too.
      first = Library.find_or_create(track(%{isrc: "GBAYE0601477"}))
      second = Library.find_or_create(track(%{isrc: scrambled("GBAYE0601477")}))

      assert first.id == second.id
    end

    test "a matching title alone does NOT reuse a recording" do
      # The real case, from a real playlist. "Hard to Imagine" appears on both
      # *Lost Dogs* and the *Chicago Cab* soundtrack and they are two different
      # studio sessions. A title-similarity match merged them and one silently
      # vanished from the playlist; requiring the album to agree keeps them
      # apart.
      lost_dogs =
        Library.find_or_create(track(%{isrc: nil, title: "Hard to Imagine", album: "Lost Dogs"}))

      chicago =
        Library.find_or_create(
          track(%{isrc: nil, title: "Hard to Imagine", album: "Chicago Cab"})
        )

      refute lost_dogs.id == chicago.id
    end

    test "a matching credit alone does NOT reuse a recording either" do
      one = Library.find_or_create(track(%{isrc: nil, title: "Corduroy", album: "Vitalogy"}))

      other =
        Library.find_or_create(
          track(%{isrc: nil, title: "Corduroy", artists: ["Eddie Vedder"], album: "Vitalogy"})
        )

      refute one.id == other.id
    end

    test "title, album and credit all agreeing IS the same recording" do
      # The second key, and the reason it has to exist: without it an ISRC-less
      # track can never be recognised on its second arrival, so a re-imported
      # playlist grows a second copy of every one of them. Exact equality after
      # normalization, never similarity.
      first = Library.find_or_create(track(%{isrc: nil, title: "Corduroy", album: "Vitalogy"}))
      again = Library.find_or_create(track(%{isrc: nil, title: "corduroy", album: "VITALOGY"}))

      assert first.id == again.id
    end

    test "the credit is compared as a set, not as a sequence" do
      # One service orders a collaboration one way and another the other way;
      # that is not two recordings.
      one =
        Library.find_or_create(
          track(%{
            isrc: nil,
            title: "The Long Road",
            artists: ["Eddie Vedder", "Nusrat Fateh Ali Khan"]
          })
        )

      other =
        Library.find_or_create(
          track(%{
            isrc: nil,
            title: "The Long Road",
            artists: ["Nusrat Fateh Ali Khan", "Eddie Vedder"]
          })
        )

      assert one.id == other.id
    end

    test "two callers racing on one ISRC produce one recording" do
      # Reading and then inserting is a race, and the store is shared: two users
      # transferring the same track at the same moment both miss and both
      # insert. Observed on a real import — two overlapping runs of one transfer
      # produced exactly two of every recording, sub-millisecond apart.
      #
      # The database is what settles it. Racing here would be flaky; inserting
      # the row behind `find_or_create/1`'s back is the same collision without
      # the timing.
      shared = isrc("USSM11100234")
      first = Library.find_or_create(track(%{isrc: "USSM11100234"}))

      assert %Recording{} =
               Repo.get_by(Recording, isrc: shared),
             "the first insert is the one to collide with"

      # A second caller that has already decided the row is absent.
      second = Library.find_or_create(track(%{isrc: "USSM11100234", title: "Corduroy"}))

      assert second.id == first.id
      assert Repo.aggregate(from(r in Recording, where: r.isrc == ^shared), :count) == 1
    end

    test "the ISRC is stored canonical, or not at all" do
      # The bug this caught, and it is the one this project keeps meeting: every
      # lookup normalises its query, so an ISRC stored as the source wrote it is
      # an ISRC nothing will ever find. Deduplication then fails silently in the
      # one place it is the entire point.
      lower = Library.find_or_create(track(%{isrc: scrambled("GBAYE0601477")}))

      assert lower.isrc == isrc("GBAYE0601477")

      assert Library.find_or_create(track(%{isrc: "GBAYE0601477"})).id == lower.id

      # A distinct title, so the metadata key cannot recognise it as the
      # recording above — this test is about the ISRC column, not about dedup.
      junk = Library.find_or_create(track(%{isrc: "not-an-isrc", title: "Zzyzx Junk"}))

      assert junk.isrc == nil,
             "junk that compares equal to other junk is worse than no identifier"
    end

    test "a library track is fetched rather than stored again" do
      stored = Library.find_or_create(track(%{isrc: "USSM11100234"}))

      assert Library.find_or_create(Recording.to_track(stored)).id == stored.id
    end

    test "the metadata is copied verbatim, including artwork" do
      stored =
        Library.find_or_create(
          track(%{
            isrc: "USSM11100234",
            duration_seconds: 285,
            artwork_url: "https://example.test/cover.jpg",
            album_upc: "602547670052"
          })
        )

      assert stored.title == "Corduroy"
      assert stored.artists == ["Pearl Jam"]
      assert stored.duration_seconds == 285
      assert stored.artwork_url == "https://example.test/cover.jpg"
      assert stored.album_upc == "602547670052"
      assert stored.origin_provider == "tidal"
    end
  end

  describe "an item owns its own account of the track" do
    setup %{user_id: user_id} do
      {:ok, playlist} = Library.create_playlist(user_id, "Mine")

      Library.append(user_id, playlist.id, [
        track(%{
          isrc: nil,
          title: "Hard to Imagine",
          album: "Chicago Cab",
          artists: ["Pearl Jam"]
        })
      ])

      [entry] = Library.entries(user_id, playlist.id)

      %{playlist: playlist, entry: entry}
    end

    test "the catalogue improving does not rewrite the playlist", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      # The whole point of the split. A recording is shared and enrichment
      # improves it for everyone; a playlist is one person's and says what their
      # source said.
      Recording
      |> Repo.get!(entry.track.provider_id)
      |> Ecto.Changeset.change(
        title: "Hard to Imagine (2003 remaster)",
        album: "Music From Chicago Cab",
        artists: ["Pearl Jam", "Somebody Else"]
      )
      |> Repo.update!()

      assert [refreshed] = Library.entries(user_id, playlist.id)

      assert refreshed.track.title == "Hard to Imagine"
      assert refreshed.track.album == "Chicago Cab"
      assert refreshed.track.artists == ["Pearl Jam"]
    end

    test "but the catalogue still supplies what a source does not know", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      Recording
      |> Repo.get!(entry.track.provider_id)
      |> Ecto.Changeset.change(
        artwork_url: "https://example.test/cover.jpg",
        album_upc: "602547670052"
      )
      |> Repo.update!()

      assert [refreshed] = Library.entries(user_id, playlist.id)

      assert refreshed.track.artwork_url == "https://example.test/cover.jpg"
      assert refreshed.track.album_upc == "602547670052"
    end

    test "an ISRC the source never had is filled in from the catalogue", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      # The item's own claim wins where it has one; this item has none, and
      # enrichment has since learned the answer.
      learned = isrc("USSM11100234")

      Recording
      |> Repo.get!(entry.track.provider_id)
      |> Ecto.Changeset.change(isrc: learned)
      |> Repo.update!()

      assert [refreshed] = Library.entries(user_id, playlist.id)
      assert refreshed.track.isrc == learned
    end

    test "the item is what a transfer out of the library reads", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      # `tracks/2` is what `Providers.Library` streams as a source, so it has to
      # agree with the screen about what the playlist holds.
      Recording
      |> Repo.get!(entry.track.provider_id)
      |> Ecto.Changeset.change(title: "Something Else Entirely")
      |> Repo.update!()

      assert [track] = Library.tracks(user_id, playlist.id)
      assert track.title == "Hard to Imagine"
      assert track.provider_id == entry.track.provider_id, "still addressed by its recording"
    end

    test "two items of one recording keep their own metadata", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      # One recording, two items. The second arrival is the same track by every
      # key `find_or_create/1` has, so it links to the recording already there —
      # and the items still say whatever their owner says they say.
      Library.append(user_id, playlist.id, [
        track(%{
          isrc: nil,
          title: "Hard to Imagine",
          album: "Chicago Cab",
          artists: ["Pearl Jam"]
        })
      ])

      assert [first, second] = Library.entries(user_id, playlist.id)

      assert first.track.provider_id == second.track.provider_id,
             "one recording, or this test is not about what it says it is"

      # What editing will do in the next step, done here by hand.
      PlaylistItem
      |> Repo.get!(second.id)
      |> Ecto.Changeset.change(album: "Lost Dogs: Rarities and B Sides")
      |> Repo.update!()

      assert [
               %{track: %{album: "Chicago Cab"}},
               %{track: %{album: "Lost Dogs: Rarities and B Sides"}}
             ] =
               Library.entries(user_id, playlist.id)

      refute entry.id == second.id
    end
  end

  describe "breaking and remaking the link" do
    setup %{user_id: user_id} do
      {:ok, playlist} = Library.create_playlist(user_id, "Mine")

      Library.append(user_id, playlist.id, [
        track(%{isrc: nil, title: "Hard to Imagine", album: "Chicago Cab"})
      ])

      [entry] = Library.entries(user_id, playlist.id)

      %{playlist: playlist, entry: entry}
    end

    test "an unlinked item keeps everything its source said", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      # The reason unlinking is not deleting. Before this the only move against
      # a wrong match was removing the track and adding it again, which loses
      # its place and any correction made to it.
      assert :ok = Library.unlink(user_id, playlist.id, entry.id)

      assert [still_there] = Library.entries(user_id, playlist.id)

      assert still_there.track.title == "Hard to Imagine"
      assert still_there.track.album == "Chicago Cab"
      refute still_there.track.provider_id, "and it no longer claims to know what recording it is"
    end

    test "an unlinked item is still in the playlist a transfer reads", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      # A `join` here would silently drop exactly the rows a person most needs
      # to see, and would quietly shrink their playlist.
      Library.unlink(user_id, playlist.id, entry.id)

      assert [track] = Library.tracks(user_id, playlist.id)
      assert track.title == "Hard to Imagine"
    end

    test "offers recordings it might be, best first", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      Library.unlink(user_id, playlist.id, entry.id)

      # Another recording of the same song, which is what a person would be
      # choosing between.
      other =
        Library.find_or_create(track(%{isrc: nil, title: "Hard to Imagine", album: "Lost Dogs"}))

      offered = Library.link_candidates(user_id, playlist.id, entry.id)

      assert other.id in Enum.map(offered, & &1.recording.id)
      assert Enum.all?(offered, &is_float(&1.score))
    end

    test "links to whichever the person picked, scored or not", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      # The choice is theirs and is not re-judged. A threshold decides what
      # somebody should look at; there is nothing to review about a recording
      # they chose themselves.
      Library.unlink(user_id, playlist.id, entry.id)

      unrelated =
        Library.find_or_create(track(%{isrc: nil, title: "Nothing Like It", album: "Elsewhere"}))

      assert :ok = Library.link(user_id, playlist.id, entry.id, unrelated.id)

      assert [relinked] = Library.entries(user_id, playlist.id)
      assert relinked.track.provider_id == unrelated.id
      assert relinked.track.title == "Hard to Imagine", "the item still says what it said"
    end

    test "refuses a recording that does not exist", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      assert :error = Library.link(user_id, playlist.id, entry.id, Ecto.UUID.generate())
    end

    test "somebody else's item cannot be unlinked", %{playlist: playlist, entry: entry} do
      # Scoped like `fetch_playlist/2`, and for the same reason: an id is not a
      # way to learn what exists.
      stranger = AuthFixtures.user_id_fixture()

      assert :error = Library.unlink(stranger, playlist.id, entry.id)
    end
  end

  describe "correcting what an item says" do
    setup %{user_id: user_id} do
      {:ok, playlist} = Library.create_playlist(user_id, "Mine")

      Library.append(user_id, playlist.id, [
        track(%{isrc: isrc("ZZZ992500001"), title: "Crucible", artists: ["Hunters & Collectors"]})
      ])

      [entry] = Library.entries(user_id, playlist.id)

      %{playlist: playlist, entry: entry}
    end

    test "an owner may fix what the source said", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      assert :ok =
               Library.update_item(user_id, playlist.id, entry.id, %{
                 artists: ["Neil Finn", "Eddie Vedder"],
                 album: "7 Worlds Collide"
               })

      assert [corrected] = Library.entries(user_id, playlist.id)
      assert corrected.track.artists == ["Neil Finn", "Eddie Vedder"]
      assert corrected.track.album == "7 Worlds Collide"
      assert corrected.track.title == "Crucible"
    end

    test "and does not thereby correct it for everybody", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      # The whole reason phase 1 moved this metadata off the recording. A
      # recording belongs to nobody, so one person's fix must not reach it.
      recording = Repo.get!(Recording, entry.track.provider_id)

      assert :ok =
               Library.update_item(user_id, playlist.id, entry.id, %{title: "Something Else"})

      assert Repo.get!(Recording, recording.id).title == recording.title
    end

    test "the link survives a correction", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      # Deliberate: an edit is usually a typo, and dropping the match on every
      # one of them would punish the careful. Unlinking stays a separate act.
      assert :ok = Library.update_item(user_id, playlist.id, entry.id, %{title: "Crucible "})

      assert [still_linked] = Library.entries(user_id, playlist.id)
      assert still_linked.linked?
    end

    test "nothing outside the owned fields can be reached through it", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      # `position` and `recording_id` are both castable by the changeset,
      # because `append/3` and `set_link/4` need them. `update_item/4` is what
      # says a *person* may not set them, and a form posting either is the
      # reason the filter is by name rather than by trust.
      elsewhere = Ecto.UUID.generate()

      assert :ok =
               Library.update_item(user_id, playlist.id, entry.id, %{
                 "title" => "Crucible",
                 "position" => 99,
                 "recording_id" => elsewhere
               })

      assert [unmoved] = Library.entries(user_id, playlist.id)
      assert unmoved.position == 0
      assert unmoved.track.provider_id == entry.track.provider_id
    end

    test "an item still needs a title", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Library.update_item(user_id, playlist.id, entry.id, %{title: nil})

      assert "can't be blank" in errors_on(changeset).title
    end

    test "somebody else's item cannot be edited", %{playlist: playlist, entry: entry} do
      stranger = AuthFixtures.user_id_fixture()

      assert :error = Library.update_item(stranger, playlist.id, entry.id, %{title: "Mine now"})
    end

    test "a corrected item can become the recording it describes", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      # The half `link_candidates/4` cannot cover: it offers only what the
      # library already holds, so a track whose real recording nobody has
      # imported has nothing to choose from.
      Library.unlink(user_id, playlist.id, entry.id)

      Library.update_item(user_id, playlist.id, entry.id, %{
        title: "Crucible",
        artists: ["Neil Finn", "Eddie Vedder"],
        album: "7 Worlds Collide",
        isrc: isrc("ZZZ992600001")
      })

      assert {:ok, :created, %Recording{} = stored} =
               Library.link_to_own_details(user_id, playlist.id, entry.id)

      assert stored.artists == ["Neil Finn", "Eddie Vedder"]
      assert stored.id != entry.track.provider_id

      assert [relinked] = Library.entries(user_id, playlist.id)
      assert relinked.linked?
      assert relinked.track.provider_id == stored.id
    end

    test "says when the details name something the library already has", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      # The button reads "use this track's own details" and, when the ISRC is
      # unchanged, links straight back to the recording that was just rejected.
      # That is correct — a canonical ISRC is what anchors identity here, so
      # these *are* the same recording — but silence made it look broken.
      Library.unlink(user_id, playlist.id, entry.id)

      assert {:ok, :existing, _recording} =
               Library.link_to_own_details(user_id, playlist.id, entry.id)
    end

    test "and clearing the ISRC is the way out", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      # Somebody who genuinely has a different recording says so by dropping the
      # anchor. The exact title-album-credit key then applies, and their
      # corrected words make a row of their own.
      Library.unlink(user_id, playlist.id, entry.id)

      Library.update_item(user_id, playlist.id, entry.id, %{
        isrc: nil,
        artists: ["Somebody Else Entirely"]
      })

      assert {:ok, :created, stored} =
               Library.link_to_own_details(user_id, playlist.id, entry.id)

      assert stored.id != entry.track.provider_id
    end

    test "and links to an existing recording rather than copying it", %{
      user_id: user_id,
      playlist: playlist,
      entry: entry
    } do
      # `find_or_create/1`, not `create/1`: an item whose details already
      # describe something the library holds must not make a second copy of it.
      Library.unlink(user_id, playlist.id, entry.id)

      assert {:ok, :existing, recording} =
               Library.link_to_own_details(user_id, playlist.id, entry.id)

      assert recording.id == entry.track.provider_id
    end
  end

  describe "asking MusicBrainz again" do
    setup %{user_id: user_id} do
      {:ok, playlist} = Library.create_playlist(user_id, "Mine")

      Library.append(user_id, playlist.id, [
        track(%{isrc: isrc("ZZZ992700001"), title: "Never Identified"}),
        track(%{isrc: isrc("ZZZ992800001"), title: "Already Identified"})
      ])

      [first, second] = Library.entries(user_id, playlist.id)

      # The second one has an answer already, which is the case this must skip.
      Repo.update_all(
        from(r in Recording, where: r.id == ^second.track.provider_id),
        set: [musicbrainz_recording_id: Ecto.UUID.generate(), enriched_at: DateTime.utc_now()]
      )

      %{playlist: playlist, unidentified: first, identified: second}
    end

    test "queues only what has no answer yet", %{
      user_id: user_id,
      playlist: playlist,
      identified: identified
    } do
      # Enrichment fills gaps and never overwrites, so re-asking about a
      # recording that already carries an id spends a request to learn nothing.
      assert {:ok, 1} = Library.reenrich(user_id, playlist.id)

      assert Repo.get!(Recording, identified.track.provider_id).musicbrainz_recording_id
    end

    test "puts the re-asked track back to waiting", %{
      user_id: user_id,
      playlist: playlist,
      unidentified: unidentified
    } do
      Repo.update_all(
        from(r in Recording, where: r.id == ^unidentified.track.provider_id),
        set: [enriched_at: DateTime.utc_now(), enrichment_outcome: :declined]
      )

      assert [%{enriched?: true} | _rest] = Library.entries(user_id, playlist.id)

      assert {:ok, 1} = Library.reenrich(user_id, playlist.id)

      # Not cosmetic: the row has to stop showing a decision that is being
      # re-taken, or the screen says "no confident match" while the queue works.
      assert [%{enriched?: false} | _rest] = Library.entries(user_id, playlist.id)
    end

    test "one entry can be re-asked on its own", %{
      user_id: user_id,
      playlist: playlist,
      unidentified: unidentified
    } do
      assert {:ok, 1} = Library.reenrich_entry(user_id, playlist.id, unidentified.id)
    end

    test "an unlinked entry has nothing to look up", %{
      user_id: user_id,
      playlist: playlist,
      unidentified: unidentified
    } do
      Library.unlink(user_id, playlist.id, unidentified.id)

      # Zero rather than an error: "there is nothing to ask about" is a true
      # statement about that row, not a failure of the request.
      assert {:ok, 0} = Library.reenrich_entry(user_id, playlist.id, unidentified.id)
    end

    test "somebody else cannot re-ask about your playlist", %{playlist: playlist} do
      stranger = AuthFixtures.user_id_fixture()

      assert :error = Library.reenrich(stranger, playlist.id)
    end
  end

  describe "search/2" do
    test "finds a held recording by ISRC" do
      Library.find_or_create(track(%{isrc: "USSM11100234"}))

      assert [%Track{provider: :library} = found] =
               Library.search(track(%{isrc: "USSM11100234", provider: :navidrome}), 10)

      assert found.isrc == isrc("USSM11100234")
    end

    test "finds one by title when the source carries no ISRC" do
      # A title no real catalogue holds. Recordings belong to nobody, so a
      # search by title is answered from every row in the shared database — a
      # real title here would match whatever somebody imported into dev.
      Library.find_or_create(track(%{isrc: nil, title: "Zzyzx Interlude"}))

      assert [%Track{title: "Zzyzx Interlude"}] =
               Library.search(track(%{isrc: nil, title: "zzyzx interlude"}), 10)
    end

    test "a recording it does not hold is no candidates, not an error" do
      assert Library.search(track(%{isrc: "ZZZZ99999999"}), 10) == []
    end

    test "honours the caller's limit" do
      for n <- 1..5, do: Library.find_or_create(track(%{isrc: nil, title: "Ripple #{n}"}))

      assert length(Library.search(track(%{isrc: nil, title: "Ripple 1"}), 2)) <= 2
    end

    test "candidates belong to the library, which the adapter contract requires" do
      Library.find_or_create(track(%{isrc: "USSM11100234"}))

      assert [%Track{provider: :library, provider_id: id}] =
               Library.search(track(%{isrc: "USSM11100234"}), 10)

      assert is_binary(id) and id != "",
             "a candidate that cannot be addressed would be written to nothing"
    end
  end

  describe "playlists and their contents" do
    test "append puts recordings in order and reports how many", %{user_id: user_id} do
      {:ok, playlist} = Library.create_playlist(user_id, "Road Trip")

      tracks = for title <- ~w(One Two Three), do: track(%{isrc: nil, title: title})

      assert Library.append(user_id, playlist.id, tracks) == 3

      assert Library.tracks(user_id, playlist.id) |> Enum.map(& &1.title) == ~w(One Two Three)
    end

    test "a second append continues rather than restarting the numbering", %{user_id: user_id} do
      {:ok, playlist} = Library.create_playlist(user_id, "Road Trip")

      Library.append(user_id, playlist.id, [track(%{isrc: nil, title: "One"})])
      Library.append(user_id, playlist.id, [track(%{isrc: nil, title: "Two"})])

      assert Library.tracks(user_id, playlist.id) |> Enum.map(& &1.title) == ~w(One Two)
    end

    test "the same recording may be held twice", %{user_id: user_id} do
      # A playlist legitimately contains the same recording twice, which is why
      # neither the position nor the pair is unique.
      {:ok, playlist} = Library.create_playlist(user_id, "Road Trip")
      same = track(%{isrc: "USSM11100234"})

      assert Library.append(user_id, playlist.id, [same, same]) == 2
      assert length(Library.tracks(user_id, playlist.id)) == 2
    end

    test "remove takes every occurrence", %{user_id: user_id} do
      {:ok, playlist} = Library.create_playlist(user_id, "Road Trip")
      doomed = track(%{isrc: "USSM11100234"})
      kept = track(%{isrc: nil, title: "Kept"})

      Library.append(user_id, playlist.id, [doomed, kept, doomed])

      [held] = Library.search(doomed, 1)

      assert Library.remove(playlist.id, [held]) == 2
      assert Library.tracks(user_id, playlist.id) |> Enum.map(& &1.title) == ["Kept"]
    end

    test "removing nothing removes nothing", %{user_id: user_id} do
      {:ok, playlist} = Library.create_playlist(user_id, "Road Trip")
      Library.append(user_id, playlist.id, [track(%{isrc: nil, title: "One"})])

      assert Library.remove(playlist.id, []) == 0
      assert length(Library.tracks(user_id, playlist.id)) == 1
    end

    test "playlists are listed newest first, with their sizes", %{user_id: user_id} do
      {:ok, older} = Library.create_playlist(user_id, "Older")
      {:ok, newer} = Library.create_playlist(user_id, "Newer")

      Library.append(user_id, older.id, [track(%{isrc: nil, title: "One"})])

      listed = Library.playlists(user_id)

      assert Enum.map(listed, fn {playlist, count} -> {playlist.name, count} end) == [
               {"Newer", 0},
               {"Older", 1}
             ]

      assert newer.id != older.id
    end

    test "entries carry the entry's own id, not the recording's", %{user_id: user_id} do
      # The distinction the editor is built on. The same recording twice is two
      # entries, and "remove this one" cannot be answered by a recording id.
      {:ok, playlist} = Library.create_playlist(user_id, "Road Trip")
      same = track(%{isrc: "USSM11100234"})

      Library.append(user_id, playlist.id, [same, same])

      assert [first, second] = Library.entries(user_id, playlist.id)
      refute first.id == second.id
      assert first.track.provider_id == second.track.provider_id
    end

    test "removing one entry leaves the other copy", %{user_id: user_id} do
      {:ok, playlist} = Library.create_playlist(user_id, "Road Trip")
      same = track(%{isrc: "USSM11100234"})

      Library.append(user_id, playlist.id, [same, same])
      [first, _second] = Library.entries(user_id, playlist.id)

      assert Library.remove_entry(user_id, playlist.id, first.id) == :ok
      assert length(Library.entries(user_id, playlist.id)) == 1
    end

    test "removing an entry that is not in this playlist is refused", %{user_id: user_id} do
      {:ok, mine} = Library.create_playlist(user_id, "Mine")
      {:ok, other} = Library.create_playlist(user_id, "Other")

      Library.append(user_id, other.id, [track(%{isrc: nil, title: "Elsewhere"})])
      [elsewhere] = Library.entries(user_id, other.id)

      assert Library.remove_entry(user_id, mine.id, elsewhere.id) == :error
      assert length(Library.entries(user_id, other.id)) == 1
    end
  end

  describe "reordering" do
    setup %{user_id: user_id} do
      {:ok, playlist} = Library.create_playlist(user_id, "Road Trip")

      tracks = for title <- ~w(One Two Three), do: track(%{isrc: nil, title: title})
      Library.append(user_id, playlist.id, tracks)

      %{playlist: playlist}
    end

    defp titles(user_id, playlist),
      do: Library.entries(user_id, playlist.id) |> Enum.map(& &1.track.title)

    test "moving up swaps with the entry above", %{user_id: user_id, playlist: playlist} do
      [_one, two, _three] = Library.entries(user_id, playlist.id)

      Library.move_entry(user_id, playlist.id, two.id, :up)

      assert titles(user_id, playlist) == ~w(Two One Three)
    end

    test "moving down swaps with the entry below", %{user_id: user_id, playlist: playlist} do
      [one, _two, _three] = Library.entries(user_id, playlist.id)

      Library.move_entry(user_id, playlist.id, one.id, :down)

      assert titles(user_id, playlist) == ~w(Two One Three)
    end

    test "moving past either end changes nothing", %{user_id: user_id, playlist: playlist} do
      [one, _two, three] = Library.entries(user_id, playlist.id)

      Library.move_entry(user_id, playlist.id, one.id, :up)
      Library.move_entry(user_id, playlist.id, three.id, :down)

      assert titles(user_id, playlist) == ~w(One Two Three),
             "pressing a button twice at the end is not a failure"
    end

    test "place_entry drops one entry after another", %{user_id: user_id, playlist: playlist} do
      [one, _two, _three] = Library.entries(user_id, playlist.id)
      [_one, _two, three] = Library.entries(user_id, playlist.id)

      Library.place_entry(user_id, playlist.id, one.id, three.id, :after)

      assert titles(user_id, playlist) == ~w(Two Three One)
    end

    test "place_entry drops one entry before another", %{user_id: user_id, playlist: playlist} do
      [one, _two, three] = Library.entries(user_id, playlist.id)

      Library.place_entry(user_id, playlist.id, three.id, one.id, :before)

      assert titles(user_id, playlist) == ~w(Three One Two)
    end

    test "place_entry renumbers densely, leaving no gaps", %{
      user_id: user_id,
      playlist: playlist
    } do
      # Dense integers were kept over fractional ranks because a renumber
      # measures at 2.3ms. That only holds if it actually renumbers.
      [one, _two, three] = Library.entries(user_id, playlist.id)

      after_move = Library.place_entry(user_id, playlist.id, one.id, three.id, :after)

      assert Enum.map(after_move, & &1.position) == [0, 1, 2]
    end

    test "place_entry keeps every entry, and only reorders", %{
      user_id: user_id,
      playlist: playlist
    } do
      before = Library.entries(user_id, playlist.id) |> Enum.map(& &1.id) |> MapSet.new()
      [one, _two, three] = Library.entries(user_id, playlist.id)

      after_move = Library.place_entry(user_id, playlist.id, one.id, three.id, :after)

      assert MapSet.new(after_move, & &1.id) == before
    end

    test "place_entry ignores an id that is not in this playlist", %{
      user_id: user_id,
      playlist: playlist
    } do
      # The client says what was dropped where, so the server checks it. Neither
      # a stale id nor another playlist's is an error — nothing moves.
      {:ok, other} = Library.create_playlist(user_id, "Elsewhere")
      Library.append(user_id, other.id, [track(%{isrc: nil, title: "Alpha"})])
      [alpha] = Library.entries(user_id, other.id)
      [one, _two, _three] = Library.entries(user_id, playlist.id)

      assert Library.place_entry(user_id, playlist.id, alpha.id, one.id, :after) |> titles_of() ==
               ~w(One Two Three)

      assert Library.place_entry(user_id, playlist.id, one.id, alpha.id, :after) |> titles_of() ==
               ~w(One Two Three)

      assert titles(user_id, other) == ~w(Alpha)
    end

    test "place_entry onto itself changes nothing", %{user_id: user_id, playlist: playlist} do
      [one, _two, _three] = Library.entries(user_id, playlist.id)

      assert Library.place_entry(user_id, playlist.id, one.id, one.id, :before) |> titles_of() ==
               ~w(One Two Three)
    end

    defp titles_of(entries), do: Enum.map(entries, & &1.track.title)

    test "a reorder never loses, duplicates or invents an entry", %{
      user_id: user_id,
      playlist: playlist
    } do
      # The conservation law `move_entry/4` deliberately does not assert, because
      # over shared state it would accuse correct code under interleaving. The
      # sandbox makes the state exclusive, so it is sound here — see
      # `Providers.disconnect/2` for the same division.
      before = Library.entries(user_id, playlist.id) |> Enum.map(& &1.id) |> Enum.sort()

      [_one, two, three] = Library.entries(user_id, playlist.id)
      Library.move_entry(user_id, playlist.id, two.id, :up)
      Library.move_entry(user_id, playlist.id, three.id, :up)

      after_moves = Library.entries(user_id, playlist.id) |> Enum.map(& &1.id) |> Enum.sort()

      assert after_moves == before
    end

    test "an entry from another playlist cannot be moved into this one", %{
      user_id: user_id,
      playlist: playlist
    } do
      {:ok, other} = Library.create_playlist(user_id, "Other")
      Library.append(user_id, other.id, [track(%{isrc: nil, title: "Elsewhere"})])
      [elsewhere] = Library.entries(user_id, other.id)

      Library.move_entry(user_id, playlist.id, elsewhere.id, :up)

      assert titles(user_id, playlist) == ~w(One Two Three)
      assert length(Library.entries(user_id, other.id)) == 1
    end
  end

  describe "playlists themselves" do
    test "renaming keeps the contents", %{user_id: user_id} do
      {:ok, playlist} = Library.create_playlist(user_id, "Old Name")
      Library.append(user_id, playlist.id, [track(%{isrc: nil, title: "One"})])

      assert {:ok, renamed} = Library.update_playlist(user_id, playlist.id, %{name: "New Name"})
      assert renamed.name == "New Name"
      assert length(Library.entries(user_id, playlist.id)) == 1
    end

    test "renaming to nothing is refused", %{user_id: user_id} do
      {:ok, playlist} = Library.create_playlist(user_id, "Road Trip")

      assert {:error, _changeset} = Library.update_playlist(user_id, playlist.id, %{name: ""})
    end

    test "another user cannot rename or delete", %{user_id: user_id} do
      {:ok, playlist} = Library.create_playlist(user_id, "Mine")
      stranger = AuthFixtures.user_id_fixture()

      assert Library.update_playlist(stranger, playlist.id, %{name: "Theirs"}) == :error
      assert Library.delete_playlist(stranger, playlist.id) == :error
      assert {:ok, %{name: "Mine"}} = Library.fetch_playlist(user_id, playlist.id)
    end

    test "deleting takes the entries and leaves the recordings", %{user_id: user_id} do
      # The recordings belong to nobody and may be in somebody else's playlist.
      # Deleting a playlist is not a licence to delete music.
      {:ok, playlist} = Library.create_playlist(user_id, "Road Trip")
      Library.append(user_id, playlist.id, [track(%{isrc: "USSM11100234"})])

      held = Repo.aggregate(Recording, :count)

      assert Library.delete_playlist(user_id, playlist.id) == :ok
      assert Library.fetch_playlist(user_id, playlist.id) == :error
      assert Repo.aggregate(Recording, :count) == held
    end
  end

  describe "scoping" do
    test "another user's playlist is not fetchable", %{user_id: user_id} do
      # The same rule as `Transfers.fetch/2`: indistinguishable from one that
      # does not exist, so an id is not a way to learn what exists.
      {:ok, mine} = Library.create_playlist(user_id, "Mine")

      assert Library.fetch_playlist(AuthFixtures.user_id_fixture(), mine.id) == :error
      assert {:ok, _} = Library.fetch_playlist(user_id, mine.id)
    end
  end
end
