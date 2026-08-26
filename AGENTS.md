This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- usage-rules-start -->
<!-- bond-start -->
## bond usage
_Design by Contract (DbC) for Elixir_

# Bond usage rules

Bond is Design by Contract for Elixir: `@pre`, `@post`, `@invariant` and `check/1` compiled into
your functions, checked at runtime, and rendered into your ExDoc.

**A contract is a specification, not a test.** It states what a function promises, in terms a
caller can rely on. Catching bugs is what that does when an implementation disagrees with its
promise — a consequence worth having, but not the purpose. That distinction decides which
contracts get written, so lead with it.

Sub-rules: `bond:testing` (proving contracts fire, property testing, coverage) and
`bond:inheritance` (behaviours, protocols, `defcontract`).

## The default is yes

**Aim for a contract on every non-trivial function.** Everything else in these rules constrains
*what* to write; almost none of it is a reason to write *nothing*. Read the "do not write" list
as a quality bar on the assertion you are about to write, not as a gate you have to argue your
way through first.

This needs saying because the failure mode is one-sided. A codebase with too few contracts looks
exactly like a codebase that did not need them — nothing is missing, nothing is red, and the
functions that quietly promise nothing are invisible. Under-contracting is the default outcome of
careful screening, and it is the one nobody notices.

Measured on a Phoenix application contracted with these rules: **67 of its 126 source files**
`use Bond`, carrying 136 postconditions, 28 preconditions and 13 struct invariants across 12
struct modules. Its author's judgement was that reaching that density took five passes, because
every earlier pass had stopped too early.

Two things follow from that ratio of nearly **five postconditions to every precondition**:

  * **Most functions have something to promise; far fewer have something to demand.** If you are
    looking for a `@pre` and not finding one, that is normal — ask what the function *returns*
    instead, which is where the interesting laws are.
  * **Start from the promise, not from the screening.** Ask "what does this guarantee?" first. If
    you can state it, write it. If you genuinely cannot, that is a finding about the function —
    usually that it does two things, or that its result has no describable shape — and it is worth
    a moment's thought rather than a shrug.

The bar does not move. A contract that restates mechanism, cannot be evaluated, or accuses correct
code is worse than nothing, and none of what follows is suspended by this section. What changes is
the presumption: **contract it unless one of the stated reasons applies**, rather than contract it
only where the case is overwhelming.

## Setup

```elixir
# mix.exs
{:bond, "~> 1.18"},
{:stream_data, "~> 1.0", only: [:dev, :test]}   # only if you want Bond.PropertyTest
```

```elixir
# .formatter.exs — add :bond, or the formatter rewrites the binding forms
import_deps: [:bond]
```

A plain labelled contract (`@pre positive: x > 0, small: x < 10`) is one keyword-list argument and
survives without this. The **multi-argument** forms — a `where`/`whenever` binding followed by
scoped assertions — do not. Verified on 1.16.0:

```elixir
# written, and what you get back without import_deps: [:bond]
@post where({:noreply, %{timer: t}} = result), timer_ref: is_reference(t)
@post(where({:noreply, %{timer: t}} = result),
  timer_ref: is_reference(t)
)
```

## Rule 0: the module must `use Bond`

Check this before diagnosing anything else. Bond works by overriding `Kernel.@/1`; without
`use Bond` the annotations fall through to plain module attributes and **none of the resulting
errors mentions Bond**:

| What you wrote | What you get without `use Bond` |
| --- | --- |
| A `@pre` referencing a parameter | `error: undefined variable "x"` |
| A `@post` referencing `result` | `error: undefined variable "result"` |
| A multi-label `@post` | `expected 0 or 1 argument for @post, got: 2` |
| An assertion referencing nothing | Compiles, **enforces nothing**, warns only `module attribute @pre was set but never used` |

The last one is the dangerous one. If a contract seems to be doing nothing, check for
`use Bond` first, not last.

The same applies to a macro that *emits* `@pre`: the `@` inside its `quote` resolves in the
defining module's context, so **that** module needs `use Bond` too.

## Writing a contract

```elixir
defmodule Account do
  use Bond

  defstruct owner: nil, balance: 0

  @invariant non_negative: subject.balance >= 0

  @pre positive_amount: amount > 0,
       sufficient_funds: amount <= account.balance
  @post debited: result.balance == account.balance - amount
  def withdraw(%Account{} = account, amount) do
    %{account | balance: account.balance - amount}
  end
end
```

  * **Always use the labelled keyword form.** The label appears in the failure message and lets
    a test target that specific clause. `@pre positive: x > 0`, not `@pre x > 0`.
  * **One claim per assertion.** Splitting `a and b and c` into three labelled assertions turns
    one ambiguous failure into a precise one and makes each individually testable.
  * `@post` sees the parameters plus `result`. `old(expr)` (in `@post` only) snapshots a value
    at entry.
  * `@invariant` uses `subject` for the struct instance, and is checked around every **public**
    function of the struct's **own** module. `defp` is exempt by design — that is how you say a
    helper may legitimately see a transiently-invalid struct.
  * `check/1` asserts mid-body. It is for recording *why* a call is legitimate, not for
    validation — it can be compiled out.
  * Contracts attach to a **function**, not a clause: put them before the first clause. A `@pre`
    between clauses is a compile error.
  * **Explain a contract in its `@doc`, not in a comment above it.** Bond appends the generated
    `#### Preconditions` / `#### Postconditions` sections to the function's `@doc`, so prose there
    renders directly above the contract it justifies and reaches the callers who must satisfy it;
    a `#` comment reaches nobody but whoever opens the file. Keep a comment beside an assertion
    only for what the assertion **cannot say about itself** and a caller does not need — a bound
    that came from a measurement, a deliberate suppression, a formulation that looks like a
    mistake and is not — and keep it to a line or two. A comment long enough to skim past pushes
    the next assertion off the screen and costs more than it records.

**Write comments and docstrings for people, not for agents.** This one is about you. Source
comments are a poor channel for anything aimed at an AI agent — not because agents don't read
them, they do, but because a comment is paid for by every reader, duplicated at every site that
needs it, and drifts out of step with the rules it paraphrases. Notes to your future self or to
the next agent belong where they load regardless of which file is open: `AGENTS.md`, the files it
references, or your project memory. Bond's own mechanics belong in these rules — a comment
restating `bond:inheritance` above an inherited contract is a copy that will go stale.

## The traps

These are the places where the obvious guess is wrong. Most of them are silent.

### `forall`/`exists` bind and assert shape — they do not filter

```elixir
@pre all_positive: forall(x <- samples, x > 0)
@pre has_admin:    exists(u <- users, u.role == :admin)
```

Despite the comprehension-looking syntax:

  * The trailing expression is **the predicate being asserted**, not a filter. There is no `do`
    block.
  * The right side of `<-` is a **plain `Enumerable`**, not a StreamData generator.
  * A **structural** generator pattern *asserts shape*: `forall(%{retry: r} <- entries, r >= 0)`
    **fails** on an entry with no `:retry` key — it is not silently skipped, the way a `for`
    comprehension would skip it.

To get comprehension-style filtering, gate the predicate with `~>` so non-matching elements pass
vacuously — **parenthesising the consequent**, see below:

```elixir
forall(entry <- entries, match?(%{retry: _}, entry) ~> (entry.retry >= 0))
```

One generator and one predicate each; nest for a Cartesian assertion. Under nesting, only the
outermost quantifier's `counterexample:` line is reported (the verdict is always correct).

**Never quantify over an infinite stream** (`forall` only returns when an element fails, so it
never terminates), and **never over an effectful one** — enumerating a lazy stream is a side
effect, so a `@post` over an `IO.stream/2`, an `Ecto.Repo.stream` cursor or a socket consumes
what the caller was going to get. Materialise it first if you really mean to assert over it.

### `|||` is exclusive-or, not "or"

```elixir
Enum.empty?(remaining) or is_reference(timer)     # ✅ disjunction
Enum.empty?(remaining) ||| is_reference(timer)    # ❌ XOR — also fails when BOTH are true
```

Use `or`. Reach for `xor/2` (or `|||`) only when you genuinely mean "exactly one". If you import
`Bond.Predicates` into a function body, scope it: `import Bond.Predicates, only: [~>: 2]`.

### `~>` short-circuits; `implies?/2` does not

`~>` is a macro; `implies?/2` is a function, so both its arguments are evaluated before the call.

```elixir
false ~> raise("boom")            # true — right side never runs
implies?(false, raise("boom"))    # ** (RuntimeError) boom
```

Use `~>` whenever the consequent is only *meaningful* once the antecedent holds — which is the
main reason to reach for implication at all.

### Always parenthesise both sides of a `~>`

`~>` is an **arrow** operator, so it binds *tighter* than every comparison. An unparenthesised
comparison consequent gets swallowed, and the result is a silently constant assertion:

```elixir
is_binary(x) ~> String.length(x) <= 10       # parses as (is_binary(x) ~> String.length(x)) <= 10
is_binary(x) ~> (String.length(x) <= 10)     # ✅
```

Elixir compares across all types, so the broken form quietly answers something. Which way it
lands depends on the operator: `p ~> q >= 0` is **always true** (an atom sorts above every
number) and `p ~> q <= 10` is **always false**. Verified on 1.16.0. Recent Elixir emits
`warning: comparison between distinct types found` — worth reading past the generated code in the
message.

`<~` shares the precedence and left-associates, so `A ~> pattern <~ B` parses as
`(A ~> pattern) <~ B`. Write `(x > 0) ~> ({:ok, _} <~ result)`.

### An assertion must be **total**, or your builds disagree

An assertion that raises has neither held nor failed. Bond reports
`Bond.AssertionEvaluationError` rather than a violation, because those are different facts.

```elixir
@pre valid: String.contains?(email, "@")                        # ❌ raises on nil
@pre valid: is_binary(email) and String.contains?(email, "@")   # ✅ total
```

This matters more than it looks. Everywhere else, turning contracts on can only *add* an error.
A partial assertion can turn a call that would have worked into a raise — and `:purge` makes it
disappear again. **That is a behavioural difference between your contracted and purged builds,
which is exactly what contracts must not introduce.**

