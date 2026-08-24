defmodule OnePlaylist.Providers.Tidal.WriteService do
  @moduledoc """
  The guarded front door for calls to TIDAL that **change** something.

  A second `ExternalService` alongside
  `OnePlaylist.Providers.Tidal.Service`, because reads and writes to TIDAL do
  not behave alike and sizing one limiter for both means sizing it wrong for
  one of them.

  ## Measured, not assumed

  `docs/reference/domain.md` recorded — from community reports — that 429s were
  common on catalogue reads and rare on playlist operations. Verified live on
  2026-08-22, that is backwards for bursts: **five playlist deletes issued back
  to back returned one 200 and four 429s.** Re-issued with two seconds between
  them, all four succeeded first time.

  So mutations get a rate limit an order of magnitude below the read one. On
  interactive use that costs nothing — creating a playlist is one call — and on
  a bulk transfer it is the difference between a steady write rate and a
  breaker full of 429s.

  ## Why a separate breaker, not just a separate limit

  Isolation in both directions. A transfer hammering the write endpoints should
  not open the breaker that serves everybody's library browsing, and a catalogue
  outage should not stop a queued transfer from retrying its writes. They fail
  for different reasons and should recover independently.

  ## The read service's settings are not transferable, twice over

  Two of the four option groups here differ from
  `OnePlaylist.Providers.Tidal.Service`, and copying either across is wrong in
  a way that does not announce itself:

    * `:within` on the breaker is a property of the **retry budget**, not the
      provider. 30s is right next door, where the retry window is ~1.5s, and
      leaves the breaker unable to open here, where it is 7.5s.
    * `:wait` on the limiter is a property of the **call site**, not the
      provider. A finite budget is right next door, where a person is waiting on
      a page; it sheds a background job that should simply have slept.

  Copying a whole configuration between two services for the same dependency
  looks like consistency. It is how both of those go wrong.

  ## Retries are the same shape, deliberately

  A 429 is classified `{:retry, …}` in `OnePlaylist.Providers.Tidal.Client`, so
  the rate limit is the *first* defence and the retry budget the second. The
  limiter is what should normally keep us under the quota; the retries are for
  when the real limit turns out to be lower than the guess above — which, given
  that TIDAL publishes nothing, it may well be.
  """

  use ExternalService,
    # Two seconds between mutations is the spacing that worked when the burst
    # did not. Deliberately blunt: there is no published quota to tune against,
    # and the cost of being too slow is a longer transfer while the cost of
    # being too fast is a wedged one.
    #
    # `wait: :infinity` because of **where these calls are made**, not because of
    # TIDAL. `external_service`'s rate-limiting guide draws the line exactly
    # here: background work sleeps, because sleeping is the back-pressure and it
    # propagates upstream; a request path takes a finite budget, because a client
    # that has already given up is being served for nothing. Every caller of this
    # service is an Oban job. Nobody is waiting on the other end.
    #
    # The default was actively harmful at this shape, which is worth spelling out
    # because the numbers collide invisibly. A single limiter check never quotes
    # more than one emission interval — `per / limit`, so **2000ms** here — and
    # the default budget is one window, also **2000ms**. One re-check exhausts
    # it, so the slightest contention sheds rather than paces. Observed: two
    # transfers of the same playlist racing produced
    # `the call was throttled beyond the configured rate limit wait time`.
    rate_limit: [limit: 1, per: :timer.seconds(2), wait: :infinity],
    # `within` is 75s rather than the read service's 30s, and the number is not
    # a guess: `ExternalService`'s compile-time linter rejects 30s here and
    # computes this one. The write retry budget is longer (5 attempts, a 10s
    # cap), so six failing calls spread their melts over ~37.5s — wider than a
    # 30s window counts over, which would leave the breaker decorative for
    # exactly the sequential caller a transfer is.
    #
    # Worth noting that the same 30s is correct next door, where the retry
    # window is ~1.5s. Copying a breaker setting between services is how you get
    # one that never trips.
    circuit_breaker: [
      tolerate: 5,
      within: :timer.seconds(75),
      reset: :timer.seconds(30)
    ],
    # Far below the read bulkhead. Writes to one playlist are ordered by nature,
    # and running many at once only races the rate limiter.
    #
    # `wait` is set because the bulkhead is the *other* place a background call
    # can be shed, and `explain/1` is what surfaced it: with the default it
    # "waits up to nothing — a throttled call returns RateLimited immediately".
    # Fixing the limiter's budget and leaving this one would have moved the
    # shedding rather than removed it.
    #
    # Bounded rather than `:infinity`, and that asymmetry with the limiter above
    # is deliberate on the library's part: a quota refills on its own, so
    # sleeping for one terminates, while a slot frees only when another call
    # finishes — an unbounded wait there is the unbounded pile-up. `start/2`
    # refuses it. Ten seconds parks a write behind a few others and still sheds a
    # genuine backlog.
    concurrency: [
      limit: 2,
      wait: :timer.seconds(10),
      reclaim_after: :timer.seconds(30)
    ],
    # A longer expiry than reads get. A 429 on a write is worth waiting out —
    # the alternative is a half-transferred playlist, which is worse than a slow
    # one — whereas a read that gives up can simply be repeated later.
    retry: [
      backoff: :exponential,
      base: 500,
      cap: :timer.seconds(10),
      max_attempts: 5,
      expiry: :timer.seconds(60),
      jitter: true
    ]
end
