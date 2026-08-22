defmodule OnePlaylist.Providers.RLSTest do
  @moduledoc """
  Exercises the Row Level Security policies on `provider_connections` the way
  Supabase's own services would reach them: as the `authenticated` role, with a
  JWT subject claim set, rather than as the table owner.

  The application connects as the owner and so is not subject to these policies
  — they are defence in depth. That is precisely why they need a test. A wrong
  policy fails quietly, and nothing in the ordinary suite would notice.

  These are `async: false` because they change the role and settings of the
  connection they run on.
  """

  use OnePlaylist.DataCase, async: false

  import OnePlaylist.AuthFixtures

  alias Ecto.Adapters.SQL
  alias OnePlaylist.Providers

  setup do
    alice = user_id_fixture()
    bob = user_id_fixture()

    {:ok, _} = connect(alice, "alice-spotify")
    {:ok, _} = connect(bob, "bob-spotify")

    %{alice: alice, bob: bob}
  end

  test "a user sees only their own connections", %{alice: alice} do
    rows = as_user(alice, "select provider_user_id from provider_connections")

    assert rows == [["alice-spotify"]],
           "RLS must scope selects to the JWT subject, got: #{inspect(rows)}"
  end

  test "a user cannot read another user's connection", %{alice: alice, bob: bob} do
    rows =
      as_user(alice, "select provider_user_id from provider_connections where user_id = $1", [
        Ecto.UUID.dump!(bob)
      ])

    assert rows == [], "one user's rows must be invisible to another"
  end

  test "a user cannot update another user's connection", %{alice: alice, bob: bob} do
    rows =
      as_user(
        alice,
        "update provider_connections set display_name = 'hijacked' where user_id = $1 returning id",
        [Ecto.UUID.dump!(bob)]
      )

    assert rows == [], "the update must match no rows rather than succeed"

    # And confirm it really did not happen, read back as the owner.
    {:ok, bobs} = Providers.fetch_connection(bob, :spotify)
    refute bobs.display_name == "hijacked"
  end

  test "a user cannot delete another user's connection", %{alice: alice, bob: bob} do
    rows =
      as_user(alice, "delete from provider_connections where user_id = $1 returning id", [
        Ecto.UUID.dump!(bob)
      ])

    assert rows == []
    assert {:ok, _still_there} = Providers.fetch_connection(bob, :spotify)
  end

  test "a user cannot insert a row owned by someone else", %{alice: alice, bob: bob} do
    assert_raise Postgrex.Error, ~r/row-level security/, fn ->
      as_user(
        alice,
        """
        insert into provider_connections (id, user_id, provider, provider_user_id, scopes, status, inserted_at, updated_at)
        values (gen_random_uuid(), $1, 'tidal', 'smuggled', '{}', 'active', now(), now())
        """,
        [Ecto.UUID.dump!(bob)]
      )
    end
  end

  test "an anonymous caller sees nothing at all", %{alice: _alice} do
    # `anon` was revoked entirely rather than merely policy-restricted, so this
    # is a permission error, not an empty result.
    assert_raise Postgrex.Error, ~r/permission denied/, fn ->
      as_role("anon", nil, "select provider_user_id from provider_connections", [])
    end
  end

  defp as_user(user_id, sql, params \\ []), do: as_role("authenticated", user_id, sql, params)

  defp as_role(role, subject, sql, params) do
    # `set local` is scoped to the surrounding transaction — which, inside the
    # Ecto sandbox, is the test itself — so the role reverts automatically.
    SQL.query!(Repo, "set local role #{role}", [])

    if subject do
      SQL.query!(Repo, "select set_config('request.jwt.claim.sub', $1, true)", [subject])
    end

    %{rows: rows} = SQL.query!(Repo, sql, params)
    rows
  after
    SQL.query!(Repo, "set local role postgres", [])
  end

  defp connect(user_id, provider_user_id) do
    Providers.connect(user_id, :spotify, %{
      provider_user_id: provider_user_id,
      display_name: "Original",
      access_token: "token",
      refresh_token: "refresh"
    })
  end
end