Watch for: `String.*` on a possibly-`nil` value, `length/1` on a non-list, `map_size/1` on a
non-map, arithmetic on a nullable field, `Enum.*` on something that may not be enumerable.

### Assertions must be pure and cheap

No `Repo.*`, no `GenServer.call`, no `send`, no `IO`/`Logger`, no `:ets`, no HTTP. Two reasons:
assertions run on every call, and under `:purge` they are not compiled at all — so a
side-effecting assertion makes production behave differently from dev.

### Never `rescue` a Bond error to decide what your program does

```elixir
def safe_charge(amount) do
  charge(amount)
rescue
  Bond.PreconditionError -> {:error, :invalid_amount}    # ❌
end
```

With contracts enabled this returns `{:error, :invalid_amount}`. Compiled with
`preconditions: :purge` it returns `{:ok, -5}` — the branch did not get slower, it stopped
existing. A contract violation is the manifestation of a bug, not a business outcome. If the
condition is something your program must handle, it is not a precondition: use ordinary control
flow and return `{:error, _}`.

Catching Bond errors to **report** them (a `Plug.ErrorHandler`, an error tracker) is fine. The
`[:bond, :assertion, :failure]` telemetry event fires on every violation before the raise.

### Contracts are suppressed while an assertion is being evaluated

Meyer's Assertion Evaluation rule, and Bond implements it. Three consequences that surprise
people:

  * A `@pre` on a predicate you call from inside another contract **is silently inert there**. A
    predicate used in assertions has to carry its own weight: keep it simple enough to be
    obviously correct and test it directly.
  * A `@post` may safely **call the function it belongs to** — `@post idempotent: text(result) == result`
    terminates rather than recursing. Put such an assertion last, so cheaper ones fail first.
  * **An `@invariant` is not reachable from another module's assertion.** If module A's `@post`
    calls `B.some_predicate/1`, B's invariant does not come to bear. To enforce a law across a
    module boundary, state it a second time as a public predicate beside the invariant.

### Multi-clause functions: names must agree where a contract references them

One contract applies uniformly to every clause. All clauses must agree on the top-level
parameter name **at each position an assertion references**; positions no contract mentions may
differ freely. A leading underscore does not count — `_now` and `now` agree, so mark unused
parameters `_amount`, not `_amt`.

For shape-dependent assertions across clauses, use `~>`:

```elixir
@pre is_struct(resource, Game) ~> resource.published
@pre is_binary(resource) ~> (String.length(resource) > 0)
```

If a head destructures and the body uses only the fields, prefix the whole-argument binding —
`def matches?(%{id: id} = _api_spec, value)` — and keep referencing the unprefixed name in the
contract. That silences Elixir's unused-variable warning without breaking the contract.

### `where` / `whenever` — destructuring with full assertion syntax

```elixir
# `where` uses `=`: a non-match is a violation.
@post where({:noreply, %{keys: keys, timer: timer}} = result),
      timer_ref: is_reference(timer)

# `whenever` uses `<-`: a non-match is vacuously satisfied.
@post whenever({:ok, %{urls: urls}} <- result),
      non_empty: urls != [],
      all_https: forall(u <- urls, String.starts_with?(u, "https"))
```

  * The keyword and the arrow must match; a mismatched pair is a compile error.
  * **Case analysis is one `whenever` per shape** — no `or {:error, _}` boilerplate, and each
    line gets its own label.
  * The first argument **must be a binding form**. `whenever(is_float(result), ok: ...)` is
    rejected. For "assert only when this holds", the operator is what you want:
    `@post ok: is_float(result) ~> (result >= 0.0)`.
  * They are recognised only at the **start** of a contract — never inside `~>`, `or`, or a
    larger expression. When you need that, either use `match?/2` with a `when` guard, or split
    into two assertions and push the antecedent inward.
  * If a bound name shadows a parameter, Elixir warns "unused variable". The contract is still
    correct; rename one of them.

### Invariants: which heads and which returns

**On entry**, only when the head gives Bond something to bind:

| Head | Checked? |
| --- | --- |
| `def f(%__MODULE__{} = name, ...)` | yes |
| `def f(x, ...) when is_struct(x, __MODULE__)` | yes |
| `def f(%__MODULE__{field: v}, ...)` (destructure-only) | yes |
| `def f({:wrapped, %__MODULE__{} = name})` (nested, bound) | yes |
| `def f({:wrapped, %__MODULE__{field: v}})` (binds nothing) | **no** |
| `def f(x, ...)` (no pattern, no guard) | **no** |
| `defp` anything | no — private functions are exempt |

**On exit**, the return value is checked only when it is `%__MODULE__{}` or
`{:ok, %__MODULE__{}}`. A struct returned in **any other tuple shape is not checked** —
`{batch, struct}` is a common Elixir shape and silently skips the exit check, so the *last* call
of a sequence (the value the caller keeps) is never validated. Bond warns where it can see this
statically, under `:warn_skipped_invariants`. If your function returns the struct under a
different wrapper, restate the law as a `@post`:

```elixir
@post whenever({_batch, updated} <- result, partitioned: partitioned?(updated))
```

Two more:

  * **Give `defstruct` defaults that satisfy the invariant.** `%MyStruct{}` is valid syntax for
    anyone; with `nil` defaults the first invariant to touch it raises
    `Bond.AssertionEvaluationError` rather than reporting a violation. Write
    `defstruct items: [], capacity: 0`, not `defstruct [:items, :capacity]`.
  * **A predicate that tests the invariant must take a bare parameter.** A `%__MODULE__{} = v`
    head gets an entry check, the entry check evaluates the invariant, and the invariant is the
    very thing the predicate exists to test — so it raises on exactly the values it should
    identify and can never answer `false`. Suppress the resulting linter warning with a comment
    saying why.

### `old/1` is meaningful only for state that changes, and only when nothing can interleave

For an immutable parameter `x`, `old(x) == x` is a tautology. And if `old(expr)` reads state
another process can write — an `Agent`, a `GenServer.call`, a shared ETS table, a database — a
concurrent write lands between the snapshot and the check and **the assertion accuses correct
code**. That is the worst failure a contract can have: it teaches you to distrust the contract
rather than the program.

Under sharing, assert only what survives interleaving:

```elixir
@post count_increased: get_count(agent) > old(get_count(agent))    # ✅ honest
@post incremented_by_1: get_count(agent) == old(get_count(agent)) + 1   # ❌ races
```

The strong version belongs somewhere it is true. Either move the pure transformation into its
own module (the before-state arrives as an argument, the after-state is `result`, and you no
longer need `old` at all), or — for a `GenServer` — use `Bond.Server`, where callbacks are
serialized and the strong assertion is sound:

```elixir
defmodule Counter do
  use GenServer
  use Bond.Server        # AFTER use GenServer

  @state_invariant      non_negative: state.count >= 0
  @transition_invariant monotonic:    new_state.count >= old_state.count
end
```

`@state_invariant` is checked on the state a callback **returns** (not the one passed in);
`@transition_invariant` relates `old_state` to `new_state`. Note that a violation raises *inside*
the server, the supervisor restarts it, and **a test suite can stay green while an invariant
fails on every message** — so these are diagnostics unless something asserts on them.

### Errors report the function that ran

A default argument (`def sqrt(x, opts \\ [])`) generates clauses for both arities; the contract
attaches to the higher one, so failures report `sqrt/2` even when the caller wrote `sqrt(-1)`.

With layered contracts (nesting, inheritance, refinement), violations fail-fast in **execution**
order: preconditions outer-first, postconditions **inner-first**. A `@post_strengthen` that seems
inert is usually being pre-empted by an inner callee's own `@post`.

## What to put in a contract

The full treatment is the `writing-bond-contracts` skill. The short version:

**The test is mechanism versus meaning**, not "does it restate the body".

```elixir
@post mapped: result == Enum.map(xs, &transform/1)      # ❌ mechanism — names the algorithm
def process(xs), do: Enum.map(xs, &transform/1)

@post definition: result == (stack.count == stack.capacity)   # ✅ meaning — a property
def full?(%Stack{} = stack), do: stack.count == stack.capacity
```

The first must change whenever the implementation does, because it *is* the implementation. The
second survives any correct rewrite, and Bond publishes it to every reader of your docs. If you
cannot describe an assertion without describing how the function works, it is mechanism.

**Do not write** — and each of these is either unsound, unreachable, or not something the
specification says:

  * **A type check, where the type is the whole of what you would be saying** — use `@spec`.
    ExDoc renders it more prominently, Dialyzer checks it, and it costs nothing at runtime. But
    `@spec` is *static* and never runs, so this is a division of labour rather than a ban: where
    the value arrives at runtime from outside the compiler's view — parsed input, a provider
    payload, a message from another process — or where violating it produces a confusing crash
    somewhere else, a `@pre` is the one that actually fires, and it names the caller. A type check
    carrying a further constraint (`is_integer(n) and n > 0`) was never in question.
  * **A `@pre` a guard already enforces.** Bond reproduces your `when` guards on the wrapper
    clauses, so a failing argument raises `FunctionClauseError` *before* any precondition runs —
    the assertion is unreachable. *Which* side to drop is Meyer's **Non-Redundancy Principle**,
    and it splits three ways: a guard that **selects a clause** is dispatch — keep it, write no
    `@pre`; a guard **standing in for a type** (`when is_binary(email)`) is Elixir's declared
    parameter type — keep it, and put the fact in a `@spec`; a guard **stating a domain rule**
    (`when amount <= account.balance`) is the only redundant case, and there you **pick one** —
    if a violation is the caller's bug, write the `@pre` and drop the guard, because only the
    contract names the caller, renders into the docs, and appears in the coverage table. **Apply
    the purge test below before dropping anything**: a guard whose absence changes what the
    program *does* is load-bearing, and a `@pre` cannot replace it. A `@pre` **stronger** than the
    guard is not redundant at all: it can fail, so keep it as it stands.
  * **Assertions about data from outside your system.** A provider sending nonsense is not a
    programming error, and a `@post` that raises on it converts their bad data into your crash.
    At a parsing boundary, **assert what you emit, never what you received.**
  * **A precondition your caller cannot evaluate.** A public function's `@pre` must not call a
    `defp` — Bond warns, citing Meyer's Precondition Availability rule. `@doc false` on the
    predicate defeats it the same way, because the obligation is published in terms the reader
    cannot look up. The fix is almost always to **publish the predicate**, not to drop the
    obligation — if it is fit to demand, it is fit for the caller to read. Postconditions are
    exempt either way: they are the function's promise, not the caller's obligation.

