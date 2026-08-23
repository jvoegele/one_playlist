defmodule OnePlaylist.MatchingPropertyTest do
  @moduledoc """
  Laws the matching engine must obey for input nobody chose by hand.

  Two kinds of check live here. `Bond.PropertyTest.contract_holds/2` uses the
  contracts themselves as the oracle — there is no separate model to keep in
  step, because `OnePlaylist.Matching` already says what must hold. The
  hand-written properties below state the laws that are *not* expressible as
  contracts, principally the ones needing two runs to compare (determinism) or
  a relationship between two different calls (monotonicity).

  ## Guarding against vacuity

  `docs/reference/contracts.md` records a property suite here that generated
  0 useful cases out of 500 and passed anyway. The first property in this file
  therefore measures that the generators actually produce matches, and fails if
  they do not. Every property below it is worthless without that one.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  use Bond.PropertyTest

  alias OnePlaylist.Matching
  alias OnePlaylist.Matching.Confidence
  alias OnePlaylist.Matching.Match
  alias OnePlaylist.Matching.Report
  alias OnePlaylist.Matching.Strategy
  alias OnePlaylist.Music.Track

  @titles ["Yesterday", "Hey Jude", "Bohemian Rhapsody", "Jóga", "Don’t Stop Me Now", ""]
  @artists ["The Beatles", "Queen", "Björk", "JAY-Z", "Beatles, The"]
  @tags ["", " (Live)", " (Karaoke Version)", " - Remastered 2015", " (feat. Someone)"]

  defp track_generator do
    gen all(
          title <- member_of(@titles),
          tag <- member_of(@tags),
          artist <- member_of(@artists),
          isrc <- one_of([constant(nil), constant("GBAYE0601477"), constant("USUM71703861")]),
          duration <- one_of([constant(nil), integer(60..400)]),
          id <- string(:alphanumeric, min_length: 1, max_length: 4)
        ) do
      %Track{
        provider: :tidal,
        provider_id: id,
        title: title <> tag,
        artists: [artist],
        album: "An Album",
        isrc: isrc,
        duration_seconds: duration
      }
    end
  end

  defp candidates_generator, do: list_of(track_generator(), max_length: 5)

  # What the engine decided, with everything incidental removed.
  #
  # Comparing the raw results would compare Errata's captured environment too,
  # which records the call site and so differs between two calls on different
  # lines — correctly, and with nothing to do with matching. The decision is
  # the chosen track, its score and the reason for a refusal.
  defp decision({:ok, match}), do: {:ok, match.track.provider_id, match.score, match.strategy}

  defp decision({:error, error}),
    do: {:error, Errata.reason(error), Errata.context(error).best_candidate_id}

  describe "the generators are not vacuous" do
    property "they produce matches often enough for the rest to mean anything" do
      pairs =
        gen all(source <- track_generator(), candidates <- candidates_generator()) do
          {source, candidates}
        end
        |> Enum.take(300)

      matched =
        Enum.count(pairs, fn {source, candidates} ->
          match?({:ok, _match}, Matching.match(source, candidates, threshold: :low))
        end)

      assert matched > 20,
             "only #{matched}/300 generated cases matched — the properties below are vacuous"
    end
  end

  describe "laws that hold for any input" do
    property "matching is deterministic" do
      # Not expressible as a contract: it needs two runs to compare. It is
      # load-bearing anyway — a transfer retried after a failure must resolve
      # the same tracks, or a resumed run duplicates some and drops others.
      check all(source <- track_generator(), candidates <- candidates_generator()) do
        first = Matching.match(source, candidates, threshold: :low)
        second = Matching.match(source, candidates, threshold: :low)

        assert decision(first) == decision(second)
      end
    end

    property "the order candidates arrive in does not change the answer" do
      # The reason `tiebreak/1` falls through to the provider id. Without a
      # total order, two equally good candidates resolve by whatever order the
      # provider's pagination happened to produce.
      check all(source <- track_generator(), candidates <- candidates_generator()) do
        forward = Matching.match(source, candidates, threshold: :low)
        backward = Matching.match(source, Enum.reverse(candidates), threshold: :low)

        case {forward, backward} do
          {{:ok, left}, {:ok, right}} ->
            assert left.track.provider_id == right.track.provider_id
            assert left.score == right.score

          {{:error, _left}, {:error, _right}} ->
            :ok

          mismatch ->
            flunk("order changed the outcome: #{inspect(mismatch)}")
        end
      end
    end

    property "a raised threshold never admits a match a lower one rejected" do
      check all(source <- track_generator(), candidates <- candidates_generator()) do
        lenient = Matching.match(source, candidates, threshold: 0.1)
        strict = Matching.match(source, candidates, threshold: 0.9)

        if match?({:ok, _match}, strict) do
          assert match?({:ok, _match}, lenient),
                 "a stricter threshold accepted what a lenient one refused"
        end
      end
    end

    property "the chosen match is always one of the candidates" do
      check all(source <- track_generator(), candidates <- candidates_generator()) do
        case Matching.match(source, candidates, threshold: :low) do
          {:ok, match} -> assert match.track in candidates
          {:error, _error} -> :ok
        end
      end
    end

    property "a track always matches itself, at the best confidence available" do
      # Reflexivity. A rung that compared a track to itself and declined has
      # inverted a comparison somewhere.
      check all(track <- track_generator(), track.title != "") do
        assert {:ok, match} = Matching.match(track, [track], threshold: :low)
        assert match.track == track

        if track.isrc do
          assert match.confidence == :exact_isrc
        end
      end
    end

    property "a report's match rate is a proportion" do
      # The ledger law itself — that the two halves account for every input
      # exactly once — is `match_all/2`'s own postcondition, and
      # `contract_holds/2` at the bottom of this file drives it. Restating it
      # here would be the same law maintained in two places. What is left is
      # the derived value, which nothing asserts.
      check all(
              pairs <-
                list_of(
                  gen all(source <- track_generator(), candidates <- candidates_generator()) do
                    {source, candidates}
                  end,
                  max_length: 6
                )
            ) do
        rate = Matching.match_all(pairs, threshold: :low) |> Report.match_rate()

        assert rate >= 0.0 and rate <= 1.0
      end
    end

    property "a score always sits inside its strategy's band" do
      check all(source <- track_generator(), candidates <- candidates_generator()) do
        for match <- Matching.rank(source, candidates) do
          {floor, ceiling} = Confidence.band(match.strategy)

          assert match.score >= floor and match.score <= ceiling,
                 "#{match.strategy} scored #{match.score}, outside #{floor}..#{ceiling}"
        end
      end
    end

    property "an unmatched track always says why, and never asks to be retried" do
      check all(source <- track_generator(), candidates <- candidates_generator()) do
        case Matching.match(source, candidates, threshold: :exact_isrc) do
          {:error, error} ->
            assert Errata.reason(error) in [
                     :below_threshold,
                     :all_rejected,
                     :no_candidates,
                     :unsearchable
                   ]

            refute Errata.retryable?(error)
            assert Errata.context(error).source == source
            assert is_binary(Errata.display_message(error))

          {:ok, _match} ->
            :ok
        end
      end
    end
  end

  describe "corroboration never costs confidence" do
    property "adding an agreeing duration does not lower the score" do
      # The monotonicity law from the design discussion. A weighted mean that
      # divides by the declared total weight rather than the weight used gets
      # this backwards: supplying one more agreeing signal *reduces* the score.
      check all(source <- track_generator(), source.title != "") do
        bare = %{source | duration_seconds: nil}
        candidate = %{bare | provider_id: "candidate"}

        with {:ok, without} <- Matching.match(bare, [candidate], threshold: :low),
             agreeing = %{bare | duration_seconds: 200},
             agreeing_candidate = %{candidate | duration_seconds: 200},
             {:ok, with_duration} <-
               Matching.match(agreeing, [agreeing_candidate], threshold: :low) do
          assert with_duration.score >= without.score,
                 "an agreeing duration lowered the score from #{without.score} " <>
                   "to #{with_duration.score}"
        end
      end
    end
  end

  # The contracts as the oracle. Any `@pre` or `@post` violation across the
  # generated space fails the test, with no expectations restated here.
  contract_holds(&Matching.match/3,
    args: [track_generator(), candidates_generator(), constant(threshold: :low)]
  )

  contract_holds(&Matching.rank/3,
    args: [track_generator(), candidates_generator(), constant([])]
  )

  # `match_all/2`'s ledger postcondition — that the matched and unmatched halves
  # are exactly the input, as a multiset — is the strongest contract in the
  # module and until now was only ever driven by hand-written examples.
  contract_holds(&Matching.match_all/2,
    args: [
      list_of(
        gen all(source <- track_generator(), candidates <- candidates_generator()) do
          {source, candidates}
        end,
        max_length: 6
      ),
      constant(threshold: :low)
    ]
  )

  # Every rung, against its inherited postcondition. One property per module
  # rather than one for the ladder, so a violation names the rung that produced
  # it — the ladder stops at the first rung with an opinion, so driving
  # `match/3` alone leaves the lower rungs largely unvisited.
  contract_holds(&Strategy.Isrc.score/2, args: [track_generator(), track_generator()])
  contract_holds(&Strategy.UpcPosition.score/2, args: [track_generator(), track_generator()])
  contract_holds(&Strategy.Text.score/2, args: [track_generator(), track_generator()])
  contract_holds(&Strategy.Fuzzy.score/2, args: [track_generator(), track_generator()])

  # The `Match` invariant, driven across every strategy. The law it states —
  # a score inside its strategy's band — is upheld today by `in_band/2`, so
  # this is really a property about *that* function: for any raw opinion in
  # `0.0..1.0` and any strategy, scaling must land inside the band.
  contract_holds(&Match.new/1,
    args: [
      gen all(
            raw <- float(min: 0.0, max: 1.0),
            strategy <- member_of([:isrc, :upc_position, :text, :fuzzy]),
            source <- track_generator(),
            track <- track_generator()
          ) do
        [
          source: source,
          track: track,
          score: Confidence.in_band(raw, strategy),
          strategy: strategy
        ]
      end
    ]
  )
end
