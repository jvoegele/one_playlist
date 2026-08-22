defmodule OnePlaylist.Repo do
  use Ecto.Repo,
    otp_app: :one_playlist,
    adapter: Ecto.Adapters.Postgres
end