**Not on that list: "every current caller already gets this right."** A precondition is an
obligation on every *future* caller, so a contract no existing call site violates is the normal
case, not a redundant one — that is what a green suite looks like. Decide from the specification,
not from a census of today's callers.

### The purge test, before converting existing code into a contract

Everything above is about what to write from scratch. **Converting a check that already exists is
a different move with a different failure mode**, and it is the one you make constantly while
sweeping a codebase. One question settles it:

> Under `:purge`, would this change what the program **does**, or only what it **notices**?

Only what it notices → contract. What it does → ordinary code, unconditional in every build.
`@pre`, `@post`, `@invariant` and `check/1` are all purgeable; a refusal your program must always
perform is not one of them.

```elixir
# The provider comes from a form. A mismatch is a FORGED REQUEST, not a caller's bug.
true = Enum.any?(socket.assigns.connections, &(&1.provider == atom))

@pre connected_to_that_provider: ...   # ❌ purged, and the forgery is accepted
```

**The tell is not how the check is written — it is what happens if it is not there.**
`true = Enum.any?(...)` has no `case`, no `{:error, _}`, nothing shaped like control flow, so a
sweep reads it as a contract someone wrote before they had Bond. What settles it is where the
value came from: data from outside your system has no caller of yours to blame, so refusing it is
behaviour, not diagnosis.

This is the inverse of *never rescue a Bond error to decide what your program does*, and the
direction that bites during an audit: **don't convert what the program does into something it
merely notices.**

When a load-bearing check cannot become a `@pre`, there is often still a `@post` worth having
beside it — keep the refusal as ordinary code with a diagnostic that names the rule, and let the
contract claim something purging cannot weaken (what the function *returns*, where the body
validates what it *looked up*).

**Non-Redundancy assumes the two checks are the same check.** Before deleting either side of an
apparent duplicate, remove it and ask what stops being true, in *every build you ship*.
"Redundant" is a conclusion, not an observation: two checks that read alike may be an accident,
a deliberate second line of defence (`bond:testing`), or a purgeable thing standing in front of
one that is not. Only the first is redundancy.

**Do write** laws that are true of the *meaning*: conservation (`length(result) <= length(input)`,
or comparing sorted multisets rather than appealing to uniqueness), relationships between two
implementations of one rule (a query and the predicate that should agree with it), units and
magnitudes that are not type errors (`@pre skew_under_a_day: skew <= 86_400` catches milliseconds
passed as seconds), and values that are silently poisonous downstream.

## Configuration

Four kinds — `:preconditions`, `:postconditions`, `:invariants`, `:checks` — each `true`
(default), `false` (compiled in, inert, runtime-togglable), or `:purge` (not compiled at all).

```elixir
# config/prod.exs — a good default posture
config :bond,
  preconditions: true,     # cheapest kind, and the only one that names a CALLER's bug
  postconditions: false,   # compiled in but inert — enable from a remote console mid-incident
  invariants: false,
  checks: false
```

  * **The chain is `preconditions ≤ postconditions ≤ invariants`.** Purging a lower kind requires
    purging every kind above it, or it is a compile error. Disabling a lower kind at runtime
    skips the higher ones too.
  * **Prefer `false` to `:purge`** unless you are on a genuinely hot path. `false` costs one
    lock-free `:persistent_term` read per kind per call, and it keeps the option of switching
    checks on in production. `:purge` also **orphans anything that existed only to serve an
    assertion** — an `import Bond.Predicates`, a `defp` predicate — which fails a release built
    with `--warnings-as-errors`. If you do purge, compile that config in CI.
  * **An assertion must be sound, not merely inert.** "It is off in production" is not a licence
    to write one that could accuse correct code — anyone can switch it on.
  * `Application.put_env(:bond, ...)` after the first contracted call **has no effect**; the
    state is cached. Use `Bond.Config.enable/1` / `disable/1`, or `Bond.Config.reset/0`.
  * Per-module: `use Bond, preconditions: :purge` or `config :bond, overrides: [{Mod, opts}]`.

## Where contracts go

Every layer has a specification, so every layer can carry a contract. What changes between them is
**which kind** the specification warrants — not whether the module deserves one.

| Layer | What the specification usually warrants |
| --- | --- |
| Domain structs, parsers | All three — external data lands here, poison values start here |
| Behaviour `@callback`s | All three, **declared once** — inherited by every implementation |
| Pure core / transformation modules | `@post` above all — the interesting laws live here |
| HTTP clients, adapters facing a service you don't control | `@post`, rarely `@pre` — assert what you *emit*, stay tolerant about what arrives |
| Persistence contexts | `@pre` for what a caller must supply; the type's own laws belong on the struct |
| Controllers / LiveViews | `@post` / `@invariant` over the state you assign — usually the thinnest layer, so there is least to say, not least worth saying |

The seam matters: **the postconditions of your filter modules must match or exceed the
preconditions of the modules behind them.**

Two things that are *not* reasons to leave a layer uncontracted:

  * **"A violation there would be a 500."** That is a configuration question, and Bond already
    answers it: ship that kind as `false` and the assertion is compiled in, inert, and switchable
    from a remote console mid-incident. An *unsound* assertion is a reason not to write one; an
    expensive failure mode is only a reason to choose where it runs.
  * **"This layer is a filter, so it should be tolerant."** Tolerance is a statement about `@pre`
    — whether bad input is the caller's bug or a normal outcome to return. It says nothing about
    `@post`, and a filter's postconditions are precisely what the demanding domain behind it is
    relying on.

<!-- bond-end -->
<!-- bond:inheritance-start -->
## bond:inheritance usage
# Bond: shared and inherited contracts

Three ways to state a contract once and enforce it in many places. Reach for them in this order:
a **behaviour** or **protocol** when the thing you are describing is a family of implementations,
a **named contract** when the same agreement governs several unrelated functions.

## Behaviours

Declare on the `@callback`, opt in from the implementation:

```elixir
defmodule Ledger do
  use Bond.Behaviour

  @pre positive_amount: amount > 0
  @post non_negative: result >= 0
  @callback withdraw(balance :: non_neg_integer, amount :: pos_integer) :: non_neg_integer
end

defmodule BankAccount do
  use Bond, behaviours: [Ledger]     # emits @behaviour for you — don't write it separately

  @impl true
  def withdraw(bal, amt) when amt <= bal, do: bal - amt
end
```

`BankAccount.withdraw/2` now enforces both, with no contract code in it. Violations read
`precondition (inherited from Ledger) failed for call to BankAccount.withdraw/2`, and the error
struct carries `:source_behaviour`.

**Four rules that bite:**

1. **The contract goes ABOVE the `@callback` it constrains.** Bond attaches `@pre`/`@post` to the
   *following* callback. Written underneath, the contract is absorbed by the **next** callback —
   and if the two callbacks happen to share a parameter name, it compiles silently and enforces
   against the wrong function. The only signal in the observed case was an unused-variable
   warning naming a *generated* function in the *implementing* module, at line 1, for a mistake
   made in a different file.

2. **`use Bond, behaviours: [...]` is the only entry point.** A bare `@behaviour TheBehaviour`
   compiles and inherits **nothing** — silently uncontracted. This is the easier mistake to make,
   because `@behaviour` is what Elixir itself asks for.

3. **Write remote calls fully qualified.** An inherited contract is stored as an expression and
   expanded **in each implementing module**. Argument names rebind positionally, but everything
   else — remote calls, struct literals, `__MODULE__` — resolves in the *implementer's* alias
   scope. An `alias` at the declaration site does not travel with the contract:

   ```elixir
   @post fresh: Tokens.fresh?(result)                    # ❌ resolves in each implementer
   @post fresh: Providers.Tokens.fresh?(result)          # ✅
   ```

   The failure lands a long way from the cause: a warning about an undefined function, naming a
   generated function in a file that does not contain the contract, and at runtime a
   `Bond.AssertionEvaluationError`. Nothing in it says "inherited contract". A corroborating hint
   *is* available at the declaration site — an alias used only inside a contract is reported as
   `unused alias`. If you see that on a behaviour, a short name in a contract is about to fail
   somewhere else.

4. **Contracts reference the callback's argument names**, which become canonical for each
   position. Your implementation may name its parameters however it likes.

### Refinement

By default an implementation inherits **verbatim**, and attaching a plain `@pre`/`@post` to an
inherited operation is a compile error — strengthening a precondition would break
substitutability, and adding a postcondition silently would be refinement by the back door.

To refine deliberately, following Eiffel's variance rules:

```elixir
@impl true
@pre_weaken small_withdrawal: amount == 0        # effective pre  = inherited OR this
@post_strengthen audited: log_exists?(result)    # effective post = inherited AND this
def withdraw(bal, amt), do: ...
```

Refinement expressions reference the **abstraction's** argument names, not your parameters.
`@pre_weaken` requires an inherited precondition to weaken (you may not introduce one);
`@post_strengthen` may add where the callback declared none. `old/1` is available in an inherited
`@post` but not in `@post_strengthen`.

For an implementation-specific assertion that is *independent* of the contract, use `check/1` in
the body — it sits outside the contract chain.

> If a `@post_strengthen` seems inert, an inner callee's own `@post` is probably catching the
> value first. Postconditions are checked **inner-first**.

## Protocols

Same syntax, different enforcement point — the contract wraps **dispatch**, so implementations
need zero Bond awareness:

```elixir
defprotocol Sized do
  use Bond.Protocol

  @post non_negative: result >= 0
  @spec size(t) :: non_neg_integer()
  def size(data)          # name the argument `data`, not `t`
end

defimpl Sized, for: List do
  def size(list), do: length(list)     # completely ordinary
end
```

Applies to every implementation including third-party ones, survives consolidation, and the error
carries `:source_protocol` and `:impl`.

Three limits: a **direct call to the implementation module** (`Sized.List.size/1`) bypasses
dispatch and is not checked; **`old/1` is not supported** in protocol contracts; and
**compile-time `:purge` is not supported** — use runtime configuration.

