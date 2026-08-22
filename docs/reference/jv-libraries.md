# Reference: Jason Voegele's Elixir Libraries

Deep reference for the four first-party libraries this project dogfoods. Compiled from
reading each library's source, `CLAUDE.md`, and full `guides/` set in
`/Users/jvoegele/projects/{external_service,errata,bond,wait_for_it}`.

**Always prefer reading the library's own `guides/` directory over trusting this summary** —
the guides are the authoritative, executed-in-CI documentation. This file exists so a session
starts with the shape of each library already in mind.

| Library | Local version | Purpose | Hard deps |
| --- | --- | --- | --- |
| `external_service` | **3.0.0-rc.4** | retries + circuit breaker + rate limit + concurrency limit for outbound calls | `fuse`, `errata`, `nimble_options`, `telemetry` |
| `errata` | **1.7.0** | structured, named, self-classifying error types | `telemetry` (jason optional) |
| `bond` | **1.14.1** | Design by Contract (`@pre`/`@post`/`@invariant`) | `telemetry` (stream_data optional) |
| `wait_for_it` | **2.4.0** | expressive waiting on async conditions | `telemetry` |

They are designed to compose: `external_service`'s own errors *are* Errata errors, and
`Errata.retryable?/1` can drive `external_service`'s retry predicates.

---

## 1. `external_service` — safe calls to external APIs

The single most important library for this project: every call to Spotify / Apple Music /
YouTube Music / Tidal / Deezer goes through it.

### The front door

```elixir
defmodule OnePlaylist.Providers.Spotify.Service do
  use ExternalService,
    circuit_breaker: [tolerate: 15, within: :timer.seconds(5), reset: :timer.seconds(5)],
    rate_limit: [limit: 100, per: :timer.seconds(1), wait: :timer.seconds(1)],
    concurrency: [limit: 25, reclaim_after: :timer.seconds(30)],
    retry: [backoff: :exponential, base: 100, cap: :timer.seconds(2),
            max_attempts: 5, expiry: :timer.seconds(10), jitter: true]

  def fetch(id) do
    call fn ->
      case Req.get(url(id), receive_timeout: :timer.seconds(5)) do
        {:ok, %{status: s} = r} when s < 500 -> {:ok, r}
        _ -> :retry
      end
    end
  end
end
```

Start it under a supervisor — `use ExternalService` generates `child_spec/1`:

```elixir
children = [OnePlaylist.Providers.Spotify.Service]
```

`:name` defaults to the module name and **is fixed at compile time** (it is consumed by the
`use` macro and is *not* a `start/2` option — passing it in a child spec override fails
validation).

Generated functions: `call/1,2`, `call!/1,2`, `call_async/1,2`, `call_async_stream/2,3,4`,
`available?/0`, `blown?/0`, `reset/0`, `reset_all/0`, `child_spec/1`, `start_link/1`.

Child-spec overrides are **deep merged** with the `use` options — the idiomatic
per-environment tuning knob.

### The retry protocol (the key rule)

Inside the wrapped zero-arity function:

| Return | Effect |
| --- | --- |
| `:retry` | retry; reason recorded as `:reason_unknown` |
| `{:retry, reason}` | retry, reason recorded (if `reason` is an exception it becomes the `:cause`) |
| value matched by `:retry_on` predicate | retry, whole result recorded as reason |
| anything else (incl. your `{:error, _}`) | **success**, returned as-is |
| raised exception | propagates untouched **unless** matched by `:retry_exceptions` |

### Retry options

`:backoff` (`:exponential` default / `:linear`), `:base` (10ms default), `:factor`, `:cap`,
`:expiry`, `:max_attempts` (**5** default, or `:infinity`), `:jitter` (`true` = ±10%, or a
float), `:retry_on` (predicate on result), `:retry_exceptions` (module list **or** predicate).

- Per-call **keyword list** → *merged* onto service defaults. Per-call **`%RetryOptions{}`
  struct** → *replaces* them wholesale.
- Default `max_attempts: 5` with `base: 10` is only **150 ms of total waiting**. For a real
  HTTP dependency raise `:base` (100 is the usual starting point), not the attempt count.
