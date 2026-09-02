defmodule OnePlaylistWeb.SessionController do
  @moduledoc """
  Signing in and out — by password, by emailed link or code, or with Google.

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

  ## Three ways in, one way of finishing

  Every path ends in `OnePlaylistWeb.UserAuth.log_in_user/2` with an
  `OnePlaylist.Accounts.Session`, which is what keeps the session spine — the
  encrypted cookie, the renewal, RLS's claims — indifferent to how a person
  proved who they were. What differs is only how the session is obtained:

    * **Password** — `create/2`, one request.
    * **Magic link** — `send_magic_link/2` asks GoTrue to email a link and a
      six-digit code. The link lands on `callback/2` with a `token_hash`; the
      code is typed into `verify_code/2`. Either finishes the same attempt.
    * **Google** — `google/2` redirects out with a PKCE challenge and keeps the
      verifier in the session; `callback/2` receives a `code` and exchanges the
      two for a session.

  `/auth/callback` is therefore shared. The parameters say which flow is
  finishing, and the two cannot be confused: a magic link carries `token_hash`
  and never `code`, and GoTrue's OAuth redirect carries `code` and never
  `token_hash`.

  ## What the session holds between the two legs of a Google sign-in

  One value, the PKCE `code_verifier`, under `"auth_code_verifier"`. It is the
  CSRF defence as well as the PKCE secret — an authorization code planted in a
  victim's browser cannot be exchanged without it — so it is deleted on **every**
  exit from `callback/2`, and `callback/2` carries a postcondition saying so. A
  verifier that outlived a failed attempt could be replayed against a later one.

  The magic-link flow keeps nothing: the `token_hash` is verified against GoTrue,
  not against a cookie, which is what lets the link work from a different
  browser than the one that asked for it.
  """

  use OnePlaylistWeb, :controller
  use Bond

  alias OnePlaylist.Accounts
  alias OnePlaylistWeb.UserAuth

  require Logger

  @verifier_key "auth_code_verifier"

  def new(conn, _params) do
    render_new(conn, email: nil, error_message: nil)
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}}) do
    case Accounts.sign_in(email, password) do
      {:ok, session} ->
        conn
        |> put_flash(:info, "Welcome back.")
        |> UserAuth.log_in_user(session)

      {:error, error} ->
        # Re-rendered in place rather than redirected, so the email survives and
        # the user retypes only the thing that was wrong. `put_status/2` because
        # a failed sign-in is not a 200, and browsers must not cache it.
        conn
        |> put_status(:unauthorized)
        |> render_new(email: email, error_message: Errata.display_message(error))
    end
  end

  @doc """
  Emails a sign-in link and code, and shows the page that takes the code.

  Reached by the second button on the credentials form, which submits with
  `formnovalidate` — so a blank address arrives here rather than being stopped
  by the browser, and is answered in place.
  """
  def send_magic_link(conn, %{"user" => %{"email" => email}}) do
    email = String.trim(email)

    with :present <- if(email == "", do: :blank, else: :present),
         :ok <- Accounts.send_magic_link(email) do
      render_sent(conn, email: email, error_message: nil)
    else
      :blank ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_new(
          email: nil,
          error_message: "Enter your email address first, and we will send you a link."
        )

      {:error, error} ->
        conn
        |> put_status(Errata.http_status(error))
        |> render_new(email: email, error_message: Errata.display_message(error))
    end
  end

  @doc "Finishes a magic link with the six-digit code from the email."
  def verify_code(conn, %{"code" => %{"email" => email, "token" => token}}) do
    case Accounts.verify_email_code(email, token) do
      {:ok, session} ->
        conn
        |> put_flash(:info, "Welcome.")
        |> UserAuth.log_in_user(session)

      {:error, error} ->
        # Back to the code page, not the sign-in page: the email is still in
        # their inbox and a mistyped digit should cost one more try, not a new
        # email against a rate limit of a few an hour.
        conn
        |> put_status(:unauthorized)
        |> render_sent(email: email, error_message: Errata.display_message(error))
    end
  end

  @doc """
  Starts a Google sign-in.

  A `POST`, so that no page can begin one by embedding a link, and so a browser
  prefetching the sign-in page's links does not set off an OAuth flow.
  """
  def google(conn, _params) do
    case Accounts.begin_google_sign_in(url(conn, ~p"/auth/callback")) do
      {:ok, %{url: authorize_url, code_verifier: verifier}} ->
        conn
        |> put_session(@verifier_key, verifier)
        |> redirect(external: authorize_url)

      {:error, error} ->
        conn
        |> put_flash(:error, Errata.display_message(error) || "Could not start Google sign-in.")
        |> redirect(to: ~p"/sign-in")
    end
  end

  @doc """
  Where every emailed link and every Google redirect lands.

  Which flow is finishing is read off the parameters — see the module
  documentation. Whatever arrives, the PKCE verifier is consumed: on success it
  has done its job, and on failure it must not be left for a later attempt to
  find.
  """
  # The law the module documentation promises. `log_in_user/2` clears the whole
  # session on success, so the clause this protects is the failing one: a
  # callback that arrives with an error, an expired code, or nothing at all,
  # must still spend the verifier. Proven by mutation — dropping the
  # `delete_session/2` below leaves it in place on every failure path and fires
  # this on the first test that plants one.
  @post verifier_is_spent: Plug.Conn.get_session(result, @verifier_key) == nil
  def callback(conn, params) do
    verifier = get_session(conn, @verifier_key)
    conn = delete_session(conn, @verifier_key)

    finish(conn, params, verifier)
  end

  # GoTrue reports a declined or failed upstream sign-in in the query string:
  # `error`, `error_code` and a human `error_description`. Checked before
  # anything else so a person who pressed "cancel" at Google reads a plain
  # sentence rather than an error about a missing code.
  defp finish(conn, %{"error" => error} = params, _verifier) do
    Logger.info("sign-in callback declined: #{error} #{params["error_description"]}")

    fail(conn, "Sign-in was cancelled. You can try again whenever you like.")
  end

  defp finish(conn, %{"token_hash" => token_hash}, _verifier) do
    case Accounts.verify_magic_link(token_hash) do
      {:ok, session} ->
        conn
        |> put_flash(:info, "Welcome.")
        |> UserAuth.log_in_user(session)

      {:error, error} ->
        fail(conn, Errata.display_message(error) || "That sign-in link could not be used.")
    end
  end

  defp finish(conn, %{"code" => _code}, nil) do
    # No verifier means no flow was started from this browser: a stale tab, a
    # refreshed callback, or a link that was started on another device. The
    # code cannot be exchanged without it, so there is nothing to try.
    fail(
      conn,
      "That sign-in has expired. Please start again from the browser you began in."
    )
  end

  defp finish(conn, %{"code" => code}, verifier) do
    case Accounts.exchange_code(code, verifier) do
      {:ok, session} ->
        conn
        |> put_flash(:info, "Welcome.")
        |> UserAuth.log_in_user(session)

      {:error, error} ->
        fail(conn, Errata.display_message(error) || "That sign-in could not be completed.")
    end
  end

  defp finish(conn, _params, _verifier) do
    fail(conn, "That sign-in link was incomplete. Please request a new one.")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> UserAuth.log_out_user()
  end

  defp render_new(conn, assigns) do
    render(
      conn,
      :new,
      Keyword.merge(assigns,
        configured?: OnePlaylist.Supabase.configured?(),
        page_title: "Sign in"
      )
    )
  end

  defp render_sent(conn, assigns) do
    render(conn, :sent, Keyword.put(assigns, :page_title, "Check your email"))
  end

  defp fail(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign-in")
  end
end
