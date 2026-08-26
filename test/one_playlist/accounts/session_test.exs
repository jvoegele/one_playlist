defmodule OnePlaylist.Accounts.SessionTest do
  @moduledoc """
  The session struct, its invariant, and the clock questions it answers.
  """

  use ExUnit.Case, async: true
  use Bond.Test

  alias OnePlaylist.Accounts.Session
  alias Supabase.Auth.Session, as: GoTrueSession
  alias Supabase.Auth.User, as: GoTrueUser

  doctest OnePlaylist.Accounts.Session

  defp session(overrides \\ []) do
    struct!(
      %Session{
        user_id: "8b0e0d1e-0000-4000-8000-000000000001",
        email: "someone@example.test",
        access_token: "at",
        refresh_token: "rt",
        expires_at: ~U[2030-01-01 00:00:00Z]
      },
      overrides
    )
  end

  describe "the invariant" do
    test "a session with no refresh token is rejected at construction" do
      # The sharpest of the four, and the reason this contract exists: a session
      # without a refresh token works perfectly for up to an hour and then signs
      # the user out mid-transfer. Nothing in the logs points back to here.
      assert_invariant_violation(Session.to_gotrue(session(refresh_token: nil)),
        label: :refresh_token_present
      )
    end

    test "a blank access token is rejected" do
      # Stored happily, looks signed in, 401s on the next call with an error
      # that blames Supabase.
      assert_invariant_violation(Session.to_gotrue(session(access_token: "")),
        label: :access_token_present
      )
    end

    test "a session belonging to nobody is rejected" do
      # `user_id` is the foreign key every connection and transfer hangs off,
      # and the `sub` claim RLS reads. Blank scopes every query to nobody, which
      # returns empty lists rather than failing.
      assert_invariant_violation(Session.to_gotrue(session(user_id: "")), label: :user_id_present)
    end

    test "a session that never expires is rejected" do
      # `nil` does not read as "expires soon", it reads as *never* — so it would
      # be renewed exactly never and simply die at the real expiry.
      assert_invariant_violation(Session.to_gotrue(session(expires_at: nil)),
        label: :expiry_is_a_timestamp
      )
    end
  end

  describe "well_formed?/1" do
    test "answers rather than raises, for anything at all" do
      # The point of the bare parameter: this is what reads a cookie written by
      # an older deploy, so it has to be able to say `false` about a value that
      # is not even a session.
      refute Session.well_formed?(:not_a_session)
      refute Session.well_formed?(nil)
      refute Session.well_formed?(%{user_id: "u"})
      refute Session.well_formed?(session(refresh_token: ""))
      assert Session.well_formed?(session())
    end
  end

  describe "from_gotrue/1" do
    test "prefers GoTrue's own expiry instant over our clock plus a duration" do
      # `expires_at` is GoTrue's clock; `expires_in` is ours plus a guess about
      # how long the response took to arrive. They disagree by the round trip.
      gotrue = %GoTrueSession{
        access_token: "at",
        refresh_token: "rt",
        expires_in: 3600,
        expires_at: 1_900_000_000,
        token_type: "bearer",
        user: %GoTrueUser{id: "u", email: "someone@example.test"}
      }

      assert Session.from_gotrue(gotrue).expires_at == DateTime.from_unix!(1_900_000_000)
    end

    test "falls back to the duration when no instant is given" do
      gotrue = %GoTrueSession{
        access_token: "at",
        refresh_token: "rt",
        expires_in: 60,
        expires_at: nil,
        token_type: "bearer",
        user: %GoTrueUser{id: "u", email: "someone@example.test"}
      }

      now = ~U[2026-01-01 00:00:00Z]
      assert Session.from_gotrue(gotrue, now).expires_at == ~U[2026-01-01 00:01:00Z]
    end
  end

  describe "needs_refresh?/3" do
    test "asks for renewal before the token actually expires" do
      # Waiting for `fresh?/2` to turn false means the renewal races the failure
      # it exists to prevent, and loses for anything already in flight.
      session = session(expires_at: ~U[2030-01-01 00:00:00Z])

      refute Session.needs_refresh?(session, ~U[2029-12-31 23:58:00Z])
      assert Session.needs_refresh?(session, ~U[2029-12-31 23:59:30Z])
      assert Session.fresh?(session, ~U[2029-12-31 23:59:30Z]), "still valid, but renewing anyway"
    end
  end

  describe "redaction" do
    test "neither token survives inspect/1" do
      # This struct is assigned onto a Plug.Conn and a LiveView socket, both of
      # which any crash report prints in full.
      rendered = inspect(session(access_token: "SECRET-AT", refresh_token: "SECRET-RT"))

      refute rendered =~ "SECRET-AT"
      refute rendered =~ "SECRET-RT"
      assert rendered =~ "someone@example.test", "the identifying fields stay useful"
    end
  end

  describe "the refresh skew is seconds" do
    test "milliseconds are refused rather than silently believed" do
      # The classic magnitude bug: `300_000` for `300`. Not a type error and
      # nothing fails — every session simply looks due on every request, so the
      # application re-authenticates against GoTrue on each page load until its
      # rate limiter notices. Falsifiable by input, so it gets a test rather
      # than a mutation.
      assert_precondition_violation(
        Session.needs_refresh?(session(), DateTime.utc_now(), 300_000),
        label: :skew_is_seconds
      )
    end

    test "a real skew is accepted" do
      refute Session.needs_refresh?(
               session(expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)),
               DateTime.utc_now(),
               300
             )
    end
  end
end
