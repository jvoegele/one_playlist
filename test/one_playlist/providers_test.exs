defmodule OnePlaylist.ProvidersTest do
  use OnePlaylist.DataCase, async: true
  # `Errata.create/2` is a macro, so the calling module has to require Errata.
  use Errata

  alias Ecto.Adapters.SQL
  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.ConnectionNotFound
  alias OnePlaylist.Providers.ConnectionUnusable
  alias OnePlaylist.Providers.TokenRefreshFailed

  @access_token "BQC-fake-access-token"
  @refresh_token "AQD-fake-refresh-token"

  setup do
    %{user_id: create_auth_user()}
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
      other = create_auth_user()

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
      soon = create_auth_user()
      later = create_auth_user()

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

  # provider_connections has a foreign key onto auth.users, which Supabase Auth
  # owns. Inserting there directly is the pragmatic way to get a user id in a
  # test; once sign-in exists this should go through it instead.
  defp create_auth_user do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values ($1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', $2, now(), now())
      """,
      [Ecto.UUID.dump!(id), "user-#{System.unique_integer([:positive])}@example.test"]
    )

    id
  end
end
