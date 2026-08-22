# Connects the local Navidrome to the signed-in development user.
#
#     bin/remote dev/navidrome/connect.exs
#
# There is no UI for connecting a Subsonic server yet — the TIDAL flow is OAuth
# and this one is a form that does not exist. Until it does, this script is how
# a development connection gets created, and it is committed rather than typed
# from memory because the shape of a Subsonic connection is not obvious:
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

server_url = System.get_env("NAVIDROME_URL", "http://localhost:4533")
username = System.get_env("NAVIDROME_USER", "admin")
password = System.get_env("NAVIDROME_PASSWORD", "oneplaylist")

case Repo.all(Providers.Connection) |> Enum.find(&(&1.provider == :tidal)) do
  nil ->
    {:error, "connect TIDAL first at http://localhost:4000/auth/tidal"}

  tidal ->
    {:ok, connection} =
      Providers.connect(tidal.user_id, :navidrome, %{
        provider_user_id: username,
        display_name: "Navidrome (local)",
        server_url: server_url,
        access_token: password,
        refresh_token: nil,
        access_token_expires_at: nil
      })

    # Proves the credential works. `getUser` rather than `ping`, because `ping`
    # answers `ok` on a server that does not check credentials at all.
    case Navidrome.whoami(connection) do
      {:ok, user} ->
        {:ok, playlists} = Navidrome.stream_playlists(connection, [])

        %{
          connected: server_url,
          username: user["username"],
          playlists: Enum.count(playlists)
        }

      {:error, error} ->
        %{connected: server_url, error: Errata.display_message(error)}
    end
end
