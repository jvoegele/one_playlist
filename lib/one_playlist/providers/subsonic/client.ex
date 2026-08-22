defmodule OnePlaylist.Providers.Subsonic.Client do
  @moduledoc """
  Calls to a Subsonic server — Navidrome, Airsonic, Gonic, or Subsonic itself.

  Takes a `OnePlaylist.Providers.Connection` rather than a token, unlike
  `OnePlaylist.Providers.Tidal.Client`, and the difference is forced: a
  Subsonic call needs the **server's address** as well as the credential, and
  the address lives on the connection because the server is the user's own.

  ## Authentication is per request, and deliberately not a password

  Every call carries `u`, `t` and `s`: the username, an MD5 of the password
  concatenated with a salt, and the salt itself. A fresh salt per request means
  the same credential never produces the same token twice.

  Subsonic also accepts `p=` — the password in the clear, or hex-encoded, which
  is the same thing. This client never sends it. That costs nothing and removes
  a whole class of accident: a password in a proxy log, a `Referer` header, or a
  bug report screenshot.

  > #### What this does not fix {: .warning}
  >
  > Token authentication protects the password in transit *from being read
  > directly*, and nothing more. The token is a plain MD5 with a known salt, so
  > it is offline-crackable, and anyone who captures a request can replay it.
  > The protection that matters is HTTPS, which is the user's to configure on
  > their own server.

  ## Failures arrive as HTTP 200

  The single largest shape difference from every other provider here. A wrong
  password, a missing playlist and a server error all return `200 OK` with
  `status: "failed"` in the body — so this module classifies on the body and
  treats a non-200 as a transport problem rather than as the error. See
  `OnePlaylist.Providers.Subsonic.APIError`.
  """

  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.Subsonic.APIError
  alias OnePlaylist.Providers.Subsonic.Mapper
  alias OnePlaylist.Providers.Subsonic.Service

  use Errata

  # 1.16.1 is where `search3` and the playlist calls settled. Asking for it by
  # name means an older server refuses with code 30 rather than answering
  # something subtly different.
  @api_version "1.16.1"
  @client_name "one_playlist"

  @receive_timeout :timer.seconds(15)
  @pool_timeout :timer.seconds(5)

  @doc """
  The connected account, and proof the credential works.

  `ping` would be cheaper, but it answers `ok` for an *unauthenticated* server
  too — so it cannot tell "the credential is good" from "this server does not
  check". `getUser` requires the credential to be right.
  """
  @spec me(Connection.t()) :: {:ok, map()} | {:error, Errata.error()}
  def me(%Connection{} = connection) do
    with {:ok, body} <- get(connection, "getUser", username: connection.provider_user_id) do
      {:ok, body["user"] || %{}}
    end
  end

  @doc "Every playlist visible to the account."
  @spec playlists(Connection.t()) ::
          {:ok, [OnePlaylist.Music.Playlist.t()]} | {:error, Errata.error()}
  def playlists(%Connection{} = connection) do
    with {:ok, body} <- get(connection, "getPlaylists") do
      {:ok,
       body
       |> get_in(["playlists", "playlist"])
       |> List.wrap()
       |> Enum.map(&Mapper.playlist/1)}
    end
  end

  @doc """
  A playlist's tracks, in order.

  Not paged, and not a stream. Subsonic returns a playlist's entire contents in
  one response — there is no cursor and no `offset` on this call — so the
  laziness `OnePlaylist.Providers.Tidal.Client` needs has nothing to be lazy
  about here.
  """
  @spec playlist_tracks(Connection.t(), String.t()) ::
          {:ok, [OnePlaylist.Music.Track.t()]} | {:error, Errata.error()}
  def playlist_tracks(%Connection{} = connection, playlist_id) do
    with {:ok, body} <- get(connection, "getPlaylist", id: playlist_id) do
      {:ok,
       body
       |> get_in(["playlist", "entry"])
       |> List.wrap()
       |> Enum.map(&Mapper.track/1)}
    end
  end

  @doc """
  Songs matching a free-text query, in the server's relevance order.

  The only way to find anything here: **Subsonic has no ISRC filter**, so
  unlike TIDAL there is no cheap exact lookup and rung 1 of the matching ladder
  has to be served by searching and then comparing. That is the adapter's job,
  not this module's.
  """
  @spec search(Connection.t(), String.t(), keyword()) ::
          {:ok, [OnePlaylist.Music.Track.t()]} | {:error, Errata.error()}
  def search(%Connection{} = connection, query, opts \\ []) do
    params = [
      query: query,
      songCount: Keyword.get(opts, :limit, 20),
      # Asked for explicitly. Without them the server returns its defaults for
      # albums and artists too, which is bandwidth spent on results nothing
      # reads.
      albumCount: 0,
      artistCount: 0
    ]

    with {:ok, body} <- get(connection, "search3", params) do
      {:ok,
       body
       |> get_in(["searchResult3", "song"])
       |> List.wrap()
       |> Enum.map(&Mapper.track/1)}
    end
  end

  @doc """
  Creates a playlist, optionally with tracks already in it.

  Subsonic takes the tracks at creation time, so a transfer's first batch costs
  no extra call — unlike TIDAL, where creating and filling are always separate.
  """
  @spec create_playlist(Connection.t(), String.t(), [String.t()]) ::
          {:ok, OnePlaylist.Music.Playlist.t()} | {:error, Errata.error()}
  def create_playlist(%Connection{} = connection, name, track_ids \\ []) do
    params = [name: name] ++ Enum.map(track_ids, &{:songId, &1})

    with {:ok, body} <- get(connection, "createPlaylist", params) do
      {:ok, Mapper.playlist(body["playlist"] || %{"name" => name})}
    end
  end

  @doc """
  Appends tracks to a playlist.

  Appends without deduplicating, exactly as TIDAL does, so the same
  snapshot-and-diff in `OnePlaylist.Transfers.Runner` is what keeps a re-run
  from duplicating.
  """
  @spec add_tracks(Connection.t(), String.t(), [String.t()]) :: :ok | {:error, Errata.error()}
  def add_tracks(connection, playlist_id, track_ids)

  def add_tracks(%Connection{}, _playlist_id, []), do: :ok

  def add_tracks(%Connection{} = connection, playlist_id, track_ids) do
    params = [playlistId: playlist_id] ++ Enum.map(track_ids, &{:songIdToAdd, &1})

    with {:ok, _body} <- get(connection, "updatePlaylist", params) do
      :ok
    end
  end

  @doc "Deletes a playlist. Present for tests and for cleaning up after them."
  @spec delete_playlist(Connection.t(), String.t()) :: :ok | {:error, Errata.error()}
  def delete_playlist(%Connection{} = connection, playlist_id) do
    with {:ok, _body} <- get(connection, "deletePlaylist", id: playlist_id) do
      :ok
    end
  end

  @doc """
  The authentication parameters for one request.

  Public because it is the part worth testing directly: that `p` is never sent,
  and that the token is `md5(password <> salt)` with a salt that changes.
  """
  @spec auth_params(Connection.t()) :: keyword()
  def auth_params(%Connection{} = connection) do
    salt = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    token =
      :md5 |> :crypto.hash("#{connection.access_token}#{salt}") |> Base.encode16(case: :lower)

    [
      u: connection.provider_user_id,
      t: token,
      s: salt,
      v: @api_version,
      c: @client_name,
      f: "json"
    ]
  end

  defp get(%Connection{} = connection, endpoint, params \\ []) do
    # The query string is built here and passed in the URL rather than through
    # Req's `:params`, and that is not a style choice.
    #
    # `Req.Steps.put_params/2` merges with `List.keystore/4`, which **replaces**
    # a parameter of the same name. Subsonic's whole vocabulary for collections
    # is the repeated parameter — `songId=a&songId=b`, `songIdToAdd=…` — so a
    # six-track append arrived as a one-track append. Nothing failed: the server
    # answered `ok`, the adapter reported six added because it counted what it
    # was given, and five tracks were silently dropped.
    #
    # `URI.encode_query/1` keeps duplicates, because it encodes a list rather
    # than merging one.
    query = URI.encode_query(auth_params(connection) ++ params)

    Service.call(fn ->
      [
        url: "#{base_url(connection)}/rest/#{endpoint}?#{query}",
        method: :get,
        receive_timeout: @receive_timeout,
        finch: [pool_timeout: @pool_timeout],
        # Same reason as everywhere else: ExternalService owns retrying, and Req
        # retrying underneath it is invisible to the breaker.
        retry: false
      ]
      |> Keyword.merge(req_options())
      |> Req.new()
      |> Req.request()
      |> classify()
    end)
  end

  # A Subsonic server answers 200 for its own failures, so the status line only
  # tells us whether we reached the server at all. The body is the authority.
  defp classify({:ok, %{status: 200, body: %{"subsonic-response" => response}}}) do
    case response do
      %{"status" => "ok"} ->
        {:ok, response}

      %{"error" => %{"code" => code} = error} ->
        reason = APIError.reason_for(code)

        result =
          Errata.create(APIError,
            reason: reason,
            context: %{provider: :navidrome, subsonic_code: code, detail: error["message"]}
          )

        # An unauthorized call is not worth repeating: the credential will not
        # have become correct, and on a self-hosted server repeated failures can
        # lock a user out of their own music.
        if Errata.retryable?(result), do: {:retry, result}, else: {:error, result}

      _unrecognised ->
        {:error, api_error(:unexpected, "the server did not answer in Subsonic's format")}
    end
  end

  # Anything that is not a 200 with a Subsonic envelope never reached the
  # application on the other end — a proxy, a wrong URL, a server that is off.
  defp classify({:ok, %{status: status}}),
    do: {:retry, api_error(:server_error, "the server answered #{status}")}

  defp classify({:error, exception}),
    do: {:retry, api_error(:server_error, Exception.message(exception))}

  defp api_error(reason, detail) do
    Errata.create(APIError, reason: reason, context: %{provider: :navidrome, detail: detail})
  end

  # Trailing slashes are the classic self-hosted footgun: a user pastes
  # `http://pi.local:4533/` and every path becomes `//rest/...`, which some
  # servers answer and others do not.
  defp base_url(%Connection{server_url: url}) when is_binary(url),
    do: String.trim_trailing(url, "/")

  defp req_options,
    do:
      Application.get_env(:one_playlist, OnePlaylist.Providers.Navidrome, [])[:req_options] || []
end
