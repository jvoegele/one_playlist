# Feedback for the first-party libraries

A running log of friction found while dogfooding `external_service`, `errata`, `bond`, and
`wait_for_it` in a real application. Goal 1 in `CLAUDE.md` says this feedback is a deliverable
of the project, not a distraction from it — so findings get written down here as they surface,
whether or not they are acted on.

Format: what was hit, why it mattered, and a suggested fix.

---

## `external_service` — no `:export` block in `.formatter.exs`

**Found:** 2026-08-22, while configuring this project's formatter.

`external_service`'s README and every guide document the API paren-free:

```elixir
def charge(params) do
  call fn ->
    ...
  end
end
```

But `external_service/.formatter.exs` has an **empty** `locals_without_parens` and no
`:export` block, so a downstream project that adds `:external_service` to `import_deps` gets
nothing, and `mix format` rewrites the documented idiom to `call(fn -> ... end)`.

We worked around it by declaring the rules locally in this project's `.formatter.exs`.

**Suggested fix** — mirror what `bond` and `wait_for_it` already do:

```elixir
locals_without_parens = [call: 1, call: 2, call!: 1, call!: 2]

[
  # ...
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
```

Worth checking whether `call_async`/`call_async_stream` want the same treatment. Note the
library's own `.formatter.exs` also carries a commented-out `line_length: 100` — presumably
intended to be enabled, since `wait_for_it` sets exactly that.

## `external_service` — Req retries by default, silently multiplying every guarded call

**Found:** 2026-08-22, building the TIDAL adapter. Not a bug in `external_service`, but a trap
worth a paragraph in its guides.

`Req` — the HTTP client Phoenix now ships by default, and which `external_service`'s own
`circuit-breakers` guide uses in its examples — defaults to `retry: :safe_transient`, retrying
408/429/5xx and transport errors **three times with its own exponential backoff**.

Wrapped in `ExternalService.call/3`, that nests: each of the four configured attempts becomes
four requests. Observed here as **12 requests where 4 were configured**, and a test suite that
took **103 seconds instead of 0.06**, because Req slept on its own backoff (`will retry in
980ms`, `will retry in 1841ms`) inside a service configured with `base: 0` for tests.

Worse than the count is that the retrying is invisible to the library: it happens below
`call/1`, so `[:external_service, :call, :retry]` never fires for it, the circuit breaker never
sees the failures, and `ExternalService.simulate/3` models a call profile the application does
not actually have. Every tuning tool in the library is quietly wrong.

The fix is one option — `retry: false` in the Req request — but it has to be *known about*.

**Suggested fix:** a note in `guides/circuit-breakers.md` beside the existing Req/Finch/Tesla
timeout examples, which already say "your HTTP client already has the timeout that matters".
The same paragraph could say that your HTTP client may also have retries that do not matter,
and should be turned off:

```elixir
# Req retries 408/429/5xx by default; ExternalService owns retrying.
Req.get(url, retry: false, receive_timeout: :timer.seconds(5))
```

Tesla's `Tesla.Middleware.Retry` and Finch's own behaviour deserve the same one-liner. This is
cheap to document and expensive to discover.

## `bond` — `Bond.Coverage`'s ETS table dies with the first test that writes to it

**Found:** 2026-08-22, wiring up contract coverage. **This one is a bug**, and it silently
disables the feature.

`Bond.Coverage` reports `no contracts were evaluated` at the end of every suite, even when
contracts demonstrably ran — a test asserting a precondition violation passes, so the check
fired, yet nothing is recorded.

The cause is in `ensure_table/0` (`lib/bond/coverage.ex:186`):

```elixir
:ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])
```

The table is created **lazily, by whichever process first evaluates a contract**. Under ExUnit
that is a test process, and an ETS table dies with its owner — so the table and every recorded
evaluation are destroyed when that test finishes, long before the `after_suite` reporter runs.
It only appears to work if you read `entries/0` from inside the same test that created it,
which is exactly what a quick manual check does.

Neither `entries/0` nor `reset/0` calls `ensure_table/0`, so there is no public way to create it
early. Our workaround pre-creates the table in `test/test_helper.exs`, where the owning process
lives for the whole run; Bond's `ensure_table/0` then finds and reuses it. That means reaching
for the private table name `:bond_coverage`, which is exactly as fragile as it sounds.

