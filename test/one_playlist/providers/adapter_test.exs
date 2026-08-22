defmodule OnePlaylist.Providers.AdapterTest do
  @moduledoc """
  The adapter behaviour and the contracts it declares.

  These test `OnePlaylist.Providers.Tidal` but are really about
  `OnePlaylist.Providers.Adapter`: the contracts live on the callbacks, so every
  adapter added later inherits both them and the guarantees asserted here
  without writing a line of contract code.
  """

  use ExUnit.Case, async: true
  use Bond.Test

  alias OnePlaylist.Providers
  alias OnePlaylist.Providers.Adapter
  alias OnePlaylist.Providers.ProviderNotSupported
  alias OnePlaylist.Providers.Tidal

  use Errata

  describe "the registry" do
    test "resolves a supported provider to its adapter" do
      assert {:ok, Tidal} = Providers.adapter(:tidal)
    end

    test "an unimplemented provider is a 501, not a crash" do
      # Connection accepts every provider on the roadmap, deliberately ahead of
      # what is built. Asking for one of those is not a programming error.
      assert {:error, %ProviderNotSupported{} = error} = Providers.adapter(:apple_music)

      assert Errata.http_status(error) == 501
      assert Errata.display_message(error) =~ "apple_music"
      refute Errata.retryable?(error)
    end

    test "every registered adapter agrees with the registry about who it is" do
      for provider <- Providers.supported_providers() do
        {:ok, adapter} = Providers.adapter(provider)

        assert adapter.provider() == provider,
               "#{inspect(adapter)} is registered under #{provider} but calls itself " <>
                 "#{adapter.provider()}"
      end
    end

    test "every registered adapter implements the whole behaviour" do
      expected = Adapter.behaviour_info(:callbacks) |> Enum.sort()

      for provider <- Providers.supported_providers() do
        {:ok, adapter} = Providers.adapter(provider)
        exported = adapter.__info__(:functions)

        for {name, arity} <- expected do
          assert {name, arity} in exported,
                 "#{inspect(adapter)} is missing #{name}/#{arity}"
        end
      end
    end
  end

  # Bond.Coverage flags an assertion that runs and never fails as a candidate
  # for vacuity. These prove each inherited contract fires — and, incidentally,
  # that inheritance works at all: there is no contract code in the Tidal module.
  describe "inherited contracts" do
    test "a blank refresh token is rejected before any request is made" do
      Req.Test.stub(Tidal, fn _conn -> flunk("nothing to exchange, so nothing to send") end)

      assert_precondition_violation(Tidal.refresh_tokens(""), label: :present)
      assert_precondition_violation(Tidal.refresh_tokens(nil), label: :present)
    end

    test "a provider that returns an already-expired token is caught" do
      # Worse than a failed refresh: it would be stored, look healthy, and fail
      # at the next call with an error pointing at the wrong thing.
      Req.Test.stub(Tidal, fn conn ->
        Req.Test.json(conn, %{"access_token" => "at", "expires_in" => -100})
      end)

      assert_postcondition_violation(Tidal.refresh_tokens("rt-valid"), label: :fresh)
    end

    test "a provider that returns a blank access token is caught" do
      Req.Test.stub(Tidal, fn conn ->
        Req.Test.json(conn, %{"access_token" => "", "expires_in" => 3600})
      end)

      assert_postcondition_violation(Tidal.refresh_tokens("rt-valid"), label: :usable)
    end

    test "a normal refresh satisfies both postconditions" do
      Req.Test.stub(Tidal, fn conn ->
        Req.Test.json(conn, %{"access_token" => "at-good", "expires_in" => 3600})
      end)

      assert {:ok, tokens} = Tidal.refresh_tokens("rt-valid")
      assert tokens.access_token == "at-good"
    end

    test "a failed refresh does not trip the postconditions" do
      # The `whenever({:ok, tokens} <- result)` form is vacuously satisfied by an
      # error, which is the point: an error tuple has no tokens to constrain.
      Req.Test.stub(Tidal, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      assert {:error, _error} = Tidal.refresh_tokens("rt-dead")
    end
  end
end
