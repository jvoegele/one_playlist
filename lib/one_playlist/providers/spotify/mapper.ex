defmodule OnePlaylist.Providers.Spotify.Mapper do
  @moduledoc """
  Spotify's JSON into `OnePlaylist.Music` structs.

  Spotify's shapes are plain nested JSON rather than JSON:API, so there is no
  `included` index to resolve against and no relationship traversal — an album
  and its artists arrive inside the track that references them. That makes this
  module smaller than TIDAL's equivalent and moves all of its difficulty into
  one place: deciding what is *not* a track.

  ## Three ways a playlist item is not a track

  This is the first provider here whose playlists contain things that are not
  tracks, and each arrives differently:

    * **Local files.** `is_local: true`, and the track's `id` is `null`. These
      are files on the user's own machine that Spotify indexes but does not
      host. There is no id to address them by.
    * **Podcast episodes.** `type: "episode"`, with a perfectly good id that is
      not a track id. Adding one to a playlist by that id fails.
    * **Removed or region-blocked entries.** `track: null` outright.

  All three are dropped. That is the safe direction in both of the ways that
  matter, and the alternative is worse than it looks —
  `c:OnePlaylist.Providers.Adapter.playlist_track_ids/3` documents that a blank
  id fails *in both directions*: it reads as absent and the track is written
  again as a duplicate, or it collides with another blank and a real track is
  silently never written at all. `to_string(nil)` is `""`, so an unfiltered
  local file becomes exactly that blank key.

  Dropping them also settles what replace-mode sync does with them, and settles
  it correctly: an entry that never appears in the destination snapshot is never
  a candidate for removal, so a mirror leaves somebody's local files alone
  rather than trying and failing to delete them.

  ## What Spotify does and does not give away free

  `track_number` and `disc_number` are on every track object, which TIDAL's are
  not. The **barcode is not**: `album` inside a track is a simplified object
  with no `external_ids`, and the UPC only appears on `GET /albums/{id}`. So
  rung 2 of the matching ladder — UPC plus position — has the position and not
  the barcode from a Spotify *source*, which is the exact mirror of TIDAL's
  situation and worth knowing before assuming either provider fills that rung.
  """

  use Bond

  alias OnePlaylist.Music.Playlist
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers.Payload

  @provider :spotify

  @doc """
  Maps a Spotify playlist object.

  `viewer_id` is the connected account's Spotify id, and it decides `owned`.
  That matters more here than it would at TIDAL: `GET /me/playlists` returns
  playlists the user **follows** alongside the ones they made, and a followed
  playlist is readable but not writable. A transfer targeting one fails at the
  append with a 403 that names nothing useful, so the difference is worth
  carrying rather than discovering.

  `nil` when the caller does not know, which is honest — `owned: false` would
  claim the playlist belongs to somebody else.
  """
  @spec playlist(map(), String.t() | nil) :: Playlist.t()
  def playlist(resource, viewer_id \\ nil)

  def playlist(%{"id" => id} = resource, viewer_id) do
    %Playlist{
      provider: @provider,
      provider_id: to_string(id),
      name: Payload.text(resource["name"]),
      description: Payload.text(resource["description"]),
      track_count: get_in(resource, ["tracks", "total"]),
      url: get_in(resource, ["external_urls", "spotify"]),
      owned: owned?(resource, viewer_id)
    }
  end

  defp owned?(_resource, nil), do: nil
  defp owned?(resource, viewer_id), do: get_in(resource, ["owner", "id"]) == viewer_id

  @doc """
  Maps a Spotify track object.

  Callers must have established that this *is* a track — see `tracks/1`, which
  is the filter. Given one, every field here is present or absent rather than
  wrong.
  """
  @spec track(map()) :: Track.t()
  def track(%{"id" => id} = resource) do
    album = resource["album"] || %{}

    %Track{
      provider: @provider,
      provider_id: to_string(id),
      isrc: get_in(resource, ["external_ids", "isrc"]),
      title: Payload.text(resource["name"]),
      album: Payload.text(album["name"]),
      # Absent by shape rather than by omission — see the moduledoc. Read from
      # `external_ids` anyway, because `GET /albums/{id}` returns a full album
      # object through this same function and that one does carry it.
      album_upc: Payload.text(get_in(album, ["external_ids", "upc"])),
      track_number: resource["track_number"],
      volume_number: resource["disc_number"],
      artists: artist_names(resource),
      duration_seconds: duration(resource["duration_ms"]),
      explicit: resource["explicit"],
      popularity: resource["popularity"],
      artwork_url: artwork_url(album)
    }
  end

  @doc """
  The tracks in a page of playlist items, in playlist order.

  The filter described in the moduledoc lives here, and it is the reason this
  takes a page rather than mapping items one at a time: a caller that mapped
  each item would have to remember to skip three separate shapes, and the one
  that forgot would produce a track with a blank id.
  """
  # A conservation law, and the reason this is a contract rather than only a
  # test. A transfer's report is built by counting what came out of here against
  # what the provider said was in the playlist, so a mapper that invented,
  # duplicated or reordered a track would produce a report that is confidently
  # wrong — the one failure mode this product cannot afford.
  #
  # `every_track_is_addressable` is the local-file guard stated as a law rather
  # than trusted to the filter below it. Proven by mutation: dropping the
  # `is_binary(id)` clause from `playable?/1` fires it against a page carrying a
  # local file.
  @post no_tracks_invented: forall(track <- result, track.provider_id in item_ids(page))
  @post never_more_than_offered: length(result) <= length(item_ids(page))
  @post every_track_is_addressable:
          forall(track <- result, is_binary(track.provider_id) and track.provider_id != "")
  @spec tracks(map()) :: [Track.t()]
  def tracks(page) do
    page
    |> items()
    |> Enum.filter(&entry_playable?/1)
    |> Enum.map(&entry/1)
    |> Enum.map(&track/1)
  end

  @doc """
  The track ids in a page of playlist items, in order and with duplicates kept.

  Duplicates are the point: `OnePlaylist.Transfers.Runner` diffs on frequencies,
  so a playlist holding a track twice must read as twice or the second copy is
  written again on every run.
  """
  @post ids_are_usable_keys: forall(id <- result, is_binary(id) and id != "")
  @spec track_ids(map()) :: [String.t()]
  def track_ids(page) do
    page
    |> items()
    |> Enum.filter(&entry_playable?/1)
    |> Enum.map(&entry/1)
    |> Enum.map(&to_string(&1["id"]))
  end

  @doc """
  The tracks in a search response.

  Search results are track objects directly rather than playlist items, so none
  of the three non-track shapes can occur — but the id check is applied anyway,
  because "cannot occur" is a claim about Spotify rather than about this code.
  """
  @spec tracks_from_search(map()) :: [Track.t()]
  def tracks_from_search(%{"tracks" => %{"items" => items}}) when is_list(items) do
    items
    |> Enum.filter(&playable?/1)
    |> Enum.map(&track/1)
  end

  def tracks_from_search(_body), do: []

  @doc """
  The tracks on an album, carrying the album's own barcode and name down onto
  each one.

  `GET /albums/{id}` returns simplified track objects — no `external_ids`, no
  `album` — so the fields rung 2 of the ladder needs would be lost unless the
  album puts them back. This is also the one Spotify response that has a UPC in
  it at all.
  """
  @spec tracks_from_album(map()) :: [Track.t()]
  def tracks_from_album(%{"id" => _id} = album) do
    upc = Payload.text(get_in(album, ["external_ids", "upc"]))
    name = Payload.text(album["name"])
    artwork = artwork_url(album)

    album
    |> get_in(["tracks", "items"])
    |> List.wrap()
    |> Enum.filter(&playable?/1)
    |> Enum.map(fn simplified ->
      simplified
      |> track()
      |> Map.merge(%{album: name, album_upc: upc, artwork_url: artwork})
    end)
  end

  def tracks_from_album(_body), do: []

  @doc """
  The ids of the items a page offered, whether or not they were playable.

  Public because `tracks/1` names it in two postconditions, and an assertion
  rendered into the documentation should reference something a reader can look
  up.
  """
  @spec item_ids(map()) :: [String.t()]
  def item_ids(page) do
    page
    |> items()
    |> Enum.map(&entry/1)
    |> Enum.map(&to_string(&1["id"]))
  end

  # A playlist entry wraps what it holds; every other endpoint returns the
  # resource itself. Spotify's current shape calls the payload **`item`**, which
  # is the name that goes with `/playlists/{id}/items`; the retired `/tracks`
  # endpoint called it `track`. Both are accepted, because a stored response or
  # an older deployment can still carry the old spelling and the cost of
  # accepting it is one clause.
  #
  # The ordering is load-bearing and the reason for the `is_map/1` guards: a
  # Spotify **track object** carries `"track" => true`, a boolean flag saying it
  # is a track rather than an episode. Matching `%{"track" => _}` without the
  # guard would take that `true` for a payload and turn every search result into
  # an empty map.
  defp entry(%{"item" => item}) when is_map(item), do: item
  defp entry(%{"track" => track}) when is_map(track), do: track
  # A wrapper whose payload is `null` — a removed or region-blocked entry. Keyed
  # on `added_at`, which every playlist entry has and no track object does.
  defp entry(%{"added_at" => _when}), do: %{}
  defp entry(%{"item" => _null}), do: %{}
  defp entry(resource) when is_map(resource), do: resource

  # `is_local` lives on the **entry**, not on what it wraps — so the check has
  # to happen before the payload is extracted. Spotify happens to repeat the
  # flag on the inner object too, and `playable?/1` still reads it there, but
  # relying on that would be relying on a redundancy rather than on the field
  # that is documented to carry the answer.
  defp entry_playable?(wrapper) when is_map(wrapper),
    do: wrapper["is_local"] != true and playable?(entry(wrapper))

  defp entry_playable?(_wrapper), do: false

  # The three shapes from the moduledoc, in one predicate. An episode is
  # rejected on `type` rather than on id shape: episode ids are perfectly
  # well-formed, and it is what they identify that makes them useless here.
  defp playable?(%{"id" => id} = resource) when is_binary(id) and id != "" do
    resource["type"] in [nil, "track"] and resource["is_local"] != true
  end

  defp playable?(_resource), do: false

  defp items(%{"items" => items}) when is_list(items), do: items
  defp items(_page), do: []

  defp artist_names(resource) do
    resource
    |> Map.get("artists")
    |> List.wrap()
    |> Enum.map(&Payload.text(&1["name"]))
    |> Enum.reject(&is_nil/1)
  end

  # Spotify measures in milliseconds where TIDAL uses an ISO 8601 duration.
  # Rounded rather than truncated: a 3:30.6 track is nearer 211 seconds than
  # 210, and the duration signal compares within a few seconds.
  defp duration(ms) when is_integer(ms) and ms >= 0, do: div(ms + 500, 1000)
  defp duration(_absent), do: nil

  # Spotify offers several sizes, largest first. The largest is taken because
  # this is used for a thumbnail *and* for the library's own record of a
  # recording, and downscaling is free where upscaling is not.
  defp artwork_url(%{"images" => [%{"url" => url} | _rest]}) when is_binary(url), do: url
  defp artwork_url(_resource), do: nil
end
