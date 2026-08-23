defmodule OnePlaylist.AuthFixtures do
  @moduledoc """
  Users for tests.

  Rows go straight into `auth.users` because Supabase Auth owns that table:
  `OnePlaylist.Accounts.sign_up/2` is the real way in, and calling it from a test
  would mean a network round trip to GoTrue and a user the Ecto sandbox cannot
  roll back — GoTrue writes over its own connection, outside the sandbox
  entirely.

  So a test that merely *needs somebody to exist* inserts the row directly, and
  `session_fixture/1` mints a matching session without contacting GoTrue. The
  tests that exercise the real sign-in path are the tagged ones in
  `test/one_playlist/accounts_test.exs`, and they are the only ones that talk to
  the service.
  """

  alias Ecto.Adapters.SQL
  alias OnePlaylist.Accounts.Session
  alias OnePlaylist.Repo

  @doc """
  Creates a user in `auth.users` and returns its id.

  `provider_connections` has a foreign key onto that table, so almost every test
  touching connections needs one.
  """
  @spec user_id_fixture(keyword()) :: Ecto.UUID.t()
  def user_id_fixture(opts \\ []) do
    id = Keyword.get_lazy(opts, :id, &Ecto.UUID.generate/0)
    email = Keyword.get_lazy(opts, :email, &unique_email/0)

    # `_ =` rather than a bare call: this module lives in test/support, which is
    # compiled, so Dialyzer's :unmatched_returns sees it — unlike the .exs test
    # files this was extracted from.
    _ =
      SQL.query!(
        Repo,
        """
        insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
        values ($1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', $2, now(), now())
        """,
        [Ecto.UUID.dump!(id), email]
      )

    id
  end

  @doc "An email no other test will collide with."
  @spec unique_email() :: String.t()
  def unique_email, do: "user-#{System.unique_integer([:positive])}@example.test"

  @doc """
  A session for a user, without involving GoTrue.

  The tokens are obvious fakes: nothing in the tests that use this ever presents
  them to Supabase, because `expires_at` is far enough away that
  `OnePlaylist.Accounts.ensure_fresh/2` never tries to renew. A test that wants
  a *renewal* to happen sets `expires_at` in the past and gets a real attempt —
  which is the point of making the expiry a parameter rather than a constant.
  """
  @spec session_fixture(keyword()) :: Session.t()
  def session_fixture(opts \\ []) do
    user_id = Keyword.get_lazy(opts, :user_id, fn -> user_id_fixture() end)

    %Session{
      user_id: user_id,
      email: Keyword.get_lazy(opts, :email, &unique_email/0),
      access_token: Keyword.get(opts, :access_token, "test-access-token"),
      refresh_token: Keyword.get(opts, :refresh_token, "test-refresh-token"),
      expires_at:
        Keyword.get_lazy(opts, :expires_at, fn -> DateTime.add(DateTime.utc_now(), 3600) end)
    }
  end
end
