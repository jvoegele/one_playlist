# Writing contracts in this project

How Bond is used here, distilled from actually using it rather than from reading about it.
Every rule below was learned by getting something wrong first; the examples are all real
contracts in this codebase.

Read [Bond's own guides](https://hexdocs.pm/bond) for the language. This is the house style,
and the answer to "should I add a contract here, and what should it say?"

---

## What a contract is for

**A contract is a specification.** It states what a function or a type promises, in terms a
caller can rely on, checked by machine and published in the documentation — Bond renders
`#### Preconditions` and `#### Postconditions` sections into ExDoc, which is Eiffel's `short`
form by another name.

That is the primary purpose, and it is worth saying plainly because this file argued
otherwise for a long time. It treated contracts as bug-catchers, with "name the bug it
catches" as the entry criterion. That frame is not wrong so much as *downstream*: catching
bugs is what a specification does when the implementation disagrees with it. Leading with it
produced a rule — never restate the body — that turned out to reject perfectly good
specifications, for reasons taken apart in
[Where this file used to depart from Meyer](#where-this-file-used-to-depart-from-meyer-and-no-longer-does).

### Why it matters *for this product specifically*

A playlist transfer tool has one failure mode worse than crashing: **finishing, reporting
success, and being wrong.** A track silently dropped, a duplicate quietly added, a playlist
transferred in the wrong order — none of these raise, none fail a type check, and none look
like anything in a log. The user finds out weeks later, if ever.

An application whose failures are silent needs its intended behaviour written down somewhere
executable. That is why contracts here concentrate on **conservation and identity laws**
rather than on argument validation: those laws *are* the specification of a transfer.

---

## The quality check: can this assertion fail?

Falsifiability is not why you write a contract — the specification is. But it is the sharpest
check on whether you have written a *good* one, because an assertion that can never fail is
usually one that describes the mechanism rather than the meaning. A vacuous contract is worse
than none: it *looks* like coverage.

Treat a failed falsifiability check as a question, not a verdict. "This cannot fail" has three
possible answers, and only one of them is "delete it":

| Why it cannot fail | What to do |
| --- | --- |
| It transcribes *how* the body works | Restate it as *what* the function promises |
| The body guards the property twice | Delete the redundant guard, keep the contract |
| It is a true law of a pure function, unfalsifiable by data | Keep it; prove it by mutation |

The last row is the common case for specifications and is developed under
[A postcondition on a pure function](#a-postcondition-on-a-pure-function-is-a-production-assertion-not-a-test-assertion).

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

### The *mechanism*, as opposed to the meaning

This entry used to read "restatements of the body", with `@post computed: result == a + b`
beside `def add(a, b), do: a + b` as the example. The example is still a poor contract; the
rule drawn from it was wrong, and it is now stated the other way round —
see [Where this file used to depart from Meyer](#where-this-file-used-to-depart-from-meyer-and-no-longer-does).

The distinction that survives is **mechanism versus meaning**, and mirroring the body is not
the test for it:

```elixir
# ❌ mechanism: `Enum.map/2` is how the answer is computed, not what it means
@post mapped: result == Enum.map(tracks, &Mapper.track/1)

# ✅ meaning: what a caller relies on, however it comes to be computed
@post no_tracks_invented: length(result) <= length(tracks)
```

`result == a + b` is degenerate rather than mechanistic — for `add/2` the `+` genuinely *is*
the meaning, and the `@spec` plus the name already carry it. Nothing is gained, so leave it
out. But "it looks like the body" is not the reason.

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
@pre normalized_barcode: barcode == Barcode.normalize(barcode)
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
| Property tests | Laws relating two *different* calls: order-independence, agreement between two spellings of one input |

When a mutation survives, the question is which of the three is missing — and
`docs/reference/contracts.md` has now been wrong about that twice by assuming it was the
contract.

### A `Bond.PropertyTest` inherits its contract's blind spots exactly

`contract_holds/2` uses the contract as its oracle, so the property sees precisely what the
contract sees and nothing more. That is easy to forget once a property is running hundreds of
cases per second and looking thorough.

Measured on `Tokens.from_oauth_response/2`, whose `scopes_are_a_list` invariant is just
`is_list/1`. Dropping `trim: true` from its `String.split/3` turns `"scope" => ""` into `[""]`
and `"  a   b  "` into a list padded with blanks — a wrong value that is structurally fine:

| | Result under the mutation |
| --- | --- |
| `contract_holds &Tokens.from_oauth_response/2`, 1100 checks | **passed** |
| One example asserting `scopes == []` | **failed** |

So a property test does not subsume the examples it is drawn over; it widens the *inputs* the
existing oracle judges. Where the contract is weak — and a type check is the weakest kind —
the examples remain the only thing looking at the value.

The corollary is a decent rule for where a `contract_holds/2` earns its place: point it at a
function whose contract states a **law about the output** over an input space too large to
enumerate. `Signals.compare/2` qualifies (four composed scoring functions, unbounded input,
and a mutation of `Enum.max/1` to `Enum.sum/1` that no example catches).
`Tokens.from_oauth_response/2` barely does — four optional keys is sixteen combinations, and
example tests can nearly enumerate that on their own.

### "It takes two runs to see" does not mean it cannot be a postcondition

The table above sorted idempotence into the property-test column, and that
mis-sorting kept `Normalize.text/1`'s `idempotent` assertion out of its contract
until it was added by hand. A postcondition may **call the function it belongs
to**:

```elixir
@post idempotent: text(result) == result
```

Bond suppresses contract checking while evaluating an assertion — Eiffel's rule —
so the nested call terminates rather than recursing forever, and is counted once
rather than once per level. Worth knowing before assuming the shape is illegal.

The real distinction is not "how many runs" but **what the law relates**:

  * Two calls on the *same* value — idempotence, `f(f(x)) == f(x)` — is a claim
    about one result and belongs in a postcondition, where it holds over every
    input the application ever sees rather than over generated ones.
  * Two calls on *different* values — "these two spellings of one credit agree",
    "order does not matter" — has no single result to hang on, and stays a
    property test.

Put a self-invoking assertion **last**, so the cheaper ones fail first and name
the problem more precisely.

It also has to be checked for independence rather than assumed, exactly like any
other addition to an existing list. `text/1` already asserted that its output is
lowercase, is letters/digits/single-spaces only, and is trimmed — which sounds
like it forces a fixed point and does not. Those three constrain what the output
*looks like*; idempotence constrains what the function *is*. Leading-article
stripping — a standard music-library normalization, and a plausible future edit
here — separates them: "The The Beatles" becomes "the beatles" and then
"beatles", satisfying all three at every step. (The band The The is a real
counterexample, not a contrived one.)

### A postcondition on a pure function is a *production* assertion, not a test assertion

`Normalize.text/1` carries three postconditions. None of them can be made to fail by data, and
that was measured rather than assumed: every codepoint in the BMP and the first astral plane
was pushed through it alone, embedded between letters, and doubled — 128,992 codepoints,
~387,000 inputs — with **zero violations**. All three are provable only by mutating the code.

That is not a reason to delete them, but it does mean their value is somewhere other than the
test suite. `text/1` is the single point where every string from every provider arrives, and
postconditions are compiled in and gated off in production (see `config/prod.exs`). So "is
normalization why this user's matches are bad?" becomes a question answerable from a remote
console during an incident, over that user's real library, rather than a rebuild.

The practical consequence: **`⚠ never failed` is the expected steady state for this class of
assertion**, and the checklist's step 7 has to be read as "prove it by mutation" rather than
"write a test that makes it fail". Distinguish the two cases when reading the coverage table:

| Assertion fires on… | Example | `⚠ never failed` means |
| --- | --- | --- |
| Data the application really sees | `Transfer.ledger_balances` | Look for the missing test |
| Only a code change | `Normalize.case_folded` | Expected; mutation is the proof |

`every_tag_is_classified` on `Normalize.title/2` sits between the two and is worth the
distinction. Adding a `:acapella` pattern without classifying it does **not** fail any test —
nothing in the suite normalizes a title containing that word — but it fires the first time a
real title does. A test cannot catch it and the contract can, which is the clearest case in
this codebase for a contract over an example.

### "Implied by another assertion" needs checking, not assuming

The rule below — delete an assertion its neighbour already implies — is right,
and it is easy to apply to something that only *looks* implied.

`Music.Barcode.normalize/1` asserts `normalized_form` (the result is `nil` or a leading-zero-free
digit string). An `idempotent: normalize(result) == result` was left out as a consequence of it,
by the reasoning that a value of that shape is unchanged by every step of the body. True of the
body *as written*, and not a property of the specification.

The edit that separates them is one somebody might genuinely make: deciding a trailing check
digit is not part of a release's identity and slicing it off. `"00602547670052"` then normalizes
to `"60254767005"` — perfectly well-formed — and normalizing *that* gives `"6025476700"`. The
shape assertion is satisfied at every step; only idempotence notices.

The two say different kinds of thing, which is the tell. `normalized_form` describes the
**shape of the output**; `idempotent` describes the **character of the function** — that it is a
projection. Assertions on different dimensions are worth checking for independence rather than
eliminating by inspection.

### Put a law where it is owed, or an innocent client gets the blame

The stronger argument for that idempotence assertion is not that it catches an extra bug — it is
*where* it catches it.

`Catalogue.album_id/3` requires `barcode == Barcode.normalize(barcode)`. A non-idempotent
`normalize/1` makes that precondition **unsatisfiable**, and it fires as a *precondition*
violation — which, by Meyer's Assertion Violation rule, means a bug in the client. The client
would be innocent: it normalized exactly once, as instructed, and has no way to do better.

Confirmed by mutation: with only the caller's precondition in place, that edit surfaces as
`normalized_barcode` failing in `Catalogue`, pointing at the wrong module. With the
postcondition on `normalize/1`, the supplier is named at the point of production, before the
value ever travels.

So when deciding where an assertion goes, ask which party can actually be at fault if it breaks.
A law about a function's own output belongs on that function, even when a caller's precondition
would happen to trip over the violation first.

### Size a generator-coverage guard from a distribution, not from one sample

The guards that keep a property test honest — "this generator actually reaches the interesting
branch" — are themselves statistical, and they need sizing like one.

`NormalizePropertyTest` asserted `collapsed_to_nothing > 2` over 300 samples, on the strength of
having measured 4 once. The true minimum at that size, over 40 independent draws, is **exactly
2** — so the guard failed about one suite run in thirty, in a test whose name gives no hint that
randomness is involved.

Measure the range before choosing the bound, and buy the headroom with **sample size** rather
than by lowering the threshold — a lower threshold on the same sample is a weaker guard that is
still flaky:

| Samples | `collapsed_to_nothing`, 40 draws | Safe bound |
| --- | --- | --- |
| 300 | 2 … 15 | none worth having |
| 1000 | 8 … 40 | `> 3` |

Record the measured range in a comment next to the assertion. The next person to see the guard
fail needs to know whether they broke the generator or drew badly, and only the range answers
that.

### Treat every `@bond_warn_skipped_invariants false` as a question

Bond warns when a module declaring an `@invariant` has a public function that neither takes nor
returns its struct. Suppressing it is sometimes right, but the suppression is worth auditing as
a set: **a module with several is usually holding two abstractions.**

`Matching.Match` had four. All were about the *scale* — `confidence_for/2`, `in_band/2`,
`band/1`, `confidences/0` — while the struct is one match graded by it. The rules and an
instance judged by the rules have different lifetimes: the scale is consulted before a match
exists (to derive the name `new/1` stores) and long after (to compare one). Splitting out
`Matching.Confidence` removed all four suppressions, and gave the scale contracts it could not
have had while it was hiding in a struct module.

That split also found a bug the old arrangement had kept invisible. `rank/1` is
`Enum.find_index/2`, which answers `nil` for an unknown name — and under Elixir's term ordering
an atom sorts above every number, so `nil >= 5` is `true`:

```elixir
Match.at_least?(:hgih, :exact_isrc)   #=> true
```

An unrecognised confidence outranked everything, so a typo would have cleared every threshold
ever set: nothing flagged for review, and `Matching.threshold/1` resolving to the first score it
tried. It is now a precondition, discharged at every call site.

The remaining suppressions in this codebase are the two shapes that are genuinely right, and
both are on `Providers.Tokens`:

  * **One-hop delegation.** `from_oauth_response/2` builds nothing itself; it normalizes and
    calls `new/1`, whose exit check fires. The linter reasons per function and cannot see that.
  * **A predicate over its own module's invariant.** `well_formed?/1` takes a bare parameter so
    that it can answer `false` rather than raise — see the next section. Not, as this file once
    claimed, because of the Assertion Evaluation rule.

Both are documented at the suppression. A suppression without a reason written beside it is the
one to go back to.

### An invariant and a predicate over that invariant cannot share a pattern-matched head

If a module declares an `@invariant` and also exposes a predicate testing that same invariant,
the predicate must take a **bare parameter**. A `%__MODULE__{} = value` head gets an entry
check; the entry check evaluates the invariant; and the invariant is the very thing the
predicate exists to test. So it raises on exactly the values it is meant to identify, and its
`false` branch is unreachable at every call site outside an assertion.

Measured on `Match.score_in_band?/1`, which is public and documented as answering a question:

```elixir
Match.score_in_band?(struct(Match, score: 0.2, strategy: :text))
#=> ** (Bond.InvariantError) score_within_its_strategys_band     # before
#=> false                                                        # after
```

A public function that can only ever answer `true` is a documentation lie, and the doctests
that show it returning `false` would have raised.

Note what this is *not*. The invariant's own call to the predicate is fine either way — the
Assertion Evaluation rule suppresses the nested check, so no recursion and no spurious raise.
The problem is only the **direct** call, which is the one a reader of the docs will make.

Bond's `warn_skipped_invariants` linter fires on the bare-parameter form. Suppress it, with the
reason written beside it; this is the third distinct shape of legitimate suppression, alongside
one-hop delegation and a function genuinely unrelated to the struct.

The rule is narrow. It applies to a predicate that tests *the invariant itself*, not to every
predicate on the type: `Tokens.fresh?/2` and `Signals.vetoed?/1` take pattern-matched heads and
should, because a malformed argument to either really is the caller's bug.

### Duplicated private helpers are a missing module, and the module is where the contract goes

Three helpers were byte-identical across `Tidal.Mapper` and `Subsonic.Mapper` —
`blank_to_nil/1`, `parse_datetime/1`, and the same two lines named
`non_negative_count/1` in one and `non_negative_integer/1` in the other. None was contracted,
because a private helper is awkward to contract and pointless to contract twice.

The duplication was the symptom; the missing abstraction was the cause. Every provider mapper
stands at the same boundary — a stranger's JSON on one side, the values the matching engine
compares on the other — and that boundary is exactly where
[assert what you emit, never what you received](#that-external-data-was-well-formed) applies.
Gathering them into `Providers.Payload` means each law is stated **once and inherited by every
provider**, present and future.

Two things worth copying from how it turned out:

  * **Name for the value, not the guard.** `count/1` rather than `non_negative_integer/1`. The
    old name described the check; the new one describes what a reader of `Mapper.playlist/1`
    is getting. The postcondition can then carry the check without the name repeating it.
  * **Near-duplicates are where the bugs hide.** `count/1` and `position/1` differ only on
    zero, and that difference is load-bearing: a release has no track 0, and rung 2 pairs a
    barcode with a position. Two private helpers under two names in two modules is precisely
    the arrangement in which that distinction gets lost.

The general move: **when the same private helper appears in two modules, do not extract it to
whichever one seems closer — ask what boundary both modules are standing at, and name that.**

### An `@invariant` is only as reachable as its own module's API

Bond checks a struct invariant on entry to and exit from **that struct module's** public
functions, and nowhere else. Two consequences fall out, and a codebase-wide sweep hit both.

**A struct module with no operations cannot carry a useful invariant — and that is usually a
smell about the *code*, not the contract.** `Music.Track` is the core domain struct, and its only
public function was `parse_iso8601_duration/1`, which neither takes nor returns a `%Track{}`. An
invariant would have fired nowhere.

The first conclusion drawn from that was "so `Track` gets no invariant". The better question is
why a struct that central had no operations, and the answer was that they were scattered: the
*same four lines* of `search_query/1` in `Providers.Tidal` and `Providers.Navidrome`,
`same_position?/2` private to TIDAL although Subsonic already carries the fields it needs, and
`identity/1` private to `Matching`. Each is a pure question about a track's own fields, and none
was reusable or contracted where it sat.

Gathering them onto `Track` removed a duplication, gave three modules one place to ask, and made
the invariant reachable — three clauses that now fire from ordinary tests rather than only under
mutation. **This is the same reasoning that moved `normalize_barcode/1` out of `Signals`, run in
the opposite direction**: there, a function had no business in the module it sat in; here, a
module had been emptied of functions that belonged to it.

So when an invariant looks unreachable, check which of the two situations you are in before
concluding the invariant is unwarranted.

A caveat learned in the same change: `parse_iso8601_duration/1` still draws the linter's warning
and is still right where it is. A parser for one of the struct's **own fields** is what a struct
module is for — `Date.from_iso8601/1` lives on `Date`. The warning distinguishes "unrelated to
this type" from "does not happen to take this type", and only the first is a misplacement.

**An invariant reached only from an assertion is inert**, by the Assertion Evaluation rule.
`TransferItem.tally/1` and `Transfer.tally/1` return the same four-field map, and lifting it to a
`Tally` struct is tempting: the ledger law (`matched + unmatched <= total`, `added <= matched`)
would become a real invariant, which `Transfer` cannot have because
[`@invariant` does not compile on an `Ecto.Schema`](../library-feedback.md).

It would also never run. The only production caller of either `tally/1` is
`record_run/3`'s precondition, and contracts are suppressed while an assertion is being
evaluated — so the invariant would be checked exactly nowhere. The law stays where it already
works: `Transfer.balanced?/1`, named in the `@post`s that guard the counters.

**Before lifting a map to a struct for an invariant's sake, ask where the invariant would fire.**
If the answer is "at functions this module does not have" or "inside somebody else's assertion",
the lift buys a name and nothing more — which may still be worth it, but not for that reason.

### Two guards mean the contract cannot earn its place

While proving the above by mutation, `no_empty_names` on `Normalize.artists/1` refused to fire
under any single edit. The reason was that the property was guaranteed twice: `trim: true` on
the split *and* an explicit `Enum.reject(&(&1 == ""))` after it. Removing either left the other
holding, so only a double mutation could falsify the assertion — which is another way of saying
it was decoration.

The fix was to delete the redundant guard, not to weaken the contract. The `Enum.reject` had
become unreachable when the split was restructured, and removing it made a single plausible
edit — dropping the `trim: true` — fail loudly.

Worth doing deliberately: when an assertion will not fire under mutation, check whether the
body defends the property more than once before concluding the assertion is wrong.

### Two assertions on one function are fine when neither can see the other's bug

`Matching.threshold/1` carries a precondition *and* a postcondition, which looks like the
"two guards" mistake above and is not. They catch the same catastrophe by different roads and
are blind to each other:

| Bad input | `is_number/1`? | Resolves to | Caught by |
| --- | --- | --- | --- |
| `threshold: 75` (a percentage) | yes — precondition passes | `75.0` | the postcondition |
| `threshold: :hgih` (a typo) | no, but a known-confidence check fails | `1.0` — in range | the precondition |

The second is the interesting one. `to_score/1` resolves an unrecognised confidence through
`Enum.find/3`'s default to `1.0`, which is a perfectly valid proportion — so the postcondition
waves it through, and only a flawless score ever matches again. The `1.0` default is not itself
a bug: a *valid* confidence no text score can reach, like `:exact_isrc`, correctly resolves
there too. That is exactly why the check has to be on **what was asked for** rather than on
what came back.

The test for redundancy is not "are there two assertions" but "can a single plausible edit or
input falsify each independently". Here, both can, and each has a test.

### Cross-check two accumulations of one truth, before the write

The strongest contract found in the codebase-wide pass was a precondition, on
`Transfers.record_run/3`:

```elixir
@pre report_agrees_with_counters: TransferItem.tally(items) == Transfer.tally(counted)
```

`Runner.finish/4` folds over the resolutions **twice** — once accumulating integers onto the
transfer, once building a report row per track — and nothing held the two in step. A miscount
in either fold produces a summary and a report that disagree: "8/10 matched" above a report
with nine matched rows. Neither number is obviously wrong, and nothing raises.

Three things make this shape worth looking for elsewhere:

  * **The pair of `tally/1` functions exists only so the comparison can be written.** Making
    two representations produce the same shape is often the whole work of stating the law.
  * **A precondition, not a postcondition.** The caller has the bug, and naming it *before* the
    write matters when a half-written report looks complete.
  * **It is strictly stronger and cheaper than what was already there.**
    `Runner.run/1`'s `reported_every_track` counts the rows with a database query; ten rows
    against ten tracks satisfies it even when seven are unmatched and the counter says three.

### A contract on dead code catches nothing — so check for callers, then decide

`Transfer.match_rate/1` looked like an obvious candidate: a proportion, on a struct whose
counters are independent columns rather than values derived from one list. A postcondition was
added, and its mutation test would not fire. The reason was not the assertion — the function
had **no callers anywhere**, in `lib/` or in tests.

An assertion that never executes is worse than one that never fails, because it does not even
appear in the coverage table as `⚠ never failed`. It is invisible.

The fix was not to delete the function. It was written for the transfer page and never wired
in, so wiring it in was the smaller change and the better one: `TransferLive.Show` now renders
"75% of the source" under the Matched stat. With a caller the postcondition became live *and*
data-falsifiable — the re-run accumulation bug this project actually hit, six matched of three
total, is caught rather than rendered as "200% of the source".

The order matters. **Check for callers first**; an uncontracted function nothing calls is a
question about the design, and answering it is a prerequisite to contracting it, not a
consequence.

### Lift a law to an invariant when it is a property of the type

If an assertion about a value would hold for *every* instance of that type, prefer stating it
once on the type over repeating it at each function that produces one.

`Matching.threshold/1` asserts `is_a_proportion` about what it returns. `Report` carries the
same number, so the obvious readings are "the invariant is redundant, skip it" or "add it and
accept the duplication". Both are wrong, and the test is the one used everywhere else here:
**can each be falsified without the other firing?**

  * `match/3` resolves a threshold and never builds a report — only the postcondition guards
    that path.
  * A report built directly, in a fixture or a future second construction site, never calls
    `threshold/1` — only the invariant guards that one.

So they are complementary, and the invariant is the stronger of the two to have: it holds for
every report however it was built, and it is falsifiable from a plain test rather than needing
a bad config. Where the two genuinely *do* coincide, lift the law to the invariant and drop the
per-function assertion rather than keeping both.

## What Meyer says, and where this project departs from him

Chapter 11 of *Object-Oriented Software Construction* (2nd ed.) is where Design by Contract
is defined. Bond implements it faithfully enough that most of the chapter transposes; the
notes below record the parts that changed something here, and the parts that deliberately
did not.

### The Assertion Evaluation rule — the one that made this codebase wrong

> During the process of evaluating an assertion at run-time, routine calls shall be executed
> without any evaluation of the associated assertions. — §11.14

Bond implements this. Measured: `Tokens.fresh?/2` called from inside a `@post` returns a
plain boolean, where the identical call outside one raises `Bond.InvariantError`.

Meyer gives two reasons, and the second is the important one. The obvious reason is that
nested assertion checking would recurse forever. The real reason is that assertions must sit
on a *higher plane* than the code they protect: a function used in an assertion has to be
"beyond reproach" before you use it there, and checking its own contracts while it is
screening someone else's is too late. His image is a security guard at a nuclear plant — you
run the background check on the guard in advance, not while he is inspecting the day's
visitors.

**The consequence is a rule about where a law can be enforced.** An `@invariant` cannot be
reached from another module's assertion. `Adapter.refresh_tokens/1`'s postcondition called
`Tokens.fresh?/2` and this file previously claimed that brought `Tokens`' invariant to bear on
the behaviour boundary. It does not, and the gap was real: an adapter hand-building a
`%Tokens{}` with a blank access token returned through that contract without complaint.

The fix is to state the law a second time in a form other modules' assertions can call —
`Tokens.well_formed?/1` beside the invariant that says the same thing.

**A correction, since this file got the reason wrong once.** That predicate takes a bare
parameter rather than `%__MODULE__{} = tokens`, and the Assertion Evaluation rule is *not* why.
The rule handles the assertion case correctly on its own: a suppressed entry check simply lets
the predicate answer, and the caller's postcondition then fails cleanly. Measured — a guarded
predicate called from a `@post` returned `false` and produced a `Bond.PostconditionError`, which
is exactly the wanted outcome. The real reason is
[the next section](#an-invariant-and-a-predicate-over-that-invariant-cannot-share-a-pattern-matched-head).

### The Non-Redundancy principle

> Under no circumstances shall the body of a routine ever test for the routine's
> precondition. — §11.6

Read from the *supplier's* side this is about not writing `if x < 0` under a `require x >= 0`;
the codebase was audited and is clean.

Read from the **client's** side it is sharper, and it found a bug.
`Adapter.refresh_tokens/1` requires a non-blank token; `Providers.refresh/1` calls it and
matched only `refresh_token: nil` in its guarding clause. A `""` — reachable from a row
written before `Tokens`' invariant existed — reached the callee and raised
`Bond.PreconditionError` out of `ensure_fresh/2`, crashing a transfer where it should have
told the user to reconnect.

The lesson to carry: **when you add a precondition, audit its call sites.** A contract makes
an obligation explicit; it does not discharge it. And a contract does not retroactively clean
a database, so data written before an invariant existed still has to be handled by code.

### The Reasonable Precondition principle

> • The precondition appears in the official documentation distributed to authors of client
> modules.
> • It is possible to justify the need for the precondition in terms of the specification
> only. — §11.7

The first half is Bond's Precondition Availability rule, already enforced (and the reason
`Connection.now_after_creation?/2`, `Matching.valid_threshold_request?/1` and
`Transfer.balanced?/1` are public).

The second half is a **test this file did not have**, and it is a good one: *could I justify
this precondition from what the function promises, or is it only convenient for how I
happened to implement it?* Meyer allows restrictions that follow from a documented design
choice — a bounded stack may require `not full` — provided the bound is part of the
specification rather than an accident of the implementation. Applied here,
`Catalogue.album_id/3`'s `normalized_barcode` passes: an unnormalized barcode is a different
cache key for the same release, which is a statement about what the cache *is*, not about how
it is written.

### Demanding and tolerant styles, and where each belongs

Meyer's answer to "should this have a precondition at all?" is a two-part one that this
codebase had arrived at by instinct and never named (§11.6–11.7):

  * **Demanding** — a precondition, and the client's job to satisfy it. Correct for
    software-to-software. "Trying to handle all possible (and impossible) cases is not
    necessarily the best way to help your clients."
  * **Tolerant** — no precondition, an error result the caller must inspect. Correct for
    **filter modules**: those facing the outside world, where "there is no substitute for the
    usual condition-checking constructs".

The dividing line is that *assertions are not an input checking mechanism*. Our provider
adapters, clients and mappers are the filter modules: they face servers we do not control, so
they return `{:error, _}` rather than asserting on what arrived. The domain behind them —
`Matching`, `Transfers`, `Providers` — is demanding.

Meyer states the seam precisely, and it is worth keeping in mind when adding a provider:
**the postconditions of the filter modules must match or exceed the preconditions of the
processing modules.** `Mapper`'s postconditions and `Matching`'s preconditions are the two
sides of exactly that.

### Where this file used to depart from Meyer, and no longer does

Meyer argues that a postcondition mirroring the body is **not** redundant (§11.7). Beside a
body of `Result := (count = capacity)`, the assertion `full_definition: Result = (count = capacity)`
says something different in kind: the instruction *prescribes*, the assertion *describes*, and
their agreement is "evidence of consistency between the implementation and the specification —
that is to say, of correctness".

This file disagreed, and gave three reasons. Two were weak and one was simply false.

**"Documentation is carried elsewhere — `@spec`, `@doc`, doctests."** False. Bond generates
`#### Preconditions` and `#### Postconditions` sections into ExDoc; the Eiffel `short` form
exists here. Worse, several comments in this codebase already *depend* on that fact — "an
assertion rendered into the documentation should reference something a reader can look up" is
why `Transfer.balanced?/1`, `Matching.valid_threshold_request?/1` and
`Connection.now_after_creation?/2` are public. The objection was contradicted by the code
making it.

And a doctest and a postcondition are not the same kind of documentation anyway. Three
doctests on `Normalize.text/1` show three strings; `case_folded` states the property for every
string the application will ever normalize.

**"`Bond.Coverage` scores assertions on whether they can fail."** True, and a real cost — but
an argument about a tool's ergonomics, not about what a contract is. It also weakened on its
own: `⚠ never failed` is already the documented steady state for pure functions, so the
marker already means "check which category this is" rather than "delete this". Specifications
enlarge that category without changing its nature.

**"The house test is *could a plausible rewrite violate it*."** Meyer answers this directly and
the answer was under-read. The body of `full` could plausibly be rewritten
`if count = capacity then Result := True end`; the postcondition is what says those are the
same function. And the mirror-image reading is an artefact of trivial bodies — for `sqrt`,
whose postcondition is `abs(Result^2 - x) <= tolerance`, nothing about the assertion resembles
the algorithm. **What looks like a restatement is often a specification whose current
implementation happens to be one line.**

So the rule is inverted. A postcondition that states what the function promises earns its place
even when today's body computes it obviously. What to leave out is an assertion about the
*mechanism* — and `result == a + b` is best described not as a restatement but as degenerate:
for `add/2`, `+` is the meaning.

**What is kept from the old position** is falsifiability, demoted from entry criterion to
quality check. It earned that much: it killed a `decomposed:` assertion implied by its
neighbour, found a contract on a function with no callers, and found a `no_empty_names` that
could only fail under a double mutation. Those were all real. But each was a *specification
already stated elsewhere*, which is why the check works — not evidence that bug-catching is
the point.

Read backwards, the specification frame explains this codebase's best contracts better than
the bug-catching frame ever did. `Tokens`' invariant defines what a token set *is*.
`every_tag_is_classified` states what a tag is. `Normalize.text/1`'s postconditions define
what "normalized" means, and under the old frame needed an elaborate justification about
production monitoring to survive at all. `report_agrees_with_counters` says a transfer's
report and its summary describe the same run. None of those is primarily a bug-catcher; all
of them are specifications, and they catch bugs because that is what specifications do when
an implementation disagrees with them.

### What does not transpose

  * **Loop invariants and variants (§11.12).** No loops.
  * **The Indirect Invariant Effect (§11.14).** Meyer needs invariants checked on entry *and*
    exit because dynamic aliasing lets one object's operation break another's invariant.
    Immutable data removes that. Bond checks on entry anyway, for a different and still good
    reason: Elixir gives no module a monopoly on constructing its struct.
  * **Assertion Violation rule (§11.6)** transposes exactly and is worth stating plainly,
    because it answers "where does this assertion go?": *a precondition violation is a bug in
    the client; a postcondition or invariant violation is a bug in the supplier.*

### `Bond.check/1` exists and is unused here

Meyer's `check` instruction (§11.11) documents an assumption at a point where you have
*deliberately not* guarded a call, because you are convinced the precondition holds and the
reason is not obvious from the surrounding code. Bond provides it. Nothing in this codebase
uses it, and nothing should be changed to create a use — but the next time a call site relies
on a non-obvious argument, that is what to reach for instead of a comment.

## Proving a contract that cannot fail from outside

Most of the assertions worth having are postconditions on functions that control
their own result, so no input can violate them — only a bug can. `Bond.Test`'s
`assert_postcondition_violation` needs a *call* that fails, and there is none to
write. That is why `Bond.Coverage` reports them as `⚠ never failed` for ever,
and why the checklist below says to mutate.

The mutation has to reach the function the contract is *on*. `ordered_best_first`
is a postcondition on `rank/3`, and the obvious mutation — returning
`List.last/1` from `match/3` — leaves `rank/3`'s own result correctly ordered
and proves nothing. It looked like a proof and was not.

A conservation law needs mutating in **both** directions. `unmatched: []` drops
the failures; a `flat_map` emitting each match twice invents them. One mutation
proves half a law.

And beware the detector. Grepping the test output for the label always matches,
because the coverage table prints every label on every run. What distinguishes a
violation is `label: :the_name` in a raised `Bond.PostconditionError`, or a
coverage row whose failure count is non-zero. Run the harness once with **no**
mutation first: if that reports a hit, the detector is broken rather than the
code.

Six of `OnePlaylist.Matching`'s assertions were verified this way on 2026-08-25,
each mutation applied alone and reverted, with the mutation recorded in a comment
beside the contract so it can be re-run rather than re-invented. The one worth
singling out is `veto_respected`: deleting the veto from `Strategy.Text` — a
different module — fires the postcondition in `Matching`, which is exactly what
restating a rule over the returned pair is for.

## Mechanics learned the hard way

| Thing | What actually happens |
| --- | --- |
| `~>` vs `implies?/2` | `~>` is a **macro** and short-circuits; `implies?/2` is a function and evaluates both sides. Use `~>` whenever the consequent is partial. |
| `~>` in a function body | Needs `import Bond.Predicates, only: [~>: 2]`. Scope it — `\|\|\|` is exclusive-or despite reading as "or". |
| Multi-clause functions | Every clause must use the same top-level parameter names. Prefix unused ones with `_` but keep the name. |
| `@post` with several labels | Both forms are valid — the prefix `@post whenever(pat <- result), a: ..., b: ...` and the all-inside `@post whenever(pat <- result, a: ..., b: ...)` — under `use Bond` **and** on a `Bond.Behaviour` callback. The all-inside form used to be a `CompileError` on a callback, with a diagnostic about nesting that did not apply; Bond 1.15.0 fixed it, verified against 1.16.0 and 1.17.0. The prefix form remains the house default for several labelled assertions, on readability alone: the labels line up under one another instead of trailing off the end of the `whenever`. |
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

1. **State what the function or type promises**, in terms a caller can rely on. If you cannot
   say it, you do not understand the thing well enough to contract it yet.
2. Is it about the **meaning** or the **mechanism**? Mechanism goes in the body, not a
   contract. "It resembles the body" is not the test — a one-line implementation of a real
   specification is still a real specification.
3. Is it a type check? Then it belongs in `@spec` — unless violating it crashes confusingly
   elsewhere.
4. Is it total? Guard partial predicates with `~>`.
5. Is it available to the caller? A precondition naming a private function is one the client
   cannot discharge — Meyer's Reasonable Precondition principle, which Bond enforces.
6. Can it be justified from the specification alone, or only from how you happened to
   implement it? The second kind is the supplier's convenience wearing a contract's clothes.
7. **Can it fail?** Write a `Bond.Test` assertion targeting its `label:`; where no input can
   falsify it, mutate the implementation instead and confirm it fires.
8. Read the coverage table. `⚠ never failed` is a question with three answers — restate,
   de-duplicate the body, or accept it as a pure-function law proven by mutation.
9. When you add a **precondition**, audit its call sites. Making an obligation explicit does
   not discharge it.