Implementations may refine by adding `use Bond.Protocol.Impl` to the `defimpl` block. Plain
`defimpl` blocks are unaffected.

## Named contracts

For an agreement shared by functions that are not implementations of anything:

```elixir
defmodule Money do
  use Bond

  defcontract withdrawal(account, amount) do
    @pre positive: amount > 0
    @pre sufficient: amount <= account.balance
    @post non_negative: result.balance >= 0
  end
end

defmodule Account do
  use Bond

  @apply_contract {Money, :withdrawal}     # or :name for a same-module contract
  def withdraw(acct, amt), do: %{acct | balance: acct.balance - amt}
end
```

The head is a canonical signature: it supplies the names the expressions use and the order they
bind in. Parameters rebind **positionally**, so the function may name them differently.

  * **Identified by `{name, arity}`** — same name at different arities are distinct contracts, and
    the applying function's arity selects the overload.
  * **A zero-argument `defcontract name()` is arity-agnostic** and applies to a function of any
    arity. The explicit `()` is required. Preconditions are rejected (there are no argument names
    to reference), so this is the form for a shared return-value guarantee.
  * **Adding your own `@pre`/`@post` alongside is fine** — they are conjoined. But added clauses
    reference the **contract's** argument names, not your function's parameters; referencing your
    own parameter is a compile error.
  * **Compose with `include`**, since a function applies exactly one named contract directly:

    ```elixir
    defcontract order(item) do
      include positive(item.quantity)
      include in_range(item.discount, 0, 100)
    end
    ```

    Each argument is an expression over the host's parameters, substituted into the included
    clauses; error messages show the substituted form. Self-inclusion is a compile error.
  * **`@apply_contract` needs Bond's `@` syntax**, so it is unavailable under
    `at_annotations: false`. `defcontract` works either way.
  * **Mutually exclusive with behaviour inheritance on the same function**, except for
    zero-argument contracts — which are how you strengthen an inherited postcondition by name
    rather than with `@post_strengthen`.

### Is it worth it?

Measured on a real codebase: **15 lines added to remove 1 duplicated line**, and the contract
disappears from the function where a reader is looking for it. Not worth it below several
non-trivial shared clauses. One repeated assertion is a poor reason to skip a contract worth
having — deliberate duplication is fine.

Simpler options first: for a shared *predicate*, just define a public function and call it from
each contract (keep it public — a precondition naming a `defp` is one the caller cannot
discharge). For a shared *label plus expanded expression*, a macro that emits the whole `@pre`
works, and renders the expanded source into errors and docs — but the macro's own module must
`use Bond`, or its `@` is `Kernel`'s and eagerly evaluates the right-hand side, producing a
baffling `undefined variable` error.

## Coexisting with another `@`-overriding library

Norm's `@contract` and Bond both `import Kernel, except: [@: 1]`, so both in one module fails to
compile with `function @/1 imported from both Bond and Norm.Contract`. Pass
`use Bond, at_annotations: false` and write contracts as qualified calls:

```elixir
defmodule Api do
  use Norm
  use Bond, at_annotations: false

  @contract scale(n :: positive_int()) :: positive_int()
  Bond.pre even: rem(n, 2) == 0
  def scale(n), do: n * 2
end
```

The calls sit **before** the `def`, exactly where `@pre` would — they are not in-body statements.
`Bond.pre/1`, `Bond.post/1`, `Bond.invariant/1`, `Bond.pre_weaken/1`, `Bond.post_strengthen/1`;
`check/1` stays available unqualified. These are never imported, so they cannot collide with your
function names.

Function-wrapping libraries (`decorator`, and anything else using `defoverridable` + `super`)
compose fine — Bond detects externally-generated override clauses and wraps the function as a
whole.

<!-- bond:inheritance-end -->
<!-- bond:testing-start -->
## bond:testing usage
# Bond: testing contracted code

Contracts are the **oracle** — the part of a test that decides whether an output is right. So
testing contracted code is less about writing assertions and more about driving the code until a
contract complains.

Two tools, and they behave oppositely, so keep them straight:

| | Called | Purpose |
| --- | --- | --- |
| `Bond.Test` | **inside** a `test` block | Test *the contracts* — prove they fire on the input they should reject |
| `Bond.PropertyTest` | at **module level**, never inside a `test` | Test *the code* — prove it honours its contracts across inputs you'd never enumerate |

Putting a `contract_holds/2` inside a `test` block is an error, and Bond says so.

**Use both, widely.** A contract you have never seen fail is a claim, not a check, so every
non-trivial contract deserves a `Bond.Test` assertion that proves it fires — and every contract
stating a *law* over an input space you cannot enumerate deserves a `contract_holds/2` alongside
it. Measured on an application contracted with these rules: 27 `assert_precondition_violation`,
27 `assert_invariant_violation`, 12 `assert_postcondition_violation` and 22 `contract_holds`,
against roughly 180 contracts — about **one proof for every two contracts**, concentrated on the
ones carrying real laws. That is a floor worth beating, not a ceiling.

**Reach for property testing whenever the contract states a law rather than a bound.**
`contract_holds/2` costs three lines once the generator exists, and it turns an assertion you
checked on four fixtures into one checked on hundreds of inputs — using the contract you already
wrote as the oracle, so there is no second assertion to keep in step. The best candidates are pure
functions with a `@post` describing a relationship: conservation, ordering, idempotence, agreement
between two spellings of one input.

**`invariants_hold/2` is the most under-used macro in the library.** A struct module that already
has an `@invariant` needs only a list of constructors, transformers and observers to get random
operation sequences checked against it — no generator design, no new assertions, and it explores
orderings you would not have thought to write down. If a module has an invariant and no property,
that is usually the cheapest coverage available to you.

## Proving a contract fires

```elixir
defmodule MyApp.AccountTest do
  use ExUnit.Case
  use Bond.Test

  test "withdrawing more than the balance is rejected" do
    account = %Account{owner: "ana", balance: 20}

    assert_precondition_violation(Account.withdraw(account, 50),
      label: :sufficient_funds
    )
  end
end
```

**Always pass `label:`.** Without it the test passes as long as *some* precondition fired, which
stays green if a different clause starts rejecting the call for an unrelated reason.

One macro per kind: `assert_precondition_violation/2`, `assert_postcondition_violation/2`,
`assert_check_violation/2`, `assert_invariant_violation/2` (pass `kind:` to distinguish a struct
`@invariant` from a `Bond.Server` `:state_invariant` / `:transition_invariant`). Each returns the
exception struct, so you can drill into `:binding`. Field expectations may be exact values or
`Regex`.

There is no "refute" helper and none is needed — a valid call simply returns, and a violation
would raise and fail the test.

**Where a guard does the work, assert `FunctionClauseError` instead.** That is what actually
fires. Use `assert_precondition_violation` for semantic constraints only a contract can express.

## Property testing

Add `{:stream_data, "~> 1.0", only: [:dev, :test]}`. Three module-level macros:

```elixir
defmodule MyApp.MathTest do
  use ExUnit.Case
  use Bond.PropertyTest

  # your generators must produce only VALID inputs — a @pre violation fails the property
  contract_holds &MyApp.Math.sqrt/1,
    args: [StreamData.float(min: 0.0)],
    name: "sqrt over all non-negative floats"

  # generate broadly: @pre becomes a FILTER, and its literal bounds are probed
  probe_contract &MyApp.Account.deposit/2,
    args: [account_gen(), StreamData.integer(-5..105)]

  # random sequences over a struct module's @invariant
  invariants_hold BoundedStack,
    constructors: [{:new, [StreamData.integer(1..100)]}],
    transformers: [{:push, [StreamData.term()]}, {:pop, []}],
    observers:    [{:size, []}]

  # random MESSAGE sequences against a Bond.Server's reachable states
  server_invariants_hold Bank,
    init: StreamData.integer(0..100),
    messages: [
      call: [{:withdraw, [StreamData.positive_integer()]}, {:balance, []}],
      cast: [{:deposit, [StreamData.positive_integer()]}],
      info: [{:tick, []}]
    ]
end
```

**Pass `:name`** whenever two properties target the same function or module — the name is
derived from the target, so they collide otherwise. Bond reports the collision at compile time
rather than letting it surface as ExUnit's `DuplicateTestError`. Distinct names are also what the
failure report shows.

### Choosing between `contract_holds` and `probe_contract`

  * `contract_holds/2` — you guarantee validity. Most direct when a valid generator is easy
    (`StreamData.float(min: 0.0)`).
  * `probe_contract/2` — Bond reads literal comparisons out of the `@pre`, injects values
    straddling them, and **discards** inputs that violate `@pre` (a generation miss, not a
    failure), leaving `@post` as the oracle.

`probe_contract/2` earns its keep when a precondition **bounds a range**. For an *equality*
precondition (`length(items) == 3`) the injected neighbours 2 and 4 are exactly what the filter
discards, so probing adds nothing. Boundaries are read from a **bare parameter** only —
`@pre length(Path.split(key)) == 5` yields none, because the size constrains a computed value.

Your generator must satisfy `@pre` **at every generation size, not just on average**. StreamData
ramps size up from 0, so `list_of(gen, length: 4..6)` produces only length-4 lists early on; a
`@pre` excluding 4 rejects every one and the run dies with
`Bond.PropertyTest.FilterTooRestrictiveError` before the size ever grows. Pin the size in the
generator. For relational preconditions (`amount <= account.balance`), use `StreamData.bind/2` —
boundary injection cannot probe those.

**Pure functions probe best.** A function that reaches a collaborator needs it stubbed for
*every* iteration (`Mox.stub/3`, not `expect/4`), and a `@post` constraining what the
collaborator returned is partly testing the stub. Extract the pure core and probe that.

### Two rules about generators, learned the hard way

**Measure that the interesting branch is reached.** A property that passes on its first run has
proven nothing until you check it exercised anything. Two real cases: a mapper property generated
`data` and `included` with independent random ids that never collided — **0 of 500 documents
produced a single track**, and every property passed while the entire resolution path went
unexercised. A similarity property found only **11 of 300** generated pairs crossed the threshold
that reaches the only interesting arithmetic. Pair every generator with an assertion that it
produces the shape under test.

