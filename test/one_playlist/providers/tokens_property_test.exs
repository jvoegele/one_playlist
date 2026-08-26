defmodule OnePlaylist.Providers.TokensPropertyTest do
  @moduledoc """
  `Tokens`' invariants against random constructions.

  Written after `bond` 1.18.0 pointed out that twelve modules here declare an
  `@invariant` and none had a property driving it. `invariants_hold/2` needs
  only a list of constructors and observers, and it explores orderings and
  values nobody would write down — a `scope` string of nothing but spaces, an
  `expires_in` of zero, a body carrying a key we never look at.

  ## Only well-formed bodies are generated, and that is not cheating

  `from_oauth_response/2` is documented as **raising** on a malformed body
  rather than answering an error tuple: every field it reads is one the OAuth
  spec requires, so an absence is the provider behaving differently than
  believed. Generating bodies with no `access_token` would therefore "fail" the
  property by triggering exactly the behaviour the invariant is for.

  What is worth exploring is the space of *valid* responses, which is wider than
  it looks — and that is what this generates.
  """

  use ExUnit.Case, async: true
  use Bond.PropertyTest

  alias OnePlaylist.Providers.Tokens

  # A token string is opaque to us and providers vary wildly: TIDAL's are long
  # JWTs, a Subsonic-style server's are short. Non-empty is the only thing the
  # invariant demands, so that is the only thing pinned.
  defp token_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 40)
  end

  # Zero is included deliberately. A provider answering `expires_in: 0` is
  # returning an already-expired token, which `Tokens`' moduledoc calls worse
  # than an error because it gets stored and looks healthy — the invariant
  # should still hold of it, and `fresh?/2` should say no.
  defp body_gen do
    StreamData.fixed_map(%{
      "access_token" => token_gen(),
      "refresh_token" => token_gen(),
      "expires_in" => StreamData.integer(0..100_000),
      "scope" => StreamData.one_of([StreamData.constant(""), StreamData.constant("a b  c")])
    })
  end

  invariants_hold(Tokens,
    constructors: [
      {:from_oauth_response, [body_gen()]},
      {:new,
       [
         StreamData.fixed_map(%{
           access_token: token_gen(),
           refresh_token: StreamData.one_of([token_gen(), StreamData.constant(nil)]),
           expires_at: StreamData.constant(~U[2030-01-01 00:00:00Z]),
           scopes: StreamData.one_of([StreamData.constant(nil), StreamData.list_of(token_gen())])
         })
       ]}
    ],
    observers: [
      {:fresh?, [StreamData.constant(~U[2026-01-01 00:00:00Z])]},
      {:well_formed?, []}
    ],
    name: "Tokens' invariants hold for every valid construction"
  )
end
