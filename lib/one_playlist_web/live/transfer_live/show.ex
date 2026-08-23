defmodule OnePlaylistWeb.TransferLive.Show do
  @moduledoc """
  One transfer: its progress while it runs, and its report when it is done.

  ## The report is the feature

  `docs/reference/domain.md` argues that a per-track report with the reason is
  worth more than another platform integration, because the loudest complaint
  about every competing tool is a wrong or missing track that nobody was told
  about. So the unmatched rows are shown first, with what was tried and how
  close it came — not hidden behind a filter.

  Progress arrives by PubSub rather than polling: the run happens in an Oban
  worker, possibly on another node, and broadcasts each state change.
  """

  use OnePlaylistWeb, :live_view

  alias OnePlaylist.Transfers
  alias OnePlaylist.Transfers.Transfer

  require Logger

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Transfers.fetch(id) do
      {:ok, transfer} ->
        if connected?(socket), do: watch(id)

        {:ok, socket |> assign_transfer(transfer) |> assign(:filter, :all)}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "That transfer no longer exists.")
         |> push_navigate(to: ~p"/transfers")}
    end
  end

  @impl true
  def handle_info({:transfer_updated, transfer}, socket) do
    {:noreply, assign_transfer(socket, transfer)}
  end

  @impl true
  def handle_event("filter", %{"outcome" => outcome}, socket) do
    filter = String.to_existing_atom(outcome)

    {:noreply,
     socket
     |> assign(:filter, filter)
     |> stream(:items, items(socket.assigns.transfer, filter), reset: true)}
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
            <h1 class="text-2xl font-semibold truncate">
              {@transfer.source_playlist_name || @transfer.source_playlist_id}
            </h1>
            <p class="text-sm opacity-70">
              {@transfer.source_provider} → {@transfer.destination_provider}
            </p>
          </div>

          <span class={[
            "badge badge-lg shrink-0",
            @transfer.status == :completed && "badge-success",
            @transfer.status == :failed && "badge-error",
            @transfer.status == :running && "badge-info",
            @transfer.status == :pending && "badge-ghost"
          ]}>
            {@transfer.status}
          </span>
        </div>

        <div :if={@transfer.status in [:pending, :running]} class="mb-6">
          <div class="flex items-center gap-3 text-sm opacity-70">
            <span class="loading loading-spinner loading-sm"></span>
            <span>
              {if @transfer.status == :pending,
                do: "Queued.",
                else: "Reading the playlist and resolving tracks…"}
            </span>
          </div>
        </div>

        <div :if={@transfer.last_error} class="alert alert-error mb-6">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <span class="break-all">{@transfer.last_error}</span>
        </div>

        <div :if={@transfer.total_tracks > 0} class="stats bg-base-200 w-full mb-6">
          <.stat label="Tracks" value={@transfer.total_tracks} />
          <.stat
            label="Matched"
            value={@transfer.matched_count}
            detail={"#{matched_percentage(@transfer)}% of the source"}
          />
          <.stat label="Added" value={@transfer.added_count} />
          <.stat
            label="Unmatched"
            value={@transfer.unmatched_count}
            tone={@transfer.unmatched_count > 0 && "text-warning"}
          />
        </div>

        <div :if={@transfer.total_tracks > 0}>
          <div role="tablist" class="tabs tabs-bordered mb-2">
            <button
              :for={{value, label} <- filters(@transfer)}
              role="tab"
              phx-click="filter"
              phx-value-outcome={value}
              class={["tab", @filter == value && "tab-active"]}
            >
              {label}
            </button>
          </div>

          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th class="w-10">#</th>
                  <th>Track</th>
                  <th>Outcome</th>
                  <th>Why</th>
                </tr>
              </thead>
              <tbody id="items" phx-update="stream">
                <tr :for={{dom_id, item} <- @streams.items} id={dom_id}>
                  <td class="tabular-nums opacity-50">{item.position + 1}</td>
                  <td>
                    <div class="font-medium">{item.source_title || item.source_track_id}</div>
                    <div class="text-xs opacity-60">{item.source_artist}</div>
                  </td>
                  <td><.outcome outcome={item.outcome} /></td>
                  <td class="text-xs opacity-70"><.why item={item} /></td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :any, default: nil

  attr :detail, :string, default: nil

  defp stat(assigns) do
    ~H"""
    <div class="stat">
      <div class="stat-title">{@label}</div>
      <div class={["stat-value text-3xl tabular-nums", @tone]}>{@value}</div>
      <div :if={@detail} class="stat-desc">{@detail}</div>
    </div>
    """
  end

  # `Transfer.match_rate/1` answers in `0.0..1.0`; this is the only place that
  # turns it into something a person reads, and the rounding is deliberately
  # asymmetric at both ends.
  #
  # A transfer that lost one track in a thousand must not render as `100%`, and
  # one that matched one in a thousand must not render as `0%`. Either would be
  # this application telling the exact lie it exists to prevent — a report that
  # looks like a clean sweep or a total failure when it was neither. So only a
  # genuine 1.0 reaches 100 and only a genuine 0.0 reaches 0; everything between
  # is clamped into 1..99.
  defp matched_percentage(%Transfer{} = transfer) do
    # Guards rather than float literals: Elixir rightly warns that matching on
    # `0.0` matches only positive zero.
    case Transfer.match_rate(transfer) do
      rate when rate <= 0.0 -> 0
      rate when rate >= 1.0 -> 100
      rate -> rate |> Kernel.*(100) |> floor() |> max(1) |> min(99)
    end
  end

  attr :outcome, :atom, required: true

  defp outcome(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      @outcome == :matched && "badge-success",
      @outcome == :already_present && "badge-ghost",
      @outcome == :unmatched && "badge-warning"
    ]}>
      {@outcome |> to_string() |> String.replace("_", " ")}
    </span>
    """
  end

  attr :item, :map, required: true

  # The column that makes the report worth reading. A matched row says how it
  # was decided; an unmatched one says what was tried and how close it came,
  # which is the difference between "not found" and "found and refused".
  defp why(assigns) do
    ~H"""
    <span :if={@item.outcome != :unmatched}>
      {@item.strategy} · {@item.confidence}
    </span>
    <span :if={@item.outcome == :unmatched}>
      {reason_text(@item)}
    </span>
    """
  end

  defp reason_text(%{reason: "no_candidates"}), do: "nothing found on the destination"

  defp reason_text(%{reason: "all_rejected", candidates_considered: n}),
    do: "#{n || "some"} found, each a different recording"

  defp reason_text(%{reason: "below_threshold", score: score}) when is_float(score),
    do: "closest match scored #{Float.round(score, 2)}"

  defp reason_text(%{reason: "unsearchable"}), do: "too little information to search"
  defp reason_text(%{reason: reason}), do: reason

  defp filters(%Transfer{} = transfer) do
    [
      {:all, "All #{transfer.total_tracks}"},
      {:unmatched, "Unmatched #{transfer.unmatched_count}"},
      {:matched, "Added #{transfer.added_count}"},
      {:already_present, "Already there"}
    ]
  end

  defp assign_transfer(socket, transfer) do
    filter = socket.assigns[:filter] || :all

    socket
    |> assign(:transfer, transfer)
    |> assign(:page_title, transfer.source_playlist_name || "Transfer")
    |> stream(:items, items(transfer, filter), reset: true)
  end

  # Only on the connected mount: the static render has no channel to deliver a
  # broadcast to, and subscribing there would leak a subscription per page load.
  # The result is matched rather than discarded so a failure to subscribe is
  # visible — the page would otherwise sit on a stale transfer forever, looking
  # like a transfer that had stopped.
  defp watch(id) do
    case Transfers.subscribe(id) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("not watching transfer #{id}: #{inspect(reason)}")
    end
  end

  defp items(transfer, :all), do: Transfers.items(transfer)
  defp items(transfer, outcome), do: Transfers.items(transfer, outcome: outcome)
end
