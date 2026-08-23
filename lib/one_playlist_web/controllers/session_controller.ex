defmodule OnePlaylistWeb.SessionController do
  @moduledoc """
  Signing in and out.

  ## A controller rather than a LiveView

  Both halves of the reason are about the password.

  A LiveView form sends its contents over the WebSocket on every `phx-change`,
  so live validation of a sign-in form means transmitting a partial password on
  every keystroke and holding it in socket assigns. `ConnectionLive.Index` makes
  the same call for the same reason, and says so.

  The second half is structural: a LiveView cannot set a cookie. Even Phoenix's
  own generated LiveView sign-in submits to a controller to finish, so a
  controller here is the destination either way rather than a step backwards.

  There is nothing a live form would add. This one has two fields and no state
  worth keeping between keystrokes.
  """

  use OnePlaylistWeb, :controller

  alias OnePlaylist.Accounts

  def new(conn, _params) do
    render(conn, :new,
      error_message: nil,
      email: nil,
      configured?: OnePlaylist.Supabase.configured?(),
      page_title: "Sign in"
    )
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}}) do
    case Accounts.sign_in(email, password) do
      {:ok, session} ->
        conn
        |> put_flash(:info, "Welcome back.")
        |> OnePlaylistWeb.UserAuth.log_in_user(session)

      {:error, error} ->
        # Re-rendered in place rather than redirected, so the email survives and
        # the user retypes only the thing that was wrong. `put_status/2` because
        # a failed sign-in is not a 200, and browsers must not cache it.
        conn
        |> put_status(:unauthorized)
        |> render(:new,
          error_message: Errata.display_message(error),
          email: email,
          configured?: OnePlaylist.Supabase.configured?(),
          page_title: "Sign in"
        )
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> OnePlaylistWeb.UserAuth.log_out_user()
  end
end
