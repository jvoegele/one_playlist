defmodule OnePlaylistWeb.SyncLive.Index do
  @moduledoc """
  The standing instructions: what is being kept in step with what.

  ## A list and three verbs, deliberately

  Pause, resume and delete. There is no edit form, and that is a decision rather
  than an omission: the fields a user might want to change — the source, the
  destination — are the ones that make a sync a *different* sync, and the
  destination is pinned to a playlist the first run created. Changing the source
  of an existing schedule would leave that playlist holding two libraries mixed
  together, with nothing in the report to say why.

  So changing a sync means deleting it and setting up another, which is one
  extra click and cannot produce that outcome. Cadence is the one field that
  could safely be edited in place, and it is the one nobody asks to change.

  ## Nothing here is asynchronous

  Unlike `/playlists`, this page reads only its own table. No provider is
  contacted: the playlist names were captured when the sync was made, and a
  sync's history is the ordinary transfers list. A page about schedules that
  went blank because TIDAL was slow would be a page about TIDAL.
  """

  use OnePlaylistWeb, :live_view
  use Bond

  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Syncs
  alias OnePlaylist.Syncs.Sync

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Syncs")
     |> load_syncs()}
  end

  @impl true
  def handle_event("toggle", %{"id" => id, "enabled" => enabled}, socket) do
    {:ok, _sync} = Syncs.set_enabled(socket.assigns.current_user_id, id, enabled == "true")

    {:noreply, load_syncs(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    :ok = Syncs.delete(socket.assigns.current_user_id, id)

    {:noreply,
     socket
     |> put_flash(:info, "Sync deleted. The transfers it made are still there.")
     |> load_syncs()}
  end

  # The one law this page owes: it shows the signed-in user's syncs and nobody
  # else's. `Syncs.list/1` already promises it, and this promises it again after
  # the assign — the two are separated by exactly the kind of code that gets a
  # user id wrong, which is why restating it here is not redundant.
  #
  # Proven by mutation — but not by the obvious one. Passing a *random* id to
  # `Syncs.list/1` does not fire it: that user has no syncs, so the list comes
  # back empty and an empty list satisfies any `forall`. Replacing the scoped
  # read with `Repo.all(Sync)` does fire it, which is the fault actually worth
  # guarding: not a mistyped id, but a scoped read quietly becoming unscoped.
  @post shows_only_this_users_syncs:
          forall(
            sync <- result.assigns.syncs,
            sync.user_id == result.assigns.current_user_id
          )
  defp load_syncs(socket) do
    assign(socket, :syncs, Syncs.list(socket.assigns.current_user_id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-4xl">
        <div class="flex items-start justify-between gap-4 mb-6">
          <div>
            <h1 class="text-2xl font-semibold mb-1">Syncs</h1>
            <p class="text-sm opacity-70">
              Playlists kept in step. Each run is an ordinary transfer with its own report.
            </p>
          </div>

          <.link navigate={~p"/transfers/new"} class="btn btn-primary btn-sm shrink-0">
            <.icon name="hero-plus" class="w-4 h-4" /> New
          </.link>
        </div>

        <div :if={@syncs == []} class="text-center py-16">
          <.icon name="hero-arrow-path" class="w-10 h-10 mx-auto opacity-30 mb-3" />
          <p class="opacity-70 mb-1">Nothing is being synced yet.</p>
          <p class="text-sm opacity-50">
            Start a transfer and pick a cadence instead of <span class="italic">Just once</span>.
          </p>
        </div>

        <ul class="space-y-3">
          <li :for={sync <- @syncs} class="card bg-base-200">
            <div class="card-body py-4 gap-3">
              <div class="flex items-start justify-between gap-4">
                <div class="min-w-0">
                  <div class="flex items-center gap-2 flex-wrap">
                    <span class="font-medium truncate">
                      {sync.source_playlist_name || sync.source_playlist_id}
                    </span>
                    <.icon name="hero-arrow-right" class="w-4 h-4 opacity-40 shrink-0" />
                    <span class="opacity-70">
                      {Connection.display_name(sync.destination_provider)}
                    </span>
                    <span :if={not sync.enabled} class="badge badge-ghost badge-sm">Paused</span>
                  </div>

                  <p class="text-sm opacity-60 mt-1">
                    {cadence_label(sync.interval_minutes)} · from {Connection.display_name(sync.source_provider)} · {schedule_note(
                      sync
                    )}
                  </p>
                </div>

                <div class="flex items-center gap-1 shrink-0">
                  <.link
                    :if={sync.last_transfer_id}
                    navigate={~p"/transfers/#{sync.last_transfer_id}"}
                    class="btn btn-ghost btn-xs"
                  >
                    Last run
                  </.link>

                  <button
                    type="button"
                    phx-click="toggle"
                    phx-value-id={sync.id}
                    phx-value-enabled={to_string(not sync.enabled)}
                    class="btn btn-ghost btn-xs"
                  >
                    {if sync.enabled, do: "Pause", else: "Resume"}
                  </button>

                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={sync.id}
                    class="btn btn-ghost btn-xs text-error"
                  >
                    Delete
                  </button>
                </div>
              </div>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  # Reads back the four the picker offers, and degrades to minutes for anything
  # else — a row written before the list changed, which is exactly why
  # `interval_minutes` is a number rather than an enum.
  defp cadence_label(60), do: "Every hour"
  defp cadence_label(1440), do: "Every day"
  defp cadence_label(10_080), do: "Every week"
  defp cadence_label(minutes) when minutes < 1440, do: "Every #{div(minutes, 60)} hours"
  defp cadence_label(minutes), do: "Every #{div(minutes, 1440)} days"

  # A paused sync keeps its `next_run_at` so that resuming does not lose its
  # place — so saying "next run in two hours" under a **Paused** badge would be
  # a contradiction on the same line. It says what it will do when resumed
  # instead.
  defp schedule_note(%Sync{enabled: false}), do: "resumes on its next slot"
  defp schedule_note(%Sync{next_run_at: nil}), do: "not scheduled"

  defp schedule_note(%Sync{next_run_at: at}) do
    case DateTime.diff(at, DateTime.utc_now(), :minute) do
      minutes when minutes <= 0 -> "due now"
      minutes when minutes < 60 -> "next run in #{minutes} min"
      minutes when minutes < 1440 -> "next run in #{div(minutes, 60)}h"
      minutes -> "next run in #{div(minutes, 1440)}d"
    end
  end
end
