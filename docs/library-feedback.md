# Feedback for the first-party libraries

A running log of friction found while dogfooding `external_service`, `errata`, `bond`, and
`wait_for_it` in a real application. Goal 1 in `CLAUDE.md` says this feedback is a deliverable
of the project, not a distraction from it — so findings get written down here as they surface,
whether or not they are acted on.

Format: what was hit, why it mattered, and a suggested fix.

Entries are kept after they are fixed, marked **Resolved**, because the reasoning is the
useful part and a fixed bug still explains why the code around it looks the way it does.

> #### bond 1.15.0 closed seven of these {: .info}
>
> Released 2026-08-23, from a sweep of this log. What changed here as a result:
>
>   * `@invariant` now works on an `Ecto.Schema`, so the transfer ledger law moved from three
>     duplicated postconditions to one invariant on the type — and `OnePlaylist.Providers.Connection`
>     gained one it could not have had.
>   * The `:ets.new/2` workaround in `test/test_helper.exs` is deleted; `install_reporter/0`
>     creates the coverage table itself.
>   * Server invariants appear in coverage, and rows are attributed to the module that ran them.
>   * Generated contract sections are fenced, so a wrapped assertion stays inside its code block.
>
> Still open below: one-hop delegation in `warn_skipped_invariants`, the
> `@doc false` Precondition Availability case, contracts orphaned by `:purge`, multi-clause
> parameter names, and the missing-`use Bond` diagnostic.

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

