defmodule OnePlaylist.Providers.ConnectionPropertyTest do
  @moduledoc """
  The refresh predicates, tested with their own contracts as the oracle.

  `Bond.PropertyTest.contract_holds/2` runs a function against generated input
  and fails if any `@pre`, `@post` or `check` is violated. There is no separate
  model of expected behaviour to write or keep in step — the contracts on
  `OnePlaylist.Providers.Connection` already say what must hold, so the only
  work here is describing what a valid input looks like.

  This matters most for `active_and_expired_must_refresh`, which the
  example-based tests exercise on a handful of hand-picked instants.
  `Bond.Coverage` reported it as checked-but-never-failed, which is a prompt
  rather than a verdict: either it is robust, or the examples never reached the
  input that breaks it. Property testing is how to tell the difference.

  Note that these macros are called at the **module** level, not inside a
  `test` block: each defines its own test.
  """

  use ExUnit.Case, async: true
  use Bond.PropertyTest

  alias OnePlaylist.Providers.Connection

  @epoch ~U[2026-01-01 00:00:00.000000Z]

  # A connection whose fields vary independently, because the interesting cases
  # are the combinations: an expired token on a revoked connection, a live token
  # with no expiry recorded, a connection with no token at all.
  defp connection do
    {
      StreamData.member_of(~w(active expired revoked reauth_required)a),
      StreamData.integer(-86_400..86_400),
      StreamData.boolean(),
      StreamData.one_of([
        StreamData.constant(nil),
        StreamData.string(:alphanumeric, min_length: 1)
      ])
    }
    |> StreamData.tuple()
    |> StreamData.map(fn {status, offset, has_expiry, token} ->
      %Connection{
        provider: :tidal,
        status: status,
        access_token: token,
        # Two days before @epoch, while `instant/0` generates within one day of
        # it. Without this the `now_after_creation` precondition would be
        # vacuously satisfied on every generated connection — the mapper
        # generators taught that lesson already.
        inserted_at: DateTime.add(@epoch, -172_800, :second),
        access_token_expires_at:
          if(has_expiry, do: DateTime.add(@epoch, offset, :second), else: nil)
      }
    end)
  end

  # Instants on both sides of the expiries above, so "already expired", "expires
  # exactly now" and "expires later" all occur.
  defp instant do
    StreamData.map(
      StreamData.integer(-86_400..86_400),
      &DateTime.add(@epoch, &1, :second)
    )
  end

  contract_holds(&Connection.needs_refresh?/3,
    args: [connection(), instant(), StreamData.integer(0..3600)]
  )

  contract_holds(&Connection.expired?/2, args: [connection(), instant()])

  # Unlike contract_holds, probe_contract generates broadly and *filters* on the
  # precondition, so it reaches the awkward values near a boundary — a skew of
  # exactly 0 among them — rather than only the comfortable middle.
  probe_contract(&Connection.needs_refresh?/3,
    args: [connection(), instant(), StreamData.integer(-5..600)]
  )
end