Note that `contract_holds/2` draws each argument independently and so **cannot produce a
correlated pair**. When similarity between arguments is the point, it has to come from a tight
pool. Likewise, a small key space is a *feature* for `server_invariants_hold/2` — random keys
produce sequences where no two messages touch the same key, exercising none of the coordination.

**Size a coverage guard from a distribution, not one sample.** A guard asserting
`collapsed > 2` over 300 samples, written on the strength of having measured 4 once, failed about
one run in thirty — the true minimum at that size was exactly 2. Measure the range over many
draws, buy headroom with **sample size** rather than a lower threshold, and record the measured
range in a comment beside the assertion.

### A property inherits its contract's blind spots exactly

`contract_holds/2` uses the contract as its oracle, so it sees precisely what the contract sees.
Measured: against a mutation that turned `"scope" => ""` into `[""]`, a property running 1100
checks **passed**, while a single example asserting `scopes == []` failed. The invariant was
`is_list/1` — a type check, the weakest kind.

So a property does not subsume the examples it is drawn over; it widens the *inputs* your
existing oracle judges. Point `contract_holds/2` at a function whose contract states a **law
about the output** over an input space too large to enumerate.

## `Bond.Server` callbacks

Because invariants are woven into the callbacks, you can call them as plain functions:

```elixir
contract_holds &Counter.handle_call/3,
  args: [
    StreamData.constant(:inc),
    StreamData.constant({self(), make_ref()}),
    StreamData.map(StreamData.non_negative_integer(), &%{count: &1})
  ]
```

One property checks the callback's own contracts, the `@state_invariant` on the returned state,
and the `@transition_invariant` relating the incoming state to it.

**Your state generator must produce *reachable* states.** An invariant guards the state a
callback *produces*, not the one passed in — so feeding a state the server could never be in
yields a spurious counterexample. That is also the honest limitation of the direct-callback
approach: it explores the states *you generate*. `server_invariants_hold/2` explores the ones the
server can actually reach.

Its `:mode` matters for mocks. Default `:callbacks` runs in the test process, so a private-mode
`Mox.stub` in `setup` is in scope. `:process` spawns a real server that will not see those
expectations — use `Mox.set_mox_global` with `async: false`, or `Mox.allow/3`. Prefer
`:callbacks`. Either way, **state gated behind a collaborator's reply is only reachable via that
reply**: a branch that runs only when an API call fails is never reached under a success stub,
however long the sequence. Split runs by outcome.

## Coverage, and the workflow it prompts

```elixir
# config/test.exs
config :bond, coverage: true
```

```elixir
# test/test_helper.exs
ExUnit.start()
Bond.Coverage.install_reporter()
```

After each suite you get a table of which assertions ran and how often they were false:

```
      @state_invariant :non_negative        checked  1184×  failed     3×  ✓
      @post :keeps_input                     checked   642×  failed     0×  ⚠ never failed
```

`⚠ never failed` is a **question, not a complaint**, with three answers:

| Why it cannot fail | What to do |
| --- | --- |
| It transcribes *how* the body works | Restate it as *what* the function promises |
| The body guards the property twice **by accident** | Delete the redundant guard, keep the contract |
| Two guards are **independently sufficient** by design | Keep both — and mutate them *together* |
| It is a true law of a pure function | Keep it — prove it by **mutation**, not by a test |

The last is the common case, and in a mature codebase **most rows will read `⚠ never failed`**.
That is what a green suite means. Skim the table for a contract that looks suspiciously safe;
don't drive it to zero.

**Mutation is the proof for that third row.** Break the implementation deliberately, confirm the
contract fires, restore. It answers a question nothing else in the toolchain asks — and it
catches gaps in the *tests* rather than the contract at least as often. Three real cases where a
mutation survived and the contract was fine:

  * Every fixture happened to give every artist a name, so a filter's postcondition never saw the
    shape it guards.
  * Every test refreshed an already-clean connection, so "clears failure state" looked identical
    to clearing nothing.
  * A test named "a gap does not shift positions" passed under a rewrite that counted by index —
    because on the captured album, track number happened to equal list position for all fourteen
    items. A multi-volume release, where disc 2 restarts at track 1, is the discriminating case.

**When a mutation survives, look first at whether your fixtures contain the case the contract
describes.** A real fixture is not automatically a discriminating one, and when a test's name
states a distinction, check the data actually exhibits it.

Contracts and tests catch different things, and it is not a stylistic split:

| | Catches |
| --- | --- |
| Contracts | Structural violations — wrong element, wrong count, out of range, relationship broken |
| Example tests | Wrong values that are structurally fine |
| Property tests | Laws relating two *different* calls — order-independence, agreement between two spellings of one input |

A bound cannot see a value that is wrong but in range. When a mutation survives, the question is
which of the three is missing.

## Running a mutation

One mutation at a time, reverted before the next. Five things make a mutation lie to you; each
has produced a wrong conclusion in a real audit, and one of them deleted a correct contract.

### Aim at the function the contract is on

**A surviving mutation is evidence about the mutation until you have checked it is evidence about
the contract.** It misses in both directions:

  * **Too far out.** `ordered_best_first` is a `@post` on `rank/3`. Mutating `match/3` to return
    `List.last/1` leaves `rank/3`'s own result correctly ordered — the contract holds because it
    is still true there, and nothing was tested.
  * **Too far in.** A `@post` on `Client.playlist_item_references/3` says every returned reference
    has both halves usable. Mutating the mapper it delegates to fires the *mapper's* own
    postcondition first, one call inward, so the outer contract never sees the bad value and looks
    unfalsifiable. It is not — corrupt how the client assembles pages instead, and the mapper stays
    satisfied on every page while the outer contract fires immediately.

The second licenses a wrong conclusion that sounds right: *the collaborator already guarantees
this, so the outer contract is redundant*. **A function whose body delegates to a collaborator
that already guarantees a property still owes that property to its own caller.** The delegation is
an implementation fact and can be refactored away tomorrow; the guarantee is the specification, it
renders into *that* function's ExDoc, and its callers read it there.

### Run a null control first

The coverage table prints **every** label on **every** run, so a harness that greps output for a
label matches whether or not anything failed — reporting a hit for every mutation, including ones
that changed nothing. Two things actually indicate a violation: `label: :the_name` inside a raised
`Bond.*Error`, or a coverage row for that label whose **failed** count is non-zero.

```elixir
defp fired?(output, label) do
  String.contains?(output, "label: :#{label}") or
    ~r/:#{label}\s+checked\s+[\d,]+×\s+failed\s+([\d,]+)×/
    |> Regex.run(output)
    |> case do
      [_, count] -> String.replace(count, ",", "") != "0"
      nil -> false
    end
end
```

**Run the harness once with no mutation applied.** If it reports a hit, the detector is broken,
not the code.

### Each assertion needs a mutation its neighbours survive

Assertions on one function fail fast in execution order, so a mutation breaking the first raises
before the second is evaluated — and the second looks unfalsifiable under every mutation you try.

Real case: `from_the_archive` and `names_the_album_asked_about` on a cover-art lookup. Returning a
redirect target fires the first and pre-empts the second. Proving the second needs a mutation that
**keeps the host intact and changes the album**.

Across *function* boundaries the same pre-emption is a genuine signal rather than a trap: a law
restated at two altitudes, where the inner assertion always raises first, is redundant and the
outer one should go. The coverage table cannot tell the two readings apart. What separates them is
**whether a bug exists that the inner assertion cannot see** — a paging bug is invisible to the
mapper above, so that outer contract earns its place; where no such bug exists, it does not.

### Two guards that are independently sufficient

Where a property is enforced twice *by design*, no single mutation can falsify a contract above
it, and the row reads `⚠ never failed` for a contract doing real work.

Measured case: an application-level `where user_id == ^user_id` and Postgres row-level security
underneath it. Drop the `where` and RLS still filters; drop the RLS scope and the `where` still
does. The scoping postcondition fires only when **both** go — which is the only way the law is
actually breakable, and exactly the refactor you want it to notice.

This is the `⚠ never failed` row easiest to misread. Accidental double-guarding means delete one
and keep the contract; defence in depth means **keep both and mutate both together**. Concluding
"vacuous, delete it" removes the one thing that would notice a later refactor taking out both.

**"Redundant" is a conclusion, not an observation.** Establish it by removing the check and asking
what stops being true, in every build you ship — never by noticing that two things say the same
words. The other half of this trap is the purge test in the main `bond` rules: a guard whose
absence changes what the program *does* cannot be replaced by a `@pre`, which is compiled out.

### Mutate toward wrong values, not toward no values

`forall` over an empty enumerable is vacuously true, so a mutation making a collection *absent*
rather than *wrong* leaves the contract satisfied.

Real case: a scoping law over the connections a page lists. The obvious mutation — read them for a
random user id — returns `[]`, and the law holds. Proving it needed a mutation returning *another
user's* rows, which needed a second user in the fixtures. When the only realistic mutation empties
the collection, the missing piece is usually a fixture.

## Gotchas

  * **A shrunk counterexample may render a list of small integers as a charlist.**
    `[{:transformer, :apply_discount, ~c"e"}]` is showing you `[101]`. The rendering comes from
    ExUnitProperties, not Bond.
  * **Destructuring heads.** If a function destructures in its head, the generator for that
    argument must produce shape-matching values.
  * **Layered contracts fail-fast in execution order.** If a test asserts on *which* contract
    fired, target it by `label` (and `source_behaviour` for inherited ones) rather than relying
    on ordering.

<!-- bond:testing-end -->
<!-- errata-start -->
## errata usage
_Elixir library for structured error handling_

# Errata usage rules

Structured, named error handling. An Errata error is an ordinary `Exception` struct that can be
**returned as a value or raised**, carrying a `message`, a `reason` atom, a `context` map, a
`cause` (the error it wrapped), and an `env` (module, function, file, line, stacktrace).

Taken together, an application's error types are a named catalogue of the ways it can fail.

## Setup

```elixir
# mix.exs
{:errata, "~> 1.8"}
```

JSON encoding needs no configuration: on Elixir 1.18+ every error type implements the built-in
`JSON.Encoder`; if `jason` is present it implements `Jason.Encoder` too. Both emit the same shape.

In any module that creates or classifies errors:

