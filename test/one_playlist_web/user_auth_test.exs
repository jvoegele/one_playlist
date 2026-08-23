defmodule OnePlaylistWeb.UserAuthTest do
  @moduledoc """
  The plugs and `on_mount` hooks that decide who is making a request.
  """

  use OnePlaylistWeb.ConnCase, async: true

  import OnePlaylist.AuthFixtures

  alias OnePlaylistWeb.UserAuth

  describe "fetch_current_user/2" do
    test "assigns the session that is there", %{conn: conn} do
      session = session_fixture()

      conn = conn |> log_in_user(session) |> get(~p"/")

      assert conn.assigns.current_user_id == session.user_id
      assert conn.assigns.current_scope.user.email == session.email
    end

    test "assigns nobody when there is no session", %{conn: conn} do
      conn = get(conn, ~p"/")

      assert conn.assigns.current_user_id == nil
      assert conn.assigns.current_scope == nil
    end

    test "a cookie that is not a well-formed session is nobody, not a crash", %{conn: conn} do
      # The realistic cause is a deploy: a cookie written by an older version of
      # this application, carrying a struct that no longer has these fields.
      # Trusting it would raise `KeyError` deep inside a request; rejecting it
      # signs the user out, which is recoverable by signing back in.
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session("user_session", %{user_id: "u", but: "not a session"})
        |> get(~p"/")

      assert conn.assigns.current_user_id == nil
    end

    test "an unrenewable session signs the user out rather than half-working", %{conn: conn} do
      # Past its expiry, so `ensure_fresh/2` attempts a renewal. Supabase is not
      # configured in the test environment, so that attempt fails without a
      # network call — which is the same shape as a revoked refresh token, and
      # must end in "signed out" rather than "signed in with a dead token".
      expired = session_fixture(expires_at: DateTime.add(DateTime.utc_now(), -60))

      conn = conn |> log_in_user(expired) |> get(~p"/")

      assert conn.assigns.current_user_id == nil
      refute get_session(conn, "user_session")
    end
  end

  describe "require_authenticated_user/2" do
    test "remembers where the user was going", %{conn: conn} do
      # The difference between "sign in and land where you meant to be" and
      # "sign in and land on a page you have to navigate away from".
      conn = get(conn, ~p"/connections")

      assert redirected_to(conn) == ~p"/sign-in"
      assert get_session(conn, :user_return_to) == "/connections"
    end

    test "signing in afterwards returns the user there", %{conn: conn} do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_return_to, "/transfers")
        |> UserAuth.log_in_user(session_fixture())

      assert redirected_to(conn) == "/transfers"
    end

    test "signing in with nowhere in mind lands somewhere useful", %{conn: conn} do
      # Connections rather than the home page: a new account can do nothing at
      # all until a service is attached, so this is the one screen that is never
      # a dead end.
      conn =
        conn |> Phoenix.ConnTest.init_test_session(%{}) |> UserAuth.log_in_user(session_fixture())

      assert redirected_to(conn) == ~p"/connections"
    end

    test "does not remember a non-GET destination" do
      # Sending the user back to a POST after sign-in would mean reissuing it,
      # resubmitting whatever it carried. Only a GET is safe to replay.
      #
      # The plug is called directly rather than through a route: there is no
      # non-GET route behind this pipeline to aim at, and inventing one would
      # be testing the router instead of the rule.
      conn =
        Phoenix.ConnTest.build_conn(:post, "/connections", %{})
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert conn.halted
      assert get_session(conn, :user_return_to) == nil
    end
  end

  describe "session fixation" do
    test "signing in discards anything already in the session", %{conn: conn} do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:planted_by_an_attacker, "value")
        |> UserAuth.log_in_user(session_fixture())

      refute get_session(conn, :planted_by_an_attacker)
    end

    test "signing out discards the session", %{conn: conn} do
      conn = conn |> log_in_user(session_fixture()) |> UserAuth.log_out_user()

      refute get_session(conn, "user_session")
    end
  end
end
