defmodule OnePlaylist.Providers.RefreshTest do
  @moduledoc """
  The token refresh path, end to end: connection store → OAuth → connection
  store. This is the piece the whole application leans on unattended, so it is
  tested through the public functions rather than by stubbing the OAuth module.
  """

  use OnePlaylist.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.ConnectionUnusable
  alias OnePlaylist.Providers.Tidal
  alias OnePlaylist.Providers.TokenRefreshFailed

  use Errata

  setup do
    %{user_id: create_auth_user()}
  end

  describe "ensure_fresh/2" do
    test "a token with plenty of time left is returned untouched", %{user_id: user_id} do
      Req.Test.stub(Tidal, fn _conn -> flunk("no refresh should have been attempted") end)

      {:ok, connection} = connect(user_id, expires_in: 3600)

      assert {:ok, same} = Providers.ensure_fresh(connection)
      assert same.access_token == "at-original"
      assert same.last_refreshed_at == nil
    end

    test "a token inside the skew window is refreshed", %{user_id: user_id} do
      stub_token_response(%{"access_token" => "at-fresh", "expires_in" => 3600})

      {:ok, connection} = connect(user_id, expires_in: 60)

      assert {:ok, refreshed} = Providers.ensure_fresh(connection, skew_seconds: 300)
      assert refreshed.access_token == "at-fresh"
      assert refreshed.last_refreshed_at != nil

      # ...and it was persisted, not just returned.
      assert {:ok, reloaded} = Providers.fetch_connection(user_id, :tidal)
      assert reloaded.access_token == "at-fresh"
    end
  end

  describe "refresh/1" do
    test "keeps the existing refresh token when TIDAL does not send a new one",
         %{user_id: user_id} do
      stub_token_response(%{"access_token" => "at-fresh", "expires_in" => 3600})

      {:ok, connection} = connect(user_id, expires_in: 60)
      assert {:ok, refreshed} = Providers.refresh(connection)

      assert refreshed.refresh_token == "rt-original",
             "dropping it would end the connection at the next expiry for no reason"
    end

    test "replaces the refresh token when TIDAL rotates it", %{user_id: user_id} do
      stub_token_response(%{
        "access_token" => "at-fresh",
        "refresh_token" => "rt-rotated",
        "expires_in" => 3600
      })

      {:ok, connection} = connect(user_id, expires_in: 60)
      assert {:ok, refreshed} = Providers.refresh(connection)
      assert refreshed.refresh_token == "rt-rotated"
    end

    test "a dead grant marks the connection as needing re-authorization",
         %{user_id: user_id} do
      Req.Test.stub(Tidal, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_grant", "error_description" => "expired"})
      end)

      {:ok, connection} = connect(user_id, expires_in: 60)

      assert {:error, %TokenRefreshFailed{}} = Providers.refresh(connection)

      assert {:ok, reloaded} = Providers.fetch_connection(user_id, :tidal)
      assert reloaded.status == :reauth_required
      assert reloaded.consecutive_failures == 1
      assert reloaded.last_error =~ "could not refresh"
    end

    test "a TIDAL outage does not disconnect the user", %{user_id: user_id} do
      Req.Test.stub(Tidal, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      {:ok, connection} = connect(user_id, expires_in: 60)

      assert {:error, _error} = Providers.refresh(connection)

      assert {:ok, reloaded} = Providers.fetch_connection(user_id, :tidal)

      assert reloaded.status == :active,
             "an outage must not turn a ten-minute blip into a re-authorization campaign"

      assert reloaded.consecutive_failures == 1
    end

    test "a connection with no refresh token cannot be refreshed", %{user_id: user_id} do
      Req.Test.stub(Tidal, fn _conn -> flunk("nothing to exchange, so nothing to send") end)

      {:ok, connection} = connect(user_id, expires_in: 60, refresh_token: nil)

      assert {:error, %ConnectionUnusable{} = error} = Providers.refresh(connection)
      assert Errata.reason(error) == :reauth_required

      assert {:ok, reloaded} = Providers.fetch_connection(user_id, :tidal)
      assert reloaded.status == :reauth_required
    end
  end

  describe "connections_due_for_refresh/2 feeding refresh/1" do
    test "the scheduler's query finds exactly what ensure_fresh would refresh",
         %{user_id: user_id} do
      stub_token_response(%{"access_token" => "at-fresh", "expires_in" => 3600})

      {:ok, _} = connect(user_id, expires_in: 60)

      due = Providers.connections_due_for_refresh(300)
      assert Enum.any?(due, &(&1.user_id == user_id))

      for connection <- due, connection.user_id == user_id do
        assert {:ok, _} = Providers.refresh(connection)
      end

      assert Providers.connections_due_for_refresh(300)
             |> Enum.reject(&(&1.user_id == user_id))
             |> Kernel.==(Providers.connections_due_for_refresh(300)),
             "the refreshed connection should no longer be due"
    end
  end

  defp stub_token_response(body) do
    Req.Test.stub(Tidal, fn conn -> Req.Test.json(conn, body) end)
  end

  defp connect(user_id, opts) do
    expires_in = Keyword.fetch!(opts, :expires_in)

    Providers.connect(user_id, :tidal, %{
      provider_user_id: "tidal-#{System.unique_integer([:positive])}",
      access_token: "at-original",
      refresh_token: Keyword.get(opts, :refresh_token, "rt-original"),
      access_token_expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second),
      scopes: ["playlists.read"]
    })
  end

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
