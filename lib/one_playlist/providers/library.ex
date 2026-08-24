defmodule OnePlaylist.Providers.Library do
  @moduledoc """
  The One Playlist adapter: `OnePlaylist.Providers.Adapter` over this
  application's own library.

  The third implementation of that behaviour, and the one that asked the
  hardest question of it — because unlike TIDAL and Subsonic there is no service
  on the other side. Every call here is a database operation. See
  `docs/reference/domain.md` §5.

  Being an adapter is the whole point rather than a flourish:
  `OnePlaylist.Transfers.Runner` is written entirely against `adapter.*`, so the
  library becomes a transfer source and destination with no pipeline branch for
  it at all. `:file` is the one endpoint that *is* a branch, and it stays one
  because a file is source-only.

  ## Two places the behaviour had to give

  **A connection with no credential.** Every callback takes a
  `%OnePlaylist.Providers.Connection{}`, and a library has nothing to
  authorize against — the row *is* the authorization. `Connection.usable?/1`
  grew a clause rather than this module inventing a token to satisfy it. That is
  the second stretch of that type after Subsonic's password-with-no-expiry, and
  the migration that added `:library` says a third should split the type.

  **A destination that cannot fail to match.** Every other adapter is a
  catalogue: `search_tracks/3` finds what is there and a miss means the track
  cannot be transferred. This one can hold anything, so a miss means *store it*
  — which is what `accept_track/3` and the `:accepts_any_track` capability are
  for, and why an `:unmatched` row is impossible when the library is the
  destination.

  ## What searching means here

  `search_tracks/3` asks "do we already have this recording?", against the
  **shared** store rather than the caller's own rows. That is deduplication
  rather than discovery, and it is why transferring the same playlist twice does
  not double the library. See `OnePlaylist.Library`.
  """

  use Bond, behaviours: [OnePlaylist.Providers.Adapter]
  use Errata

  alias OnePlaylist.Library
  alias OnePlaylist.Library.Playlist, as: LibraryPlaylist
  alias OnePlaylist.Library.Recording
  alias OnePlaylist.Music.Playlist
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers.Adapter
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.ConnectionUnusable

  @impl true
  def provider, do: :library

  @impl true
  # `:artwork` because a recording keeps whatever cover the track arrived with,
  # and it is an ordinary URL needing no credential — unlike Subsonic's.
  def capabilities, do: [:artwork, :accepts_any_track, :remove_tracks, :global_ids]

  @impl true
  def refresh_tokens(_refresh_token) do
    # Unreachable in normal operation, exactly as `Navidrome`'s is:
    # `Connection.needs_refresh?/3` answers `false` for a nil expiry, so nothing
    # ever asks. Implemented to keep the behaviour total.
    {:error,
     Errata.create(ConnectionUnusable,
       reason: :reauth_required,
       context: %{
         provider: :library,
         detail: "the library needs no credential, so there is nothing to refresh"
       }
     )}
  end

  @impl true
  def whoami(%Connection{} = connection), do: {:ok, %{"id" => connection.user_id}}

  @impl true
  def stream_playlists(%Connection{} = connection, _opts) do
    # Eager underneath and honest about it, like `Navidrome`'s: there is no
    # paging to defer, and the stream exists to satisfy the behaviour.
    playlists =
      connection.user_id
      |> Library.playlists()
      |> Enum.map(fn {playlist, count} -> LibraryPlaylist.to_playlist(playlist, count) end)

    {:ok, Stream.map(playlists, & &1)}
  end

  @impl true
  def stream_tracks(connection, playlist, opts)

  def stream_tracks(%Connection{} = connection, %Playlist{provider_id: id}, opts),
    do: stream_tracks(connection, id, opts)

  def stream_tracks(%Connection{} = connection, playlist, _opts) when is_binary(playlist) do
    with {:ok, _found} <- fetch_playlist(connection, playlist) do
      {:ok, Stream.map(Library.tracks(connection.user_id, playlist), & &1)}
    end
  end

  @impl true
  def search_tracks(%Connection{} = _connection, %Track{} = track, opts \\ []) do
    {:ok, Library.search(track, Adapter.limit(opts))}
  end

  @impl true
  def accept_track(%Connection{} = _connection, %Track{} = track, _opts \\ []) do
    {:ok, track |> Library.find_or_create() |> Recording.to_track()}
  end

  @impl true
  def create_playlist(%Connection{} = connection, name, opts \\ []) do
    case Library.create_playlist(connection.user_id, name, opts) do
      {:ok, playlist} -> {:ok, LibraryPlaylist.to_playlist(playlist, 0)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @impl true
  def add_tracks(connection, playlist, tracks, opts \\ [])

  def add_tracks(%Connection{} = connection, %Playlist{provider_id: id}, tracks, opts),
    do: add_tracks(connection, id, tracks, opts)

  def add_tracks(%Connection{} = connection, playlist, tracks, _opts) when is_binary(playlist) do
    with {:ok, _found} <- fetch_playlist(connection, playlist) do
      {:ok, Library.append(connection.user_id, playlist, tracks)}
    end
  end

  @impl true
  def remove_tracks(connection, playlist, tracks, opts \\ [])

  def remove_tracks(%Connection{} = connection, %Playlist{provider_id: id}, tracks, opts),
    do: remove_tracks(connection, id, tracks, opts)

  def remove_tracks(%Connection{} = connection, playlist, tracks, _opts)
      when is_binary(playlist) do
    with {:ok, _found} <- fetch_playlist(connection, playlist) do
      {:ok, Library.remove(playlist, tracks)}
    end
  end

  @impl true
  def playlist_track_ids(connection, playlist, opts \\ [])

  def playlist_track_ids(%Connection{} = connection, %Playlist{provider_id: id}, opts),
    do: playlist_track_ids(connection, id, opts)

  def playlist_track_ids(%Connection{} = connection, playlist, _opts) when is_binary(playlist) do
    with {:ok, _found} <- fetch_playlist(connection, playlist) do
      {:ok, connection.user_id |> Library.tracks(playlist) |> Enum.map(& &1.provider_id)}
    end
  end

  # Every playlist-addressed call goes through this rather than trusting the id
  # it was handed. The id arrives from a `transfers` row, which a user can
  # influence, and `Library.tracks/2` and friends filter by playlist alone — so
  # without this a transfer naming somebody else's playlist id would read and
  # write it. `fetch_playlist/2` is scoped, so it answers `:error` for a
  # playlist belonging to anybody else exactly as it does for one that is gone.
  defp fetch_playlist(%Connection{} = connection, playlist_id) do
    case Library.fetch_playlist(connection.user_id, playlist_id) do
      {:ok, playlist} ->
        {:ok, playlist}

      :error ->
        {:error,
         Errata.create(ConnectionUnusable,
           reason: :reauth_required,
           context: %{
             provider: :library,
             detail: "that playlist is not in your library"
           }
         )}
    end
  end
end