- **Nothing here bounds a single attempt.** `:expiry` is checked *between* attempts. Bounding
  one attempt is the caller's job — set `receive_timeout` **and** pool checkout timeout on Req.
- `max_attempts: :infinity` + default melt semantics is **rejected** in 3.0 (a call that never
  gives up never melts the breaker, so nothing would stop it).
- Predicates given to `use ExternalService` **must be remote captures**
  (`&OnePlaylist.Retry.transient?/1`), never anonymous fns — module attributes cannot hold a
  closure. `start/2` and per-call options accept either.
- A predicate that raises is treated as **no match**: nothing retried, breaker untouched, a
  warning naming the option and service is logged.

### Circuit breaker

`:tolerate` (10), `:within` (10_000 ms), `:reset` (60_000 ms), `:fault_injection` (0.0–1.0),
`:backend`, `:melt`.

- **3.0 semantics: `:tolerate` counts *calls*, not attempts.** A call melts the breaker once,
  when its retrying gives up. `:fuse` tolerates `:tolerate` melts and opens on the next, so
  `tolerate: 10` opens on the **11th** failing call. `circuit_breaker: [melt: :per_attempt]`
  restores pre-3.0 behaviour.
- A call that fails some attempts then **succeeds** melts nothing.
- `tolerate: :infinity` installs **no breaker at all** — holds no state. This is the correct
  setting for tests (state cannot leak between them). Cannot combine with `:fault_injection`.
- The breaker protects against a service that **fails**, not one that **hangs**. Without a
  client timeout, a slow-but-up dependency is invisible to it.
- Sized *against* the retry settings, not independently: `:within` must be wider than the
  retry window plus attempt duration, or melts never accumulate.
- `ExternalService.CircuitBreaker.melt/1` reports a failure the library never saw.
- Node-local by default; `ExternalService.CircuitBreaker.Cluster` propagates trips.

### Rate limiting (critical for music APIs)

`:limit` (required), `:per` (required, ms), `:wait`, `:backend`. Opt-in.

- Default limiter is a **token bucket**: burst to `:limit`, then paced at `per / limit`.
- Throttled calls **sleep the calling process** (or the task, for async variants).
- `:wait` default = **one window (`:per`), capped at 5 s**. Values: unset / `:infinity` /
  milliseconds / `false`.
  - Background jobs & Flow pipelines → `wait: :infinity` (sleeping *is* the back-pressure).
  - Request paths → a finite budget; over budget you get
    `{:error, %ExternalService.RateLimited{context: %{retry_after: ms}}}` (HTTP 429).
- The wait loop is **unfair** — no queue; a sleeping caller can lose to a newly arrived one
  repeatedly. Measured: one caller against 25 blocked for 1.7 s / 4.4 s / 5.2 s on three runs.
- `limit: :infinity` installs no limiter (the override-friendly "off" switch).
- `ExternalService.rate_limited?/1` (read, consumes nothing),
  `ExternalService.RateLimiter.peek/1` → `:ok | {:wait, ms}`,
  `ExternalService.RateLimiter.request/1` spends budget for a call made elsewhere.
- **Never** use `sleep_function: fn _ -> :ok end` for rate limits — it busy-waits. Measured at
  `limit: 1, per: 2_000`: still 2000 ms, no-op invoked 2,075,418 times.
- Cluster-wide: `backend: {ExternalService.RateLimiter.Hammer, module: MyApp.RateLimit}`.

### Concurrency limiting (bulkhead)

`:limit` (required), `:reclaim_after` (required, ms), `:wait` (default `false`, `:infinity`
**rejected**). Opt-in.

- Over the limit → `ExternalService.ServiceSaturated` (HTTP 503). **No cooldown** — a slot
  frees the moment a call finishes.
- Slot is taken **per attempt**, inside the rate limiter, so backoff and rate-limit sleeps
  hold nothing.
- `:reclaim_after` must exceed your client timeout; it exists because an external `:shutdown`
  exit does not run `after` blocks (i.e. every draining deploy).
- Size it to the **connection pool**, not to the remote service.
- `saturated?/1`, `Concurrency.in_flight/1`, `Concurrency.limit/1`.

### Errors (all are Errata infrastructure errors)

