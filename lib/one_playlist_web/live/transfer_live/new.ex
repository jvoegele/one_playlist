defmodule OnePlaylistWeb.TransferLive.New do
  @moduledoc """
  Choose a playlist to transfer, and where to put it.

  ## Both ends are chosen, and either may be any connected service

  The source and the destination are both picked from the user's connections.
  Hard-coding either would make the application's whole premise unreachable
  from its own UI.

  Nothing stops them being the same. TIDAL to TIDAL is a real operation — it
  duplicates a playlist — and the transfer engine already treats a re-run
  against a destination that holds the tracks as `already_present` rather than
  as a mistake, so the same-service case is neither special-cased nor refused.

  ## The playlist list is loaded asynchronously, and again on every source change

  Reading a library is one request per twenty playlists against a rate-limited
  provider, and the test account has 216 of them. Doing that in `mount/3` would
  hold the connection open through a static render *and* a connected one — the
  work would happen twice, and the page would show nothing until it finished
  both times.

  `assign_async/3` renders the page immediately and fills the list in when it
  arrives, which is also why `<.async_result>` has a `:loading` slot below
  rather than a spinner bolted on afterwards. Changing the source starts the
  same work again, and clears the selection: a playlist id belongs to the
  service it came from, and carrying one across a source change would send the
  worker looking for a TIDAL id in a Navidrome library.
  """

  use OnePlaylistWeb, :live_view
  use Bond

  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Connection

  alias OnePlaylist.Transfers

  @impl true
  def mount(_params, _session, socket) do
    connections = Providers.list_connections(socket.assigns.current_user_id)
    source = default_provider(connections)

    {:ok,
     socket
     |> assign(:page_title, "New transfer")
     |> assign(:connections, connections)
     |> assign(:source, source)
     |> assign(:destination, source)
     |> assign(:selected, MapSet.new())
     |> assign(:submitting?, false)
     |> load_playlists(source)}
  end

  @impl true
  def handle_event("source", %{"provider" => provider}, socket) do
    source = provider!(socket, provider)

    {:noreply,
     socket
     |> assign(:source, source)
     # The selection belongs to the previous service and means nothing here.
     |> assign(:selected, MapSet.new())
     |> load_playlists(source)}
  end

  def handle_event("destination", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, :destination, provider!(socket, provider))}
  end

  # Toggling rather than replacing, because the list is now a multi-select. A
  # `MapSet` rather than a list: clicking the same row twice is an ordinary
  # gesture and must not queue the playlist twice.
  def handle_event("select", %{"id" => id}, socket) do
    selected = socket.assigns.selected

    toggled =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected, toggled)}
  end

  def handle_event("select_all", _params, socket) do
    everything =
      case socket.assigns.playlists do
        %{result: playlists} when is_list(playlists) -> MapSet.new(playlists, & &1.provider_id)
        _not_loaded -> MapSet.new()
      end

    {:noreply, assign(socket, :selected, everything)}
  end

  def handle_event("select_none", _params, socket),
    do: {:noreply, assign(socket, :selected, MapSet.new())}

  def handle_event("transfer", _params, socket) do
    # Ordered by the list rather than by the set, so the batch reads in the same
    # order as the picker the user was just looking at. A `MapSet` has no order
    # to offer and iterating it would shuffle the report.
    chosen =
      case socket.assigns.playlists do
        %{result: playlists} when is_list(playlists) ->
          Enum.filter(playlists, &MapSet.member?(socket.assigns.selected, &1.provider_id))

        _not_loaded ->
          []
      end

    queue(socket, chosen)
  end

  defp queue(socket, []), do: {:noreply, put_flash(socket, :error, "Pick a playlist first.")}

  defp queue(socket, [playlist]) do
    case Transfers.create(attrs_for(socket, playlist)) do
      {:ok, transfer} ->
        {:noreply, push_navigate(socket, to: ~p"/transfers/#{transfer.id}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That transfer could not be queued.")}
    end
  end

  # Several playlists land on the list rather than on one report, because there
  # is no single report to show: each playlist is its own transfer with its own
  # report, and `/transfers` is where the batch can be watched as a whole.
  defp queue(socket, playlists) do
    common = %{
      user_id: socket.assigns.current_user_id,
      source_provider: socket.assigns.source,
      destination_provider: socket.assigns.destination
    }

    per_playlist =
      Enum.map(playlists, fn playlist ->
        %{
          source_playlist_id: playlist.provider_id,
          source_playlist_name: playlist.name,
          destination_playlist_name: destination_name(socket, playlist)
        }
      end)

    case Transfers.create_batch(common, per_playlist) do
      {:ok, transfers} ->
        {:noreply,
         socket
         |> put_flash(:info, "Queued #{length(transfers)} playlists.")
         |> push_navigate(to: ~p"/transfers")}

      {:error, _reason} ->
        # Nothing was queued: `create_batch/2` is one transaction, so the button
        # can simply be pressed again.
        {:noreply, put_flash(socket, :error, "Those transfers could not be queued.")}
    end
  end

  defp attrs_for(socket, playlist) do
    %{
      user_id: socket.assigns.current_user_id,
      source_provider: socket.assigns.source,
      source_playlist_id: playlist.provider_id,
      source_playlist_name: playlist.name,
      destination_provider: socket.assigns.destination,
      destination_playlist_name: destination_name(socket, playlist)
    }
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
          Pick a playlist and where it should go. Every track is matched on the
          way, and the report says what happened to each one.
        </p>

        <div :if={@connections == []} class="alert alert-warning" role="alert">
          <.icon name="hero-link-slash" class="w-5 h-5 shrink-0" />
          <div>
            <p class="font-semibold">No music service connected.</p>
            <p class="text-sm">
              A transfer needs somewhere to read from and somewhere to write to. <.link
                navigate={~p"/connections"}
                class="link"
              >Connect one first</.link>.
            </p>
          </div>
        </div>

        <div :if={@connections != []}>
          <div class="grid gap-4 sm:grid-cols-[1fr_auto_1fr] sm:items-end mb-6">
            <.provider_picker
              id="source"
              label="From"
              event="source"
              connections={@connections}
              selected={@source}
            />

            <div class="hidden sm:flex pb-3 justify-center opacity-40">
              <.icon name="hero-arrow-right" class="w-5 h-5" />
            </div>

            <.provider_picker
              id="destination"
              label="To"
              event="destination"
              connections={@connections}
              selected={@destination}
            />
          </div>

          <.async_result :let={playlists} assign={@playlists}>
            <:loading>
              <div class="space-y-2">
                <div :for={_ <- 1..5} class="skeleton h-14 w-full"></div>
              </div>
            </:loading>

            <:failed :let={_reason}>
              <div class="alert alert-error" role="alert">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                <span>
                  Could not read your {Connection.display_name(@source)} library.
                  <.link navigate={~p"/connections"} class="link">Check the connection</.link>
                  and try again.
                </span>
              </div>
            </:failed>

            <div :if={playlists == []} class="text-center py-16 opacity-70">
              <p>No playlists on {Connection.display_name(@source)} yet.</p>
            </div>

            <div class="space-y-2 max-h-[28rem] overflow-y-auto pr-1">
              <button
                :for={playlist <- playlists}
                type="button"
                phx-click="select"
                phx-value-id={playlist.provider_id}
                class={[
                  "w-full text-left card bg-base-200 hover:bg-base-300 transition-colors",
                  MapSet.member?(@selected, playlist.provider_id) && "ring-2 ring-primary"
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

            <div class="mt-6 flex items-center justify-between gap-4">
              <div class="flex items-center gap-2 text-sm">
                <button type="button" phx-click="select_all" class="btn btn-ghost btn-xs">
                  Select all
                </button>
                <button
                  :if={MapSet.size(@selected) > 0}
                  type="button"
                  phx-click="select_none"
                  class="btn btn-ghost btn-xs"
                >
                  Clear
                </button>
                <span :if={MapSet.size(@selected) > 0} class="opacity-70 tabular-nums">
                  {MapSet.size(@selected)} selected
                </span>
              </div>

              <button
                type="button"
                phx-click="transfer"
                disabled={MapSet.size(@selected) == 0}
                class="btn btn-primary"
              >
                {transfer_label(MapSet.size(@selected))} to {Connection.display_name(@destination)}
              </button>
            </div>
          </.async_result>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # "Transfer" for one and "Transfer 12 playlists" for several, so the button
  # says how much is about to happen rather than leaving the count to the row
  # highlights.
  defp transfer_label(1), do: "Transfer"
  defp transfer_label(count), do: "Transfer #{count} playlists"

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :event, :string, required: true
  attr :connections, :list, required: true
  attr :selected, :atom, required: true

  # A `<select>` over the user's own connections, and not over every provider
  # this application knows about: offering an unconnected service would produce
  # a form whose only outcome is `ConnectionNotFound`.
  defp provider_picker(assigns) do
    ~H"""
    <div>
      <label class="label" for={@id}>
        <span class="label-text">{@label}</span>
      </label>
      <%!-- The id is what LiveView uses to recover a form's state after a
            reconnect; without one it warns, and the picker would reset. --%>
      <form id={"#{@id}-form"} phx-change={@event}>
        <select id={@id} name="provider" class="select select-bordered w-full">
          <option
            :for={connection <- @connections}
            value={connection.provider}
            selected={connection.provider == @selected}
          >
            {Connection.label(connection)}
          </option>
        </select>
      </form>
    </div>
    """
  end

  defp default_provider([]), do: nil
  defp default_provider([connection | _rest]), do: connection.provider

  # `to_existing_atom` rather than `to_atom`, and checked against the user's own
  # connections afterwards. The value arrives from a form whose options are
  # rendered from those connections, so anything else is a forged request rather
  # than a choice, and raising is the right answer to one.
  #
  # The refusal is **not** a precondition, though it reads exactly like one. A
  # `@pre` is compiled out under `preconditions: :purge`, and a security check
  # that stops existing when a config flag changes is not a check — a forged
  # request is something this program must handle, not something it may assume
  # away. So it stays ordinary code, and only its diagnostic changed.
  #
  # The `@post` is a different claim, and purging is irrelevant to it: what this
  # function *returns*, where the body checks what it *looked up*. The same atom
  # today and need not be. Proven by mutation: deleting the `Enum.any?/2` branch
  # fires it against the forged-provider test.
  @post connected_to_that_provider:
          Enum.any?(socket.assigns.connections, &(&1.provider == result))
  defp provider!(socket, provider) do
    atom = String.to_existing_atom(provider)

    if Enum.any?(socket.assigns.connections, &(&1.provider == atom)) do
      atom
    else
      raise ArgumentError,
            "refused a forged destination: #{inspect(atom)} is not among this user's connections"
    end
  end

  defp load_playlists(socket, nil),
    do: assign_async(socket, :playlists, fn -> {:ok, %{playlists: []}} end)

  defp load_playlists(socket, provider) do
    user_id = socket.assigns.current_user_id

    assign_async(socket, :playlists, fn -> read_playlists(user_id, provider) end)
  end

  defp read_playlists(user_id, provider) do
    with {:ok, connection} <- Providers.fetch_usable_connection(user_id, provider),
         {:ok, adapter} <- Providers.adapter(provider),
         {:ok, stream} <- adapter.stream_playlists(connection, []) do
      # Bounded deliberately. The list is a picker, not a library browser, and
      # 216 playlists is 11 requests against a provider with no published rate
      # limit — paging the rest belongs behind a search box, not a first render.
      {:ok, %{playlists: Enum.take(stream, 100)}}
    end
  end

  # A copy within one service needs a name that is not the original's, or the
  # two are indistinguishable in the destination's own list. Across services the
  # original name is right, and "(copy)" would be noise.
  defp destination_name(%{assigns: %{source: same, destination: same}}, playlist),
    do: "#{playlist.name} (copy)"

  defp destination_name(_socket, playlist), do: playlist.name
end
