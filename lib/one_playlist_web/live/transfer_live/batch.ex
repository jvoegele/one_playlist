defmodule OnePlaylistWeb.TransferLive.Batch do
  @moduledoc """
  One batch: the playlists that were transferred together, and how they went.

  `/transfers` collapses a batch to a single row, which answers "how is it
  going" and nothing else. This is where the rest of the questions live: which
  playlist failed, what it said, and **run the failed ones again** without
  opening forty reports to find them.

  ## Only the failed ones are re-run

  A batch of forty where two hit a rate limit wants those two. Re-running the
  thirty-eight that worked is safe — `OnePlaylist.Transfers.Runner.run/1`
  re-reads the destination and writes what is missing — but each would spend a
  full transfer's worth of a rate-limited provider's quota to discover it has
  nothing to do.
  """

  use OnePlaylistWeb, :live_view
  use Bond

  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Transfers

  @post whenever(
          {:ok, mounted} <- result,
          every_member_is_shown:
            is_nil(mounted.assigns[:transfers]) or
              length(mounted.assigns.transfers) == mounted.assigns.total
        )
  @impl true
  def mount(%{"id" => batch_id}, _session, socket) do
    case Transfers.fetch_batch(socket.assigns.current_user_id, batch_id) do
      {:ok, transfers} ->
        {:ok,
         socket
         |> assign(:page_title, "Batch")
         |> assign(:batch_id, batch_id)
         |> assign_batch(transfers)}

      # Indistinguishable from a batch that never existed, exactly as
      # `TransferLive.Show` treats somebody else's transfer.
      :error ->
        {:ok,
         socket
         |> put_flash(:error, "That batch no longer exists.")
         |> push_navigate(to: ~p"/transfers")}
    end
  end

  @impl true
  def handle_event("retry_failed", _params, socket) do
    retried = Transfers.retry_failed(socket.assigns.transfers)

    {:ok, transfers} =
      Transfers.fetch_batch(socket.assigns.current_user_id, socket.assigns.batch_id)

    {:noreply,
     socket
     |> put_flash(:info, "Queued #{retried} #{playlist_word(retried)} again.")
     |> assign_batch(transfers)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-4xl">
        <.link navigate={~p"/transfers"} class="btn btn-ghost btn-sm mb-4">
          <.icon name="hero-arrow-left" class="w-4 h-4" /> Transfers
        </.link>

        <div class="flex items-start justify-between gap-4 mb-6">
          <div class="min-w-0">
            <h1 class="text-2xl font-semibold">{@total} playlists</h1>
            <p class="text-sm opacity-70">
              {Connection.display_name(@source_provider)} → {Connection.display_name(@destination_provider)}
            </p>
          </div>

          <button
            :if={@failed > 0}
            type="button"
            phx-click="retry_failed"
            class="btn btn-sm shrink-0"
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Run {@failed} failed again
          </button>
        </div>

        <div class="stats stats-horizontal bg-base-200 w-full mb-6">
          <div class="stat">
            <div class="stat-title">Done</div>
            <div class="stat-value text-2xl tabular-nums">{@done}/{@total}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Tracks added</div>
            <div class="stat-value text-2xl tabular-nums">{@added}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Unmatched</div>
            <div class={["stat-value text-2xl tabular-nums", @unmatched > 0 && "text-warning"]}>
              {@unmatched}
            </div>
          </div>
          <div class="stat">
            <div class="stat-title">Failed</div>
            <div class={["stat-value text-2xl tabular-nums", @failed > 0 && "text-error"]}>
              {@failed}
            </div>
          </div>
        </div>

        <ul class="space-y-2">
          <li :for={transfer <- @transfers}>
            <.link
              navigate={~p"/transfers/#{transfer.id}"}
              class="card bg-base-200 hover:bg-base-300 transition-colors block"
            >
              <div class="card-body py-3 flex-row items-center justify-between gap-4">
                <div class="min-w-0">
                  <p class="font-medium truncate">
                    {transfer.source_playlist_name || transfer.source_playlist_id}
                  </p>
                  <p :if={transfer.last_error} class="text-sm text-error truncate">
                    {transfer.last_error}
                  </p>
                </div>

                <div class="flex items-center gap-4 shrink-0">
                  <span :if={transfer.total_tracks > 0} class="text-sm tabular-nums opacity-70">
                    {transfer.matched_count}/{transfer.total_tracks} matched
                  </span>
                  <span class={[
                    "badge",
                    transfer.status == :completed && "badge-success",
                    transfer.status == :failed && "badge-error",
                    transfer.status == :running && "badge-info",
                    transfer.status == :pending && "badge-ghost"
                  ]}>
                    {transfer.status}
                  </span>
                </div>
              </div>
            </.link>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  # Every number this screen shows is derived from the members rather than
  # stored, which is the whole reason a batch is a column and not a table — see
  # the migration.
  defp assign_batch(socket, transfers) do
    first = hd(transfers)

    socket
    |> assign(:transfers, transfers)
    |> assign(:total, length(transfers))
    |> assign(:done, Enum.count(transfers, &(&1.status in [:completed, :failed])))
    |> assign(:failed, Enum.count(transfers, &(&1.status == :failed)))
    |> assign(:added, Enum.sum(Enum.map(transfers, & &1.added_count)))
    |> assign(:unmatched, Enum.sum(Enum.map(transfers, & &1.unmatched_count)))
    |> assign(:source_provider, first.source_provider)
    |> assign(:destination_provider, first.destination_provider)
  end

  defp playlist_word(1), do: "playlist"
  defp playlist_word(_many), do: "playlists"
end
