defmodule OnePlaylistWeb.PlaylistLive.Show do
  @moduledoc """
  One library playlist, and the editing of it.

  `docs/reference/domain.md` §5's L2. The first screen in this application where
  a user *changes* something rather than watching a pipeline report what it did.

  ## Entries, not tracks

  Every action here names an **entry** — the row joining a playlist to a
  recording — rather than the recording itself. A playlist may legitimately hold
  the same recording twice, so "remove this" and "move this" are questions a
  recording id cannot answer. That is also why removing here is
  `OnePlaylist.Library.remove_entry/3` and not the adapter's `remove_tracks/4`,
  which takes recordings and deliberately removes every occurrence.

  ## "No confident match" is not "not found"

  The marker for an unidentified recording said **not found at MusicBrainz**,
  and that asserts something usually untrue. Most of these were found: the
  search returns the right recording, often ranked first, and the ladder then
  declines it because the stored album carries a subtitle the catalogue does not
  use and nothing else corroborates. *Footsteps* from *Lost Dogs: Rarities and B
  Sides* comes back at rank one and is declined at `0.860`.

  A user reading "not found" concludes the catalogue is missing a record it
  holds, and reports a matching bug that is really a scoring decision. The
  wording now says what actually happened. Saying *which* — nothing returned, or
  returned and declined — would be better still and needs enrichment to record
  the reason; that is a column and a decision, not a rename.

  ## What "identified by ISRC" is doing in the header

  The count is the honest measure of what
  `OnePlaylist.Library.Enrichment` buys. Everything else it fills in is
  cosmetic — an album name, a cover, a length — but an ISRC is what makes a
  track exactly matchable at every service, so a playlist where all of them
  carry one will transfer perfectly and one where none do will not.

  It is also why the number moves on its own: enrichment is a background job on
  a queue of one, so a freshly imported playlist starts low and climbs.

  **"Missing an ISRC" and "not looked up yet" are different, and the first
  version of this conflated them.** It inferred "still being looked up" from a
  track having no ISRC, so a playlist whose every recording had been resolved —
  MusicBrainz simply having no ISRC for thirteen live cuts and soundtrack
  appearances — reported that it was still working, permanently. Enrichment
  looked broken while it was in fact finished and correct.

  So the sentence is driven by `enriched?`, which says whether MusicBrainz has
  been *asked*, and the terminal state says so plainly rather than trailing off.

  ## Reordering is a drag, and the server still decides the order

  It began as two chevron buttons per row, which was the honest small version.
  It stopped being honest when enrichment added a *second* chevron for expanding
  a row: three chevrons in one row, two of which reorder and one of which does
  not, is a worse interface than either feature deserves.

  So reordering is a drag from a handle, and the two things that usually go
  wrong with that are avoided deliberately.

  **The hook does not reorder the list.** `AGENTS.md` requires
  `phx-update="ignore"` on a hook that manages its own DOM, and that would stop
  this list re-rendering at all — no removals, no expanded detail, no enrichment
  landing while the page is open. Instead the hook reports *what was dropped
  where*, as an entry and a neighbour, and `OnePlaylist.Library.place_entry/5`
  computes the order. A client that submitted a whole ordering would be trusted
  to have got it right; this one cannot say anything the server does not check.

  **The handle is a button, not a grip.** Reordering by dragging alone is
  reordering nobody can do without a mouse. Focusing a handle and pressing the
  arrow keys moves that row, through the same `move_entry/4` the chevrons used —
  so the keyboard path is not a reimplementation, it is the original one with a
  different trigger.

  One limitation, stated rather than discovered later: this is the HTML5 drag
  API, which does not fire on touch. A phone reorders with the keyboard path or
  not at all. Fixing that means pointer events and a hand-written drag, or a
  vendored library, and neither is worth it before somebody asks.
  """

  use OnePlaylistWeb, :live_view

  alias OnePlaylist.Library

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Library.fetch_playlist(socket.assigns.current_user_id, id) do
      {:ok, playlist} ->
        {:ok,
         socket
         |> assign(:playlist, playlist)
         |> assign(:page_title, playlist.name)
         |> assign(:renaming?, false)
         |> assign(:expanded, MapSet.new())
         |> load_entries()}

      # Indistinguishable from a playlist that never existed, exactly as
      # `TransferLive.Show` treats somebody else's transfer.
      :error ->
        {:ok,
         socket
         |> put_flash(:error, "That playlist is not in your library.")
         |> push_navigate(to: ~p"/playlists")}
    end
  end

  @impl true
  def handle_event("place", %{"entry" => entry, "target" => target, "side" => side}, socket)
      when side in ["before", "after"] do
    entries =
      Library.place_entry(
        socket.assigns.current_user_id,
        socket.assigns.playlist.id,
        entry,
        target,
        String.to_existing_atom(side)
      )

    {:noreply, assign_entries(socket, entries)}
  end

  # The keyboard path, and the reason the drag handle is a `<button>` rather than
  # a decorative grip: reordering by dragging alone is reordering nobody can do
  # without a mouse. Focus a handle and the arrow keys move that row, using the
  # same `move_entry/4` the two chevrons used to.
  def handle_event("move_by_key", %{"key" => key, "entry" => entry_id}, socket)
      when key in ["ArrowUp", "ArrowDown"] do
    direction = if key == "ArrowUp", do: :up, else: :down

    entries =
      Library.move_entry(
        socket.assigns.current_user_id,
        socket.assigns.playlist.id,
        entry_id,
        direction
      )

    {:noreply, assign_entries(socket, entries)}
  end

  def handle_event("move_by_key", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_detail", %{"entry" => entry_id}, socket) do
    expanded = socket.assigns.expanded

    toggled =
      if MapSet.member?(expanded, entry_id) do
        MapSet.delete(expanded, entry_id)
      else
        MapSet.put(expanded, entry_id)
      end

    {:noreply, assign(socket, :expanded, toggled)}
  end

  def handle_event("rename", _params, socket), do: {:noreply, assign(socket, :renaming?, true)}

  def handle_event("cancel_rename", _params, socket),
    do: {:noreply, assign(socket, :renaming?, false)}

  def handle_event("save_name", %{"name" => name}, socket) do
    user_id = socket.assigns.current_user_id
    playlist = socket.assigns.playlist

    case Library.update_playlist(user_id, playlist.id, %{name: String.trim(name)}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:playlist, updated)
         |> assign(:page_title, updated.name)
         |> assign(:renaming?, false)
         |> assign(:expanded, MapSet.new())}

      _otherwise ->
        {:noreply, put_flash(socket, :error, "A playlist needs a name.")}
    end
  end

  def handle_event("remove", %{"entry" => entry_id}, socket) do
    user_id = socket.assigns.current_user_id
    playlist = socket.assigns.playlist

    case Library.remove_entry(user_id, playlist.id, entry_id) do
      :ok ->
        {:noreply, load_entries(socket)}

      :error ->
        # Two tabs, or a double click. The entry is not there and the user asked
        # for it not to be there, so the page is refreshed rather than scolded.
        {:noreply, load_entries(socket)}
    end
  end

  def handle_event("delete", _params, socket) do
    case Library.delete_playlist(socket.assigns.current_user_id, socket.assigns.playlist.id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Deleted #{socket.assigns.playlist.name}.")
         |> push_navigate(to: ~p"/playlists")}

      :error ->
        {:noreply, put_flash(socket, :error, "That playlist could not be deleted.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-3xl">
        <.link navigate={~p"/playlists"} class="btn btn-ghost btn-sm mb-4">
          <.icon name="hero-arrow-left" class="w-4 h-4" /> My playlists
        </.link>

        <div class="flex items-start justify-between gap-4 mb-6">
          <div class="min-w-0 flex-1">
            <form :if={@renaming?} phx-submit="save_name" class="flex gap-2">
              <input
                type="text"
                name="name"
                value={@playlist.name}
                autocomplete="off"
                required
                class="input input-bordered flex-1"
              />
              <button type="submit" class="btn btn-primary btn-sm">Save</button>
              <button type="button" phx-click="cancel_rename" class="btn btn-ghost btn-sm">
                Cancel
              </button>
            </form>

            <div :if={!@renaming?} class="flex items-center gap-2 min-w-0">
              <h1 class="text-2xl font-semibold truncate">{@playlist.name}</h1>
              <button phx-click="rename" class="btn btn-ghost btn-xs" aria-label="Rename">
                <.icon name="hero-pencil" class="w-4 h-4" />
              </button>
            </div>

            <p class="text-sm opacity-70">
              {length(@entries)} {if length(@entries) == 1, do: "track", else: "tracks"} · in One Playlist
            </p>
            <p :if={@entries != []} class="text-xs opacity-60 mt-1">
              {@identified} of {length(@entries)} identified by ISRC
              <span :if={@pending > 0}>· {@pending} still being looked up</span>
              <span :if={@pending == 0 and @identified < length(@entries)}>
                · MusicBrainz has no ISRC for the other {length(@entries) - @identified}
              </span>
            </p>
          </div>

          <button
            phx-click="delete"
            data-confirm={"Delete #{@playlist.name}? The tracks stay in your library; only this playlist goes."}
            class="btn btn-ghost btn-sm text-error shrink-0"
          >
            <.icon name="hero-trash" class="w-4 h-4" />
            <span class="hidden sm:inline">Delete</span>
          </button>
        </div>

        <div :if={@entries == []} class="text-center py-16 opacity-70">
          <p>Nothing in here yet.</p>
          <p class="text-sm mt-1">
            <.link navigate={~p"/transfers/new"} class="link">Transfer a playlist in</.link>
            or <.link navigate={~p"/imports/new"} class="link">import a file</.link>.
          </p>
        </div>

        <ul :if={@entries != []} id="entries" phx-hook=".DragToReorder" class="space-y-1">
          <li
            :for={{entry, index} <- Enum.with_index(@entries)}
            class="card bg-base-200 border-2 border-transparent"
            id={"entry-#{entry.id}"}
            data-entry={entry.id}
          >
            <div class="card-body py-2 flex-row items-center gap-3">
              <button
                id={"handle-#{entry.id}"}
                data-drag-handle
                phx-keydown="move_by_key"
                phx-value-entry={entry.id}
                class="btn btn-ghost btn-xs cursor-grab active:cursor-grabbing shrink-0 opacity-40 hover:opacity-100"
                aria-label={"Reorder #{entry.track.title}. Drag, or use the arrow keys."}
              >
                <.icon name="hero-bars-2" class="w-4 h-4" />
              </button>

              <span class="tabular-nums opacity-50 w-8 shrink-0">{index + 1}</span>

              <div class="w-10 h-10 shrink-0">
                <img
                  :if={entry.track.artwork_url}
                  src={entry.track.artwork_url}
                  alt=""
                  class="w-10 h-10 rounded object-cover"
                />
              </div>

              <div class="min-w-0 flex-1">
                <div class="font-medium truncate">{entry.track.title}</div>
                <div class="text-xs opacity-60 truncate">
                  {Enum.join(entry.track.artists, ", ")}
                  <span :if={entry.track.album}>
                    · <em>{entry.track.album}</em>
                  </span>
                  <span :if={entry.track.duration_seconds}>
                    · {duration(entry.track.duration_seconds)}
                  </span>
                </div>
                <div :if={note(entry)} class="text-xs opacity-50 mt-0.5 truncate">
                  {note(entry)}
                </div>
              </div>

              <div class="flex items-center gap-1 shrink-0">
                <span title={marker_title(entry)} aria-label={marker_title(entry)}>
                  <.icon name={marker_icon(entry)} class={"w-4 h-4 " <> marker_class(entry)} />
                </span>

                <button
                  phx-click="toggle_detail"
                  phx-value-entry={entry.id}
                  class="btn btn-ghost btn-xs"
                  aria-expanded={to_string(expanded?(@expanded, entry))}
                  aria-label="What is known about this recording"
                >
                  <.icon
                    name={if expanded?(@expanded, entry), do: "hero-chevron-up", else: "hero-chevron-down"}
                    class="w-4 h-4"
                  />
                </button>
              </div>

              <div class="flex items-center gap-1 shrink-0">
                <button
                  phx-click="remove"
                  phx-value-entry={entry.id}
                  class="btn btn-ghost btn-xs text-error"
                  aria-label="Remove"
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>
            </div>

            <.detail :if={expanded?(@expanded, entry)} entry={entry} />
          </li>
        </ul>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DragToReorder">
        // Deliberately does *not* reorder the list itself. `AGENTS.md` requires
        // `phx-update="ignore"` on a hook that manages its own DOM, and that
        // would stop the list re-rendering at all — no removals, no expanded
        // detail, no enrichment landing. So this reports where the drop
        // happened and lets the server decide the order, which is also what
        // keeps a client from submitting an ordering of its own invention.
        //
        // The only DOM it touches is a highlight class on the row being hovered,
        // and that is safe because no patch can arrive mid-drag: nothing is
        // pushed until the drop.
        const EDGE = "border-primary"

        export default {
          mounted() { this.bind() },

          bind() {
            let dragging = null
            let over = null
            let side = "before"

            const clear = () => {
              if (over) { over.classList.remove(EDGE, "border-t-2", "border-b-2") }
              over = null
            }

            // HTML5 drag needs `draggable` on the row, but a row that is always
            // draggable cannot have its text selected. So it is granted on the
            // handle and taken back at the end.
            this.el.addEventListener("pointerdown", e => {
              const handle = e.target.closest("[data-drag-handle]")
              if (handle) { handle.closest("li").draggable = true }
            })

            this.el.addEventListener("dragstart", e => {
              dragging = e.target.closest("li")
              if (!dragging) return
              dragging.classList.add("opacity-40")
              e.dataTransfer.effectAllowed = "move"
              // Firefox will not start a drag without data on the transfer.
              e.dataTransfer.setData("text/plain", dragging.dataset.entry)
            })

            this.el.addEventListener("dragover", e => {
              const row = e.target.closest("li")
              if (!dragging || !row || row === dragging) return
              e.preventDefault()

              const box = row.getBoundingClientRect()
              side = (e.clientY - box.top) / box.height > 0.5 ? "after" : "before"

              if (over !== row) { clear(); over = row }
              row.classList.add(EDGE)
              row.classList.toggle("border-t-2", side === "before")
              row.classList.toggle("border-b-2", side === "after")
            })

            this.el.addEventListener("drop", e => {
              e.preventDefault()
              if (!dragging || !over) return
              this.pushEvent("place", {
                entry: dragging.dataset.entry,
                target: over.dataset.entry,
                side: side
              })
            })

            // A focused button still scrolls the page on an arrow key, which
            // makes keyboard reordering unusable on a long playlist. The server
            // handles the move; this only stops the browser also scrolling.
            this.el.addEventListener("keydown", e => {
              if (e.target.closest("[data-drag-handle]") &&
                  (e.key === "ArrowUp" || e.key === "ArrowDown")) {
                e.preventDefault()
              }
            })

            this.el.addEventListener("dragend", () => {
              if (dragging) {
                dragging.classList.remove("opacity-40")
                dragging.draggable = false
              }
              clear()
              dragging = null
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :entry, :map, required: true

  defp detail(assigns) do
    ~H"""
    <div class="px-4 pb-3 -mt-1">
      <dl class="grid grid-cols-[7rem_1fr] gap-x-3 gap-y-1 text-xs bg-base-100 rounded p-3">
        <.fact label="ISRC" value={@entry.track.isrc} missing="none at MusicBrainz" />

        <dt class="opacity-60">MusicBrainz</dt>
        <dd class="font-mono break-all">
          <a
            :if={@entry.musicbrainz.recording_id}
            href={"https://musicbrainz.org/recording/#{@entry.musicbrainz.recording_id}"}
            target="_blank"
            rel="noopener noreferrer"
            class="link"
          >
            {@entry.musicbrainz.recording_id}
          </a>
          <span :if={!@entry.musicbrainz.recording_id} class="opacity-40 font-sans">
            {if @entry.enriched?, do: "no confident match", else: "not looked up yet"}
          </span>
        </dd>

        <.fact label="Album" value={@entry.track.album} />
        <.fact label="Barcode" value={@entry.track.album_upc} />

        <dt :if={@entry.musicbrainz.release_id} class="opacity-60">Release</dt>
        <dd :if={@entry.musicbrainz.release_id} class="font-mono break-all">
          <a
            href={"https://musicbrainz.org/release/#{@entry.musicbrainz.release_id}"}
            target="_blank"
            rel="noopener noreferrer"
            class="link"
          >
            {@entry.musicbrainz.release_id}
          </a>
        </dd>

        <.fact
          label="Length"
          value={@entry.track.duration_seconds && duration(@entry.track.duration_seconds)}
        />

        <dt class="opacity-60">Looked up</dt>
        <dd>
          <span :if={@entry.musicbrainz.looked_up_at}>
            {Calendar.strftime(@entry.musicbrainz.looked_up_at, "%d %b %Y, %H:%M UTC")}
          </span>
          <span :if={!@entry.musicbrainz.looked_up_at} class="opacity-40">
            queued — enrichment runs one recording a second
          </span>
        </dd>
      </dl>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, default: nil
  attr :missing, :string, default: "—"

  defp fact(assigns) do
    ~H"""
    <dt class="opacity-60">{@label}</dt>
    <dd class={if @value, do: "break-all", else: "opacity-40"}>{@value || @missing}</dd>
    """
  end

  # Three states, because there are three. Collapsing "not asked" into "nothing
  # found" is the bug this screen already shipped once.
  defp state(%{enriched?: false}), do: :waiting
  defp state(%{musicbrainz: %{recording_id: nil}}), do: :unidentified
  defp state(_entry), do: :identified

  defp marker_icon(entry) do
    case state(entry) do
      :identified -> "hero-check-circle"
      :unidentified -> "hero-minus-circle"
      :waiting -> "hero-clock"
    end
  end

  defp marker_class(entry) do
    case state(entry) do
      :identified -> "text-success/70"
      :unidentified -> "opacity-30"
      :waiting -> "opacity-40"
    end
  end

  defp marker_title(entry) do
    case state(entry) do
      :identified -> "Identified at MusicBrainz"
      :unidentified -> "No confident match at MusicBrainz"
      :waiting -> "Waiting to be looked up"
    end
  end

  # Only says something when there is something to say. An identified recording
  # carrying an ISRC is the ordinary case and gets no third line.
  defp note(entry) do
    case {state(entry), entry.track.isrc} do
      {:waiting, _isrc} -> "waiting to be looked up"
      {:unidentified, _isrc} -> "no confident match at MusicBrainz"
      {:identified, nil} -> "MusicBrainz has no ISRC for this recording"
      {:identified, _isrc} -> nil
    end
  end

  defp expanded?(expanded, entry), do: MapSet.member?(expanded, entry.id)

  defp duration(seconds) when is_integer(seconds) do
    "#{div(seconds, 60)}:#{String.pad_leading(to_string(rem(seconds, 60)), 2, "0")}"
  end

  defp load_entries(socket) do
    assign_entries(
      socket,
      Library.entries(socket.assigns.current_user_id, socket.assigns.playlist.id)
    )
  end

  # The header counts are derived from the entries, so they are assigned in the
  # same place. Reordering does not change either, but a removal does, and a
  # caller that assigned only `:entries` would leave the header stale.
  defp assign_entries(socket, entries) do
    socket
    |> assign(:entries, entries)
    |> assign(:identified, Enum.count(entries, &is_binary(&1.track.isrc)))
    |> assign(:pending, Enum.count(entries, &(not &1.enriched?)))
  end
end
