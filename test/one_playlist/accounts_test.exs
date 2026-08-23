defmodule OnePlaylist.AccountsTest do
  @moduledoc """
  The context, against a **real** GoTrue.

  ## Why these talk to the service instead of stubbing it

  `supabase_potion` picks its HTTP client per request, inside the SDK, so the
  `Req.Test` stubs the rest of this suite uses cannot reach it. The alternatives
  were a behaviour with a swappable implementation — whose configuration is
  global state, and `CLAUDE.md` records two days lost to exactly that in async
  tests — or talking to the local stack, which is already a hard requirement for
  running any of this suite at all, since the database *is* Supabase's Postgres.

  So these are integration tests and are tagged as such. They are **excluded by
  default** (`test/test_helper.exs`) and run with:

      SUPABASE_URL=http://127.0.0.1:54321 \\
        SUPABASE_PUBLISHABLE_KEY=$(supabase status -o env | grep ^ANON_KEY= | cut -d= -f2-) \\
        mix test --include supabase

  `config/runtime.exs` reads those two variables in every environment, so no
  test here calls `Application.put_env/3` — the one thing that would make this
  file dangerous to the ones running beside it.

  ## Every account these tests create is permanent

  GoTrue writes `auth.users` over its own connection, outside the Ecto sandbox,
  so nothing here is rolled back. Two consequences, both learned the hard way:

    * Addresses must be unique **across runs**, not merely within one.
      `System.unique_integer/1` restarts with the VM, so on the second run it
      hands back the same numbers and `sign_up/2` answers `:already_registered`.
      `unique_email/0` mixes in the wall clock for that reason.
    * Nothing may assert on how many users exist, or on a specific address being
      absent.

  `supabase db reset` clears them, at the cost of the rest of the local database.
  """

  # `DataCase` rather than `ExUnit.Case`: one test reads `auth.users` through
  # the Repo, which needs a sandbox checkout. `async: false` because these hit a
  # shared external service with its own rate limits.
  use OnePlaylist.DataCase, async: false

  alias OnePlaylist.Accounts
  alias OnePlaylist.Accounts.Session

  @moduletag :supabase

  setup do
    unless OnePlaylist.Supabase.configured?() do
      flunk("""
      Supabase is not configured, so these tests cannot run.

      See this module's documentation for the two environment variables and the
      command that sets them.
      """)
    end

    %{email: unique_email(), password: "a-perfectly-fine-password"}
  end

  describe "sign_up/2 and sign_in/2" do
    test "a new account can sign in", %{email: email, password: password} do
      assert {:ok, %Session{} = created} = Accounts.sign_up(email, password)
      assert {:ok, %Session{} = signed_in} = Accounts.sign_in(email, password)

      assert signed_in.user_id == created.user_id
      assert signed_in.email == email
      assert Session.well_formed?(signed_in)
      assert Session.fresh?(signed_in)
    end

    test "the user really exists in auth.users", %{email: email, password: password} do
      # The point of using Supabase Auth rather than `mix phx.gen.auth`:
      # `provider_connections.user_id` has a foreign key onto this table, so a
      # session is only useful if the row behind it is real.
      {:ok, session} = Accounts.sign_up(email, password)

      %{rows: [[count]]} =
        Ecto.Adapters.SQL.query!(
          OnePlaylist.Repo,
          "select count(*) from auth.users where id = $1",
          [Ecto.UUID.dump!(session.user_id)]
        )

      assert count == 1
    end

    test "a wrong password is a domain error the form can act on", %{
      email: email,
      password: password
    } do
      {:ok, _session} = Accounts.sign_up(email, password)

      assert {:error, error} = Accounts.sign_in(email, "not the password")
      assert error.__struct__ == Accounts.SignInFailed
      assert error.reason == :invalid_credentials
    end

    test "an account that does not exist fails the same way as a wrong password" do
      # Deliberately indistinguishable. Telling them apart would tell an
      # attacker which addresses have accounts here, and GoTrue itself answers
      # both with `invalid_credentials`.
      assert {:error, error} = Accounts.sign_in("no-such-user@one-playlist.test", "whatever")
      assert error.reason == :invalid_credentials
    end

    test "a password GoTrue considers too weak says so specifically", %{email: email} do
      # Separated from `:invalid_credentials` because the user can act on it
      # differently: a different password, not a retyped one.
      assert {:error, error} = Accounts.sign_up(email, "abc")
      assert error.reason == :weak_password
      assert Errata.display_message(error) =~ "6 characters"
    end
  end

  describe "refresh/1" do
    test "rotates both tokens", %{email: email, password: password} do
      # `enable_refresh_token_rotation = true`, so the old refresh token is
      # spent. Keeping it would present a used one on the next renewal, which
      # GoTrue treats as theft and answers by revoking the whole family.
      {:ok, session} = Accounts.sign_up(email, password)

      assert {:ok, renewed} = Accounts.refresh(session)
      assert renewed.user_id == session.user_id
      assert renewed.refresh_token != session.refresh_token
      assert renewed.access_token != session.access_token
    end

    test "ensure_fresh/2 leaves a healthy session alone", %{email: email, password: password} do
      {:ok, session} = Accounts.sign_up(email, password)

      assert {:ok, ^session} = Accounts.ensure_fresh(session)
    end

    test "ensure_fresh/2 renews one that is near expiry", %{email: email, password: password} do
      {:ok, session} = Accounts.sign_up(email, password)

      # Rather than wait an hour: ask as though it were nearly the expiry.
      almost_expired = DateTime.add(session.expires_at, -5, :second)

      assert {:ok, renewed} = Accounts.ensure_fresh(session, almost_expired)
      assert renewed.refresh_token != session.refresh_token
    end
  end

  describe "claims/1" do
    test "verifies the token locally and reports who it belongs to", %{
      email: email,
      password: password
    } do
      # ES256 against the project's JWKS, in process. `role` is what an RLS
      # policy runs as, and is the reason this matters beyond identity.
      {:ok, session} = Accounts.sign_up(email, password)

      assert {:ok, claims} = Accounts.claims(session.access_token)
      assert claims["sub"] == session.user_id
      assert claims["role"] == "authenticated"
    end

    test "rejects a token that is not one of ours" do
      assert {:error, _error} = Accounts.claims("not.a.jwt")
    end
  end

  describe "sign_out/1" do
    test "revokes the session and always answers :ok", %{email: email, password: password} do
      {:ok, session} = Accounts.sign_up(email, password)

      assert :ok = Accounts.sign_out(session)

      # Revoked, so renewing it must now fail — which is what makes signing out
      # mean something rather than merely dropping a cookie.
      assert {:error, _error} = Accounts.refresh(session)
    end

    test "answers :ok even for a session GoTrue has never heard of" do
      # A user clicking "sign out" must end up signed out even when the remote
      # call cannot succeed.
      stale = %Session{
        user_id: Ecto.UUID.generate(),
        email: "nobody@one-playlist.test",
        access_token: "not-a-real-token",
        refresh_token: "not-a-real-token",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      }

      assert :ok = Accounts.sign_out(stale)
    end
  end

  # Unique across runs, not merely within one — see the note above.
  defp unique_email do
    "test-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}@one-playlist.test"
  end
end
