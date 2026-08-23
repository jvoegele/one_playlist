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

  ## Two different size limits, for two different problems

  A finished report is **paged**: `@page_size` rows at a time, with the rest
  behind "Load more". A 5,000 track transfer otherwise puts 5,000 table rows in
  the initial payload, which is slow to render and most of it is never scrolled
  to.

  A running report is **windowed**: the stream keeps only the most recent
  `@live_window` rows, and drops the older ones. That is not pagination and
  should not be — a run in flight has nothing worth paging back through, and
  every row it has ever shown is about to be replaced by the real report anyway.
  The window is what keeps a long run's memory flat in the LiveView process and
  in the browser.
  """

  use OnePlaylistWeb, :live_view

  alias OnePlaylist.Providers.Connection

  alias OnePlaylist.Transfers
  alias OnePlaylist.Transfers.Transfer

  require Logger

  # One screenful and then some. Big enough that a typical playlist needs no
  # paging at all, small enough that the initial render of a large one is not
  # dominated by rows nobody scrolls to.
  @page_size 100

  # The live window is the same size deliberately: a run showing more rows than
  # a page holds would shrink when the report replaced it, which reads as rows
  # being lost.
  @live_window 100

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # Scoped to the signed-in user. `Transfers.fetch/2` answers `:error` for
    # somebody else's transfer just as it does for one that does not exist, so
    # the branch below covers both without telling the two apart.
    case Transfers.fetch(socket.assigns.current_user_id, id) do
      {:ok, transfer} ->
        if connected?(socket), do: watch(id)

        {:ok,
         socket
         |> assign(:filter, :all)
         # `nil` until the first report arrives, which reads as "Starting…"
         # rather than as zero of zero.
         |> assign(:progress, nil)
         # Position => provisional row, for the rows a run has reported but not
         # yet persisted. Assigned before `assign_transfer/2`, which reads it,
         # and bounded to `@live_window` by `remember/2`.
         |> assign(:provisional, %{})
         |> assign_transfer(transfer)}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "That transfer no longer exists.")
         |> push_navigate(to: ~p"/transfers")}
    end
  end

  @impl true
  def handle_info({:transfer_progress, progress}, socket) do
    socket = assign(socket, :progress, %{resolved: progress.resolved, total: progress.total})

    # Rows appear as their tracks resolve, rather than every row appearing at
    # once when the run ends. Keyed on position, so the persisted report replaces
    # these in place instead of doubling the table.
    #
    # A batch rather than one row: `OnePlaylist.Transfers.Progress` decides how
    # many arrive together, so that a 5,000 track run is not 5,000 messages.
    {:noreply, Enum.reduce(progress.items, socket, &live_row(&2, &1))}
  end

  def handle_info({:transfer_updated, transfer}, socket) do
    {:noreply, socket |> forget_provisional_once_final(transfer) |> assign_transfer(transfer)}
  end

  @impl true
  def handle_event("delete", _params, socket) do
    # `Transfers.delete/2` is scoped by the session, so a forged id belonging to
    # somebody else answers exactly as a missing one does — which is why both
    # land in the same branch here rather than being told apart.
    case Transfers.delete(socket.assigns.current_session, socket.assigns.transfer.id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Transfer deleted.")
         |> push_navigate(to: ~p"/transfers")}

      :error ->
        {:noreply, put_flash(socket, :error, "That transfer could not be deleted.")}
    end
  end

  def handle_event("filter", %{"outcome" => outcome}, socket) do
    # Each filter is its own sequence of rows, so switching starts again at the
    # top rather than carrying the previous filter's offset into it.
    {:noreply, socket |> assign(:filter, String.to_existing_atom(outcome)) |> load_first_page()}
  end

  def handle_event("load-more", _params, socket) do
    {:noreply, load_next_page(socket)}
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
              {Connection.display_name(@transfer.source_provider)} → {Connection.display_name(
                @transfer.destination_provider
              )}
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

        <%!-- Only while a run is in flight. A finished transfer has counters,
              which say more than a full bar does. --%>
        <div :if={@transfer.status in [:pending, :running]} class="mb-6">
          <div class="flex items-center justify-between text-sm mb-2">
            <span class="opacity-70">
              {if @progress, do: "Matching track #{@progress.resolved} of #{@progress.total}", else: "Starting…"}
            </span>
            <span :if={@progress} class="opacity-70 tabular-nums">
              {round(@progress.resolved / max(@progress.total, 1) * 100)}%
            </span>
          </div>

          <progress
            class="progress progress-primary w-full"
            value={(@progress && @progress.resolved) || 0}
            max={(@progress && @progress.total) || 1}
          ></progress>
        </div>

        <%!-- `data-confirm` rather than a modal. A transfer takes provider
                calls to rebuild and its report is not reproducible, so the one
                irreversible action on this page should cost a deliberate
                click. --%>
        <button
          phx-click="delete"
          data-confirm={"Delete #{@transfer.source_playlist_name || "this transfer"} and its report?"}
          class="btn btn-ghost btn-sm text-error shrink-0"
        >
          <.icon name="hero-trash" class="w-4 h-4" />
          <span class="hidden sm:inline">Delete</span>
        </button>

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

        <%!-- `@progress` as well as the counters, because `total_tracks` is not
              persisted until the run finishes: gating on it alone kept the
              table hidden for exactly the period the live rows are for. --%>
        <div :if={@transfer.total_tracks > 0 or @progress}>
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

          <%!-- Only for a finished report. A run in flight is windowed rather
                than paged, so there is no "rest" to ask for: the rows scrolled
                off are about to be replaced wholesale by the real report. --%>
          <div :if={@more?} class="flex items-center justify-center gap-3 mt-4">
            <span class="text-sm opacity-60 tabular-nums">
              Showing {@loaded} of {shown_total(@transfer, @filter)}
            </span>
            <button phx-click="load-more" class="btn btn-sm btn-ghost">
              Load more
            </button>
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

  # What the current filter's tab already counts, so "Showing 100 of 4,812" and
  # the tab above it cannot disagree. `:already_present` has no counter of its
  # own — it is `matched - added` — which is also why its tab carries no number.
  defp shown_total(%Transfer{} = transfer, :all), do: transfer.total_tracks
  defp shown_total(%Transfer{} = transfer, :unmatched), do: transfer.unmatched_count
  defp shown_total(%Transfer{} = transfer, :matched), do: transfer.added_count

  defp shown_total(%Transfer{} = transfer, :already_present),
    do: transfer.matched_count - transfer.added_count

  defp filters(%Transfer{} = transfer) do
    [
      {:all, "All #{transfer.total_tracks}"},
      {:unmatched, "Unmatched #{transfer.unmatched_count}"},
      {:matched, "Added #{transfer.added_count}"},
      {:already_present, "Already there"}
    ]
  end

  defp assign_transfer(socket, transfer) do
    socket
    |> assign(:transfer, transfer)
    |> assign(:page_title, transfer.source_playlist_name || "Transfer")
    |> load_first_page()
  end

  # Replaces whatever was on screen with the first page of the current filter.
  # `reset: true` is what makes this safe to call on every transfer update: the
  # rows are rebuilt from the database rather than accumulated.
  defp load_first_page(socket) do
    {rows, more?} = page(socket.assigns.transfer, socket.assigns.filter, 0)

    socket
    |> stream(:items, rows, reset: true, dom_id: &row_id/1)
    |> assign(:loaded, length(rows))
    |> assign(:more?, more?)
    |> restore_provisional(rows)
  end

  defp load_next_page(socket) do
    {rows, more?} = page(socket.assigns.transfer, socket.assigns.filter, socket.assigns.loaded)

    socket
    |> stream(:items, rows, dom_id: &row_id/1)
    |> assign(:loaded, socket.assigns.loaded + length(rows))
    |> assign(:more?, more?)
  end

  # Asks for one row more than a page holds, and reports whether it came back.
  # That is cheaper than a `count(*)` over the report and cannot disagree with
  # it: the extra row either exists or it does not.
  defp page(transfer, filter, offset) do
    rows = items(transfer, filter, limit: @page_size + 1, offset: offset)

    case rows do
      [_ | _] = rows when length(rows) > @page_size -> {Enum.take(rows, @page_size), true}
      rows -> {rows, false}
    end
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

  # A track's position in the source playlist identifies its row for the whole
  # life of the page: first as a provisional result broadcast during the run,
  # then as the persisted `TransferItem` that replaces it.
  defp row_id(item), do: "item-#{item.position}"

  # One provisional row: remembered so a filter change does not lose it, and
  # appended to the table if the current filter admits it.
  defp live_row(socket, item) do
    socket |> remember(item) |> insert_if_shown(item)
  end

  # Bounded, because this map is held by the LiveView process for the whole run.
  # Unbounded it grew one entry per resolved track, which is exactly the thing
  # this change exists to stop. The oldest positions go first: a watcher looking
  # at a run in flight is looking at the end of it.
  defp remember(socket, item) do
    provisional = Map.put(socket.assigns.provisional, item.position, item)

    provisional =
      if map_size(provisional) > @live_window do
        Map.delete(provisional, provisional |> Map.keys() |> Enum.min())
      else
        provisional
      end

    assign(socket, :provisional, provisional)
  end

  # `limit: -@live_window` keeps the most recent rows and drops the rest, which
  # is the browser-side half of the same bound. Negative because we append
  # (`at: -1`) and it is the newest rows that are worth keeping.
  #
  # Only on this path. The paged report must not be windowed, or "Load more"
  # would evict the rows it just scrolled past.
  defp insert_if_shown(socket, item) do
    if shown?(item, socket.assigns.filter),
      do: stream_insert(socket, :items, item, at: -1, limit: -@live_window),
      else: socket
  end

  # A finished run has persisted a real `TransferItem` for every position, so the
  # provisional rows are not merely redundant — they are potentially wrong.
  # `provisional_item/3` reports `:matched` for anything that resolved, and a
  # track that turns out to be in the destination already is recorded as
  # `:already_present`. Keeping it would leave a stale row visible under a filter
  # the real one does not belong to.
  defp forget_provisional_once_final(socket, %Transfer{status: status} = _transfer)
       when status in [:pending, :running],
       do: socket

  defp forget_provisional_once_final(socket, _transfer), do: assign(socket, :provisional, %{})

  # Provisional rows that the persisted report has not superseded, in position
  # order, so a mid-run filter change does not wipe what the watcher has seen.
  defp restore_provisional(socket, persisted) do
    covered = MapSet.new(persisted, & &1.position)

    socket.assigns.provisional
    |> Map.values()
    |> Enum.reject(&MapSet.member?(covered, &1.position))
    |> Enum.sort_by(& &1.position)
    |> Enum.reduce(socket, &insert_if_shown(&2, &1))
  end

  defp shown?(_item, :all), do: true
  defp shown?(item, outcome), do: item.outcome == outcome

  defp items(transfer, :all, opts), do: Transfers.items(transfer, opts)
  defp items(transfer, outcome, opts), do: Transfers.items(transfer, [outcome: outcome] ++ opts)
end
