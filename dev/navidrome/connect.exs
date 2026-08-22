# Connects the local Navidrome to the signed-in development user.
#
#     bin/remote dev/navidrome/connect.exs
#
# There *is* a UI for this now — /connections has a form, and it is the path a
# real user takes. This script survives it because it does the same job without
# a browser: rebuilding a dev environment, seeding CI, or reconnecting after a
# `supabase db reset` without clicking through anything.
#
# It also remains the readable description of what a Subsonic connection *is*,
# which is not obvious:
#
#   * `provider_user_id` is the **username**, not an opaque account id.
#   * `access_token` is the **password**. It is the credential presented on
#     every call, so it goes in the column that is already encrypted and
#     redacted. See OnePlaylist.Providers.Connection.
#   * `server_url` is the server's address, which no hosted provider needs.
#   * `refresh_token` and `access_token_expires_at` are **nil**, and that is what
#     makes `Providers.ensure_fresh/2` leave the connection alone forever —
#     `needs_refresh?/3` answers `false` for a nil expiry.
#
# Attaches to whichever user already has a TIDAL connection, so a cross-provider
# transfer has both ends. Idempotent: `connect/3` upserts on (user_id, provider).

alias OnePlaylist.{Providers, Repo}
alias OnePlaylist.Providers.Navidrome
alias OnePlaylist.Providers.SubsonicCredentials

server_url = System.get_env("NAVIDROME_URL", "http://localhost:4533")
username = System.get_env("NAVIDROME_USER", "admin")
password = System.get_env("NAVIDROME_PASSWORD", "oneplaylist")

# The same call the form makes, rather than a hand-built `connect/3` — so this
# script cannot drift away from the path real users take, and so it inherits the
# credential check instead of storing a password that might be wrong.
credentials = %SubsonicCredentials{
  server_url: server_url,
  username: username,
  password: password,
  display_name: "Navidrome (local)"
}

case Repo.all(Providers.Connection) |> Enum.find(&(&1.provider == :tidal)) do
  nil ->
    {:error, "connect TIDAL first at http://localhost:4000/auth/tidal"}

  tidal ->
    case Providers.connect_subsonic(tidal.user_id, credentials) do
      {:ok, connection} ->
        {:ok, playlists} = Navidrome.stream_playlists(connection, [])

        %{
          connected: connection.server_url,
          username: connection.provider_user_id,
          playlists: Enum.count(playlists)
        }

      {:error, error} ->
        %{server_url: server_url, error: Errata.display_message(error)}
    end
end
