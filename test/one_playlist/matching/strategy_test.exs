defmodule OnePlaylist.Matching.StrategyTest do
  @moduledoc """
  The contracts `OnePlaylist.Matching.Strategy` declares, and that every rung
  inherits without writing a line of contract code.

  The two modules at the top are deliberately broken. They exist because
  `Bond.Coverage` cannot tell an assertion that is robust from one that is
  vacuous — only an implementation that violates it can, and the four real
  rungs are all correct. A rung that *could* be written wrong is the honest way
  to prove the inherited contract would catch it.
  """

  use ExUnit.Case, async: true
  use Bond.Test

  alias OnePlaylist.Matching.Strategy
  alias OnePlaylist.MusicFixtures

  defmodule Overconfident do
    @moduledoc false
    # Sums its signals and forgets to divide. The realistic version of this bug
    # is a weight added to the numerator but not the denominator.
    use Bond, behaviours: [OnePlaylist.Matching.Strategy]

    @impl true
    def strategy, do: :fuzzy

    @impl true
    def score(_source, _candidate), do: {1.4, [title: 0.9, artists: 0.5]}
  end

  defmodule Misnamed do
    @moduledoc false
    # A rung whose name no band is defined for — a typo, or a rename that
    # missed one place.
    use Bond, behaviours: [OnePlaylist.Matching.Strategy]

    @impl true
    def strategy, do: :vector

    @impl true
    def score(_source, _candidate), do: nil
  end

  describe "inherited contracts" do
    test "a score above 1.0 is caught at the rung that produced it" do
      {source, candidate} = MusicFixtures.pair()

      assert_postcondition_violation(Overconfident.score(source, candidate),
        label: :in_unit_interval
      )
    end

    test "a rung reporting a name no band knows about is caught" do
      assert_postcondition_violation(Misnamed.strategy(), label: :known_to_match)
    end

    test "the real rungs satisfy both, with no contract code of their own" do
      {source, candidate} = MusicFixtures.pair([isrc: "GBAYE0601477"], isrc: "GBAYE0601477")

      for rung <- [
            OnePlaylist.Matching.Strategy.Isrc,
            OnePlaylist.Matching.Strategy.UpcPosition,
            OnePlaylist.Matching.Strategy.Text,
            OnePlaylist.Matching.Strategy.Fuzzy
          ] do
        assert rung.strategy() in [:isrc, :upc_position, :text, :fuzzy]

        case rung.score(source, candidate) do
          {raw, evidence} ->
            assert raw >= 0.0 and raw <= 1.0
            assert is_list(evidence)

          nil ->
            :ok
        end
      end
    end

    test "every rung in the ladder implements the whole behaviour" do
      expected = Strategy.behaviour_info(:callbacks) |> Enum.sort()

      for rung <- OnePlaylist.Matching.strategies() do
        exported = rung.__info__(:functions)

        for {name, arity} <- expected do
          assert {name, arity} in exported, "#{inspect(rung)} is missing #{name}/#{arity}"
        end
      end
    end
  end
end
