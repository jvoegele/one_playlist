defmodule OnePlaylist.AuthFixtures do
  @moduledoc """
  Users for tests.

  Rows go straight into `auth.users` because Supabase Auth owns that table and
  this application has no sign-up flow yet. When Supabase Auth sign-in exists,
  this is the one place that changes rather than every test that needs a user.
  """

  alias Ecto.Adapters.SQL
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
end
