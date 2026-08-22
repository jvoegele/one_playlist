defmodule OnePlaylistWeb.ConnectionLive.Index do
  @moduledoc """
  The services this user has connected, and how to connect another.

  Until this existed, a Subsonic server could only be attached by running
  `dev/navidrome/connect.exs` against a live node — which made the second
  provider real for the developer and invisible to everybody else. It is the
  first screen where the two providers look genuinely different, because they
  are: one is an OAuth redirect, the other is a form.

  ## Connecting is asynchronous, and says so

  Saving a Subsonic connection calls the user's server first (see
  `OnePlaylist.Providers.connect_subsonic/2`). That is a real network round trip
  to an address that may be wrong, switched off, or on the other side of a VPN —
  `OnePlaylist.Providers.Subsonic.Service` gives it about ten seconds before it
  gives up. Doing that inside `handle_event/3` would block this LiveView's
  process for the duration, freezing the whole page including the flash and the
  nav. `start_async/3` keeps the page alive and lets the button say what is
  happening.

  ## The password is never sent back

  The form has no `phx-change`, so an in-progress password is not sent on every
  keystroke, and the password input is explicitly given `value={nil}` so that a
  failed submission does not put the secret into the HTML the server renders —
  where it would reach the page source, the websocket payload of every later
  patch, and any logging in between. The errors still render, because they live
  on the changeset rather than on the value.

  Note what this does *not* do: the box on screen still shows what the user
  typed. That value is the browser's own — removing a `value` attribute does not
  clear a DOM property somebody entered — and it never left their machine. Which
  is the useful behaviour anyway: a rejected credential usually means one of the
  three fields is wrong, and clearing the password would make the user retype it
  to find out which.
  """

  use OnePlaylistWeb, :live_view

  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.SubsonicCredentials

  require Errata
  require Logger

  # Presentation only — what a person needs to read to decide whether to click.
  # Which of these are actually *offered* comes from
  # `Providers.supported_providers/0`, so a provider gaining an adapter cannot be
  # silently missing from this page and one listed here without an adapter cannot
  # be clicked.
  #
  # A function rather than a module attribute because `~p` may only appear inside
  # one. `:connect_path` is written out per provider rather than interpolated,
  # since `~p"/auth/#{provider}"` cannot be verified against a router that spells
  # the segment out — and compile-time verification is the last thing to give up
  # on the one button whose whole job is to leave the application.
  defp catalogue do
    %{
      tidal: %{
        name: "TIDAL",
        blurb: "Playlists, albums and liked tracks. Sign in with your TIDAL account.",
        kind: :oauth,
        connect_path: ~p"/auth/tidal",
        icon: "hero-musical-note"
      },
      navidrome: %{
        name: "Subsonic server",
        blurb:
          "Navidrome, Airsonic, Gonic or Subsonic itself — your own server, " <>
            "with no quota and no allowlist.",
        kind: :form,
        icon: "hero-server-stack"
      }
    }
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Connections")
     |> assign(:form_open?, false)
     |> assign(:connecting?, false)
     |> assign(:connect_error, nil)
     |> assign_form()
     |> load_connections()}
  end

  @impl true
  def handle_event("open_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form_open?, true)
     |> assign(:connect_error, nil)
     |> assign_form()}
  end

  def handle_event("close_form", _params, socket) do
    {:noreply, assign(socket, form_open?: false, connect_error: nil)}
  end

  def handle_event("connect_subsonic", %{"subsonic" => params}, socket) do
    user_id = socket.assigns.current_user_id

    case SubsonicCredentials.apply(params) do
      {:ok, credentials} ->
        {:noreply,
         socket
         |> assign(connecting?: true, connect_error: nil)
         |> start_async(:connect_subsonic, fn ->
           Providers.connect_subsonic(user_id, credentials)
         end)}

      {:error, changeset} ->
        # Nothing was sent anywhere. A malformed URL is worth catching here
        # rather than spending ten seconds discovering that `ftp://` is not a
        # music server.
        {:noreply,
         socket |> assign(:form, to_form(changeset, as: :subsonic)) |> stop_connecting()}
    end
  end

  def handle_event("disconnect", %{"provider" => provider}, socket) do
    # Never `String.to_atom/1` on a value from the client. Matching against the
    # schema's own list is both the check and the conversion.
    case Enum.find(Connection.providers(), &(to_string(&1) == provider)) do
      nil ->
        {:noreply, put_flash(socket, :error, "That is not a service this application knows.")}

      provider ->
        # A `ConnectionNotFound` here means it is already gone — two tabs, or a
        # double click. The user asked for it to not be connected, and it is not
        # connected, so that is a success with nothing left to do.
        _ = Providers.disconnect(socket.assigns.current_user_id, provider)

        {:noreply,
         socket
         |> put_flash(:info, "Disconnected #{name_of(provider)}.")
         |> load_connections()}
    end
  end

  @impl true
  def handle_async(:connect_subsonic, {:ok, {:ok, connection}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Connected to #{connection.display_name || "your music server"}.")
     |> assign(form_open?: false)
     |> assign_form()
     |> stop_connecting()
     |> load_connections()}
  end

  def handle_async(:connect_subsonic, {:ok, {:error, %Ecto.Changeset{} = changeset}}, socket) do
    # The credential worked and the row would not save — a constraint, not the
    # user's typing. Rare enough that the changeset errors are the honest thing
    # to show rather than a rewritten sentence.
    {:noreply, socket |> assign(:form, to_form(changeset, as: :subsonic)) |> stop_connecting()}
  end

  def handle_async(:connect_subsonic, {:ok, {:error, error}}, socket) do
    {:noreply, socket |> assign(:connect_error, message_for(error)) |> stop_connecting()}
  end

  def handle_async(:connect_subsonic, {:exit, reason}, socket) do
    Logger.error("connecting a Subsonic server crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:connect_error, "Something went wrong reaching that server. Please try again.")
     |> stop_connecting()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-3xl">
        <.header>
          Connections
          <:subtitle>
            A transfer needs two of these: somewhere to read from, and somewhere to write to.
          </:subtitle>
        </.header>

        <div class="space-y-3 mt-6">
          <.service_card
            :for={service <- @services}
            service={service}
            connection={@connections[service.provider]}
            form={@form}
            form_open?={@form_open? and service.kind == :form}
            connecting?={@connecting?}
            connect_error={@connect_error}
          />
        </div>

        <div class="mt-10 text-sm opacity-60">
          <p>
            Other services are not here yet for reasons that are not about effort:
            Apple Music needs a paid developer membership and a browser-side token,
            Spotify caps new applications at five people, and Deezer no longer issues
            API keys at all.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :service, :map, required: true
  attr :connection, :any, required: true
  attr :form, :any, required: true
  attr :form_open?, :boolean, required: true
  attr :connecting?, :boolean, required: true
  attr :connect_error, :any, required: true

  defp service_card(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body py-5">
        <div class="flex items-start justify-between gap-4">
          <div class="flex items-start gap-3 min-w-0">
            <.icon name={@service.icon} class="w-6 h-6 mt-0.5 shrink-0 opacity-70" />
            <div class="min-w-0">
              <p class="font-medium">{@service.name}</p>
              <p :if={@connection} class="text-sm opacity-70 truncate">
                {@connection.display_name || @connection.provider_user_id}
                <span :if={@connection.server_url}>— {@connection.server_url}</span>
              </p>
              <p :if={is_nil(@connection)} class="text-sm opacity-70">{@service.blurb}</p>
            </div>
          </div>

          <div class="shrink-0">
            <.connected_actions :if={@connection} service={@service} connection={@connection} />
            <.connect_action
              :if={is_nil(@connection)}
              service={@service}
              form_open?={@form_open?}
              connecting?={@connecting?}
            />
          </div>
        </div>

        <.subsonic_form
          :if={@form_open? and is_nil(@connection)}
          form={@form}
          connecting?={@connecting?}
          connect_error={@connect_error}
        />
      </div>
    </div>
    """
  end

  attr :service, :map, required: true
  attr :connection, :map, required: true

  defp connected_actions(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class={[
        "badge",
        @connection.status == :active && "badge-success",
        @connection.status != :active && "badge-warning"
      ]}>
        {if @connection.status == :active, do: "Connected", else: @connection.status}
      </span>

      <button
        type="button"
        phx-click="disconnect"
        phx-value-provider={@connection.provider}
        data-confirm={"Disconnect #{@service.name}? Transfers using it will stop working until you reconnect."}
        class="btn btn-ghost btn-sm"
      >
        Disconnect
      </button>
    </div>
    """
  end

  attr :service, :map, required: true
  attr :form_open?, :boolean, required: true
  attr :connecting?, :boolean, required: true

  defp connect_action(%{service: %{kind: :oauth}} = assigns) do
    ~H"""
    <.link href={@service.connect_path} class="btn btn-primary btn-sm">
      Connect
    </.link>
    """
  end

  defp connect_action(%{service: %{kind: :form}} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click={if @form_open?, do: "close_form", else: "open_form"}
      disabled={@connecting?}
      class={["btn btn-sm", @form_open? && "btn-ghost", !@form_open? && "btn-primary"]}
    >
      {if @form_open?, do: "Cancel", else: "Connect"}
    </button>
    """
  end

  attr :form, :any, required: true
  attr :connecting?, :boolean, required: true
  attr :connect_error, :any, required: true

  defp subsonic_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="subsonic-connect-form"
      phx-submit="connect_subsonic"
      class="mt-4 pt-4 border-t border-base-300"
    >
      <div
        :if={@connect_error}
        class="alert alert-error mb-4"
        id="subsonic-connect-error"
        role="alert"
      >
        <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
        <span>{@connect_error}</span>
      </div>

      <.input
        field={@form[:server_url]}
        label="Server address"
        placeholder="http://192.168.1.10:4533"
        autocomplete="url"
        required
      />

      <div class="grid gap-x-4 sm:grid-cols-2">
        <.input field={@form[:username]} label="Username" autocomplete="username" required />
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          value={nil}
          autocomplete="current-password"
          required
        />
      </div>

      <.input
        field={@form[:display_name]}
        label="Name for this server (optional)"
        placeholder="Living room Pi"
      />

      <p class="text-xs opacity-60 mt-1">
        Your password is encrypted before it is stored, and is never sent to your
        server in the clear — each request carries a fresh salted hash instead.
      </p>

      <div class="mt-4 flex justify-end gap-2">
        <button type="button" phx-click="close_form" class="btn btn-ghost btn-sm">Cancel</button>
        <button type="submit" disabled={@connecting?} class="btn btn-primary btn-sm">
          <span :if={@connecting?} class="loading loading-spinner loading-xs"></span>
          {if @connecting?, do: "Checking the server…", else: "Connect"}
        </button>
      </div>
    </.form>
    """
  end

  defp assign_form(socket) do
    assign(socket, :form, to_form(SubsonicCredentials.changeset(%{}), as: :subsonic))
  end

  defp stop_connecting(socket), do: assign(socket, :connecting?, false)

  # `RetriesExhausted` says only that retrying did not help, so unwrap to the
  # failure the user can act on — "connection refused" names the problem;
  # "gave up after 3 attempts" names our reaction to it.
  defp message_for(error) do
    case Providers.root_cause(error) do
      # `APIError`'s own wording for this is "reconnect to continue", which is
      # right where it is usually read — a transfer failing on a credential that
      # used to work. On *this* screen there is nothing to reconnect: the user is
      # looking at the three fields they just typed, and needs to be told which
      # kind of thing was wrong.
      %{reason: :unauthorized} ->
        "Your server rejected that username and password. Check both, " <>
          "and that this account can sign in to the server itself."

      cause when Errata.is_error(cause) ->
        Errata.display_message(cause) || Exception.message(cause)

      _unrecognised ->
        "Could not reach that server."
    end
  end

  defp load_connections(socket) do
    connections =
      socket.assigns.current_user_id
      |> Providers.list_connections()
      |> Map.new(&{&1.provider, &1})

    socket
    |> assign(:connections, connections)
    |> assign(:services, services())
  end

  defp services do
    entries = catalogue()

    Providers.supported_providers()
    |> Enum.flat_map(fn provider ->
      case Map.fetch(entries, provider) do
        {:ok, entry} -> [Map.put(entry, :provider, provider)]
        :error -> []
      end
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp name_of(provider) do
    case Map.fetch(catalogue(), provider) do
      {:ok, %{name: name}} -> name
      :error -> to_string(provider)
    end
  end
end
