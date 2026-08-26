defmodule OnePlaylist.Providers.Spotify.Client do
  @moduledoc """
  HTTP against the Spotify Web API.

  Takes an access token and returns Spotify's JSON, or an
  `OnePlaylist.Providers.Spotify.APIError`. Knows nothing about how tokens are
  stored or refreshed — that is `OnePlaylist.Providers.Spotify`'s job, one layer
  up.

  Every call goes through `OnePlaylist.Providers.Spotify.Service`, so retries,
  the circuit breaker, the rate limiter and the concurrency bulkhead are already
  applied and this module can be written as if the network were reliable.

  ## Pagination is offset-based, not cursored

  TIDAL pages by opaque cursor; Spotify pages by `limit` and `offset` and hands
  back a fully-formed `next` URL. The `next` URL is what is followed, rather
  than incrementing an offset locally: the two agree until they do not, and when
  they disagree Spotify is right.

  A `next` that pointed back at the page just fetched would spin forever, and a
  background job would spin with it — so a repeated URL is treated as the end
  rather than trusted, the same defence `Tidal.Client` applies to its cursors.

  ## `Retry-After` is honoured explicitly

  Spotify's rate limit is a rolling window sized to the *application*, and a 429
  carries a `Retry-After` in seconds. `ExternalService` owns the retry schedule,
  but its exponential backoff knows nothing about a number the service just
  told us — so a 429 sleeps for what was asked before handing back `:retry`,
  and the backoff then applies on top.

  Sleeping inside the guarded function is deliberate: it holds this call's
  concurrency slot for the duration, which is exactly right. The window is
  shared, so a slot released early would only let another call spend the quota
  that is already exhausted.

  `@max_retry_after` bounds it. A service asking us to wait ten minutes is
  asking for something a transfer job should refuse — better to fail the run and
  let Oban reschedule it than to hold a worker and a connection open.
  """

  alias OnePlaylist.Providers.Spotify
  alias OnePlaylist.Providers.Spotify.APIError
  alias OnePlaylist.Providers.Spotify.Mapper
  alias OnePlaylist.Providers.Spotify.Service

  use Errata

  require Logger

  @receive_timeout :timer.seconds(10)
  @pool_timeout :timer.seconds(5)

  # Spotify's own maxima, and exceeding either is a 400 rather than a clamp.
  @playlist_page 50
  @items_page 100
  @write_batch 100

  # Beyond this a 429 is a failed run rather than a wait. See the moduledoc.
  @max_retry_after 60

  @doc "The authorizing account. `country` needs the `user-read-private` scope."
  @spec current_user(String.t()) :: {:ok, map()} | {:error, Errata.error()}
  def current_user(access_token), do: get(access_token, "/me")

  @doc "One page of the user's playlists."
  @spec list_playlists(String.t(), keyword()) :: {:ok, map()} | {:error, Errata.error()}
  def list_playlists(access_token, opts \\ []) do
    page(access_token, "/me/playlists", [{"limit", @playlist_page}], opts)
  end

  @doc "One page of a playlist's items."
  @spec list_playlist_items(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Errata.error()}
  def list_playlist_items(access_token, playlist_id, opts \\ []) do
    page(
      access_token,
      "/playlists/#{playlist_id}/tracks",
      [{"limit", @items_page}] ++ market_param(opts),
      opts
    )
  end

  # A page is either the first — our path, our parameters — or a `next` link,
  # which is an absolute URL with every parameter already baked into it. Sending
  # ours alongside one would duplicate `market` and `limit` on every page after
  # the first, so the two cases share nothing but the request itself.
  defp page(access_token, path, params, opts) do
    case Keyword.get(opts, :next) do
      nil -> request(access_token, method: :get, url: api_url() <> path, params: params)
      next -> request(access_token, method: :get, url: next)
    end
  end

  @doc """
  Every playlist the user has, as a lazy stream.

  `spotify_user_id` is the connected account, and it is what lets each playlist
  say whether the user *owns* it or merely follows it — see `Mapper.playlist/2`.
  """
  @spec stream_playlists(String.t(), String.t() | nil, keyword()) :: Enumerable.t()
  def stream_playlists(access_token, spotify_user_id \\ nil, opts \\ []) do
    opts
    |> Keyword.put(
      :map_page,
      &Enum.map(&1["items"] || [], fn p -> Mapper.playlist(p, spotify_user_id) end)
    )
    |> paginate(fn page_opts -> list_playlists(access_token, page_opts) end)
  end

  @doc "Every track in a playlist, in order, as a lazy stream."
  @spec stream_playlist_tracks(String.t(), String.t(), keyword()) :: Enumerable.t()
  def stream_playlist_tracks(access_token, playlist_id, opts \\ []) do
    opts
    |> Keyword.put(:map_page, &Mapper.tracks/1)
    |> paginate(fn page_opts -> list_playlist_items(access_token, playlist_id, page_opts) end)
  end

  @doc """
  The provider ids of everything in a playlist, in order and with duplicates.

  The snapshot an idempotent transfer diffs against.
  """
  @spec playlist_track_ids(String.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, Errata.error()}
  def playlist_track_ids(access_token, playlist_id, opts \\ []) do
    ids =
      opts
      |> Keyword.put(:map_page, &Mapper.track_ids/1)
      |> paginate(fn page_opts -> list_playlist_items(access_token, playlist_id, page_opts) end)
      |> Enum.to_list()

    {:ok, ids}
  rescue
    error in [APIError, ExternalService.RetriesExhausted] -> {:error, error}
  end

  @doc """
  Tracks carrying an ISRC.

  Spotify has no ISRC filter endpoint; it has an ISRC *search operator*, which
  is a different thing and behaves like one. `q=isrc:CODE` is matched against
  the search index rather than looked up, so it can return nothing for a code
  the catalogue genuinely holds, and it occasionally returns more than one
  recording. Both are why this feeds the matching ladder as candidates rather
  than being trusted as an answer.
  """
  @spec tracks_by_isrc(String.t(), String.t(), keyword()) ::
          {:ok, [OnePlaylist.Music.Track.t()]} | {:error, Errata.error()}
  def tracks_by_isrc(access_token, isrc, opts \\ []) do
    with {:ok, body} <- search(access_token, "isrc:#{isrc}", "track", opts) do
      {:ok, Mapper.tracks_from_search(body)}
    end
  end

  @doc "Tracks matching free text."
  @spec search_tracks(String.t(), String.t(), keyword()) ::
          {:ok, [OnePlaylist.Music.Track.t()]} | {:error, Errata.error()}
  def search_tracks(access_token, query, opts \\ []) do
    with {:ok, body} <- search(access_token, query, "track", opts) do
      {:ok, Mapper.tracks_from_search(body)}
    end
  end

  @doc """
  The id of the album carrying a barcode, or `nil`.

  `upc:` is a search operator like `isrc:` above, with the same caveat: a miss
  is not proof the release is absent.
  """
  @spec album_by_barcode(String.t(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, Errata.error()}
  def album_by_barcode(access_token, barcode, opts \\ []) do
    with {:ok, body} <- search(access_token, "upc:#{barcode}", "album", opts) do
      {:ok, body |> get_in(["albums", "items"]) |> List.wrap() |> List.first() |> album_id()}
    end
  end

  @doc """
  An album's tracks, carrying the album's barcode down onto each.

  The only Spotify response with a UPC in it — see
  `OnePlaylist.Providers.Spotify.Mapper`.
  """
  @spec album_items(String.t(), String.t(), keyword()) ::
          {:ok, [OnePlaylist.Music.Track.t()]} | {:error, Errata.error()}
  def album_items(access_token, album_id, opts \\ []) do
    with {:ok, body} <- get(access_token, "/albums/#{album_id}", market_param(opts)) do
      {:ok, Mapper.tracks_from_album(body)}
    end
  end

  @doc """
  Creates a private playlist owned by the authorizing user.

  The user id goes in the path — Spotify has no "current user" form of this
  endpoint — so callers must supply it, which is why
  `OnePlaylist.Providers.Connection.provider_user_id` is captured at connect.

  Private by default. A transfer tool that published somebody's playlists to
  their followers by omission would be a bad surprise, and `public: false` is
  the explicit way of saying so — Spotify's own default is `true`.
  """
  @spec create_playlist(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, OnePlaylist.Music.Playlist.t()} | {:error, Errata.error()}
  def create_playlist(access_token, spotify_user_id, name, opts \\ []) do
    body =
      %{"name" => name, "public" => false}
      |> maybe_put("description", Keyword.get(opts, :description))

    with {:ok, resource} <-
           write(access_token, :post, "/users/#{spotify_user_id}/playlists", body, []) do
      {:ok, Mapper.playlist(resource)}
    end
  end

  @doc """
  Appends tracks to a playlist, in batches of #{@write_batch}.

  Answers the last `snapshot_id` Spotify returned. A snapshot names the playlist
  as it stood after a change, and `remove_tracks/4` can pass one back so that a
  removal computed against a stale view is refused rather than applied to the
  wrong entries.
  """
  @spec add_tracks(String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, String.t() | nil} | {:error, Errata.error()}
  def add_tracks(access_token, playlist_id, track_ids, opts \\ [])

  def add_tracks(_access_token, _playlist_id, [], _opts), do: {:ok, nil}

  def add_tracks(access_token, playlist_id, track_ids, opts) do
    track_ids
    |> Enum.chunk_every(@write_batch)
    |> Enum.reduce_while({:ok, nil}, fn batch, {:ok, _snapshot} ->
      body = %{"uris" => Enum.map(batch, &track_uri/1)}

      case write(access_token, :post, "/playlists/#{playlist_id}/tracks", body, opts) do
        {:ok, response} -> {:cont, {:ok, response["snapshot_id"]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Removes tracks from a playlist, in batches of #{@write_batch}.

  ## Every occurrence, and that is Spotify's own default

  A removal naming only `uri` takes out **every** occurrence of that track.
  Spotify also accepts a `positions` array to remove particular copies, and it
  is deliberately not used: `c:OnePlaylist.Providers.Adapter.remove_tracks/4` is
  specified as removing every occurrence, which is what makes calling it twice
  harmless, and positions would be computed against a playlist that may have
  moved.

  This is the third removal model this application speaks, and none of the three
  resemble each other — TIDAL needs a track id *and* an item id, Subsonic needs
  a zero-based index and no id at all, and Spotify takes a URI. That the adapter
  boundary absorbs all three without the caller knowing is the point of it.

  ## The snapshot is optimistic concurrency, and is passed when known

  `snapshot_id` names the playlist state a removal was computed against. Given
  one, Spotify refuses the removal if the playlist has changed underneath — the
  one protection available against a concurrent edit, and free to use.
  """
  @spec remove_tracks(String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, String.t() | nil} | {:error, Errata.error()}
  def remove_tracks(access_token, playlist_id, track_ids, opts \\ [])

  def remove_tracks(_access_token, _playlist_id, [], _opts), do: {:ok, nil}

  def remove_tracks(access_token, playlist_id, track_ids, opts) do
    track_ids
    |> Enum.chunk_every(@write_batch)
    |> Enum.reduce_while({:ok, Keyword.get(opts, :snapshot_id)}, fn batch, {:ok, snapshot} ->
      body =
        %{"tracks" => Enum.map(batch, &%{"uri" => track_uri(&1)})}
        |> maybe_put("snapshot_id", snapshot)

      case write(access_token, :delete, "/playlists/#{playlist_id}/tracks", body, opts) do
        # Carried forward, so each batch is checked against the state the
        # previous batch produced rather than against the one this started with.
        {:ok, response} -> {:cont, {:ok, response["snapshot_id"]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  The current snapshot id of a playlist.

  One cheap request — `fields` narrows the response to the single value, so this
  does not drag a thousand tracks back to learn one string.
  """
  @spec playlist_snapshot(String.t(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, Errata.error()}
  def playlist_snapshot(access_token, playlist_id, _opts \\ []) do
    with {:ok, body} <-
           get(access_token, "/playlists/#{playlist_id}", [{"fields", "snapshot_id"}]) do
      {:ok, body["snapshot_id"]}
    end
  end

  defp search(access_token, query, type, opts) do
    params =
      [{"q", query}, {"type", type}, {"limit", Keyword.get(opts, :limit, 20)}] ++
        market_param(opts)

    get(access_token, "/search", params)
  end

  defp album_id(%{"id" => id}) when is_binary(id), do: id
  defp album_id(_absent), do: nil

  # A track id is not a URI, and Spotify's write endpoints take the URI form.
  # Built here rather than stored, because everything else in this application —
  # the report, the identity spine, the diff — keys on the bare id.
  defp track_uri(id), do: "spotify:track:#{id}"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # One pagination loop for every offset-paged endpoint. `fetch` returns the raw
  # page; the caller decides what a page's items are.
  defp paginate(opts, fetch) do
    {mapper, opts} = Keyword.pop(opts, :map_page, & &1["items"])

    Stream.resource(
      fn -> {:start, nil} end,
      fn
        :halt ->
          {:halt, nil}

        {_previous, next_url} = acc ->
          page_opts = if next_url, do: Keyword.put(opts, :next, next_url), else: opts

          case fetch.(page_opts) do
            {:ok, page} -> {List.wrap(mapper.(page)), advance(acc, page["next"])}
            {:error, error} -> raise error
          end
      end,
      fn _ -> :ok end
    )
  end

  # Termination is decided by the remote service, which is a poor place to leave
  # it. A repeated `next` is treated as the end rather than trusted.
  defp advance(_acc, nil), do: :halt
  defp advance({_previous, url}, url), do: :halt
  defp advance({_previous, url}, next), do: {url, next}

  # Spotify returns different catalogue availability per market, and omitting it
  # can hide a track the account can actually play. The value belongs to the
  # connected account, so callers pass it down from the connection.
  defp market_param(opts) do
    case Keyword.get(opts, :market) do
      nil -> []
      market -> [{"market", market}]
    end
  end

  # Writes never follow a `next` link, so there is no absolute-URL case here.
  defp write(access_token, method, path, body, _opts) do
    request(access_token, method: method, url: api_url() <> path, json: body)
  end

  defp get(access_token, path, params \\ []) do
    request(access_token, method: :get, url: api_url() <> path, params: params)
  end

  defp request(access_token, options) do
    Service.call(fn ->
      [
        auth: {:bearer, access_token},
        headers: [{"accept", "application/json"}],
        receive_timeout: @receive_timeout,
        finch: [pool_timeout: @pool_timeout],
        # Req retries 408/429/5xx three times with its own backoff by default.
        # Left on, every guarded call would retry 3× *inside* each
        # ExternalService attempt — twelve requests where four were configured,
        # with a backoff nothing here can see or tune, and Req's own scheduling
        # would ignore the `Retry-After` this module honours below.
        # ExternalService owns retrying; Req must not.
        retry: false
      ]
      |> Keyword.merge(options)
      |> Keyword.merge(req_options())
      |> Req.new()
      |> Req.request()
      |> classify()
    end)
  end

  # The mapping from HTTP status to "should this be attempted again".
  #
  # 401 is *not* retried. A token does not become valid by asking twice, and
  # retrying would melt the circuit breaker on what is really one user's expired
  # connection — degrading Spotify access for everybody else.
  defp classify({:ok, %{status: status, body: body}}) when status in 200..299, do: {:ok, body}

  defp classify({:ok, %{status: 401, body: body}}), do: {:error, api_error(:unauthorized, body)}

  # Development Mode's refusal and an ordinary scope refusal are both 403 and
  # are told apart only by the message. See `Spotify.APIError` for why the
  # distinction is worth making.
  defp classify({:ok, %{status: 403, body: body}}) do
    if development_mode_refusal?(body) do
      {:error, api_error(:not_allowlisted, body)}
    else
      {:error, api_error(:forbidden, body)}
    end
  end

  defp classify({:ok, %{status: 404, body: body}}), do: {:error, api_error(:not_found, body)}

  defp classify({:ok, %{status: 429} = response}) do
    wait = retry_after(response)

    cond do
      is_nil(wait) ->
        {:retry, api_error(:rate_limited, response.body)}

      wait > @max_retry_after ->
        # Longer than a job should hold a worker for. Reported as a distinct
        # reason so it is not retried into a wedge — see `Spotify.APIError`.
        Logger.warning("Spotify asked for #{wait}s; treating as quota exhaustion")
        {:error, api_error(:quota_exceeded, response.body)}

      true ->
        Logger.info("Spotify rate limited; waiting #{wait}s as asked")
        Process.sleep(:timer.seconds(wait))
        {:retry, api_error(:rate_limited, response.body)}
    end
  end

  defp classify({:ok, %{status: status, body: body}}) when status >= 500,
    do: {:retry, api_error(:server_error, body)}

  defp classify({:ok, %{status: _status, body: body}}),
    do: {:error, api_error(:unexpected, body)}

  # A transport failure — connection refused, timeout, DNS. Always worth another
  # attempt, and it should melt the breaker, because unlike a 401 it really does
  # say something about Spotify's reachability.
  defp classify({:error, exception}),
    do:
      {:retry,
       api_error(:server_error, %{"error" => %{"message" => Exception.message(exception)}})}

  # Seconds, per the spec. A malformed value is treated as absent rather than
  # as zero: falling back to the configured backoff is safe, and parsing garbage
  # into "retry immediately" is not.
  defp retry_after(response) do
    response
    |> Req.Response.get_header("retry-after")
    |> List.first()
    |> case do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, _rest} when seconds >= 0 -> seconds
          _unparseable -> nil
        end

      _absent ->
        nil
    end
  end

  # Verified shape: Development Mode refusals carry a message naming the app's
  # status rather than a scope. Matched loosely on purpose — the wording is not
  # contractual, and being wrong here costs a less precise error message rather
  # than a wrong outcome.
  defp development_mode_refusal?(%{"error" => %{"message" => message}})
       when is_binary(message) do
    downcased = String.downcase(message)

    String.contains?(downcased, "development mode") or
      String.contains?(downcased, "not registered") or
      String.contains?(downcased, "user may not")
  end

  defp development_mode_refusal?(_body), do: false

  defp api_error(reason, body) do
    Errata.create(APIError,
      reason: reason,
      context: Map.merge(%{provider: :spotify}, describe(body))
    )
  end

  # Spotify's Web API error shape, which is one object rather than JSON:API's
  # array. The token endpoint uses a different one — see `Spotify.OAuth`.
  defp describe(%{"error" => %{} = error}),
    do: %{detail: error["message"], spotify_status: error["status"]}

  defp describe(%{"error" => error}) when is_binary(error), do: %{detail: error}
  defp describe(_body), do: %{}

  defp api_url, do: config()[:api_url]
  defp req_options, do: config()[:req_options] || []
  defp config, do: Application.get_env(:one_playlist, Spotify, [])
end
