defmodule OnePlaylistWeb.SessionControllerTest do
  @moduledoc """
  The sign-in and sign-out pages.

  Supabase is normally not configured in the test environment, so
  `OnePlaylist.Accounts` answers `:not_configured` without a network call and
  these stay hermetic. They must also pass when it *is* configured — running the
  tagged tests in `test/one_playlist/accounts_test.exs` sets `SUPABASE_URL` for
  the whole run — so every assertion here is about an outcome that holds either
  way: a sign-in that fails for *some* reason, a sign-out, a redirect.

  Anything whose answer depends on that configuration belongs in
  `OnePlaylistWeb.AuthComponentsTest`, where it is passed in as an argument.
  """

  use OnePlaylistWeb.ConnCase, async: true

  import OnePlaylist.AuthFixtures

  describe "GET /sign-in" do
    test "renders the form", %{conn: conn} do
      response = conn |> get(~p"/sign-in") |> html_response(200)

      assert response =~ "Sign in"
      assert response =~ ~s(name="user[email]")
      assert response =~ ~s(name="user[password]")
    end

    test "a signed-in user is sent on rather than shown a password field", %{conn: conn} do
      conn = conn |> log_in_user(session_fixture()) |> get(~p"/sign-in")

      assert redirected_to(conn) == ~p"/connections"
    end
  end

  describe "POST /sign-in" do
    test "a failed attempt keeps the email and drops the password", %{conn: conn} do
      # A fixed address would eventually name a real account: when the tagged
      # integration tests run, they configure Supabase for the whole run, and
      # anything this file signs up persists outside the Ecto sandbox. This test
      # once passed for months and then failed because a *sibling test* had
      # created `someone@example.test` on an earlier run.
      email = "nobody-#{System.system_time(:nanosecond)}@example.test"

      conn =
        post(conn, ~p"/sign-in", %{"user" => %{"email" => email, "password" => "swordfish"}})

      response = html_response(conn, 401)

      assert response =~ email, "retype only what was wrong"
      refute response =~ "swordfish", "the password must never be echoed into the DOM"
    end

    test "answers 401 rather than 200, so nothing caches a failed sign-in", %{conn: conn} do
      conn =
        post(conn, ~p"/sign-in", %{"user" => %{"email" => "a@b.test", "password" => "x"}})

      assert conn.status == 401
    end
  end

  describe "the other ways in, on the sign-in page" do
    test "offers a magic link from the same form, and Google from its own", %{conn: conn} do
      response = conn |> get(~p"/sign-in") |> html_response(200)

      # One email field serves both buttons: the link button re-targets the
      # form rather than being a second form asking for the address again.
      assert response =~ ~s(formaction="/sign-in/magic-link")
      assert response =~ "formnovalidate"
      # Google starts with a POST, never a link — nothing should be able to
      # begin an OAuth flow by embedding a URL or prefetching one.
      assert response =~ ~s(action="/sign-in/google")
      refute response =~ ~s(href="/sign-in/google")
    end
  end

  describe "POST /sign-in/magic-link" do
    test "a blank address is answered in place rather than sent to GoTrue", %{conn: conn} do
      # `formnovalidate` on the button means the browser does not enforce the
      # field's `required`, so this is a reachable state and not a curiosity.
      conn = post(conn, ~p"/sign-in/magic-link", %{"user" => %{"email" => "   "}})

      response = html_response(conn, 422)
      assert response =~ "Enter your email address first"
      assert response =~ ~s(name="user[email]"), "back on the form, not on a dead end"
    end

    test "an address GoTrue cannot use keeps the email on the form", %{conn: conn} do
      # Holds either way: unconfigured, this is `:not_configured`; configured,
      # GoTrue refuses the malformed address with `validation_failed` and no
      # email is sent. Neither outcome is a 200, and both keep what was typed.
      email = "not-an-address"
      conn = post(conn, ~p"/sign-in/magic-link", %{"user" => %{"email" => email}})

      assert conn.status in [401, 501]
      response = html_response(conn, conn.status)
      assert response =~ email
      assert response =~ ~s(id="auth-error")
    end
  end

  describe "POST /sign-in/code" do
    test "a code that does not verify returns to the code page, address intact", %{conn: conn} do
      # Not to the sign-in page: the email is still in their inbox, and a
      # mistyped digit should cost one more try rather than another email
      # against a rate limit of a few an hour.
      email = "nobody-#{System.system_time(:nanosecond)}@example.test"

      conn =
        post(conn, ~p"/sign-in/code", %{"code" => %{"email" => email, "token" => "000000"}})

      response = html_response(conn, 401)
      assert response =~ ~s(value="#{email}")
      assert response =~ ~s(name="code[token]")
      assert response =~ ~s(id="auth-error")
    end
  end

  describe "POST /sign-in/google" do
    test "always redirects, never renders", %{conn: conn} do
      # Unconfigured, back to the sign-in page with a reason; configured, out to
      # GoTrue's authorize URL. The configured half is asserted in
      # `OnePlaylist.AccountsTest`, where it is a parameter rather than an
      # ambient fact.
      conn = post(conn, ~p"/sign-in/google")

      assert conn.status == 302
    end
  end

  describe "GET /auth/callback" do
    test "with nothing in it, says so and goes back to the sign-in page", %{conn: conn} do
      conn = get(conn, ~p"/auth/callback")

      assert redirected_to(conn) == ~p"/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "incomplete"
    end

    test "is not swallowed by the provider-connection routes", %{conn: conn} do
      # `/auth/:provider` is declared after it, and would otherwise match with
      # provider = "callback". That route requires a signed-in user and fails
      # to `/`, so a signed-in user reaching `/sign-in` proves the order held.
      conn = conn |> log_in_user(session_fixture()) |> get(~p"/auth/callback")

      assert redirected_to(conn) == ~p"/sign-in"
    end

    test "a declined upstream sign-in reads as cancelled, not as an error", %{conn: conn} do
      conn =
        get(conn, ~p"/auth/callback", %{
          "error" => "access_denied",
          "error_code" => "user_cancelled",
          "error_description" => "The user cancelled"
        })

      assert redirected_to(conn) == ~p"/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "cancelled"
    end

    test "a code with no verifier in this browser cannot be exchanged", %{conn: conn} do
      # A stale tab, a refreshed callback, or a flow started on another device.
      # Refused without a network call — there is nothing to exchange it with.
      conn = get(conn, ~p"/auth/callback", %{"code" => "an-authorization-code"})

      assert redirected_to(conn) == ~p"/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "browser you began in"
    end

    test "a failed exchange spends the verifier", %{conn: conn} do
      # The law `callback/2`'s postcondition states, from the outside. The
      # exchange fails either way — unconfigured, or GoTrue rejecting a code it
      # never issued — and a verifier that survived would be available to the
      # next callback that arrived, which is what a replay is.
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{"auth_code_verifier" => "kept-from-google"})
        |> get(~p"/auth/callback", %{"code" => "an-authorization-code"})

      assert redirected_to(conn) == ~p"/sign-in"
      refute get_session(conn, "auth_code_verifier")
    end

    test "a token hash that does not verify goes back to sign-in with a reason", %{conn: conn} do
      conn = get(conn, ~p"/auth/callback", %{"token_hash" => "not-a-hash", "type" => "email"})

      assert redirected_to(conn) == ~p"/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
    end
  end

  describe "DELETE /sign-out" do
    test "clears the session and sends the user home", %{conn: conn} do
      conn = conn |> log_in_user(session_fixture()) |> delete(~p"/sign-out")

      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, "user_session")
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Signed out"
    end

    test "works even when nobody is signed in", %{conn: conn} do
      # Reachable by a double-submit or a stale tab, and must not crash.
      conn = delete(conn, ~p"/sign-out")

      assert redirected_to(conn) == ~p"/"
    end

    test "is not reachable by GET", %{conn: conn} do
      # A GET that ends your session can be triggered by any page that embeds
      # the URL, and would be followed by anything that prefetches links.
      assert get(conn, ~p"/sign-out").status == 404
    end
  end

  describe "the session cookie" do
    test "is encrypted, not merely signed", %{conn: conn} do
      # `OnePlaylistWeb.Endpoint` sets an `encryption_salt` because the session
      # carries a GoTrue refresh token — a bearer credential that anyone able to
      # read the cookie could spend. A signed-only cookie is readable: its
      # payload is base64 of `:erlang.term_to_binary/1`, so any string in the
      # session appears verbatim in the decoded bytes.
      #
      # Driven through a real request rather than `init_test_session/2`, which
      # uses an in-memory store and emits no cookie at all — the earlier version
      # of this test asserted against a cookie that was never set, and passed
      # for that reason rather than because anything was encrypted.
      #
      # Signing out to `/connections` is what puts a known string in the
      # session: `require_authenticated_user` stores it as `:user_return_to`.
      conn = get(conn, ~p"/connections")

      assert redirected_to(conn) == ~p"/sign-in"

      cookie = conn.resp_cookies["_one_playlist_key"]
      assert cookie, "the request must actually have written a session cookie"

      # `Plug.Crypto.MessageVerifier` writes `protected.payload.signature`, each
      # part url-safe base64. Decoding every part is what separates a signed
      # cookie from an encrypted one: with signing alone the payload is
      # `:erlang.term_to_binary/1`, and every string in the session is plainly
      # visible in it. Checking the *undecoded* value proves nothing, because
      # base64 hides the string either way — which is how the first version of
      # this test passed against a deliberately unencrypted cookie.
      decoded =
        cookie.value
        |> String.split(".")
        |> Enum.map(fn part ->
          case Base.url_decode64(part, padding: false) do
            {:ok, bytes} -> bytes
            :error -> part
          end
        end)
        |> Enum.join(" ")

      refute decoded =~ "connections",
             "a session value survived decoding — the cookie is signed but not encrypted"
    end
  end
end
