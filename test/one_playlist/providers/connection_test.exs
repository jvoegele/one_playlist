defmodule OnePlaylist.Providers.ConnectionTest do
  use ExUnit.Case, async: true
  use Bond.Test

  alias OnePlaylist.Providers.Connection

  # The `now_after_creation?/2` examples are part of a precondition's public
  # contract, so they are executed rather than merely written down.
  doctest OnePlaylist.Providers.Connection, import: true

  @now ~U[2026-08-22 12:00:00.000000Z]

  defp connection(overrides \\ []) do
    struct!(
      %Connection{
        status: :active,
        access_token: "token",
        access_token_expires_at: DateTime.add(@now, 3600, :second)
      },
      overrides
    )
  end

  describe "expired?/2" do
    test "a token past its expiry is expired" do
      assert Connection.expired?(
               connection(access_token_expires_at: DateTime.add(@now, -1)),
               @now
             )
    end

    test "a token expiring exactly now is expired" do
      assert Connection.expired?(connection(access_token_expires_at: @now), @now),
             "the boundary is inclusive: a token is not usable in its final instant"
    end

    test "a token with time left is not expired" do
      refute Connection.expired?(connection(), @now)
    end

    test "a token with no recorded expiry never expires" do
      refute Connection.expired?(connection(access_token_expires_at: nil), @now)
    end
  end

  describe "needs_refresh?/3" do
    test "a token inside the skew window needs refreshing" do
      soon = connection(access_token_expires_at: DateTime.add(@now, 30, :second))

      assert Connection.needs_refresh?(soon, @now, 60)
      refute Connection.expired?(soon, @now), "not yet expired, but should refresh early"
    end

    test "a token outside the skew window does not" do
      refute Connection.needs_refresh?(connection(), @now, 60)
    end

    test "a connection needing re-authorization is not refreshable" do
      dead = connection(status: :reauth_required, access_token_expires_at: DateTime.add(@now, -1))

      refute Connection.needs_refresh?(dead, @now, 60),
             "we cannot fix a dead grant by refreshing it"
    end

    test "a token with no expiry never needs refreshing" do
      refute Connection.needs_refresh?(connection(access_token_expires_at: nil), @now, 60)
    end
  end

  describe "usable?/1" do
    test "active with a token" do
      assert Connection.usable?(connection())
    end

    test "active but tokenless is not usable" do
      refute Connection.usable?(connection(access_token: nil))
    end

    test "a non-active status is not usable regardless of token" do
      for status <- [:expired, :revoked, :reauth_required] do
        refute Connection.usable?(connection(status: status)), "#{status} must not be usable"
      end
    end
  end

  # Bond's guide is emphatic that an assertion you have never seen fail is an
  # assertion you have not tested — a vacuous contract is worse than none,
  # because it looks like coverage. These prove each contract can actually fire.
  describe "contracts" do
    test "expired?/2 rejects a non-DateTime clock" do
      assert_precondition_violation(Connection.expired?(connection(), :not_a_datetime),
        label: :valid_now
      )
    end

    test "needs_refresh?/3 rejects a negative skew" do
      assert_precondition_violation(Connection.needs_refresh?(connection(), @now, -1),
        label: :non_negative_skew
      )
    end

    test "needs_refresh?/3 rejects a non-integer skew" do
      assert_precondition_violation(Connection.needs_refresh?(connection(), @now, 1.5),
        label: :non_negative_skew
      )
    end

    # Bond.Coverage flagged this one as checked-but-never-failed. It is a real
    # assertion rather than a vacuous one, so the answer is to prove it fires
    # rather than to delete it.
    test "needs_refresh?/3 rejects a non-DateTime clock" do
      assert_precondition_violation(
        Connection.needs_refresh?(connection(), :not_a_datetime, 60),
        label: :valid_now
      )
    end

    test "rejects a clock that predates the connection" do
      # The bug: an epoch default or a badly parsed timestamp. Not a type error,
      # and it makes every token look expired.
      persisted = connection(inserted_at: ~U[2026-08-01 00:00:00.000000Z])
      epoch_default = ~U[1970-01-01 00:00:00.000000Z]

      assert_precondition_violation(Connection.expired?(persisted, epoch_default),
        label: :now_after_creation
      )

      assert_precondition_violation(
        Connection.needs_refresh?(persisted, epoch_default, 60),
        label: :now_after_creation
      )
    end

    test "a connection that was never persisted is exempt, not rejected" do
      # inserted_at is nil for an in-memory struct, which is legitimate.
      refute Connection.expired?(connection(), ~U[1970-01-01 00:00:00.000000Z])
    end

    test "needs_refresh?/3 rejects a skew longer than any token lives" do
      # The bug this exists for: passing milliseconds where seconds are wanted.
      # It is not a type error and nothing fails — every token just looks due on
      # every call, and the application refreshes in a loop.
      assert_precondition_violation(
        Connection.needs_refresh?(connection(), @now, 300_000),
        label: :skew_under_a_day
      )
    end

    test "a skew right at the boundary is still accepted" do
      # 86_400 must pass and 86_401 must not, or the bound is off by one and
      # the test above would pass for the wrong reason.
      assert is_boolean(Connection.needs_refresh?(connection(), @now, 86_400))

      assert_precondition_violation(
        Connection.needs_refresh?(connection(), @now, 86_401),
        label: :skew_under_a_day
      )
    end
  end
end