**Suggested fix:** have `install_reporter/0` call `ensure_table/0`. It is documented as the
thing you call from `test_helper.exs`, so the table would be owned by a process that outlives
the suite, and the one-line change needs no API addition. A `heir` would also work but is more
machinery than this needs.

Once fixed, delete the workaround block in `test/test_helper.exs`.

**Worth saying:** once it reports, the report is excellent, and it immediately paid for itself.
It flagged three assertions as `⚠ never failed`; two were `@post total: is_boolean(result)`,
which restate a `@spec` that Dialyzer already checks — precisely the vacuous contract the
`writing-sound-assertions` guide warns about. They are now deleted. The third was a real
assertion that simply lacked a test proving it could fire, so it got one.

## `errata` — generated specs trip Dialyzer's `:extra_return` flag

**Found:** 2026-08-22, configuring Dialyzer.

With `flags: [:extra_return]`, every Errata error module produces `extra_range` warnings:

```
OnePlaylist.Providers.ConnectionNotFound.code/1
  Extra type:      nil
  Success typing:  <<_::176>>

OnePlaylist.Providers.ConnectionUnusable.retryable?/1
  Extra type:      true
  Success typing:  false
```

The generated `code/1` is specced `String.t() | nil`, but a type declaring `code: "..."` only
ever returns that string; `retryable?/1` is specced `boolean()`, but a domain error that does
not override it only ever returns `false`.

**The generated specs are not wrong** — they state the behaviour's contract, not one
implementation of it, and narrowing them per type would make overriding awkward. But it does
mean `:extra_return` is effectively unusable in any application built on Errata: the warning
count grows with every error type defined, and an ignore list would have to grow with it. We
dropped the flag.

**Suggested fix:** probably none in the library. Worth a line in the Errata docs, though —
something under `observability.md` or the `Errata.Error` moduledoc noting that
`:extra_return` will flag generated accessors and is best left off. That is cheaper to read than
to rediscover.

## `bond` — `~>` and `implies?/2` differ in evaluation, and the docs say they are identical

**Found:** 2026-08-22, writing a precondition helper with a partial consequent.

`Bond.Predicates` documents the two forms as interchangeable — the cheatsheet says "Both
connectives have a named form that behaves identically: `implies?(p, q)` for `~>`". For total
operands they do. They differ in the one case an implication is most worth reaching for:

```elixir
# `~>` is a macro. Verified: returns true, right-hand side never evaluated.
false ~> raise("boom")

# `implies?/2` is a function, so both arguments are evaluated before the call.
implies?(false, raise("boom"))   # raises
```

That matters because the reason to write `p ~> q` is usually that `q` is only *meaningful*
when `p` holds — Bond's own `writing-sound-assertions` guide says exactly this: "`~>` is also
the safe choice when the consequent only makes sense once the antecedent holds — it
short-circuits instead of evaluating a consequent that would raise." So the guide has the
right advice for `~>`, and the cheatsheet's "behaves identically" quietly contradicts it for
`implies?/2`.

Concretely, this helper is safe as written and raises if `~>` is swapped for `implies?/2`:

```elixir
(is_struct(now, DateTime) and is_struct(connection.inserted_at, DateTime)) ~>
  (DateTime.compare(now, connection.inserted_at) != :lt)
```

The cheatsheet already distinguishes them structurally in a different section — "`~>`/`<~` are
macros; the rest are functions" — so the information is present, just not where the equivalence
is claimed.

**Suggested fix:** qualify "behaves identically" in the cheatsheet's operator table, e.g.
"identical for total operands; `~>` short-circuits, `implies?/2` does not". One clause, and it
turns a trap into a documented choice.

**Also worth noting:** `Bond.Predicates` can be imported into ordinary function bodies
(`import Bond.Predicates, only: [~>: 2]`), which is not obvious from the guides — they describe
the vocabulary as being for assertions. It reads well in a predicate written to serve a
contract. Worth a sentence, along with a caution to scope the import: `|||` is exclusive-or
despite reading as "or", and the guides already flag that as a trap.

