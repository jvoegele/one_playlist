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
