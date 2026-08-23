defmodule OnePlaylistWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use OnePlaylistWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint OnePlaylistWeb.Endpoint

      use OnePlaylistWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import OnePlaylistWeb.ConnCase
    end
  end

  setup tags do
    OnePlaylist.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Signs a user in, for tests that need to be past the front door.

  Was written three times — in `tidal_auth_controller_test.exs`,
  `transfer_live_test.exs` and `connection_live_test.exs` — with three different
  names and two different session shapes. When the session stopped being a bare
  user id, all three broke, which is the argument for having one.

  Deliberately calls `OnePlaylistWeb.UserAuth.put_user_session/2` rather than
  writing the session key directly: a test that fakes the cookie's *shape* stops
  proving anything the moment the real shape changes, and would have kept
  passing through exactly the change that broke the application.
  """
  def log_in_user(conn, session_or_user_id)

  def log_in_user(conn, %OnePlaylist.Accounts.Session{} = session) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> OnePlaylistWeb.UserAuth.put_user_session(session)
  end

  def log_in_user(conn, user_id) when is_binary(user_id) do
    log_in_user(conn, OnePlaylist.AuthFixtures.session_fixture(user_id: user_id))
  end
end
