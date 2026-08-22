defmodule OnePlaylistWeb.UserAuth do
  @moduledoc """
  Establishes who is making a request.

  ## Deliberately minimal, and deliberately temporary

  This holds a user id in the session and nothing else. It is **not** the
  authentication story for this application — Supabase Auth is (see
  `docs/reference/supabase.md`), and when that lands this module becomes a thin
  wrapper over a verified Supabase JWT rather than the source of truth.

  It exists now because `provider_connections` has a foreign key onto
  `auth.users`, so connecting TIDAL requires *some* user to connect it for, and
  building the whole sign-in story first would mean the provider adapter went
  untested against the live API for however long that took.

  The seam is `current_user_id/1`. Everything downstream reads that, so
  replacing what fills it does not touch anything else.
  """

  import Plug.Conn
  import Phoenix.Controller

  @session_key "user_id"

  @doc "Assigns `:current_user_id` from the session, or `nil`."
  def fetch_current_user(conn, _opts) do
    assign(conn, :current_user_id, get_session(conn, @session_key))
  end

  @doc """
  Halts with a redirect unless a user is signed in.

  Deliberately not `Plug.Conn.halt/1` with a 401: these are browser routes, and
  a person who is not signed in wants a page, not a status code.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user_id] do
      conn
    else
      conn
      |> put_flash(:error, "You must be signed in to do that.")
      |> redirect(to: "/")
      |> halt()
    end
  end

  @doc "Puts `user_id` in the session, renewing it to prevent session fixation."
  def log_in_user(conn, user_id) do
    conn
    |> renew_session()
    |> put_session(@session_key, user_id)
  end

  @doc "Clears the session."
  def log_out_user(conn) do
    renew_session(conn)
  end

  @doc "The signed-in user's id, or `nil`."
  def current_user_id(conn), do: conn.assigns[:current_user_id]

  # Dropping the whole session on privilege change is the cheap defence against
  # session fixation: anything an attacker planted before sign-in is discarded.
  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
