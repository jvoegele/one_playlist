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

  @doc "Maps a `playlists` resource to `OnePlaylist.Music.Playlist`."
  @spec playlist(map()) :: Playlist.t()
  def playlist(%{"id" => id} = resource) do
    attributes = resource["attributes"] || %{}

    %Playlist{
      provider: @provider,
      provider_id: id,
      name: attributes["name"],
      description: blank_to_nil(attributes["description"]),
      track_count: attributes["numberOfItems"],
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
  @spec track(map(), map()) :: Track.t()
  def track(%{"id" => id} = resource, index \\ %{}) do
    attributes = resource["attributes"] || %{}

    %Track{
      provider: @provider,
      provider_id: id,
      isrc: attributes["isrc"],
      title: attributes["title"],
      album: related_name(resource, "albums", index),
      artists: related_names(resource, "artists", index),
      duration_seconds: Track.parse_iso8601_duration(attributes["duration"]),
      explicit: attributes["explicit"]
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

  defp related_name(resource, relationship, index) do
    resource |> related_names(relationship, index) |> List.first()
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

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
