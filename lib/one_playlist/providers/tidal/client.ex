defmodule OnePlaylist.Providers.Tidal.Client do
  @moduledoc """
  Calls to the TIDAL API, each guarded by `OnePlaylist.Providers.Tidal.Service`.

  Every function here takes an access token rather than a
  `OnePlaylist.Providers.Connection`, so this module knows nothing about how
  tokens are stored or refreshed. `OnePlaylist.Providers.Tidal` is the layer
  that joins the two.

  ## Timeouts are set here on purpose

  `ExternalService` deliberately imposes no timeout — it cannot abandon a socket
  from the outside, and a breaker protects against a service that *fails*, not
  one that *hangs*. Bounding an attempt is the client's job, so every request
  below sets both a receive timeout and a pool checkout timeout. Without the
  latter, saturation blocks before a request is even sent, and nothing observes
  it. See `docs/reference/jv-libraries.md`.
  """

  alias OnePlaylist.Providers.Tidal
  alias OnePlaylist.Providers.Tidal.APIError
  alias OnePlaylist.Providers.Tidal.Mapper
  alias OnePlaylist.Providers.Tidal.Service
  alias OnePlaylist.Providers.Tidal.WriteService

  use Errata

  @receive_timeout :timer.seconds(10)
  @pool_timeout :timer.seconds(5)

  @doc """
  The authenticated user.

  Doubles as the connection health check: it is the cheapest call that proves a
  token is live, which is what the OAuth callback needs before storing anything.
  """
  @spec current_user(String.t()) :: {:ok, map()} | {:error, Errata.error()}
  def current_user(access_token) do
    with {:ok, %{"data" => data}} <- get(access_token, "/users/me") do
      {:ok, data}
    end
  end

  @doc """
  A page of the playlists a user owns.

  `tidal_user_id` is TIDAL's numeric account id — the `provider_user_id` on the
  connection, and the `id` from `current_user/1`. It is required rather than
  defaulted to `me`, because **TIDAL accepts `me` only on `/users/me`**.

  Uses `filter[r.owners.id]` rather than
  `/userCollections/{id}/relationships/playlists`. Both return 200; they differ
  in what comes back, and the difference decides how many requests a library
  listing costs. Verified live on 2026-08-22:

  | Endpoint | Returns |
  | --- | --- |
  | `/userCollections/{id}/relationships/playlists` | identifiers only — `{id, type, meta.addedAt}` |
  | `/playlists?filter[r.owners.id]={id}` | **full resources**, with `name`, `numberOfItems`, timestamps |

  The relationships form would need a follow-up request per playlist just to
  learn its name: 216 requests instead of 11 for the test account.

  They also differ in *scope*, which matters more than the request count: the
  collection is everything in the user's library including playlists they merely
  follow, while this filter is only what they own. Transferring someone else's
  followed playlist is a separate feature, and a separate call.
  """
  @spec list_playlists(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Errata.error()}
  def list_playlists(access_token, tidal_user_id, opts \\ []) do
    params =
      [{"filter[r.owners.id]", tidal_user_id}] ++
        country_param(opts) ++ page_params(opts)

    get(access_token, "/playlists", params)
  end

  @doc """
  A page of a playlist's items, with the track resources included.

  `include=items.artists,items.albums` is what makes this one request instead of
  three: without it the items come back as bare identifiers, and artist names —
  which the matching engine needs when ISRC is absent — would each cost their
  own round trip.
  """
  @spec list_playlist_items(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Errata.error()}
  def list_playlist_items(access_token, playlist_id, opts \\ []) do
    params =
      [{"include", "items.artists,items.albums,items.albums.coverArt"}] ++
        country_param(opts) ++ page_params(opts)

    get(access_token, "/playlists/#{playlist_id}/relationships/items", params)
  end

  @doc """
  Catalogue tracks carrying a given ISRC.

  One request, exact results, and the cheapest way to answer the matching
  engine's question — no text search, no scoring, no guessing. Verified live on
  2026-08-22 against `GET /v2/tracks?filter[isrc]=…`.

  Expect **more than one**. That first live call returned two catalogue entries
  for `GBAYE0601477`, which is normal: the same recording appears on a single,
  an album and any number of compilations, each its own catalogue entry with
  its own id. They are all correct answers, which is why this returns candidates
  and `OnePlaylist.Matching` chooses between them rather than this function
  taking the first.

  `include=artists,albums` is what makes those candidates comparable: without
  it the artist names and the album barcode — the fields the text and UPC rungs
  need — are absent, and a candidate that cannot be scored is not a candidate.
  """
  @spec tracks_by_isrc(String.t(), String.t(), keyword()) ::
          {:ok, [OnePlaylist.Music.Track.t()]} | {:error, Errata.error()}
  def tracks_by_isrc(access_token, isrc, opts \\ []) do
    params =
      [{"filter[isrc]", isrc}, {"include", "artists,albums,albums.coverArt"}] ++
        country_param(opts)

    with {:ok, document} <- get(access_token, "/tracks", params) do
      {:ok, Mapper.tracks_from_data(document)}
    end
  end

  @doc """
  The album carrying a barcode, or `nil`.

  Verified live on 2026-08-22: `GET /v2/albums?filter[barcodeId]=…` returns the
  release. Barcodes are normalized before use because TIDAL reports them
  zero-padded to 13 digits where other catalogues print 12 — see
  `OnePlaylist.Music.Barcode.normalize/1`.

  Returns the album's id only. Nothing else about the album is wanted: the
  caller has the barcode already, and what it actually needs is the item list.
  """
  @spec album_by_barcode(String.t(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, Errata.error()}
  def album_by_barcode(access_token, barcode, opts \\ []) do
    params = [{"filter[barcodeId]", barcode}] ++ country_param(opts)

    with {:ok, %{"data" => data}} <- get(access_token, "/albums", params) do
      {:ok, data |> List.wrap() |> List.first() |> then(& &1["id"])}
    end
  end

  @doc """
  An album's tracks, each carrying its position within the release.

  The only TIDAL call that yields `track_number` and `volume_number`, and so
  the only way rung 2 of the matching ladder can fire. Positions arrive as
  `meta` on each item rather than as attributes on the track, which is why this
  is a separate request from everything else.

  `include=items.artists` costs nothing extra and makes the results scoreable
  on text as well, so a candidate rejected by rung 2 is not wasted.
  """
  @spec album_items(String.t(), String.t(), keyword()) ::
          {:ok, [OnePlaylist.Music.Track.t()]} | {:error, Errata.error()}
  def album_items(access_token, album_id, opts \\ []) do
    params =
      [{"include", "items.artists"}] ++ country_param(opts) ++ page_params(opts)

    with {:ok, document} <-
           get(access_token, "/albums/#{album_id}/relationships/items", params) do
      {:ok, Mapper.tracks_from_album_items(document, Keyword.get(opts, :barcode))}
    end
  end

  @doc """
  Catalogue tracks matching a free-text query, in TIDAL's relevance order.

  For tracks with no ISRC, which is the only reason to prefer this over
  `tracks_by_isrc/3`.

  ## The request shape, and the one that looks right and is not

  `searchResults` is a **collection with a filter**, not a resource addressed by
  the query:

  | Request | Result |
  | --- | --- |
  | `/searchResults?filter[query]=hey+jude` | **200** |
  | `/searchResults/hey%20jude` | 400 `INVALID_RESOURCE_ID` |

  The second reads like the obvious JSON:API form and is what the path in the
  response's own pagination links looks like — but that path takes the **opaque
  search id** from `data[0].id`, not the query text. Eight request variants
  were tried against the live service before the filter form was found, and
  every one of them returned the same `INVALID_RESOURCE_ID`, which says nothing
  about which part was wrong.

  `include=tracks.artists,tracks.albums` is not optional in practice. Without
  the nested part the included tracks arrive with **no relationships at all** —
  verified — so they have no artist names and no album barcode, and a candidate
  that cannot be scored on text is no use to the one caller this exists for.
  """
  @spec search_tracks(String.t(), String.t(), keyword()) ::
          {:ok, [OnePlaylist.Music.Track.t()]} | {:error, Errata.error()}
  def search_tracks(access_token, query, opts \\ []) do
    params =
      [
        {"filter[query]", query},
        {"include", "tracks.artists,tracks.albums,tracks.albums.coverArt"}
      ] ++ country_param(opts) ++ page_params(opts)

    with {:ok, document} <- get(access_token, "/searchResults", params) do
      {:ok, Mapper.tracks_from_search(document)}
    end
  end

  @doc """
  Every playlist the user has, as a lazy `Stream`.

  Lazy because a large library is many round trips and the caller may only want
  the first few — and because each page is a guarded call, so pacing falls out
  of the rate limiter rather than needing its own throttle here.

  Errors terminate the stream by raising, since a `Stream` has nowhere to put an
  error tuple. Callers that want values should wrap in `Errata`-aware handling
  or use `list_playlists/2` directly.
  """
  @spec stream_playlists(String.t(), String.t(), keyword()) :: Enumerable.t()
  def stream_playlists(access_token, tidal_user_id, opts \\ []) do
    paginate(opts, fn page_opts ->
      list_playlists(access_token, tidal_user_id, page_opts)
    end)
  end

  @doc """
  Every track in a playlist, in playlist order, as `OnePlaylist.Music.Track`.

  Lazy for the same reason `stream_playlists/3` is, and more urgently: the test
  account has a playlist with 2,030 items, which is 102 requests. A caller that
  wants the first ten should pay for one.
  """
  @spec stream_playlist_tracks(String.t(), String.t(), keyword()) :: Enumerable.t()
  def stream_playlist_tracks(access_token, playlist_id, opts \\ []) do
    opts
    |> Keyword.put(:map_page, &Mapper.tracks_from_items_page/1)
    |> paginate(fn page_opts ->
      list_playlist_items(access_token, playlist_id, page_opts)
    end)
  end

  @doc """
  Creates a playlist and returns it.

  Verified live on 2026-08-22: `POST /v2/playlists` with a JSON:API document
  returns **201** and a playlist whose `id` is a **UUID**, unlike the numeric
  ids catalogue resources carry. Nothing downstream should assume a shape for a
  provider id, and this is why.

  `accessType` is deliberately not sent. `"PRIVATE"` is rejected with a 400
  pointing at `data/attributes/accessType`, while `"UNLISTED"` and `"PUBLIC"`
  are accepted — so the safe default is to omit it and let TIDAL decide, rather
  than to guess at a visibility on the user's behalf.
  """
  @spec create_playlist(String.t(), String.t(), keyword()) ::
          {:ok, OnePlaylist.Music.Playlist.t()} | {:error, Errata.error()}
  def create_playlist(access_token, name, opts \\ []) do
    body = %{
      "data" => %{
        "type" => "playlists",
        "attributes" =>
          %{"name" => name}
          |> maybe_put("description", Keyword.get(opts, :description))
      }
    }

    with {:ok, %{"data" => resource}} <-
           write(access_token, :post, "/playlists", body, country_param(opts)) do
      {:ok, Mapper.playlist(resource)}
    end
  end

  @doc """
  Appends tracks to a playlist, in the order given.

  `POST /v2/playlists/{id}/relationships/items` with a JSON:API resource
  identifier array; verified to return **200**.

  Appends, and does not deduplicate — TIDAL will happily add a track already
  present. Deciding what to add is the caller's job, and
  `playlist_track_ids/3` is what it should decide against.
  """
  @spec add_tracks(String.t(), String.t(), [String.t()], keyword()) ::
          :ok | {:error, Errata.error()}
  def add_tracks(access_token, playlist_id, track_ids, opts \\ [])

  def add_tracks(_access_token, _playlist_id, [], _opts), do: :ok

  def add_tracks(access_token, playlist_id, track_ids, opts) do
    body = %{"data" => Enum.map(track_ids, &%{"id" => &1, "type" => "tracks"})}

    with {:ok, _response} <-
           write(
             access_token,
             :post,
             "/playlists/#{playlist_id}/relationships/items",
             body,
             country_param(opts)
           ) do
      :ok
    end
  end

  @doc """
  The ids of the tracks currently in a playlist, in order.

  The snapshot an idempotent transfer diffs against: `docs/reference/domain.md`
  requires that a retried "add tracks" must not duplicate, and the only way to
  keep that promise is to look before writing.

  Returns identifiers rather than `OnePlaylist.Music.Track` structs on purpose.
  The caller wants to know *what is already there*, which is a set membership
  question — mapping the resources would cost an `include` and produce data
  nobody reads.
  """
  @spec playlist_track_ids(String.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, Errata.error()}
  def playlist_track_ids(access_token, playlist_id, opts \\ []) do
    ids =
      opts
      |> Keyword.put(:map_page, &Mapper.item_ids/1)
      |> paginate(fn page_opts ->
        list_playlist_items(access_token, playlist_id, page_opts)
      end)
      |> Enum.to_list()

    {:ok, ids}
  rescue
    error in [OnePlaylist.Providers.Tidal.APIError, ExternalService.RetriesExhausted] ->
      {:error, error}
  end

  @doc """
  Deletes a playlist.

  Present for the sake of the tests and of cleaning up after them, not because
  the product deletes playlists. It is the call that revealed how hard TIDAL
  rate-limits mutations — see `OnePlaylist.Providers.Tidal.WriteService`.
  """
  @spec delete_playlist(String.t(), String.t(), keyword()) :: :ok | {:error, Errata.error()}
  def delete_playlist(access_token, playlist_id, opts \\ []) do
    with {:ok, _response} <-
           write(access_token, :delete, "/playlists/#{playlist_id}", nil, country_param(opts)) do
      :ok
    end
  end

  defp with_body(options, nil), do: options
  defp with_body(options, body), do: Keyword.put(options, :json, body)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # One pagination loop for every cursor-paged endpoint. `fetch` returns the raw
  # page; the caller decides what a page's items are.
  defp paginate(opts, fetch) do
    {mapper, opts} = Keyword.pop(opts, :map_page, & &1["data"])

    Stream.resource(
      fn -> {:start, nil} end,
      fn
        :halt ->
          {:halt, nil}

        {_previous, cursor} = acc ->
          page_opts = if cursor, do: Keyword.put(opts, :cursor, cursor), else: opts

          case fetch.(page_opts) do
            {:ok, page} -> {List.wrap(mapper.(page)), advance(acc, next_cursor(page))}
            {:error, error} -> raise error
          end
      end,
      fn _ -> :ok end
    )
  end

  defp page_params(opts) do
    opts
    |> Keyword.take([:cursor, :limit])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map(fn
      {:cursor, value} -> {"page[cursor]", value}
      {:limit, value} -> {"page[limit]", value}
    end)
  end

  # Most TIDAL endpoints return different catalogue availability per country,
  # and some refuse without it. The value belongs to the connected account, so
  # callers pass it down from the connection rather than guessing.
  defp country_param(opts) do
    case Keyword.get(opts, :country) do
      nil -> []
      country -> [{"countryCode", country}]
    end
  end

  # Termination is decided by the remote service, which is a poor place to leave
  # it: a `next` link that points at the page we just fetched would spin
  # forever, and a background job would spin with it. A repeated cursor is
  # treated as the end rather than trusted.
  defp advance(_acc, nil), do: :halt
  defp advance({_previous, cursor}, cursor), do: :halt
  defp advance({_previous, cursor}, next), do: {cursor, next}

  defp next_cursor(%{"links" => %{"next" => next}}) when is_binary(next) do
    next |> URI.parse() |> Map.get(:query) |> decode_cursor()
  end

  defp next_cursor(_page), do: nil

  defp decode_cursor(nil), do: nil
  defp decode_cursor(query), do: query |> URI.decode_query() |> Map.get("page[cursor]")

  # The mutating counterpart of `get/3`. Same classification and the same
  # timeouts; a different guarded front door, because TIDAL rate-limits writes
  # far harder than reads.
  defp write(access_token, method, path, body, params) do
    WriteService.call(fn ->
      [
        base_url: api_url(),
        url: path,
        method: method,
        params: params,
        auth: {:bearer, access_token},
        headers: [
          {"accept", "application/vnd.api+json"},
          {"content-type", "application/vnd.api+json"}
        ],
        receive_timeout: @receive_timeout,
        finch: [pool_timeout: @pool_timeout],
        retry: false
      ]
      |> with_body(body)
      |> Keyword.merge(req_options())
      |> Req.new()
      |> Req.request()
      |> classify()
    end)
  end

  defp get(access_token, path, params \\ []) do
    Service.call(fn ->
      [
        base_url: api_url(),
        url: path,
        method: :get,
        params: params,
        auth: {:bearer, access_token},
        headers: [{"accept", "application/vnd.api+json"}],
        receive_timeout: @receive_timeout,
        finch: [pool_timeout: @pool_timeout],
        # Req retries 408/429/5xx three times with its own backoff by default.
        # Left on, every guarded call would retry 3× *inside* each
        # ExternalService attempt — twelve requests where four were configured,
        # with a backoff nothing here can see or tune. ExternalService owns
        # retrying; Req must not.
        retry: false
      ]
      |> Keyword.merge(req_options())
      |> Req.new()
      |> Req.request()
      |> classify()
    end)
  end

  # The mapping from HTTP status to "should this be attempted again".
  #
  # Note that 401 is *not* retried. A token does not become valid by asking
  # twice, and retrying would melt the circuit breaker on what is really one
  # user's expired connection — degrading TIDAL access for everybody else.
  defp classify({:ok, %{status: status, body: body}}) when status in 200..299, do: {:ok, body}

  defp classify({:ok, %{status: 401, body: body}}), do: {:error, api_error(:unauthorized, body)}
  defp classify({:ok, %{status: 403, body: body}}), do: {:error, api_error(:forbidden, body)}
  defp classify({:ok, %{status: 404, body: body}}), do: {:error, api_error(:not_found, body)}

  defp classify({:ok, %{status: 429, body: body}}),
    do: {:retry, api_error(:rate_limited, body)}

  defp classify({:ok, %{status: status, body: body}}) when status >= 500,
    do: {:retry, api_error(:server_error, body)}

  defp classify({:ok, %{status: _status, body: body}}),
    do: {:error, api_error(:unexpected, body)}

  # A transport failure — connection refused, timeout, DNS. Always worth another
  # attempt, and it should melt the breaker, because unlike a 401 it really does
  # say something about TIDAL's reachability.
  defp classify({:error, exception}),
    do: {:retry, api_error(:server_error, %{"detail" => Exception.message(exception)})}

  defp api_error(reason, body) do
    Errata.create(APIError,
      reason: reason,
      context: Map.merge(%{provider: :tidal}, describe(body))
    )
  end

  # TIDAL replies in JSON:API's error shape; keep the first error's detail,
  # which is the part worth putting in front of a human.
  defp describe(%{"errors" => [%{} = first | _rest]}) do
    %{
      tidal_code: first["code"],
      detail: first["detail"],
      category: get_in(first, ["meta", "category"])
    }
  end

  defp describe(%{"detail" => detail}), do: %{detail: detail}
  defp describe(_body), do: %{}

  defp api_url, do: config()[:api_url]
  defp req_options, do: config()[:req_options] || []
  defp config, do: Application.get_env(:one_playlist, Tidal, [])
end
