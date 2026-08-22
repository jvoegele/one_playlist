# OnePlaylist

Move playlists between music services — and be honest about what happened.

A playlist transfer tool has one failure mode worse than crashing: **finishing,
reporting success, and being wrong.** A track silently dropped, a cover version
matched instead of the original, a playlist transferred out of order. None of
those raise, none fail a type check, and none look like anything in a log. The
user finds out weeks later, if ever.

That problem is why this project exists, and it shapes everything below.

> **Status: early.** Reading a TIDAL library works end to end against the live
> API — OAuth with PKCE, encrypted token storage, automatic refresh, playlists
> and tracks with ISRCs. There is no matching engine, no write path and no UI
> yet. 128 tests, 27 contracts.

---

## Why this repository exists

It is a real product being built for real use, and deliberately also a **worked
example** of four Elixir libraries used deeply rather than decoratively:

| Library | What it does here |
| --- | --- |
| [`bond`](https://hexdocs.pm/bond) | Design by Contract. 27 contracts stating laws that a plausible rewrite could break. |
| [`external_service`](https://hexdocs.pm/external_service) | Every outbound provider call: retries, circuit breaker, rate limit, bulkhead. |
| [`errata`](https://hexdocs.pm/errata) | Structured errors that classify themselves — HTTP status, severity, retryability. |
| [`wait_for_it`](https://hexdocs.pm/wait_for_it) | Waiting on asynchronous work without `Process.sleep/1`. |

The backend is [Supabase](https://supabase.com) — Postgres with RLS, Auth,
Storage, Realtime, Queues and pgvector — used as natively as the workload allows.

---

## Where the libraries earn their keep

### Bond — contracts for the bugs that do not raise

Every contract here is named for a bug it catches, and the load-bearing ones are
**mutation-verified**: the implementation is broken deliberately, the contract
confirmed to fire, the change reverted.

PKCE is the clearest example. Its entire security value rests on one
relationship — what travels to the provider must be the *hash* of the secret we
keep, never the secret itself. Send the verifier instead and the flow still
completes, the exchange still succeeds, and every test still passes:

```elixir
@post whenever(
        {:ok, authorization} <- result,
        challenge_is_hashed:
          challenge_in(authorization.url) ==
            Base.url_encode64(:crypto.hash(:sha256, authorization.code_verifier), padding: false),
        verifier_never_sent: challenge_in(authorization.url) != authorization.code_verifier
      )
def authorization_url(opts \\ [])
```

Others in the same spirit: a mapper that cannot invent a track, a refresh that
cannot lose its refresh token, a scheduler's SQL query cross-checked against the
Elixir predicate it duplicates, and a skew bound that catches milliseconds passed
where seconds were meant.

One real bug found this way: ISO 8601 admits negative components, so `"PT-5S"`
parsed to `-5`. A negative duration is not a shorter track — it is a value that
scores as a near miss against real durations. The property test had passed over
it for days, because it only asserted `is_integer(result)`.

**[`docs/reference/contracts.md`](docs/reference/contracts.md)** is the house
style, and the most transferable thing in this repository: what to assert, what
not to, and how to tell a contract that works from one that only looks like it.

### ExternalService — one guarded front door per provider

```elixir
use ExternalService,
  rate_limit: [limit: 8, per: :timer.seconds(1)],
  circuit_breaker: [tolerate: 5, within: :timer.seconds(30), reset: :timer.seconds(30)],
  concurrency: [limit: 10, reclaim_after: :timer.seconds(30)],
  retry: [backoff: :exponential, base: 200, cap: :timer.seconds(5),
          max_attempts: 4, expiry: :timer.seconds(20), jitter: true]
```

Every number has a reason recorded next to it. TIDAL publishes no rate limit, so
8/second is deliberately conservative; `within` must exceed the retry window or
the breaker never trips; `reclaim_after` must exceed the client timeout or a slow
call has its slot stolen.

A trap worth knowing if you combine this with Req: **Req retries by default**.
Nested inside a guarded call that means twelve requests where four were
configured — and invisibly, because the retrying happens below the library, so
no telemetry fires and the breaker never sees it.

### Errata — errors that answer questions at the boundary

Error types classify themselves, so a boundary can be written once:

```elixir
def retryable?(%{reason: :invalid_grant}), do: false
def retryable?(_error), do: true
```

That one line is load-bearing. A dead grant must not be retried, while a provider
outage must be — and getting it backwards means either wedging an integration or
demanding that every user reconnect after a ten-minute blip.

### WaitForIt

Used for `WaitForIt.Test` assertions and for polling asynchronous provider work.
The heaviest use is still ahead, in the transfer pipeline.

---

## What the platforms allow

The APIs, not the code, are what make this hard. Full detail in
[`docs/reference/domain.md`](docs/reference/domain.md):

- **Spotify** — new apps are capped at **5 allowlisted users**; extended quota
  needs an organisation with ≥ 250,000 MAU. Not a public feature.
- **YouTube Music** — 10,000 quota units/day, and `playlistItems.insert` costs
  50, so roughly **200 track adds per day in total**.
- **Apple Music** — the user token can only be obtained client-side.
- **Deezer** — no longer issues API tokens.
- **TIDAL and self-hosted** (Plex, Jellyfin, Navidrome, Subsonic) are open and
  unlimited. That is why TIDAL came first.

---

## Getting started

Requires Elixir 1.20 / OTP 29 (pinned in `.tool-versions`), Docker, and the
[Supabase CLI](https://supabase.com/docs/guides/local-development).

```sh
supabase start                                  # Postgres on :54322, Studio on :54323
mix deps.get && mix ecto.migrate
cp config/dev_local.example.exs config/dev_local.exs   # then add TIDAL credentials
mix phx.server
```

The sibling libraries are path dependencies, so a checkout expects
`bond`, `errata`, `external_service` and `wait_for_it` alongside this directory.

```sh
mix precommit        # compile, format, credo, sobelow, deps.audit, dialyzer, test
mix ci               # the same, plus docs and coverage, without rewriting files
```

Contract coverage prints after every test run. An assertion marked
`⚠ never failed` is a prompt, not a pass.

---

## Documentation

| | |
| --- | --- |
| [`CLAUDE.md`](CLAUDE.md) | Goals, constraints, and working agreements |
| [`docs/reference/contracts.md`](docs/reference/contracts.md) | House style for writing contracts |
| [`docs/reference/jv-libraries.md`](docs/reference/jv-libraries.md) | Deep reference for the four libraries |
| [`docs/reference/supabase.md`](docs/reference/supabase.md) | Supabase for Elixir/Phoenix |
| [`docs/reference/domain.md`](docs/reference/domain.md) | Competitors, track matching, API limits |
| [`docs/library-feedback.md`](docs/library-feedback.md) | Friction found while using the libraries |

That last one is deliberate. Dogfooding is only worth something if the friction
gets written down, including the times the mistake was mine.

## License

**AGPL-3.0** for the application ([`LICENSE`](LICENSE)), **Apache-2.0** for the
documentation ([`docs/LICENSE`](docs/LICENSE)).

The split is deliberate. AGPL §13 is the reason it is not the plain GPL: running
a modified version as a network service counts as conveying it, so anyone
offering a modified OnePlaylist over a network must offer its users the source.
The GPL would not require that, because serving software over a network is not
distribution — which is the whole loophole a hosted competitor would use.

But `docs/` exists to be copied. The contract patterns, the guarded-call
configuration and the reference material are written to be lifted into other
projects, including proprietary ones, and AGPL-ing them would defeat the point
of writing them. See [`NOTICE`](NOTICE).
