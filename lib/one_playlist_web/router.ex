defmodule OnePlaylistWeb.Router do
  use OnePlaylistWeb, :router

  import OnePlaylistWeb.UserAuth

  # Built at compile time from config so dev can allow what LiveReload needs
  # (a ws: connection and its iframe) without loosening the deployed policy.
  @csp Application.compile_env!(:one_playlist, :content_security_policy)

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OnePlaylistWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", OnePlaylistWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/auth", OnePlaylistWeb do
    # Connecting a music service acts on behalf of a specific user, so these
    # require a signed-in one. The callback included: an unauthenticated
    # callback has no account to attach the connection to.
    pipe_through [:browser, :require_authenticated_user]

    get "/tidal", TidalAuthController, :start
    get "/tidal/callback", TidalAuthController, :callback
  end

  # Other scopes may use custom stacks.
  # scope "/api", OnePlaylistWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:one_playlist, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: OnePlaylistWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    # Scaffolding: signs in a fixed development user so provider connections
    # have someone to belong to. Remove with OnePlaylistWeb.DevAuthController
    # once Supabase Auth sign-in exists.
    scope "/dev", OnePlaylistWeb do
      pipe_through :browser

      get "/sign-in", DevAuthController, :create
      get "/sign-out", DevAuthController, :delete
    end
  end
end
