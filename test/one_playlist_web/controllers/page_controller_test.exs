defmodule OnePlaylistWeb.PageControllerTest do
  @moduledoc """
  The landing page, which matters more than a landing page usually does: it is
  where the TIDAL OAuth callback, dev sign-in and every
  `require_authenticated_user/2` redirect all come back to.
  """

  use OnePlaylistWeb.ConnCase

  alias OnePlaylist.AuthFixtures

  test "GET / says what this application does", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert html_response(conn, 200) =~ "Move a playlist"
  end

  test "a signed-out visitor is not offered links that would only bounce them back", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    refute html =~ ~s|href="/connections"|
  end

  test "a signed-in user can get to their connections from here", %{conn: conn} do
    # The whole point of the navigation: before this, a Subsonic server could
    # only be attached by running a script against a live node.
    html =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> log_in_user(AuthFixtures.user_id_fixture())
      |> get(~p"/")
      |> html_response(200)

    assert html =~ ~s|href="/connections"|
    assert html =~ ~s|href="/transfers|
  end
end
