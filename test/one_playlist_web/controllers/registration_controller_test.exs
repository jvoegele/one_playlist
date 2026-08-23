defmodule OnePlaylistWeb.RegistrationControllerTest do
  @moduledoc """
  The sign-up page. Hermetic, for the reason
  `OnePlaylistWeb.SessionControllerTest` gives.
  """

  use OnePlaylistWeb.ConnCase, async: true

  import OnePlaylist.AuthFixtures

  describe "GET /sign-up" do
    test "renders the form", %{conn: conn} do
      response = conn |> get(~p"/sign-up") |> html_response(200)

      assert response =~ "Create an account"
      assert response =~ ~s(name="user[email]")
    end

    test "asks the password manager for a new password, not a saved one", %{conn: conn} do
      # `new-password` makes a password manager offer to generate one. With
      # `current-password` it offers a saved credential instead, which on a
      # sign-up form is always the wrong entry — and reads to the user as a
      # browser bug rather than a mistake here.
      response = conn |> get(~p"/sign-up") |> html_response(200)

      assert response =~ ~s(autocomplete="new-password")
    end

    test "a signed-in user is sent on", %{conn: conn} do
      conn = conn |> log_in_user(session_fixture()) |> get(~p"/sign-up")

      assert redirected_to(conn) == ~p"/connections"
    end
  end

  describe "POST /sign-up" do
    test "a rejected sign-up keeps the email and drops the password", %{conn: conn} do
      # A password GoTrue rejects as too short, so this fails for the same
      # reason whether or not Supabase is configured — unconfigured it is
      # `:not_configured`, configured it is `:weak_password`, and both render
      # the form again with a 422. A password that would *succeed* against a
      # real GoTrue would make this test pass or fail depending on the
      # environment it happened to run in.
      email = "nobody-#{System.system_time(:nanosecond)}@example.test"

      conn = post(conn, ~p"/sign-up", %{"user" => %{"email" => email, "password" => "abc"}})

      response = html_response(conn, 422)

      assert response =~ email
      refute response =~ "abc\""
    end
  end

  describe "the two pages link to each other" do
    test "sign-in offers sign-up and vice versa", %{conn: conn} do
      # Each page is a dead end for the half of visitors who wanted the other.
      assert conn |> get(~p"/sign-in") |> html_response(200) =~ ~s(href="/sign-up")
      assert conn |> get(~p"/sign-up") |> html_response(200) =~ ~s(href="/sign-in")
    end
  end
end