| Error | When | `http_status` | `retryable?` |
| --- | --- | --- | --- |
| `RetriesExhausted` | retry budget spent | 503 | **false** |
| `CircuitBreakerOpen` | breaker open | 503 | true |
| `ServiceNotStarted` | never `start/2`ed | 500 | false |
| `RateLimited` | past the `:wait` budget | 429 | true |
| `ServiceSaturated` | concurrency limit full | 503 | true |

Every error's `:context` carries `:service`. `RetriesExhausted` carries `:context.reason`, and
when that reason is an exception it is *also* set as the error's `:cause` (reachable via
`Errata.cause/1` / `root_cause/1` / `format_chain/1`).

`call/3` returns them in `{:error, struct}`; `call!/3` raises them. Your own function's
returns and raises pass through both untouched.

`RateLimited` (429, *their* refusal) vs `ServiceSaturated` (503, *our* bulkhead shedding) is a
deliberate distinction. Neither melts the breaker, neither is retried.

### Introspection & configuration tooling

```elixir
IO.puts ExternalService.explain(MyApp.Api)          # what will this config do?
ExternalService.simulate(MyApp.Api, :always_failing) # virtual clock, nothing sleeps
#=> %Simulation{opens_after: 4, worst_call: 1500, attempts: 20, ...}
ExternalService.simulate(MyApp.Api, {:slow, 5_000})  # slow ≠ failing
ExternalService.RetryOptions.window(base: 100, max_attempts: 5)  #=> 1500
ExternalService.Insights.attach()                    # runtime "config has gone inert" watchdog
```

`Insights` catches the one thing `explain`/`simulate` cannot: whether what is *happening*
matches the configuration. Attempt duration is not stated anywhere in a config, so a breaker
sized correctly on day one goes quietly inert when the dependency slows down.

### Telemetry

```
[:external_service, :call, :start | :stop | :exception | :retry]
[:external_service, :circuit_breaker, :blown]
[:external_service, :rate_limit, :sleep]
[:external_service, :concurrency, :rejected | :waited]
```

All carry `:service` metadata. The `:call` events form a `:telemetry.span/3`. Event names are
a stable public contract.

### Async / bulk

- `call_async/1` → `Task` (linked; an escaping exception crashes it).
- `call_async_stream/2` → `Stream`, **preserves input order**, bounded concurrency. This is
  the right tool for "transfer 500 tracks".
- `ExternalService.Flow.map/3,4,5` (optional `:flow` dep) — only when the guarded call is a
  stage of a larger pipeline; **unordered**. Needs `rate_limit: [wait: :infinity]`.
- `ExternalService.Decorator` (optional `:decorator` dep) — `@decorate external_call(Svc)`.

For bulk work prefer returning `{:error, reason}` / `{:retry, reason}` over letting exceptions
escape, so one bad element can't crash the batch.

### Testing

- **Service state is global** (`:persistent_term` + `:fuse`), keyed on the service term.
  Nothing is torn down for you; `async: true` tests sharing a service share one breaker and
  one bucket.
- Make a service **inert** in `test.exs` via child-spec override:
  `circuit_breaker: [tolerate: :infinity], rate_limit: [limit: :infinity], retry: [max_attempts: 1]`.
