defmodule OnePlaylist.Providers.RefreshTest do
  @moduledoc """
  The token refresh path, end to end: connection store → OAuth → connection
  store. This is the piece the whole application leans on unattended, so it is
  tested through the public functions rather than by stubbing the OAuth module.
  """

  use OnePlaylist.DataCase, async: true

  import Req.Test, only: [set_req_test_from_context: 1]

  # Several test files stub Req under this same name and all run async. Without
  # per-test ownership they overwrite one another, and a test intermittently
  # gets a response meant for a different one. Same idea as the Ecto sandbox:
  # private ownership for async tests, shared for sync ones.
  setup :set_req_test_from_context

  import OnePlaylist.AuthFixtures

  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Connection
  alias OnePlaylist.Providers.ConnectionUnusable
  alias OnePlaylist.Providers.Tidal
  alias OnePlaylist.Providers.TokenRefreshFailed

  use Errata

  setup do
    %{user_id: user_id_fixture()}
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

    test "a successful refresh clears an earlier failure", %{user_id: user_id} do
      # Without this, `record_refresh/2`'s postcondition is unfalsifiable: every
      # other test refreshes a connection that was already clean, so removing the
      # reset changes nothing. Found by mutation testing — the contract survived
      # deleting the very code it exists to protect.
      {:ok, connection} = connect(user_id, expires_in: 60)

      transient =
        Errata.create(TokenRefreshFailed,
          reason: :provider_unavailable,
          context: %{provider: :tidal}
        )

      {:ok, failing} = Providers.record_failure(connection, transient)
      assert failing.consecutive_failures == 1

      stub_token_response(%{"access_token" => "at-fresh", "expires_in" => 3600})

      assert {:ok, refreshed} = Providers.refresh(failing)
      assert refreshed.consecutive_failures == 0
      assert refreshed.status == :active
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

  describe "the caller that was missing" do
    test "fetch_usable_connection/2 hands back a token that actually works", %{user_id: user_id} do
      # `ensure_fresh/2` was thoroughly tested and had **no callers at all**, so
      # every test above passed while a real TIDAL connection stopped working an
      # hour after it was made — every call answering `unauthorized` until
      # somebody reconnected by hand.
      #
      # `Connection.usable?/1` answers `true` throughout, which is what the bug
      # hid behind: it asks whether there are credentials, not whether they
      # still work.
      stub_token_response(%{"access_token" => "at-fresh", "expires_in" => 3600})

      {:ok, expired} = connect(user_id, expires_in: -60)

      assert Connection.usable?(expired), "the state the bug hid behind"

      assert {:ok, fresh} = Providers.fetch_usable_connection(user_id, :tidal)

      assert fresh.access_token == "at-fresh"

      refute Connection.needs_refresh?(fresh, DateTime.utc_now()),
             "a caller asking for a usable connection should not have to check the clock"
    end

    test "and spends no request when there is time left", %{user_id: user_id} do
      # The common case has to stay free. A request per provider call to
      # discover that nothing needed doing is rate limit spent on nothing.
      Req.Test.stub(Tidal, fn _conn -> flunk("refreshed a token with an hour left") end)

      {:ok, _} = connect(user_id, expires_in: 3600)

      assert {:ok, %Connection{access_token: "at-original"}} =
               Providers.fetch_usable_connection(user_id, :tidal)
    end
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
end
