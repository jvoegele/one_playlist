defmodule OnePlaylist.Providers.Navidrome do
  @moduledoc """
  The Navidrome adapter: `OnePlaylist.Providers.Adapter` over the Subsonic API.

  The second implementation of that behaviour, and the one that tests whether
  it described *a music service* or merely *TIDAL*. Mostly it held. The places
  it did not are worth naming, because each is a decision the behaviour now
  carries rather than an accident:

  ## Nothing to refresh

  A Subsonic credential is a username and a password. It does not expire, there
  is no refresh token, and `refresh_tokens/1` has nothing to do.

  It is implemented anyway, returning a typed error, rather than made an
  optional callback. Two reasons. `OnePlaylist.Providers.ensure_fresh/2` never
  reaches it — `Connection.needs_refresh?/3` answers `false` for a nil expiry,
  so a never-expiring connection is simply left alone — which means the error
  is unreachable in normal operation and exists to be explicit rather than to
  be handled. And keeping the behaviour total means "every adapter implements
  every callback" stays a property the test suite can check, instead of
  becoming a list of exceptions.

  ## Rung 1 is a search, not a lookup

  TIDAL has `filter[isrc]`, so an ISRC match is one request returning exact
  candidates. **Subsonic has no ISRC filter at all** — `search3` takes text and
  nothing else. So `search_tracks/3` always searches by text, and the ISRC rung
  fires (or does not) on whatever comes back.

  That is a real quality difference rather than an implementation detail: on
  TIDAL an ISRC match is guaranteed to be found if it exists, while here it is
  found only if the text search surfaced it. Asking for more candidates than
  TIDAL needs is the cheap mitigation, and it is cheap precisely because this
  server belongs to the user.

  ## The library usually has no ISRCs

  A self-hosted library is tagged by whoever ripped it, and most tags carry no
  ISRC. This is therefore the first provider where the text and fuzzy rungs
  carry the *majority* of matches rather than the remainder — which is why
  `dev/navidrome/generate_library.py` can build a library without them.
  """

  use Bond, behaviours: [OnePlaylist.Providers.Adapter]
  use Errata

  alias OnePlaylist.Music.Playlist
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers.Adapter
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.ConnectionUnusable
  alias OnePlaylist.Providers.Subsonic.Client

  # More than TIDAL's default, because rung 1 depends on the text search
  # surfacing the right recording rather than on a filter guaranteeing it — and
  # because these requests cost the user's own server rather than a quota.
  @search_candidates 25

  @impl true
  def provider, do: :navidrome

  @impl true
  # No `:artwork`. Subsonic *has* cover art, but `getCoverArt` wants the
  # credentials on the request, so its URL cannot go in an `img` tag without
  # putting a token in the page. That needs a proxy route before this can
  # honestly claim it.
  def capabilities, do: [:remove_tracks]

  @impl true
  def refresh_tokens(_refresh_token) do
    {:error,
     Errata.create(ConnectionUnusable,
       reason: :reauth_required,
       context: %{
         provider: :navidrome,
         detail:
           "a Subsonic credential is a username and password; there is nothing to refresh, " <>
             "so a connection that stops working has to be re-entered"
       }
     )}
  end

  @impl true
  def whoami(%Connection{} = connection), do: Client.me(connection)

  @impl true
  def stream_playlists(%Connection{} = connection, _opts) do
    # Eager underneath, and honest about it. `getPlaylists` has no paging, so
    # there is nothing to be lazy about — the stream exists to satisfy the
    # behaviour, not to defer work that could be deferred.
    with {:ok, playlists} <- Client.playlists(connection) do
      {:ok, Stream.map(playlists, & &1)}
    end
  end

  @impl true
  def stream_tracks(connection, playlist, opts)

  def stream_tracks(%Connection{} = connection, %Playlist{provider_id: id}, opts),
    do: stream_tracks(connection, id, opts)

  def stream_tracks(%Connection{} = connection, playlist, _opts) when is_binary(playlist) do
    with {:ok, tracks} <- Client.playlist_tracks(connection, playlist) do
      {:ok, Stream.map(tracks, & &1)}
    end
  end

  @impl true
  def search_tracks(%Connection{} = connection, %Track{} = track, opts \\ []) do
    limit = Adapter.limit(opts)

    with {:ok, candidates} <-
           Client.search(connection, Track.search_query(track), limit: @search_candidates) do
      {:ok, Enum.take(candidates, limit)}
    end
  end

  @impl true
  def accept_track(%Connection{} = _connection, %Track{} = track, _opts \\ []) do
    # A catalogue holds what it holds. Declared as unsupported by
    # `capabilities/0` rather than left optional, so the behaviour stays total.
    {:error,
     Errata.create(ConnectionUnusable,
       reason: :reauth_required,
       context: %{
         provider: :navidrome,
         detail:
           "Navidrome carries a fixed catalogue, so a recording it does not have " <>
             "cannot be added to it — only found or not found",
         track: track.provider_id
       }
     )}
  end

  @impl true
  def create_playlist(%Connection{} = connection, name, _opts \\ []) do
    Client.create_playlist(connection, name, [])
  end

  @impl true
  def add_tracks(connection, playlist, tracks, opts \\ [])

  def add_tracks(%Connection{} = connection, %Playlist{provider_id: id}, tracks, opts),
    do: add_tracks(connection, id, tracks, opts)

  def add_tracks(%Connection{} = connection, playlist, tracks, _opts) when is_binary(playlist) do
    ids = Enum.map(tracks, & &1.provider_id)

    with :ok <- Client.add_tracks(connection, playlist, ids) do
      {:ok, length(ids)}
    end
  end

  @impl true
  def remove_tracks(connection, playlist, tracks, opts \\ [])

  def remove_tracks(%Connection{} = connection, %Playlist{provider_id: id}, tracks, opts),
    do: remove_tracks(connection, id, tracks, opts)

  def remove_tracks(%Connection{} = connection, playlist, tracks, _opts)
      when is_binary(playlist) do
    wanted = MapSet.new(tracks, & &1.provider_id)

    with {:ok, entries} <- Client.playlist_tracks(connection, playlist) do
      # Subsonic names an entry by its position and by nothing else, so the read
      # is not an optimisation to be skipped — there is no id to send. The
      # indexes are zero-based and are read by the server against the list as it
      # is here, so several may go in one call without each removal shifting the
      # ones after it. Verified against Navidrome 0.58.0 on 2026-08-24: removing
      # 0 and 2 from four entries left exactly the second and fourth.
      doomed =
        entries
        |> Enum.with_index()
        |> Enum.filter(fn {track, _index} -> track.provider_id in wanted end)
        |> Enum.map(fn {_track, index} -> index end)

      with :ok <- Client.remove_by_index(connection, playlist, doomed) do
        {:ok, length(doomed)}
      end
    end
  end

  @impl true
  def playlist_track_ids(connection, playlist, opts \\ [])

  def playlist_track_ids(%Connection{} = connection, %Playlist{provider_id: id}, opts),
    do: playlist_track_ids(connection, id, opts)

  def playlist_track_ids(%Connection{} = connection, playlist, _opts) when is_binary(playlist) do
    with {:ok, tracks} <- Client.playlist_tracks(connection, playlist) do
      {:ok, Enum.map(tracks, & &1.provider_id)}
    end
  end
end
