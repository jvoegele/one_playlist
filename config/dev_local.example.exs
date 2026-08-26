import Config

# Template for config/dev_local.exs — local development overrides holding real
# provider credentials.
#
#     cp config/dev_local.example.exs config/dev_local.exs
#
# The real file is gitignored. This example is committed so a fresh checkout can
# see what needs filling in. Never put a real secret in *this* file.
#
# These values can also come from the environment (TIDAL_CLIENT_ID and friends,
# read in config/runtime.exs). A file is usually nicer for local work because it
# survives shell restarts and does not leak into the environment of every other
# process you launch; environment variables remain the right answer in
# production.

# TIDAL — https://developer.tidal.com/dashboard
#
# The redirect URI must be registered on the TIDAL application, under its
# Settings tab, byte for byte. A mismatch fails at the authorize step with an
# error that does not say which part disagreed.
config :one_playlist, OnePlaylist.Providers.Tidal,
  client_id: "your-tidal-client-id",
  client_secret: "your-tidal-client-secret",
  redirect_uri: "http://localhost:4000/auth/tidal/callback"

# Spotify — https://developer.spotify.com/dashboard
#
# Create an app, tick **Web API**, and register the redirect URI below under its
# settings byte for byte. Two things differ from TIDAL and both bite silently:
#
#   * `127.0.0.1`, **not** `localhost`. Spotify stopped accepting `localhost`
#     for loopback redirects in 2025 and requires the literal IP.
#   * the client secret is required, not optional — Spotify is driven as a
#     confidential client, so a missing secret authorizes the user and then
#     fails the token exchange with `invalid_client`.
#
# A new app is in Development Mode, which serves only the accounts listed under
# its User Management tab. Add yourself there, or every call answers 403.
config :one_playlist, OnePlaylist.Providers.Spotify,
  client_id: "your-spotify-client-id",
  client_secret: "your-spotify-client-secret",
  redirect_uri: "http://127.0.0.1:4000/auth/spotify/callback"

# Supabase — copy the values printed by `supabase status`.
#
# `api_key` is the **publishable (anon)** key, never the service role key: the
# service role key bypasses every RLS policy, so signing a user in with it would
# authenticate anybody as anybody. See OnePlaylist.Supabase.
config :one_playlist, OnePlaylist.Supabase,
  base_url: "http://127.0.0.1:54321",
  api_key: "your-local-anon-key"
