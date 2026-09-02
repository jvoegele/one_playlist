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

  require WaitForIt

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

  describe "magic links" do
    # Each of these sends a real email, against `email_sent` per hour in
    # supabase/config.toml — raised to 30 locally for this reason. Two are
    # sent per run, to different addresses.

    test "the emailed link signs the address in, from any browser", %{email: email} do
      # Nothing is held in a cookie between the request and the click: the
      # token hash is verified against GoTrue. So the test needs no conn, and
      # neither does a person opening the email on a different device.
      assert :ok = Accounts.send_magic_link(email)

      %{token_hash: token_hash} = sign_in_email(email)

      assert {:ok, %Session{} = session} = Accounts.verify_magic_link(token_hash)
      assert session.email == email
      assert Session.well_formed?(session)

      # A magic link to an unknown address is also how somebody signs up.
      %{rows: [[count]]} =
        Ecto.Adapters.SQL.query!(
          OnePlaylist.Repo,
          "select count(*) from auth.users where id = $1",
          [Ecto.UUID.dump!(session.user_id)]
        )

      assert count == 1

      # Single use. A second click — or a forwarded email — gets nothing.
      assert {:error, error} = Accounts.verify_magic_link(token_hash)
      assert error.reason == :link_expired
    end

    test "the six-digit code from the same email signs the address in too", %{email: email} do
      assert :ok = Accounts.send_magic_link(email)

      %{code: code} = sign_in_email(email)

      assert {:ok, %Session{} = session} = Accounts.verify_email_code(email, code)
      assert session.email == email
    end

    test "a hash GoTrue never issued is the same failure as a stale one" do
      assert {:error, error} = Accounts.verify_magic_link("not-a-token-hash")
      assert error.__struct__ == Accounts.SignInFailed
      assert error.reason == :link_expired
    end

    test "a code for an address with no pending attempt fails without saying why", %{
      email: email
    } do
      # Distinguishing "no such attempt" from "wrong digits" would confirm to a
      # guesser which addresses have a live one.
      assert {:error, error} = Accounts.verify_email_code(email, "000000")
      assert error.reason == :link_expired
    end
  end

  describe "Google sign-in" do
    test "begin_google_sign_in/1 hands back a GoTrue URL and the verifier to finish it with" do
      # No network: the SDK builds the URL. So this is hermetic in everything
      # but needing a configured base URL, which is why it lives with the
      # tagged tests rather than the controller's.
      callback = "http://localhost:4000/auth/callback"

      assert {:ok, %{url: url, code_verifier: verifier}} = Accounts.begin_google_sign_in(callback)

      %URI{path: path, query: query} = URI.parse(url)
      assert String.ends_with?(path, "/auth/v1/authorize")

      params = URI.decode_query(query)
      assert params["provider"] == "google"
      assert params["redirect_to"] == callback
      assert params["code_challenge_method"] == "s256"

      # The pair actually corresponds — a verifier that did not hash to the
      # challenge in the URL would fail at the exchange, silently, later.
      assert params["code_challenge"] == Supabase.Auth.PKCE.generate_challenge(verifier)
    end

    test "exchange_code/2 refuses a code GoTrue never issued" do
      assert {:error, error} = Accounts.exchange_code("not-a-code", "not-a-verifier")
      assert error.__struct__ == Accounts.SignInFailed
      assert error.reason == :link_expired
    end
  end

  # Reads the sign-in email GoTrue sent to `email` out of Mailpit, which the
  # local stack routes all mail to (`supabase status` prints `MAILPIT_URL`).
  # Returns the token hash from the link and the six-digit code from the body.
  #
  # `match_wait` because delivery is asynchronous from the request that caused
  # it: `send_magic_link/1` returns when GoTrue has accepted the send, not when
  # Mailpit has indexed the message.
  defp sign_in_email(email) do
    {:ok, %{"ID" => id}} =
      WaitForIt.match_wait({:ok, %{"ID" => _}}, latest_mail_to(email), timeout: 10_000)

    %{"HTML" => html} = mailpit!("/api/v1/message/#{id}").body

    [_, token_hash] = Regex.run(~r/token_hash=([^&"]+)/, html)
    [_, code] = Regex.run(~r/<strong>(\d{6})<\/strong>/, html)

    %{token_hash: token_hash, code: code}
  end

  defp latest_mail_to(email) do
    case mailpit!("/api/v1/search", params: [query: ~s(to:"#{email}")]).body do
      %{"messages" => [message | _]} -> {:ok, message}
      _nothing_yet -> :none
    end
  end

  defp mailpit!(path, opts \\ []) do
    Req.get!(Keyword.merge([base_url: mailpit_url(), url: path], opts))
  end

  defp mailpit_url, do: System.get_env("MAILPIT_URL", "http://127.0.0.1:54324")

  # Unique across runs, not merely within one — see the note above.
  defp unique_email do
    "test-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}@one-playlist.test"
  end
end
