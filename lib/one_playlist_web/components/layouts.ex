defmodule OnePlaylistWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use OnePlaylistWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar border-b border-base-300 px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <.link navigate={~p"/"} class="flex w-fit items-center gap-2 text-lg font-semibold">
          <.icon name="hero-queue-list" class="w-6 h-6 text-primary" /> One Playlist
        </.link>
      </div>

      <nav class="flex-none">
        <ul class="flex items-center gap-1 sm:gap-2">
          <%!-- Signed out, there is nothing behind these but a redirect back to
                here, so they are not offered. --%>
          <li :if={@current_scope}>
            <.link navigate={~p"/transfers"} class="btn btn-ghost btn-sm">Transfers</.link>
          </li>
          <li :if={@current_scope}>
            <.link navigate={~p"/connections"} class="btn btn-ghost btn-sm">
              <.icon name="hero-link" class="w-4 h-4" />
              <span class="hidden sm:inline">Connections</span>
            </.link>
          </li>
          <li>
            <.theme_toggle />
          </li>
          <li :if={@current_scope && dev_routes?()}>
            <.link href="/dev/sign-out" class="btn btn-ghost btn-sm">Sign out</.link>
          </li>
          <li :if={!@current_scope && dev_routes?()}>
            <.link href="/dev/sign-in" class="btn btn-primary btn-sm">Sign in</.link>
          </li>
        </ul>
      </nav>
    </header>

    <main class="px-4 py-10 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-4xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  # Sign-in is `OnePlaylistWeb.DevAuthController` scaffolding, routed only under
  # `:dev_routes` — so the link is both hidden at runtime and written as a plain
  # string rather than `~p`, because a verified route that exists in no
  # environment but `:dev` is a compile warning everywhere else. When Supabase
  # Auth lands, this becomes a real sign-in link and the guard goes away.
  defp dev_routes?, do: Application.get_env(:one_playlist, :dev_routes, false)

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