```elixir
use Errata     # not `require` — this requires AND imports the three guards
```

## Rule 0: define error types in compiled code

**This is the trap that costs the most time, because it fails far from its cause.**

`use Errata.DomainError` and friends generate `String.Chars` and JSON protocol implementations,
and protocols are **consolidated when your project compiles**. A type defined after that point
gets none of them. Defining one in a `.exs` script, an `iex` session, or *inside a test module
body* produces three "protocol has already been consolidated" warnings at compile time, and then,
much later and somewhere else:

```
** (Protocol.UndefinedError) protocol String.Chars not implemented for %Bare{...}
```

Only the protocol paths break — `Errata.to_map/1` and the accessors work regardless — which is why
it can go unnoticed until something calls `to_string/1`.

Define error types in `lib/`. In tests, define fixture types at the **top level of the test file,
above the test module**, or set `consolidate_protocols: Mix.env() != :test` in `mix.exs`.

## Defining a type

Pick a kind. The kind decides how a **boundary** treats the error; the type decides how your
**domain logic** behaves.

```elixir
defmodule MyApp.Orders.PaymentDeclined do
  use Errata.DomainError,          # a business-rule violation, inside the problem domain
    default_message: "the payment was declined",
    reasons: [:insufficient_funds, :card_expired]
end

defmodule MyApp.Orders.GatewayTimeout do
  use Errata.InfrastructureError   # network, database — outside the problem domain
end

defmodule MyApp.UnexpectedError do
  use Errata.Error                 # kind :general — fits neither
end
```

Prefer `DomainError` and `InfrastructureError` over the base `Errata.Error`: the classification is
what lets a boundary route errors without knowing every type.

Every option is optional:

| Option | Purpose |
| --- | --- |
| `:default_message` / `:default_reason` | used when none is given |
| `:reasons` | declare the valid reasons — compile-time validated, and the basis of atom safety in `from_map/3` |
| `:http_status`, `:code`, `:severity`, `:retryable` | classifications consumed at a boundary |
| `:redact` | keep sensitive context out of logs and JSON |
| `:aggregate` | a type that carries several errors at once |

Declaring `:reasons` is worth doing by default. It catches typos at compile time, generates a
`reason/0` type, and is what makes decoding an error from the wire safe — a declared set turns
decoding into a lookup, so nothing from outside is ever atomised.

## Creating errors

Three ways, differing in setup and in whether they record where the error came from.

```elixir
# Default. Captures __ENV__ and the stacktrace into :env. One `use Errata` covers every type.
{:error, Errata.create(OrderNotFound, reason: :not_found, context: %{order_id: id})}

# Same thing, reads better when a module works mostly with one type. Needs `require OrderNotFound`.
{:error, OrderNotFound.create(reason: :not_found)}

# A plain function. No :env captured.
{:error, OrderNotFound.new(reason: :not_found)}
```

**Reach for `Errata.create/2` unless you have a reason not to.** The origin of an error is often
the most useful thing you have when debugging, and capturing it costs ~0.7 µs — negligible next to
anything that can fail.

`new/1` exists for the cases a macro cannot serve, and those are the only reasons to prefer it:

  * dynamic dispatch — `apply(OrderNotFound, :new, [params])`; a macro raises `UndefinedFunctionError`
  * capture — `&OrderNotFound.new/1`; capturing a macro freezes the capture site's env into every
    error it builds
  * tests and fixtures, where `env: nil` keeps structs easy to compare

`create` must be a macro, and cannot be reimplemented as a function that derives the call site
from the stacktrace: **tail-call optimisation drops the caller's frame**, so `e = Err.new(...); e`
would silently report the caller's caller.

Raising uses the same type:

```elixir
raise MyApp.Orders.OrderNotFound, reason: :not_found, context: %{order_id: 42}
```

## Wrapping: the cause chain

Wrap a lower-level failure rather than discarding it:

```elixir
rescue
  e -> {:error, Errata.wrap(MyApp.Orders.GatewayTimeout, e, stacktrace: __STACKTRACE__)}
```

A cause chain is Errata errors all the way down, optionally ending in **one foreign value** — a
bare atom, an `{:error, reason}` tuple, a standard exception. That shape decides which accessor
you want:

```elixir
Errata.root_error(error)                       # deepest ERRATA error — has code, context, classification
Errata.root_error(error) |> Errata.cause()     # the foreign original, or nil
Errata.format_chain(error)                     # the whole chain, stacktraces included, for a log
```

> **Do not hand-roll a recursive unwrap loop, and do not use `Errata.root_cause/1`** — it is
> deprecated precisely because it returns an Errata error *or* a foreign value depending on how the
> chain ends, so the caller has to work out which it got. Use `root_error/1` to render, report or
> classify; `cause/1` on it to diagnose what actually failed.

This is where a shared error library pays off: a `RetriesExhausted` from `external_service`
wrapping your own error, neither knowing about the other, still unwraps to "connection refused" —
which is the message a user can act on, where "could not be completed after 3 attempts" is not.

## Handling errors

The three guards are `defguard`s, so a module calling them **fully qualified still needs
`require Errata`**. `use Errata` does that for you and imports them unqualified:

```elixir
use Errata

case do_something() do
  {:error, e} when Errata.is_domain_error(e) -> render_to_user(e)
  {:error, e} when Errata.is_infrastructure_error(e) -> retry_later(e)
  {:error, e} when Errata.is_error(e) -> report(e)
  {:error, other} -> report_foreign(other)
end
```

### Every accessor raises on a non-Errata value

`reason/1`, `context/1`, `kind/1`, `code/1`, `severity/1`, `retryable?/1`, `http_status/1`,
`cause/1`, `root_error/1`, `display_message/1` — all of them raise `ArgumentError` when handed
something that is not an Errata error.

That matters because the boundary where you ask these questions is exactly the boundary where
other error shapes arrive. An Oban worker receiving `{:error, %Ecto.Changeset{}}` alongside your
own errors will **raise inside error handling** — the worst place for it, since it replaces a real
error with an unrelated one.

Two correct shapes:

```elixir
# Guard first
{:error, reason} when Errata.is_error(reason) ->
  if Errata.retryable?(reason), do: {:snooze, 60}, else: give_up(reason)

{:error, reason} ->
  give_up(reason)
```

```elixir
# Or normalise first, and treat everything uniformly
error = Errata.to_error(reason)
if Errata.retryable?(error), do: {:snooze, 60}, else: give_up(error)
```

### `display_message/1` returns `nil` when there is no message to show

Specifically, when the type declares no `:default_message` and none was given — verified on 1.8.0.
So call sites generally need a fallback: `Errata.display_message(e) || Exception.message(e)`.

Note also that `display_message/1` is written for one audience at a time. The same error may want
different phrasing in a background report and on the form the user is staring at — special-casing
at the call site is legitimate.

## At a boundary

`Errata.to_error/2` normalises any value into an Errata error, which is what makes a catch-all
handler possible. The recommended shape is your own `to_error/1` with ordinary clauses, so one
function shows how a boundary classifies errors:

```elixir
defmodule MyAppWeb.Errors do
  def to_error(%Ecto.Changeset{} = changeset),
    do: MyApp.ValidationFailed.new(reason: :invalid, cause: changeset)

  def to_error(other), do: Errata.to_error(other)
end
```

> **`{:error, reason}` tuples are not unwrapped.** `Errata.to_error({:error, :timeout})` normalises
> the *two-tuple itself*, because a value that legitimately is a two-tuple is indistinguishable
> from one meaning "error". Match the tuple at the call site:
> `{:error, reason} -> {:error, Errata.to_error(reason)}`.

Then route on classification rather than on type:

```elixir
conn |> put_status(Errata.http_status(error)) |> json(Errata.to_map(error))
```

`to_map/1` and both JSON encoders carry `kind`, `http_status`, `severity`, `retryable` and `code`,
so a consumer holding only the serialised error can still route on it. `Errata.from_map/3` rebuilds
one on the far side — the type is an argument, not read from the payload, and `:reasons` is what
keeps it safe.

## Reporting

```elixir
Errata.log(error)              # structured Logger metadata; level defaults to severity(error)
Errata.report(error)           # emits [:errata, :error] telemetry for your own handler
Errata.report(error, log: true)
```

Vendor-neutral — wire the telemetry event to Sentry or wherever errors should go. Use `:redact` on
types whose context can hold secrets; the library tells you to put arbitrary metadata in `context`
and then ships it to Logger, telemetry and JSON.

## Two things that will surprise you

**Structural guards are invisible to the Elixir type checker.** `is_error/1` matches on struct
shape, which does not refine a struct type, so `e.reason` after a bare `rescue` or guard warns on
1.18+. Use the accessors (`Errata.reason(e)`) or `Map.fetch!(e, :reason)`.

**Dialyzer's `:extra_return` flag is unusable in an Errata application.** Generated accessors are
specced to the behaviour's contract, not to one implementation — `code/1` is `String.t() | nil`
though a type declaring `code: "..."` only ever returns the string; `retryable?/1` is `boolean()`
though a domain error only ever returns `false`. The warning count grows with every error type
defined. Leave the flag off.

## Aggregates

For a type that carries several errors at once (validation, batch work), `use Errata.DomainError,
aggregate: true`. `Errata.errors/1` returns `[]` for an ordinary error rather than raising, so
calling code can treat every error uniformly instead of branching on `aggregate?/1` first:

```elixir
for member <- Errata.errors(error), do: Logger.warning(Exception.message(member))
```

<!-- errata-end -->
<!-- external_service-start -->
## external_service usage
_Elixir library for safely using any external service or API using automatic retry with rate limiting and circuit breakers. Calls to external services can be synchronous, asynchronous background tasks, or multiple calls can be made in parallel for MapReduce style processing._

# ExternalService usage rules

Safely calling external services with **retries**, a **circuit breaker**, **rate limiting**, and
a **concurrency limit** (bulkhead). You wrap the risky call in a function; all four protections
apply on every call.

## Setup

```elixir
# mix.exs
{:external_service, "~> 3.1"}
```

```elixir
# .formatter.exs — the guides use the paren-free `call fn -> ... end` idiom
import_deps: [:external_service]
```

Define a module per service, configure it declaratively, and **start it under a supervisor**:

