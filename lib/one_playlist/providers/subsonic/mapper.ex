defmodule OnePlaylist.Providers.Subsonic.Mapper do
  @moduledoc """
  Turns Subsonic's flat JSON into `OnePlaylist.Music` structs.

  Much shorter than `OnePlaylist.Providers.Tidal.Mapper`, and the difference is
  the protocol rather than the effort. Subsonic returns a song with its artist
  and album inline, so there is no `included` array to index and no
  relationship to resolve — the whole class of bug those conservation contracts
  guard against does not exist here.

  What does exist is a set of small shape differences, each of which would be a
  silent wrong answer rather than a crash:

    * **`isrc` is an array.** `"isrc": ["DESK90390301"]` where TIDAL sends a
      string. Passed through unflattened it would never equal a TIDAL ISRC, and
      rung 1 of the matching ladder would quietly never fire — the single most
      valuable rung, disabled by a type mismatch nothing checks.
    * **`duration` is seconds already**, not an ISO 8601 string.
    * **`artist` is a display string**, which for a multi-artist track is one
      pre-joined credit rather than a list.
  """

  use Bond

  alias OnePlaylist.Music.Isrc
  alias OnePlaylist.Music.Playlist
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers.Payload

  @provider :navidrome

  @doc """
  Maps a Subsonic song to `OnePlaylist.Music.Track`.
  """
  # `isrc` feeds an exact identity comparison, so a list where a string belongs
  # does not fail loudly — it fails by never matching. The postcondition is the
  # cheapest place to state that this module emits the shape the rest of the
  # application compares against.
  @post identity_preserved: result.provider_id == to_string(resource["id"]),
        isrc_is_scalar: is_nil(result.isrc) or is_binary(result.isrc),
        artists_are_names: forall(artist <- result.artists, is_binary(artist)),
        # A recording cannot be of negative length, so a negative value is not a
        # shorter track — it is one that scores as a *near miss* against real
        # durations in `OnePlaylist.Matching.Similarity`, quietly nudging the
        # wrong candidate over the threshold.
        #
        # `OnePlaylist.Providers.Tidal.Mapper` states the same law one level
        # down, on `OnePlaylist.Providers.Payload.duration/1`, and so does not repeat it
        # here. This mapper has no such parser — Subsonic sends seconds as an
        # integer and a private helper filters it — so without this the law is
        # written nowhere a caller can see.
        duration_is_never_negative:
          is_nil(result.duration_seconds) or result.duration_seconds >= 0
  @spec track(map()) :: Track.t()
  def track(resource) when is_map(resource) do
    %Track{
      provider: @provider,
      provider_id: to_string(resource["id"]),
      isrc: isrc(resource["isrc"]),
      title: resource["title"],
      album: resource["album"],
      album_upc: nil,
      # Subsonic's `track` is the position within its album, which is exactly
      # what rung 2 wants — but without a barcode to pair it with, it cannot
      # fire. Carried anyway: it costs nothing and a future provider pairing
      # would need it.
      track_number: Payload.position(resource["track"]),
      volume_number: Payload.position(resource["discNumber"]),
      duration_seconds: Payload.count(resource["duration"]),
      explicit: resource["explicitStatus"] == "explicit",
      artists: artists(resource)
    }
  end

  @doc "Maps a Subsonic playlist resource to `OnePlaylist.Music.Playlist`."
  @post identity_preserved: result.provider_id == to_string(resource["id"]),
        sane_track_count: is_nil(result.track_count) or result.track_count >= 0
  @spec playlist(map()) :: Playlist.t()
  def playlist(resource) when is_map(resource) do
    %Playlist{
      provider: @provider,
      provider_id: to_string(resource["id"]),
      name: resource["name"],
      description: Payload.text(resource["comment"]),
      track_count: Payload.count(resource["songCount"]),
      duration_seconds: Payload.count(resource["duration"]),
      created_at: Payload.timestamp(resource["created"]),
      updated_at: Payload.timestamp(resource["changed"]),
      # Every playlist a Subsonic account can see through `getPlaylists` is
      # either its own or shared with it, and the API does not distinguish. A
      # transfer only ever *reads* a source, so guessing `true` here would be a
      # claim this module cannot support.
      owned: nil
    }
  end

  # The array-vs-string difference, in one place. Also tolerates the string a
  # different Subsonic implementation might send, because the protocol has
  # several servers and this field is an OpenSubsonic extension rather than part
  # of 1.16.1.
  # Normalised, not merely extracted. A Subsonic ISRC comes from a file tag,
  # which is as untrusted as a spreadsheet cell — and an ISRC that is not in
  # canonical form is rejected by the providers it is looked up against. See
  # `OnePlaylist.Music.Isrc`.
  defp isrc(value) when is_binary(value), do: value |> Payload.text() |> Isrc.normalize()

  defp isrc([first | _rest]) when is_binary(first),
    do: first |> Payload.text() |> Isrc.normalize()

  defp isrc(_value), do: nil

  # `artists` is the OpenSubsonic structured field; `artist` is the 1.16.1
  # display string. Preferring the former keeps a multi-artist credit as
  # separate names, which is what `OnePlaylist.Matching.Normalize` wants — the
  # display string would arrive pre-joined and have to be split back apart by
  # guessing at the separator.
  defp artists(%{"artists" => artists}) when is_list(artists) and artists != [] do
    artists
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
  end

  defp artists(%{"artist" => artist}) when is_binary(artist), do: [artist]
  defp artists(_resource), do: []
end
