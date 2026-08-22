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

  alias OnePlaylist.Music.Playlist
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Adapter
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.ConnectionUnusable
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

  defp candidates(connection, _track, _opts) do
    # Text search is not implemented, and this says so rather than guessing.
    #
    # TIDAL's search endpoint needs the `search.read` scope, which was added to
    # the requested set only after this connection was authorized. Without it
    # every search shape tried returns `400 INVALID_RESOURCE_ID` — identical to
    # a malformed query — so the endpoint's real request and response shapes
    # cannot be established from here. Verified across five variants on
    # 2026-08-22.
    #
    # Building against a guessed shape would be worse than not building it: the
    # failure would be a wrong match rather than a missing feature. Reconnecting
    # grants the scope, after which this can be written against something
    # observed instead of assumed.
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

  defp limit_to({:ok, tracks}, limit), do: {:ok, Enum.take(tracks, limit)}
  defp limit_to({:error, error}, _limit), do: {:error, error}

  defp call_opts(connection, opts), do: Keyword.put_new(opts, :country, connection.country)
end
