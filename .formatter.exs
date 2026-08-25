[
  # Elixir's own formatter default, stated explicitly so it is a deliberate
  # choice rather than an inherited one. Note that `external_service` and
  # `wait_for_it` use 100; if we ever want to match them, this is the knob.
  line_length: 98,

  # HEEx attributes wrap badly at 98 — a single tag with a handful of
  # attributes and an event binding blows past it and gets split one attribute
  # per line. Give markup more room than code.
  heex_line_length: 120,
  plugins: [Phoenix.LiveView.HTMLFormatter],
  import_deps: [
    # Framework
    :ecto,
    :ecto_sql,
    :phoenix,
    # `assert_email_sent` and friends, for mailer tests.
    :swoosh,

    # First-party (see CLAUDE.md). `bond`, `wait_for_it` and — as of 3.0.0 —
    # `external_service` export `locals_without_parens`. `errata` ships no
    # `.formatter.exs` at all, so listing it is a no-op today that starts
    # working the moment it does; a dep without one is silently ignored rather
    # than an error.
    :bond,
    :errata,
    :external_service,
    :wait_for_it
  ],

  # The hand-written `locals_without_parens` for `call/1,2` and `call!/1,2` is
  # gone: `external_service` 3.0.0 ships the `:export` block this project asked
  # for, so `import_deps` now carries them — along with `call_async/1,2`, which
  # the local copy did not. Dogfooding feedback that came back as a release.
  subdirectories: ["priv/*/migrations"],
  inputs: [
    # `*.exs` does not match dotfiles, so `.formatter.exs` needs naming.
    "{mix,.formatter}.exs",
    "*.{heex,ex,exs}",
    "{config,lib,test}/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs"
  ]
]
