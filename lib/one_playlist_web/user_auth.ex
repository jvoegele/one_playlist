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

  @doc """
  Assigns `:current_user_id` from the session, or `nil`.

  Also assigns `:current_scope`, which is what `OnePlaylistWeb.Layouts.app/1`
  reads to decide whether to render navigation — the same shim `on_mount/4`
  applies for LiveViews, applied here so a controller-rendered page gets the
  same header rather than one missing every link.
  """
  def fetch_current_user(conn, _opts) do
    user_id = get_session(conn, @session_key)

    conn
    |> assign(:current_user_id, user_id)
    |> assign(:current_scope, user_id && %{user: %{id: user_id}})
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

  @doc """
  The signed-in user's id, or `nil`.
  """
  def current_user_id(conn), do: conn.assigns[:current_user_id]

  @doc """
  `on_mount` hook: the LiveView counterpart of the two plugs above.

  `:mount_current_user` assigns the id and nothing else; `:require_authenticated`
  additionally halts the mount. Both also assign `:current_scope`, which is what
  `OnePlaylistWeb.Layouts.app/1` expects — this application carries a bare user
  id where Phoenix 1.8's generators carry a scope struct, so the shim lives here
  rather than in every template.
  """
  def on_mount(:mount_current_user, _params, session, socket),
    do: {:cont, assign_current_user(socket, session)}

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = assign_current_user(socket, session)

    if socket.assigns.current_user_id do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "You must be signed in to do that.")
       |> Phoenix.LiveView.redirect(to: "/")}
    end
  end

  defp assign_current_user(socket, session) do
    user_id = session[@session_key]

    socket
    |> Phoenix.Component.assign(:current_user_id, user_id)
    |> Phoenix.Component.assign(:current_scope, user_id && %{user: %{id: user_id}})
  end

  # Dropping the whole session on privilege change is the cheap defence against
  # session fixation: anything an attacker planted before sign-in is discarded.
  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
