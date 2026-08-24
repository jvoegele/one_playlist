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

  ## Reordering is two buttons, not a drag

  Up and down move an entry one place, which is a swap of two `position` values
  and needs no renumbering. A drag would be nicer and needs a JS hook plus a
  client-side ordering to reconcile against; this is the honest version of the
  feature rather than a worse version of a better one, and the context function
  underneath is the same either way.
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

  def handle_event("move", %{"entry" => entry_id, "direction" => direction}, socket)
      when direction in ~w(up down) do
    entries =
      Library.move_entry(
        socket.assigns.current_user_id,
        socket.assigns.playlist.id,
        entry_id,
        String.to_existing_atom(direction)
      )

    {:noreply, assign(socket, :entries, entries)}
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

        <ul :if={@entries != []} class="space-y-1">
          <li
            :for={{entry, index} <- Enum.with_index(@entries)}
            class="card bg-base-200"
            id={"entry-#{entry.id}"}
          >
            <div class="card-body py-2 flex-row items-center gap-3">
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
                  phx-click="move"
                  phx-value-entry={entry.id}
                  phx-value-direction="up"
                  disabled={index == 0}
                  class="btn btn-ghost btn-xs"
                  aria-label="Move up"
                >
                  <.icon name="hero-chevron-up" class="w-4 h-4" />
                </button>
                <button
                  phx-click="move"
                  phx-value-entry={entry.id}
                  phx-value-direction="down"
                  disabled={index == length(@entries) - 1}
                  class="btn btn-ghost btn-xs"
                  aria-label="Move down"
                >
                  <.icon name="hero-chevron-down" class="w-4 h-4" />
                </button>
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
            {if @entry.enriched?, do: "not found", else: "not looked up yet"}
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
      :unidentified -> "MusicBrainz does not have this recording"
      :waiting -> "Waiting to be looked up"
    end
  end

  # Only says something when there is something to say. An identified recording
  # carrying an ISRC is the ordinary case and gets no third line.
  defp note(entry) do
    case {state(entry), entry.track.isrc} do
      {:waiting, _isrc} -> "waiting to be looked up"
      {:unidentified, _isrc} -> "not found at MusicBrainz"
      {:identified, nil} -> "MusicBrainz has no ISRC for this recording"
      {:identified, _isrc} -> nil
    end
  end

  defp expanded?(expanded, entry), do: MapSet.member?(expanded, entry.id)

  defp duration(seconds) when is_integer(seconds) do
    "#{div(seconds, 60)}:#{String.pad_leading(to_string(rem(seconds, 60)), 2, "0")}"
  end

  defp load_entries(socket) do
    entries = Library.entries(socket.assigns.current_user_id, socket.assigns.playlist.id)

    socket
    |> assign(:entries, entries)
    |> assign(:identified, Enum.count(entries, &is_binary(&1.track.isrc)))
    |> assign(:pending, Enum.count(entries, &(not &1.enriched?)))
  end
end
