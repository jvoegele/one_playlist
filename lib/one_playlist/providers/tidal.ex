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

  alias OnePlaylist.Catalogue
  alias OnePlaylist.Music.Barcode
  alias OnePlaylist.Music.Isrc
  alias OnePlaylist.Music.Playlist
  alias OnePlaylist.Music.Track
  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Adapter
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.ConnectionUnusable
  alias OnePlaylist.Providers.Tidal.Client
  alias OnePlaylist.Providers.Tidal.Mapper
  alias OnePlaylist.Providers.Tidal.OAuth

  # TIDAL reports the absence of this as `400 INVALID_RESOURCE_ID`, naming
  # neither scopes nor the parameter it is complaining about — so it is checked
  # rather than discovered.
  @search_scope "search.read"

  @impl true
  def capabilities, do: [:artwork]

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

  @impl true
  def create_playlist(%Connection{} = connection, name, opts \\ []) do
    with {:ok, connection} <- Providers.ensure_fresh(connection) do
      Client.create_playlist(connection.access_token, name, call_opts(connection, opts))
    end
  end

  @impl true
  def add_tracks(connection, playlist, tracks, opts \\ [])

  def add_tracks(%Connection{} = connection, %Playlist{provider_id: id}, tracks, opts),
    do: add_tracks(connection, id, tracks, opts)

  def add_tracks(%Connection{} = connection, playlist, tracks, opts) when is_binary(playlist) do
    ids = Enum.map(tracks, & &1.provider_id)

    with {:ok, connection} <- Providers.ensure_fresh(connection),
         :ok <-
           Client.add_tracks(
             connection.access_token,
             playlist,
             ids,
             call_opts(connection, opts)
           ) do
      # TIDAL answers an append with 200 and no body, so there is nothing to
      # count but what we sent. Reporting `length(ids)` is honest only because
      # the call is all-or-nothing: a partial append would come back as an
      # error, and the caller re-reads the destination before trusting a total.
      {:ok, length(ids)}
    end
  end

  @impl true
  def playlist_track_ids(connection, playlist, opts \\ [])

  def playlist_track_ids(%Connection{} = connection, %Playlist{provider_id: id}, opts),
    do: playlist_track_ids(connection, id, opts)

  def playlist_track_ids(%Connection{} = connection, playlist, opts) when is_binary(playlist) do
    with {:ok, connection} <- Providers.ensure_fresh(connection) do
      Client.playlist_track_ids(connection.access_token, playlist, call_opts(connection, opts))
    end
  end

  # ISRC first, always. It is one request, the results are exact, and it does
  # not need a scope this connection may not have.
  defp candidates(connection, %Track{isrc: isrc} = track, opts) when is_binary(isrc) do
    # `Isrc.normalize/1` because a source can supply any spelling. Roon writes
    # them in lower case and TIDAL rejects that outright, which failed 57 of 58
    # tracks in a real import — every one that *had* an ISRC. Normalising at the
    # parsing boundaries is the real fix; this is the belt to those braces, and
    # it costs one function call on a path that is about to make a request.
    case Isrc.normalize(isrc) do
      nil ->
        # Not an ISRC at all, so there is nothing to look up. Searching by name
        # is strictly better than searching by a malformed identifier.
        text_candidates(connection, track, opts)

      canonical ->
        by_isrc(connection, track, canonical, opts)
    end
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

  # A miss falls back to text, and so does a failure. This is the same shape as
  # the release-position rung above, and it did not used to be.
  #
  # It used to stop on an empty result, on the reasoning that "an ISRC names one
  # recording, so a catalogue without it does not have that recording". **That
  # reasoning is wrong**, and a real import disproved it. An ISRC identifies a
  # recording *as issued on a particular release*, and a reissue is a new issue:
  # the same master gets a new code. Roon exports Eddie Vedder's "Setting Forth"
  # as `USJY50700001`, the 2007 soundtrack. TIDAL has the recording as
  # `USJY51700100`, the 2017 reissue. Asking TIDAL for the first returns nothing
  # at all, and the track was reported "nothing found on the destination" while
  # sitting in the catalogue under a different number. Searching by name finds it
  # first result.
  #
  # The fear behind the old rule — that text search finds a *different* recording
  # and reports it as a match — is real and is defended against, but not here.
  # It is defended by the version veto, the duration conflict and the confidence
  # threshold, which every text candidate goes through. Refusing to look was
  # never what made the answer safe; it only made a findable track unfindable.
  #
  # The cost is one extra call per ISRC that misses, and only for tracks that
  # would otherwise have been reported unmatched.
  defp by_isrc(connection, track, isrc, opts) do
    case Client.tracks_by_isrc(connection.access_token, isrc, opts) do
      {:ok, [_candidate | _rest] = found} -> {:ok, found}
      _miss_or_error -> text_candidates(connection, track, opts)
    end
  end

  # Needs this scope, which a connection authorized before it was
  # requested will not have — checked here because TIDAL reports its absence as
  # `400 INVALID_RESOURCE_ID`, which names neither scopes nor the parameter it
  # is really complaining about.
  defp text_candidates(connection, %Track{} = track, opts) do
    if Connection.grants?(connection, @search_scope) do
      Client.search_tracks(connection.access_token, Track.search_query(track), opts)
    else
      {:error,
       Errata.create(ConnectionUnusable,
         reason: :insufficient_scope,
         context: %{
           provider: :tidal,
           required_scope: @search_scope,
           granted_scopes: connection.scopes
         }
       )}
    end
  end

  defp by_release_position(connection, %Track{} = track, opts) do
    barcode = Barcode.normalize(track.album_upc)
    token = connection.access_token
    lookup_opts = Keyword.put(opts, :barcode, track.album_upc)

    with true <- is_binary(barcode),
         {:ok, album_id} when is_binary(album_id) <-
           Catalogue.album_id(:tidal, barcode, fn ->
             Client.album_by_barcode(token, barcode, opts)
           end),
         {:ok, tracks} <- items_or_forget(token, album_id, barcode, lookup_opts) do
      {:ok, Enum.filter(tracks, &Track.same_position?(&1, track))}
    else
      # A barcode TIDAL does not carry, or a release that lists nothing at that
      # position. Both are misses, not failures.
      _miss -> {:ok, []}
    end
  end

  # A barcode identifies a release permanently, but TIDAL's *id* for that
  # release does not have to be permanent — a re-ingest or a delisting changes
  # it, and the only symptom is a 404 here rather than anything visible when the
  # id was handed over. This is the one place that can tell, so it is the one
  # place that says so.
  defp items_or_forget(token, album_id, barcode, opts) do
    case Client.album_items(token, album_id, opts) do
      {:ok, tracks} ->
        {:ok, tracks}

      {:error, error} = failure ->
        if Errata.reason(error) == :not_found, do: Catalogue.forget(:tidal, barcode)

        failure
    end
  end

  defp limit_to({:ok, tracks}, limit), do: {:ok, Enum.take(tracks, limit)}
  defp limit_to({:error, error}, _limit), do: {:error, error}

  defp call_opts(connection, opts), do: Keyword.put_new(opts, :country, connection.country)
end
