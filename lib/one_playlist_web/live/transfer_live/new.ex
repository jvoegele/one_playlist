defmodule OnePlaylistWeb.TransferLive.New do
  @moduledoc """
  Choose a playlist to transfer.

  ## The playlist list is loaded asynchronously

  Reading a library is one request per twenty playlists against a rate-limited
  provider, and the test account has 216 of them. Doing that in `mount/3` would
  hold the connection open through a static render *and* a connected one — the
  work would happen twice, and the page would show nothing until it finished
  both times.

  `assign_async/3` renders the page immediately and fills the list in when it
  arrives, which is also why `<.async_result>` has a `:loading` slot below
  rather than a spinner bolted on afterwards.
  """

  use OnePlaylistWeb, :live_view

  alias OnePlaylist.Providers
  alias OnePlaylist.Transfers

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user_id

    {:ok,
     socket
     |> assign(:selected, nil)
     |> assign(:submitting?, false)
     |> assign_async(:playlists, fn -> load_playlists(user_id) end)}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected, id)}
  end

  def handle_event("transfer", _params, %{assigns: %{selected: nil}} = socket) do
    {:noreply, put_flash(socket, :error, "Pick a playlist first.")}
  end

  def handle_event("transfer", _params, socket) do
    playlist = find_playlist(socket, socket.assigns.selected)

    attrs = %{
      user_id: socket.assigns.current_user_id,
      source_provider: :tidal,
      source_playlist_id: playlist.provider_id,
      source_playlist_name: playlist.name,
      destination_provider: :tidal,
      destination_playlist_name: "#{playlist.name} (copy)"
    }

    case Transfers.create(attrs) do
      {:ok, transfer} ->
        {:noreply, push_navigate(socket, to: ~p"/transfers/#{transfer.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "That transfer could not be queued.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-3xl">
        <.link navigate={~p"/transfers"} class="btn btn-ghost btn-sm mb-4">
          <.icon name="hero-arrow-left" class="w-4 h-4" /> Transfers
        </.link>

        <h1 class="text-2xl font-semibold mb-1">New transfer</h1>
        <p class="text-sm opacity-70 mb-6">
          Pick a TIDAL playlist. It will be copied to a new TIDAL playlist —
          the same machinery that will move it to another service once one is
          connected.
        </p>

        <.async_result :let={playlists} assign={@playlists}>
          <:loading>
            <div class="space-y-2">
              <div :for={_ <- 1..5} class="skeleton h-14 w-full"></div>
            </div>
          </:loading>

          <:failed :let={_reason}>
            <div class="alert alert-error">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
              <span>
                Could not read your TIDAL library. <.link navigate={~p"/auth/tidal"} class="link">Reconnect</.link>
                and try again.
              </span>
            </div>
          </:failed>

          <div class="space-y-2 max-h-[28rem] overflow-y-auto pr-1">
            <button
              :for={playlist <- playlists}
              type="button"
              phx-click="select"
              phx-value-id={playlist.provider_id}
              class={[
                "w-full text-left card bg-base-200 hover:bg-base-300 transition-colors",
                @selected == playlist.provider_id && "ring-2 ring-primary"
              ]}
            >
              <div class="card-body py-3 flex-row items-center justify-between gap-4">
                <span class="font-medium truncate">{playlist.name}</span>
                <span class="text-sm opacity-70 shrink-0 tabular-nums">
                  {playlist.track_count || "?"} tracks
                </span>
              </div>
            </button>
          </div>

          <div class="mt-6 flex justify-end">
            <button
              type="button"
              phx-click="transfer"
              disabled={is_nil(@selected)}
              class="btn btn-primary"
            >
              Transfer
            </button>
          </div>
        </.async_result>
      </div>
    </Layouts.app>
    """
  end

  defp load_playlists(user_id) do
    with {:ok, connection} <- Providers.fetch_connection(user_id, :tidal),
         {:ok, adapter} <- Providers.adapter(:tidal),
         {:ok, stream} <- adapter.stream_playlists(connection, []) do
      # Bounded deliberately. The list is a picker, not a library browser, and
      # 216 playlists is 11 requests against a provider with no published rate
      # limit — paging the rest belongs behind a search box, not a first render.
      {:ok, %{playlists: Enum.take(stream, 100)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_playlist(socket, id) do
    socket.assigns.playlists.result
    |> Enum.find(&(&1.provider_id == id))
  end
end
