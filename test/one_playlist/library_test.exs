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
  alias OnePlaylist.Library.Recording
  alias OnePlaylist.Music.Track

  setup do
    %{user_id: AuthFixtures.user_id_fixture()}
  end

  defp track(attrs) do
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
      assert Repo.aggregate(from(r in Recording, where: r.isrc == "USSM11100234"), :count) == 1
    end

    test "an ISRC spelled differently is the same recording" do
      # Roon writes them lower case and hyphenated. Canonical form is what the
      # column holds, so the comparison has to be canonical too.
      first = Library.find_or_create(track(%{isrc: "GBAYE0601477"}))
      second = Library.find_or_create(track(%{isrc: "gb-aye-06-01477"}))

      assert first.id == second.id
    end

    test "a matching title alone does NOT reuse a recording" do
      # The deliberately conservative half. `search/2` will *offer* a
      # title match as a candidate, because the ladder can throw it out; joining
      # on one here would silently point somebody's playlist at a different
      # recording, and that is not undoable by adding.
      first = Library.find_or_create(track(%{isrc: nil, title: "Corduroy"}))
      second = Library.find_or_create(track(%{isrc: nil, title: "Corduroy"}))

      refute first.id == second.id
    end

    test "the ISRC is stored canonical, or not at all" do
      # The bug this caught, and it is the one this project keeps meeting: every
      # lookup normalises its query, so an ISRC stored as the source wrote it is
      # an ISRC nothing will ever find. Deduplication then fails silently in the
      # one place it is the entire point.
      lower = Library.find_or_create(track(%{isrc: "gb-aye-06-01477"}))

      assert lower.isrc == "GBAYE0601477"

      assert Library.find_or_create(track(%{isrc: "GBAYE0601477"})).id == lower.id

      junk = Library.find_or_create(track(%{isrc: "not-an-isrc"}))

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

  describe "search/2" do
    test "finds a held recording by ISRC" do
      Library.find_or_create(track(%{isrc: "USSM11100234"}))

      assert [%Track{provider: :library} = found] =
               Library.search(track(%{isrc: "USSM11100234", provider: :navidrome}), 10)

      assert found.isrc == "USSM11100234"
    end

    test "finds one by title when the source carries no ISRC" do
      Library.find_or_create(track(%{isrc: nil, title: "Setting Forth"}))

      assert [%Track{title: "Setting Forth"}] =
               Library.search(track(%{isrc: nil, title: "setting forth"}), 10)
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
