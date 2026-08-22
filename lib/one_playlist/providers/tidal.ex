defmodule OnePlaylist.Providers.Tidal do
  @moduledoc """
  Reading a user's TIDAL library.

  The layer that joins a stored `OnePlaylist.Providers.Connection` to
  `OnePlaylist.Providers.Tidal.Client`. Everything here takes a connection and
  returns `OnePlaylist.Music` structs; the client below it takes an access token
  and returns TIDAL's JSON.

  That split is the point. The client knows nothing about how tokens are stored
  or refreshed, and callers above never see an access token, a `countryCode`, or
  a JSON:API document.

  Every function refreshes the connection first via
  `OnePlaylist.Providers.ensure_fresh/2`, which is a no-op when the token has
  time left. A caller reading a large library over several minutes therefore
  cannot have its token expire mid-read.
  """

  alias OnePlaylist.Music.Playlist
  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.Tidal.Client
  alias OnePlaylist.Providers.Tidal.Mapper

  use Errata

  @doc """
  Every playlist the user owns, as a lazy stream of
  `OnePlaylist.Music.Playlist`.

  Followed playlists are deliberately excluded — see the note on
  `OnePlaylist.Providers.Tidal.Client.list_playlists/3`.
  """
  @spec stream_playlists(Connection.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Errata.error()}
  def stream_playlists(%Connection{} = connection, opts \\ []) do
    with {:ok, connection} <- Providers.ensure_fresh(connection) do
      stream =
        connection.access_token
        |> Client.stream_playlists(connection.provider_user_id, call_opts(connection, opts))
        |> Stream.map(&Mapper.playlist/1)

      {:ok, stream}
    end
  end

  @doc """
  Every track in a playlist, in playlist order, as a lazy stream of
  `OnePlaylist.Music.Track`.
  """
  @spec stream_tracks(Connection.t(), String.t() | Playlist.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Errata.error()}
  def stream_tracks(connection, playlist, opts \\ [])

  def stream_tracks(%Connection{} = connection, %Playlist{provider_id: id}, opts),
    do: stream_tracks(connection, id, opts)

  def stream_tracks(%Connection{} = connection, playlist_id, opts) when is_binary(playlist_id) do
    with {:ok, connection} <- Providers.ensure_fresh(connection) do
      {:ok,
       Client.stream_playlist_tracks(
         connection.access_token,
         playlist_id,
         call_opts(connection, opts)
       )}
    end
  end

  @doc "The connected TIDAL account, useful as a liveness check."
  @spec whoami(Connection.t()) :: {:ok, map()} | {:error, Errata.error()}
  def whoami(%Connection{} = connection) do
    with {:ok, connection} <- Providers.ensure_fresh(connection) do
      Client.current_user(connection.access_token)
    end
  end

  defp call_opts(connection, opts), do: Keyword.put_new(opts, :country, connection.country)
end
