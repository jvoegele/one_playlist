defmodule OnePlaylist.Cache.SingleflightPropertyTest do
  @moduledoc """
  The coordinator's invariants, over the state space it can actually reach.

  The invariants on `OnePlaylist.Cache.Singleflight` were verified by mutation:
  break `release/3`, watch the invariant fire. That proves each one *can* fail,
  which is the weaker half of the question. It says nothing about whether some
  ordinary sequence of messages — an acquire interleaved with a completion for
  a different key, a `:DOWN` for a monitor already released — walks the server
  into a state it should not be in.

  Answering that needs the reachable state space, and no hand-written state
  generator can describe it without drifting out of step with the
  implementation. `server_invariants_hold/2` generates message sequences
  instead and lets the server's own `init/1` and callbacks decide which states
  follow, with the invariants as the oracle.

  ## Why `:callbacks` mode

  The default, and the right one here. It threads each callback's returned
  state into the next, so the trajectory is genuinely reachable, and it runs in
  the test process — which matters because `handle_call({:acquire, _}, from, _)`
  monitors the calling process. In `:process` mode a violation would crash the
  server and be reported as a `GenServer terminating` log rather than a
  shrunken counterexample.
  """

  use ExUnit.Case, async: true
  use Bond.PropertyTest

  alias OnePlaylist.Cache.Singleflight

  # A small key space on purpose. Random keys would almost never collide, and a
  # sequence in which no two messages touch the same key exercises none of the
  # coordination this module exists for — the same vacuity trap that let an
  # earlier property suite here generate 0 useful cases out of 500.
  defp key_generator do
    StreamData.member_of([
      {:release, :tidal, "602547670052"},
      {:release, :tidal, "602547670053"},
      {:release, :spotify, "602547670052"}
    ])
  end

  defp result_generator do
    StreamData.one_of([
      StreamData.constant({:ok, "album-1"}),
      StreamData.constant({:ok, nil}),
      StreamData.constant({:error, :timeout})
    ])
  end

  # `:DOWN` for a reference the state has never seen. The matching case cannot
  # be generated — a real monitor reference is minted inside `handle_call` and
  # is not visible to a message generator — so what this covers is the branch
  # that must leave the state untouched. That branch is worth covering: an
  # implementation that assumed every `:DOWN` belonged to a live key would
  # corrupt the state on any stray monitor message.
  defp down_generator do
    StreamData.constant({:DOWN, make_ref(), :process, self(), :normal})
  end

  server_invariants_hold(Singleflight,
    init: StreamData.constant([]),
    messages: [
      call: [{:acquire, [key_generator()]}],
      cast: [{:done, [key_generator(), result_generator()]}],
      info: [down_generator()]
    ]
  )
end
