defmodule OnePlaylistWeb.RegistrationController do
  @moduledoc """
  Creating an account.

  A sibling of `OnePlaylistWeb.SessionController`, and a controller for the same
  two reasons: the password should not travel on every keystroke, and finishing
  a sign-up means setting a cookie.

  ## Two outcomes, not one

  `OnePlaylist.Accounts.sign_up/2` answers either a live session or
  `:confirmation_required`, depending on whether the Supabase project has email
  confirmation switched on. The local stack has it off, so development always
  takes the first path and production is expected to take the second. Both are
  handled here rather than assumed, because the difference only shows up on
  deploy — and shows up as a user who signs up and is silently not signed in.
  """

  use OnePlaylistWeb, :controller

  alias OnePlaylist.Accounts

  def new(conn, _params) do
    render(conn, :new,
      error_message: nil,
      email: nil,
      configured?: OnePlaylist.Supabase.configured?(),
      page_title: "Create an account"
    )
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}}) do
    case Accounts.sign_up(email, password) do
      {:ok, :confirmation_required} ->
        conn
        |> put_flash(:info, "Almost there — check #{email} for a confirmation link.")
        |> redirect(to: ~p"/sign-in")

      {:ok, session} ->
        conn
        |> put_flash(:info, "Welcome to One Playlist.")
        |> OnePlaylistWeb.UserAuth.log_in_user(session)

      {:error, error} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:new,
          error_message: Errata.display_message(error),
          email: email,
          configured?: OnePlaylist.Supabase.configured?(),
          page_title: "Create an account"
        )
    end
  end
end
