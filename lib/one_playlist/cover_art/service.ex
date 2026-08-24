defmodule OnePlaylist.CoverArt.Service do
  @moduledoc """
  Retries, rate limiting and circuit breaking for the Cover Art Archive.

  ## Why this is not `OnePlaylist.MusicBrainz.Service`

  Cover Art Archive is a MetaBrainz project and shares MusicBrainz's
  identifiers, which makes sharing a service module tempting. It is a different
  service with different properties, and `CLAUDE.md`'s rule — one
  `ExternalService` per provider, sized to that provider's real limits — is the
  right one here rather than a formality:

    * It publishes **no one-request-a-second rule**. That limit belongs to the
      MusicBrainz web service, and inheriting it would halve enrichment's
      throughput for a service that never asked for it.
    * It **redirects to archive.org**, which serves the images. So a call here
      is two round trips through a CDN rather than one to a small API, and the
      timeout that suits MusicBrainz is not the timeout that suits this.
    * Its failures are **cosmetic**. A missing cover is a missing thumbnail; a
      missing ISRC is a track that cannot be transferred. There is no reason for
      an outage here to consume the budget of the service that matters.

  ## Still polite, and still background

  Two a second rather than one, which is restraint rather than measurement —
  MetaBrainz asks for a descriptive user agent and reasonable use, and this is
  a volunteer-run archive serving image files for free.

  `wait: :infinity` on the limiter for the reason
  `OnePlaylist.MusicBrainz.Service` gives at length: every caller is an Oban
  job, nobody is waiting on a socket, and sleeping is the back-pressure. The
  bulkhead's wait stays bounded, because a concurrency slot frees only when
  another call finishes.

  The breaker is the most forgiving in the application. Tripping it costs
  nothing but thumbnails, and enrichment carries on filling in everything else.
  """

  use ExternalService,
    rate_limit: [limit: 2, per: :timer.seconds(1), wait: :infinity],
    circuit_breaker: [
      tolerate: 10,
      within: :timer.seconds(60),
      reset: :timer.seconds(60)
    ],
    concurrency: [
      limit: 2,
      wait: :timer.seconds(30),
      reclaim_after: :timer.seconds(30)
    ],
    retry: [
      backoff: :exponential,
      base: 1_000,
      cap: :timer.seconds(10),
      # One fewer than MusicBrainz's. A cover that cannot be fetched twice is
      # not worth a third attempt when the answer is a thumbnail.
      max_attempts: 2,
      expiry: :timer.seconds(20),
      jitter: true
    ]
end
