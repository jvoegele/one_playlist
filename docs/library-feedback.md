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