## `bond` — the Precondition Availability check does not consider `@doc false`

**Found:** 2026-08-22, immediately after the above.

Bond enforces Meyer's Precondition Availability rule and the diagnostic is excellent — it
names the rule, cites OOSC §11.7, explains the reasoning, and lists three ways to suppress it:

```
warning: the precondition of public function `expired?/2` calls a private function
(`created_at_respected?/2`). A precondition is an obligation on the caller, so a caller
that cannot call `created_at_respected?/2` cannot check it before calling — and Bond
renders the assertion into the generated docs, where `created_at_respected?/2` does not
appear.
```

The gap is in the last clause of its own reasoning. The check tests *callability* — public
versus private — but a **public function marked `@doc false` passes it while still not
appearing in the generated docs**. The stated rationale is defeated exactly as described, and
nothing warns. We shipped that for one commit before noticing.

**Suggested fix:** extend the check to warn when a precondition calls a public function whose
`@doc` is `false`, with wording along the lines of "…is public but hidden from documentation,
so a caller reading the docs cannot discover it." The existing message needs almost no change,
since it already argues from documentation visibility.

## `bond` — a module that forgets `use Bond` fails in ways that never mention Bond

**Found:** 2026-08-22. **Nothing to fix in the contract machinery** — this is purely about
diagnosability, and it is worth reading the correction below before spending time on it.

I originally recorded this as "the multi-label `@post` form works under `Bond.Behaviour` but
not under `use Bond`". **That was wrong** — and so was the retraction, which tested only one of
the two macros and concluded the forms were consistent everywhere. See the entry below for the
real difference, which runs the other way.

My failing module simply had no `use Bond` in it — I had added `use Errata` and assumed the
annotations were live — so `@post` fell through to `Kernel.@` and I attributed a missing-`use`
error to a form difference.

The real, much smaller observation is that **none of the failure modes name Bond**, which is
what let me misdiagnose it. Without `use Bond`:

  * an assertion referencing parameters →
    `error: undefined variable "x"`
  * a multi-label assertion →
    `error: expected 0 or 1 argument for @post, got: 2` (from `Kernel.do_at/5`)
  * a parameter-free assertion → compiles, enforcing nothing, with only Elixir's generic
    `warning: module attribute @post was set but never used`

The third is the one that could bite quietly, though `--warnings-as-errors` catches it and most
real assertions reference parameters, so the exposure is small.

**Suggested fix, if it is ever worth the effort:** nothing in the compiler can easily intercept
`@pre`/`@post` in a module that never invoked Bond. A line in the getting-started guide — "if
`@pre`/`@post` produce `undefined variable` or `expected 0 or 1 argument`, check that the module
has `use Bond`" — would cost nothing and is where someone would look. A Credo check would also
fit, if Bond ever ships one.

## `bond` — `@invariant` cannot be used on an `Ecto.Schema` module

**Found:** 2026-08-22, putting the transfer ledger law on `OnePlaylist.Transfers.Transfer`.
**This one is a bug**, and it rules out invariants on the most common struct type in a Phoenix
application.

Adding a single `@invariant` to an Ecto schema fails to compile:

```
error: undefined variable "bond_arg_1"
  └─ lib/one_playlist/transfers/transfer.ex:1: OnePlaylist.Transfers.Transfer.__schema__/2
```

Three isolated modules, differing only in the two axes:

| Module | `@pre`/`@post` | `@invariant` |
| --- | --- | --- |
| `use Ecto.Schema` + `use Bond` | compiles | **CompileError** |
| plain `defstruct` + `use Bond` | compiles | compiles |

```elixir
# does not compile
defmodule EctoInv do
  use Ecto.Schema
  use Bond

  @invariant non_negative: subject.n >= 0

  schema "t" do
    field :n, :integer
  end

  def bump(%__MODULE__{} = s), do: %{s | n: s.n + 1}
end
```

The cause is that invariants are woven into **every** public function of the declaring module,
and `Ecto.Schema` generates several — `__schema__/1`, `__schema__/2`, `__changeset__/0`. The
multi-clause `__schema__/2` in particular has clause heads Bond's argument-renaming does not
survive, and the generated wrapper references a `bond_arg_1` that was never bound.

