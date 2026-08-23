defmodule OnePlaylistWeb.ExportLive.New do
  @moduledoc """
  Downloading a playlist from a connected service as a file.

  The mirror of `OnePlaylistWeb.ImportLive.New`, and a separate page from
  `OnePlaylistWeb.TransferLive.New` even though both list the same playlists.
  They are different questions: one asks where to *put* a playlist, the other
  asks for a copy of it, and the second needs no destination, no threshold and
  no report.

  ## The export happens off the socket

  Reading a playlist is several rate-limited provider calls, so `start_async/3`
  does it while the page stays responsive. That is a real wait, unlike the
  import side where the slow part is deferred to a job: an export has nothing to
  defer to, because a worker could not write the result to Storage without the
  service key.

  ## The stored name and the downloaded name differ, on purpose

  `OnePlaylist.Storage.path_for/3` reduces an object key to characters needing
  no URL encoding, so *Road Trip 2026* is stored as `Road-Trip-2026.csv`. The
  signed URL carries `download:` with the name the person actually chose, which
  Supabase passes as a query parameter where encoding is not a problem. So the
  file lands in their downloads folder called what they call it.
  """

  use OnePlaylistWeb, :live_view

  alias OnePlaylist.Exports
  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Storage

  @impl true
  def mount(_params, _session, socket) do
    connections = Providers.list_connections(socket.assigns.current_user_id)
    source = default_provider(connections)

    {:ok,
     socket
     |> assign(:page_title, "Export a playlist")
     |> assign(:connections, connections)
     |> assign(:source, source)
     |> assign(:exporting, nil)
     |> assign(:ready, nil)
     |> assign(:error, nil)
     |> load_playlists(source)}
  end

  @impl true
  def handle_event("source", %{"provider" => provider}, socket) do
    source = String.to_existing_atom(provider)
    true = Enum.any?(socket.assigns.connections, &(&1.provider == source))

    {:noreply,
     socket
     |> assign(:source, source)
     # A signed URL for the previous service's playlist is still valid, but
     # showing it under a different service's list reads as if it came from
     # there.
     |> assign(:ready, nil)
     |> assign(:error, nil)
     |> load_playlists(source)}
  end

  @impl true
  def handle_event("export", %{"id" => id, "name" => name}, socket) do
    session = socket.assigns.current_session
    source = socket.assigns.source

    {:noreply,
     socket
     |> assign(:exporting, id)
     |> assign(:ready, nil)
     |> assign(:error, nil)
     |> start_async(:export, fn -> export(session, source, id, name) end)}
  end

  @impl true
  def handle_async(:export, {:ok, {:ok, ready}}, socket) do
    {:noreply, socket |> assign(:exporting, nil) |> assign(:ready, ready)}
  end

  def handle_async(:export, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(:exporting, nil) |> assign(:error, describe(reason))}
  end

  # `start_async/3` reports a crash separately from a returned error. Without
  # this clause an exception in the export would leave the button spinning for
  # ever, which is the one outcome worse than saying it failed.
  def handle_async(:export, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:exporting, nil)
     |> assign(:error, "That export stopped unexpectedly (#{inspect(reason)}).")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-2xl mx-auto">
        <div class="mb-8">
          <h1 class="text-2xl font-semibold">Export a playlist</h1>
          <p class="text-sm opacity-70">
            Download a copy as CSV, to keep or to import somewhere else.
          </p>
        </div>

        <div :if={@connections == []} class="alert alert-warning mb-6" role="alert">
          <.icon name="hero-link-slash" class="w-5 h-5 shrink-0" />
          <div>
            <p class="font-semibold">No music service connected.</p>
            <p class="text-sm">
              <.link navigate={~p"/connections"} class="link">Connect one</.link> and its playlists will appear here.
            </p>
          </div>
        </div>

        <div :if={@error} class="alert alert-error mb-6" id="export-error" role="alert">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
          <span>{@error}</span>
        </div>

        <%!-- The link is rendered rather than followed automatically. A
              navigation the page starts by itself is indistinguishable from a
              popup, and browsers treat it accordingly. --%>
        <div :if={@ready} class="alert alert-success mb-6" id="export-ready" role="status">
          <.icon name="hero-check-circle" class="w-5 h-5 shrink-0" />
          <div class="flex-1 min-w-0">
            <p class="font-semibold truncate">{@ready.filename} is ready</p>
            <p class="text-sm">{@ready.track_count} tracks. The link is good for an hour.</p>
          </div>
          <a href={@ready.url} class="btn btn-sm" download={@ready.filename}>
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Download
          </a>
        </div>

        <div :if={@connections != []} class="mb-6">
          <label class="label" for="source">
            <span class="label-text">Export from</span>
          </label>
          <form id="source-form" phx-change="source">
            <select id="source" name="provider" class="select select-bordered w-full">
              <option
                :for={connection <- @connections}
                value={connection.provider}
                selected={connection.provider == @source}
              >
                {Connection.label(connection)}
              </option>
            </select>
          </form>
        </div>

        <.async_result :let={playlists} assign={@playlists}>
          <:loading>
            <div class="text-center py-16 opacity-70">
              <span class="loading loading-spinner"></span>
              <p class="mt-3 text-sm">Reading your playlists…</p>
            </div>
          </:loading>

          <:failed :let={reason}>
            <div class="alert alert-error" role="alert">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
              <span>{describe(reason)}</span>
            </div>
          </:failed>

          <div :if={playlists == []} class="text-center py-16 opacity-70">
            <p>No playlists on that service yet.</p>
          </div>

          <ul class="space-y-2">
            <li
              :for={playlist <- playlists}
              class="card bg-base-200 flex-row items-center justify-between gap-4 py-3 px-4"
            >
              <div class="min-w-0">
                <p class="font-medium truncate">{playlist.name}</p>
                <p :if={playlist.track_count} class="text-sm opacity-70">
                  {playlist.track_count} tracks
                </p>
              </div>

              <button
                phx-click="export"
                phx-value-id={playlist.provider_id}
                phx-value-name={playlist.name}
                disabled={@exporting != nil}
                class="btn btn-sm btn-primary shrink-0"
              >
                <span :if={@exporting == playlist.provider_id} class="loading loading-spinner loading-xs"></span>
                {if @exporting == playlist.provider_id, do: "Exporting…", else: "Export CSV"}
              </button>
            </li>
          </ul>
        </.async_result>
      </div>
    </Layouts.app>
    """
  end

  # Runs off the socket, so it takes the session rather than reaching for
  # assigns: the task has no socket, and closing over one would copy it.
  defp export(session, provider, playlist_id, name) do
    with {:ok, exported} <- Exports.export(session, provider, playlist_id, name: name),
         {:ok, url} <-
           Storage.signed_url(session, exported.path, download: exported.filename) do
      {:ok, Map.put(exported, :url, url)}
    end
  end

  defp load_playlists(socket, nil),
    do: assign_async(socket, :playlists, fn -> {:ok, %{playlists: []}} end)

  defp load_playlists(socket, provider) do
    user_id = socket.assigns.current_user_id

    assign_async(socket, :playlists, fn -> read_playlists(user_id, provider) end)
  end

  defp default_provider([]), do: nil
  defp default_provider([connection | _rest]), do: connection.provider

  defp read_playlists(user_id, provider) do
    with {:ok, connection} <- Providers.fetch_usable_connection(user_id, provider),
         {:ok, adapter} <- Providers.adapter(provider),
         {:ok, stream} <- adapter.stream_playlists(connection, []) do
      # Bounded for the same reason `TransferLive.New` bounds it: this is a
      # picker, not a library browser.
      {:ok, %{playlists: Enum.take(stream, 100)}}
    end
  end

  defp describe(error) when is_exception(error), do: Errata.display_message(error)
  defp describe(other), do: inspect(other)
end
