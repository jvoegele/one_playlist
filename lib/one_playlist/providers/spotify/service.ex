defmodule OnePlaylist.Providers.Spotify.Service do
  @moduledoc """
  The guarded front door for every outbound call to Spotify.

  Retries, circuit breaking, rate limiting and a concurrency bulkhead all live
  here rather than at each call site, so `OnePlaylist.Providers.Spotify.Client`
  can be written as if the network were reliable.

  ## One service, where TIDAL has two

  `OnePlaylist.Providers.Tidal` has a separate `WriteService` because TIDAL
  rate-limits mutations far harder than reads — roughly one write every two
  seconds against eight reads a second. Spotify does not make that distinction:
  its limit is a **single rolling window over every call the application makes**,
  reads and writes together. Splitting the budget in two would mean two limiters
  each guessing at their share of one quota, and a write burst would still push
  the shared window over while the write limiter believed itself idle.

  So one service, and the shape of the dependency decided it rather than
  symmetry with the adapter next door.

  ## Why these numbers

  Spotify does not publish a rate limit. What it documents is the *mechanism* —
  a rolling ~30 second window, sized to the application rather than the user,
  with a `Retry-After` header on the 429 — and that mechanism is what the
  settings below are shaped around:

    * `rate_limit` — 10 calls/second. Conservative for the same reason TIDAL's
      is, with an extra one specific to Development Mode: the quota is shared
      across every allowlisted account, so a bulk transfer by one user spends
      the window everybody else is drawing on.

    * `circuit_breaker` — `within` must exceed the retry window plus attempt
      duration or melts never accumulate and the breaker is decorative. Same
      arithmetic as TIDAL's, same 30s.

    * `retry` — `expiry` is 60s rather than TIDAL's 20. Spotify's `Retry-After`
      on a sustained overrun is commonly tens of seconds, occasionally more, and
      an expiry shorter than the wait the service *asked for* turns a polite
      instruction into a failed transfer. `Client` honours the header
      explicitly; this is the budget that lets it.

    * `concurrency` — sized to the connection pool rather than to Spotify.
      `reclaim_after` must exceed the client receive timeout, or a merely-slow
      call has its slot stolen and the limit is quietly defeated.

  Tune with `ExternalService.explain/1` and `ExternalService.simulate/3` rather
  than by intuition; both are covered in `docs/reference/jv-libraries.md`.
  """

  use ExternalService,
    rate_limit: [limit: 10, per: :timer.seconds(1)],
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
      cap: :timer.seconds(20),
      max_attempts: 4,
      expiry: :timer.seconds(60),
      jitter: true
    ]
end
