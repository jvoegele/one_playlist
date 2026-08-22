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

This has now happened three times, which makes it a pattern rather than an anecdote — and in
every case the gap was *test data*, not test logic. `artists_are_names` survived removing the
filter it guards, because every fixture happened to give every artist a name. The tests
exercised the function thoroughly and the shape that mattered never occurred. When a mutation
survives, look first at whether your fixtures contain the case the contract describes.

The third is the sharpest, because the test *looked* like it was about exactly the right thing.
`tracks_from_album_items/2` reads each track's position from `meta.trackNumber` rather than
counting list order, and a test named "a gap in `included` does not shift the positions after
it" asserted the consequence. Rewriting the implementation to count by index left that test
green — because on the captured album, `trackNumber` happens to equal the list position for all
fourteen items. **A real fixture is not automatically a discriminating one.** The case where the
two disagree is a multi-volume release, where disc 2 restarts at track 1; adding four synthetic
items covering that killed the mutation.

The lesson generalises: when a test's name states a distinction, check that the fixture actually
*exhibits* the distinction. Capturing real data protects against imagined shapes, not against
unexercised ones.

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

### A cache, beyond its keys

`OnePlaylist.Cache` and `OnePlaylist.Catalogue` carry **no postconditions**, and the reason
is shape 0b rather than oversight. Every law worth stating about them — "an error is never
cached", "after `forget/2` neither tier holds it", "a hit does not call the provider" — is a
claim about shared state that another process may legitimately change between the call and
the check. Asserted, they would accuse correct code under exactly the concurrency the cache
exists to serve.

What *is* assertable is the boundary, and it turned out to be the valuable part anyway:

```elixir
@pre normalized_barcode: barcode == Signals.normalize_barcode(barcode)
```

An unnormalized barcode is not a wrong answer. It is a **different cache key for the same
release**, so the caller silently gets a private copy of every lookup, doubles the provider
calls the cache was meant to save, and writes a second row for a release that already has
one. Nothing raises and nothing is incorrect; the cache simply stops working, in a way that
shows up as a bill. Preconditions stay enabled in production precisely for this: it names the
caller's bug, and the caller is the one who can fix it.

It also caught something immediately — not in `lib/`, but in the tests, which had been using
readable labels like `"doomed"` as barcodes. A fixture that cannot occur in production tests
nothing that matters, and the fix was the fixtures.

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

### 0d. Process state — where `Bond.Server` earns its place

`@invariant` constrains a struct; `Bond.Server`'s `@state_invariant` and
`@transition_invariant` constrain a running `GenServer`'s state, checked after every
callback that returns one.

The distinction that matters is **who can observe the state mid-change**. Shape 0b above
rules out asserting over a shared table because a concurrent writer can interleave between
the snapshot and the check. A `GenServer`'s state has no such problem: one process owns it,
callbacks are serialized, and no interleaving is observable. So the strong assertions that
are unsound against shared state are perfectly sound here.

`Cache.Singleflight` records one fact twice — a key's monitor reference lives both on its
`in_flight` entry and as a key of `monitors`, so a `:DOWN` can find the key it belongs to.
Nothing else keeps them in step:

```elixir
@state_invariant one_monitor_per_in_flight_key:
                   map_size(state.monitors) == map_size(state.in_flight),
                 monitors_point_back_at_their_keys: monitors_agree?(state)

@transition_invariant at_most_one_key_per_message:
                        abs(map_size(new_state.in_flight) - map_size(old_state.in_flight)) <= 1
```

The first pair is shape 0 applied to state rather than to code. Drift is silent in both
directions: a `release/3` that forgot to delete from `monitors` leaks a reference per
completed fetch forever, and a stale entry there makes a later, unrelated `:DOWN` release a
key that is legitimately in flight.

The transition invariant is the blast-radius law that `disconnect/2` could not have — there,
the state was a shared table and the assertion would have raced; here it is process-local and
sound. Mutation-verified: rewriting `release/3` to reset the map, the shape that looks like
tidying up, fires it.

**One result worth knowing before relying on this.** That mutation fired the invariant and
**the test suite still reported all green**. The violation raises inside the coordinator, the
supervisor restarts it, and callers absorb the error — so nothing asserted on it. The
`Bond.InvariantError` was in the output, with the label and the offending expression, and no
test failed.

That is the argument for process invariants rather than against them: it is a bug tests
structurally cannot see, because the system is designed to survive exactly that crash. But it
also means an invariant on a supervised process is a **diagnostic**, not a gate. If a
violation must fail a build, something has to assert on it.

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

## Using the contracts as the test oracle

`Bond.PropertyTest` inverts the usual property-test cost. There is no model of expected
behaviour to write, because the contracts already are one — the work is choosing generators
that produce **valid** inputs and actually reach the interesting branch.

| Macro | Used here for | Not used here because |
| --- | --- | --- |
| `contract_holds/2` | The pure core: `Similarity`, the four rungs' `score/2`, the three `Mapper` document shapes, `Matching.match_all/2`, `Match.new/1` | — |
| `probe_contract/2` | `Connection.needs_refresh?/3`, whose `@pre` bounds a range (`skew >= 0`, `<= 86_400`) | Every other `@pre` here is either an *equality* on a computed value — where the guide notes the injected neighbours are exactly what the filter discards — or on a function that performs I/O, which the guide warns probes badly |
| `invariants_hold/2` | — | It drives constructor/transformer/observer sequences over a struct, and the one struct with an `@invariant` (`Match`) has no transformers: it is immutable, with no function taking a match and returning another |
| `server_invariants_hold/2` | `Cache.Singleflight` | — |

Two rules earned the hard way, both about generators rather than assertions.

**A small key space is a feature.** `server_invariants_hold/2` over randomly generated keys
would produce sequences in which no two messages touch the same key — exercising none of the
coordination the module exists for. Three keys, drawn repeatedly, is what makes collisions the
common case.

**Measure that the interesting branch is reached.** `contract_holds &Similarity.jaro_winkler/2`
passed immediately, and a guard beside it showed why: only **11 of 300** generated pairs
exceeded the Winkler threshold, so the prefix bonus — the only arithmetic in the function that
can leave the unit interval — was essentially never computed. Weighting the generator toward
variants of one word fixed it. Note that `contract_holds/2` draws each argument independently
and so cannot produce a *correlated* pair; when similarity between arguments is what matters,
it has to come from the pool being tight.

This is the same failure the vacuity trap describes, and it has now appeared in three different
suites. **Every generator in this project is paired with a measurement that it produces the
shape under test.**

### What property testing found that examples had not

`tracks_from_data/1` did not check a resource's `type`, so handing it a *search* document —
one of the three confusable shapes — mapped the `searchResults` wrapper itself into a track
whose id was the search token. Its conservation postconditions all held, correctly: that id
really was in `data`. The module's own documentation claimed confusing the shapes "yields an
empty list, not an error", and that claim was false until a property compared the shapes
directly.

Worth noting what caught it: not the contract, and not an example test, but a property
asserting a relationship *between two functions*. The contracts constrain each function against
its own input; nothing until then constrained them against each other.

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
