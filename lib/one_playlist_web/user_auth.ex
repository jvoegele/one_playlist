defmodule OnePlaylistWeb.UserAuth do
  @moduledoc """
  Establishes who is making a request, from the session cookie.

  The cookie carries an `OnePlaylist.Accounts.Session` — the GoTrue session
  issued at sign-in, including its refresh token. `OnePlaylistWeb.Endpoint`
  encrypts the cookie for that reason; a signed-only cookie is readable, and a
  refresh token is a bearer credential.

  ## Why this is not `Supabase.Auth.Plug`

  The SDK ships a plug and an `on_mount` that would do most of this. They are
  deliberately unused: this is the layer that will have to step Postgres down
  from `postgres` (which holds `BYPASSRLS`) to `authenticated` and set
  `request.jwt.claims`, so that the policies in `priv/repo/migrations` actually
  apply. That seam has to be somewhere this repository controls. See
  `OnePlaylist.Accounts`.

  ## The seam

  `current_user_id/1`. Everything downstream reads that and nothing else, which
  is what made replacing the dev scaffolding with real sign-in a change to this
  module rather than to every context.

  > #### A LiveView cannot rewrite the cookie {: .info}
  >
  > `fetch_current_user/2` renews a session that is close to expiry and writes
  > the new one back. `on_mount/4` cannot: a LiveView runs over a WebSocket,
  > which has no way to set a cookie, so it takes the session as it stood at
  > mount and holds it.
  >
  > That is harmless today because a LiveView reads only `user_id`, which never
  > expires. It stops being harmless when RLS lands and the *access token* is
  > what the database is given — at which point a long-open page needs a real
  > renewal path, not this comment. Recorded here because the failure would
  > otherwise appear as "queries return nothing after an hour".
  """

  use OnePlaylistWeb, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias OnePlaylist.Accounts
  alias OnePlaylist.Accounts.Session

  require Logger

  @session_key "user_session"

  @doc """
  Assigns the current session, renewing it first if it is near expiry.

  A cookie that does not deserialize into a well-formed session is treated as
  signed out rather than trusted — it may have been written by an older deploy
  with a different struct, which is a normal consequence of shipping, not an
  attack. Same for one whose renewal failed: the refresh token may simply have
  been revoked.
  """
  def fetch_current_user(conn, _opts) do
    case session_from(conn) do
      nil ->
        assign_session(conn, nil)

      %Session{} = session ->
        case Accounts.ensure_fresh(session) do
          {:ok, ^session} ->
            assign_session(conn, session)

          {:ok, renewed} ->
            conn |> put_session(@session_key, renewed) |> assign_session(renewed)

          {:error, error} ->
            Logger.info("signing out: session could not be renewed (#{Errata.reason(error)})")
            conn |> renew_session() |> assign_session(nil)
        end
    end
  end

  @doc """
  Halts with a redirect unless a user is signed in.

  Deliberately not a 401: these are browser routes, and a person who is not
  signed in wants a page, not a status code.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user_id] do
      conn
    else
      conn
      |> put_flash(:error, "You must be signed in to do that.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/sign-in")
      |> halt()
    end
  end

  @doc """
  Redirects away from the sign-in pages when already signed in.

  Landing on a login form while signed in is a dead end that invites the user to
  type a password they do not need to type.
  """
  def redirect_if_authenticated(conn, _opts) do
    if conn.assigns[:current_user_id] do
      conn |> redirect(to: signed_in_path()) |> halt()
    else
      conn
    end
  end

  @doc """
  Stores a freshly issued session and renews the cookie.

  The session is dropped and rebuilt first — `configure_session(renew: true)`
  discards anything an attacker may have planted in the visitor's session before
  sign-in, which is the cheap defence against session fixation.
  """
  def log_in_user(conn, %Session{} = session) do
    # Read before `put_user_session/2`, which renews the session and discards
    # everything in it — including where the user was trying to go.
    return_to = get_session(conn, :user_return_to)

    conn
    |> put_user_session(session)
    |> redirect(to: return_to || signed_in_path())
  end

  @doc """
  Stores a session without redirecting.

  The half of `log_in_user/2` that establishes identity, separated from the half
  that decides where to send the browser. Two callers already need only this
  one: the test suite, which continues the same `conn` into a request, and — when
  magic links and Google sign-in land — the callback route, which has its own
  destination logic.
  """
  def put_user_session(conn, %Session{} = session) do
    conn
    |> renew_session()
    |> put_session(@session_key, session)
  end

  @doc """
  Revokes the session at GoTrue and clears the cookie.

  In that order, and unconditionally: `OnePlaylist.Accounts.sign_out/1` always
  answers `:ok`, so a service that cannot be reached still ends the local
  session. A "sign out" that leaves the user signed in because a remote call
  failed is the wrong answer in exactly the case where it matters.
  """
  def log_out_user(conn) do
    if session = session_from(conn), do: Accounts.sign_out(session)

    conn
    |> renew_session()
    |> redirect(to: ~p"/")
  end

  @doc """
  The signed-in user's id, or `nil`. The seam everything downstream reads.
  """
  def current_user_id(conn), do: conn.assigns[:current_user_id]

  @doc """
  `on_mount` hook: the LiveView counterpart of the plugs above.

  `:mount_current_user` assigns and continues; `:require_authenticated` halts
  the mount when there is nobody. Neither renews the session — see the note in
  the module documentation.
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
       |> Phoenix.LiveView.redirect(to: ~p"/sign-in")}
    end
  end

  @doc """
  Where a user lands after signing in.

  Connections rather than the home page: a new account has no services attached
  and can do nothing at all until it does, so this is the one screen that is
  never a dead end.
  """
  def signed_in_path, do: ~p"/connections"

  # Anything that is not a well-formed session is nobody. `well_formed?/1`
  # rather than a pattern match on `%Session{}`, because a cookie written by an
  # older deploy deserializes into a struct with the *old* fields — it would
  # match and then fail on access.
  defp session_from(conn) do
    case get_session(conn, @session_key) do
      session -> if Session.well_formed?(session), do: session
    end
  end

  defp assign_session(conn, session) do
    conn
    |> assign(:current_session, session)
    |> assign(:current_user_id, session && session.user_id)
    |> assign(:current_scope, scope(session))
  end

  defp assign_current_user(socket, session) do
    session = session[@session_key]
    session = if Session.well_formed?(session), do: session

    socket
    |> Phoenix.Component.assign(:current_session, session)
    |> Phoenix.Component.assign(:current_user_id, session && session.user_id)
    |> Phoenix.Component.assign(:current_scope, scope(session))
  end

  # This application carries a session where Phoenix 1.8's generators carry a
  # `Scope` struct. The shim lives here rather than in every template, and
  # carries the email so the header can say *who* is signed in — "signed in as
  # somebody" is the question a user actually has when two accounts exist.
  defp scope(nil), do: nil
  defp scope(%Session{} = session), do: %{user: %{id: session.user_id, email: session.email}}

  defp maybe_store_return_to(%{method: "GET"} = conn),
    do: put_session(conn, :user_return_to, current_path(conn))

  defp maybe_store_return_to(conn), do: conn

  # Dropping the whole session on a privilege change is the cheap defence
  # against session fixation: anything planted before sign-in is discarded.
  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
