defmodule OnePlaylist.MusicBrainz.Service do
  @moduledoc """
  Retries, rate limiting and circuit breaking for MusicBrainz.

  ## One request per second, and it is not negotiable

  MusicBrainz asks anonymous clients for an average of one request a second and
  enforces it. The service reports its own accounting in `X-RateLimit-Limit`
  (1200) and `X-RateLimit-Remaining`, and answers `503` when a client goes over.

  So the limiter here is set to exactly that, and it is the whole reason this is
  a service module rather than a bare `Req` call: a transfer resolving a
  thousand tracks would otherwise hammer a volunteer-run project and be blocked,
  correctly.

  ## Every caller here is background work, so it sleeps rather than sheds

  `wait: :infinity` on the limiter, and a bounded wait on the bulkhead. That is
  the rule `OnePlaylist.Providers.Tidal.WriteService` states and the reason is
  the same: sleeping is the back-pressure, and it propagates upstream to a
  caller that has nowhere else to be. Every path here is an Oban job — the two
  fallbacks in `OnePlaylist.Transfers.Runner`, and enrichment — so nobody is
  waiting on the other end of a socket.

  Without it this service had **both** defects that module documents, and
  enrichment is what found them. A single limiter check never quotes more than
  one emission interval, `per / limit` — **1000ms** here — and the default
  budget is one window, so the second of two sequential calls is shed rather
  than paced. `ExternalService.explain/1` said so plainly once it was asked:
  *"waits up to nothing — a throttled call returns RateLimited immediately"*.
  Four ordinary requests in a row were enough to produce a `RateLimited`.

  The asymmetry between the two waits is deliberate and is the library's own:
  a quota refills on its own, so sleeping for one terminates, while a
  concurrency slot frees only when another call finishes — an unbounded wait
  there is the unbounded pile-up, and `start/2` refuses it.

  ## Sized for a fallback that became a workload

  `OnePlaylist.MusicBrainz` was consulted only when an identifier lookup had
  already missed — about one ISRC-bearing track in seven — and everything was
  cached in two tiers, so a low concurrency limit cost nothing. Enrichment
  changes the shape: it is nothing *but* sustained sequential lookups. The
  limits are unchanged, because one request a second is the published policy
  either way; what changed is that they now have to pace a queue rather than
  absorb an occasional miss.

  The breaker is deliberately more forgiving than TIDAL's. A MusicBrainz outage
  is not a failed transfer, it is a transfer that matches as it did before this
  existed, so there is no reason to trip fast.
  """

  use ExternalService,
    # The published policy, exactly. Not a guess to be tuned: going faster is
    # not a performance decision, it is a decision to be blocked.
    #
    # `wait: :infinity` because every caller is background — see the moduledoc.
    rate_limit: [limit: 1, per: :timer.seconds(1), wait: :infinity],
    circuit_breaker: [
      tolerate: 10,
      within: :timer.seconds(60),
      reset: :timer.seconds(60)
    ],
    concurrency: [
      # One in flight. Anything more would queue behind the rate limiter anyway,
      # and this makes that explicit rather than incidental.
      limit: 1,
      # Bounded, unlike the limiter above: a slot frees only when another call
      # finishes, so an unbounded wait here is a pile-up rather than
      # back-pressure. Generous enough that a queue of enrichment jobs paces
      # instead of shedding, since each is at most a couple of seconds.
      wait: :timer.seconds(30),
      reclaim_after: :timer.seconds(30)
    ],
    retry: [
      backoff: :exponential,
      base: 1_000,
      cap: :timer.seconds(10),
      max_attempts: 3,
      expiry: :timer.seconds(30),
      jitter: true
    ]
end
