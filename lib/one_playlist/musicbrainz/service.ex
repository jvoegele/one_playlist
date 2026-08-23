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

  ## Sized for a fallback, not a hot path

  `OnePlaylist.MusicBrainz` is consulted only when an identifier lookup has
  already missed — about one ISRC-bearing track in seven, measured against the
  credit corpus — and every answer is cached in two tiers. So a low concurrency
  limit costs nothing: there is no burst to absorb.

  The breaker is deliberately more forgiving than TIDAL's. A MusicBrainz outage
  is not a failed transfer, it is a transfer that matches as it did before this
  existed, so there is no reason to trip fast.
  """

  use ExternalService,
    # The published policy, exactly. Not a guess to be tuned: going faster is
    # not a performance decision, it is a decision to be blocked.
    rate_limit: [limit: 1, per: :timer.seconds(1)],
    circuit_breaker: [
      tolerate: 10,
      within: :timer.seconds(60),
      reset: :timer.seconds(60)
    ],
    concurrency: [
      # One in flight. Anything more would queue behind the rate limiter anyway,
      # and this makes that explicit rather than incidental.
      limit: 1,
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
