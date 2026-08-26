defmodule OnePlaylist.Providers.Spotify do
  @moduledoc """
  The Spotify adapter: `OnePlaylist.Providers.Adapter` for Spotify.

  The layer that joins a stored `OnePlaylist.Providers.Connection` to the
  modules beneath it — `Client` for API calls, `OAuth` for tokens, `Mapper` for
  shapes. Everything here takes a connection and returns `OnePlaylist.Music`
  structs; the client below takes an access token and returns Spotify's JSON.

  Every read refreshes the connection first via
  `OnePlaylist.Providers.ensure_fresh/2`, which is a no-op when the token has
  time left. A caller reading a large library over several minutes therefore
  cannot have its token expire mid-read — and Spotify's access tokens last one
  hour, so that is not a theoretical concern for a bulk transfer.

  Contracts on `refresh_tokens/1` and the rest are inherited from the
  behaviour — there is no contract code in this module, and every other adapter
  gets the same ones.

  ## What Development Mode means for this adapter

  A Spotify application that has not been granted extended quota serves only the
  accounts allowlisted in its dashboard. Nothing here can detect that in
  advance: the refusal arrives as a 403 at the first real call, which is why
  `Client` bothers to tell it apart from a scope problem and
  `OnePlaylist.Providers.Spotify.APIError` gives it its own display message. A
  user seeing "reconnect to continue" for a problem no reconnection can fix is
  the outcome that distinction exists to prevent.

  ## `market` where TIDAL has `country`

  Same idea, different name and slightly different force. Spotify's `market`
  decides which recordings are visible and, given one, *relinks* a track to the
  copy playable in that market. Omitting it can hide a recording the account can
  actually play — so it is carried down from the connection on every call,
  exactly as TIDAL's `countryCode` is.
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
  alias OnePlaylist.Providers.Spotify.Client
  alias OnePlaylist.Providers.Spotify.OAuth

  @impl true
  # `:artwork` because album images ride along on every track object, free of an
  # extra request — which is the qualifier that matters, see `Adapter`.
  #
  # `:global_ids` because a Spotify track id means the same thing to every
  # Spotify account, so a Spotify → Spotify transfer copies ids across without
  # searching. Two Subsonic connections cannot claim this and that is the
  # distinction the capability exists for.
  def capabilities, do: [:artwork, :remove_tracks, :global_ids]

  @impl true
  def provider, do: :spotify

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
      {:ok,
       Client.stream_playlists(
         connection.access_token,
         connection.provider_user_id,
         call_opts(connection, opts)
       )}
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
  def accept_track(%Connection{} = _connection, %Track{} = track, _opts \\ []) do
    # A catalogue holds what it holds. Declared as unsupported by
    # `capabilities/0` rather than left optional, so the behaviour stays total.
    {:error,
     Errata.create(ConnectionUnusable,
       reason: :reauth_required,
       context: %{
         provider: :spotify,
         detail:
           "Spotify carries a fixed catalogue, so a recording it does not have " <>
             "cannot be added to it — only found or not found",
         track: track.provider_id
       }
     )}
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
         {:ok, _snapshot} <-
           Client.add_tracks(
             connection.access_token,
             playlist,
             ids,
             call_opts(connection, opts)
           ) do
      # Spotify answers an append with a snapshot id and no count, so there is
      # nothing to count but what we sent. Reporting `length(ids)` is honest
      # only because the call is all-or-nothing per batch: a partial append
      # comes back as an error, and the caller re-reads the destination before
      # trusting a total.
      {:ok, length(ids)}
    end
  end

  @impl true
  def remove_tracks(connection, playlist, tracks, opts \\ [])

  def remove_tracks(%Connection{} = connection, %Playlist{provider_id: id}, tracks, opts),
    do: remove_tracks(connection, id, tracks, opts)

  def remove_tracks(%Connection{} = connection, playlist, tracks, opts)
      when is_binary(playlist) do
    # `uniq` because Spotify removes every occurrence of a URI it is given, so
    # naming one twice would ask for a removal that has already happened and
    # count it twice. The behaviour's `nothing_asked_removes_nothing` is what
    # makes the empty case load-bearing, and `Client` short-circuits it.
    ids = tracks |> Enum.map(& &1.provider_id) |> Enum.uniq()

    with {:ok, connection} <- Providers.ensure_fresh(connection),
         {:ok, held} <-
           Client.playlist_track_ids(
             connection.access_token,
             playlist,
             call_opts(connection, opts)
           ) do
      wanted = MapSet.new(ids)
      doomed = held |> Enum.filter(&MapSet.member?(wanted, &1)) |> Enum.uniq()

      remove_present(connection, playlist, doomed, opts)
    end
  end

  defp remove_present(_connection, _playlist, [], _opts), do: {:ok, 0}

  # Counted by **re-reading**, not by trusting the response.
  #
  # That is a request this adapter would rather not spend, and it is spent
  # because Spotify has been shown to answer `200 OK` to a removal it did not
  # perform — see `Client.remove_tracks/4` on the `snapshot_id` measurement. The
  # bug that produced it is fixed, but what the measurement established is more
  # general and did not go away with it: a 200 from this endpoint is not
  # evidence that anything was removed.
  #
  # So the count is a difference rather than an intention, and a removal that
  # silently does nothing reports zero rather than reporting what it meant to
  # do. `OnePlaylist.Transfers.Runner` writes that number into a report a person
  # reads, and a report that is confidently wrong is the one failure mode this
  # application is organised against.
  defp remove_present(connection, playlist, doomed, opts) do
    wanted = MapSet.new(doomed)
    call_opts = call_opts(connection, opts)
    token = connection.access_token

    with {:ok, before} <- Client.playlist_track_ids(token, playlist, call_opts),
         {:ok, _snapshot} <- Client.remove_tracks(token, playlist, doomed, call_opts),
         {:ok, left} <- Client.playlist_track_ids(token, playlist, call_opts) do
      {:ok, occurrences(before, wanted) - occurrences(left, wanted)}
    end
  end

  defp occurrences(ids, wanted), do: Enum.count(ids, &MapSet.member?(wanted, &1))

  @impl true
  def playlist_track_ids(connection, playlist, opts \\ [])

  def playlist_track_ids(%Connection{} = connection, %Playlist{provider_id: id}, opts),
    do: playlist_track_ids(connection, id, opts)

  def playlist_track_ids(%Connection{} = connection, playlist, opts) when is_binary(playlist) do
    with {:ok, connection} <- Providers.ensure_fresh(connection) do
      Client.playlist_track_ids(connection.access_token, playlist, call_opts(connection, opts))
    end
  end

  # ISRC first, always. It is one request and the results are exact enough to
  # rank above text, though see `Client.tracks_by_isrc/3` on why "exact" is
  # weaker here than at TIDAL: Spotify matches ISRC through its *search* index
  # rather than by lookup.
  defp candidates(connection, %Track{isrc: isrc} = track, opts) when is_binary(isrc) do
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
  # Note which sources can reach this rung against Spotify. A *Spotify* source
  # cannot supply the barcode — see `Spotify.Mapper` — so this fires for tracks
  # that came from a file import, from MusicBrainz enrichment, or from the
  # library, which is where most barcodes in this application come from anyway.
  defp candidates(connection, %Track{album_upc: upc, track_number: number} = track, opts)
       when is_binary(upc) and is_integer(number) do
    case by_release_position(connection, track, opts) do
      {:ok, [_candidate | _rest] = found} -> {:ok, found}
      _miss_or_error -> text_candidates(connection, track, opts)
    end
  end

  defp candidates(connection, %Track{} = track, opts),
    do: text_candidates(connection, track, opts)

  # A miss falls back to text, and so does a failure.
  #
  # The tempting alternative is to stop on an empty result, reasoning that "an
  # ISRC names one recording, so a catalogue without it does not have that
  # recording". That reasoning is wrong: an ISRC identifies a recording *as
  # issued on a particular release*, and a reissue is a new issue with a new
  # code. See `OnePlaylist.MusicBrainz` for the case that demonstrates it.
  #
  # It is wronger here than at TIDAL, because Spotify's `isrc:` is a search
  # operator rather than a lookup: a code the catalogue holds can simply fail to
  # match the index. Stopping on that would report a findable track unmatched.
  defp by_isrc(connection, track, isrc, opts) do
    case Client.tracks_by_isrc(connection.access_token, isrc, opts) do
      {:ok, [_candidate | _rest] = found} -> {:ok, found}
      _miss_or_error -> text_candidates(connection, track, opts)
    end
  end

  # No scope check, unlike TIDAL's. Spotify's search endpoint needs no scope at
  # all — it is part of the base grant — so there is no equivalent of TIDAL's
  # `search.read` to be missing, and a connection made before this adapter
  # existed cannot be short of it.
  defp text_candidates(connection, %Track{} = track, opts),
    do: Client.search_tracks(connection.access_token, Track.search_query(track), opts)

  defp by_release_position(connection, %Track{} = track, opts) do
    barcode = Barcode.normalize(track.album_upc)
    token = connection.access_token

    with true <- is_binary(barcode),
         {:ok, album_id} when is_binary(album_id) <-
           Catalogue.album_id(:spotify, barcode, fn ->
             Client.album_by_barcode(token, barcode, opts)
           end),
         {:ok, tracks} <- items_or_forget(token, album_id, barcode, opts) do
      {:ok, Enum.filter(tracks, &Track.same_position?(&1, track))}
    else
      # A barcode Spotify does not carry, or a release that lists nothing at
      # that position. Both are misses, not failures.
      _miss -> {:ok, []}
    end
  end

  # A barcode identifies a release permanently, but Spotify's *id* for that
  # release does not have to be permanent — a re-ingest or a delisting changes
  # it, and the only symptom is a 404 here rather than anything visible when the
  # id was handed over. This is the one place that can tell, so it is the one
  # place that says so.
  defp items_or_forget(token, album_id, barcode, opts) do
    case Client.album_items(token, album_id, opts) do
      {:ok, tracks} ->
        {:ok, tracks}

      {:error, error} = failure ->
        if Errata.reason(error) == :not_found, do: Catalogue.forget(:spotify, barcode)

        failure
    end
  end

  defp limit_to({:ok, tracks}, limit), do: {:ok, Enum.take(tracks, limit)}
  defp limit_to({:error, error}, _limit), do: {:error, error}

  defp call_opts(connection, opts), do: Keyword.put_new(opts, :market, connection.country)
end
