defmodule OnePlaylist.Providers.Tidal.Mapper do
  @moduledoc """
  Turns TIDAL's JSON:API documents into `OnePlaylist.Music` structs.

  Kept apart from `OnePlaylist.Providers.Tidal.Client` so that HTTP concerns and
  shape concerns fail separately: a change to TIDAL's payload breaks tests here,
  against recorded fixtures, rather than only showing up against the live API.

  ## Resolving `included`

  JSON:API returns relationships as identifier pairs and puts the actual
  resources in a sibling `included` array. A track's artists therefore arrive as
  `[%{"id" => "17123", "type" => "artists"}]`, with the artist's `name`
  somewhere else in the document. `index_included/1` builds the `{type, id}`
  lookup once per page so resolving is not quadratic over a large playlist.
  """

  use Bond

  alias OnePlaylist.Music.Playlist
  alias OnePlaylist.Music.Track

  @provider :tidal

  @doc "Builds a `{type, id} => resource` index from a document's `included`."
  @spec index_included(map()) :: %{{String.t(), String.t()} => map()}
  def index_included(document) do
    document
    |> Map.get("included", [])
    |> List.wrap()
    |> Map.new(fn resource -> {{resource["type"], resource["id"]}, resource} end)
  end

  # `track_count` comes straight from the provider and is shown to the user and
  # counted against in transfer reports. The same shape as the negative-duration
  # bug: not a type error, nothing raises, and a report reading "-3 tracks
  # transferred" is worse than one that fails.
  @doc "Maps a `playlists` resource to `OnePlaylist.Music.Playlist`."
  @post sane_track_count: is_nil(result.track_count) or result.track_count >= 0
  @post identity_preserved: result.provider_id == resource["id"]
  @spec playlist(map()) :: Playlist.t()
  def playlist(resource)

  def playlist(%{"id" => id} = resource) do
    attributes = resource["attributes"] || %{}

    %Playlist{
      provider: @provider,
      provider_id: id,
      name: attributes["name"],
      description: blank_to_nil(attributes["description"]),
      track_count: non_negative_count(attributes["numberOfItems"]),
      duration_seconds: Track.parse_iso8601_duration(attributes["duration"]),
      created_at: parse_datetime(attributes["createdAt"]),
      updated_at: parse_datetime(attributes["lastModifiedAt"]),
      url: sharing_url(attributes["externalLinks"]),
      owned: attributes["playlistType"] == "USER"
    }
  end

  @doc """
  Maps a `tracks` resource to `OnePlaylist.Music.Track`, resolving artists and
  album from `index`.

  Non-track items are mapped too rather than skipped — a playlist can hold
  videos, and dropping them silently would make a transfer report claim a
  complete transfer that lost items.
  """
  # `artists` feeds normalized-text matching when ISRC is absent. A nil or a
  # stray map in that list would not raise — it would be joined into a query
  # string and quietly produce a wrong match, which is this product's worst
  # failure mode rather than an error.
  @post identity_preserved: result.provider_id == resource["id"]
  @post artists_are_names: forall(artist <- result.artists, is_binary(artist))
  @spec track(map(), map()) :: Track.t()
  def track(resource, index \\ %{})

  def track(%{"id" => id} = resource, index) do
    attributes = resource["attributes"] || %{}
    album = related_resource(resource, "albums", index)

    %Track{
      provider: @provider,
      provider_id: id,
      isrc: attributes["isrc"],
      title: attributes["title"],
      version: blank_to_nil(attributes["version"]),
      album: get_in(album, ["attributes", "title"]),
      # TIDAL exposes the release barcode on the album resource, so this costs
      # nothing extra when albums are already included — but it does *not*
      # expose the track's position within that album on the track resource or
      # on the relationship, so `track_number` stays nil here. Rung 2 of the
      # ladder therefore does not fire for TIDAL sources; the barcode is still
      # worth carrying, because it corroborates a text match strongly.
      album_upc: blank_to_nil(get_in(album, ["attributes", "barcodeId"])),
      artists: related_names(resource, "artists", index),
      duration_seconds: Track.parse_iso8601_duration(attributes["duration"]),
      explicit: attributes["explicit"],
      popularity: attributes["popularity"]
    }
  end

  @doc """
  Maps a playlist-items page to tracks, in playlist order.

  Order comes from `data`, not from `included`: `included` is an unordered bag
  of resources, and a playlist whose tracks come back shuffled is a broken
  transfer. Items whose resource is missing from `included` are dropped, which
  happens for a track unavailable in the account's country — the identifier is
  listed but the resource is not returned.
  """
  # A conservation law, and the reason this is a contract rather than only a
  # test. A transfer's report is built by counting what came out of here against
  # what the provider said was in the playlist, so a mapper that invented,
  # duplicated or reordered a track would produce a report that is confidently
  # wrong — the one failure mode this product cannot afford.
  #
  # Stated over `data` because that is the authority on membership and order;
  # `included` is an unordered bag of resources that happens to contain them.
  @post no_tracks_invented: forall(track <- result, track.provider_id in item_ids(document))
  @post never_more_than_requested: length(result) <= length(item_ids(document))
  @spec tracks_from_items_page(map()) :: [Track.t()]
  def tracks_from_items_page(document) do
    index = index_included(document)

    document
    |> Map.get("data", [])
    |> List.wrap()
    |> Enum.flat_map(fn item ->
      case Map.fetch(index, {item["type"], item["id"]}) do
        {:ok, resource} -> [track(resource, index)]
        :error -> []
      end
    end)
  end

  @doc """
  Maps a document whose `data` holds track resources directly.

  The other shape. `tracks_from_items_page/1` handles a playlist's items, where
  `data` is a list of *identifiers* and the resources live in `included`; this
  handles a catalogue query such as `filter[isrc]`, where `data` is the
  resources themselves and `included` only supplies their artists and albums.

  Getting these two the wrong way round yields an empty list rather than an
  error — which is why both carry the same conservation postconditions.
  """
  @post no_tracks_invented: forall(track <- result, track.provider_id in item_ids(document))
  @post never_more_than_requested: length(result) <= length(item_ids(document))
  @spec tracks_from_data(map()) :: [Track.t()]
  def tracks_from_data(document) do
    index = index_included(document)

    document
    |> Map.get("data", [])
    |> List.wrap()
    |> Enum.filter(&is_map_key(&1, "id"))
    |> Enum.map(&track(&1, index))
  end

  @doc """
  Maps a search document to tracks, in the relevance order TIDAL returned.

  A third document shape, and the most indirect of the three. `data` holds a
  single `searchResults` resource whose id is an opaque search token; the
  tracks it found are identified by
  `data[0].relationships.tracks.data` and their resources are in `included`.

  Relevance order comes from that relationship and is worth preserving even
  though the matching engine scores every candidate: it is TIDAL's opinion,
  it is the order a `:limit` truncates against, and it is a sensible last
  tiebreaker between candidates this application cannot otherwise separate.
  """
  @post no_tracks_invented:
          forall(track <- result, track.provider_id in search_track_ids(document))
  @post never_more_than_found: length(result) <= length(search_track_ids(document))
  @spec tracks_from_search(map()) :: [Track.t()]
  def tracks_from_search(document) do
    index = index_included(document)

    document
    |> search_track_ids()
    |> Enum.flat_map(fn id ->
      case Map.fetch(index, {"tracks", id}) do
        {:ok, resource} -> [track(resource, index)]
        :error -> []
      end
    end)
  end

  @doc """
  The track ids a search document found, in relevance order.

  Public because `tracks_from_search/1` names it in a postcondition, and an
  assertion rendered into the docs should reference something a reader can look
  up.
  """
  @spec search_track_ids(map()) :: [String.t()]
  def search_track_ids(document) do
    document
    |> Map.get("data", [])
    |> List.wrap()
    |> Enum.flat_map(fn resource ->
      resource
      |> get_in(["relationships", "tracks", "data"])
      |> List.wrap()
      |> Enum.map(& &1["id"])
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The ids in a document's `data` member, in order.

  Public because `tracks_from_items_page/1` names it in a postcondition, and an
  assertion rendered into the docs should reference something a reader can look
  up.
  """
  @spec item_ids(map()) :: [String.t()]
  def item_ids(document) do
    document |> Map.get("data", []) |> List.wrap() |> Enum.map(& &1["id"])
  end

  defp related_names(resource, relationship, index) do
    resource
    |> get_in(["relationships", relationship, "data"])
    |> List.wrap()
    |> Enum.flat_map(fn ref ->
      case Map.fetch(index, {ref["type"], ref["id"]}) do
        {:ok, %{"attributes" => %{"name" => name}}} when is_binary(name) -> [name]
        _other -> []
      end
    end)
  end

  defp related_resource(resource, relationship, index) do
    resource
    |> get_in(["relationships", relationship, "data"])
    |> List.wrap()
    |> Enum.find_value(fn ref -> Map.get(index, {ref["type"], ref["id"]}) end)
  end

  # TIDAL lists several external links per resource, one per platform. The
  # sharing link is the one a person would recognise.
  defp sharing_url(links) when is_list(links) do
    Enum.find_value(links, fn link ->
      if get_in(link, ["meta", "type"]) == "TIDAL_SHARING", do: link["href"]
    end)
  end

  defp sharing_url(_links), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  # External data, so this sanitizes rather than trusts. The postcondition above
  # is then a law about what this module *produces*, which is the only thing it
  # controls — a provider sending nonsense is not a programming error, and a
  # contract that raised on it would turn their bad data into our crash.
  defp non_negative_count(count) when is_integer(count) and count >= 0, do: count
  defp non_negative_count(_count), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
