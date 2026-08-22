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

    # First-party (see CLAUDE.md). `bond` and `wait_for_it` export
    # `locals_without_parens`; `errata` and `external_service` do not yet, so
    # listing them is a no-op today that starts working the moment they do.
    # A dep with a `.formatter.exs` but no `:export` key is silently ignored,
    # so this is harmless rather than an error.
    :bond,
    :errata,
    :external_service,
    :wait_for_it
  ],

  # `external_service` documents its API as `call fn -> ... end` throughout its
  # README and guides, but ships no `:export` block, so the rules have to live
  # here. These belong upstream — see the dogfooding note in CLAUDE.md.
  # Safe alongside `def call(conn, opts)` in Plug modules: `locals_without_parens`
  # only stops the formatter *adding* parens; it never strips them from a
  # definition head.
  locals_without_parens: [
    call: 1,
    call: 2,
    call!: 1,
    call!: 2
  ],
  subdirectories: ["priv/*/migrations"],
  inputs: [
    # `*.exs` does not match dotfiles, so `.formatter.exs` needs naming.
    "{mix,.formatter}.exs",
    "*.{heex,ex,exs}",
    "{config,lib,test}/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs"
  ]
]
