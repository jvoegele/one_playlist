defmodule OnePlaylist.Transfers.ProgressTest do
  use ExUnit.Case, async: true

  alias OnePlaylist.Transfers.Progress

  # Times are passed rather than slept, so these assert the batching rules
  # themselves instead of asserting that the machine is fast enough.
  defp item(position), do: %{position: position, outcome: :matched}

  defp add_all(progress, positions, now) do
    Enum.reduce(positions, {[], progress}, fn position, {sent, progress} ->
      {batch, progress} = Progress.add(progress, item(position), now)
      {sent ++ batch, progress}
    end)
  end

  describe "batching by count" do
    test "holds tracks until a batch is full, then hands the whole batch over" do
      progress = Progress.new(10, batch: 3, interval: 1_000, now: 0)

      # Same instant throughout, so only the count can trigger a handover.
      {batch, progress} = Progress.add(progress, item(0), 0)
      assert batch == []

      {batch, progress} = Progress.add(progress, item(1), 0)
      assert batch == []

      {batch, _progress} = Progress.add(progress, item(2), 0)
      assert Enum.map(batch, & &1.position) == [0, 1, 2]
    end

    test "hands them over oldest first" do
      progress = Progress.new(10, batch: 4, interval: 1_000, now: 0)

      {sent, _progress} = add_all(progress, [0, 1, 2, 3], 0)

      assert Enum.map(sent, & &1.position) == [0, 1, 2, 3],
             "the buffer is built by prepending, so a missing reverse draws the report backwards"
    end
  end

  describe "batching by time" do
    test "a slow run does not wait for a full batch" do
      # One track, and a batch size it will never reach. Without the interval
      # this would sit in the buffer until the run ended.
      progress = Progress.new(10, batch: 25, interval: 500, now: 0)

      {batch, _progress} = Progress.add(progress, item(0), 500)

      assert Enum.map(batch, & &1.position) == [0]
    end

    test "the interval runs from the last handover, not from the start" do
      progress = Progress.new(10, batch: 25, interval: 500, now: 0)

      {[_ | _], progress} = Progress.add(progress, item(0), 500)

      # 400ms after that handover: not yet due, even though 900ms have passed
      # since the run began.
      {batch, _progress} = Progress.add(progress, item(1), 900)

      assert batch == []
    end
  end

  describe "the final flush" do
    test "hands over a partial batch that no rule would have triggered" do
      progress = Progress.new(10, batch: 25, interval: 500, now: 0)

      {[], progress} = Progress.add(progress, item(0), 0)
      {[], progress} = Progress.add(progress, item(1), 0)

      {batch, progress} = Progress.flush(progress, 0)

      assert Enum.map(batch, & &1.position) == [0, 1]
      assert progress.buffer == []
    end

    test "is harmless when nothing is waiting" do
      progress = Progress.new(10, batch: 2, interval: 500, now: 0)
      {[_, _], progress} = add_all(progress, [0, 1], 0)

      assert {[], _progress} = Progress.flush(progress, 0)
    end
  end

  describe "conservation" do
    test "every track added is handed over exactly once, whatever the timings" do
      # A mix of both triggers: a burst at one instant, a slow stretch, another
      # burst, and a tail that only the final flush can reach.
      progress = Progress.new(50, batch: 5, interval: 100, now: 0)

      {sent, progress} =
        Enum.reduce(Enum.with_index(0..29), {[], progress}, fn {position, index}, {sent, p} ->
          # Time advances in a pattern that crosses the interval irregularly.
          now = index * 37
          {batch, p} = Progress.add(p, item(position), now)
          {sent ++ batch, p}
        end)

      {tail, progress} = Progress.flush(progress, 2_000)
      sent = sent ++ tail

      assert Enum.map(sent, & &1.position) == Enum.to_list(0..29),
             "each track once, in order, with nothing lost or repeated"

      assert progress.resolved == 30
      assert progress.reported == 30
      assert progress.buffer == []
    end
  end
end
