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

  ## The contracts describe what this emits, never what it received

  This is a parsing boundary, so nothing here rejects an input: a provider
  sending nonsense is not a programming error, and a contract that raised on it
  would turn their bad data into our crash. Field-level sanitizing is
  `OnePlaylist.Providers.Payload`'s; the postconditions below are conservation
  laws about the tracks that come out.
  """

  use Bond

  alias OnePlaylist.Music.Playlist
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers.Payload

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
      description: Payload.text(attributes["description"]),
      track_count: Payload.count(attributes["numberOfItems"]),
      duration_seconds: Payload.duration(attributes["duration"]),
      created_at: Payload.timestamp(attributes["createdAt"]),
      updated_at: Payload.timestamp(attributes["lastModifiedAt"]),
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
      version: Payload.text(attributes["version"]),
      album: get_in(album, ["attributes", "title"]),
      # TIDAL exposes the release barcode on the album resource, so this costs
      # nothing extra when albums are already included — but it does *not*
      # expose the track's position within that album on the track resource or
      # on the relationship, so `track_number` stays nil here. Rung 2 of the
      # ladder therefore does not fire for TIDAL sources; the barcode is still
      # worth carrying, because it corroborates a text match strongly.
      album_upc: Payload.text(get_in(album, ["attributes", "barcodeId"])),
      artists: related_names(resource, "artists", index),
      duration_seconds: Payload.duration(attributes["duration"]),
      explicit: attributes["explicit"],
      popularity: attributes["popularity"],
      artwork_url: artwork_url(album, index)
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
    # Type-checked, unlike `tracks_from_items_page/1`, which deliberately maps
    # videos too because a playlist can hold them. Here `data` is the *answer to
    # a catalogue query for tracks*, so anything else in it means this function
    # was handed the wrong document shape — and without this filter it would
    # oblige, mapping a `searchResults` wrapper into a track whose id is the
    # search token. That passes the conservation postconditions, because the id
    # really was in `data`; a property comparing the shapes is what caught it.
    |> Enum.filter(&(&1["type"] == "tracks" and is_map_key(&1, "id")))
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
  Maps an album's item list to tracks, carrying each one's position.

  The only place `track_number` and `volume_number` get populated for TIDAL,
  and the reason rung 2 of the matching ladder can fire at all.

  Positions come from `meta` on each item — `%{"trackNumber" => 1,
  "volumeNumber" => 1}` — and **not** from the item's index in the list. That
  distinction is load-bearing rather than stylistic: a track unavailable in the
  account's country is listed but its resource is not returned, exactly as on
  playlists. Counting positions by index would shift every track after such a
  gap by one, and rung 2 would then match confidently, at score 1.0, to the
  wrong recording — the worst failure this product has, produced by an
  optimisation that looks equivalent.

  `album_upc` is passed in rather than read from the document, because the
  caller reached this album *by* its barcode and including the album resource
  again would be a second copy of something already known.
  """
  @post no_tracks_invented: forall(track <- result, track.provider_id in album_item_ids(document))
  @post never_more_than_listed: length(result) <= length(album_item_ids(document))
  @post positions_are_populated: forall(track <- result, is_integer(track.track_number))
  @spec tracks_from_album_items(map(), String.t() | nil) :: [Track.t()]
  def tracks_from_album_items(document, album_upc \\ nil) do
    index = index_included(document)

    document
    |> Map.get("data", [])
    |> List.wrap()
    |> Enum.flat_map(fn item ->
      with {:ok, resource} <- Map.fetch(index, {item["type"], item["id"]}),
           number when is_integer(number) <- get_in(item, ["meta", "trackNumber"]) do
        [
          %{
            track(resource, index)
            | track_number: number,
              volume_number: get_in(item, ["meta", "volumeNumber"]) || 1,
              album_upc: album_upc
          }
        ]
      else
        _unresolvable_or_unnumbered -> []
      end
    end)
  end

  @doc """
  The item ids an album lists, in order.

  Public because `tracks_from_album_items/2` names it in a postcondition.
  """
  @spec album_item_ids(map()) :: [String.t()]
  def album_item_ids(document) do
    document
    |> Map.get("data", [])
    |> List.wrap()
    |> Enum.map(& &1["id"])
    |> Enum.reject(&is_nil/1)
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

  @doc """
  Each entry's track id paired with the id of that *entry*, in playlist order.

  The two are different things and both are needed to remove one: TIDAL keys a
  removal on the track id **and** `meta.itemId`, and rejects either alone with a
  `400` whose message is "Must not be null" and which does not say which field
  it means. See `c:OnePlaylist.Providers.Adapter.remove_tracks/4`.

  A track added twice appears twice here, with the same track id and different
  item ids — which is what makes removing one occurrence of a duplicate
  possible, and what stops `item_ids/1` being enough.
  """
  # An entry missing either half is dropped rather than returned with a `nil`,
  # because both halves travel straight into a delete body. `to_string(nil)` is
  # `""`, and TIDAL's answer to a blank item id is the same unhelpful 400 as its
  # answer to an absent one — so the failure would arrive as "the provider
  # refused" rather than as "we sent nonsense".
  @post no_entries_invented: forall(reference <- result, elem(reference, 0) in item_ids(document))
  @post both_ids_usable:
          forall(
            reference <- result,
            is_binary(elem(reference, 0)) and elem(reference, 0) != "" and
              is_binary(elem(reference, 1)) and elem(reference, 1) != ""
          )
  @spec item_references(map()) :: [{String.t(), String.t()}]
  def item_references(document) do
    document
    |> Map.get("data", [])
    |> List.wrap()
    |> Enum.flat_map(fn entry ->
      track_id = entry["id"]
      item_id = get_in(entry, ["meta", "itemId"])

      if usable?(track_id) and usable?(item_id), do: [{track_id, item_id}], else: []
    end)
  end

  defp usable?(value), do: is_binary(value) and value != ""

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

  # A cover image, one relationship hop past the album. TIDAL models artwork as
  # its own resource — `albums.coverArt` — so it arrives in the same response
  # whenever the include chain asks for it, and costs no extra request.
  #
  # `nil` all the way down when the caller did not include it, which is most of
  # them: the artwork is for a person choosing between candidates, not for the
  # matching engine, which never looks at it.
  defp artwork_url(album, index) do
    album
    |> related_resource("coverArt", index)
    |> get_in(["attributes", "files"])
    |> List.wrap()
    |> smallest_usable_file()
  end

  # The smallest file that still looks sharp in a report row, rather than the
  # first or the largest. TIDAL offers the same cover from 80px to 1280px, and a
  # hundred-row report that reached for 1280 would pull tens of megabytes to draw
  # thumbnails.
  @thumbnail_px 160

  defp smallest_usable_file([]), do: nil

  defp smallest_usable_file(files) do
    sized = Enum.filter(files, &is_integer(get_in(&1, ["meta", "width"])))

    big_enough = Enum.filter(sized, &(get_in(&1, ["meta", "width"]) >= @thumbnail_px))

    # Falls back to the largest available rather than to nothing: a cover only
    # published at 80px is still better than a blank square.
    chosen =
      case big_enough do
        [] -> Enum.max_by(sized, &get_in(&1, ["meta", "width"]), fn -> nil end)
        candidates -> Enum.min_by(candidates, &get_in(&1, ["meta", "width"]))
      end

    Payload.text(chosen["href"])
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
end
