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
    delete "/sign-out", SessionController, :delete

    # Where every emailed sign-in link and every Google redirect lands. Two
    # things about its placement are deliberate. It is declared **before**
    # `/auth/:provider` below, because routes match in order and that segment
    # would otherwise swallow it as a provider named "callback". And it is
    # outside `redirect_if_authenticated`: a signed-in person clicking a sign-in
    # link should get the account the link names, not be bounced away from it.
    # It is also in GoTrue's redirect allowlist — `additional_redirect_urls` in
    # supabase/config.toml — which is why the path is this one and not another.
    get "/auth/callback", SessionController, :callback
  end

  # The pages a signed-in user has no business seeing. `redirect_if_authenticated`
  # sends them on rather than offering a password field they do not need.
  scope "/", OnePlaylistWeb do
    pipe_through [:browser, :redirect_if_authenticated]

    get "/sign-in", SessionController, :new
    post "/sign-in", SessionController, :create
    post "/sign-in/magic-link", SessionController, :send_magic_link
    post "/sign-in/code", SessionController, :verify_code
    post "/sign-in/google", SessionController, :google
    get "/sign-up", RegistrationController, :new
    post "/sign-up", RegistrationController, :create
  end

  # Everything here belongs to somebody: a connection carries a credential, and
  # a transfer's report is the user's own library. None of it has a meaningful
  # signed-out rendering.
  scope "/", OnePlaylistWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated,
      on_mount: [{OnePlaylistWeb.UserAuth, :require_authenticated}] do
      live "/connections", ConnectionLive.Index, :index
      live "/playlists", PlaylistLive.Index, :index
      live "/playlists/:id", PlaylistLive.Show, :show
      live "/transfers", TransferLive.Index, :index
      live "/syncs", SyncLive.Index, :index
      live "/transfers/new", TransferLive.New, :new
      live "/transfers/batch/:id", TransferLive.Batch, :show
      live "/imports/new", ImportLive.New, :new
      live "/exports/new", ExportLive.New, :new
      live "/transfers/:id", TransferLive.Show, :show
    end
  end

  scope "/auth", OnePlaylistWeb do
    # Connecting a music service acts on behalf of a specific user, so these
    # require a signed-in one. The callback included: an unauthenticated
    # callback has no account to attach the connection to.
    pipe_through [:browser, :require_authenticated_user]

    # One pair for every provider, with the segment as a parameter — so
    # `~p"/auth/\#{provider}"` verifies against the router instead of having to
    # be written out per provider. See OnePlaylistWeb.OAuthController.
    get "/:provider", OAuthController, :start
    get "/:provider/callback", OAuthController, :callback
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
  end
end
