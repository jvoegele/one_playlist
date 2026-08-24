defmodule OnePlaylist.ContractsTest do
  @moduledoc """
  The contracts added in the codebase-wide pass, each proved able to fire.

  These live together rather than in each module's own test file because what
  they have in common is the point: every one guards a *silent* failure, and
  every one is falsifiable by **data** — a config value, a provider response, a
  row read back from the database — rather than only by mutating the code. That
  is the stronger of the two categories in `docs/reference/contracts.md`, and it
  is why none of them shows up as `⚠ never failed`.
  """

  use ExUnit.Case, async: true
  use Bond.Test

  alias OnePlaylist.Matching
  alias OnePlaylist.Transfers
  alias OnePlaylist.Transfers.Transfer
  alias OnePlaylist.Transfers.TransferItem

  describe "Matching.threshold/1 — a threshold that can never be met" do
    test "a percentage where a proportion belongs is rejected" do
      # The classic magnitude bug, and the most consequential one here.
      # `to_score/1` turns an integer into `value / 1`, so `75` — meaning 75%,
      # which is how everyone says it — becomes 75.0. No score can reach it, so
      # every transfer completes with every track reported unmatched and an
      # empty destination playlist. Nothing raises.
      assert_postcondition_violation(Matching.threshold(threshold: 75), label: :is_a_proportion)
      assert_postcondition_violation(Matching.threshold(threshold: 75.0), label: :is_a_proportion)
    end

    test "a negative threshold is rejected too" do
      assert_postcondition_violation(Matching.threshold(threshold: -0.5),
        label: :is_a_proportion
      )
    end

    test "a misspelled confidence is rejected before it resolves to 1.0" do
      # The same catastrophe by a different road, and invisible to the
      # postcondition above: `:hgih` falls through `to_score/1`'s `Enum.find/3`
      # default to 1.0, which is a perfectly valid proportion. Only a flawless
      # score would then pass, so everything but an exact-identifier match is
      # reported unmatched.
      assert_precondition_violation(Matching.threshold(threshold: :hgih),
        label: :threshold_request_is_meaningful
      )
    end

    test "the two assertions genuinely cover different things" do
      # Neither subsumes the other, which is what stops this being the
      # "two guards" mistake recorded in docs/reference/contracts.md.
      assert Matching.valid_threshold_request?(threshold: 75),
             "75 is a meaningful *request*; it is the resolved value that is wrong"

      refute Matching.valid_threshold_request?(threshold: :hgih)
    end

    test "every real threshold spelling still resolves" do
      for confidence <- OnePlaylist.Matching.Confidence.all() do
        rate = Matching.threshold(threshold: confidence)
        assert rate >= 0.0 and rate <= 1.0
      end

      assert Matching.threshold(threshold: 0.75) == 0.75
      assert Matching.threshold() >= 0.0
    end
  end

  describe "Matching.Report — the threshold invariant, lifted" do
    alias OnePlaylist.Matching.Report

    test "a percentage stored on a report is caught when the report is used" do
      # Independent of `threshold/1`'s postcondition rather than a copy of it: a
      # report built directly never goes near that function, so nothing else
      # looks at this value. Falsifiable from a plain test, with no mutation and
      # no bad config — the strongest of the three categories.
      assert_invariant_violation(Report.total(%Report{threshold: 75.0}),
        label: :threshold_is_a_proportion
      )
    end

    test "it guards every entry point, not just one" do
      report = %Report{threshold: 1.5}

      for call <- [
            fn -> Report.total(report) end,
            fn -> Report.match_rate(report) end,
            fn -> Report.by_confidence(report) end,
            fn -> Report.ambiguous(report) end,
            fn -> Report.needs_review(report) end
          ] do
        assert_raise Bond.InvariantError, call
      end
    end

    test "the two assertions cover different surfaces" do
      # `match/3` resolves a threshold and builds no report, so only the
      # postcondition guards it. A report built by hand never calls `threshold/1`,
      # so only the invariant guards that. Neither is reachable from the other.
      assert_postcondition_violation(Matching.threshold(threshold: 75), label: :is_a_proportion)

      assert_invariant_violation(Report.total(%Report{threshold: 75.0}),
        label: :threshold_is_a_proportion
      )
    end

    test "the match rate is a proportion at both extremes" do
      # `Report.match_rate/1`'s `is_a_proportion` cannot be falsified by data:
      # `total/1` *is* matched + unmatched, so the quotient is in range for every
      # report that can be built. It is a pure-function law, proven by mutation
      # (inverting the division fires it) and kept because it states what the
      # function means — the third row of the table in
      # docs/reference/contracts.md, not a candidate for deletion.
      assert Report.match_rate(%Report{threshold: 0.75}) == 1.0
      assert Report.match_rate(%Report{threshold: 0.75, matched: [1], unmatched: [2]}) == 0.5

      assert Report.match_rate(%Report{threshold: 0.75, unmatched: [1, 2]}) == 0.0
    end

    test "a real report is unaffected" do
      report = %Report{threshold: 0.75, matched: [], unmatched: []}

      assert Report.total(report) == 0
      assert Report.match_rate(report) == 1.0
    end
  end

  describe "Transfer.match_rate/1 — now that the UI renders it" do
    test "a ledger that does not add up is caught rather than displayed" do
      # The re-run accumulation bug that actually happened here: six matched of
      # three total. It would render as "200% of the source" on the transfer
      # page. Falsifiable by data — no mutation needed.
      #
      # Caught by the `@invariant` on entry since bond 1.15.0 made invariants
      # usable on an `Ecto.Schema`, rather than by `match_rate/1`'s own
      # `is_a_proportion` postcondition on the way out. That is a strict
      # improvement and worth stating rather than merely accommodating: the value
      # is rejected before the division instead of after it, so the label names
      # the ledger that is wrong rather than the percentage derived from it.
      #
      # `is_a_proportion` is kept. It is a different claim — that this function's
      # arithmetic produces a proportion — and it would still catch a rewrite
      # that divided by the wrong field on a perfectly balanced transfer.
      assert_invariant_violation(
        Transfer.match_rate(%Transfer{total_tracks: 3, matched_count: 6}),
        label: :ledger_balances
      )
    end

    test "the honest extremes still work" do
      assert Transfer.match_rate(%Transfer{total_tracks: 0}) == 1.0
      assert Transfer.match_rate(%Transfer{total_tracks: 10, matched_count: 0}) == 0.0
      assert Transfer.match_rate(%Transfer{total_tracks: 10, matched_count: 10}) == 1.0
    end
  end

  describe "Transfers.record_run/3 — the report and the summary must agree" do
    setup do
      transfer = %Transfer{
        id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        status: :running
      }

      %{transfer: transfer}
    end

    defp counted(total, matched, added, unmatched) do
      %Transfer{
        total_tracks: total,
        matched_count: matched,
        added_count: added,
        unmatched_count: unmatched
      }
    end

    defp rows(matched, already_present, unmatched) do
      List.duplicate(%{outcome: :matched}, matched) ++
        List.duplicate(%{outcome: :already_present}, already_present) ++
        List.duplicate(%{outcome: :unmatched}, unmatched)
    end

    test "a report with more matched rows than the counter admits", %{transfer: transfer} do
      # The failure this exists for: the transfer list would show "2/3 matched"
      # above a report containing three matched rows. Neither number is
      # obviously the wrong one and nothing raises.
      assert_precondition_violation(
        Transfers.record_run(transfer, counted(3, 2, 2, 1), rows(3, 0, 0)),
        label: :report_agrees_with_counters
      )
    end

    test "a report missing a row entirely", %{transfer: transfer} do
      assert_precondition_violation(
        Transfers.record_run(transfer, counted(3, 2, 2, 1), rows(2, 0, 0)),
        label: :report_agrees_with_counters
      )
    end

    test "already_present counts as matched but not as added", %{transfer: transfer} do
      # The distinction a re-run turns on, and the one a naive tally gets wrong.
      assert_precondition_violation(
        Transfers.record_run(transfer, counted(2, 2, 2, 0), rows(1, 1, 0)),
        label: :report_agrees_with_counters
      )
    end
  end

  describe "Transfer.record_write/1 — the ledger move a correction makes" do
    test "a row that resolved and was already there becomes one this run wrote" do
      # `:already_present` counts toward `matched` and not toward `added`.
      # Correcting it writes a track, so `added` moves and nothing else does.
      counted =
        Transfer.record_write(%Transfer{total_tracks: 3, matched_count: 3, added_count: 1})

      assert {counted.matched_count, counted.added_count, counted.unmatched_count} == {3, 2, 0}
    end

    test "writing more than was matched is caught, not rendered as 133%" do
      # Falsifiable by data rather than only by mutation: calling this for a row
      # that was already `:matched` — already resolved *and* already written —
      # pushes `added` past `matched`. Nothing raises without the invariant; the
      # report simply claims more tracks were added than were found, and
      # `match_rate/1` renders a number above 100%.
      full = %Transfer{total_tracks: 3, matched_count: 2, added_count: 2}

      assert_invariant_violation(Transfer.record_write(full), label: :added_at_most_matched)
    end
  end

  describe "TransferItem.tally/1 and Transfer.tally/1" do
    test "produce the same shape from the two representations" do
      # The whole point of the pair: one law, computed two ways, compared.
      items = [
        %{outcome: :matched},
        %{outcome: :matched},
        %{outcome: :already_present},
        %{outcome: :unmatched}
      ]

      transfer = %Transfer{
        total_tracks: 4,
        matched_count: 3,
        added_count: 2,
        unmatched_count: 1
      }

      assert TransferItem.tally(items) == Transfer.tally(transfer)
    end

    test "counts persisted rows the same as unpersisted maps" do
      # `matched/4` returns a plain map before the write; the database returns
      # structs afterwards. A tally that only understood one of them would make
      # the precondition unusable from half the places it is wanted.
      assert TransferItem.tally([%TransferItem{outcome: :matched}]) ==
               TransferItem.tally([%{outcome: :matched}])
    end

    test "an unrecognised outcome is counted but not classified" do
      # Deliberate: the comparison then fails and says so, rather than the tally
      # raising from inside an assertion — which would be an
      # AssertionEvaluationError naming nothing useful.
      assert TransferItem.tally([%{outcome: nil}]) ==
               %{total: 1, matched: 0, added: 0, unmatched: 0}
    end
  end
end
