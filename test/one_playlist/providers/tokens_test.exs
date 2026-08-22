defmodule OnePlaylist.Providers.TokensTest do
  @moduledoc """
  The OAuth token set.

  Every invariant here names a failure that is *stored happily and surfaces
  later*, so each one gets a test that proves it can fire — otherwise
  `Bond.Coverage` is right to call it decoration.
  """

  use ExUnit.Case, async: true
  use Bond.Test

  alias OnePlaylist.Providers.Tokens

  doctest OnePlaylist.Providers.Tokens

  @an_hour_from_now DateTime.add(DateTime.utc_now(), 3600, :second)

  defp valid(overrides \\ []) do
    Tokens.new(
      Keyword.merge(
        [access_token: "at-real", refresh_token: "rt-real", expires_at: @an_hour_from_now],
        overrides
      )
    )
  end

  describe "new/1" do
    test "accepts a keyword list or a map" do
      assert Tokens.new(access_token: "at", expires_at: @an_hour_from_now).access_token == "at"
      assert Tokens.new(%{access_token: "at", expires_at: @an_hour_from_now}).access_token == "at"
    end

    test "absent scopes are an empty list, never nil" do
      # "the provider said nothing about scopes" and "the provider granted none"
      # are the same thing to every caller, and `nil` is the one that crashes
      # three modules away in `"search.read" in nil`.
      assert Tokens.new(access_token: "at", expires_at: @an_hour_from_now).scopes == []

      assert Tokens.new(access_token: "at", expires_at: @an_hour_from_now, scopes: nil).scopes ==
               []
    end
  end

  describe "from_oauth_response/2" do
    test "turns the RFC 6749 shape into a token set" do
      now = ~U[2026-08-22 12:00:00Z]

      tokens =
        Tokens.from_oauth_response(
          %{
            "access_token" => "at",
            "refresh_token" => "rt",
            "expires_in" => 3600,
            "scope" => "playlists.read search.read"
          },
          now
        )

      assert tokens.access_token == "at"
      assert tokens.refresh_token == "rt"
      assert tokens.scopes == ["playlists.read", "search.read"]
      assert tokens.expires_at == ~U[2026-08-22 13:00:00Z]
    end

    test "expires_in is a duration, and becomes an instant" do
      # The mistake this exists to prevent: storing 3600 as though it were a
      # timestamp. Nothing about that is a type error at the point it happens.
      now = ~U[2026-08-22 12:00:00Z]

      assert Tokens.from_oauth_response(%{"access_token" => "at", "expires_in" => 60}, now).expires_at ==
               ~U[2026-08-22 12:01:00Z]
    end

    test "a response with no expiry gets a conservative hour" do
      now = ~U[2026-08-22 12:00:00Z]

      assert Tokens.from_oauth_response(%{"access_token" => "at"}, now).expires_at ==
               ~U[2026-08-22 13:00:00Z]
    end

    test "a missing scope string is no scopes rather than one empty scope" do
      assert Tokens.from_oauth_response(%{"access_token" => "at"}).scopes == []
      assert Tokens.from_oauth_response(%{"access_token" => "at", "scope" => ""}).scopes == []
    end
  end

  describe "fresh?/2" do
    test "answers the question at the given moment" do
      tokens = valid(expires_at: ~U[2026-08-22 12:00:00Z])

      assert Tokens.fresh?(tokens, ~U[2026-08-22 11:59:59Z])
      refute Tokens.fresh?(tokens, ~U[2026-08-22 12:00:01Z])
    end

    test "expiry is not freshness: the boundary is not fresh" do
      tokens = valid(expires_at: ~U[2026-08-22 12:00:00Z])

      refute Tokens.fresh?(tokens, ~U[2026-08-22 12:00:00Z]),
             "a token expiring exactly now is already unusable by the time it is sent"
    end

    test "staleness is not an invariant violation" do
      # The distinction the moduledoc rests on. An expired token set is a
      # perfectly valid *value* — it is what a refresh is for — so asking about
      # it must answer, not raise.
      assert Tokens.fresh?(valid(expires_at: ~U[2020-01-01 00:00:00Z])) == false
    end
  end

  describe "the invariant" do
    test "a blank or absent access token is not a token set" do
      assert_invariant_violation(Tokens.new(access_token: "", expires_at: @an_hour_from_now),
        label: :access_token_present
      )

      assert_invariant_violation(Tokens.new(access_token: nil, expires_at: @an_hour_from_now),
        label: :access_token_present
      )
    end

    test "a nil expiry is rejected, because downstream it means *never*" do
      # `Connection.needs_refresh?/3` answers `false` for a nil expiry by
      # design — that is what lets a Subsonic password need no special case. A
      # nil arriving from an OAuth provider inherits that answer and the
      # connection is never refreshed again.
      assert_invariant_violation(Tokens.new(access_token: "at", expires_at: nil),
        label: :expiry_is_a_timestamp
      )
    end

    test "a blank refresh token is rejected; an absent one is fine" do
      assert_invariant_violation(
        Tokens.new(
          access_token: "at",
          refresh_token: "",
          expires_at: @an_hour_from_now
        ),
        label: :refresh_token_absent_or_real
      )

      assert %Tokens{refresh_token: nil} =
               Tokens.new(access_token: "at", expires_at: @an_hour_from_now)
    end

    test "scopes must be a list" do
      assert_invariant_violation(
        %Tokens{access_token: "at", expires_at: @an_hour_from_now, scopes: "search.read"}
        |> Tokens.fresh?(),
        label: :scopes_are_a_list
      )
    end

    test "fires on the way in as well as out" do
      # Nothing stops anyone building the struct directly, and such a value never
      # passes through `new/1`, so no exit check ever sees it. The entry check is
      # what notices — which is why `fresh?/2` takes `%Tokens{} = tokens` rather
      # than a bare variable, per Bond's detection table.
      hand_built = %Tokens{access_token: "", expires_at: @an_hour_from_now}

      assert_invariant_violation(Tokens.fresh?(hand_built), label: :access_token_present)
    end

    test "a bare %Tokens{} is rejected by Elixir before Bond is reached" do
      # Meyer's base-case rule wants a struct's defaults to satisfy its
      # invariant, and these deliberately do not: there is no valid stand-in for
      # "a real credential", so an empty token set is not a token set.
      #
      # Elixir 1.20's type system reaches the same conclusion independently and
      # earlier — `Tokens.fresh?(%Tokens{})` is a *compile-time* type error,
      # because the default `expires_at: nil` cannot be the `DateTime` that
      # `DateTime.after?/2` needs. Bond's entry check is the runtime backstop for
      # the same mistake made dynamically.
      assert %Tokens{}.access_token == nil
      assert %Tokens{}.expires_at == nil
      assert %Tokens{}.scopes == [], "the one default that can be valid, is"
    end
  end

  describe "the secrets" do
    test "neither token survives inspect/1" do
      # This struct travels through a controller, a context and an Oban worker.
      # Encryption protects the tokens at rest and does nothing for a stack
      # trace, a `dbg/1`, or a Logger interpolation.
      inspected = inspect(valid())

      refute inspected =~ "at-real"
      refute inspected =~ "rt-real"
    end

    test "what remains is still useful for debugging" do
      inspected = inspect(valid(scopes: ["search.read"]))

      assert inspected =~ "search.read"
      assert inspected =~ "expires_at"
    end
  end
end
