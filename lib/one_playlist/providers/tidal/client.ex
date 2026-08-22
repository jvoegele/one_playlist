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
  alias OnePlaylist.Providers.Tidal.Service

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
  A page of the user's own playlists.

  Returns the raw JSON:API page — `data` plus whatever `links.next` TIDAL
  supplies — rather than a list, so the caller can page without this module
  deciding how much to fetch. `stream_playlists/2` is the convenience over it.
  """
  @spec list_playlists(String.t(), keyword()) :: {:ok, map()} | {:error, Errata.error()}
  def list_playlists(access_token, opts \\ []) do
    params =
      opts
      |> Keyword.take([:cursor, :limit])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn
        {:cursor, v} -> {"page[cursor]", v}
        {:limit, v} -> {"page[limit]", v}
      end)

    get(access_token, "/userCollections/me/relationships/playlists", params)
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
  @spec stream_playlists(String.t(), keyword()) :: Enumerable.t()
  def stream_playlists(access_token, opts \\ []) do
    Stream.resource(
      fn -> {:start, nil} end,
      fn
        :halt ->
          {:halt, nil}

        {_previous, cursor} = acc ->
          opts = if cursor, do: Keyword.put(opts, :cursor, cursor), else: opts

          case list_playlists(access_token, opts) do
            {:ok, %{"data" => data} = page} ->
              {data, advance(acc, next_cursor(page))}

            {:error, error} ->
              raise error
          end
      end,
      fn _ -> :ok end
    )
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
