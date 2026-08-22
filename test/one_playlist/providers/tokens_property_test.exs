defmodule OnePlaylist.Providers.TokensPropertyTest do
  @moduledoc """
  `Tokens.from_oauth_response/2` over the shapes a provider's token endpoint
  actually returns, with the struct's invariant as the oracle.

  ## This one is worth less than `SignalsPropertyTest`, and it is worth saying so

  That property drives a composition of four scoring functions over an
  effectively unbounded input space, and a mutation of `Enum.max/1` to
  `Enum.sum/1` is caught by it and by no example test.

  This one covers four keys with a handful of shapes each — a space the example
  tests in `OnePlaylist.Providers.TokensTest` nearly enumerate on their own. What
  it adds is the *combinatorics of absence*: RFC 6749 makes `refresh_token`,
  `expires_in` and `scope` all optional, which is sixteen presence combinations
  where the examples pick five, and the ones nobody writes down are exactly the
  ones a provider picks. The invariant judges all of them for free.

  ## Only inputs that should succeed

  `contract_holds/2` reads a contract violation as a property failure, so the
  generator must produce responses a correct implementation accepts. A blank
  `access_token` or a blank `refresh_token` *should* violate the invariant —
  those are example tests, where the expected failure can be asserted.

  A negative `expires_in` is deliberately **in** the generator. It produces a
  token set that is already expired, which is a perfectly valid value and must
  not raise: freshness is a property of the producer, not of the type. Several
  hundred expired-on-arrival token sets passing the invariant is the clearest
  statement of that distinction available.

  ## Where this property stops, measured rather than guessed

  The invariant is the oracle, so this property can only see what the invariant
  can see — and `scopes_are_a_list` is the weakest of the four assertions, since
  `is_list/1` is all of it.

  Dropping `trim: true` from the `String.split/3` below turns `"scope" => ""`
  into `[""]` and `"  a   b  "` into a list padded with blanks. Verified: this
  property **passes** under that mutation, and the `"a missing scope string is
  no scopes rather than one empty scope"` example in
  `OnePlaylist.Providers.TokensTest` is what fails. A property whose oracle is a
  contract inherits the contract's blind spots exactly, which is the argument for
  keeping both kinds of test rather than letting the property subsume the
  examples.
  """

  use ExUnit.Case, async: true
  use Bond.PropertyTest

  alias OnePlaylist.Providers.Tokens

  # Never blank: a blank access token must violate the invariant, and asserting
  # that belongs in an example test where the failure can be named.
  defp access_token_generator do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 40)
  end

  # Absent, explicitly null, or real — the three things a provider does. Not
  # `""`, for the same reason as above.
  defp refresh_token_generator do
    StreamData.frequency([
      {2, StreamData.string(:alphanumeric, min_length: 1, max_length: 40)},
      {1, StreamData.constant(nil)}
    ])
  end

  # Zero and negative included on purpose: both yield an already-expired token
  # set, which is valid data and must not be confused with invalid data.
  defp expires_in_generator do
    StreamData.frequency([
      {5, StreamData.integer(1..86_400)},
      {1, StreamData.constant(0)},
      {1, StreamData.integer(-3600..-1)}
    ])
  end

  defp scope_generator do
    StreamData.frequency([
      {4,
       StreamData.member_of(["playlists.read", "playlists.read playlists.write", "user.read"])},
      {1, StreamData.constant("")},
      # Providers are inconsistent about padding, and `trim: true` is what makes
      # this produce two scopes rather than four with two blanks among them.
      {1, StreamData.constant("  playlists.read   search.read  ")}
    ])
  end

  # The point of the property: every optional key is independently absent-able,
  # so the map itself is generated rather than filled in.
  defp response_generator do
    StreamData.bind(
      StreamData.tuple({
        access_token_generator(),
        refresh_token_generator(),
        expires_in_generator(),
        scope_generator(),
        StreamData.list_of(StreamData.member_of(~w(refresh_token expires_in scope)),
          max_length: 3
        )
      }),
      fn {access_token, refresh_token, expires_in, scope, omitted} ->
        StreamData.constant(
          %{
            "access_token" => access_token,
            "refresh_token" => refresh_token,
            "expires_in" => expires_in,
            "scope" => scope,
            # Providers return fields we do not read. They must be ignored, not
            # tripped over.
            "token_type" => "Bearer"
          }
          |> Map.drop(omitted)
        )
      end
    )
  end

  defp now_generator do
    StreamData.map(
      StreamData.integer(-100_000..100_000),
      &DateTime.add(~U[2026-01-01 00:00:00Z], &1, :second)
    )
  end

  contract_holds(&Tokens.from_oauth_response/2,
    args: [response_generator(), now_generator()]
  )

  describe "the generator reaches the absences it exists to cover" do
    property "each optional key is sometimes present and sometimes missing" do
      # Without this the generator could quietly settle into always returning a
      # complete response, and the sixteen combinations this property exists for
      # would be one combination tested three hundred times.
      responses = Enum.take(response_generator(), 300)

      for key <- ~w(refresh_token expires_in scope) do
        present = Enum.count(responses, &Map.has_key?(&1, key))

        assert present > 30, "#{key} was present in only #{present}/300 responses"
        assert present < 270, "#{key} was missing from only #{300 - present}/300 responses"
      end
    end

    property "expired-on-arrival token sets are actually produced" do
      # The distinction the moduledoc rests on: an expired token set is valid
      # data. If the generator never made one, the property would be silent
      # about the thing it is most useful for saying.
      now = ~U[2026-01-01 00:00:00Z]

      expired =
        response_generator()
        |> Enum.take(300)
        |> Enum.count(&(not Tokens.fresh?(Tokens.from_oauth_response(&1, now), now)))

      assert expired > 10, "only #{expired}/300 responses produced an already-expired token set"
    end
  end
end
