defmodule OnePlaylistWeb.PlaylistLive.Index do
  @moduledoc """
  Every playlist this user has, grouped by where it is stored.

  The page `docs/reference/domain.md` §5 calls L7, and the first screen that
  answers "what do I have?" rather than "what did this transfer do?". One group
  for the library and one per connected service.

  ## Each group loads on its own

  The library half is a database read. The rest is one rate-limited, individually
  failing HTTP conversation per service — 216 playlists at TIDAL is eleven
  requests before anything can be drawn. So every service group is its own
  `assign_async/3`, which means the page renders immediately, a slow service
  delays only its own section, and a service that is down or rate-limited
  degrades to an error inside its own box rather than taking the page with it.

  That is the same shape `OnePlaylistWeb.TransferLive.New` uses for one source,
  applied per group.
  """

  use OnePlaylistWeb, :live_view
  use Bond

  alias OnePlaylist.Library
  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Connection

  # One `assign_async/3` key per provider, so each group loads, fails and
  # renders on its own. Built at compile time from the schema's own list rather
  # than with `String.to_atom/1` on the provider at render time: the value there
  # comes from a validated enum and is bounded, but a table costs nothing and
  # needs no argument about whether that stays true.
  @async_keys Map.new(Connection.providers(), &{&1, :"playlists_#{&1}"})

  # The template renders one `.async_result` per entry in `@services`, reading
  # `assigns[service.key]`. Those two assigns are built in different places and
  # nothing but this holds them in step, so a service listed without its key
  # loaded renders an `.async_result` over `nil` — a whole service's playlists
  # gone from the page, with no error anywhere to say so. That is the failure
  # this screen is shaped to avoid, arriving by the back door.
  #
  # The second is what keeps the library out of the service list. It has its own
  # section above, and `Connection.usable?/1` says a library connection carries
  # no credential — so a library group would ask an adapter for playlists with
  # nothing to authenticate, and render a failed box under a heading the page
  # already showed.
  #
  # Neither is falsifiable by input — `mount/3` builds both assigns itself — so
  # both are proven by mutation, and both fire against the existing LiveView
  # tests: drop the `Enum.reject/2` below for `library_is_not_a_service`, and
  # return `{:ok, socket}` instead of the `Enum.reduce/3` for
  # `every_group_can_render`.
  @post whenever(
          {:ok, mounted} <- result,
          every_group_can_render:
            forall(
              service <- mounted.assigns.services,
              Map.has_key?(mounted.assigns, service.key)
            ),
          library_is_not_a_service:
            forall(service <- mounted.assigns.services, service.connection.provider != :library)
        )
  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user_id

    # The library is not fetched asynchronously: it is a local read, and making
    # it flicker in beside the remote ones would be pretending it is slow.
    # Each service gets its own assign key so its group can load, fail and
    # render independently of the others.
    services =
      user_id
      |> Providers.list_connections()
      |> Enum.reject(&(&1.provider == :library))
      |> Enum.map(&%{connection: &1, key: Map.fetch!(@async_keys, &1.provider)})

    socket =
      socket
      |> assign(:page_title, "My playlists")
      |> assign(:services, services)
      |> assign(:creating?, false)
      |> assign_library()

    {:ok, Enum.reduce(services, socket, &load_service(&2, &1))}
  end

  @impl true
  def handle_event("new", _params, socket), do: {:noreply, assign(socket, :creating?, true)}

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, :creating?, false)}

  def handle_event("create", %{"name" => name}, socket) do
    case Library.create_playlist(socket.assigns.current_user_id, String.trim(name)) do
      {:ok, playlist} ->
        {:noreply, push_navigate(socket, to: ~p"/playlists/#{playlist.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "A playlist needs a name.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-3xl">
        <.header>
          My playlists
          <:subtitle>Everything you have, wherever it is kept.</:subtitle>
        </.header>

        <section class="mt-8">
          <div class="flex items-center justify-between mb-2">
            <h2 class="text-lg font-semibold">One Playlist</h2>
            <button :if={!@creating?} phx-click="new" class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4" /> New playlist
            </button>
          </div>

          <p class="text-sm opacity-70 mb-3">
            Kept here, editable, and usable as either end of a transfer.
          </p>

          <form :if={@creating?} phx-submit="create" class="flex gap-2 mb-3">
            <input
              type="text"
              name="name"
              placeholder="Playlist name"
              autocomplete="off"
              required
              class="input input-bordered flex-1"
            />
            <button type="submit" class="btn btn-primary">Create</button>
            <button type="button" phx-click="cancel" class="btn btn-ghost">Cancel</button>
          </form>

          <div :if={@library == []} class="text-sm opacity-60 py-6 text-center">
            Nothing here yet. Make one, or transfer a playlist in.
          </div>

          <ul class="space-y-2">
            <li :for={{playlist, count} <- @library}>
              <.link
                navigate={~p"/playlists/#{playlist.id}"}
                class="card bg-base-200 hover:bg-base-300 transition-colors block"
              >
                <div class="card-body py-3 flex-row items-center justify-between gap-4">
                  <span class="font-medium truncate">{playlist.name}</span>
                  <span class="text-sm opacity-70 shrink-0 tabular-nums">
                    {count} {if count == 1, do: "track", else: "tracks"}
                  </span>
                </div>
              </.link>
            </li>
          </ul>
        </section>

        <section :for={service <- @services} class="mt-10">
          <h2 class="text-lg font-semibold mb-2">{Connection.label(service.connection)}</h2>

          <.async_result :let={playlists} assign={assigns[service.key]}>
            <:loading>
              <div class="space-y-2">
                <div :for={_ <- 1..3} class="skeleton h-12 w-full"></div>
              </div>
            </:loading>

            <:failed :let={_reason}>
              <div class="alert alert-error" role="alert">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
                <span>
                  Could not read your {Connection.display_name(service.connection.provider)} playlists. <.link
                    navigate={~p"/connections"}
                    class="link"
                  >Check the connection</.link>.
                </span>
              </div>
            </:failed>

            <div :if={playlists == []} class="text-sm opacity-60 py-6 text-center">
              No playlists on {Connection.display_name(service.connection.provider)} yet.
            </div>

            <ul class="space-y-2">
              <li :for={playlist <- playlists} class="card bg-base-200">
                <div class="card-body py-3 flex-row items-center justify-between gap-4">
                  <span class="font-medium truncate">{playlist.name}</span>
                  <span class="text-sm opacity-70 shrink-0 tabular-nums">
                    {playlist.track_count || "?"} tracks
                  </span>
                </div>
              </li>
            </ul>
          </.async_result>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp assign_library(socket) do
    assign(socket, :library, Library.playlists(socket.assigns.current_user_id))
  end

  defp load_service(socket, %{connection: connection, key: key}) do
    user_id = socket.assigns.current_user_id
    provider = connection.provider

    assign_async(socket, key, fn -> read_playlists(user_id, provider, key) end)
  end

  defp read_playlists(user_id, provider, key) do
    with {:ok, connection} <- Providers.fetch_usable_connection(user_id, provider),
         {:ok, adapter} <- Providers.adapter(provider),
         {:ok, stream} <- adapter.stream_playlists(connection, []) do
      # Bounded for the reason `TransferLive.New` bounds its picker: this is a
      # list somebody scans, not a library browser, and paging the rest belongs
      # behind a search box rather than a first render.
      {:ok, %{key => Enum.take(stream, 100)}}
    end
  end
end
