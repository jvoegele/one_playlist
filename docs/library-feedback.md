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
