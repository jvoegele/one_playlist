defmodule OnePlaylist.Providers.Subsonic.Service do
  @moduledoc """
  The guarded front door for calls to a Subsonic server.

  ## Sized for a different kind of dependency

  TIDAL is a shared, remote, rate-limited service with an unpublished quota.
  A Subsonic server is **the user's own machine**, often on their own network,
  frequently a Raspberry Pi. Those want opposite settings, and copying either
  TIDAL service here would have been the third instance of the mistake recorded
  in `OnePlaylist.Providers.Tidal.WriteService`.

    * **No rate limit at all.** There is no quota to stay under. The one thing
      throttling would achieve is making a user's own library slower to read
      than it needs to be.

    * **A small concurrency limit anyway.** Not to protect the server from us —
      to protect *us* from it. A slow home server with ten requests in flight
      ties up ten connections from a pool sized for everything else, and the
      bulkhead is what stops one user's Pi degrading everybody else's transfers.

    * **A shorter retry budget than TIDAL gets.** A 502 from a shared service is
      usually transient and worth waiting out; a self-hosted server that is not
      answering is usually *off*, and retrying for a minute serves nobody.

    * **A breaker that opens quickly and resets quickly.** Per server would be
      ideal — one user's server being down says nothing about another's — but
      `ExternalService` keys on the module, so this is shared. That makes it a
      **coarse** protection, and the settings are chosen accordingly: it opens
      after enough failures to be sure, and resets fast so a recovered server is
      not locked out by an unrelated one.

  > #### A known limitation {: .warning}
  >
  > One breaker across every user's server is wrong in principle. It is
  > acceptable now because this application has one user and one server, and it
  > is the first thing to revisit when it has two. The fix is a dynamic service
  > per host rather than a module-level one.
  """

  use ExternalService,
    circuit_breaker: [
      tolerate: 10,
      within: :timer.seconds(60),
      reset: :timer.seconds(15)
    ],
    concurrency: [
      limit: 4,
      # Background transfers do the bulk of this, and a home server is slow
      # rather than saturated — parking briefly beats shedding a track.
      wait: :timer.seconds(5),
      reclaim_after: :timer.seconds(30)
    ],
    retry: [
      backoff: :exponential,
      base: 200,
      cap: :timer.seconds(2),
      max_attempts: 3,
      expiry: :timer.seconds(10),
      jitter: true
    ]
end
