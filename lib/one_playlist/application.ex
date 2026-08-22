defmodule OnePlaylist.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      OnePlaylistWeb.Telemetry,
      # Must precede the Repo: encrypted Ecto types resolve their cipher through
      # the vault, so it has to be up before any query can load or dump a field.
      OnePlaylist.Vault,
      OnePlaylist.Repo,
      {DNSCluster, query: Application.get_env(:one_playlist, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: OnePlaylist.PubSub},
      # Guarded front doors for outbound provider calls. The child-spec options
      # are deep merged with the module's own, which is how the test environment
      # takes the mechanisms off the clock without a second module.
      {OnePlaylist.Providers.Tidal.Service,
       Application.get_env(:one_playlist, :tidal_service_opts, [])},
      # Mutations get their own front door: TIDAL rate-limits them an order of
      # magnitude harder than reads, and one limiter sized for both is sized
      # wrong for one of them. See Tidal.WriteService.
      {OnePlaylist.Providers.Tidal.WriteService,
       Application.get_env(:one_playlist, :tidal_service_opts, [])},
      # L1 of the catalogue cache and the coordinator that stops concurrent
      # misses on one key becoming N provider calls. Both must precede anything
      # that serves a request; neither is load-bearing if absent.
      OnePlaylist.Cache,
      OnePlaylist.Cache.Singleflight,
      # Start a worker by calling: OnePlaylist.Worker.start_link(arg)
      # {OnePlaylist.Worker, arg},
      # Start to serve requests, typically the last entry
      OnePlaylistWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: OnePlaylist.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OnePlaylistWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
