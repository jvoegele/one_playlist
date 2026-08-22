defmodule OnePlaylist.MixProject do
  use Mix.Project

  def project do
    [
      app: :one_playlist,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: dialyzer(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        credo: :test,
        sobelow: :test
      ],
      docs: docs()
    ]
  end

  defp dialyzer do
    [
      # PLTs live in the repo (gitignored) rather than under _build, so a
      # `mix clean` or an env switch does not throw away several minutes of
      # work. plt_core_path holds the Erlang/Elixir core, which changes only
      # when the toolchain does.
      plt_local_path: "priv/plts/project.plt",
      plt_core_path: "priv/plts/core.plt",
      # :mix and :ex_unit are not runtime deps, but the Mix task and the test
      # helpers are still code Dialyzer should understand.
      plt_add_apps: [:mix, :ex_unit],
      flags: [
        :error_handling,
        :no_opaque,
        :unmatched_returns,
        # Catches a spec that promises a return the body can never produce.
        :missing_return
        #
        # `:extra_return` is deliberately absent. It flags a spec *wider* than
        # the success typing, which is precisely the shape of every Errata
        # error module: the generated `code/1` is specced `String.t() | nil`
        # while a type declaring `code: "..."` only ever returns that string,
        # and `retryable?/1` is specced `boolean()` while a domain error only
        # ever returns `false`. Those generated specs are right — they state the
        # behaviour's contract, not one implementation of it — so the warning is
        # noise that would recur for every error type we define. See
        # docs/library-feedback.md.
      ]
    ]
  end

  defp docs do
    [
      main: "OnePlaylist",
      extras: [
        "CLAUDE.md",
        "docs/reference/jv-libraries.md",
        "docs/reference/supabase.md",
        "docs/reference/domain.md",
        "docs/library-feedback.md"
      ],
      groups_for_extras: [Reference: ~r/docs\/reference\//],
      groups_for_modules: [
        Providers: ~r/OnePlaylist\.Providers/,
        Encryption: [OnePlaylist.Vault, OnePlaylist.Encrypted.Binary]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {OnePlaylist.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, ci: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # Application-side encryption for third-party OAuth tokens, so plaintext
      # never reaches Postgres. See docs/reference/supabase.md.
      {:cloak_ecto, "~> 1.3"},

      # First-party libraries, depended on by path so that improvements can flow
      # in both directions while this project dogfoods them. See CLAUDE.md.
      # `:errata` is overridden because `:external_service` also requires it from Hex.
      # L1 of the catalogue cache. Chosen for `Nebulex.Adapters.Local`'s
      # generational eviction, which bounds memory without the flush-everything
      # cliff a hand-rolled cap produces. See OnePlaylist.Cache.
      # The transfer/sync job pipeline. Postgres-backed, which matters here:
      # the queue lives in the same database as the transfers it drives, so a
      # job and the row it advances commit or roll back together.
      {:oban, "~> 2.23"},
      {:nebulex, "~> 3.0"},
      {:nebulex_local, "~> 3.0"},
      {:external_service, path: "../external_service"},
      {:errata, path: "../errata", override: true},
      {:bond, path: "../bond"},
      {:wait_for_it, path: "../wait_for_it"},

      # Property-based testing. Not just for our own properties: it is what
      # unlocks `Bond.PropertyTest`, which uses the contracts we have already
      # written as the oracle. See docs/reference/jv-libraries.md.
      {:stream_data, "~> 1.0", only: [:dev, :test]},

      # Static analysis and linting.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Phoenix-specific security scanner: XSS in templates, CSRF gaps, config
      # mistakes, SQL injection. Worth having in any Phoenix app; worth more in
      # one holding third-party OAuth tokens.
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      # Checks dependencies against the Elixir security advisory database.
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create --quiet", "ecto.migrate", "run priv/repo/seeds.exs"],
      # `ecto.drop` would delete the local Supabase database out from under the
      # running stack, taking auth/storage/realtime with it. `supabase db reset`
      # is the safe equivalent: it rebuilds the Supabase base schemas and
      # re-applies supabase/migrations, after which our Ecto migrations go on top.
      "ecto.reset": ["cmd supabase db reset", "ecto.migrate", "run priv/repo/seeds.exs"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind one_playlist", "esbuild one_playlist"],
      "assets.deploy": [
        "tailwind one_playlist --minify",
        "esbuild one_playlist --minify",
        "phx.digest"
      ],
      # The gate to run before considering a change done. Ordered cheapest-first
      # so an obvious failure surfaces without waiting for the slow steps.
      #
      # Dialyzer is included because it costs ~2s once the PLT exists. Building
      # that PLT is a one-off ~30s, so the first run on a fresh checkout is slow
      # — `mix dialyzer --plt` gets it out of the way deliberately.
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "sobelow --exit",
        "deps.audit",
        "dialyzer",
        "test"
      ],
      # Everything precommit runs, minus the formatter's rewriting: CI should
      # fail on unformatted code rather than quietly fixing it.
      ci: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "sobelow --exit",
        "deps.audit",
        "dialyzer",
        # Broken `Module.fun/arity` references in docs are silent until someone
        # builds them. Caught one this way: docs/library-feedback.md cited
        # `ExternalService.call/1`, which does not exist — `call/1` is generated
        # on the front-door module, not exported by ExternalService.
        #
        # Runs in :dev because ex_doc is `only: :dev`, unlike everything above it.
        "cmd env MIX_ENV=dev mix docs",
        "coveralls"
      ]
    ]
  end
end
