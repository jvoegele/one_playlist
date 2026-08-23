defmodule OnePlaylistWeb.ImportLive.New do
  @moduledoc """
  Uploading a playlist file and turning it into a transfer.

  ## The upload is consumed in the request, not queued

  `OnePlaylist.Imports.import/4` parses the file, stores it and creates the
  transfer before this handler returns, which is why a bad file can be shown as
  a form error at all. A worker could not do the work — it has no session, and
  therefore no way to reach Storage without the service key — and if it could,
  the user would learn about a malformed row by going to look at a failed job.

  So the slow part a person waits for here is a parse and one upload of a file
  they just chose. The provider calls and the matching are still the job's.

  ## The destination list is the connections list

  A transfer needs somewhere to put the tracks, and "somewhere" means a service
  this user has actually connected. Offering every provider this application
  knows about would produce a form whose only outcome is `ConnectionNotFound`.
  """

  use OnePlaylistWeb, :live_view

  alias OnePlaylist.Formats
  alias OnePlaylist.Imports
  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Connection

  # Comfortably above a real playlist and below the bucket's own 5 MiB limit, so
  # an oversized file is refused by the browser with a useful message rather than
  # by Storage with an opaque one.
  @max_bytes 4 * 1024 * 1024

  @impl true
  def mount(_params, _session, socket) do
    connections = Providers.list_connections(socket.assigns.current_user_id)

    {:ok,
     socket
     |> assign(:page_title, "Import a playlist")
     |> assign(:max_bytes, @max_bytes)
     |> assign(:connections, connections)
     |> assign(:destination, default_destination(connections))
     |> assign(:error, nil)
     |> assign(:importing?, false)
     |> allow_upload(:playlist,
       accept: accepted_extensions(),
       max_entries: 1,
       max_file_size: @max_bytes
     )}
  end

  @impl true
  def handle_event("validate", %{"destination" => destination}, socket) do
    {:noreply, socket |> assign(:destination, destination) |> assign(:error, nil)}
  end

  def handle_event("validate", _params, socket), do: {:noreply, assign(socket, :error, nil)}

  def handle_event("cancel", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :playlist, ref)}
  end

  def handle_event("import", _params, %{assigns: %{destination: nil}} = socket) do
    {:noreply, assign(socket, :error, "Connect a music service first.")}
  end

  # Sobelow flags the `File.read!/1` below as directory traversal, at low
  # confidence. `path` is not a value anybody sends us: it is the temporary file
  # LiveView wrote the upload into, handed back by `consume_uploaded_entries/3`
  # for exactly this purpose. What the user *does* control is `entry.client_name`,
  # which never reaches the filesystem — it picks a format by extension and is
  # sanitised into a storage key by `OnePlaylist.Storage.path_for/3`.
  #
  # Skipped by name so every other traversal finding in this file still fails
  # the build.
  # sobelow_skip ["Traversal.FileModule"]
  def handle_event("import", _params, socket) do
    # `to_existing_atom` rather than `to_atom`: the value arrives from a form,
    # and the select is rendered from the user's own connections, so a submitted
    # provider that names no existing atom is a forged request rather than a
    # choice. Raising is the right answer to that.
    destination = String.to_existing_atom(to_string(socket.assigns.destination))

    # `consume_uploaded_entries/3` returns a list because an upload may allow
    # several; this one allows exactly one, so the list is empty or a single
    # result. An empty list means the form was submitted with nothing attached.
    socket
    |> consume_uploaded_entries(:playlist, fn %{path: path}, entry ->
      {:ok,
       Imports.import(
         socket.assigns.current_session,
         entry.client_name,
         File.read!(path),
         destination
       )}
    end)
    |> case do
      [{:ok, transfer}] ->
        {:noreply,
         socket
         |> put_flash(:info, "Imported #{transfer.source_playlist_name}. Matching now.")
         |> push_navigate(to: ~p"/transfers/#{transfer.id}")}

      [{:error, reason}] ->
        {:noreply, assign(socket, :error, describe(reason))}

      [] ->
        {:noreply, assign(socket, :error, "Choose a file to import.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-xl mx-auto">
        <div class="mb-8">
          <h1 class="text-2xl font-semibold">Import a playlist</h1>
          <p class="text-sm opacity-70">
            Upload a {Enum.join(Enum.map(Formats.known(), &String.upcase(to_string(&1))), " or ")} exported from another service, and we will match every track.
          </p>
        </div>

        <div :if={@connections == []} class="alert alert-warning mb-6" role="alert">
          <.icon name="hero-link-slash" class="w-5 h-5 shrink-0" />
          <div>
            <p class="font-semibold">No music service connected.</p>
            <p class="text-sm">
              An import needs somewhere to put the tracks. <.link navigate={~p"/connections"} class="link">Connect one first</.link>.
            </p>
          </div>
        </div>

        <div :if={@error} class="alert alert-error mb-6" id="import-error" role="alert">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
          <span>{@error}</span>
        </div>

        <form id="import-form" phx-submit="import" phx-change="validate">
          <div
            class="border-2 border-dashed border-base-300 rounded-box p-8 text-center"
            phx-drop-target={@uploads.playlist.ref}
          >
            <.icon name="hero-document-arrow-up" class="w-8 h-8 mx-auto mb-3 opacity-60" />
            <.live_file_input upload={@uploads.playlist} class="file-input file-input-bordered" />
            <p class="text-xs opacity-60 mt-3">Up to {div(@max_bytes, 1024 * 1024)} MB.</p>
          </div>

          <%!-- Client-side refusals, shown before anything is uploaded. --%>
          <div :for={entry <- @uploads.playlist.entries} class="mt-4">
            <div class="flex items-center justify-between gap-3">
              <span class="truncate text-sm">{entry.client_name}</span>
              <button
                type="button"
                phx-click="cancel"
                phx-value-ref={entry.ref}
                class="btn btn-ghost btn-xs"
              >
                Remove
              </button>
            </div>

            <p :for={err <- upload_errors(@uploads.playlist, entry)} class="text-error text-sm mt-1">
              {upload_error_to_string(err)}
            </p>
          </div>

          <div :if={@connections != []} class="mt-6">
            <label class="label" for="destination">
              <span class="label-text">Put the tracks in</span>
            </label>
            <select id="destination" name="destination" class="select select-bordered w-full">
              <option :for={connection <- @connections} value={connection.provider}>
                {Connection.label(connection)}
              </option>
            </select>
          </div>

          <div class="mt-6 flex justify-end gap-2">
            <.link navigate={~p"/transfers"} class="btn btn-ghost">Cancel</.link>
            <button
              type="submit"
              disabled={@connections == [] or @uploads.playlist.entries == []}
              class="btn btn-primary"
            >
              Import
            </button>
          </div>
        </form>
      </div>
    </Layouts.app>
    """
  end

  defp default_destination([]), do: nil
  defp default_destination([connection | _rest]), do: connection.provider

  # Every format the codecs claim, as the file input's `accept` list. Derived
  # rather than written out, so adding a format does not leave a picker that
  # refuses files the application can now read.
  defp accepted_extensions do
    Enum.flat_map(Formats.known(), fn format ->
      {:ok, codec} = Formats.codec(format)
      Enum.map(codec.extensions(), &".#{&1}")
    end)
  end

  # `UnreadablePlaylist` says something a person can act on — which row is wrong,
  # or which formats are known. A changeset here would mean the transfer itself
  # was rejected, which is our problem rather than theirs.
  defp describe(%Ecto.Changeset{}), do: "That import could not be started. Please try again."
  defp describe(error) when is_exception(error), do: Errata.display_message(error)
  defp describe(other), do: inspect(other)

  defp upload_error_to_string(:too_large), do: "That file is too large."
  defp upload_error_to_string(:not_accepted), do: "We can only read CSV files."
  defp upload_error_to_string(:too_many_files), do: "One file at a time."
  defp upload_error_to_string(_error), do: "That file could not be uploaded."
end