```elixir
defmodule MyApp.Stripe do
  use ExternalService,
    retry: [max_attempts: 5, backoff: :exponential, base: 100, cap: 2_000, jitter: true],
    circuit_breaker: [tolerate: 5, within: :timer.seconds(30), reset: :timer.seconds(5)],
    rate_limit: [limit: 100, per: :timer.seconds(1), wait: :timer.seconds(1)]

  def charge(params) do
    call fn ->
      case Stripe.charge(params) do
        {:ok, result} -> {:ok, result}
        {:error, %{status: s}} when s in 500..599 -> {:retry, s}
        other -> other
      end
    end
  end
end
```

```elixir
children = [MyApp.Stripe]   # forgetting this is the #1 cause of "why isn't anything protected?"
Supervisor.start_link(children, strategy: :one_for_one)
```

A functional API exists too (`ExternalService.start/2` + `ExternalService.call/3` with a service
name atom), but the module front door is the recommended shape.

## The one rule about `call`

Everything hinges on what the function you pass to `call/1` returns:

| Return | Effect |
| --- | --- |
| `:retry` | retry |
| `{:retry, reason}` | retry, and record the reason |
| a value matched by the `:retry_on` predicate | retry, result recorded as the reason |
| **anything else** | **success — returned as-is** |
| a raised exception | propagates, unless matched by `:retry_exceptions` |

**"Anything else" includes `{:error, reason}`.** An error tuple is a successful call as far as
this library is concerned, and is handed straight back to you. If you want a failure retried, you
must say so — either by returning `:retry`/`{:retry, reason}`, or by declaring a `:retry_on`
predicate.

```elixir
call fn -> HTTP.get(url) end            # ❌ {:error, :timeout} is never retried
call fn ->
  case HTTP.get(url) do
    {:error, :timeout} -> :retry        # ✅
    other -> other
  end
end
```

## The traps

### Your HTTP client's own retries multiply against these

If the client you call inside `call/1` retries on its own, the two compound: `max_attempts: 3`
around a client doing 3 retries is up to 9 requests, with two independent backoff schedules
interleaved, and the breaker melting on a count you did not choose.

`Req` is the common case — it retries by default (`retry: :safe_transient`, which covers **GET
and HEAD only**, so a POST behaves differently from a GET under the same configuration). Turn the
client's retries off and let this library own the policy:

```elixir
Req.new(retry: false)
```

**Check this first whenever attempt counts do not match what you configured.**

### `max_attempts: 5` is a bound, not an allowance

With the default `base: 10` that is **150 ms of total waiting** — far too little for a real
dependency. For a service that is briefly overloaded, raise `:base`, not the attempt count:

```elixir
retry: [max_attempts: 5, base: 100, cap: 2_000, backoff: :exponential, jitter: true]
```

`max_attempts: :infinity` retries forever, and **the circuit breaker does not reliably stop it**.

### Circuit-breaker `:tolerate` counts failed *attempts*, not failed calls

Retries melt the breaker too, so a call with `max_attempts: 5` can contribute five melts on its
own. `tolerate ≈ failing calls × max_attempts` is the arithmetic to have in mind.

And the window has to be wide enough to *contain* those melts. If one call's retry schedule
spans 7.5 s and you need 6 calls to open the breaker, the melts spread over ~37.5 s — so a
`within: 30_000` breaker **never opens**, silently, with nothing raising and no log line.

Do not hand-tune this. Ask the library:

```elixir
IO.puts ExternalService.explain(MyApp.Stripe)          # what will this configuration do?
ExternalService.simulate(MyApp.Stripe, :always_failing) # does the breaker actually open?
#=> %Simulation{opens_after: 4, worst_call: 1500, attempts: 20, ...}
ExternalService.RetryOptions.window(base: 100, max_attempts: 5)  #=> 1500
```

Both `explain/1` and `simulate/3` also accept a proposed keyword list, so you can check a
configuration before shipping it. `ExternalService.ConfigCheck` runs the same reasoning at
compile time and at start, and warns with the arithmetic shown.

### `:wait` for the rate limiter depends on *where the call is made*, not on the service

This is the rule to internalise, because the wrong answer sheds traffic silently.

A limiter check never quotes more than one emission interval (`per / limit`), and the default
`:wait` budget is one window capped at 5 s. At `limit: 1, per: 2_000` those are both 2000 ms, so
a single re-check exhausts the budget and the service sheds on the slightest contention instead
of pacing.

  * **Background work** — an Oban job, a Flow pipeline, a bulk transfer: `wait: :infinity`.
    Sleeping *is* the back-pressure, and there is no user waiting.
  * **A request path** — a page load, a LiveView event: a finite budget, so a slow dependency
    turns into a fast error rather than a hung request.
  * `wait: false` fails immediately. It never melts the breaker and is never retried.

The same call configured for the wrong side of that line is the single most common
misconfiguration.

### Not every failure melts the breaker or gets retried

| Error | Melts breaker? | Retried? |
| --- | --- | --- |
| `%ExternalService.RetriesExhausted{}` | the attempts did | — |
| `%ExternalService.CircuitBreakerOpen{}` | n/a — it is already open | no |
| `%ExternalService.RateLimited{}` (http_status 429) | **no** | **no** |
| `%ExternalService.ServiceSaturated{}` (http_status 503) | **no** | **no** |

Shedding is not failing. Treating a `RateLimited` as a service outage — melting, retrying, or
tripping an alert — is a misreading.

### The concurrency limit sheds; it does not queue

```elixir
concurrency: [limit: 25, reclaim_after: :timer.seconds(30), wait: 50]
```

Over the limit, calls return `ServiceSaturated` rather than queueing. A short `:wait` absorbs
bursts; `:infinity` is **rejected** for the bulkhead (a quota refills on its own, but a slot
frees only when another call finishes). `:reclaim_after` must exceed your client timeout, or
slots are reclaimed from calls that are still running.

### Both the breaker and the limiter are node-local by default

N nodes means up to N × `limit` calls, and each node trips its breaker on its own. If the quota
is imposed per-account rather than per-node, you need a shared backend:

```elixir
rate_limit: [limit: 100, per: 1_000,
             backend: {ExternalService.RateLimiter.Hammer, module: MyApp.RateLimit}]

circuit_breaker: [tolerate: 5, backend: ExternalService.CircuitBreaker.Cluster]
```

### Errors are Errata errors, and the useful message is usually underneath

`RetriesExhausted`'s own message describes *our* reaction — "the request could not be completed
after 3 attempts" — which is true and rarely actionable. The failure a user can do something
about is the `:cause`:

```elixir
# the deepest Errata error — has a code, a context and a classification to render or report
Errata.root_error(error)

# the foreign original underneath it — :econnrefused, an %Mint.TransportError{}, ... or nil
Errata.root_error(error) |> Errata.cause()
```

That turns "could not be completed after 3 attempts" into "connection refused", and works across
library boundaries — `RetriesExhausted` wraps your error and neither knows about the other.

Do not hand-roll a recursive unwrap loop, and do not reach for `Errata.root_cause/1`: it is
deprecated because it returns an Errata error *or* a foreign value depending on how the chain
ends, leaving the caller to work out which it got. See the [Using Errata](guides/errata.md) guide — an application's own Errata
errors can also drive retries via `:retry_on` and `retryable?/1`, which puts the retry decision
in the error type rather than in a branch on the shape of what came back.

## Calling

```elixir
MyApp.Api.call(fn -> work() end)
MyApp.Api.call([max_attempts: 2], fn -> work() end)   # per-call retry overrides
MyApp.Api.call!(fn -> work() end)                      # raises instead of returning {:error, _}

task = MyApp.Api.call_async(fn -> work() end)          # Task
ids |> MyApp.Api.call_async_stream(fn id -> fetch(id) end) |> Enum.to_list()
```

Handle the outcome by error type, not by string:

```elixir
case MyApp.Api.fetch(id) do
  {:ok, v} -> v
  {:error, %ExternalService.RetriesExhausted{}} -> degrade()
  {:error, %ExternalService.CircuitBreakerOpen{}} -> degrade()
  {:error, %ExternalService.RateLimited{}} -> shed()
  {:error, reason} -> {:error, reason}       # your own error, passed through
end
```

## Retry options

```elixir
retry: [
  backoff: :exponential,          # or :linear
  base: 100,                      # initial delay ms (default 10 — usually too small)
  cap: :timer.seconds(2),         # max single delay
  max_attempts: 5,                # default; or :infinity
  expiry: :timer.seconds(10),     # total time budget; or :infinity
  jitter: true,                   # ±10%, or a float proportion
  retry_on: &match?({:error, %{status: 500}}, &1),   # predicate over the result
  retry_exceptions: [MyApp.TransientError]           # modules, or a predicate on the exception
]
```

`:retry_on` is how you retry the result of a function you cannot modify. `:retry_exceptions` is
how you retry something that raises — by default a raised exception propagates untouched.

Turn a protection off explicitly rather than omitting the mechanism:
`circuit_breaker: [tolerate: :infinity]` (never opens, holds no state) and
`rate_limit: [limit: :infinity, per: 1_000]`.

## Introspection

```elixir
MyApp.Api.available?()      # breaker closed?
MyApp.Api.blown?()          # breaker open?
MyApp.Api.reset()           # force closed
ExternalService.rate_limited?(:api)         # boolean, consumes no budget
ExternalService.saturated?(:svc)
ExternalService.Concurrency.in_flight(:svc)
```

## Telemetry

```text
[:external_service, :call, :start | :stop | :exception | :retry]
[:external_service, :circuit_breaker, :blown]
[:external_service, :rate_limit, :sleep]
[:external_service, :concurrency, :rejected | :waited]
```

`[:call, :retry]` fires **per attempt**, so it is a count of attempts and not of calls — worth
remembering when building a dashboard.

## Testing

`ExternalService.Test` provides assertions over those events. They need a handler attached before
the call, so record explicitly:

```elixir
defmodule MyApp.ApiTest do
  use ExUnit.Case
  use ExternalService.Test

  setup :record_events

  test "a 500 is retried" do
    # ... exercise the call ...
    assert_retried(MyApp.Api)
  end
end
```

