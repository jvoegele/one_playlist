defmodule OnePlaylist.Providers.Tidal.Service do
  @moduledoc """
  The guarded front door for every outbound call to TIDAL.

  Retries, circuit breaking, rate limiting and a concurrency bulkhead all live
  here rather than at each call site, so `OnePlaylist.Providers.Tidal.Client`
  can be written as if the network were reliable.

  ## Why these numbers

  TIDAL does not publish its rate limits, and the community reports 429s on
  catalog reads far more often than on playlist operations. That absence is the
  reason for the settings below rather than an excuse for guessing: with no
  published quota, the only safe posture is to stay well under whatever it is
  and to treat a 429 as information rather than as an error.

    * `rate_limit` — 8 calls/second is deliberately conservative. It costs
      nothing on interactive use (a page load makes a handful of calls) and
      keeps a bulk transfer from discovering the real limit the hard way.
      `wait: :infinity` is wrong here and `false` is too harsh, so the default
      one-window budget stands: a burst waits, sustained overload sheds.

    * `circuit_breaker` — `within` must exceed the retry window plus attempt
      duration or melts never accumulate and the breaker is decorative. The
      retry window below is ~1.5s and a slow TIDAL response is a few seconds, so
      10s is the floor; 30s gives headroom for the dependency slowing down.
      `tolerate: 5` counts *calls*, not attempts, since external_service 3.0.

    * `concurrency` — sized to the connection pool rather than to TIDAL.
      `reclaim_after` must exceed the client receive timeout (10s, set in
      `Client`), or a merely-slow call has its slot stolen and the limit is
      quietly defeated.

    * `retry` — jitter matters more than usual: a bulk transfer runs many calls
      in near-lockstep, which is exactly the thundering herd jitter exists for.

  Tune with `ExternalService.explain/1` and `ExternalService.simulate/3` rather
  than by intuition; both are covered in `docs/reference/jv-libraries.md`.
  """

  use ExternalService,
    rate_limit: [limit: 8, per: :timer.seconds(1)],
    circuit_breaker: [
      tolerate: 5,
      within: :timer.seconds(30),
      reset: :timer.seconds(30)
    ],
    concurrency: [
      limit: 10,
      reclaim_after: :timer.seconds(30)
    ],
    retry: [
      backoff: :exponential,
      base: 200,
      cap: :timer.seconds(5),
      max_attempts: 4,
      expiry: :timer.seconds(20),
      jitter: true
    ]
end