- Isolate with a per-test service term + `on_exit(fn -> ExternalService.stop(service) end)`
  (functional API only — the front door can't vary `:name`).
- Otherwise `MyApp.Api.reset_all()` in `setup` (`reset/0` clears only the breaker, deliberately
  leaving the limiter alone) and `async: false`.
- Off the clock: retries → `base: 0`; rate limits → `wait: false`; assert on backoff delays with
  a recording `:sleep_function` (legitimate *only* for retry backoff).
- Assert a retry happened via the `[:external_service, :call, :retry]` telemetry event with a
  test-unique handler ID.
- `ExternalService.simulate/3` asserts the *configuration* behaves, on a virtual clock.

---

## 2. `errata` — structured, named, self-classifying errors

### Defining types

```elixir
defmodule OnePlaylist.Transfers.TrackNotMatched do
  use Errata.DomainError,
    default_message: "no matching track was found on the destination service",
    reasons: [:no_isrc_match, :no_fuzzy_match, :ambiguous],
    http_status: 422,
    code: "TRACK_NOT_MATCHED"
end

defmodule OnePlaylist.Providers.UpstreamUnavailable do
  use Errata.InfrastructureError, default_message: "the music service is unavailable"
end
```

Three entry points: `Errata.DomainError` (kind `:domain`), `Errata.InfrastructureError`
(`:infrastructure`), `Errata.Error` (`:general`).

`use` options: `:kind`, `:default_reason`, `:default_message`, `:reasons`, `:http_status`,
`:code`, `:severity`, `:retryable`, `:redact`, `:aggregate`.

Struct fields: `message`, `reason`, `context`, `cause`, `env`, `kind`, `__errata_error__`
(+ `errors` on aggregates). Every type is an `Exception`, implements `String.Chars`, and gets
`JSON.Encoder` (1.18+) and/or `Jason.Encoder`.

### Kind defaults

| kind | `http_status/1` | `retryable?/1` |
| --- | --- | --- |
| `:domain` | 422 | false |
| `:infrastructure` | 503 | true |
| `:general` | 500 | false |

`severity/1` defaults to `:error` for all kinds; `code/1` has no default.

Choosing a kind — ask **who acts on it**: the caller (`:domain`), an operator or a retry
(`:infrastructure`), neither (`:general`). A third-party API failing is `:infrastructure`.

### Creating errors

```elixir
defmodule OnePlaylist.Transfers do
  use Errata   # imports the guards; implies `require Errata`

  def match(track) do
    {:error, Errata.create(TrackNotMatched, reason: :no_isrc_match, context: %{isrc: track.isrc})}
  end
end
```

- **`Errata.create/2` is the default.** A macro — captures `__ENV__` + stacktrace into `:env`.
  One `use Errata` per calling module covers every error type (no per-type `require`).
- `MyError.create/1` — same, but needs `require MyError`.
- `MyError.new/1` — plain function, `env: nil`. For `apply/3`, `&MyError.new/1` captures, and
  tests where comparable structs matter.
- The macros cannot be replaced by stacktrace inspection: TCO drops the caller's frame.

### Guards

`Errata.is_error/1`, `is_domain_error/1`, `is_infrastructure_error/1`. Structural (they check
the `__errata_error__` marker) — no central registry. Usable in `case`/`with`/function heads;
**not** in `rescue` clauses (Elixir forbids `when` there) — rescue into a variable and dispatch
with `cond`.

Inside a bare `rescue e ->`, use accessors (`Errata.reason(e)`) not field access (`e.reason`
warns: the variable has no narrowable type). After a structural guard, field access is fine.

### Accessors (all raise `ArgumentError` on non-Errata values)

`to_map/1`, `display_message/1`, `reason/1`, `context/1`, `kind/1`, `code/1`, `severity/1`,
`http_status/1`, `retryable?/1`, `cause/1`, `root_cause/1`, `format_chain/1`, `errors/1`,
`aggregate?/1`, `put_context/3`, `merge_context/2`, `log/2`, `report/2`, `to_error/2`,
`from_map/3`, `from_map!/3`, `wrap/3`.

### Overridable generated functions

`http_status/1`, `code/1`, `severity/1`, `retryable?/1`, `display_message/1`,
`redact_context/1`. Deliberately **not** behaviour callbacks (so overriding doesn't trip
`@impl` warnings). All accessors dispatch through them.

Two distinct message renderings:
- **Developer message** — `Exception.message/1`, `to_string/1`, `raise`, `Errata.log/2`.
  Combines `:message` and `:reason`. Override `message/1`.
- **Display message** — `Errata.display_message/1`, `to_map/1`, JSON. Human text only.
  Override `display_message/1` (e.g. to compute from `:context`).

### Wrapping vs normalizing

| | `Errata.wrap/3` | `Errata.to_error/2` |
| --- | --- | --- |
| do you know what it means? | yes — you name the type | no — it is whatever arrived |
| where | where the failure is caught | where the error leaves the system |
| given an Errata error | adds a layer | returns it **unchanged** |
| form | macro; records call site | function; capturable; no `:env` |

Reaching for `wrap/3` at a boundary is a bug: it turns a 404 into a 500 and replaces the
user-facing message.

Pattern: an application-level `MyApp.Errors.to_error/1` with clauses for the types you
recognize (changesets → 422, HTTP timeouts → retryable 503), falling through to
`Errata.to_error/1`. Then the Phoenix fallback controller is one clause.

`Errata.http_status(:timeout)` raising is *desirable* inside domain code — it means an error
escaped unclassified. Normalize at the boundary, not before it.

### Enriching, aggregating

- `Errata.put_context/3` / `merge_context/2` — enrich as an error propagates up a `with` chain.
- `use Errata.DomainError, aggregate: true` → gains an `errors` field. Merge rules:
  `severity/1` = most severe member; `retryable?/1` = **only if every member is**;
  `http_status/1` = members' status if they agree, else the aggregate's own. Members must be
  Errata errors.

### Boundary & wire

- `:code` — stable external identifier. **Match on `code`, not `error_type`** (a module name
  moves when you move the module). No default; opt in.
- `Errata.to_map/1` / JSON carries `kind`, `http_status`, `severity`, `retryable` computed
  through the overridable functions — a non-Elixir consumer can branch on plain JSON.
- `Errata.from_map/3` rebuilds on the far side (type passed as an argument, never resolved
  from the wire). Classification is **recomputed locally**; `:env` is always `nil`; aggregates
  are refused; context keys come back as strings unless `keys: :existing_atoms`.
  Declaring `:reasons` is what keeps reason decoding off `String.to_existing_atom/1`.

### Observability & redaction

- `Errata.log/2` — logs the developer message with `reason`/`kind`/`code`/`severity`/
  `retryable`/`http_status`/`context`/`env` as **Logger metadata** (queryable, not flattened).
- `Errata.report/2` — emits `[:errata, :error]` telemetry; metadata carries the `:error` struct
  plus flat `:kind`, `:reason`, `:error_type`, `:code`, `:severity`, `:retryable`,
  `:http_status`, `:context`. This is the Sentry seam — Errata ships no vendor integration.
- `:redact` — recursive, matches atom **and** binary keys, applies at the **serialization
  seam** (the struct in hand keeps real values). Global floor:
  `config :errata, redact: [:password, :token, :secret, :authorization, :api_key]`.
  **This project must redact provider OAuth tokens.**

### Errata + `external_service`

```elixir
defmodule OnePlaylist.Retry do
  require Errata
  def retryable_error?(e), do: Errata.is_error(e) and Errata.retryable?(e)
  def retryable_result?({:error, e}), do: retryable_error?(e)
  def retryable_result?(_), do: false
end

use ExternalService,
  retry: [retry_on: &OnePlaylist.Retry.retryable_result?/1,
          retry_exceptions: &OnePlaylist.Retry.retryable_error?/1]
```

**Retryability is not idempotency.** `retryable?/1` says "could another attempt succeed?", not
"is it safe to call twice?" Wire these per service or per call — a `POST /playlists/{id}/tracks`
retry can duplicate tracks.

Note: a `:retry_on`-driven retry records the *whole return value* as the reason, so no `:cause`
is set. Where you control the function, return `{:retry, error}` to get the chain.

---

## 3. `bond` — Design by Contract

`use Bond` is compile-time machinery. It starts no processes and adds nothing to the
supervision tree.

### The forms

```elixir
@pre positive: amount > 0                     # caller's obligation
@post conserved: result.a + result.b == a + b # the function's promise; `result` is bound
@invariant total_matches: subject.total == Enum.sum(...)  # struct property, both boundaries
check total_is_integer: is_integer(raw)       # mid-body assertion
```

Labels appear in the failure message and can be targeted from tests. Bare and labelled forms
cannot be mixed in one annotation. Multiple annotations on one function are conjoined.

`old(expr)` snapshots a value before the body runs — `@post` only, and only meaningful for
state that actually changes.

### Assertion vocabulary (`Bond.Predicates`, auto-imported)

| Operator | Meaning |
| --- | --- |
| `p ~> q` | implication ("if p then q") — also `implies?(p, q)` |
| `p ||| q` | **exclusive** or — also `xor(p, q)`; **prefer the named form** |
| `pattern <~ expr` | `match?(pattern, expr)` |
| `forall(x <- xs, pred)` / `exists(...)` | quantifiers; report the failing element |

`forall`'s generator pattern **binds and asserts shape — it does not filter.** A non-matching
element *fails* the assertion. To filter comprehension-style, gate with `~>`.

Destructuring bindings: `where(pattern = expr, ...)` (non-match = violation) vs
`whenever(pattern <- expr, ...)` (non-match = vacuously true — one clause per result shape,
no `or {:error, _}` boilerplate).

### Beyond one call

- `use Bond.Behaviour` — contracts on `@callback`s, enforced in every implementing module
  (`use Bond, behaviours: [Ledger]`). Violations are attributed to the declaring behaviour.
- `use Bond.Protocol` — enforced at the dispatch boundary across every `defimpl`.
- `defcontract name(args) do ... end` + `@apply_contract {Module, :name}` — reusable named
  contracts, keyed `{name, arity}`, composable with `include`.
- Refinement (behavioural subtyping): `@pre_weaken` (inherited **or** weakened),
  `@post_strengthen` (inherited **and** strengthened). A plain `@pre`/`@post` on an inherited
  operation is rejected.
- `use Bond.Server` (after `use GenServer`) — `@state_invariant` (binds `state`) and
  `@transition_invariant` (binds `old_state`, `new_state`).

### Configuration — the whole point

Four kinds: `:preconditions`, `:postconditions`, `:invariants`, `:checks`. Each is
`true | false | :purge` (default `true`).

| Mode | Compiled? | Runtime |
| --- | --- | --- |
| `true` | yes | evaluated unless disabled via `Bond.Config` |
| `false` | yes | skipped unless enabled — **toggleable from a remote console mid-incident** |
| `:purge` | **no** | nothing exists to run |

Chain: `preconditions ≤ postconditions ≤ invariants`. A `:purge`d kind requires every kind
*above* it purged too (compile error otherwise). `:checks` sits outside the chain.

Precedence: `use Bond` opts → exact-module `:overrides` → regex `:overrides` → global config.

Recommended production posture for this project: **preconditions on, everything else purged**
— cheapest kind, and the only one that names a *caller's* bug.

`Bond.Config.disable/1`, `enable/1`, `all/0`, `reset/0` (global, `:persistent_term`-backed).
Note `Application.put_env/3` is **not** live after the first contracted call.

### Writing sound assertions

- **Assertions must be total.** A partial predicate (`String.contains?(email, "@")` on `nil`)
  raises `Bond.AssertionEvaluationError` — which is neither "holds" nor "fails". Lead with a
  type check. This is the *one* case where turning contracts on changes behaviour a purged
  build wouldn't have.
- A `@post` that restates the body can only fail if the runtime is broken. State the **law**
  the body must obey (money conserved), not a second copy of the body.
- A `@pre` the `when` guard already enforces is unreachable — guards run first. For *types*,
  reach for `@spec` (Dialyzer checks it, ExDoc renders it, costs nothing). Reserve `@pre` for
  what types cannot say: relations between arguments, domain rules.
- `|||` is XOR, not OR. Use `or` for disjunction.
- Prove every non-trivial assertion **can fail** with a `Bond.Test` assertion.
- A compile-time **linter** (`config :bond, lint_assertions: true`) catches provably-constant
  assertions, self-comparisons, and vacuous quantifiers. It cannot catch type-disjoint
  comparisons or guard-shadowed preconditions.

### Errors and telemetry

`Bond.PreconditionError`, `PostconditionError`, `InvariantError`, `CheckError`,
`AssertionEvaluationError` (the assertion *expression* raised — carries `:exception`).
Fields (`:label`, `:kind`, `:expression`, `:file`, `:line`, `:module`, `:function`,
`:binding`, `:source_behaviour`, …) are public and stable; the rendered message text is not.

One telemetry event: `[:bond, :assertion, :failure]`. Failures only, emitted **before** the
raise, with a stable `:assertion_id` for aggregation.

### Testing

- `use Bond.Test` → `assert_precondition_violation/2`, `assert_postcondition_violation/2`,
  `assert_check_violation/2`, `assert_invariant_violation/2` (with `label:` / `kind:`).
- `use Bond.PropertyTest` (needs optional `:stream_data`):
  - `contract_holds &f/1, args: [gen]` — you generate only **valid** input; a `@pre` violation
    is a test failure. The contracts are the oracle — no model to write.
  - `probe_contract &f/2, args: [...]` — reads literal comparisons out of the `@pre`, aims
    generators at those boundaries, and *filters* on the precondition.
  - `invariants_hold Mod, constructors:/transformers:/observers:` — random operation sequences.
  - `server_invariants_hold Mod, init:, messages: [call:, cast:, info:]`.
- `config :bond, coverage: true` + `Bond.Coverage.install_reporter()` — surfaces assertions
  that ran but were never observed to fail.

---

## 4. `wait_for_it` — expressive waiting

`require WaitForIt` or `import WaitForIt`.

### The five macro forms + the functional one

| Form | Waits until… |
| --- | --- |
| `wait/2` | an expression is truthy |
| `match_wait/3` | an expression matches a pattern (binds out of it) |
| `case_wait/3` | an expression matches one of several clauses |
| `cond_wait/2` | one of several expressions is truthy |
| `with_wait/3` | several composed waits all succeed (`<~` clauses inside `on(...)`) |
| `until/2` | *functional* counterpart of `wait/2`; returns `{:ok, v} \| {:timeout, last}` |

Each has a `!` variant raising `WaitForIt.TimeoutError`.

### The one timeout rule

> On timeout, each form behaves exactly as its built-in Elixir counterpart would on a final
> evaluation in which nothing matched.

So `case_wait` raises `CaseClauseError`, `match_wait` raises `MatchError`, `cond_wait` raises
`CondClauseError`, `with_wait` returns the last unmatched value. Two additions: an optional
`else` clause (turns timeout into a value) and the `!` variants (uniform `TimeoutError`).

### Options (all forms)

| Option | Default | Meaning |
| --- | --- | --- |
| `:timeout` | 5_000 | total ms, or `:infinity` |
| `:interval` | 100 | polling ms; alias `:frequency`; **may be a 1-arity backoff fn** |
| `:pre_wait` | 0 | delay before first evaluation |
| `:signal` | — | disable polling; re-evaluate only on `WaitForIt.signal/1` |

`WaitForIt.Backoff.exponential(start: 50, max: 2_000, factor: 2, jitter: 0.1)` and
`Backoff.constant/1` build interval functions. The timeout still bounds the total wait.

**Never use catch-all clauses** in `case_wait`/`cond_wait` — they match on the first
evaluation and end the wait. Use `else`.

Waitable expressions are re-evaluated an indeterminate number of times; side effects must be
safe to repeat.

### Signal-based waiting

```elixir
# consumer
WaitForIt.wait(Buffer.count() >= 4, signal: :buffer_filled)
# producer
Buffer.put(item); WaitForIt.signal(:buffer_filled)
```

A signal means "re-evaluate", not "the condition now holds".

### `with_wait`

```elixir
WaitForIt.with_wait on(
  {:ok, account} <~ {load_account(token), timeout: 2_000},
  {:ok, balance} <~ fetch_balance(account)
), interval: 50 do
  {:ok, balance}
else
  not_ready -> {:error, {:timed_out, not_ready}}
end
```

`<-` = ordinary one-shot `with` clause. `<~` = wait-for-match. A `<~` timeout flows to `else`
exactly like a non-match. `<~` binds tighter than `when` and comparisons — parenthesize
guards and comparison RHSs. Per-clause options override global ones.

### In tests

```elixir
use WaitForIt.Test

assert_eventually {:ok, %User{confirmed: true}} = Repo.fetch(User, id)
refute_eventually error_reported?()
assert_always circuit_closed?(), timeout: 500
```

Fail with a normal `ExUnit.AssertionError` including the source expression and last value
seen. Defaults: `assert_eventually` 1 s; `refute_eventually` / `assert_always` sample 100 ms.

### Telemetry

`[:wait_for_it, :wait, :start | :stop | :exception]`. `:stop` reports `duration`,
`evaluations`, and whether the wait `:matched` or hit a `:timeout`. `with_wait` clauses carry
`wait_context: %{construct: :with_wait, clause: index}` — that is how you find the slow step.
