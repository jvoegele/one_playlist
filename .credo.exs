# Credo configuration, following the shape used in wait_for_it: a strict gate over
# application code, with test code deliberately outside it — tests favour clarity and
# repetition over lint rules, and a linter that argues with them gets switched off.
#
# > #### Do not add an `enabled:` list here
# >
# > `checks: %{enabled: [...]}` does not add to the default set, it *replaces* it.
# > Measured on this project: with a one-entry `enabled:` list Credo ran 1 check;
# > without it, 68. A config that looks more thorough while silently disabling 67
# > checks is the worst possible outcome, so the only key used here is `disabled:`.
# > To retune a check's parameters, generate the full explicit list with
# > `mix credo.gen.config` and edit that instead.
#
# Line length is left at Credo's default of 120 rather than matched to the
# formatter's 98. That is deliberate: the formatter already wraps everything it
# can, so anything still over 98 is a string, a comment, or a URL that it chose
# not to touch. Credo's job here is to catch the genuinely unreadable ones.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "mix.exs"],
        excluded: []
      },
      strict: true,
      plugins: [],
      requires: [],
      checks: %{
        disabled: [
          # Errata and Bond error/contract modules are referenced by their full names
          # in `use` options and assertions, where an alias would obscure which type is
          # being produced. The suggestion is noise in this codebase.
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}
