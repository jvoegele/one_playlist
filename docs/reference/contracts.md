# Writing contracts in this project

How Bond is used here, distilled from actually using it rather than from reading about it.
Every rule below was learned by getting something wrong first; the examples are all real
contracts in this codebase.

Read [Bond's own guides](https://hexdocs.pm/bond) for the language. This is the house style,
and the answer to "should I add a contract here, and what should it say?"

---

## Why contracts matter *for this product specifically*

A playlist transfer tool has one failure mode worse than crashing: **finishing, reporting
success, and being wrong.** A track silently dropped, a duplicate quietly added, a playlist
transferred in the wrong order — none of these raise, none fail a type check, and none look
like anything in a log. The user finds out weeks later, if ever.

That is the shape of bug Design by Contract is for, and it is why contracts here concentrate on
**conservation and identity laws** rather than on argument validation.

---

## The one rule: an assertion must be able to fail

An assertion you have never seen fail is an assertion you have not tested. A vacuous contract
is worse than none, because it *looks* like coverage.

Three habits enforce this, in increasing order of confidence:

1. **`Bond.Coverage` runs on every `mix test`.** Anything marked `⚠ never failed` is a prompt:
   either write a test that makes it fail, or delete it.
2. **A `Bond.Test` assertion per contract**, targeting it by `label:`, proving it fires.
3. **Mutation-test the ones that matter.** Break the implementation deliberately, confirm the
   contract catches it, restore. Every postcondition in `Mapper`, `Track` and `OAuth` was
   verified this way — see the commits.

Habit 3 caught something habits 1 and 2 could not: a conservation postcondition can be
unbreakable-by-correct-code and still be worth having, and mutation is the only way to tell
that apart from unbreakable-because-vacuous.

It also catches gaps in the *tests* rather than the contract.
`record_refresh/2`'s `refresh_clears_failure_state` survived deleting the very code it exists
to protect, because every test refreshed a connection that was already clean — so clearing
nothing looked identical to clearing correctly. The contract was fine; the suite never reached
the case where it mattered. **A surviving mutation means one of the two is missing, and it is
not always the contract.**

This has now happened twice, which makes it a pattern rather than an anecdote — and in both
cases the gap was *test data*, not test logic. `artists_are_names` survived removing the filter
it guards, because every fixture happened to give every artist a name. The tests exercised the
function thoroughly and the shape that mattered never occurred. When a mutation survives, look
first at whether your fixtures contain the case the contract describes.

### The vacuity trap in property tests

Property tests fail silently in the one direction that matters — by proving nothing.

`MapperPropertyTest` generated `data` and `included` with independent random ids. They never
collided: **0 documents out of 500 produced a single track.** Every property passed while the
entire resolution path went unexercised.

The fix was to derive `included` from `data`, plus a property that asserts the generators
resolve at all. **When a property passes on the first run, measure whether it exercised
anything** before believing it.

---

## What not to assert

### Types — those belong in `@spec`

`@spec` documents more prominently, Dialyzer checks it, and it costs nothing at runtime. Bond's
own `writing-sound-assertions` guide makes this argument; follow it.

The exception, and why `valid_now` survives here: a type check earns its place when violating
it produces a *confusing crash somewhere else*. `DateTime.compare/2` raises a
`FunctionClauseError` on a `NaiveDateTime` — a precondition converts that into a named
violation identifying the caller.

### Restatements of the body

```elixir
@post computed: result == a + b        # fails only if `+` is broken
def add(a, b), do: a + b
```

The test is whether a *plausible rewrite* of the body could violate it.

### Anything about a lazy stream

`Adapter.stream_playlists/2` and `stream_tracks/3` carry **no** postcondition. Asserting
anything about a stream's contents consumes it — turning a lazy read into hundreds of HTTP
requests, inside an assertion, on every call. "It is an Enumerable" restates the `@spec`.

Contract the *eager* thing next to it instead: this is why `refresh_tokens/1` is heavily
contracted and the streaming callbacks are not at all.

### That external data was well formed

A contract guards *our* logic. A provider sending nonsense is not a programming error, and a
postcondition that raises on it converts their bad data into our crash.

Written first as `@post sane_track_count: is_integer(result.track_count) ~> (result.track_count >= 0)`
on `Mapper.playlist/1`, this fired 14 times against generated input — because the mapper was
passing `numberOfItems` straight through. The fix was not to relax the contract but to
**sanitize the value**, after which the same assertion became a law about what this module
*produces*, which is the only thing it controls.

At a parsing boundary, assert what you emit, never what you received. The property test
"never raises on an arbitrary resource" is what caught the mistake — the two techniques check
each other.

### Anything unfalsifiable in this codebase

Requiring `now` to be UTC looked principled — the schema is `:utc_datetime_usec` throughout.
But this application has no time zone database, so no call site can construct a non-UTC
`DateTime` to violate it. And even with one, `DateTime.compare/2` is correct across zones, so
the assertion would reject a *valid* call.

**Falsifiable is not the same as valuable.** An assertion should reject inputs that are wrong,
not inputs that are merely unconventional.

---

## What a good assertion looks like here

The contracts worth having in this codebase all fit one of four shapes.

### 0. Two implementations of one rule, cross-checked

```elixir
@post query_agrees_with_predicate:
        forall(c <- result, Connection.needs_refresh?(c, DateTime.utc_now(), skew_seconds))
def connections_due_for_refresh(skew_seconds, opts)
```

The strongest contract in the codebase. That Ecto query and `Connection.needs_refresh?/3` are
the same rule written twice, once in SQL and once in Elixir, and nothing else keeps them in
step. Drift is silent in both directions — too wide and the scheduler burns provider quota
refreshing tokens that were fine; too narrow and connections pass their expiry and die.

Mutation-verified against both directions: dropping the query's status filter and widening its
window past the predicate's both fire it.

**Look for this shape wherever a rule exists twice** — a query and a predicate, a database
constraint and a changeset validation, a serializer and its parser.

### 0b. Shared state — assert only what survives interleaving

`disconnect/2` wants a blast-radius law: a rewrite to `Repo.delete_all` with a filter that drops
the `user_id` clause wipes other people's rows while still satisfying "the requested one is
gone". The obvious expression of it is unsound:

```elixir
# WRONG — races, and accuses correct code
@post removed_exactly_one_row: connection_count() == old(connection_count()) - 1
```

Any concurrent `connect/3` or `disconnect/2` **by a different user** can interleave between the
`old/1` snapshot and the check. Bond's own `contracts-and-concurrency` guide names this the
worst failure mode a contract can have: it accuses correct code, and teaches you to distrust the
contract rather than the program. Under concurrent writes, *nothing* about a global table count
is assertable.

What is left is the race-free half — a claim about the struct the call returned, which touches
no shared state:

```elixir
@post removed_what_was_asked_for: removed.user_id == user_id and removed.provider == provider
```

**The blast-radius law belongs in a test**, where the sandbox makes the state genuinely
exclusive and the strong assertion is sound. Verified: the test catches the `delete_all` rewrite
on its own, so moving it lost no coverage.

The general rule, from Bond's guide: for state shared across processes, assert only what the
implementation can guarantee under interleaving. Weak guarantees are the only honest ones, and a
strong assertion elsewhere is better than an unsound one here.

### 0c. Legitimate duplicates — assert multiset equality, not uniqueness

`match_all/2`'s ledger law was first written as a count plus a uniqueness check:

```elixir
# WRONG — a playlist may contain the same track twice
@post every_track_accounted_for: Report.total(result) == length(pairs)
@post no_track_reported_twice: length(Enum.uniq(source_ids(result))) == length(pairs)
```

It fired on the first smoke test, against correct code, because the input genuinely repeated a
track. Uniqueness was never the law — it was a proxy for "nothing was duplicated *by the
implementation*", and the two come apart the moment the input has duplicates of its own.

```elixir
@post every_track_accounted_for_exactly_once:
        Enum.sort(source_ids(result)) == Enum.sort(source_ids(pairs))
```

Comparing the two multisets is **sound and strictly stronger**: it rejects a drop, a
duplication and a substitution, and it replaced both assertions rather than joining them.
Mutation-verified by returning `unmatched: []`.

The general lesson: when tempted to assert that a collection has no duplicates, ask whether
duplicates are illegal *in the domain* or merely unexpected in the examples to hand. If the
input may contain them, compare against the input instead of appealing to uniqueness.

### 1. Conservation — nothing invented, nothing lost

```elixir
@post no_tracks_invented: forall(track <- result, track.provider_id in item_ids(document))
@post never_more_than_requested: length(result) <= length(item_ids(document))
def tracks_from_items_page(document)
```

Catches: a mapper that reads from the wrong collection. Mutation-verified — swapping `data` for
`included` fires `no_tracks_invented`. This is the closest thing the codebase has to Bond's own
`Ledger` example, and the transfer engine will want more of them
(`matched + unmatched + skipped == total`).

### 2. Security relationships that still "work" when broken

```elixir
@post whenever({:ok, authorization} <- result,
        challenge_is_hashed:
          challenge_in(authorization.url) == Base.url_encode64(:crypto.hash(:sha256, ...)),
        verifier_never_sent: challenge_in(authorization.url) != authorization.code_verifier)
def authorization_url(opts)
```

Catches: sending the PKCE verifier where the challenge belongs. The flow still completes, the
exchange still succeeds, every test still passes — and PKCE's entire protection is gone.
Mutation-verified.

### 3. Units and magnitudes that are not type errors

```elixir
@pre skew_under_a_day: skew_seconds <= 86_400
```

Catches: milliseconds passed where seconds are wanted (`300_000` for `300`). Nothing fails —
every token merely looks due for refresh on every call, and the application hammers the
provider until the rate limiter notices.

Bonus: `probe_contract` reads literal comparisons out of the `@pre` and aims generators at
them, so adding a bound gets boundary testing for free.

### 4. Values that are silently poisonous downstream

```elixir
@post non_negative: is_integer(result) ~> (result >= 0)
def parse_iso8601_duration(value)
```

Catches: ISO 8601 admits negative components, so `"PT-5S"` parsed to `-5`. A negative duration
is not a shorter track — it is a value that scores as a near miss against real durations in the
matching engine. **The property test passed over this bug** because it only asserted
`is_integer(result)`.

---

## What a contract cannot catch

A bound cannot see a value that is wrong but in range.

`Similarity.weighted_mean/1` carries `in_unit_interval`. Mutating it to divide by the declared
total weight rather than the weight actually used — the realistic bug, and the one the comment
above it names — produces scores that are *too low* and still perfectly within `0.0..1.0`. The
contract did not fire, correctly. Four example-based tests did, including
`"an absent signal costs its weight too, not just its value"`.

The reverse also happened here: `veto_respected` and `ordered_best_first` catch mutations that
every example-based test survived, because the tests asserted "a match was returned" and the
match still was.

So the division of labour is not stylistic:

| | Catches |
| --- | --- |
| Contracts | Structural violations — wrong element, wrong count, out of range, relationship broken |
| Example tests | Wrong values that are structurally fine |
| Property tests | Laws needing two runs to see: determinism, order-independence, monotonicity |

When a mutation survives, the question is which of the three is missing — and
`docs/reference/contracts.md` has now been wrong about that twice by assuming it was the
contract.

## Mechanics learned the hard way

| Thing | What actually happens |
| --- | --- |
| `~>` vs `implies?/2` | `~>` is a **macro** and short-circuits; `implies?/2` is a function and evaluates both sides. Use `~>` whenever the consequent is partial. |
| `~>` in a function body | Needs `import Bond.Predicates, only: [~>: 2]`. Scope it — `\|\|\|` is exclusive-or despite reading as "or". |
| Multi-clause functions | Every clause must use the same top-level parameter names. Prefix unused ones with `_` but keep the name. |
| `@post` with several labels | **Use the prefix form** — `@post whenever(pat <- result), a: ..., b: ...` — everywhere. It is the only one that works in both places. The all-inside form `@post whenever(pat <- result, a: ..., b: ...)` compiles under `use Bond` but is a `CompileError` on a `Bond.Behaviour` callback, with a diagnostic about nesting that does not apply. See `docs/library-feedback.md`. |
| `whenever`'s first argument | Must be a binding form — `pat <- source`. A plain boolean is not one: `whenever(is_float(result), ok: ...)` is rejected. For "assert only when this holds", the operator is what you want: `@post ok: is_float(result) ~> (result >= 0.0)`. |
| `@pre`/`@post` behaving strangely | **Check the module has `use Bond`.** Without it the annotations fall through to `Kernel.@` and the diagnostics never mention Bond: an assertion referencing parameters fails with `undefined variable "x"`, a multi-label one with `expected 0 or 1 argument for @post, got: 2`, and a parameter-free one merely warns `module attribute @post was set but never used` while enforcing nothing. This is the first thing to check, not the last. |
| Preconditions calling helpers | The helper must be **public** (Bond warns otherwise, citing Meyer) *and* documented — `@doc false` passes Bond's check while defeating its stated rationale. |
| `@apply_contract` + behaviours | Mutually exclusive on the same function, except for result-only contracts. Adapters inherit from `Providers.Adapter`, so `defcontract` is largely unavailable there. |
| `defcontract` for small duplication | Measured: 15 lines added to remove 1 duplicated line, and the contract disappears from the function. Not worth it below several non-trivial shared clauses. |
| Duplication vs. value | One repeated assertion is a poor reason to skip a contract worth having. `now_after_creation` is deliberately duplicated. |

---

## Where contracts go, by layer

| Layer | Contract? | Why |
| --- | --- | --- |
| `Music.*` structs | Yes, on parsers | External data lands here; poison values start here. |
| `Providers.Adapter` callbacks | **Yes — declare once** | Inherited by every adapter with no contract code in them. |
| `Providers.Tidal.Mapper` | Yes | Conservation laws over external payloads. |
| `Providers.Tidal.Client` | No | Behaviour is HTTP-shaped; guarded by `ExternalService`, tested with `Req.Test`. |
| `Providers` context | Sparingly | Mostly persistence; the laws live in `Connection`. |
| Controllers / LiveViews | No | Assert in tests; a contract violation in a request path is a 500. |

## Production posture

```elixir
# config/prod.exs — actually configured, not merely intended
config :bond,
  preconditions: true,
  postconditions: false,
  invariants: false,
  checks: false
```

Preconditions are fully on: cheapest to evaluate, and the only kind that names a *caller's* bug
— exactly the failure you cannot reconstruct from the callee's logs afterwards.

The rest are **`false`, not `:purge`**. Both leave them inert; the difference is that `:purge`
removes the code entirely while `false` compiles it in behind a single lock-free
`:persistent_term` read per kind per call. That gate buys something a purged build cannot offer:

```elixir
# in a remote console, mid-incident
Bond.Config.enable(:postconditions)
```

Verified against a real `MIX_ENV=prod` build — off as deployed, enforced after `enable/1`, off
again after `disable/1`.

Two consequences that follow directly:

  * **An assertion must be sound, not merely inert.** "It is off in production" is not a licence
    to write one that could accuse correct code, because anyone can switch it on. This is why the
    racing table-count postcondition on `disconnect/2` was deleted rather than left disabled.
  * **Nothing is purged, so nothing is orphaned.** An `import Bond.Predicates` used only inside
    an assertion stays used, and a release does not warn about it. That constraint shaped some
    existing assertions — written as `not p or q` while purging was the plan — and no longer
    applies to new ones.

`config/prod.exs` is the authority. Check the file rather than trusting this paragraph: it was
documented here for several commits before it was configured at all, and an I/O-performing
postcondition got justified in the gap.

## Checklist for a new contract

1. Name the bug it catches. If you cannot, do not write it.
2. Could a plausible rewrite of the body violate it? If not, it restates the body.
3. Is it a type check? Then it belongs in `@spec` — unless violating it crashes confusingly elsewhere.
4. Is it total? Guard partial predicates with `~>`.
5. Is it falsifiable *in this codebase*? Check, do not assume.
6. Write a `Bond.Test` assertion targeting its `label:`.
7. Run the suite and read the coverage table. `⚠ never failed` means go back to 6.
8. For anything load-bearing, mutate the implementation and confirm it fires.
