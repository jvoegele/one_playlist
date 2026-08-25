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

## Setup

```elixir
# mix.exs
{:bond, "~> 1.17"},
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
of a sequence (the value the caller keeps) is never validated. Verified against 1.16.0. If your
function returns the struct under a different wrapper, restate the law as a `@post`:

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

**Do not write:**

  * **Type checks** — use `@spec`. ExDoc renders it more prominently, Dialyzer checks it, and it
    costs nothing at runtime. Exception: when violating it produces a confusing crash somewhere
    else, a `@pre` converts that into a named violation identifying the caller.
  * **A `@pre` a guard already enforces.** Bond reproduces your `when` guards on the wrapper
    clauses, so a failing argument raises `FunctionClauseError` *before* any precondition runs —
    the assertion is unreachable. A `@pre` **stronger** than the guard is a different matter and
    worth keeping.
  * **Assertions about data from outside your system.** A provider sending nonsense is not a
    programming error, and a `@post` that raises on it converts their bad data into your crash.
    At a parsing boundary, **assert what you emit, never what you received.**
  * **A precondition your caller cannot evaluate.** A public function's `@pre` must not call a
    `defp` — Bond warns, citing Meyer's Precondition Availability rule. `@doc false` on the
    predicate defeats it the same way, because the obligation is published in terms the reader
    cannot look up. Postconditions are exempt: they are the function's promise, not the caller's
    obligation.

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

| Layer | Contract? |
| --- | --- |
| Domain structs, parsers | **Yes** — external data lands here, poison values start here |
| Behaviour `@callback`s | **Yes, declare once** — inherited by every implementation |
| Pure core / transformation modules | **Yes** — the interesting laws live here |
| HTTP clients, adapters facing a service you don't control | **No** — they return `{:error, _}`; they are filters, not demanding modules |
| Persistence contexts | Sparingly — the laws usually belong on the struct |
| Controllers / LiveViews | **No** — assert in tests; a violation in a request path is a 500 |

The seam matters: **the postconditions of your filter modules must match or exceed the
preconditions of the modules behind them.**

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
| The body guards the property twice | Delete the redundant guard, keep the contract |
| It is a true law of a pure function | Keep it — prove it by **mutation**, not by a test |

The third is the common case, and in a mature codebase **most rows will read `⚠ never failed`**.
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
<!-- nebulex:architecture-start -->
## nebulex:architecture usage
# Nebulex Architecture

This guide explains why Nebulex exists, who uses it, how it is structured
internally, and the non-negotiable design principles that govern every
contribution. Read it at session start to establish project context, and
refer back to it when making structural changes.

---

## Why Nebulex Exists

Elixir applications need caching. But caching backends — Redis, local ETS,
Memcached, Cachex, distributed cluster caches — each have their own APIs,
semantics, and failure modes. Without an abstraction layer, teams either
lock themselves into a single backend or scatter adapter-specific code
throughout their application.

Nebulex solves this the same way [Ecto][ecto] solved it for databases:
a **unified caching abstraction** that lets you swap backends, compose
topologies, and add declarative caching to any function — without changing
application code.

> "Give users explicit control over failure handling, while keeping the
> API ergonomic." — core design principle established in v3

Nebulex has been in production since 2017. It serves read-heavy workloads,
configuration caching, session management, and high-concurrency scenarios
across local, distributed, and hybrid cache setups.

[ecto]: https://github.com/elixir-ecto/ecto

---

## Who Uses It

Nebulex is used by Elixir teams who need:

- **Backend flexibility** — switch from a local ETS cache in development to
  Redis or a distributed cluster in production without changing application
  code.
- **Declarative caching** — annotate functions with `@decorate cacheable(...)`,
  `@decorate cache_put(...)`, or `@decorate cache_evict(...)` and let Nebulex
  handle the cache lifecycle automatically.
- **Composed topologies** — layer a local cache in front of a Redis cache, or
  run a coherent local cache with distributed invalidation, without writing
  topology-specific code.
- **Graceful degradation** — handle cache infrastructure failures (timeouts,
  connection drops, cluster failovers) differently from database failures,
  because a cache outage often permits fallback to the source of record.

---

## High-Level Architecture

Nebulex is organized into three distinct layers:

```ascii
+-------------------------------------------------------------+
|                     Application Layer                       |
|         (your modules using Nebulex.Cache API or            |
|          declarative caching decorators)                    |
+-------------------------------------------------------------+
                           |
+------------------------------------------------------------+
|                      Core Layer                            |
|                                                            |
|  +------------------+   +-------------------------------+  |
|  |  Nebulex.Cache   |<--|     Nebulex.Caching           |  |
|  |  (public API)    |   |  (declarative decorators)     |  |
|  +------------------+   +-------------------------------+  |
|            |                                               |
|            v                                               |
|  +-------------------------------------------------------+ |
|  |           Nebulex.Adapter behaviours                  | |
|  |  (KV, Queryable, Transaction, Observable, Info)       | |
|  +-------------------------------------------------------+ |
+------------------------------------------------------------+
                           |
