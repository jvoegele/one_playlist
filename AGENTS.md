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
