defmodule OnePlaylist.ErrorsTest do
  @moduledoc """
  What a failure looks like once it is written down.

  Every outbound call here is guarded, so the value reaching a `Logger` call is
  usually an `ExternalService.RetriesExhausted` wrapping the thing that actually
  went wrong. How that renders is the difference between a log somebody can read
  and one they scroll past.
  """

  use ExUnit.Case, async: true
  use Errata

  alias OnePlaylist.Errors
  alias OnePlaylist.Providers.Tidal.APIError

  doctest OnePlaylist.Errors

  defp chain do
    inner = %RuntimeError{message: "connection refused"}
    api = Errata.create(APIError, reason: :server_error, context: %{status: 503}, cause: inner)
    Errata.create(ExternalService.RetriesExhausted, context: %{service: Some}, cause: api)
  end

  describe "describe/1" do
    test "renders every level of the chain, ending in what went wrong" do
      rendered = Errors.describe(chain())

      assert rendered =~ "RetriesExhausted"
      assert rendered =~ "APIError"

      # The line that matters, and the one `inspect/1` buries: the foreign
      # original the code actually caught.
      assert rendered =~ "connection refused"

      assert rendered |> String.split("\n") |> length() == 3
    end

    test "and is dramatically shorter than inspecting the same value" do
      # Not cosmetic. `inspect/1` on one of these prints the whole `Errata.Env`
      # — module, function, file, line — and the captured stacktrace, as one
      # unbroken line, with the actual cause somewhere in the middle.
      error = chain()

      assert String.length(Errors.describe(error)) < String.length(inspect(error)) / 4
    end

    test "a value with no chain is inspected, as it was before" do
      # These call sites are where foreign shapes arrive — a Nebulex error, a
      # bare atom from a library that does not use Errata. `format_chain/1`
      # raises on one of those, and raising inside `Logger.warning/1` would
      # replace a logged failure with a crash in the one place that exists to
      # record failures quietly.
      assert Errors.describe({:error, :enoent}) == "{:error, :enoent}"
      assert Errors.describe(%RuntimeError{message: "bare"}) =~ "RuntimeError"
    end
  end
end
