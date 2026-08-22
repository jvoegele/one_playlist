import Config

# Configure your database
#
# Tests run against the same local Supabase database as dev (see the comment in
# config/dev.exs for why it must be `postgres` and not a database of our own).
# Isolation comes from Ecto's SQL sandbox — every test runs in a transaction
# that is rolled back — rather than from a separate database.
#
# The trade-off, stated plainly: dev and test share one database, so a test that
# escapes the sandbox and commits would be visible in dev. In exchange, tests
# see the real `auth` schema, the real `anon`/`authenticated`/`service_role`
# roles, and real `auth.uid()`, which is the only way RLS policies can be
# meaningfully tested. Testing RLS against a plain Postgres that lacks all three
# is how RLS bugs survive to production.
#
# MIX_TEST_PARTITION is deliberately not used: it partitions by creating one
# database per partition, which cannot work when the database is fixed.
#
# The pool is capped rather than the usual `schedulers_online() * 2` (32 here).
# The Supabase services already hold ~32 of the cluster's 100 connections, so
# the default would leave very little headroom with a dev server also running.
config :one_playlist, OnePlaylist.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  port: 54322,
  database: "postgres",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: min(System.schedulers_online() * 2, 16)

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :one_playlist, OnePlaylistWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "8aqKPsgTPAzJbJ2FJM3vlVpqZWaM1skoDlfhPepJBWMs/okyGyHQ7MQfv1hGdoEy",
  server: false

# In test we don't send emails
config :one_playlist, OnePlaylist.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Encryption key for OnePlaylist.Vault. See the note in config/dev.exs — this is
# a throwaway key, deliberately committed so the suite runs without setup.
config :one_playlist, OnePlaylist.Vault, key: "b8sLzK5ycelvlNomefBIAX7zKj12kvD3ostieeVVwY0="

# Bond contract coverage. Records which assertions were checked and which were
# ever observed to fail, so an assertion that runs but can never fail — the
# vacuous contract Bond's guides warn about — shows up instead of looking like
# coverage. Compile-time opt-in; the reporter is installed in test_helper.exs.
config :bond, coverage: true
