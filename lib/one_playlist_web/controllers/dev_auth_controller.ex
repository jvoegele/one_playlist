defmodule OnePlaylistWeb.DevAuthController do
  @moduledoc """
  Signs in a fixed development user. **Dev only — scaffolding.**

  `provider_connections` has a foreign key onto `auth.users`, so connecting a
  music service needs a signed-in user. Supabase Auth will provide that; this
  exists so the TIDAL adapter can be exercised against the live API before that
  work lands, rather than sitting untested behind it.

  It is routed only under `dev_routes`, and refuses to run outside `:dev`
  regardless — a route guard is a compile-time fact about this file, and this
  is the kind of thing that must not become reachable by accident.

  Delete this module, its route, and its test when Supabase Auth sign-in exists.
  """

  use OnePlaylistWeb, :controller

  import OnePlaylistWeb.UserAuth, only: [log_in_user: 2, log_out_user: 1]

  alias Ecto.Adapters.SQL
  alias OnePlaylist.Repo

  @dev_email "dev@one-playlist.test"

  def create(conn, _params) do
    unless Application.get_env(:one_playlist, :dev_routes) do
      raise "DevAuthController is not available outside development"
    end

    conn
    |> log_in_user(dev_user_id())
    |> put_flash(:info, "Signed in as #{@dev_email} (development only).")
    |> redirect(to: ~p"/")
  end

  def delete(conn, _params) do
    conn
    |> log_out_user()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/")
  end

  # Written straight into auth.users because Supabase Auth owns that table and
  # we have no sign-up flow yet. Look up first, insert if absent, so repeated
  # dev sign-ins reuse one user and one set of provider connections.
  #
  # Not `on conflict (email)`: auth.users has no plain unique constraint on
  # email. Supabase's is `users_email_partial_key`, unique only
  # `where (is_sso_user = false)`, and ON CONFLICT cannot target a partial index
  # without repeating its predicate. Two statements are clearer than that, and
  # the race they leave open does not exist for one developer clicking a link.
  defp dev_user_id do
    case SQL.query!(Repo, "select id from auth.users where email = $1 limit 1", [@dev_email]) do
      %{rows: [[id]]} ->
        Ecto.UUID.load!(id)

      %{rows: []} ->
        %{rows: [[id]]} =
          SQL.query!(
            Repo,
            """
            insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
            values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
                    'authenticated', 'authenticated', $1, now(), now())
            returning id
            """,
            [@dev_email]
          )

        Ecto.UUID.load!(id)
    end
  end
end
