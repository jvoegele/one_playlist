defmodule OnePlaylist.Transfers.Progress do
  @moduledoc """
  Batches per-track results so a large transfer does not flood its watchers.

  Broadcasting once per resolved track is right for a 58 track import and wrong
  for a 5,000 track one: 5,000 PubSub messages, 5,000 LiveView diffs, and a
  browser asked to append 5,000 table rows one at a time.

  This holds results and hands them back in batches — when `:batch` of them have
  accumulated, or when `:interval` milliseconds have passed since the last
  handover, whichever comes first.

  ## Why both conditions, rather than the simpler one

  They cover opposite failure modes, and each is useless against the other's.

  A count alone fails when tracks resolve slowly. TIDAL is rate limited to 8
  calls a second, so a batch of 25 is three seconds of a progress bar that does
  not move, and a playlist ending in 24 stragglers would sit there until the
  final flush.

  An interval alone fails when they resolve quickly. A cached re-run, or a
  Navidrome server on the same machine, resolves faster than any interval
  usefully divides, and the batch is then bounded only by how many tracks fit in
  500ms.

  ## The clock is a parameter

  `add/3` and `flush/2` take the current monotonic time rather than reading it,
  so the batching rules can be tested by passing times instead of sleeping.
  Production callers omit it.
  """

  use Bond

  # 25 tracks is roughly three seconds of TIDAL's rate limit, and 500ms is
  # comfortably below the point where a progress bar reads as stuck.
  @batch 25
  @interval 500

  # `reported` exists to be cross-checked against `resolved`, which is
  # accumulated separately, one per `add/3`. Keeping the two and asserting they
  # agree is what makes `every_track_accounted_for` a real check rather than a
  # restatement of the body — see `docs/reference/contracts.md`.
  defstruct [
    :total,
    :batch,
    :interval,
    :last_flush_at,
    resolved: 0,
    reported: 0,
    matched: 0,
    unmatched: 0,
    buffer: []
  ]

  @type item :: map()

  @type t :: %__MODULE__{
          total: non_neg_integer(),
          batch: pos_integer(),
          interval: non_neg_integer(),
          last_flush_at: integer(),
          resolved: non_neg_integer(),
          reported: non_neg_integer(),
          matched: non_neg_integer(),
          unmatched: non_neg_integer(),
          buffer: [item()]
        }

  # Every track handed to `add/3` is either already on its way to the watchers
  # or still waiting in the buffer. Never both, which would show a row twice,
  # and never neither, which would lose it silently — the row simply never
  # appears, the counters still add up, and nothing raises.
  #
  # This is the whole risk of batching stated in one line, and it is checkable
  # only because `resolved` and `reported` are accumulated independently.
  #
  # Reads `⚠ never failed` in the coverage table and should: no input can
  # falsify it, so it is verified by mutation instead. Dropping the
  # `+ length(items)` from `drain/2` fires this and nothing else.
  @invariant every_track_accounted_for: accounted_for?(subject)

  # The running tallies are what the report's filter tabs count while a run is
  # in flight, and a tab that disagrees with the progress bar beside it is the
  # kind of wrong a person notices immediately and cannot explain.
  #
  # Not implied by the first invariant, which counts tracks through the buffer
  # and never looks at what any of them says. This one counts the same tracks by
  # outcome, so it also catches the case that motivates it: a provisional item
  # carrying an outcome that is neither — `:already_present`, which a run cannot
  # know yet — falls out of both tallies and is silently uncounted.
  @invariant outcomes_partition_the_resolved: partitioned?(subject)

  # The two laws above, in one place each, so that the `@invariant` and the
  # postconditions that cover for it below cannot drift apart. Private, and so
  # not subject to the trap in `docs/reference/contracts.md` where a *public*
  # predicate over an invariant raises on exactly the values it exists to
  # identify.
  defp accounted_for?(%__MODULE__{} = progress),
    do: progress.resolved == progress.reported + length(progress.buffer)

  defp partitioned?(%__MODULE__{} = progress),
    do: progress.resolved == progress.matched + progress.unmatched

  @doc """
  A buffer for a run of `total` tracks.

  Options are `:batch`, `:interval` and `:now`, all with production defaults.
  """
  @spec new(non_neg_integer(), keyword()) :: t()
  def new(total, opts \\ []) when is_integer(total) and total >= 0 do
    %__MODULE__{
      total: total,
      batch: Keyword.get(opts, :batch, @batch),
      interval: Keyword.get(opts, :interval, @interval),
      last_flush_at: Keyword.get(opts, :now, now())
    }
  end

  @doc """
  Records one resolved track.

  Returns the batch to broadcast, which is empty unless this track is the one
  that made a batch due, and the buffer to carry forward.
  """
  # Bond checks an `@invariant` on entry and on a result that *is* a struct of
  # the module. This returns the struct inside a tuple, so the exit check finds
  # nothing to look at and a violation introduced here is caught only by the
  # next call's entry check — which for the last call of a run never comes.
  # Verified: with the outcome tally broken, `add/3` returned a bad struct
  # without raising, and only the following `flush/2` noticed.
  #
  # So the laws are restated where they can see the value the caller actually
  # gets. The predicates are shared with the invariant, so this is one law in
  # two places rather than two statements of one law.
  @post whenever(
          {_batch, updated} <- result,
          every_track_accounted_for: accounted_for?(updated),
          outcomes_partition_the_resolved: partitioned?(updated)
        )
  @spec add(t(), item(), integer()) :: {[item()], t()}
  def add(%__MODULE__{} = progress, item, now \\ now()) do
    progress = %{
      progress
      | resolved: progress.resolved + 1,
        buffer: [item | progress.buffer],
        matched: progress.matched + count_of(item, :matched),
        unmatched: progress.unmatched + count_of(item, :unmatched)
    }

    if due?(progress, now), do: drain(progress, now), else: {[], progress}
  end

  defp count_of(%{outcome: outcome}, outcome), do: 1
  defp count_of(_item, _outcome), do: 0

  @doc """
  Hands back everything still waiting, however little that is.

  Called once when a run finishes. Without it a run ending mid-batch would leave
  its last few tracks in the buffer, and those rows would never appear.
  """
  # The tail is exactly the part a batching scheme loses, and it loses it
  # quietly: the final report still lands a moment later and papers over the
  # gap, so the only symptom is rows that flicker in late.
  #
  # Not implied by `every_track_accounted_for`, which a stranded buffer can
  # satisfy: a `flush/2` that returns the items but hands back the buffer
  # untouched *and* leaves `reported` alone keeps the ledger balanced and fires
  # only this. Verified by exactly that mutation.
  @post whenever(
          {_items, drained} <- result,
          nothing_held_back: drained.buffer == [],
          # Same tuple gap as `add/3`.
          every_track_accounted_for: accounted_for?(drained),
          outcomes_partition_the_resolved: partitioned?(drained)
        )
  @spec flush(t(), integer()) :: {[item()], t()}
  def flush(%__MODULE__{} = progress, now \\ now()), do: drain(progress, now)

  defp due?(%__MODULE__{} = progress, now) do
    length(progress.buffer) >= progress.batch or now - progress.last_flush_at >= progress.interval
  end

  # Oldest first: the buffer is built by prepending, and watchers append these
  # rows in the order they arrive, so a missing reverse would draw the report
  # backwards within every batch.
  defp drain(%__MODULE__{} = progress, now) do
    items = Enum.reverse(progress.buffer)

    {items,
     %{
       progress
       | buffer: [],
         reported: progress.reported + length(items),
         last_flush_at: now
     }}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
