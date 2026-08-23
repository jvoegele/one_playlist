defmodule OnePlaylist.ProvidersTest do
  use OnePlaylist.DataCase, async: true

  import OnePlaylist.AuthFixtures
  import Req.Test, only: [set_req_test_from_context: 1]
  # `Errata.create/2` is a macro, so the calling module has to require Errata.
  use Errata

  # The capability declarations are the point of `supports?/2`, and nothing
  # else asserts them: TIDAL quietly dropping `:artwork` would only show up as
  # covers disappearing from a page.
  doctest OnePlaylist.Providers, only: [supports?: 2]

  alias Ecto.Adapters.SQL
  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.ConnectionNotFound
  alias OnePlaylist.Providers.ConnectionUnusable
  alias OnePlaylist.Providers.Navidrome
  alias OnePlaylist.Providers.SubsonicCredentials
  alias OnePlaylist.Providers.TokenRefreshFailed

  @access_token "BQC-fake-access-token"
  @refresh_token "AQD-fake-refresh-token"

  # `connect_subsonic/2` calls the server before it stores anything, so this file
  # now needs the Req stub owned per-test (it is `async: true`).
  setup :set_req_test_from_context

  setup do
    %{user_id: user_id_fixture()}
  end

  describe "connect/3" do
    test "stores a connection", %{user_id: user_id} do
      assert {:ok, connection} = connect(user_id)
      assert connection.provider == :spotify
      assert connection.access_token == @access_token
      assert connection.status == :active
    end

    test "reconnecting replaces tokens rather than creating a second row", %{user_id: user_id} do
      assert {:ok, first} = connect(user_id)
      assert {:ok, second} = connect(user_id, access_token: "BQC-rotated")

      assert first.id == second.id
      assert second.access_token == "BQC-rotated"
      assert [_only_one] = Providers.list_connections(user_id)
    end

    test "reconnecting clears a previous failure", %{user_id: user_id} do
      {:ok, connection} = connect(user_id)
      {:ok, failed} = Providers.record_failure(connection, dead_grant())
      assert failed.status == :reauth_required

      assert {:ok, reconnected} = connect(user_id)
      assert reconnected.status == :active
      assert reconnected.consecutive_failures == 0
      assert reconnected.last_error == nil
    end

    test "rejects a user that does not exist" do
      assert {:error, changeset} = connect(Ecto.UUID.generate())
      assert %{user_id: _} = errors_on(changeset)
    end
  end

  describe "fetch_usable_connection/2" do
    test "returns the connection when it is usable", %{user_id: user_id} do
      {:ok, _} = connect(user_id)
      assert {:ok, %Connection{}} = Providers.fetch_usable_connection(user_id, :spotify)
    end

    test "distinguishes 'never connected' from 'needs reconnecting'", %{user_id: user_id} do
      assert {:error, %ConnectionNotFound{} = missing} =
               Providers.fetch_usable_connection(user_id, :tidal)

      assert Errata.http_status(missing) == 404
      assert Errata.code(missing) == "PROVIDER_NOT_CONNECTED"

      {:ok, connection} = connect(user_id)
      {:ok, _} = Providers.record_failure(connection, dead_grant())

      assert {:error, %ConnectionUnusable{} = unusable} =
               Providers.fetch_usable_connection(user_id, :spotify)

      assert Errata.http_status(unusable) == 403
      assert Errata.reason(unusable) == :reauth_required
    end

    test "one user cannot reach another's connection", %{user_id: user_id} do
      {:ok, _} = connect(user_id)
      other = user_id_fixture()

      assert {:error, %ConnectionNotFound{}} =
               Providers.fetch_usable_connection(other, :spotify)
    end
  end

  describe "record_failure/2" do
    test "a transient failure leaves the connection active", %{user_id: user_id} do
      {:ok, connection} = connect(user_id)

      transient =
        Errata.create(TokenRefreshFailed,
          reason: :provider_unavailable,
          context: %{provider: :spotify}
        )

      assert Errata.retryable?(transient)
      assert {:ok, updated} = Providers.record_failure(connection, transient)

      assert updated.status == :active, "a provider outage must not mass-disconnect users"
      assert updated.consecutive_failures == 1
    end

    test "a dead grant requires re-authorization", %{user_id: user_id} do
      {:ok, connection} = connect(user_id)

      refute Errata.retryable?(dead_grant())
      assert {:ok, updated} = Providers.record_failure(connection, dead_grant())
      assert updated.status == :reauth_required
    end

    test "failures accumulate", %{user_id: user_id} do
      {:ok, connection} = connect(user_id)
      {:ok, once} = Providers.record_failure(connection, dead_grant())
      {:ok, twice} = Providers.record_failure(once, dead_grant())

      assert twice.consecutive_failures == 2
    end
  end

  describe "connections_due_for_refresh/2" do
    test "finds tokens expiring inside the window and ignores the rest", %{user_id: user_id} do
      soon = user_id_fixture()
      later = user_id_fixture()

      {:ok, _} = connect(soon, access_token_expires_at: seconds_from_now(60))
      {:ok, _} = connect(later, access_token_expires_at: seconds_from_now(3600))
      {:ok, _} = connect(user_id, access_token_expires_at: nil)

      due = Providers.connections_due_for_refresh(300) |> Enum.map(& &1.user_id)

      assert soon in due
      refute later in due, "a token with an hour left is not due"
      refute user_id in due, "a token with no expiry never becomes due"
    end

    test "ignores connections that need re-authorization", %{user_id: user_id} do
      {:ok, connection} = connect(user_id, access_token_expires_at: seconds_from_now(60))
      {:ok, _} = Providers.record_failure(connection, dead_grant())

      refute user_id in Enum.map(Providers.connections_due_for_refresh(300), & &1.user_id)
    end
  end

  describe "contracts" do
    test "every field in the upsert replace list actually round-trips", %{user_id: user_id} do
      # The `on_conflict: {:replace, [...]}` list has to be kept in step with the
      # schema by hand. A field added to one and not the other means a reconnect
      # silently keeps the stale value — which no contract can catch, because
      # the function did exactly what it was told. So it is pinned here instead.
      {:ok, _first} =
        connect(user_id,
          provider_user_id: "before",
          display_name: "Before",
          access_token: "at-before",
          refresh_token: "rt-before",
          scopes: ["before"],
          access_token_expires_at: seconds_from_now(60)
        )

      later = seconds_from_now(7200)

      {:ok, second} =
        connect(user_id,
          provider_user_id: "after",
          display_name: "After",
          access_token: "at-after",
          refresh_token: "rt-after",
          scopes: ["after"],
          access_token_expires_at: later
        )

      assert second.provider_user_id == "after"
      assert second.display_name == "After"
      assert second.access_token == "at-after"
      assert second.refresh_token == "rt-after"
      assert second.scopes == ["after"]
      assert DateTime.compare(second.access_token_expires_at, later) == :eq
    end

    test "disconnecting removes one row and leaves other users alone", %{user_id: user_id} do
      other = user_id_fixture()
      {:ok, _} = connect(user_id)
      {:ok, _} = connect(other)

      assert {:ok, removed} = Providers.disconnect(user_id, :spotify)
      assert removed.user_id == user_id

      assert {:error, _} = Providers.fetch_connection(user_id, :spotify)

      assert {:ok, _} = Providers.fetch_connection(other, :spotify),
             "another user's connection must survive"
    end

    test "disconnecting something not connected is an error, not a deletion",
         %{user_id: user_id} do
      {:ok, _} = connect(user_id)

      assert {:error, %ConnectionNotFound{}} = Providers.disconnect(user_id, :tidal)
      assert {:ok, _} = Providers.fetch_connection(user_id, :spotify)
    end

    test "the failure counter advances by exactly one", %{user_id: user_id} do
      {:ok, connection} = connect(user_id)
      {:ok, once} = Providers.record_failure(connection, dead_grant())
      {:ok, twice} = Providers.record_failure(once, dead_grant())

      assert once.consecutive_failures == 1
      assert twice.consecutive_failures == 2
    end
  end

  describe "encryption at rest" do
    test "tokens are ciphertext in Postgres", %{user_id: user_id} do
      {:ok, connection} = connect(user_id)

      %{rows: [[access, refresh]]} =
        SQL.query!(
          Repo,
          "select access_token, refresh_token from provider_connections where id = $1",
          [Ecto.UUID.dump!(connection.id)]
        )

      assert is_binary(access)
      refute access == @access_token
      refute refresh == @refresh_token

      # The plaintext must not appear anywhere in the stored bytes, not merely
      # differ from it — a broken cipher that prepended a header would still
      # pass an inequality check.
      refute String.contains?(access, @access_token)
      refute String.contains?(refresh, @refresh_token)

      # ...and it round-trips.
      assert {:ok, reloaded} = Providers.fetch_connection(user_id, :spotify)
      assert reloaded.access_token == @access_token
      assert reloaded.refresh_token == @refresh_token
    end

    test "tokens do not leak through inspect", %{user_id: user_id} do
      {:ok, connection} = connect(user_id)
      inspected = inspect(connection)

      refute String.contains?(inspected, @access_token)
      refute String.contains?(inspected, @refresh_token)
    end

    test "tokens are redacted out of a serialized error context" do
      error =
        Errata.create(TokenRefreshFailed,
          reason: :invalid_grant,
          context: %{provider: :spotify, refresh_token: @refresh_token}
        )

      serialized = error |> Errata.to_map() |> inspect()

      refute String.contains?(serialized, @refresh_token)
      assert String.contains?(serialized, "REDACTED")
    end
  end

  describe "connect_subsonic/2" do
    test "proves the credential before storing it", %{user_id: user_id} do
      Req.Test.stub(Navidrome, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.request_path == "/rest/getUser",
               "ping answers ok on a server that checks nothing; getUser does not"

        Req.Test.json(conn, subsonic_ok(%{"user" => %{"username" => "admin"}}))
      end)

      assert {:ok, connection} = Providers.connect_subsonic(user_id, subsonic_credentials())
      assert connection.provider == :navidrome
      assert connection.provider_user_id == "admin"
      assert connection.server_url == "http://music.local:4533"
      assert connection.access_token == "hunter2"
    end

    test "stores nothing when the server rejects the credential", %{user_id: user_id} do
      # The law this function exists for. Storing an unverified password moves
      # the failure to the next transfer, minutes or days later, where it reads
      # as "TIDAL is broken" rather than "you mistyped your password".
      Req.Test.stub(Navidrome, fn conn ->
        Req.Test.json(conn, subsonic_failed(40, "Wrong username or password"))
      end)

      assert {:error, error} =
               Providers.connect_subsonic(user_id, subsonic_credentials(password: "wrong"))

      assert Errata.reason(error) == :unauthorized
      assert Providers.list_connections(user_id) == []
    end

    test "a stored Subsonic connection never asks to be refreshed", %{user_id: user_id} do
      # `Navidrome.refresh_tokens/1` returns `:reauth_required` by design, so an
      # expiry set here would have `ensure_fresh/2` mark a working connection
      # dead the first time a transfer touched it. Nothing would look wrong until
      # then. Verified by mutation: giving the connection an expiry fails this.
      stub_ok()

      {:ok, connection} = Providers.connect_subsonic(user_id, subsonic_credentials())

      assert connection.access_token_expires_at == nil
      assert connection.refresh_token == nil
      refute Connection.needs_refresh?(connection, DateTime.utc_now(), 86_400)
      assert {:ok, ^connection} = Providers.ensure_fresh(connection)
    end

    test "names the connection after the host when the user did not", %{user_id: user_id} do
      stub_ok()

      {:ok, connection} = Providers.connect_subsonic(user_id, subsonic_credentials())

      assert connection.display_name == "music.local"
    end

    test "keeps the name the user chose", %{user_id: user_id} do
      stub_ok()

      {:ok, connection} =
        Providers.connect_subsonic(user_id, subsonic_credentials(display_name: "Living room Pi"))

      assert connection.display_name == "Living room Pi"
    end

    test "reconnecting replaces the credential rather than adding a row", %{user_id: user_id} do
      stub_ok()

      {:ok, first} = Providers.connect_subsonic(user_id, subsonic_credentials())

      {:ok, second} =
        Providers.connect_subsonic(user_id, subsonic_credentials(password: "rotated"))

      assert first.id == second.id
      assert second.access_token == "rotated"
      assert [_only_one] = Providers.list_connections(user_id)
    end
  end

  describe "refresh/1 establishes the precondition of what it calls" do
    test "a blank refresh token fails cleanly rather than crashing", %{user_id: user_id} do
      # Meyer's Non-Redundancy principle read from the client's side: a caller
      # must establish the precondition of what it calls.
      # `Adapter.refresh_tokens/1` requires a non-blank token, and this function
      # matched only `nil` — so `""` reached it and raised
      # `Bond.PreconditionError` out of `ensure_fresh/2`, crashing a transfer
      # where it should have told the user to reconnect.
      #
      # Reachable from a row written before `Tokens`' invariant existed: a
      # contract does not retroactively clean a database.
      {:ok, connection} = connect(user_id, refresh_token: "")

      assert {:error, error} = Providers.refresh(connection)
      assert Errata.reason(error) == :reauth_required
    end

    test "and nil still does too", %{user_id: user_id} do
      {:ok, connection} = connect(user_id, refresh_token: nil)

      assert {:error, error} = Providers.refresh(connection)
      assert Errata.reason(error) == :reauth_required
    end
  end

  describe "root_cause/1" do
    test "unwraps to the failure a user can act on" do
      # ExternalService reports that retrying did not help. That is the right
      # thing to classify on and the wrong thing to show somebody.
      cause = Errata.create(TokenRefreshFailed, reason: :invalid_grant, context: %{})
      wrapped = Errata.create(ConnectionUnusable, reason: :revoked, cause: cause)

      assert Providers.root_cause(wrapped) == cause
      assert Providers.root_cause(cause) == cause
      assert Providers.root_cause(:not_an_error) == :not_an_error
    end
  end

  defp subsonic_credentials(overrides \\ []) do
    {:ok, credentials} =
      SubsonicCredentials.apply(%{
        "server_url" => "http://music.local:4533",
        "username" => "admin",
        "password" => Keyword.get(overrides, :password, "hunter2"),
        "display_name" => Keyword.get(overrides, :display_name)
      })

    credentials
  end

  defp stub_ok do
    Req.Test.stub(Navidrome, fn conn ->
      Req.Test.json(conn, subsonic_ok(%{"user" => %{"username" => "admin"}}))
    end)
  end

  defp subsonic_ok(body),
    do: %{"subsonic-response" => Map.merge(%{"status" => "ok"}, body)}

  defp subsonic_failed(code, message) do
    %{
      "subsonic-response" => %{
        "status" => "failed",
        "error" => %{"code" => code, "message" => message}
      }
    }
  end

  defp connect(user_id, overrides \\ []) do
    attrs =
      Enum.into(overrides, %{
        provider_user_id: "spotify-user-#{System.unique_integer([:positive])}",
        display_name: "Test Account",
        access_token: @access_token,
        refresh_token: @refresh_token,
        access_token_expires_at: seconds_from_now(3600),
        scopes: ["playlist-read-private"]
      })

    Providers.connect(user_id, :spotify, attrs)
  end

  defp dead_grant do
    Errata.create(TokenRefreshFailed, reason: :invalid_grant, context: %{provider: :spotify})
  end

  defp seconds_from_now(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)
end
