defmodule OnePlaylistWeb.TransferLive.Index do
  @moduledoc """
  Every transfer this user has run, and the button that starts another.

  ## A batch is one row

  Transferring forty playlists creates forty transfers — see
  `OnePlaylist.Transfers.create_batch/2` for why one each rather than one with
  forty sources. Drawn flat, that makes this screen unusable the moment somebody
  moves a library across: forty near-identical rows, and the transfer they ran
  yesterday pushed off the bottom.

  So a batch collapses to a single row carrying its own summary, and opens to
  show its members. A `<details>` element rather than a hook, because "show me
  the rest" needs no state on the server and no JavaScript of ours: it survives
  a LiveView reconnect, works before the socket connects, and is what a screen
  reader already knows how to announce.
  """

  use OnePlaylistWeb, :live_view

  alias OnePlaylist.Providers.Connection

  alias OnePlaylist.Transfers

  # A plain assign rather than a stream: the rows are now nested, and a batch's
  # summary is derived from its members rather than from a row of its own.
  # `list/1` already loads every transfer, so this changes what is rendered and
  # not what is read.
  #
  # No contract here. "Every transfer appears in exactly one row" is
  # `Transfers.group_batches/1`'s `every_transfer_in_exactly_one_group`, and
  # restating it over the assigns would fire first and make that one unreachable
  # — see `docs/reference/contracts.md` on thin wrappers over a contracted callee.
  @impl true
  def mount(_params, _session, socket) do
    transfers = Transfers.list(socket.assigns.current_user_id)

    {:ok,
     socket
     |> assign(:transfers, transfers)
     |> assign(:groups, Transfers.group_batches(transfers))}
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

        <div class="space-y-3">
          <div :if={@groups == []} class="text-center py-16 opacity-70">
            <.icon name="hero-arrow-path-rounded-square" class="w-10 h-10 mx-auto mb-3" />
            <p>No transfers yet.</p>
          </div>

          <%= for group <- @groups do %>
            <.link
              :if={match?({:single, _transfer}, group)}
              navigate={~p"/transfers/#{elem(group, 1).id}"}
              class="card bg-base-200 hover:bg-base-300 transition-colors block"
            >
              <.transfer_row transfer={elem(group, 1)} />
            </.link>

            <details :if={match?({:batch, _batch}, group)} class="card bg-base-200">
              <summary class="card-body py-4 flex-row items-center justify-between gap-4 cursor-pointer list-none">
                <div class="min-w-0">
                  <p class="font-medium truncate">
                    {length(elem(group, 1).transfers)} playlists
                  </p>
                  <p class="text-sm opacity-70">
                    {Connection.display_name(hd(elem(group, 1).transfers).source_provider)} → {Connection.display_name(
                      hd(elem(group, 1).transfers).destination_provider
                    )}
                  </p>
                </div>

                <div class="flex items-center gap-4 shrink-0">
                  <span class="text-sm tabular-nums opacity-70">
                    {done(elem(group, 1).transfers)}/{length(elem(group, 1).transfers)} done<%= if failed(
                                                                                                    elem(
                                                                                                      group,
                                                                                                      1
                                                                                                    ).transfers
                                                                                                  ) > 0 do %>
                      · {failed(elem(group, 1).transfers)} failed
                    <% end %>
                  </span>
                  <.status status={elem(group, 1).status} />
                  <.icon name="hero-chevron-down" class="w-4 h-4 opacity-50" />
                </div>
              </summary>

              <ul class="px-4 pb-4 space-y-2">
                <li :for={transfer <- elem(group, 1).transfers}>
                  <.link
                    navigate={~p"/transfers/#{transfer.id}"}
                    class="card bg-base-100 hover:bg-base-300 transition-colors block"
                  >
                    <.transfer_row transfer={transfer} />
                  </.link>
                </li>
              </ul>
            </details>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # A batch member and a lone transfer read identically, so the row is one
  # component rather than two that drift.
  attr :transfer, :map, required: true

  defp transfer_row(assigns) do
    ~H"""
    <div class="card-body py-4 flex-row items-center justify-between gap-4">
      <div class="min-w-0">
        <p class="font-medium truncate">
          {@transfer.source_playlist_name || @transfer.source_playlist_id}
        </p>
        <p class="text-sm opacity-70">
          {Connection.display_name(@transfer.source_provider)} → {Connection.display_name(@transfer.destination_provider)}
        </p>
      </div>

      <div class="flex items-center gap-4 shrink-0">
        <.counts :if={@transfer.total_tracks > 0} transfer={@transfer} />
        <.status status={@transfer.status} />
      </div>
    </div>
    """
  end

  defp done(transfers), do: Enum.count(transfers, &(&1.status in [:completed, :failed]))
  defp failed(transfers), do: Enum.count(transfers, &(&1.status == :failed))

  attr :status, :atom, required: true

  defp status(assigns) do
    ~H"""
    <span class={[
      "badge",
      @status == :completed && "badge-success",
      @status == :failed && "badge-error",
      @status == :running && "badge-info",
      @status == :partial && "badge-warning",
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
