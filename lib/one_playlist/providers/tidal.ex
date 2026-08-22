defmodule OnePlaylist.Providers.Tidal do
  @moduledoc """
  The TIDAL adapter: `OnePlaylist.Providers.Adapter` for TIDAL.

  The layer that joins a stored `OnePlaylist.Providers.Connection` to the
  modules beneath it — `Client` for API calls, `OAuth` for tokens, `Mapper` for
  shapes. Everything here takes a connection and returns `OnePlaylist.Music`
  structs; the client below takes an access token and returns TIDAL's JSON.

  That split is the point. The client knows nothing about how tokens are stored
  or refreshed, and callers above never see an access token, a `countryCode`, or
  a JSON:API document.

  Every read refreshes the connection first via
  `OnePlaylist.Providers.ensure_fresh/2`, which is a no-op when the token has
  time left. A caller reading a large library over several minutes therefore
  cannot have its token expire mid-read.

  Contracts on `refresh_tokens/1` are inherited from the behaviour — there is no
  contract code in this module, and every other adapter will get the same ones.
  """

  use Bond, behaviours: [OnePlaylist.Providers.Adapter]
  use Errata

  alias OnePlaylist.Matching.Signals
  alias OnePlaylist.Music.Playlist
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Adapter
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.ConnectionUnusable
  alias OnePlaylist.Providers.Tidal.AlbumCache
  alias OnePlaylist.Providers.Tidal.Client
  alias OnePlaylist.Providers.Tidal.Mapper
  alias OnePlaylist.Providers.Tidal.OAuth

  @impl true
  def provider, do: :tidal

  @impl true
  def refresh_tokens(refresh_token), do: OAuth.refresh(refresh_token)

  @impl true
  def whoami(%Connection{} = connection) do
    with {:ok, connection} <- Providers.ensure_fresh(connection) do
      Client.current_user(connection.access_token)
    end
  end

  @impl true
  def stream_playlists(%Connection{} = connection, opts) do
    with {:ok, connection} <- Providers.ensure_fresh(connection) do
      stream =
        connection.access_token
        |> Client.stream_playlists(connection.provider_user_id, call_opts(connection, opts))
        |> Stream.map(&Mapper.playlist/1)

      {:ok, stream}
    end
  end

  @impl true
  def stream_tracks(connection, playlist, opts)

  def stream_tracks(%Connection{} = connection, %Playlist{provider_id: id}, opts),
    do: stream_tracks(connection, id, opts)

  def stream_tracks(%Connection{} = connection, playlist, opts) when is_binary(playlist) do
    with {:ok, connection} <- Providers.ensure_fresh(connection) do
      {:ok,
       Client.stream_playlist_tracks(
         connection.access_token,
         playlist,
         call_opts(connection, opts)
       )}
    end
  end

  @impl true
  def search_tracks(%Connection{} = connection, %Track{} = track, opts \\ []) do
    with {:ok, connection} <- Providers.ensure_fresh(connection) do
      connection
      |> candidates(track, call_opts(connection, opts))
      |> limit_to(Adapter.limit(opts))
    end
  end

  # ISRC first, always. It is one request, the results are exact, and it does
  # not need a scope this connection may not have.
  defp candidates(connection, %Track{isrc: isrc}, opts) when is_binary(isrc) do
    Client.tracks_by_isrc(connection.access_token, isrc, opts)
  end

  # No ISRC, but the source knows its release and its position on it. Find the
  # release by barcode and take the track at that position: two requests, and
  # the answer is exact rather than scored.
  #
  # Sources that carry both are the ones ISRC failed on for a reason worth
  # recovering — a recording issued with a different ISRC per territory. Spotify
  # and Apple Music both supply barcode and track number natively, so this is
  # the path that will carry most of the traffic once either is added.
  #
  # Falls back to text when the release is unknown to TIDAL or lists nothing at
  # that position, rather than returning no candidates: a structural miss here
  # says nothing about whether the recording exists.
  defp candidates(
         connection,
         %Track{album_upc: upc, track_number: number} = track,
         opts
       )
       when is_binary(upc) and is_integer(number) do
    case by_release_position(connection, track, opts) do
      {:ok, [_candidate | _rest] = found} -> {:ok, found}
      _miss_or_error -> text_candidates(connection, track, opts)
    end
  end

  defp candidates(connection, %Track{} = track, opts),
    do: text_candidates(connection, track, opts)

  # Needs the `search.read` scope, which a connection authorized before it was
  # requested will not have — checked here because TIDAL reports its absence as
  # `400 INVALID_RESOURCE_ID`, which names neither scopes nor the parameter it
  # is really complaining about.
  defp text_candidates(connection, %Track{} = track, opts) do
    if "search.read" in (connection.scopes || []) do
      Client.search_tracks(connection.access_token, search_query(track), opts)
    else
      {:error,
       Errata.create(ConnectionUnusable,
         reason: :insufficient_scope,
         context: %{
           provider: :tidal,
           required_scope: "search.read",
           granted_scopes: connection.scopes
         }
       )}
    end
  end

  defp by_release_position(connection, %Track{} = track, opts) do
    barcode = Signals.normalize_barcode(track.album_upc)
    token = connection.access_token
    lookup_opts = Keyword.put(opts, :barcode, track.album_upc)

    with true <- is_binary(barcode),
         {:ok, album_id} when is_binary(album_id) <-
           AlbumCache.fetch(barcode, fn -> Client.album_by_barcode(token, barcode, opts) end),
         {:ok, tracks} <- Client.album_items(token, album_id, lookup_opts) do
      {:ok, Enum.filter(tracks, &same_position?(&1, track))}
    else
      # A barcode TIDAL does not carry, or a release that lists nothing at that
      # position. Both are misses, not failures.
      _miss -> {:ok, []}
    end
  end

  defp same_position?(candidate, source) do
    candidate.track_number == source.track_number and
      (candidate.volume_number || 1) == (source.volume_number || 1)
  end

  # Title and artists, as a person would type it.
  #
  # Deliberately the raw title rather than the normalized one: normalization
  # exists to compare two strings that already describe the same recording, and
  # stripping `(Live)` here would ask TIDAL for the studio version and then
  # reject everything it sent back. The matching engine applies its own rules
  # to whatever comes back.
  defp search_query(%Track{} = track) do
    [track.title | track.artists]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.trim()
  end

  defp limit_to({:ok, tracks}, limit), do: {:ok, Enum.take(tracks, limit)}
  defp limit_to({:error, error}, _limit), do: {:error, error}

  defp call_opts(connection, opts), do: Keyword.put_new(opts, :country, connection.country)
end
