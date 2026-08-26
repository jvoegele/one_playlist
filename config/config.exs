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

# The transfer/sync job pipeline.
#
# `prefix: "oban"` matches the migration: the job tables live in their own
# schema, off the surface PostgREST exposes, so this application never has to
# write RLS policies for columns Oban owns.
#
# One queue, sized low on purpose. A transfer is mostly waiting on a provider
# that rate-limits writes, so concurrency here buys nothing and costs quota —
# the limit that matters is in Tidal.WriteService, and running more workers just
# queues behind it.
config :one_playlist, Oban,
  repo: OnePlaylist.Repo,
  prefix: "oban",
  # `enrichment: 1` is not caution, it is arithmetic: MusicBrainz asks for one
  # request a second and `OnePlaylist.MusicBrainz.Service` enforces that for the
  # whole node, so a second worker could only wait inside the limiter while
  # holding a slot and a connection. See OnePlaylist.Library.EnrichmentWorker.
  queues: [transfers: 2, enrichment: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Rescues jobs orphaned by a node dying mid-run. Safe here only because the
    # runner is idempotent: a rescued transfer re-reads the destination and adds
    # what is missing. See Transfers.TransferWorker.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    # 04:00 UTC, well clear of the pg_cron pruning jobs. See
    # OnePlaylist.Library.EnrichmentSweeper for why this one is scheduled here
    # rather than in Postgres with the others.
    {Oban.Plugins.Cron,
     crontab: [
       {"0 4 * * *", OnePlaylist.Library.EnrichmentSweeper},
       # Every fifteen minutes: the resolution of the sync schedule rather than
       # its cadence, which has an hourly floor. See OnePlaylist.Syncs.Sweeper.
       {"*/15 * * * *", OnePlaylist.Syncs.Sweeper}
     ]}
  ]

# L1 of the catalogue cache. Bounded by memory rather than by a guessed entry
# count: a barcode-to-id entry measures 120 bytes, so 500k entries is roughly
# 57 MB, and `allocated_memory` is the bound that actually stops a leak.
#
# `Nebulex.Adapters.Local` is generational — at the bound it drops the oldest
# generation rather than emptying, so a full cache loses a fraction and keeps
# the hot set. That is the property this replaced a hand-rolled ETS table for.
config :one_playlist, OnePlaylist.Cache,
  gc_interval: :timer.hours(12),
  max_size: 500_000,
  allocated_memory: 100_000_000,
  gc_memory_check_interval: :timer.seconds(30)

# TIDAL. Endpoints are not secret and are the same everywhere; credentials come
# from the environment in config/runtime.exs.
#
# TIDAL is first because it is the only major service whose API a small
# developer can actually use: full playlist CRUD, no allowlist, no MAU
# threshold. See docs/reference/domain.md.
config :one_playlist, OnePlaylist.Providers.Tidal,
  login_url: "https://login.tidal.com",
  auth_url: "https://auth.tidal.com/v1",
  api_url: "https://openapi.tidal.com/v2",
  # Requested at authorization time. `playlists.write` and `collection.write`
  # are what make this a transfer tool rather than a viewer.
  #
  # `search.read` is what the matching engine needs to find candidates for a
  # track with no ISRC. A connection authorized before this was added does not
  # have it, so `OnePlaylist.Providers.Tidal.search_tracks/3` checks the granted
  # scopes and returns a typed error naming the scope — TIDAL's own refusals on
  # that endpoint do not mention scopes at all.
  scopes:
    ~w(user.read collection.read collection.write playlists.read playlists.write search.read),
  # Overridden by TIDAL_REDIRECT_URI, and must match a redirect URI registered
  # on the TIDAL application exactly.
  redirect_uri: "http://localhost:4000/auth/tidal/callback",
  # Extra options merged into every Req request. Tests inject a Req.Test plug
  # here; production leaves it empty.
  req_options: []

# Spotify. Same arrangement as TIDAL above: endpoints here, credentials from the
# environment in config/runtime.exs.
#
# Spotify is second despite being the service most people's playlists actually
# live in, because a new application is capped at a handful of allowlisted
# accounts and extended quota now requires an organization with 250,000 monthly
# users. So this is a personal and small-group feature by construction, and the
# cap is a fact about Spotify rather than something better code can lift. See
# docs/reference/domain.md.
config :one_playlist, OnePlaylist.Providers.Spotify,
  # Authorization *and* the token endpoint. Spotify serves both from
  # accounts.spotify.com, where TIDAL splits login from auth.
  login_url: "https://accounts.spotify.com",
  api_url: "https://api.spotify.com/v1",
  # Requested at authorization time.
  #
  # The two `playlist-read-*` scopes are not redundant: `private` covers the
  # user's own unlisted playlists and `collaborative` covers ones shared with
  # them, and neither implies the other. Both `modify` scopes are needed for the
  # same reason — this application creates private playlists, but a user may
  # point a transfer at a public one they own.
  #
  # `user-read-private` is what puts `country` on `GET /me`, which becomes the
  # `market` parameter on every read. Without it Spotify omits the field rather
  # than refusing, and catalogue visibility degrades silently.
  scopes: ~w(user-read-private playlist-read-private playlist-read-collaborative
       playlist-modify-private playlist-modify-public),
  # Overridden by SPOTIFY_REDIRECT_URI, and must match a redirect URI registered
  # on the Spotify application exactly.
  #
  # `127.0.0.1` rather than `localhost`, which Spotify stopped accepting for
  # loopback redirects in 2025 — it requires either HTTPS or the literal IP.
  # This is the one place the two providers' local URLs differ, and it is not a
  # typo.
  redirect_uri: "http://127.0.0.1:4000/auth/spotify/callback",
  req_options: []

# Content-Security-Policy for the browser pipeline.
#
# Notes on the non-obvious directives:
#
#   * `img-src ... https:` — album art is served from the providers' own CDNs
#     (i.scdn.co, mzstatic.com, and so on), and enumerating them would break
#     every time one changed. Images are the one resource type where a broad
#     allowance is low risk.
#   * `style-src 'unsafe-inline'` — LiveView writes inline styles for
#     transitions, and removing this breaks them. Scripts get no such
#     allowance: AGENTS.md forbids inline <script> tags, so `script-src 'self'`
#     holds.
#   * `connect-src` and `frame-ancestors` are relaxed in dev only: LiveReload
#     talks over an unencrypted websocket and injects a same-origin iframe.
#
# The dev branch lives here rather than in dev.exs because a config file cannot
# read back what it just set — `Application.get_env/2` during config evaluation
# returns nil — so deriving one policy from the other would have to duplicate it.
connect_src = if config_env() == :dev, do: "'self' ws: wss:", else: "'self' wss:"
frame_ancestors = if config_env() == :dev, do: "'self'", else: "'none'"

config :one_playlist,
  content_security_policy:
    [
      "default-src 'self'",
      "base-uri 'self'",
      "frame-ancestors #{frame_ancestors}",
      "object-src 'none'",
      "img-src 'self' data: https:",
      "style-src 'self' 'unsafe-inline'",
      "script-src 'self'",
      "connect-src #{connect_src}",
      "font-src 'self' data:",
      "form-action 'self'"
    ]
    |> Enum.join("; ")

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
