defmodule OnePlaylist.Providers.Spotify.MapperTest do
  @moduledoc """
  Spotify's JSON into `OnePlaylist.Music` structs, and mostly: what is not a
  track.

  Every other adapter here maps playlists whose every entry is a track. Spotify
  is the first whose playlists carry things that are not — local files, podcast
  episodes and outright `null` — and each arrives in a different shape. That is
  what most of this file is about, because
  `c:OnePlaylist.Providers.Adapter.playlist_track_ids/3` documents that a blank
  id fails in *both* directions: read as absent it duplicates a track, and
  collided with another blank it silently drops one.
  """

  use ExUnit.Case, async: true
  use Bond.Test

  alias OnePlaylist.Music.Playlist
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers.Spotify.Mapper

  defp track_object(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "type" => "track",
        "name" => "Song #{id}",
        "duration_ms" => 211_000,
        "explicit" => false,
        "popularity" => 42,
        "track_number" => 3,
        "disc_number" => 1,
        "external_ids" => %{"isrc" => "GBAYE0601498"},
        "artists" => [%{"name" => "Radiohead"}],
        "album" => %{
          "id" => "alb1",
          "name" => "Hail to the Thief",
          "images" => [%{"url" => "https://i.example/large.jpg", "height" => 640}]
        }
      },
      overrides
    )
  end

  defp item(track), do: %{"added_at" => "2026-01-01T00:00:00Z", "track" => track}

  defp page(items), do: %{"items" => items, "next" => nil}

  describe "track/1" do
    test "reads what Spotify gives away free" do
      assert %Track{} = track = Mapper.track(track_object("t1"))

      assert track.provider == :spotify
      assert track.provider_id == "t1"
      assert track.isrc == "GBAYE0601498"
      assert track.title == "Song t1"
      assert track.album == "Hail to the Thief"
      assert track.artists == ["Radiohead"]
      assert track.track_number == 3
      assert track.volume_number == 1
      assert track.artwork_url == "https://i.example/large.jpg"
    end

    # Milliseconds, where TIDAL uses an ISO 8601 duration. Rounded rather than
    # truncated: the duration signal compares within a few seconds, and a
    # consistent half-second downward bias is free to avoid.
    test "converts milliseconds to seconds, rounding" do
      assert Mapper.track(track_object("t1", %{"duration_ms" => 211_600})).duration_seconds == 212
      assert Mapper.track(track_object("t1", %{"duration_ms" => 211_400})).duration_seconds == 211
      assert Mapper.track(track_object("t1", %{"duration_ms" => nil})).duration_seconds == nil
    end

    # The barcode is genuinely absent from a track's nested album — it only
    # appears on `GET /albums/{id}`. Asserted so that a future reader does not
    # take the nil for a mapping bug.
    test "has no barcode, because a nested album carries none" do
      assert Mapper.track(track_object("t1")).album_upc == nil
    end

    test "keeps several artists in order" do
      resource =
        track_object("t1", %{"artists" => [%{"name" => "Neil Finn"}, %{"name" => "Eddie Vedder"}]})

      assert Mapper.track(resource).artists == ["Neil Finn", "Eddie Vedder"]
    end
  end

  describe "playlist/2" do
    test "maps what a picker needs" do
      resource = %{
        "id" => "p1",
        "name" => "Road Trip",
        "description" => "Loud",
        "tracks" => %{"total" => 42},
        "external_urls" => %{"spotify" => "https://open.spotify.com/playlist/p1"},
        "owner" => %{"id" => "jason"}
      }

      assert %Playlist{} = playlist = Mapper.playlist(resource, "jason")

      assert playlist.provider_id == "p1"
      assert playlist.name == "Road Trip"
      assert playlist.track_count == 42
      assert playlist.owned == true
    end

    # `/me/playlists` returns followed playlists alongside owned ones, and a
    # followed playlist is readable but not writable — a transfer targeting one
    # fails at the append with a 403 that names nothing useful.
    test "says a followed playlist is not the user's" do
      resource = %{"id" => "p2", "name" => "Someone Else's", "owner" => %{"id" => "stranger"}}

      assert Mapper.playlist(resource, "jason").owned == false
    end

    # `false` would claim the playlist belongs to somebody else, which is a
    # different statement from not knowing.
    test "says nothing about ownership when the viewer is unknown" do
      resource = %{"id" => "p3", "name" => "Unknown", "owner" => %{"id" => "stranger"}}

      assert Mapper.playlist(resource).owned == nil
    end
  end

  describe "the three ways an item is not a track" do
    test "a local file is dropped" do
      local = %{"id" => nil, "type" => "track", "is_local" => true, "name" => "Bootleg.mp3"}

      tracks = Mapper.tracks(page([item(track_object("t1")), item(local)]))

      assert Enum.map(tracks, & &1.provider_id) == ["t1"]
    end

    test "a podcast episode is dropped" do
      episode = %{"id" => "ep1", "type" => "episode", "name" => "Some Podcast"}

      tracks = Mapper.tracks(page([item(track_object("t1")), item(episode)]))

      assert Enum.map(tracks, & &1.provider_id) == ["t1"]
    end

    # Not the same case as a local file, though it looks like one: `is_local`
    # is absent here, so the id check is the *only* thing rejecting it. Spotify
    # returns this shape for a track that has been relinked or withdrawn, and
    # without the case the id guard has a second guard covering for it and no
    # mutation can show whether it works.
    test "a track with an id of null and no other marking is dropped" do
      idless = %{"id" => nil, "type" => "track", "name" => "Withdrawn"}

      assert Mapper.tracks(page([item(track_object("t1")), item(idless)]))
             |> Enum.map(& &1.provider_id) == ["t1"]

      assert Mapper.track_ids(page([item(idless)])) == []
    end

    test "a null track is dropped" do
      tracks = Mapper.tracks(page([item(track_object("t1")), item(nil)]))

      assert Enum.map(tracks, & &1.provider_id) == ["t1"]
    end

    # The one that matters most for the transfer pipeline. `to_string(nil)` is
    # `""`, and a blank key in the destination snapshot either duplicates a
    # track or silently drops one — see `Adapter.playlist_track_ids/3`.
    test "no blank id ever reaches the diff" do
      local = %{"id" => nil, "type" => "track", "is_local" => true}

      ids = Mapper.track_ids(page([item(track_object("t1")), item(local), item(nil)]))

      assert ids == ["t1"]
      refute "" in ids
    end
  end

  describe "tracks/1" do
    test "keeps playlist order" do
      items = for id <- ~w(t3 t1 t2), do: item(track_object(id))

      assert Mapper.tracks(page(items)) |> Enum.map(& &1.provider_id) == ~w(t3 t1 t2)
    end

    # `Transfers.Runner` diffs on frequencies, so a playlist holding a track
    # twice must read as twice or the second copy is written again on every run.
    test "keeps duplicates" do
      items = [item(track_object("t1")), item(track_object("t1"))]

      assert Mapper.track_ids(page(items)) == ["t1", "t1"]
    end

    test "an empty page is not an error" do
      assert Mapper.tracks(page([])) == []
      assert Mapper.track_ids(page([])) == []
    end

    test "a page with no items key at all is not an error" do
      assert Mapper.tracks(%{}) == []
    end
  end

  describe "tracks_from_album/1" do
    # `GET /albums/{id}` returns simplified tracks — no `external_ids`, no
    # `album` — so without this the two fields rung 2 of the ladder needs would
    # be lost. It is also the only Spotify response with a UPC in it.
    test "carries the album's barcode and name down onto each track" do
      album = %{
        "id" => "alb1",
        "name" => "Vs.",
        "external_ids" => %{"upc" => "602547670444"},
        "images" => [%{"url" => "https://i.example/vs.jpg"}],
        "tracks" => %{
          "items" => [
            %{"id" => "a1", "type" => "track", "name" => "Go", "track_number" => 1},
            %{"id" => "a2", "type" => "track", "name" => "Animal", "track_number" => 2}
          ]
        }
      }

      assert [go, animal] = Mapper.tracks_from_album(album)

      assert go.album_upc == "602547670444"
      assert go.album == "Vs."
      assert go.artwork_url == "https://i.example/vs.jpg"
      assert go.track_number == 1
      assert animal.track_number == 2
    end
  end

  describe "tracks_from_search/1" do
    test "maps the nested items" do
      body = %{"tracks" => %{"items" => [track_object("t1"), track_object("t2")]}}

      assert Mapper.tracks_from_search(body) |> Enum.map(& &1.provider_id) == ~w(t1 t2)
    end

    test "an empty or unexpected body is not an error" do
      assert Mapper.tracks_from_search(%{"tracks" => %{"items" => []}}) == []
      assert Mapper.tracks_from_search(%{}) == []
    end
  end
end