`ExternalService.Test.Coverage` reports which protections each service actually exercised across
a suite — useful for finding a breaker or limiter that is configured but never reached.

Note that a `wait: false` rate limit never sleeps, so it emits no `[:rate_limit, :sleep]` event —
if your tests configure it that way, that signal is absent by construction.

## When configuration and reality disagree

Reach for these in order, before changing numbers:

1. `ExternalService.explain(MyApp.Api)` — states the *consequence* of each setting, not the
   setting.
2. `ExternalService.simulate(MyApp.Api, :always_failing)` — a virtual clock; nothing sleeps.
3. Check whether your HTTP client is retrying underneath you.

Fixing one shedding path can simply move the shedding to another — a limiter and a concurrency
limit can both shed the same call — which is why `explain/1` lists all of them at once.

<!-- external_service-end -->
<!-- wait_for_it-start -->
## wait_for_it usage
_Elixir library providing various ways of waiting for things to happen_

# WaitForIt usage rules

Waiting on asynchronous or remote work, using syntax built on Elixir's own control-flow
constructs. Most useful in tests that must wait for concurrent activity, and anywhere processes
coordinate.

```elixir
{:ok, user} = WaitForIt.match_wait({:ok, %User{}}, Repo.fetch(User, id), timeout: 2_000)
```

`require WaitForIt` or `import WaitForIt` before using any of it — the five waiting forms are
macros.

## The one rule

> On timeout, each form behaves exactly as its built-in Elixir counterpart would on a final
> evaluation in which nothing matched.

That is the whole design. There is nothing WaitForIt-specific to memorise: a `case_wait` that
times out raises `CaseClauseError` for the same reason a `case` does; a `with_wait` returns the
last unmatched value for the same reason a `with` does.

| Form | Waits until | Native counterpart | On timeout (no `else`) |
| --- | --- | --- | --- |
| `wait/2` | an expression is truthy | truthiness | returns the last falsy value |
| `match_wait/3` | an expression matches a pattern (and binds out of it) | `=` | raises `MatchError` |
| `case_wait/3` | one of several clauses matches | `case` | raises `CaseClauseError` |
| `cond_wait/2` | one of several expressions is truthy | `cond` | raises `CondClauseError` |
| `with_wait/3` | several composed waits all succeed | `with` | returns the last value |

Two consistent additions:

  * An **`else` clause** (on `case_wait`, `cond_wait`, `with_wait`) turns a timeout into a value.
  * A **`!` variant** of every form (`wait!/2`, `match_wait!/3`, …) replaces whatever the
    non-bang form would do with a uniform `WaitForIt.TimeoutError`.

## Options

Every form takes the same ones:

| Option | Default | Meaning |
| --- | --- | --- |
| `:timeout` | `5_000` | total ms to wait before giving up, or `:infinity` |
| `:interval` | `100` | ms between re-evaluations, or a `WaitForIt.Backoff` function |
| `:pre_wait` | `0` | ms to wait before the first evaluation |
| `:signal` | — | disable polling; re-evaluate only when this signal arrives |

Use `:interval`. `:frequency` is a deprecated alias kept for compatibility and slated for
removal in a future major — do not write it in new code.

## The traps

### Waiting blocks the calling process — never wait inside a GenServer callback

A wait is a polling loop in the caller's own process. While it runs, that process does nothing
else.

```elixir
def handle_call(:fetch, _from, state) do
  # ❌ the entire server is blocked for up to 5 seconds; every other caller queues behind this
  {:ok, v} = WaitForIt.match_wait({:ok, _}, remote_fetch(), timeout: 5_000)
  {:reply, v, state}
end
```

Worse, the defaults collide: `WaitForIt`'s default `:timeout` is 5000ms and `GenServer.call/3`'s
default timeout is also 5000ms, so the caller gives up at almost exactly the moment the wait
does — you get a confusing `:timeout` exit from the *caller* rather than the wait's own timeout
behaviour.

Wait in the process that can afford to block: the caller, a `Task`, or a test. If a server must
wait, do it in a spawned task and `handle_info` the result.

### Signals are node-local

`signal/1` dispatches through a local `Registry`, so a signal sent on one node never reaches a
waiter on another. In a distributed application, a wait blocked on `signal: :thing` will sit
there until its timeout while the producer on another node happily signals into the void.

Polling has no such limitation — it re-evaluates the expression, and the expression can consult
anything (a database, a replicated table, a `:global` process). **If the condition can be
changed from another node, poll.**

### Never write a catch-all clause in `case_wait` or `cond_wait`

This is the single most common mistake, and it silently disables the waiting.

```elixir
# ❌ `_` matches on the very first evaluation, so this never waits at all
WaitForIt.case_wait Repo.get(Job, id) do
  %Job{status: :done} -> :finished
  _ -> :not_yet
end

# ✅ `else` runs only on timeout
WaitForIt.case_wait Repo.get(Job, id), timeout: 10_000 do
  %Job{status: :done} -> :finished
else
  _ -> :gave_up
end
```

The same applies to a final `true ->` in `cond_wait`. A clause that always matches halts the
wait on the first evaluation; `else` is evaluated *only* when the wait gives up.

### The expression is re-evaluated, so its side effects must be repeatable

A waitable expression runs an indeterminate number of times. An idempotent expression is useless
here — it either halts immediately or never halts — so it is *expected* that the value changes
between evaluations, and any side effect must be safe to repeat. Do not put a POST, an insert, or
a counter increment in a waitable expression.

### `timeout: :infinity` removes all timeout behaviour

Not just "waits longer". Because such a wait can never time out: a `!` variant never raises, an
`else` clause never runs, and `until/2` never returns `{:timeout, last_value}`. The process
blocks until the condition is met or it dies. Reach for it only where something else bounds the
wait — a supervised process, a `Task` with its own timeout, or a caller that can shut it down.

### `with_wait` uses two different arrows

```elixir
WaitForIt.with_wait on(
  {:ok, account} <~ {load_account(token), timeout: 2_000},   # WAITS for the match
  {:ok, balance} <- fetch_balance(account)                    # one-shot, exactly like `with`
) do
  {:ok, balance}
else
  not_ready -> {:error, {:timed_out, not_ready}}
end
```

`<~` is wait-for-match; `<-` behaves exactly as in a native `with`. Per-clause options go in a
tuple: `{expr, opts}`. Note the `on(...)` wrapper — it is the one place the "looks like the
native construct" resemblance breaks.

### "The following clause will never match" is telling the truth

On Elixir 1.20+ you may see the type checker flag a `match_wait`/`with_wait` pattern as
unreachable. **Waiting changes values over time; it does not change types.** If the expression's
inferred type cannot produce the pattern, the wait can only ever time out, and the warning has
found a real bug.

The usual innocent cause is a test stub narrow enough for the compiler to pin down
(`defp pending, do: :pending` infers exactly `:pending`). Widen it rather than silencing the
warning:

```elixir
defp pending, do: Process.get(:__unset__, :pending)   # same value, type is now dynamic()
```

## Choosing a form

**`match_wait/3`** is the one to reach for by default when waiting on a tagged result — it waits
and binds in one expression.

**`until/2`** is the functional counterpart of `wait/2`, for when the condition is computed at
runtime or built dynamically and a macro cannot serve. It takes a zero-arity function and returns
a *tagged* result, so success and timeout are never ambiguous:

```elixir
case WaitForIt.until(fn -> Repo.get(Post, id) end, timeout: :timer.seconds(5)) do
  {:ok, post} -> post
  {:timeout, _last} -> raise "post #{id} never appeared"
end
```

`until!/2` returns the bare value and raises `WaitForIt.TimeoutError` instead.

## Polling and backoff

Polling is the default: re-evaluate every `:interval` ms. `:interval` also accepts a 1-arity
function of the attempt number, which is how you back off against a struggling dependency:

```elixir
WaitForIt.wait(Service.ready?(), interval: WaitForIt.Backoff.exponential(cap: 2_000, jitter: true))
```

Signal-based waiting removes the polling loop entirely — a waiter blocks until it receives a
named signal telling it to re-evaluate:

```elixir
# consumer
WaitForIt.wait(Buffer.count() >= 4, signal: :buffer_filled)

# producer, after changing the condition
Buffer.put(item)
WaitForIt.signal(:buffer_filled)
```

A signal does **not** mean the condition is now satisfied — only that waiters should re-check.
Both sides must agree on the signal name, and both must be on the same node.

## In tests

Prefer `WaitForIt.Test`'s assertions over `Process.sleep/1`. They wait, re-evaluate, and on
timeout fail with an ordinary `ExUnit.AssertionError` carrying the source expression and the last
value seen:

```elixir
defmodule MyApp.SomeTest do
  use ExUnit.Case
  use WaitForIt.Test

  test "the user is eventually confirmed" do
    assert_eventually {:ok, %User{confirmed: true}} = Repo.fetch(User, user_id)
  end
end
```

`assert_eventually/2` (truthy or `pattern = expr` binding form), `refute_eventually/2`, and
`assert_always/2` — the last for asserting something stays true for the duration rather than
becomes true.

The waiting macros work in tests too when you want their exact return values or timeout
semantics; `wait/2` returns its value and drops straight into an `assert`.

## Telemetry

Every wait emits `[:wait_for_it, :wait, :start | :stop | :exception]`. The `:stop` event reports
the `duration`, the number of `evaluations`, and whether the wait `:matched` or hit a `:timeout`
— which is how you find waits that are quietly timing out, or polling far more than they need to.

## Deprecated

`WaitForIt.V1` emits compile-time deprecation warnings and will be removed in 3.0. Do not write
new code against it.

<!-- wait_for_it-end -->
<!-- phoenix:ecto-start -->
## phoenix:ecto usage
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied

<!-- phoenix:ecto-end -->
<!-- phoenix:elixir-start -->
## phoenix:elixir usage
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages


<!-- phoenix:elixir-end -->
<!-- phoenix:html-start -->
## phoenix:html usage
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>

<!-- phoenix:html-end -->
<!-- phoenix:liveview-start -->
## phoenix:liveview usage
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @streams.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset

<!-- phoenix:liveview-end -->
<!-- phoenix:phoenix-start -->
## phoenix:phoenix usage
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it

<!-- phoenix:phoenix-end -->
<!-- usage-rules-end -->
