defmodule OnePlaylist.RepoTest do
  @moduledoc """
  `as_user/3` — the seam that puts this application's own queries under RLS.

  Every test here uses a **deliberately unscoped** query. That is the whole
  point: scoped queries return the right rows whether or not RLS is working, so
  they cannot tell you whether it is. Only a query that *would* leak proves the
  database is doing the work.
  """

  use OnePlaylist.DataCase, async: true
  use Bond.Test

  import Ecto.Query

  alias OnePlaylist.AuthFixtures
  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Connection

  # No `where`. Anywhere else in this repository this would be a bug.
  @unscoped from(c in Connection, select: c.user_id)

  defp connection_for(user_id) do
    {:ok, connection} =
      Providers.connect(user_id, :tidal, %{
        provider_user_id: "p-#{System.unique_integer([:positive])}",
        access_token: "at",
        refresh_token: "rt",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
        scopes: ["playlists.read"]
      })

    connection
  end

  describe "without as_user/3" do
    test "an unscoped query returns everybody's rows" do
      # Not a defect being demonstrated — this is what `BYPASSRLS` means, and it
      # is why `as_user/3` exists. Pinned so that if the connection role ever
      # changes, the change is noticed here rather than inferred from a
      # mysteriously empty page.
      alice = AuthFixtures.user_id_fixture()
      bob = AuthFixtures.user_id_fixture()
      _ = connection_for(alice)
      _ = connection_for(bob)

      rows = Repo.all(@unscoped)

      assert alice in rows
      assert bob in rows
      assert Repo.current_role() == "postgres"
      assert Repo.current_user_id() == nil
    end
  end

  describe "as_user/3" do
    test "an unscoped query returns only that user's rows" do
      alice = AuthFixtures.user_id_fixture()
      bob = AuthFixtures.user_id_fixture()
      _ = connection_for(alice)
      _ = connection_for(bob)

      assert {:ok, rows} = Repo.as_user(alice, fn -> Repo.all(@unscoped) end)

      assert rows == [alice]
      refute bob in rows
    end

    test "steps down to authenticated and says who it is" do
      # Asserting on rows alone cannot distinguish "RLS filtered them" from
      # "there were none", so the mechanism is checked directly.
      alice = AuthFixtures.user_id_fixture()

      assert {:ok, {role, uid}} =
               Repo.as_user(alice, fn -> {Repo.current_role(), Repo.current_user_id()} end)

      assert role == "authenticated"
      assert uid == alice
    end

    test "a user with nothing sees nothing, rather than everything" do
      owner = AuthFixtures.user_id_fixture()
      _ = connection_for(owner)
      stranger = AuthFixtures.user_id_fixture()

      assert {:ok, []} = Repo.as_user(stranger, fn -> Repo.all(@unscoped) end)
    end

    test "the value comes back through the transaction tuple" do
      alice = AuthFixtures.user_id_fixture()

      assert {:ok, :whatever} = Repo.as_user(alice, fn -> :whatever end)
    end
  end

  describe "restoring privileges" do
    test "the role is back to postgres afterwards" do
      # The sandbox holds one transaction for the whole test, so `Repo.transaction/2`
      # inside it opens a *savepoint*. Releasing a savepoint does not undo a
      # `SET LOCAL` made within it — without the explicit revert, the connection
      # would stay `authenticated` for the rest of this test.
      alice = AuthFixtures.user_id_fixture()

      {:ok, _} = Repo.as_user(alice, fn -> :ok end)

      assert Repo.current_role() == "postgres"
      assert Repo.current_user_id() == nil
    end

    test "privileges come back even when the body raises" do
      # The case that would otherwise poison the connection: an exception skips
      # any cleanup that is not in an `after`.
      alice = AuthFixtures.user_id_fixture()

      assert_raise RuntimeError, fn ->
        Repo.as_user(alice, fn -> raise "boom" end)
      end

      assert Repo.current_role() == "postgres"
    end

    test "a privileged query works again immediately afterwards" do
      # The observable consequence of getting the revert wrong: the *next*
      # unrelated query fails, somewhere with no clue as to why.
      alice = AuthFixtures.user_id_fixture()

      {:ok, _} = Repo.as_user(alice, fn -> :ok end)

      assert is_integer(Repo.aggregate(Connection, :count))
    end
  end

  describe "establishing identity unambiguously" do
    test "a stale singular claim cannot override as_user/3" do
      # `auth.uid()` is
      # `coalesce(request.jwt.claim.sub, request.jwt.claims->>'sub')`, so the
      # legacy singular setting *wins*. Anything that had set it — another test,
      # a console session, a future helper — would silently redirect every query
      # inside `as_user/3` to the wrong user.
      #
      # Found for real: `providers/rls_test.exs` sets it and does not clear it,
      # which made `Providers.fetch_connection/2` report a perfectly good
      # connection as "not connected" once that function started scoping.
      alice = AuthFixtures.user_id_fixture()
      bob = AuthFixtures.user_id_fixture()
      _ = connection_for(bob)

      Ecto.Adapters.SQL.query!(
        Repo,
        "select set_config('request.jwt.claim.sub', $1, true)",
        [alice]
      )

      assert {:ok, [^bob]} = Repo.as_user(bob, fn -> Repo.all(@unscoped) end)
    end

    test "both claim settings are cleared afterwards" do
      # Leaving either behind would scope a *later* privileged query to a user
      # who is no longer the subject of the request.
      alice = AuthFixtures.user_id_fixture()

      {:ok, _} = Repo.as_user(alice, fn -> :ok end)

      assert Repo.current_user_id() == nil
    end
  end

  describe "the contract" do
    test "a blank user id is refused rather than quietly matching nothing" do
      # `auth.uid()` casts the claim to uuid, and `""` casts to NULL without
      # raising — so every `auth.uid() = user_id` comparison becomes NULL, which
      # is not true, which returns no rows. A session scoped to nobody is
      # indistinguishable from a user who owns nothing.
      assert_precondition_violation(Repo.as_user("", fn -> :ok end), label: :user_is_identified)
    end

    test "a nil user id is refused" do
      assert_precondition_violation(Repo.as_user(nil, fn -> :ok end), label: :user_is_identified)
    end
  end
end
