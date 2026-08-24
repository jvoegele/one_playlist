defmodule OnePlaylist.Providers.LibraryTest do
  @moduledoc """
  The library as an `OnePlaylist.Providers.Adapter`.

  The third implementation of that behaviour and the one with no service behind
  it, so what is worth testing is the two places the behaviour had to give: a
  connection carrying no credential, and a destination that cannot fail to hold
  a track.
  """

  use OnePlaylist.DataCase, async: true
  use Bond.Test

  alias OnePlaylist.AuthFixtures
  alias OnePlaylist.Library
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.Library, as: LibraryAdapter

  setup do
    user_id = AuthFixtures.user_id_fixture()
    {:ok, connection} = Providers.ensure_library(user_id)

    %{user_id: user_id, connection: connection}
  end

  # Recordings belong to nobody, so a fixture cannot be scoped to the test's own
  # user the way everything else here is — and dev and test share the `postgres`
  # database. A real ISRC would find whatever somebody imported into dev, which
  # is exactly how this test started failing. `ZZ` is unassigned, so nothing
  # real can carry one of these.
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
        artists: ["Pearl Jam"]
      },
      attrs
    )
  end

  describe "a connection with no credential" do
    test "is usable, because the row is the authorization", %{connection: connection} do
      assert connection.access_token == nil
      assert Connection.usable?(connection)

      assert {:ok, ^connection} = Providers.fetch_usable_connection(connection.user_id, :library)
    end

    test "is never due for refresh", %{connection: connection} do
      # The nil expiry is what keeps `ensure_fresh/2` away from
      # `refresh_tokens/1`, which has nothing to do and says so.
      refute Connection.needs_refresh?(connection, DateTime.utc_now(), 300)
    end

    test "refreshing it is an error rather than a crash", %{connection: connection} do
      assert {:error, error} = LibraryAdapter.refresh_tokens("anything")
      assert Errata.reason(error) == :reauth_required
      assert Connection.usable?(connection), "and the connection is untouched"
    end

    test "ensuring it twice makes one row", %{user_id: user_id, connection: connection} do
      assert {:ok, again} = Providers.ensure_library(user_id)
      assert again.id == connection.id
    end
  end

  describe "a destination that cannot fail to hold a track" do
    test "declares the capability, and no other adapter does" do
      assert Providers.supports?(:library, :accepts_any_track)
      refute Providers.supports?(:tidal, :accepts_any_track)
      refute Providers.supports?(:navidrome, :accepts_any_track)
    end

    test "accept_track stores an unheld recording and gives it an id of its own", %{
      connection: connection
    } do
      assert {:ok, %Track{provider: :library} = accepted} =
               LibraryAdapter.accept_track(connection, track(%{isrc: unique_isrc()}))

      assert is_binary(accepted.provider_id) and accepted.provider_id != ""

      refute accepted.provider_id == "t-1",
             "the source's id would be looked for in the destination and not found"
    end

    test "accept_track reuses a recording it already holds", %{connection: connection} do
      isrc = unique_isrc()

      {:ok, first} = LibraryAdapter.accept_track(connection, track(%{isrc: isrc}))
      {:ok, second} = LibraryAdapter.accept_track(connection, track(%{isrc: isrc}))

      assert first.provider_id == second.provider_id
    end

    test "a catalogue refuses, which is what the capability advertises", %{connection: connection} do
      tidal = %Connection{provider: :tidal, user_id: connection.user_id, access_token: "at"}

      assert {:error, error} = OnePlaylist.Providers.Tidal.accept_track(tidal, track())
      assert Errata.reason(error) == :reauth_required
    end
  end

  describe "the behaviour" do
    test "a playlist round-trips through create, add, list and remove", %{
      connection: connection
    } do
      assert {:ok, playlist} = LibraryAdapter.create_playlist(connection, "Road Trip")
      assert playlist.provider == :library
      assert playlist.name == "Road Trip"

      first = track(%{isrc: unique_isrc(), title: "One"})
      second = track(%{isrc: nil, title: "Two"})

      assert {:ok, 2} = LibraryAdapter.add_tracks(connection, playlist, [first, second])

      assert {:ok, ids} = LibraryAdapter.playlist_track_ids(connection, playlist)
      assert length(ids) == 2
      assert Enum.all?(ids, &(is_binary(&1) and &1 != ""))

      assert {:ok, stream} = LibraryAdapter.stream_tracks(connection, playlist, [])
      assert Enum.map(stream, & &1.title) == ~w(One Two)

      [held] = Library.search(first, 1)
      assert {:ok, 1} = LibraryAdapter.remove_tracks(connection, playlist, [held])

      assert {:ok, [_one]} = LibraryAdapter.playlist_track_ids(connection, playlist)
    end

    test "searching answers with library tracks, as the contract requires", %{
      connection: connection
    } do
      isrc = unique_isrc()

      {:ok, _stored} = LibraryAdapter.accept_track(connection, track(%{isrc: isrc}))

      assert {:ok, [%Track{provider: :library}]} =
               LibraryAdapter.search_tracks(connection, track(%{isrc: isrc}))
    end

    test "listing playlists reports their sizes", %{connection: connection} do
      {:ok, playlist} = LibraryAdapter.create_playlist(connection, "Road Trip")
      {:ok, _added} = LibraryAdapter.add_tracks(connection, playlist, [track(%{isrc: nil})])

      assert {:ok, stream} = LibraryAdapter.stream_playlists(connection, [])
      assert [%{name: "Road Trip", track_count: 1, provider: :library}] = Enum.to_list(stream)
    end
  end

  describe "a playlist belonging to somebody else" do
    setup %{connection: connection} do
      stranger = AuthFixtures.user_id_fixture()
      {:ok, _theirs} = Providers.ensure_library(stranger)
      {:ok, playlist} = Library.create_playlist(stranger, "Not Yours")

      %{connection: connection, theirs: playlist}
    end

    test "cannot be read", %{connection: connection, theirs: theirs} do
      # The playlist id travels on a `transfers` row, which a user influences.
      # Filtering by playlist alone would read and write a stranger's library, so
      # every playlist-addressed call re-fetches it scoped first.
      assert {:error, _error} = LibraryAdapter.stream_tracks(connection, theirs.id, [])
      assert {:error, _error} = LibraryAdapter.playlist_track_ids(connection, theirs.id)
    end

    test "cannot be written to", %{connection: connection, theirs: theirs} do
      assert {:error, _error} = LibraryAdapter.add_tracks(connection, theirs.id, [track()])

      assert Library.tracks(theirs.user_id, theirs.id) == [],
             "and nothing reached it"
    end

    test "cannot be removed from", %{connection: connection, theirs: theirs} do
      assert {:error, _error} = LibraryAdapter.remove_tracks(connection, theirs.id, [track()])
    end
  end
end