`use Bond, warn_skipped_invariants: false` does **not** help. It silences the warning about
those functions not mentioning the struct, but the weaving still happens, so the compile error
stands. That is worth knowing, because the warning text names that option as the fix and it
addresses only the symptom that is cosmetic.

Why this matters more than a niche incompatibility: the schema module is where a struct's laws
belong in a Phoenix application, and it is where Bond's own
[invariants guide](https://hexdocs.pm/bond/invariants.html) would send you — its `BoundedStack`
example is exactly this shape with `defstruct` instead of `schema`. Every domain type in this
project that is worth an invariant is an Ecto schema.

**Workaround used here:** state the law as `@post` on each function that produces a value —
`with_total/2`, `record_matched/2`, `record_unmatched/1` — via a shared public predicate
`balanced?/1`. That covers everything the module builds, but not values built elsewhere, which
is precisely what an invariant would have added.

**Suggested fix:** skip weaving into compiler-generated functions. `__schema__`, `__changeset__`
and friends are recognisable by name, and none of them can take or return the struct in a way an
invariant is about — the existing `warn_skipped_invariants` machinery already knows they do not
mention it, so the information needed to skip them is present. Failing that, making
`warn_skipped_invariants: false` actually *skip* rather than merely not warn would give users a
working escape hatch, and would match what the option's name suggests.

## `external_service` — the compile-time linter caught a real misconfiguration I was about to ship

**Found:** 2026-08-22, adding a second service for TIDAL's write endpoints. **Nothing to fix** —
this is the opposite of friction, and it is recorded because a feedback log that only contains
complaints gives its author a skewed picture of what is working.

Writes needed their own `ExternalService`: TIDAL rate-limits mutations far harder than reads, so
the limiter and the retry budget both had to change. I copied the circuit-breaker settings from
the read service, since they had been reasoned about carefully and looked provider-shaped rather
than call-shaped. They are not. The compiler said so:

```
warning: OnePlaylist.Providers.Tidal.WriteService has a circuit breaker window narrower than
the failures it has to count. Its retry window is 7.5s per call, and it takes 6 failing calls
to open the breaker, at one melt each — so the failures that would open it are spread over
about 37.5s, wider than the 30s that `within: 30000` counts over. A caller making these calls
one after another never opens it; concurrent callers still can, so this is a question of your
traffic rather than a certainty.

    circuit_breaker: [within: :timer.seconds(75)]

Or leave `:within` unset, which sizes it from the retry options.
```

Four things that message does that most linters do not:

  * **It shows the arithmetic.** 7.5s per call × 6 calls = 37.5s > 30s. I could check the claim
    rather than take it on faith, which is what made it persuasive rather than annoying.
  * **It gives the number**, and the number was right.
  * **It offers the alternative** — omit `:within` and let it be derived — so the fix is not
    "tune this by hand until the warning stops".
  * **It is honest about the conditions.** "A caller making these calls one after another never
    opens it; concurrent callers still can" — it does not overstate. That mattered here, because
    a bulk transfer *is* a sequential caller, so the failure mode it describes was precisely
    mine.

The bug would have been invisible in production. Nothing raises; the breaker simply never trips,
and the first anyone learns of it is a wedged transfer retrying into a provider that has stopped
answering. It is exactly the class of defect this project uses contracts for, caught here at
compile time by the library itself.

**The transferable lesson, now in `docs/reference/domain.md`:** breaker settings are a property
of the *retry budget*, not of the provider. `within: 30s` is right next door, where the retry
window is ~1.5s, and wrong here, where it is 7.5s. Copying that line between two services for
the same provider is how you get a breaker that never trips.

**Suggested improvement, if any:** the warning fires at `defmodule`, so with several services in
a project the line number does not identify which `use ExternalService` option block to edit.
Pointing at the `use` call, or at the `:circuit_breaker` keyword itself, would save a moment.
Very minor against how much the check itself is worth.

### The same thing happened again with `:wait`, and `explain/1` caught it

Worth appending rather than filing separately, because it is the same mistake twice and the
pattern is the interesting part.

The write service was shedding calls in production-ish use — a real transfer failed with
`the call was throttled beyond the configured rate limit wait time`. The cause was the default
`:wait` budget, and the arithmetic is invisible unless you go looking: a limiter check never
quotes more than one emission interval (`per / limit`, **2000ms** at `limit: 1, per: 2s`), and
the default budget is one window, **also 2000ms**. One re-check exhausts it, so the shape sheds
on the slightest contention rather than pacing.

`guides/rate-limiting.md` answers this directly, and its framing is the part worth praising:

> Which value you want depends on **where the call is made**, not on the service.

Background work takes `:infinity` because sleeping *is* the back-pressure; a request path takes
a finite budget because a client that has given up is being served for nothing. Every caller of
the write service is an Oban job. The read service next door serves page loads. Same dependency,
opposite answers — and the first draft of the write service had copied the read one wholesale,
exactly as it had for `:within`.

Then `explain/1` found a **second** shedding path in the same configuration:

```
  rate limit
    limit        1 per 2s
    waits up to  as long as it takes

  concurrency
    limit           2 in flight
    waits up to     nothing — a throttled call returns RateLimited immediately
```

Fixing the limiter alone would have moved the shedding rather than removed it. That line is
doing a lot of work: it states the *consequence* ("returns RateLimited immediately") rather than
the setting, which is what made it legible at a glance.

The asymmetry between the two `:wait` options is also well judged and well documented —
`:infinity` is accepted for the limiter and refused by `start/2` for the bulkhead, because a
quota refills on its own while a slot frees only when another call finishes, so an unbounded
wait there *is* the unbounded pile-up. That is the kind of constraint a library should enforce
rather than document, and it does both.

**The transferable lesson**, now in the module's own docs: a configuration for one dependency is
not one thing. `:within` belongs to the retry budget, `:wait` belongs to the call site, and only
the rest belongs to the provider. Copying a whole option list between two services for the same
API looks like consistency and produced two bugs here.

## `bond` — `Bond.Server` invariants never appear in `Bond.Coverage`

**Found:** 2026-08-22, adding `server_invariants_hold/2` for
`OnePlaylist.Cache.Singleflight`.

`@state_invariant` and `@transition_invariant` are checked — proven by mutation, which fires
them with a correct label and expression — but they are **never recorded** in the coverage
table. Three ways of driving them, none of which produce a row:

| Driven by | Invariants run? | Appears in coverage? |
| --- | --- | --- |
| `server_invariants_hold/2` (`:callbacks` mode) | yes | no |
| A live `GenServer` under test | yes | no |
| A direct call to `handle_call/3` | yes | no |

The property file alone reports `Bond contract coverage: no contracts were evaluated.` Run
alongside a file whose `@pre`/`@post`/`@invariant` do appear, the other module's rows show and
the server's still do not, so this is not the ETS-ownership issue recorded above — the table
is alive and being written to, and these particular checks are absent from it.

Why it matters more than a cosmetic gap: `guides/testing-contracts.md` presents coverage as the
way to spot a vacuous assertion, and this project's house style makes `⚠ never failed` the
prompt to either prove a contract can fail or delete it. A whole contract kind missing from the
table means a vacuous **state** invariant is invisible to that process — and process invariants
are exactly where vacuity is hardest to notice by reading, because no caller can put the state
into a bad shape by hand.

It also interacts badly with a second property of supervised servers, which is worth stating in
the same breath: a violated invariant raises inside the server, the supervisor restarts it, and
callers absorb the error. Verified here — a mutation that reset the in-flight map fired
`at_most_one_key_per_message` **and the suite still reported all green**. So the two signals
that would normally catch a bad server invariant, a failing test and a coverage row, are both
absent at once.

**Suggested fix:** record `:state_invariant` and `:transition_invariant` through the same
coverage path as `@invariant`, keyed on the callback the check ran after (which the
`Bond.InvariantError` already carries in its `:function` field, so the information exists at
raise time). Failing that, a line in `testing-contracts.md` under "Contract coverage" saying
these kinds are not reported would at least stop someone concluding their server invariants
never ran.

## `bond` — inherited-contract coverage is aggregated under one arbitrary implementation

**Found:** 2026-08-22, adding a fourth implementation of `OnePlaylist.Matching.Strategy`.

`Bond.Coverage` reports a contract inherited from a `Bond.Behaviour` under a **single**
implementing module, and which one it picks depends on test ordering. The same two test files,
run with three different seeds:

```
--- run 1 ---            --- run 2 ---                     --- run 3 ---
  …Strategy.Isrc           …StrategyTest.Misnamed            …Strategy.Isrc
    score/2                  strategy/0                        strategy/0
    strategy/0             …StrategyTest.Overconfident       …StrategyTest.Overconfident
                             score/2                           score/2
```

Six modules implement that behaviour here. At most two ever appear, the counts are the totals
across all six, and no row belongs to the module it names.

Two consequences, the second worse than the first:

  * **Per-implementation coverage is invisible.** "Does the TIDAL adapter's inherited
    `usable` postcondition ever actually run?" is unanswerable from this table, and that is
    the question the table exists to answer. It matters most for exactly the case inherited
    contracts are for — many implementations, contract written once.
  * **A `✓` can be earned by a different module than the one it is printed against.** In run 1,
    `Strategy.Isrc / score/2` shows a failure that came from `StrategyTest.Overconfident`. Read
    literally, that says a correct rung violated its contract. The whole value of the coverage
    table is that `⚠ never failed` is trustworthy, and this makes the `✓` untrustworthy in the
    other direction.

**Suggested fix:** key coverage entries on the module the contract was *evaluated in* rather
than the one that registered the assertion. Failing that, printing the defining module
(`OnePlaylist.Matching.Strategy`) would at least be consistently true, and an aggregate row is
more useful than a misattributed one.

This is separate from the ETS-table issue recorded above, and survives it: the counts are
correct in total, only the attribution is wrong.

## `bond` — the all-inside `whenever`/`where` form is rejected on `Bond.Behaviour` callbacks

**Found:** 2026-08-22, declaring a contract on `OnePlaylist.Matching.Strategy.score/2`.

`guides/public-api.md` documents the all-inside form as an alias of the prefix form, and says
so specifically for inherited contracts:

> **All-inside form** — `where(pattern = source, <assertions>)` […] Also accepted in the `@`
> annotations as an alias of the prefix form.
>
> `@post` accepts both forms […] as do `@invariant`, the `Bond.Server` `@state_invariant` /
> `@transition_invariant`, and inherited contracts (`Bond.Behaviour` callbacks and
> `Bond.Protocol` functions).

It is not accepted on `Bond.Behaviour` callbacks. Four isolated modules, differing only in the
macro and the form:

| Form | `use Bond` | `use Bond.Behaviour` |
| --- | --- | --- |
| `@post whenever(pat <- result), ok: …` (prefix) | compiles | compiles |
| `@post whenever(pat <- result, ok: …)` (all-inside) | compiles | **CompileError** |

```
Bond: `whenever` may only appear at the start of a contract, not inside a larger expression.

    whenever({a, _b} <- result, ok: a >= 0)
```

The diagnostic is the one written for a genuinely nested binding form — it suggests `match?/2`,
splitting into two assertions, or a private predicate — so it reads as "you wrote this in the
wrong place" rather than "this macro does not support this form here". That is what made it
cost time: the form *was* at the start of the contract, and the advice does not apply.

The stack trace points at the cause. `Bond.Compiler.InheritedContracts.stash_assertion/7` calls
`Bond.Compiler.Assertion.new/5`, which runs `reject_nested_binding_form!/2` over the whole
annotation body. On the `use Bond` path the prefix and all-inside forms are both unwrapped
before that check runs; on the inherited-contract path the all-inside form reaches the check
still wrapped, and its own `whenever` is then found by the prewalk and rejected as nested.

**Suggested fix:** unwrap the all-inside form in `stash_assertion/7` the way the `use Bond`
path does, before `reject_nested_binding_form!/2` sees it. Failing that, the check could ignore
a `whenever`/`where` node that *is* the root of the expression it is walking, which would make
the two paths agree without either needing to know about the other.

This is the third-party half of the entry above: that one was my error, this one is real, and
they are easy to confuse because both surface as "the form matters". Worth resolving together.

## `bond` — purging contracts orphans `import Bond.Predicates`

**Found:** 2026-08-22, the first time a production build was actually compiled.

`~>` lives in `Bond.Predicates`, which a module must import to use the operator in an assertion
if it does not otherwise have it in scope. When contracts are purged, the assertion disappears
and the import becomes unused:

```
warning: unused import Bond.Predicates
  └─ lib/one_playlist/music/track.ex:31:3
```

Three modules here, and only in `MIX_ENV=prod`, which is exactly where it is least likely to be
noticed and most likely to matter: a release built with `--warnings-as-errors` fails on it.

The same applies to any helper that exists solely to be called from a purged assertion — a
private one becomes an unused function.

**No longer applies to this project**, which now sets the non-precondition kinds to `false`
rather than `:purge` — the assertions stay compiled in, so the import stays used. The finding
stands for anyone who does purge.

Not a correctness problem, and there may be nothing Bond can do: purging happens in the
`@`-annotation macro, which has no way to retract an `import` written by the user. Worth a
sentence in `guides/configuration.md` beside the purge documentation, since the failure appears
only in the one build people compile last. The workarounds are to use the operator in a function
body as well, or to write the implication as `not p or q` and drop the import.

## `bond` — contracted multi-clause functions need consistent parameter names

**Found:** 2026-08-22, writing `OnePlaylist.Providers.Connection.needs_refresh?/3`.

Attaching `@pre`/`@post` to a multi-clause function where the ignored parameters were named
`_skew` in two clauses and `skew_seconds` in a third is a compile error. Renaming the ignored
ones to `_skew_seconds` fixed it. Note the leading underscore is *not* what mattered — `_now`
versus `now` was accepted — only the name after it.

**This is recorded as a positive, not a complaint.** The diagnostic was among the best I have
seen from an Elixir library: it named the function, the disagreeing position, printed the
per-clause names side by side, said exactly what to change, suggested `~>` for the
shape-dependent case, and stated that per-clause contracts may come later with an invitation to
open an issue if the restriction bites.

```
** (CompileError) Bond requires consistent top-level parameter names across all clauses of
   needs_refresh?/3 when contracts are attached. Position 2 disagrees: :_skew, :skew_seconds.

Per-clause top-level names:
  clause 1: _, _now, _skew
  ...
```

**Suggested fix:** none needed. The one thing that might help is a sentence in the
`writing-contracts` guide, since the restriction is discoverable only by hitting it —
something like "a contracted function's clauses must agree on top-level parameter names;
prefix unused ones with `_` but keep the name."

## `errata` — no `:export` block in `.formatter.exs`

**Found:** 2026-08-22, same pass.

Lower impact than the above, because Errata's public API (`Errata.create/2`, `wrap/3`, the
accessors) reads naturally *with* parentheses and there is no documented paren-free idiom. So
there may be nothing to export.

Listing it in `import_deps` is harmless either way — a dep with a `.formatter.exs` but no
`:export` key is silently ignored rather than raising — so this project lists it speculatively
and will pick up any rules added later for free.

**Suggested fix:** probably none. Recorded so the question is settled rather than re-asked.

## Formatter-config inconsistency across the four libraries

**Found:** 2026-08-22, same pass.

The four `.formatter.exs` files have diverged in ways that look accidental rather than
intentional:

| | `line_length` | `inputs` include `mix.exs`? | exports rules? |
| --- | --- | --- | --- |
| `external_service` | commented out (`# 100`) | yes | no |
| `errata` | unset (98) | via `{mix,.formatter}.exs` | no |
| `bond` | unset (98) | via `{mix,.formatter}.exs` | yes |
| `wait_for_it` | 100 | yes | yes |

So `wait_for_it` formats at 100 while `bond` and `errata` format at 98, and only two of the
four have `.formatter.exs` itself under the formatter. A shared convention across the four
would make cross-library diffs quieter.

**Suggested fix:** pick one `line_length` and apply it to all four; use
`"{mix,.formatter}.exs"` in `inputs` everywhere (a bare `*.exs` glob does not match dotfiles,
so `.formatter.exs` silently goes unformatted).
