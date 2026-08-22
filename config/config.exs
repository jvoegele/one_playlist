# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :one_playlist,
  ecto_repos: [OnePlaylist.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :one_playlist, OnePlaylistWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: OnePlaylistWeb.ErrorHTML, json: OnePlaylistWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: OnePlaylist.PubSub,
  live_view: [signing_salt: "yiRVjJDl"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :one_playlist, OnePlaylist.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  one_playlist: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  one_playlist: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Keys whose values Errata replaces with "[REDACTED]" wherever it serializes an
# error context — logs, telemetry metadata, JSON responses. Redaction is
# recursive and matches atom and binary keys alike, so this also covers a
# "provider_token" buried inside a captured params map.
#
# This is a floor, not the whole story: an error context should not be handed a
# token in the first place. It is here because the cost of being wrong once is a
# user's music account.
config :errata,
  redact: [
    :access_token,
    :refresh_token,
    :provider_token,
    :provider_refresh_token,
    :client_secret,
    :password,
    :secret,
    :token,
    :api_key,
    :authorization
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
