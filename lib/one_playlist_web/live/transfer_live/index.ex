defmodule OnePlaylistWeb.TransferLive.Index do
  @moduledoc """
  Every transfer this user has run, and the button that starts another.
  """

  use OnePlaylistWeb, :live_view

  alias OnePlaylist.Transfers

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :transfers, Transfers.list(socket.assigns.current_user_id))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-4xl">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-semibold">Transfers</h1>
            <p class="text-sm opacity-70">Move a playlist, and see what happened to every track.</p>
          </div>

          <div class="flex gap-2">
            <.link navigate={~p"/imports/new"} class="btn btn-ghost">
              <.icon name="hero-document-arrow-up" class="w-4 h-4" />
              <span class="hidden sm:inline">Import a file</span>
            </.link>

            <.link navigate={~p"/exports/new"} class="btn btn-ghost">
              <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
              <span class="hidden sm:inline">Export</span>
            </.link>

            <.link navigate={~p"/transfers/new"} class="btn btn-primary">
              <.icon name="hero-plus" class="w-4 h-4" /> New transfer
            </.link>
          </div>
        </div>

        <div id="transfers" phx-update="stream" class="space-y-3">
          <div id="transfers-empty" class="hidden only:block text-center py-16 opacity-70">
            <.icon name="hero-arrow-path-rounded-square" class="w-10 h-10 mx-auto mb-3" />
            <p>No transfers yet.</p>
          </div>

          <.link
            :for={{dom_id, transfer} <- @streams.transfers}
            id={dom_id}
            navigate={~p"/transfers/#{transfer.id}"}
            class="card bg-base-200 hover:bg-base-300 transition-colors block"
          >
            <div class="card-body py-4 flex-row items-center justify-between gap-4">
              <div class="min-w-0">
                <p class="font-medium truncate">
                  {transfer.source_playlist_name || transfer.source_playlist_id}
                </p>
                <p class="text-sm opacity-70">
                  {transfer.source_provider} → {transfer.destination_provider}
                </p>
              </div>

              <div class="flex items-center gap-4 shrink-0">
                <.counts :if={transfer.total_tracks > 0} transfer={transfer} />
                <.status status={transfer.status} />
              </div>
            </div>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :status, :atom, required: true

  defp status(assigns) do
    ~H"""
    <span class={[
      "badge",
      @status == :completed && "badge-success",
      @status == :failed && "badge-error",
      @status == :running && "badge-info",
      @status == :pending && "badge-ghost"
    ]}>
      {@status}
    </span>
    """
  end

  attr :transfer, :map, required: true

  defp counts(assigns) do
    ~H"""
    <span class="text-sm tabular-nums opacity-70">
      {@transfer.matched_count}/{@transfer.total_tracks} matched
    </span>
    """
  end
end
