defmodule OnePlaylist.Providers.TokenLoggingTest do
  @moduledoc """
  Tokens must not reach the logs.

  Encryption keeps them out of the database; it does nothing about Ecto's query
  log, which prints every bound parameter — and for these writes the parameters
  are the tokens, before encryption. This was observed for real: a live TIDAL
  access token and refresh token were printed in full at `:debug` during the
  first successful OAuth round trip.

  Kept as a test rather than a comment because the failure is silent. Nothing
  breaks, no test goes red, and the credential is simply sitting in a log file
  that gets shipped somewhere.
  """

  use OnePlaylist.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias OnePlaylist.Providers

  @access "at-secret-should-never-be-logged"
  @refresh "rt-secret-should-never-be-logged"

  setup do
    %{user_id: create_auth_user()}
  end

  test "connect/3 does not log the tokens", %{user_id: user_id} do
    log = capture_all_logs(fn -> {:ok, _} = connect(user_id) end)

    refute log =~ @access
    refute log =~ @refresh
  end

  test "record_refresh/2 does not log the tokens", %{user_id: user_id} do
    {:ok, connection} = connect(user_id)

    log =
      capture_all_logs(fn ->
        {:ok, _} =
          Providers.record_refresh(connection, %{
            access_token: "at-rotated-secret",
            refresh_token: "rt-rotated-secret",
            access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          })
      end)

    refute log =~ "at-rotated-secret"
    refute log =~ "rt-rotated-secret"
  end

  test "recording a failure still logs, since it carries no tokens", %{user_id: user_id} do
    # The point is that `log: false` is scoped to the writes that carry
    # credentials, not applied everywhere out of caution — losing query logging
    # across the board would be its own problem.
    {:ok, connection} = connect(user_id)

    error = %RuntimeError{message: "upstream exploded"}
    log = capture_all_logs(fn -> {:ok, _} = Providers.record_failure(connection, error) end)

    assert log =~ "provider_connections", "ordinary writes should still be logged"
    refute log =~ @access
  end

  defp capture_all_logs(fun) do
    capture_log([level: :debug], fn ->
      Logger.configure(level: :debug)
      fun.()
    end)
  end

  defp connect(user_id) do
    Providers.connect(user_id, :tidal, %{
      provider_user_id: "tidal-#{System.unique_integer([:positive])}",
      access_token: @access,
      refresh_token: @refresh,
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
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