**Resolved in bond 1.15.0.** `install_reporter/0` now creates the table, so it is owned by the
process running `test/test_helper.exs` and outlives the suite. The workaround below is deleted.

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
    `error: expected 0 or 1 argument for @post, got: 2` (reported against Elixir's internal `do_at` expansion helper)
  * a parameter-free assertion → compiles, enforcing nothing, with only Elixir's generic
    `warning: module attribute @post was set but never used`

The third is the one that could bite quietly, though `--warnings-as-errors` catches it and most
real assertions reference parameters, so the exposure is small.

**Suggested fix, if it is ever worth the effort:** nothing in the compiler can easily intercept
`@pre`/`@post` in a module that never invoked Bond. A line in the getting-started guide — "if
`@pre`/`@post` produce `undefined variable` or `expected 0 or 1 argument`, check that the module
has `use Bond`" — would cost nothing and is where someone would look. A Credo check would also
fit, if Bond ever ships one.

## `external_service` — a second Req trap worth a line in the guides

**Found:** 2026-08-22, building the Subsonic adapter. **Not a bug in
`external_service`**, and filed here for the same reason the Req-retries entry above is: the
library's own guides use Req in their examples, so a reader following them inherits its
defaults.

Req's `put_params` step merges parameters with `List.keystore/4`, which **replaces** a
parameter of the same name:

```elixir
# lib/req/steps.ex
new_params
|> Enum.reduce(old_params, fn {name, value}, acc ->
  name = to_string(name)
  List.keystore(acc, name, 0, {name, value})
end)
|> URI.encode_query()
```

That is defensible for the common case, and fatal for an API whose vocabulary for a collection
is the repeated parameter. Subsonic's is: `songId=a&songId=b`, `songIdToAdd=…`. A six-track
append went out as a **one-track** append — the last one — and every layer reported success:

  * the server answered `{"status": "ok"}`, because it had done what it was asked;
  * the adapter reported six added, because `add_tracks/4` can only count what it was *given*;
  * the transfer reported six matched and six added, because it believed the adapter.

Five tracks vanished with no error anywhere, which is precisely the failure this application
exists to prevent. The fix is one line — build the query with `URI.encode_query/1`, which
encodes a list rather than merging one, and pass it in the URL instead of through `:params`.

**Suggested fix:** a sentence beside the existing Req note in `guides/circuit-breakers.md`.
Something like: *"Req's `:params` replaces same-named parameters. If your service expresses
collections as repeated query parameters — Subsonic, some SOAP-ish APIs, `filter[]=` styles —
build the query string yourself, or the extra values are dropped silently."*

Worth pairing with the retries note because they have the same shape: a Req default that is
reasonable in isolation, invisible from inside `call/1`, and wrong for the wrapped service.

## `bond` — `@invariant` cannot be used on an `Ecto.Schema` module

**Resolved in bond 1.15.0.** The cause was hygiene rather than anything Ecto-specific: a clause
head built with `unquote_splicing/1` carries the `quote`-introduced context, and the wrapper bound
its canonical name there while referencing it from the body in `nil`. `OnePlaylist.Transfers.Transfer`
now states its ledger law as one `@invariant` instead of three duplicated postconditions, which also
catches a transfer read back from the database — something no postcondition could reach.

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

**Resolved in bond 1.15.0.** `OnePlaylist.Cache.Singleflight`'s state invariants now report, under
a `(every callback)` heading rather than a bare `nil`.

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

**Resolved in bond 1.15.0.** Rows are keyed on the assertion together with module, function, kind
and label, so each implementation gets its own row and a `✓` is earned by the module it names.

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

**Resolved in bond 1.15.0.** `Bond.Protocol` was affected too. The prefix form is still what
`OnePlaylist.Providers.Adapter` uses, for an unrelated reason documented there: an inherited
contract's expression resolves in the *implementing* module's alias scope, which is a separate
entry below and is not a bug.

**Found:** 2026-08-22, declaring a contract on `c:OnePlaylist.Matching.Strategy.score/2`.

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

## `errata` — the cause chain turned a useless error message into an actionable one

**Found:** 2026-08-22, building the Subsonic connect form. **A positive, and a small
documentation request.**

The form calls the user's own music server before it stores their password, so the failure a
person is most likely to see is "that address is wrong". What `ExternalService` hands back for
that is `RetriesExhausted`, whose message is about *our* reaction to the problem:

> the request could not be completed after 3 attempts

Which is true, and useless: the user did not ask us to retry and cannot do anything about it.
The failure they can act on is underneath, and `Errata.cause/1` walks straight to it —

```elixir
def root_cause(error) do
  if Errata.is_error(error) do
    case Errata.cause(error) do
      nil -> error
      cause -> root_cause(cause)
    end
  else
    error
  end
end
```

— turning the same failure into "connection refused". Six lines, no special cases, and it
works across library boundaries: `RetriesExhausted` is `external_service`'s error wrapping
`one_playlist`'s, and neither knows about the other. That is the whole argument for a shared
error library, and it is nice to have it pay off without ceremony.

Two things worth noting for the guides:

1. **`display_message/1` is written for one audience at a time, and that shows.** Our
   `Subsonic.APIError` says "reconnect to continue" for `:unauthorized`, which is right on a
   transfer report and wrong on the connect form — where there is nothing to reconnect and the
   user is staring at the three fields they just typed. We special-cased it at the call site.
   That is probably correct, but the guides present `display_message/1` as *the* user-facing
   message, and it might be worth saying out loud that a given error can have more than one
   right phrasing depending on where it surfaces.

2. **`Errata.is_error/1` is a `defguard`**, so a module using it fully qualified still needs
   `require Errata`. The error message says so clearly, so this cost about ten seconds — but
   the guides' examples all appear inside modules that already `use Errata`, and a LiveView
   that only wants to *classify* an error has no reason to.

**Suggested fix:** an "unwrapping a wrapped error" recipe in the guides, with the `root_cause`
loop above — the pattern is small enough that everyone writes it, and general enough that
nobody should have to.

## `bond` — an inherited contract's expression is resolved in the *implementing* module's aliases

**Found:** 2026-08-22, moving the OAuth token map into a `Providers.Tokens` struct.

`OnePlaylist.Providers.Adapter` aliases `OnePlaylist.Providers.Tokens` and declares a
contract on one of its callbacks using it:

```elixir
alias OnePlaylist.Providers.Tokens

@post whenever({:ok, tokens} <- result), fresh: Tokens.fresh?(tokens)
@callback refresh_tokens(refresh_token :: String.t()) :: {:ok, tokens()} | {:error, Exception.t()}
```

That compiles cleanly in `Adapter`, and then fails in **both implementing modules**, neither
of which aliases `Tokens`:

```
warning: Tokens.fresh?/1 is undefined (module Tokens is not available or is yet to be defined).
Did you mean:
      * OnePlaylist.Providers.Tokens.fresh?/1
 101 │
     │                                                          ~
     └─ lib/one_playlist/providers/tidal.ex:101:58:
          OnePlaylist.Providers.Tidal.__bond_postconditions__refresh_tokens__1/2
```

Which is correct behaviour — the assertion is injected into the implementor and resolved
there — but the diagnostic lands a long way from the cause. It names a generated function
(`__bond_postconditions__refresh_tokens__1/2`), points at a file that does not contain the
contract, and gives a line and column (`101:58`) that are blank in that file. Nothing in it
says "inherited contract", so the natural first move is to add an alias to `Tidal` — which
works, and quietly leaves the same trap set for the next adapter.

The fix is to spell the module out in full at the declaration site. That is easy once known
and invisible beforehand, and it is a *general* rule about inherited contracts rather than a
detail of this one: any remote call, struct literal, or `__MODULE__` in a `Bond.Behaviour`
contract has to be resolvable from every implementing module.

**Suggested fix:** two things, in order of value.

1. A paragraph in `contract-inheritance.md` — "expressions are resolved in the implementing
   module's alias scope, so write remote calls fully qualified". This is the whole fix for
   anyone who reads it first.
2. If the injected AST can carry the declaring module's `__ENV__`, expanding aliases at
   declaration time would make the short form work and remove the trap entirely. Failing
   that, a compile-time check in `Bond.Behaviour` for unresolvable remote calls in a contract
   would catch it where the contract is *written*.

## `bond` — `warn_skipped_invariants` is a good linter, and it cannot see one-hop delegation

**Found:** 2026-08-22, same change. **Mostly a positive.**

Adding `@invariant` to two struct modules produced two warnings, and the linter was right
both times about the facts:

```
warning: public function `from_oauth_response/2` in invariant-declaring module
`OnePlaylist.Providers.Tokens` never mentions the struct: no clause matches
`%OnePlaylist.Providers.Tokens{}` in its head or builds one in its body, so the entry check
is skipped and invariants are skipped here.
```

The second one earned its keep immediately. It fired on `Signals.normalize_barcode/1`, a
string utility that lives in `Matching.Signals` only because barcode comparison was first
needed there — and which now has callers in three other modules. "This module declares an
invariant and has a public function with nothing to do with its struct" turns out to be a
decent smell for a namespace squatter. Suppressed for now with the reason written down;
moving it is its own change.

The first is a false positive of a specific and probably common shape. `from_oauth_response/2`
does not build the struct — it normalizes an OAuth response and calls `new/1`, which does:

```elixir
def from_oauth_response(body, now \\ DateTime.utc_now()) when is_map(body) do
  new(access_token: body["access_token"], ...)   # new/1 IS checked, on its way out
end
```

So the invariant *is* enforced on every value this function returns, one call away. The
warning text hedges correctly ("the exit check still fires if this function returns a
`%…{}` at runtime"), but it still asks the reader to prove the linter wrong, and the
lowest-friction way to silence it is to inline the struct literal — which duplicates the
normalization that `new/1` exists to hold in one place. That is the linter pushing very
gently toward a worse design.

**Suggested fix:** treat a function whose every return path is a call to another public
function *in the same module* as covered, and stay quiet. If that is more analysis than the
linter wants to do, softening the wording would go most of the way: naming delegation as the
common benign case, and suggesting `@bond_warn_skipped_invariants false` for it specifically,
rather than leaving inlining as the obvious escape.

## `bond` + Elixir 1.20 — the type system independently enforces Meyer's base case

**Found:** 2026-08-22, same change. **A positive, and an argument for the `defstruct`
defaults tip in the invariants guide.**

The guide says a struct's `defstruct` defaults should satisfy its invariant, because `%Mod{}`
is always constructible. `Providers.Tokens` cannot honour that — there is no valid stand-in
for "a real access token" or "a real expiry" — so `%Tokens{}` deliberately violates its own
invariant, and Bond's entry check is what notices.

Elixir 1.20's type system reaches the same conclusion at *compile time*, without being told:

```
Tokens.fresh?(%Tokens{})
#                    ~
# the given type does not have the given key:
#     dynamic(%Tokens{expires_at: nil, ...})
# but expected one of:
#     %Tokens{expires_at: %{..., calendar: atom(), ...}}
```

Because `fresh?/2` passes `expires_at` to `DateTime.after?/2`, the compiler can prove that the
default-constructed struct can never be a valid argument. Two independent mechanisms — a
1988 design rule and a 2025 type checker — agreeing that the defaults are part of the
contract.

**Suggested fix:** none, but it is a nice example for the guide. The tip currently justifies
itself with `Bond.AssertionEvaluationError`, a runtime failure; "and on recent Elixir the type
checker will often catch it for you first" makes the same point more forcefully, and gives a
reader a reason to care before they have been bitten.

## `bond` — the guides frame contracts as bug-catchers where Meyer frames them as specifications

**Found:** 2026-08-23, after reading *OOSC* 2nd ed. chapter 11 in full and comparing it against
Bond's guides. **Not a bug, and the smallest of the suggestions here is a two-line change** —
but it changed how this project writes contracts, so it seems worth reporting.

### The observation

`writing-sound-assertions.md` opens by naming its goal:

> The goal of this guide is to help you write assertions that *can fail on the input they are
> meant to reject*.

That is exactly right **for that guide's topic**, which is soundness — vacuity, totality,
unreachability, assertions whose surface reading does not match their behaviour. The guide is
excellent on all of it and caught several real mistakes here.

The difficulty is that it is also, in practice, where a reader goes to learn *what a contract
should say*, and on that question falsifiability is a quality check rather than the purpose.
Meyer's purpose is the specification: an assertion states what a routine promises, and
catching bugs is what that does when the implementation disagrees. The difference is not
academic — it changes which contracts get written.

### Where it bites: "a `@post` that restates the body"

```elixir
@post computed: result == a + b        # ❌ fails only if `+` is broken
def add(a, b), do: a + b
```

> The test is whether a *plausible* rewrite of the body could violate it.

The example is well chosen and the conclusion ("a good postcondition is a law the body must
respect, not a second copy of it") is right. But **"restates the body" is the wrong test for
it**, and Meyer argues the point directly against this reading (§11.7, "The imperative and the
applicative"). His `full` has body `Result := (count = capacity)` and postcondition
`Result = (count = capacity)`, and he spends two pages on why that is not redundancy:

> The instruction is prescriptive; the assertion is descriptive… So the presence of related
> elements in the body and the postcondition is not evidence of redundancy; it is evidence of
> consistency between the implementation and the specification — that is to say, of correctness.

He also answers the plausible-rewrite test on its own terms: the body could plausibly become
`if count = capacity then Result := True end`, and the postcondition is what says those are
the same function. And the resemblance is an artefact of trivial bodies — for `sqrt`, whose
postcondition is `abs(Result^2 - x) <= tolerance`, nothing about the assertion looks like the
algorithm.

Following the guide's test literally, this project wrote a house rule prohibiting
"restatements of the body" and lost real specifications to it for months. The distinction that
actually holds is **mechanism versus meaning**: `result == Enum.map(xs, &f/1)` beside a body
that maps is mechanism; `result = (count = capacity)` is meaning that happens to fit on one
line.

### The part that makes this worth reporting rather than shrugging at

Bond **already has Meyer's short form** — `Bond.Compiler.ContractDocs` renders
`#### Preconditions` / `#### Postconditions` into ExDoc, and `writing-sound-assertions.md`
itself notes that ExDoc shows "Bond's generated contract sections". That is the feature that
makes contracts-as-specification work, and it is the strongest argument *against* the
restatement rule sitting a few paragraphs away — a postcondition that mirrors a one-line body
still publishes the specification to every reader of the docs, which is most of its value.

So the library has built the Eiffel documentation story and then, in the guide most people
read first, evaluates assertions on a criterion that ignores it.

**Suggested fix,** in increasing order of effort:

1. **Two lines in the restatement section.** Replace "the test is whether a plausible rewrite
   could violate it" with the mechanism/meaning distinction, and note that a specification with
   a one-line implementation is still a specification. Optionally cite §11.7 — the audience for
   a DbC library will mostly take Meyer's word for it.
2. **A sentence in the opening.** Something like: "falsifiability is how you check an assertion
   is *good*; stating the specification is why you write one." That reframes the whole guide at
   no cost to its content.
3. **A short guide of its own** — "What should a contract say?" — sitting before
   `writing-sound-assertions.md` in the ordering. Bond has thorough guides on soundness,
   testing, inheritance, concurrency and configuration; the gap is the one Meyer's chapter 11
   fills, and none of the existing guides quite claims it.

### A related note on `Bond.check/1`

It is Meyer's `check` instruction and it is documented, but it appears only in
`behaviour.ex`'s prose ("use `Bond.check/1` in the body") rather than in any guide's
narrative. Its actual purpose is worth stating, because it is not obvious from the name:
documenting a non-trivial assumption at a call site where you have *deliberately not* guarded
a call, because you are convinced the callee's precondition holds and the reason is not
obvious from the surrounding code (§11.11). A paragraph in `writing-contracts.md` would
probably double its usage.

## `bond` — a wrapped assertion breaks out of its code block in generated docs

**Resolved in bond 1.15.0.** Both sections are emitted as fenced ```` ```elixir ```` blocks now.
Verified here: the `Invariants` section of `OnePlaylist.Providers.Tokens` renders as a single code
block, and `refresh_token_absent_or_real` no longer leaks into the surrounding prose.

**Found:** 2026-08-23, reading the generated docs after `mix docs`. **Presentational, not a
correctness problem — but it damages the feature that makes contracts-as-specification work.**

### What it looks like

`OnePlaylist.Providers.Tokens`' `## Invariants` section renders as three lines of code, then a
stray paragraph, then a fresh code block:

```
    access_token_present: is_binary(subject.access_token) and subject.access_token != ""
    expiry_is_a_timestamp: is_struct(subject.expires_at, DateTime)
    refresh_token_absent_or_real: is_nil(subject.refresh_token) or
  (is_binary(subject.refresh_token) and subject.refresh_token != "")     ← escapes the block
    scopes_are_a_list: is_list(subject.scopes)
```

In HTML that middle line becomes `<p>  (is_binary(…))</p>` sandwiched between two
`<pre><code class="makeup elixir">` blocks: unhighlighted, in the body font, and reading as
prose in the middle of a specification.

### The cause

`Bond.Compiler.ContractDocs` emits contract sections as **4-space indented** code blocks, and
indents each *assertion*:

```elixir
# contract_docs.ex:260 (moduledoc_invariants_section/3)
|> Enum.map(&("    " <> &1))

# contract_docs.ex:195 (the per-function path)
[header | lines] |> Enum.intersperse("\n    ")
```

Both assume one assertion is one line. But the rendered `code` comes from `Macro.to_string/1`,
which runs the formatter — so any assertion wider than the formatter's line length **wraps**,
and only its first line gets the four spaces. The continuation arrives carrying
`Macro.to_string`'s own indentation, which is 0 or 2 spaces, below Markdown's 4-space
threshold. The code block ends there.

That single cause has two quite different-looking symptoms, which is what made it look like two
bugs:

| Continuation indent | Symptom |
| --- | --- |
| 2 spaces | Renders as an indented paragraph; a *new* code block opens for the next assertion |
| 0 spaces | Markdown folds it into the preceding paragraph line **with no separator** |

The second is the more misleading. `OnePlaylist.Matching.match/3` displays

```
veto_respected: (match.strategy in [:text, :fuzzy])~> not Signals.vetoed?(…)
```

— which reads like a whitespace bug around `~>` and is not one. The newline was simply eaten by
paragraph folding.

### Scope in this project

Five contracts, across five modules, and the discriminator is exactly "does the rendered form
wrap":

| Module | Assertion |
| --- | --- |
| `OnePlaylist.Providers.Tokens` | `refresh_token_absent_or_real` (invariant) |
| `OnePlaylist.Matching.Signals` | `similarities_are_proportions` (invariant, `forall`) |
| `OnePlaylist.Matching` | `veto_respected` (postcondition) |
| `OnePlaylist.Providers` | `query_agrees_with_predicate` (postcondition, `forall`) |
| `OnePlaylist.Providers.Tidal.OAuth` | `challenge_is_hashed` (postcondition) |

Every single-line assertion in the project renders correctly. `forall`/`exists` are
over-represented above because they are verbose enough to wrap almost by construction.

### Why it is worth fixing rather than living with

The previous entry in this file argues that Bond's generated `#### Preconditions` /
`#### Postconditions` sections are the library's strongest and most under-sold asset — they are
Eiffel's `short` form, and they are what makes it reasonable to treat a contract as the
published specification rather than as a test aid. A specification that renders as broken prose
undercuts precisely that argument, and it does so on the *longest* assertions, which are the
ones a reader most needs rendered legibly.

**Suggested fix,** either of:

1. **Indent every line.** Split the rendered assertion on `\n` and prefix each line, rather than
   prefixing the assertion. Smallest change, keeps the existing indented-block style.
2. **Emit a fenced block instead** — ```` ```elixir ```` … ```` ``` ````. Immune to indentation
   entirely, guarantees the `elixir` lexer regardless of what the expression contains, and
   removes this class of bug rather than this instance of it. It would also make the contract
   sections match how `@spec` is already rendered on the same page, which currently uses a
   fence while the contracts beneath it use indentation.

Option 2 looks strictly better here, at the cost of one line of visual difference for anyone
who has grown used to the current output.

---

## Bond — the coverage ETS table, again

**Resolved in bond 1.15.0**, by the same change as the original entry.

**Version:** 1.14.1 · **Found:** 2026-08-23, adding Supabase Auth

`test/test_helper.exs` already carries a workaround for Bond creating its coverage table
lazily inside whichever process first evaluates a contract (see the entry above). That
workaround creates the table from the `test_helper` process so it outlives the run.

The new information is that **the workaround can itself crash the suite**. Once, `:ets.new/2`
in `test_helper.exs` raised `ArgumentError: table name already exists` and took the entire run
down before a single test executed — something had created `:bond_coverage` first.

The cause was not reproduced. Checked directly afterwards, the table is *not* present after a
normal application start, so this is not simply "a contract runs during boot". Whatever the
race is, the shape of the bug is the same one the original entry describes: **the table's
lifecycle is implicit, and every user of `coverage: true` has to guess at it.**

**Suggested fix:** create the table in `Bond.Coverage.install_reporter/0`, idempotently
(`:ets.whereis/1` guard, or `:ets.new` inside a `try`). That is the function a user already
calls explicitly at a well-defined point, it makes the owning process predictable, and it
removes the need for any user-side workaround — including the one in this repository, which
should then be deleted.

Until then, the guard in `test/test_helper.exs` is `:ets.whereis(:bond_coverage) == :undefined`,
which is a correct thing for user code to do but is not something a user should have to
discover by having a green suite fail to start.

---

## `bond` — a `@post` written *after* its `@callback` attaches to the next one

**Version:** 1.15.0 · **Found:** 2026-08-23, contracting `OnePlaylist.Formats.Codec`.

`Bond.Behaviour` attaches `@pre`/`@post` to the **following** `@callback`, which the moduledoc
says. Writing them underneath is therefore user error — but the way it fails is worth a
diagnostic, because it is the exact hazard the 1.15.0 discard logic was written to prevent,
arriving from a direction that change does not cover.

```elixir
@callback parse(binary(), keyword()) :: {:ok, [Track.t()]} | {:error, term()}
@post whenever({:ok, tracks} <- result, ok: forall(t <- tracks, usable?(t)))

@callback render([Track.t()], keyword()) :: iodata()
```

The `@post` intended for `parse/2` is absorbed by `render/2`. The only sign was a warning about
an unused variable in a generated function:

```
warning: variable "tracks" is unused
  └─ lib/one_playlist/formats/csv.ex:1: OnePlaylist.Formats.Csv.__bond_postconditions__render__2/3
```

That names `csv.ex:1` — the *implementing* module, at line 1 — for a mistake made in a different
file, in the behaviour. It took a deliberately-broken implementation and a failing test to find,
because the contract compiled, was woven, and simply guarded the wrong function.

The compiler warning appeared only because `tracks` happens not to be bound in `render/2`'s
scope. Had the two callbacks shared a parameter name — `opts`, say, or `tracks` for a
`@callback validate(tracks, opts)` — the assertion would have compiled silently and enforced
against the wrong callback. That is precisely what the `discard_contracts_declared_on/3`
comment in `compiler.ex` says must not happen:

> leaving them queued means the *next* function silently acquires a contract its author never
> wrote on it — which, when the parameter names happen to line up, enforces quietly against the
> wrong function rather than failing.

1.15.0 closed that for implicitly generated functions. The same reasoning applies to an ordinary
`@callback` that follows another one.

**Suggested fix:** warn when a `Bond.Behaviour` module reaches `@before_compile` with contracts
still pending — that is unambiguously a `@pre`/`@post` after the final `@callback`, and cannot
be anything else. That alone would have caught this, since the trailing `@post` on the last
callback is the shape a user reaching for the wrong order tends to write.

Going further would mean warning when an absorbed contract references a variable that is not a
parameter of the callback absorbing it. That is a stronger check and would have named this
exactly — `tracks` is not a parameter of `render/2` — but it needs care around assertions that
legitimately reference module attributes or imported functions.

**Second, smaller thing.** An implementing module needs `use Bond, behaviours: [TheBehaviour]`;
a bare `@behaviour TheBehaviour` compiles and inherits nothing. This is documented, and it is
still the easier of the two mistakes to make, because `@behaviour` is what Elixir itself asks
for and the result is silently uncontracted rather than an error. A note in the behaviour's
`@moduledoc` output — "implementers must `use Bond, behaviours: [...]`" — would be seen at
exactly the moment somebody is writing one.

## `bond` — an `@invariant` cannot see a struct returned inside a tuple

`OnePlaylist.Transfers.Progress` is a plain struct with two `@invariant`s. Its two
state-changing functions return `{batch_to_broadcast, updated_struct}`, because the caller
needs both.

Bond checks an invariant on entry, and on a result that *is* a struct of the module. A tuple
is neither, so the exit check has nothing to look at, and a violation introduced by the call is
caught only by the **next** call's entry check. Verified directly, with the outcome tally
deliberately broken:

```elixir
p = Progress.new(3, batch: 99, interval: 99_999, now: 0)

{_, bad} = Progress.add(p, %{position: 0, outcome: :unmatched}, 0)
#=> no raise; `bad` is %Progress{resolved: 1, matched: 0, unmatched: 0}

Progress.flush(bad, 0)
#=> ** (Bond.InvariantError) outcomes_partition_the_resolved
```

The gap is narrow but lands in the worst place: the **last** call of a run has no next call, so
the final state — the one the caller keeps — is never checked. Here that is the value the
progress broadcast is built from.

### Why this is not just "hold it differently"

The obvious answer is to return the struct and let the caller ask for the batch separately, but
that trades a real API for a contract mechanism, and the tuple is the honest shape: a `add/3`
either hands you a batch or does not.

The workaround is to restate the laws as postconditions that destructure the result:

```elixir
@post whenever({_batch, updated} <- result,
        every_track_accounted_for: accounted_for?(updated),
        outcomes_partition_the_resolved: partitioned?(updated))
```

That works, and sharing private predicates with the `@invariant` keeps it one law in two
places rather than two statements of one law. But it is the module restating its own invariant
because the tool could not find it, which is exactly the kind of duplication the invariant
exists to remove — and nothing warns you that you need to, so the natural version of this
module is silently half-checked.

### What would fix it

Searching a tuple result for a struct of the module would cover this case and the common
`{:ok, struct}` shape at once. If that is too magical — a function returning *two* structs of
the module has no obvious answer — then the linter is the next best thing:
`warn_skipped_invariants` already knows which functions took an invariant check and which did
not, and "this function's result contains a `%__MODULE__{}` that was not checked" is the same
kind of observation it already makes well.

Failing both, it is worth a line in the invariants guide. The rule "checked on entry and on a
struct result" is accurate but reads as complete coverage, and the tuple case is common enough
in Elixir that most stateful structs will hit it.

---

## `bond` — mutation testing is the feature, and the coverage table is what prompts it

A positive, recorded because the negatives above outnumber them and this one changed what got
built rather than merely being pleasant.

`OnePlaylist.Library.Enrichment.enrich/1` carries two postconditions:

```elixir
@post whenever({:ok, enriched} <- result,
        nothing_was_overwritten: only_filled_gaps?(recording, enriched),
        attempt_recorded: is_struct(enriched.enriched_at, DateTime)
      )
```

Neither can be falsified by any input. The function merges rather than assigns and always stamps
the timestamp, so every test passes and both show as `⚠ never failed` in the coverage table
printed after `mix test`. That is exactly the situation the checklist in
`docs/reference/contracts.md` covers, and what it asks for — mutate the implementation and
confirm the assertion fires — took two minutes and returned the answer both times:

  * dropping `record_attempt/2`'s "already has a value" test →
    `** (Bond.PostconditionError) … label: :nothing_was_overwritten`
  * dropping its `Map.put(:enriched_at, …)` → `… label: :attempt_recorded`

What makes this worth writing down is *which* failures these are. Both are silent and both are
on a schedule. A future edit that let enrichment assign rather than merge would rewrite users'
own titles and albums with a stranger's spelling, in the background, for every recording in the
library — no test would fail, no error would be logged, and the damage would be discovered by a
user noticing their playlist had changed. The second stops `due/1` re-offering a recording
MusicBrainz cannot identify, every night, forever.

Two observations for the library:

  * The coverage table is doing real work as a **prompt**. `⚠ never failed` is not a complaint
    about the test suite, it is a question — and it arrived at the moment the assertion was
    written, unprompted, in the normal test output. Nothing else in the toolchain asks it.
  * The workflow it prompts has no tooling. Mutating by hand and remembering to restore is
    error-prone — and it bit twice here, because `cp` back over the original prompted
    interactively and left the mutated file in place mid-run. A `mix bond.mutate` that took a
    label, applied a supplied patch, ran the targeted tests and restored unconditionally would
    turn "the checklist asks for this" into something that happens every time. Even a documented
    recipe in the guides would help; right now every project invents its own.

The suggestion, concretely: give `⚠ never failed` a third state. An assertion proven by mutation
is not the same as one nobody has looked at, and there is currently no way to say so except a
comment in the source — which is what this project does, and which the coverage table cannot see.