+------------------------------------------------------------+
|                     Adapter Layer                          |
|  (separate packages: nebulex_local, nebulex_distributed,   |
|   nebulex_redis_adapter, nebulex_adapters_cachex, etc.)    |
+------------------------------------------------------------+
```

### Core Layer — `lib/nebulex/`

The core package provides the abstraction. It contains no production cache
implementation; all storage logic lives in adapters.

| Module | Responsibility |
|---|---|
| `Nebulex.Cache` | Public API macro — `use Nebulex.Cache` generates the full cache API for a module |
| `Nebulex.Cache.KV` | Key-value operations: `fetch`, `get`, `put`, `delete`, `take`, etc. |
| `Nebulex.Cache.Queryable` | Query-based operations: `get_all`, `count_all`, `delete_all` |
| `Nebulex.Cache.Transaction` | Optimistic locking and transactional operations |
| `Nebulex.Cache.Observable` | Event streaming for cache entry changes |
| `Nebulex.Cache.Info` | Stats and monitoring (`info/2`) |
| `Nebulex.Cache.Options` | NimbleOptions-based validation for all cache options |
| `Nebulex.Cache.Supervisor` | OTP supervision tree for cache processes |
| `Nebulex.Cache.Registry` | Registry for dynamic caches |
| `Nebulex.Adapter` | Adapter behaviour definition and shared macros |
| `Nebulex.Adapter.KV` | Callback spec for KV operations |
| `Nebulex.Adapter.Queryable` | Callback spec for query operations |
| `Nebulex.Adapter.Transaction` | Callback spec for transaction operations |
| `Nebulex.Adapter.Observable` | Callback spec for event streaming |
| `Nebulex.Adapter.Info` | Callback spec for stats/info |
| `Nebulex.Caching` | Entry point for declarative caching (`use Nebulex.Caching`) |
| `Nebulex.Caching.Decorators` | `cacheable`, `cache_put`, `cache_evict` decorator implementations |
| `Nebulex.Caching.Decorators.Runtime` | Runtime evaluation of cache operations, key generation, match logic |
| `Nebulex.Caching.Decorators.Context` | Per-invocation decorator context (function name, args, decorator type) |
| `Nebulex.Telemetry` | Telemetry span events emitted by cache operations |
| `Nebulex.Event` | Cache entry event types for the Observable API |

### Adapter Layer — separate packages

Each adapter is its own Hex package. The core package ships only with
`Nebulex.Adapters.Nil` (a no-op adapter used for benchmarking the abstraction
layer itself) and `Nebulex.Adapters.Common.Info.Stats` (shared stats helpers).

For the canonical list of official adapters (package names, modules,
and Hex/GitHub links), see `guides/introduction/nbx-adapters.md`. That
guide is the single source of truth — do not maintain a parallel list here.

### Declarative Caching — `Nebulex.Caching`

Declarative caching is built on the [`decorator`][decorator-lib] library.
`use Nebulex.Caching` registers three function decorators:

- `cacheable` — read-through: skip execution on cache hit, populate on miss
- `cache_put` — write-through: always execute, always update the cache
- `cache_evict` — invalidation: execute and remove entries from the cache

The decorator macro captures key expressions and option lambdas as AST at
compile time and inlines them into generated wrapper functions. All runtime
resolution (key generation, cache selection, match evaluation) happens in
Nebulex.Caching.Decorators.Runtime.

[decorator-lib]: https://github.com/arjan/decorator

---

## Key Design Decisions

### ok/error tuples everywhere

All cache operations return `{:ok, value}` or `{:error, reason}` by default.
Bang variants (`fetch!/2`, `put!/3`, etc.) are available for fail-fast
semantics. This was a deliberate v3 decision: cache infrastructure failures
should be handled explicitly at each call site, not swallowed silently.

### Adapters are decoupled — always

The core package has no runtime dependency on any adapter package. Adapters
depend on core, never the reverse. The adapter callback specs (`Nebulex.Adapter.*`)
define the contract; the core enforces it at compile time via behaviours.

This decoupling means adapters evolve independently. A breaking change in an
adapter does not require a core release. New adapters can be published by
anyone without touching the core repository.

### Optional dependencies

No dependency in `mix.exs` is required. `:telemetry`, `:decorator`, and all
adapters are optional. This keeps the core footprint minimal for users who
only need a subset of features. If a dependency is absent, the feature it
enables is simply unavailable (no runtime error, no silent failure).

### NimbleOptions for all option validation

Every public option set — cache options, decorator options, adapter-specific
options — is validated through [NimbleOptions][nimble_options] schemas. This
produces consistent, actionable error messages at compile time or startup,
rather than cryptic runtime failures.

[nimble_options]: https://hexdocs.pm/nimble_options

### Telemetry as the observability contract

The core emits consistent `[:nebulex, :cache, <operation>, :start/stop/exception]`
Telemetry span events for every cache operation, regardless of which adapter
is in use. Adapters may emit additional events but must not suppress or
redefine core events. This guarantees that monitoring dashboards and
telemetry handlers work across backend switches.

### Nil is a valid cache value

Since v3, `nil` can be cached. The sentinel-value restriction from v2 (where
`nil` meant "cache miss") is gone. Match functions control whether a result
is cached, giving developers explicit control over nil caching.

---

## Non-Negotiables

These rules are not open for debate. Any contribution that violates them
will not be merged, regardless of other merits.

### 1. Adapters must remain decoupled from core

The core package must not import, alias, or depend on any adapter module at
runtime. Shared utilities belong in `Nebulex.Adapters.Common.*` within the
core, not in adapter packages. If you find yourself adding an adapter-specific
module to the core, stop and reconsider.

### 2. No breaking public API changes without a major version

`Nebulex.Cache`, `Nebulex.Caching`, and all `Nebulex.Adapter.*` callback specs
are public API. Removing or renaming public functions, changing callback
signatures, or altering option semantics requires a major version bump
(`v3.x` → `v4.0`). Deprecation warnings must precede removals by at least
one minor release.

### 3. Every public function must have a `@doc` and typespec

Module documentation (`@moduledoc`) is required for every module. Public
functions require `@doc` and `@spec`. This is enforced by `mix doctor` in CI
and is not optional. Undocumented public API will not be merged.

### 4. New behaviour must have tests

Any new feature, option, or code path must be accompanied by tests. For
adapter-facing changes, tests belong in `test/shared/` using the `deftests`
macro so the shared test suite covers all adapters consistently. For
core-only changes, tests belong in `test/nebulex/`. A PR without tests for
new behaviour will not be merged.

### 5. `mix test.ci` must pass

All changes must pass the full CI suite locally before opening a PR:

```bash
mix test.ci
```

This runs tests, coverage, Credo (strict), Dialyzer, Sobelow, and `mix doctor`.
Green CI on the PR is a requirement, not a courtesy check.

### 6. Keep this document up to date

After any structural change — new module, new adapter callback, new public
option, new dependency, or changes to the layer boundaries — review this
document and update it if needed. Architecture docs rot when nobody owns them.
This is not a checkbox on every PR, but a conscious check: "did my change
affect the architecture described here?"

### 7. `mix docs` must produce no warnings

Documentation must build cleanly:

```bash
mix docs
```

No warnings are acceptable. Common causes: referencing hidden modules with
backtick syntax, broken links, or missing `@doc`/`@moduledoc`. Fix the root
cause — do not suppress warnings.

---

## Source of Truth Hierarchy

When in doubt about intent, consult these sources in order:

1. `usage-rules/workflow.md` — contribution workflow and rule precedence
2. This document — architectural decisions and non-negotiables
3. `usage-rules/nebulex.md` — domain-specific patterns and pitfalls
4. Module `@moduledoc` and function `@doc` — local intent for each API
5. `CHANGELOG.md` — history of decisions and the reasoning behind them
6. The blog post ["Nebulex v3: A New Chapter for Caching in Elixir"][v3-post]
   for the philosophy behind the v3 redesign

[v3-post]: https://medium.com/erlang-battleground/nebulex-v3-a-new-chapter-for-caching-in-elixir-03cd366692c3

<!-- nebulex:architecture-end -->
<!-- nebulex:elixir-start -->
## nebulex:elixir usage
# Elixir Core Usage Rules

## Pattern Matching

- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling

- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`
- Bang functions (`!`) that explicitly raise exceptions on failure are acceptable (e.g., `File.read!/1`, `String.to_integer!/1`)
- Avoid rescuing exceptions unless for a very specific case (e.g., cleaning up resources, logging critical errors)

## Common Mistakes to Avoid

- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design

- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures

- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing

- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!--
The following rules are sourced from [Phoenix Framework](https://github.com/phoenixframework/phoenix),
with modifications and additions.

Copyright (c) 2014 Chris McCord, licensed under the MIT License.
-->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, i.e.:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, i.e.:

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
- Elixir's built-in OTP primitives, such as `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Extra Elixir guidelines

- The `in` operator in guards requires a compile-time known value on the right side (literal list or range)

  **Never do this (invalid)**: using a variable which is unknown at compile time

      def t(x, y) when x in y, do: {x, y}

  This will raise `ArgumentError: invalid right argument for operator "in", it expects a compile-time proper list or compile-time range on the right side when used in guard expressions`

  **Valid**: use a known value for the list or range

      def t(x, y) when x in [1, 2, 3], do: {x, y}
      def t(x, y) when x in 1..10, do: {x, y}

- In tests, avoid using `assert` with pattern matching when the expected value is fully known. Use direct equality comparison instead for clearer test failures

  **Avoid**:

      assert {:ok, ^value} = testing()
      assert {:error, :not_found} = fetch()

  **Prefer**:

      assert testing() == {:ok, value}
      assert fetch() == {:error, :not_found}

  **Exception**: Pattern matching is acceptable when you only want to assert part of a complex structure

      # OK: asserting only specific fields of a large struct/map
      assert {:ok, %{id: ^id}} = get_order()

- In tests, avoid duplicating test data across multiple tests. Use constants, fixture files, or private fixture functions instead

  **Avoid**: Duplicating test data

      test "validates user email" do
        assert valid_email?("user@example.com")
      end

      test "creates user" do
        assert create_user("user@example.com")
      end

  **Prefer**: Use module attributes for constants or fixture functions

      @valid_email "user@example.com"

      test "validates user email" do
        assert valid_email?(@valid_email)
      end

      test "creates user" do
        assert create_user(@valid_email)
      end

  For complex data structures, create fixture functions:

      defp user_fixture(attrs \\ %{}) do
        %User{
          name: "John Doe",
          email: "john@example.com",
          age: 30
        }
        |> Map.merge(attrs)
      end

<!-- nebulex:elixir-end -->
<!-- nebulex:elixir-style-start -->
## nebulex:elixir-style usage
# Elixir Style

> Most of these guidelines are based on
> [The Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide)
> by Christopher Adams, licensed under
> [CC-BY-3.0](https://creativecommons.org/licenses/by/3.0/).

## Formatting

### Whitespace

- Use blank lines between `def`s to break up a function into logical paragraphs.
  For example:

  ```elixir
  def some_function(some_data) do
    some_data |> other_function() |> List.first()
  end

  def some_function do
    result
  end

  def some_other_function do
    another_result
  end

  def a_longer_function do
    one
    two

    three
    four
  end
  ```

- If the function head and `do:` clause are too long to fit on the same line, put `do:` on a new line, indented one level more than the previous line. For example:

  ```elixir
  def some_function([:foo, :bar, :baz] = args),
    do: Enum.map(args, fn arg -> arg <> " is on a very long line!" end)
  ```

  When the `do:` clause starts on its own line, treat it as a multiline function by separating it with blank lines.

  ```elixir
  # not preferred
  def some_function([]), do: :empty
  def some_function(_),
    do: :very_long_line_here

  # preferred
  def some_function([]), do: :empty

  def some_function(_),
    do: :very_long_line_here
  ```

- Add a blank line after a multiline assignment as a visual cue that the assignment is 'over'. For example:

  ```elixir
  # not preferred
  some_string =
    "Hello"
    |> String.downcase()
    |> String.trim()
  another_string <> some_string

  # preferred
  some_string =
    "Hello"
    |> String.downcase()
    |> String.trim()

  another_string <> some_string
  ```

  ```elixir
  # also not preferred
  something =
    if x == 2 do
      "Hi"
    else
      "Bye"
    end
  String.downcase(something)

  # preferred
  something =
    if x == 2 do
      "Hi"
    else
      "Bye"
    end

  String.downcase(something)
  ```

### Parentheses

- Use parentheses when defining a type.

  ```elixir
  # not preferred
  @type name :: atom

  # preferred
  @type name() :: atom
  ```

## General guidelines

The rules in this section may not be applied by the code formatter, but they are generally preferred practice.

### Expressions

- Keep single-line `def` clauses of the same function together, but separate multiline `def`s with a blank line. For example:

  ```elixir
  def some_function(nil), do: {:error, "No Value"}
  def some_function([]), do: :ok

  def some_function([first | rest]) do
    some_function(rest)
  end
  ```

- If you have more than one multiline `def`, do not use single-line `def`s. For example:

  ```elixir
  def some_function(nil) do
    {:error, "No Value"}
  end

  def some_function([]) do
    :ok
  end

  def some_function([first | rest]) do
    some_function(rest)
  end

  def some_function([first | rest], opts) do
    some_function(rest, opts)
  end
  ```

- Use the pipe operator to chain functions together. For example:

  ```elixir
  # not preferred
  String.trim(String.downcase(some_string))

  # preferred
  some_string |> String.downcase() |> String.trim()

  # Multiline pipelines are not further indented
  some_string
  |> String.downcase()
  |> String.trim()

  # Multiline pipelines on the right side of a pattern match
  # should be indented on a new line
  sanitized_string =
    some_string
    |> String.downcase()
    |> String.trim()
  ```

- Avoid using the pipe operator just once, unless the first expression is a function. For example:

  ```elixir
  # not preferred
  some_string |> String.downcase()

  # preferred
  String.downcase(some_string)

  # not preferred
  Version.parse(System.version())

  # preferred
  System.version() |> Version.parse()
  ```

- Use parentheses when a `def` has arguments, and omit them when it doesn't. For example:

  ```elixir
  # not preferred
  def some_function arg1, arg2 do
    # body omitted
  end

  def some_function() do
    # body omitted
  end

  # preferred
  def some_function(arg1, arg2) do
    # body omitted
  end

  def some_function do
    # body omitted
  end
  ```

- Use `do:` for single-line `if/unless` statements.

  ```elixir
  # preferred
  if some_condition, do: # some_stuff
  ```

- Use `true` as the last condition of the `cond` special form when you need a clause that always matches.

  ```elixir
  # not preferred
  cond do
    1 + 2 == 5 ->
      "Nope"

    1 + 3 == 5 ->
      "Uh, uh"

    :else ->
      "OK"
  end

  # preferred
  cond do
    1 + 2 == 5 ->
      "Nope"

    1 + 3 == 5 ->
      "Uh, uh"

    true ->
      "OK"
  end
  ```

### Naming

- Use `snake_case` for atoms, functions and variables.

  ```elixir
  # not preferred
  :"some atom"
  :SomeAtom
  :someAtom

  someVar = 5

  def someFunction do
    ...
  end

  # preferred
  :some_atom

  some_var = 5

  def some_function do
    ...
  end
  ```

- Use `CamelCase` for modules (keep acronyms like HTTP, RFC, XML uppercase).

  ```elixir
  # not preferred
  defmodule Somemodule do
    ...
  end

  defmodule Some_Module do
    ...
  end

  defmodule SomeXml do
    ...
  end

  # preferred
  defmodule SomeModule do
    ...
  end

  defmodule SomeXML do
    ...
  end
  ```

- Functions that return a boolean (`true` or `false`) should be named with a trailing question mark.

  ```elixir
  def cool?(var) do
    String.contains?(var, "cool")
  end
  ```

- Boolean checks that can be used in guard clauses (custom guards) should be named with an `is_` prefix.

  ```elixir
  defguard is_cool(var) when var == "cool"
  defguard is_very_cool(var) when var == "very cool"
  ```

### Comments

- Write expressive code and try to convey your program's intention through control-flow, structure and naming.

- Comments longer than a word are capitalized, and sentences use punctuation. Use one space after periods.

```elixir
# not preferred
# these lowercase comments are missing punctuation

# preferred
# Capitalization example
# Use punctuation for complete sentences.
```

- Limit comment lines to 80 characters.

#### Comment Annotations

- Annotations should usually be written on the line immediately above the relevant code.

- The annotation keyword is uppercase, and is followed by a colon and a space, then a note describing the problem.

```elixir
# TODO: Deprecate in v1.5.
def some_function(arg), do: {:ok, arg}
```

- In cases where the problem is so obvious that any documentation would be redundant, annotations may be left with no note. This usage should be the exception and not the rule.

```elixir
start_task()

# FIXME
Process.sleep(5000)
```

- Use `TODO` to note missing features or functionality that should be added at a later date.

- Use `FIXME` to note broken code that needs to be fixed.

- Use `OPTIMIZE` to note slow or inefficient code that may cause performance problems.

- Use `HACK` to note code smells where questionable coding practices were used and should be refactored away.

- Use `REVIEW` to note anything that should be looked at to confirm it is working as intended. For example: `REVIEW: Are we sure this is how the client does X currently?`

- Use other custom annotation keywords if it feels appropriate, but be sure to document them in your project's `README` or similar.

### Comment Constants

- When defining a constant, pick a descriptive name that reflects the intention or usage of the constant and add a comment with a short description.

**Not preferred:**

```elixir
@retries 10
```

**Preferred:**

```elixir
# Default HTTP retries
@http_retries 10
```

- When the constant is a timeout in milliseconds, use `:timer` module instead of explicit value (e.g., `:timer.seconds/1`, `:timer.minutes/1`, `:timer.hours/1`).

**Not preferred:**

```elixir
# Default HTTP request timeout in milliseconds
@http_request_timeout 10_000
```

**Preferred:**

```elixir
# Default HTTP request timeout in milliseconds
@http_request_timeout :timer.seconds(10)
```

- When the constant is a list of atoms or strings, a regex, or anything that can be expressed using Sigils, then use Sigils.

**Not preferred:**

```elixir
# User types
@user_types [:admin, :editor, :customer]

# Supported country codes
@user_types ["US", "ES", "CO"]
```

**Preferred:**

```elixir
# User types
@user_types ~w(admin editor customer)a

# Supported country codes
@user_types ~w(US ES CO)
```

### Modules

- List module attributes, directives, and macros in the following order:

  1. `@moduledoc`
  2. `@behaviour`
  3. `use`
  4. `import`
  5. `require`
  6. `alias`
  7. `@module_attribute`
  8. `defstruct`
  9. `@type`
  10. `@callback`
  11. `@macrocallback`
  12. `@optional_callbacks`
  13. `defmacro`, `defmodule`, `defguard`, `def`, etc.

  Add a blank line between each grouping, and sort the terms (like module names) alphabetically. Here's an overall example of how you should order things in your modules:

  ```elixir
  defmodule MyModule do
    @moduledoc """
    An example module
    """

    @behaviour MyBehaviour

    use GenServer

    import Something
    import SomethingElse

    require Integer

    alias My.Long.Module.Name
    alias My.Other.Module.Example

    @module_attribute :foo
    @other_attribute 100

    defstruct [:name, params: []]

    @type params :: [{binary, binary}]

    @callback some_function(term) :: :ok | {:error, term}

    @macrocallback macro_name(term) :: Macro.t()

    @optional_callbacks macro_name: 1

    @doc false
    defmacro __using__(_opts), do: :no_op

    @doc """
    Determines when a term is `:ok`. Allowed in guards.
    """
    defguard is_ok(term) when term == :ok

    @impl true
    def init(state), do: {:ok, state}

    # Define other functions here.
  end
  ```

- Use the `__MODULE__` pseudo variable when a module refers to itself. This avoids having to update any self-references when the module name changes.

  ```elixir
  defmodule SomeProject.SomeModule do
    defstruct [:name]

    def name(%__MODULE__{name: name}), do: name
  end
  ```

### Typespecs

- Place `@typedoc` and `@type` definitions together, and separate each pair with a blank line.

  ```elixir
  defmodule SomeModule do
    @moduledoc false

    @typedoc "The name"
    @type name() :: atom()

    @typedoc "The result"
    @type result() :: {:ok, any()} | {:error, any()}

    ...
  end
  ```

- Name the main type for a module `t()`, for example: the type specification for a struct.

  ```elixir
  defstruct name: nil, params: []

  @typedoc "The type for ..."
  @type t() :: %__MODULE__{
          name: String.t() | nil,
          params: Keyword.t()
        }
  ```

- Place specifications right before the function definition, after the `@doc`, without separating them by a blank line.

  ```elixir
  @doc """
  Some function description.
  """
  @spec some_function(any()) :: result()
  def some_function(some_data) do
    {:ok, some_data}
  end
  ```

### Structs

- Use a list of atoms for struct fields that default to `nil`, followed by the other keywords.

  ```elixir
  # not preferred
  defstruct name: nil, params: nil, active: true

  # preferred
  defstruct [:name, :params, active: true]
  ```

- Omit square brackets when the argument of a `defstruct` is a keyword list.

  ```elixir
  # not preferred
  defstruct [params: [], active: true]

  # preferred
  defstruct params: [], active: true

  # required - brackets are not optional, with at least one atom in the list
  defstruct [:name, params: [], active: true]
  ```

- If a struct definition spans multiple lines, put each element on its own line, keeping the elements aligned.

  ```elixir
  defstruct foo: "test",
            bar: true,
            baz: false,
            qux: false,
            quux: 1
  ```

  If a multiline struct requires brackets, format it as a multiline list:

  ```elixir
  defstruct [
    :name,
    params: [],
    active: true
  ]
  ```

### Exceptions

- Make exception names end with a trailing `Error`.

  ```elixir
  # not preferred
  defmodule BadHTTPCode do
    defexception [:message]
  end

  defmodule BadHTTPCodeException do
    defexception [:message]
  end

  # preferred
  defmodule BadHTTPCodeError do
    defexception [:message]
  end
  ```

- Use lowercase error messages when raising exceptions, with no trailing punctuation.

  ```elixir
  # not preferred
  raise ArgumentError, "This is not valid."

  # preferred
  raise ArgumentError, "this is not valid"
  ```

### Collections

- Always use the special syntax for keyword lists.

  ```elixir
  # not preferred
  some_value = [{:a, "baz"}, {:b, "qux"}]

  # preferred
  some_value = [a: "baz", b: "qux"]
  ```

- Use the shorthand key-value syntax for maps when all of the keys are atoms.

  ```elixir
  # not preferred
  %{:a => 1, :b => 2, :c => 0}

  # preferred
  %{a: 1, b: 2, c: 3}
  ```

- Use the verbose key-value syntax for maps if any key is not an atom.

  ```elixir
  # not preferred
  %{"c" => 0, a: 1, b: 2}

  # preferred
  %{:a => 1, :b => 2, "c" => 0}
  ```

### Testing

- When writing ExUnit assertions, put the expression being tested to the left of the operator, and the expected result to the right, unless the assertion is a pattern match.

  ```elixir
  # not preferred
  assert true == actual_function(1)

  # preferred
  assert actual_function(1) == true

  # required - the assertion is a pattern match, and the `expected` variable is used later
  assert {:ok, expected} = actual_function(3)
  assert expected.atom == :atom
  assert expected.int == 123

  # preferred - if the right side is known, even if it is a tuple
  assert actual_function(11) == {:ok, %{atom: :atom, int: 123}}

  # preferred - if the right side is known (using a variable)
  expected = %{atom: :atom, int: 123}
  assert actual_function(11) == {:ok, expected}
  ```

## Extra guidelines

- Use a blank line for the return or final statement (unless it is a single line).

  **Avoid**:

      def some_function(arg) do
        Logger.info("Arg: #{inspect(some_data)}")
        :ok
      end

  **Prefer**:

      def some_function(some_data) do
        Logger.info("Arg: #{inspect(some_data)}")

        :ok
      end

- Use multi-line when a function returns with a pipe.

  **Avoid**:

      def some_function(some_data) do
        some_data |> other_function() |> List.first()
      end

  **Prefer**:

      def some_function(some_data) do
        some_data
        |> other_function()
        |> List.first()
      end

- Use `with` when only one case has to be handled, either the success or the error.

  **Avoid**: `case` forwarding the same result

      case some_call() do
        :ok ->
          :ok

        {:error, reason} = error ->
          Logger.error("Error: #{inspect(reason)}")

          error
      end

  **Prefer**: `with` handling only the needed case

      with {:error, reason} = error <- some_call() do
        Logger.error("Error: #{inspect(reason)}")

        error
      end

<!-- nebulex:elixir-style-end -->
<!-- nebulex:nebulex-start -->
## nebulex:nebulex usage
# Nebulex Project-Specific Usage Rules

## Project Overview

Nebulex is a fast, flexible, and extensible caching library for Elixir that
provides:
- Multiple cache adapters (local, distributed, multilevel, partitioned,
  coherent).
- Declarative decorator-based caching inspired by Spring Cache Abstraction.
- OTP design patterns and fault tolerance.
- Telemetry instrumentation.
- Event streaming via `Nebulex.Streams` for distributed invalidation.
- Support for TTL, eviction policies, transactions, and more.

## Architecture & Key Files

> Read `usage-rules/architecture.md` for full architecture context,
> module hierarchy, layer boundaries, and non-negotiable contribution rules.
> The section below is a quick-reference complement to that guide.

| Path | Purpose |
|------|---------|
| `lib/nebulex/cache.ex` | Main Cache API |
| `lib/nebulex/cache/` | Cache feature modules (KV, Options, etc.) |
| `lib/nebulex/adapter.ex` | Adapter behaviour and macros |
| `lib/nebulex/adapters/` | Built-in adapter modules in core (e.g., Nil, common helpers) |
| `lib/nebulex/caching/decorators.ex` | Decorator implementation |
| `lib/nebulex/caching/` | Caching internals (Context, Runtime) |
| `lib/nebulex/event.ex` | Cache event types |
| `lib/nebulex/telemetry.ex` | Telemetry instrumentation |
| `lib/nebulex/utils.ex` | Shared utilities |
| `mix.exs` | Dependencies and project config |
| `CHANGELOG.md` | Release history and breaking changes |
| `test/` | Test suite (mirrors `lib/` structure) |
| `usage-rules/architecture.md` | Architecture, non-negotiables, source of truth hierarchy |
| `guides/` | User-facing guides, behavioral references, and examples |
| `guides/upgrading/v3.0.md` | v3 migration guide |

## Package Structure (v3)

Nebulex v3 separates adapters into dedicated packages:
- `nebulex` - Core.
- `nebulex_local` - Local cache adapter.
- `nebulex_distributed` - Partitioned, multilevel, and coherent adapters.
- `nebulex_redis_adapter` - Adapter for Redis (including Redis Cluster).
- `nebulex_adapters_cachex` - Adapter for `cachex` library.
- `nebulex_disk_lfu` - Persistent disk-based cache adapter with LFU eviction for Nebulex.

> See `guides/introduction/nbx-adapters.md` for more information about the
> available adapters.

Add the required dependencies to your `mix.exs`:

```elixir
defp deps do
  [
    {:nebulex, "~> 3.0"},
    {:nebulex_local, "~> 3.0"},
    # For distributed caching
    {:nebulex_distributed, "~> 3.0"},
    # Required for caching decorators
    {:decorator, "~> 1.4"},
    # Optional but highly recommended for observability
    {:telemetry, "~> 1.0"}
  ]
end
```

> **Note**: The `:telemetry` dependency is optional but highly recommended for
> production environments. It enables cache metrics, monitoring, and
> integration with observability tools.

## Architecture Patterns

### Cache Definition

- Caches MUST be defined using `use Nebulex.Cache` with `:otp_app` and
  `:adapter` options.
- Caches should be started in the application supervision tree, not manually.
- Use descriptive cache module names that indicate their purpose
  (e.g., `MyApp.LocalCache`, `MyApp.UserCache`).
- Use `adapter_opts` for compile-time adapter options like
  `:primary_storage_adapter`.

**Example**:

```elixir
defmodule MyApp.Cache do
  use Nebulex.Cache,
    otp_app: :my_app,
    adapter: Nebulex.Adapters.Local
end
```

**With compile-time adapter options** (Partitioned/Coherent adapters):

```elixir
defmodule MyApp.PartitionedCache do
  use Nebulex.Cache,
    otp_app: :my_app,
    adapter: Nebulex.Adapters.Partitioned,
    adapter_opts: [primary_storage_adapter: Nebulex.Adapters.Local]
end
```

**Avoid** putting adapter options at the top level:

```elixir
# WRONG - will raise an error
defmodule MyApp.PartitionedCache do
  use Nebulex.Cache,
    otp_app: :my_app,
    adapter: Nebulex.Adapters.Partitioned,
    primary_storage_adapter: Nebulex.Adapters.Local
end
```

### Cache Topologies

Nebulex supports multiple cache topologies:

- **Local** (`Nebulex.Adapters.Local`): Single-node generational cache with
  automatic garbage collection.
- **Partitioned** (`Nebulex.Adapters.Partitioned`): Distributed cache with
  data sharded across cluster nodes using consistent hashing.
- **Multilevel** (`Nebulex.Adapters.Multilevel`): Hierarchical cache with
  multiple levels (e.g., L1 local + L2 distributed).
- **Coherent** (`Nebulex.Adapters.Coherent`): Local cache with distributed
  invalidation via `Nebulex.Streams`. Ideal for read-heavy workloads.

### Multilevel Cache Configuration

Use `inclusion_policy` (not the deprecated `model`) for multilevel caches:

```elixir
config :my_app, MyApp.NearCache,
  inclusion_policy: :inclusive,
  levels: [
    {MyApp.NearCache.L1, gc_interval: :timer.hours(12)},
    {MyApp.NearCache.L2, primary: [gc_interval: :timer.hours(12)]}
  ]
```

### Adapter Pattern

- All adapters MUST implement the `Nebulex.Adapter` behaviour.
- Adapters MUST implement `c:init/1` returning
  `{:ok, child_spec, adapter_meta}`.
- Adapter functions MUST return `{:ok, value}` or `{:error, reason}` tuples.
- Use `wrap_error/2` from `Nebulex.Utils` to wrap errors consistently.
- Implement optional behaviours as needed: `Nebulex.Adapter.KV`,
  `Nebulex.Adapter.Queryable`, etc.

### Command Pattern

- Use `defcommand/2` macro from `Nebulex.Adapter` to build public command
  wrappers.
- Use `defcommandp/2` for private command wrappers.
- Command functions automatically handle telemetry, metadata, and error
  wrapping.
- The first parameter to commands should always be `name`
  (the cache name or PID).
- The last parameter should always be `opts` (keyword list).

**Example**:

```elixir
defcommand fetch(name, key, opts)
defcommandp do_put(name, key, value, on_write, ttl, keep_ttl?, opts), command: :put
```

## Return Value Conventions

### Tuple Returns

- Read operations that can fail MUST return `{:ok, value}` or
  `{:error, %Nebulex.KeyError{}}` for missing keys.
- Write operations MUST return `{:ok, true}` for success or `{:ok, false}` for
  conditional failures (e.g., `put_new`).
- Delete operations MUST return `:ok` regardless of whether the key existed.
- NEVER return bare `:error` atoms; always use `{:error, reason}` tuples.

### Bang Functions

- Provide bang versions (`!`) of functions that unwrap `{:ok, value}` or raise
  exceptions.
- Bang functions MUST use `unwrap_or_raise/1` from `Nebulex.Utils`.
- Functions that return `:ok` should have bang versions that also return `:ok`.
- Functions that return `{:ok, boolean}` should have bang versions that return
  the boolean.

**Example**:

```elixir
def fetch!(name, key, opts) do
  unwrap_or_raise fetch(name, key, opts)
end

def put!(name, key, value, opts) do
  _ = unwrap_or_raise do_put(name, key, value, :put, opts)
  :ok
end
```

### Fetch-or-Store Pattern

Use `fetch_or_store/3` and `get_or_store/3` for read-through caching:

```elixir
# Returns {:ok, value} or {:error, reason}
cache.fetch_or_store("user:123", fn ->
  case Repo.get(User, 123) do
    nil -> {:error, :not_found}
    user -> {:ok, user}
  end
end)

# Returns value directly (raises on error)
cache.get_or_store!("user:123", fn ->
  Repo.get!(User, 123)
end)
```

- `fetch_or_store/3` - Returns `{:ok, value}` from cache or fallback function.
  If the fallback returns `{:error, reason}`, it propagates the error without
  caching.
- `get_or_store/3` - Simpler variant that stores the direct return value from
  the fallback function.

## Options and Validation

### Options Handling

- Use `Nebulex.Cache.Options` module for option validation.
- Call `Options.validate_runtime_shared_opts!/1` to validate runtime options.
- Use `Options.pop_and_validate_timeout!/2` for TTL and timeout options.
- Use `Options.pop_and_validate_boolean!/2` for boolean options.
- Use `Options.pop_and_validate_integer!/2` for integer options.
- Validate options as early as possible, preferably at the beginning of the
  function.

**Example**:

```elixir
def put(name, key, value, opts) do
  {ttl, opts} = Options.pop_and_validate_timeout!(opts, :ttl)
  {keep_ttl?, opts} = Options.pop_and_validate_boolean!(opts, :keep_ttl, false)

  do_put(name, key, value, :put, ttl, keep_ttl?, opts)
end
```

### Shared Options

- All cache functions should accept `:telemetry`, `:telemetry_event`, and
  `:telemetry_metadata` options.
- Document adapter-specific options clearly in the module documentation.

## Decorators

### Decorator Usage

- Use `use Nebulex.Caching` to enable decorator support in a module.
- Configure default cache via `use Nebulex.Caching, cache: MyCache`.
- Always use decorators on functions, not on function heads with multiple
  clauses.
- Prefer module captures over anonymous functions for better performance:
  `match: &__MODULE__.match_fun/1`.
- Avoid capturing large data structures in decorator lambdas.

**Invalid**:

```elixir
@decorate cacheable(key: id)
def get_user(nil), do: nil

def get_user(id) do
  # logic
end
```

**Valid**:

```elixir
@decorate cacheable(key: id)
def get_user(id) do
  do_get_user(id)
end

defp do_get_user(nil), do: nil
defp do_get_user(id) do
  # logic
end
```

### Decorator Options

- Use `:key` option to specify explicit cache keys; avoid relying solely on
  default key generation.
- Use `:references` for implementing cache key references and memory-efficient
  caching.
- Use `:match` option to conditionally cache values
  (e.g., `match: &match_fun/1`).
- Use `:on_error` option to control error handling (`:raise` or `:nothing`).
- Specify TTL via `:opts` option: `opts: [ttl: :timer.hours(1)]`.
- Use `:transaction` option to wrap cache operations in a transaction,
  preventing race conditions and cache stampede.

**Transaction example** (prevents concurrent updates to the same key):

```elixir
@decorate cacheable(key: id, transaction: true)
def get_user(id) do
  Repo.get(User, id)
end
```

### `cacheable` Decorator

- Use `@decorate cacheable` for read-through caching patterns.
- Combine with `:references` option when the same value needs multiple cache
  keys.
- Use `:match` function with references to ensure consistency
  (e.g., validating email matches).

**Example**:

```elixir
@decorate cacheable(key: id)
def get_user(id) do
  Repo.get(User, id)
end

@decorate cacheable(key: email, references: &(&1 && &1.id), match: &match_email(&1, email))
def get_user_by_email(email) do
  Repo.get_by(User, email: email)
end

defp match_email(%{email: email}, email), do: true
defp match_email(_, _), do: false
```

### `cache_put` Decorator

- Use `@decorate cache_put` for write-through caching patterns.
- Always use `:match` option to conditionally update cache
  (e.g., only on `{:ok, value}`).
- Avoid using `cache_put` and `cacheable` on the same function.

**Example**:

```elixir
@decorate cache_put(key: user.id, match: &match_ok/1)
def update_user(user, attrs) do
  user
  |> User.changeset(attrs)
  |> Repo.update()
end

defp match_ok({:ok, user}), do: {true, user}
defp match_ok({:error, _}), do: false
```

### `cache_evict` Decorator

- Use `@decorate cache_evict` for cache invalidation.
- Use `key: {:in, keys}` to evict multiple keys at once.
- Use `:all_entries` option to clear the entire cache.
- Use `:before_invocation` option to evict before function execution.
- Use `:query` option for complex eviction patterns based on match
  specifications.

**Example**:

```elixir
@decorate cache_evict(key: {:in, [user.id, user.email]})
def delete_user(user) do
  Repo.delete(user)
end

@decorate cache_evict(all_entries: true)
def clear_all_users do
  Repo.delete_all(User)
end

@decorate cache_evict(query: &__MODULE__.query_for_tag/1)
def delete_by_tag(tag) do
  # Delete logic
end

def query_for_tag(%{args: [tag]}) do
  [{:entry, :"$1", %{tag: :"$2"}, :_, :_}, [{:"=:=", :"$2", tag}], [true]]
end
```

## Nebulex.Streams

`Nebulex.Streams` provides event streaming for cache operations, enabling
distributed cache invalidation patterns.

### Enabling Streams

Add `use Nebulex.Streams` to your cache module:

```elixir
defmodule MyApp.Cache do
  use Nebulex.Cache,
    otp_app: :my_app,
    adapter: Nebulex.Adapters.Local

  use Nebulex.Streams
end
```

### Stream Handlers

Implement custom stream handlers by using `Nebulex.Streams.Handler`:

```elixir
defmodule MyApp.CacheEventHandler do
  use Nebulex.Streams.Handler

  @impl true
  def handle_event(event, state) do
    # Handle cache events (put, delete, etc.)
    {:cont, state}
  end
end
```

### Coherent Cache Pattern

The `Nebulex.Adapters.Coherent` adapter uses `Nebulex.Streams` to provide
local caching with distributed invalidation:

- Each node maintains its own local cache.
- Write operations trigger invalidation events via `Phoenix.PubSub`.
- Other nodes delete the invalidated keys from their local caches.
- Next read on other nodes results in a cache miss, fetching fresh data.

```elixir
defmodule MyApp.CoherentCache do
  use Nebulex.Cache,
    otp_app: :my_app,
    adapter: Nebulex.Adapters.Coherent,
    adapter_opts: [primary_storage_adapter: Nebulex.Adapters.Local]
end
```

Configuration:

```elixir
config :my_app, MyApp.CoherentCache,
  primary: [
    gc_interval: :timer.hours(12),
    max_size: 1_000_000
  ]
```

## Testing Patterns

### Test Structure

- Use `deftests do` macro for shared test suites that can run across multiple
  adapters.
- Structure tests with `describe` blocks grouping related functionality.
- Use context fixtures with `%{cache: cache}` for test setup.
- Test both successful and error scenarios for each function.

**Example**:

```elixir
defmodule MyAdapterTest do
  import Nebulex.CacheCase

  deftests do
    describe "put/3" do
      test "puts the given entry into the cache", %{cache: cache} do
        assert cache.put(:key, :value) == :ok
        assert cache.fetch!(:key) == :value
      end

      test "raises when invalid option is given", %{cache: cache} do
        assert_raise NimbleOptions.ValidationError, fn ->
          cache.put(:key, :value, ttl: "invalid")
        end
      end
    end
  end
end
```

### Test Assertions

- Use `assert cache.function() == expected_value` for exact equality.
- Use `assert_raise ErrorType, ~r"message pattern"` for exception testing.
- Test edge cases: `nil`, boolean values (`true`, `false`), empty collections.
- Test both normal and bang (`!`) versions of functions.
- Avoid pattern matching in assertions when the full value is known
  (use direct equality).

**Invalid**:

```elixir
assert {:ok, value} = cache.fetch(:key)
```

**Valid**:

```elixir
assert cache.fetch(:key) == {:ok, expected_value}
```

## Telemetry

### Telemetry Events

- Emit telemetry events for all cache commands when `:telemetry` option is
  `true`.
- Use `:telemetry_prefix` option to customize event names
  (defaults to `[:cache_name, :cache]`).
- Provide comprehensive metadata: `:adapter_meta`, `:command`, `:args`,
  `:result`.
- Support custom `:telemetry_event` and `:telemetry_metadata` options per
  command.

### Telemetry Best Practices

- Use `Nebulex.Telemetry.span/3` for span events (start, stop, exception).
- Include measurements like `:duration` and `:system_time`.
- Document all telemetry events in module documentation with measurement and
  metadata keys.
- Provide example telemetry handlers in documentation.

## Error Handling

### Error Types

- Use `Nebulex.Error` for general cache errors.
- Use `Nebulex.KeyError` for missing key errors.
- Use `Nebulex.CacheNotFoundError` for dynamic cache lookup failures.
- Wrap adapter-specific errors using `wrap_error/2` from `Nebulex.Utils`.

### Error Wrapping

- Adapter functions should wrap errors consistently using `wrap_error/2`.
- Include relevant context in error metadata (`:key`, `:command`, `:reason`).
- Preserve original error information in the `:reason` field.

**Example**:

```elixir
def fetch(_adapter_meta, key, opts) do
  case do_fetch(key) do
    {:ok, value} -> {:ok, value}
    {:error, :not_found} -> wrap_error Nebulex.KeyError, key: key
    {:error, reason} -> wrap_error Nebulex.Error, reason: reason, command: :fetch, key: key
  end
end
```

## Performance Considerations

### Key Generation

- Provide explicit keys in decorators when possible; avoid relying on default
  key generation.
- For complex keys, use module captures: `key: &MyModule.generate_key/1`.
- Keep captured data in decorator lambdas small; fetch large configs inside
  functions.

### Reference Keys

- Use cache key references (`:references` option) to avoid storing duplicate
  values.
- Store references in a local cache and values in a remote cache (e.g., Redis)
  for optimization.
- Set TTL for references to prevent dangling keys.
- Use external references with `keyref(key, cache: AnotherCache)` for
  cross-cache references.

### Optimization

- Use `Stream` for large result sets instead of loading all data at once.
- Leverage `Task.async_stream/3` for concurrent cache operations when
  appropriate.
- Set appropriate TTL values to balance freshness and performance.
- Use `put_all/2` for batch operations instead of multiple `put/3` calls.

## Documentation Standards

### Module Documentation

- Start with a clear `@moduledoc` explaining the purpose and main features,
  except modules that use `NimbleOptions` for option documentation.
- Options documented using `NimbleOptions` should provide functions to insert
  that documentation into the module docs. Therefore, it is not required to
  document an option in the `moduledoc` or in the function `@doc` if it is
  already inserted using `NimbleOptions`. For example,
  `#{Nebulex.Cache.Options.start_link_options_docs()}`.
- Include usage examples in module documentation.
- Document all compile-time options.
- Document all runtime shared options.
- Provide telemetry event documentation with measurements and metadata.
- The maximum text length is 80 characters, and you should aim to adhere to this
  limit. However, there are special cases where exceeding it is acceptable. For
  example, you may exceed the limit for a link (e.g., [my link](https://github.com/elixir-nebulex))
  or a code snippet that only exceeds the limit by a few characters (e.g., 1 or 2).
  If a code snippet exceeds the 80-character limit by more than 1 or 2
  characters, format it using the Elixir formatter.
- When you make a change to the documentation, use `mix docs` to validate it.

### Function Documentation

- Use `@doc` for all public functions.
- Include `@typedoc` for all custom types.
- Provide examples in function documentation using doctests when applicable.
- Document all options with descriptions and default values.
- Group related functions using `@doc group: "Group Name"`.
- Follow the same 80-character line-length guidance described in
  "Module Documentation," including the same exceptions for links and short
  formatter-friendly code snippets.
- When you make a change to the documentation, use `mix docs` to validate it.

### Code Comments

- Avoid obvious comments; code should be self-explanatory.
- Use comments for complex algorithms or non-obvious business logic. Use a
  single `#` for code comments. E.g., `# My comment ...`.
- For separating sections in a module, use `##`. E.g., `## API`,
  `## Private functions`, etc.
- Mark internal functions with `@doc false` or `@moduledoc false`.
- Use `# Inline common instructions` followed by
  `@compile inline: [function_name: arity]`.
- The maximum text length is 80 characters; use multiple lines if the comment
  exceeds the limit.

## Naming Conventions

### Modules

- Adapter modules: `Nebulex.Adapters.*` (e.g., `Nebulex.Adapters.Local`).
- Cache modules: `<App>.Cache` or `<App>.<Context>Cache`
  (e.g., `MyApp.Cache`, `MyApp.UserCache`).
- Behaviour modules: `Nebulex.Adapter.<Feature>` (e.g., `Nebulex.Adapter.KV`).

### Functions

- Use descriptive function names: `fetch/2`, `put/3`, `delete/2`, `has_key?/2`.
- Bang versions: `fetch!/2`, `put!/3`, `delete!/2`.
- Private helpers: prefix with `do_` (e.g., `do_fetch`, `do_put`).
- Predicate functions: suffix with `?` (e.g., `has_key?/2`, `expired?/2`).

### Variables

- Cache instance: `cache`.
- Adapter metadata: `adapter_meta`.
- Options: `opts`.
- Keys: `key` or `keys`.
- Values: `value` or `values`.
- TTL: `ttl`.

## Code Organization

### File Structure

- Main cache API: `lib/nebulex/cache.ex`.
- Adapter behaviour: `lib/nebulex/adapter.ex`.
- Adapter implementations: `lib/nebulex/adapters/<adapter_name>.ex`.
- Cache features: `lib/nebulex/cache/<feature>.ex`.
- Decorators: `lib/nebulex/caching/decorators.ex`.
- Mix tasks: `lib/mix/tasks/<task_name>.ex`.

### Module Grouping

- Keep related functionality together (e.g., all KV operations in `Nebulex.Cache.KV`).
- Use nested modules for options, helpers, and internal implementation details.
- Separate public API from internal implementation.

## Mix Tasks

Nebulex provides `mix nbx.gen.cache` to generate a cache module:

```
mix nbx.gen.cache -c MyApp.Cache
```

This generates a cache using `Nebulex.Adapters.Local` by default. For other
adapters (Partitioned, Multilevel, Coherent), manually update the generated
module:

```elixir
# Generated (Local adapter by default)
defmodule MyApp.Cache do
  use Nebulex.Cache,
    otp_app: :my_app,
    adapter: Nebulex.Adapters.Local
end

# Manually update for Partitioned
defmodule MyApp.PartitionedCache do
  use Nebulex.Cache,
    otp_app: :my_app,
    adapter: Nebulex.Adapters.Partitioned,
    adapter_opts: [primary_storage_adapter: Nebulex.Adapters.Local]
end
```

## Common Pitfalls to Avoid

### General

- **Do NOT** use decorators on multi-clause functions without proper wrapper
  functions.
- **Do NOT** forget to validate options at the beginning of functions.
- **Do NOT** return inconsistent error types; always use tuples or raise
  exceptions via bang functions.
- **Do NOT** capture large data structures in decorator lambdas.
- **Do NOT** forget to handle `nil`, boolean, and edge case values in tests.
- **Do NOT** use `cache_put` and `cacheable` decorators on the same function.
- **Do NOT** forget to evict cache references when using `:references` option;
  use TTL or explicit eviction.
- **Do NOT** implement adapter callbacks without proper error wrapping.

### v3-Specific

- **Do NOT** use `primary_storage_adapter` at the top level; wrap it in
  `adapter_opts: [primary_storage_adapter: ...]`.
- **Do NOT** use the deprecated `model` option for multilevel caches; use
  `inclusion_policy` instead.
- **Do NOT** use `mix nbx.gen.cache.partitioned` or `mix nbx.gen.cache.multilevel`
  (they don't exist); use `mix nbx.gen.cache` and manually configure the adapter.
- **Do NOT** use the old `all/2` callback; use `get_all/2` with query spec instead.
- **Do NOT** use `:keys` option in decorators; use `key: {:in, keys}` instead.
- **Do NOT** use `:key_generator` option; use `key: &MyModule.generate_key/1`.
- **Do NOT** skip telemetry support in adapter implementations.
- **Do NOT** use pattern matching in test assertions when the full value is
  known.

## Backward Compatibility

- Maintain backward compatibility when adding new options (use default values).
- Deprecate old APIs before removal; provide migration path in documentation.
- Follow semantic versioning strictly: major version for breaking changes.
- Test against multiple Elixir and OTP versions in CI.

## Dependencies

- Keep dependencies minimal and well-justified.
- Prefer standard library solutions over external dependencies.
- Use optional dependencies for non-core features.
- Document all dependencies in README with their purpose.

<!-- nebulex:nebulex-end -->
<!-- nebulex:workflow-start -->
## nebulex:workflow usage
# Agent Workflow

## Rules

Read these at session start and refer back while coding. When rules
conflict, prioritize them in the order listed.

1. `usage-rules/workflow.md` — entry point (this file)
2. `usage-rules/architecture.md` — architecture & non-negotiables
3. `usage-rules/nebulex.md` — Nebulex-specific rules
4. `usage-rules/elixir-style.md` — style guidelines
5. `usage-rules/elixir.md` — core Elixir rules

## Session Bootstrap

At the start of each session, quickly establish context:

1. Run `git status --short` and `git diff --name-only` to check
   local modifications and currently touched files.
2. Run `git log --oneline -20` to see recent changes.
3. Run `git branch -a` to see active branches and current branch.
4. Read `README.md` and the latest section of `CHANGELOG.md`.
5. Read the rule files listed in the Rules section above.
6. Check `.tool-versions` or the `elixir` version in `mix.exs` for
   supported Elixir/OTP versions.

If on a feature branch, also run:

7. `git log --oneline main..HEAD` to see the branch's commits.
8. `git diff main...HEAD` to understand the branch's full scope.

When relevant to the task:

9. Check open issues and PRs with `gh issue list` and `gh pr list`.
   If `gh` is unavailable or unauthenticated, skip this step.

## Current Project Status

- **Latest release**: check the latest section in `CHANGELOG.md`.
- Read `CHANGELOG.md` for recent features, breaking changes, and
  the project's direction.
- When summarizing changes for the PR description, distinguish
  user-visible behavior from internal refactors — only the former
  typically warrants release-note context for maintainers.

## PR Workflow

### Reviewing PRs

1. Read the PR description and all comments:
   `gh pr view <number>` and `gh pr view <number> --comments`.
2. Review the diff: `gh pr diff <number>`.
3. Check `CHANGELOG.md` to understand if the change aligns with the
   project's direction.
4. Verify code follows `usage-rules/` conventions (architectural
   non-negotiables first, then Nebulex-specific rules, Elixir
   patterns, and style guidelines).
5. Rely on green CI for the canonical gate; re-run `mix test.ci`
   locally only if you doubt CI's result. Use the fast-iteration
   commands (see below) for spot checks.
6. Provide constructive feedback referencing specific lines and
   conventions.
7. Structure review feedback as:
   - findings first (ordered by severity, with file:line references),
   - open questions/assumptions,
   - brief summary last.

### Opening PRs

1. Branch from `main` with a descriptive branch name
   (e.g., `fix/some-bug`, `feat/cache-warming-support`).
2. Do not update `CHANGELOG.md` directly. Include release-note context
   in the PR description for maintainers to fold into the next release.
3. Run `mix test.ci` before pushing (canonical gate; see below).
4. Reference related GitHub issues in the PR description
   (e.g., "Closes #123").
5. Use `gh pr create` with a clear title and description.

## Commit Messages

Commit messages must follow the
[Conventional Commits](https://www.conventionalcommits.org/) format:

```text
type(scope): short summary
```

### Allowed Types

- `feat`
- `fix`
- `refactor`
- `docs`
- `test`
- `chore`
- `perf`
- `ci`
- `build`

### Rules

1. Use imperative mood in the summary.
2. Keep the summary lowercase and do not end it with a period.
3. Use a scope when it adds clarity (e.g., `cache`, `decorators`,
   `telemetry`, `workflow`).
4. Keep the first line concise (ideally <= 72 chars).

### Examples

- `feat(cache): add runtime option validation for ttl`
- `fix(decorators): handle nested context pop safely`
- `chore(workflow): refine session bootstrap steps`

## Validation Commands

Use these for fast iteration during development:

```bash
# Targeted test
mix test path/to/changed_test.exs

# Format check
mix format --check-formatted

# Static analysis
mix credo --strict

# Documentation (if docs were changed)
mix docs
```

Before pushing for review, the canonical gate is `mix test.ci`. It runs
tests, coverage, Credo (strict), Dialyzer, Sobelow, and `mix doctor`.
Green CI is a requirement, not a courtesy check (see
`usage-rules/architecture.md` Non-Negotiable #5).

```bash
mix test.ci
```

<!-- nebulex:workflow-end -->
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
<!-- sobelow-start -->
## sobelow usage
_Security-focused static analysis for Elixir & the Phoenix framework_

# Sobelow usage rules

Sobelow is a security-focused **static** analyser for Elixir and Phoenix. It reads
source code, never runs it, and never contacts a running application.

## Running it

```sh
mix sobelow                 # scan the current project
mix sobelow -r ../my_app    # scan another project root
```

Add it as a dev/test dependency so `mix sobelow` is available:

```elixir
{:sobelow, "~> 0.14", only: [:dev, :test], runtime: false, warn_if_outdated: true}
```

Sobelow scans **one application at a time**. For an umbrella, add an alias to the
root `mix.exs` and give each child app its own config file:

```elixir
defp aliases do
  [sobelow: ["cmd mix sobelow"]]
end
```

## Confidence levels are triage guidance, not severity

Every finding carries High, Medium, or Low confidence. This is Sobelow's confidence
that the code is *reachable with attacker-controlled input* — not how bad the bug
would be.

- **High** — the tainted value traces back to a function parameter or `conn.params`.
- **Medium** — the dangerous call is present but the input source is less certain.
- **Low** — the pattern looks dangerous but Sobelow cannot tell whether it takes
  user input. Often, but not always, a false positive.

Sobelow intentionally over-reports. **A green (low) finding may still be critical.**
Never tell a user their code is safe because findings are low confidence, and never
suppress low-confidence findings wholesale to make a build pass.

Use `--threshold low|medium|high` to filter the report by confidence.

## Suppressing false positives

There are two mechanisms and they are not interchangeable.

**`# sobelow_skip` comments** mark a *specific function* or a *specific Phoenix
router pipeline*. The comment must sit immediately above the `def` or `pipeline`
it applies to.

```elixir
# sobelow_skip ["Traversal.SendFile", "XSS.Raw"]
def download(conn, params) do
  ...
end
```

On a pipeline they suppress the router configuration checks — `Config.CSRF`,
`Config.Headers`, and `Config.CSP`:

```elixir
# sobelow_skip ["Config.CSRF"]
pipeline :api do
  ...
end
```

Listing the parent `Config` module suppresses every Config check on that
pipeline, the same way `-i Config` ignores the whole group.

Spacing does not matter, but the check names must be a list of double-quoted
strings. A comment Sobelow cannot read is reported on stderr with its file and
line rather than being ignored, so a skip that appears to do nothing is worth
checking the warnings for.

They still cannot suppress configuration findings that are not attached to a
function or a pipeline — `Config.Secrets` or `Config.HTTPS`, for instance, which
come from `config/*.exs`. Use `--mark-skip-all` for those.

**`--mark-skip-all`** writes every currently-reported finding to a `.sobelow-skips`
file, and works for *all* finding types including configuration ones. Use it when
adopting Sobelow on an existing codebase.

Either way, the skips only take effect when you pass `--skip`:

```sh
mix sobelow --mark-skip-all   # record the current findings as accepted
mix sobelow --skip            # scan, ignoring those
mix sobelow --clear-skip      # discard the recorded skips
```

Commit `.sobelow-skips` so the whole team and CI share the same baseline. The file
is rewritten in sorted order each time it is regenerated, so re-running
`--mark-skip-all` after fixing or adding a finding produces a small, readable diff
rather than reshuffling the file. Pass `--legacy-skips` if you need the older
append-only behaviour, which never rewrites lines it did not add.

Prefer `# sobelow_skip` with an explicit module list over `--mark-skip-all` when you
have only a handful of false positives — it documents the decision at the code, and
it does not go stale silently when the line moves.

`--ignore` (`-i`) is different again: it disables a whole check for the entire scan.
Reach for it only when a check does not apply to the project at all.

## Configuration file

`--save-config` writes a `.sobelow-conf` at the project root from the flags you
passed:

```sh
mix sobelow -i XSS.Raw,Traversal --verbose --exit Low --save-config
```

Precedence rules:

- `.sobelow-conf` is used automatically when present.
- **CLI switches override the file.**
- `--no-config` ignores the file for that run.

The file holds settings only. `--version`, `--details`, `--all-details`,
`--save-config`, and `--diff` pick what Sobelow does instead of configuring a
scan, and each ends the run before one happens, so they are ignored if they
appear in the file.

Commit `.sobelow-conf`. Paths in it are stored relative to the project root, so it
works on other machines and in CI.

## CI

Sobelow exits 0 by default, *even when it finds things*. To fail a build you must
pass `--exit`:

```sh
mix sobelow --exit medium     # non-zero if any medium or high finding exists
mix sobelow --exit            # bare --exit means low, i.e. fail on anything
```

A reasonable starting point for an existing codebase: baseline with
`--mark-skip-all`, then run `mix sobelow --skip --exit low` in CI so any *new*
finding fails the build.

Machine-readable output for other tooling:

```sh
mix sobelow --format json
mix sobelow --format sarif        # e.g. GitHub code scanning
mix sobelow --format sarif --out results.sarif
```

`--out` implies a machine-readable format; a `txt` format is coerced to `json`.

Other useful flags:

- `--private` — no update check, no network requests, no cache file written.
  Use this in CI and in sandboxed builds.
- `--quiet` — print a one-line count instead of findings.
- `--compact` / `--flycheck` — single-line findings for editors and tooling.
- `--strict` — treat a file Sobelow cannot parse as a hard error (exit 2) instead of
  skipping it. Without it, unparseable files are silently skipped.
- `--no-router` — for a project with no Phoenix router, such as a plain Elixir
  library. Without it Sobelow warns that it cannot find one, on every run. The
  router-dependent checks are skipped either way. Set it in `.sobelow-conf` as
  `router: :none`.

## What it will and will not find

Sobelow flags patterns, not proven exploits. It has no cross-function taint
tracking: it decides confidence from the parameters of the *enclosing* function
only. A value laundered through a helper will usually come back as low confidence
or not at all.

It also does not check dependencies for known CVEs in general — the `Vuln.*` checks
cover a small fixed set of historical advisories by inspecting `deps/`. For real
dependency scanning use `mix hex.audit` (retired packages) alongside a dedicated
tool such as MixAudit.

If Sobelow reports nothing, that is not evidence the application is secure. Say so
plainly rather than reporting a clean scan as a security sign-off.

## Getting details on a finding

```sh
mix sobelow -d Config.CSRF     # explain one check
mix sobelow --all-details      # explain all of them
mix help sobelow               # flags and the full module list
```

<!-- sobelow-end -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
