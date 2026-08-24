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
        # `contracts.md` is cited by sixteen modules in `lib/` and was missing
        # from this list, so every one of those references pointed at a page
        # that was never published.
        "docs/reference/domain.md",
        "docs/reference/contracts.md",
        "docs/reference/jv-libraries.md",
        "docs/reference/supabase.md",
        "docs/library-feedback.md",
        "docs/supabase-sdk-issues.md"
      ],
      groups_for_extras: [
        Reference: ~r/docs\/reference\//,
        Findings: ~r/docs\/(library-feedback|supabase-sdk-issues)\.md/
      ],
      groups_for_modules: groups_for_modules()
    ]
  end

  # Patterns rather than lists of module names, so a module added to a namespace
  # is grouped without anyone remembering to come back here. The one exception is
  # `OnePlaylist` itself, which names no namespace of its own.
  #
  # Order is both match order and display order — the first pattern to match wins
  # — so the groups that carve a subset out of a wider namespace use a negative
  # lookahead rather than relying on being listed first. That keeps the sidebar
  # in reading order (the shared thing above the specific ones) instead of in
  # whatever order the matching happens to require.
  #
  # Anything left unmatched falls through to ExDoc's own categories: "Modules",
  # plus an automatic "Exceptions" bucket for anything that defines one. That
  # bucket is what put seven of this application's error types under `Providers`
  # and the other eight under `Exceptions`, which is the split these patterns
  # exist to remove — every error now sits with the domain that raises it.
  defp groups_for_modules do
    [
      # The landing page, and the only module that is not part of a namespace.
      Overview: [OnePlaylist],

      # The vocabulary every other group is written in.
      Music: ~r/^OnePlaylist\.Music\./,

      # The technical core, and then the rungs of its ladder.
      Matching: ~r/^OnePlaylist\.Matching($|\.(?!Strategy))/,
      "Matching: the ladder": ~r/^OnePlaylist\.Matching\.Strategy($|\.)/,

      # The pipeline that drives it.
      Transfers: ~r/^OnePlaylist\.Transfers($|\.)/,

      # The behaviour and the shared types, then one group per service. TIDAL
      # and Subsonic are excluded from the first by lookahead, which is also
      # what puts `SubsonicCredentials` with Subsonic rather than in the
      # shared group.
      Providers: ~r/^OnePlaylist\.Providers($|\.(?!Tidal|Subsonic|Navidrome))/,
      "Providers: TIDAL": ~r/^OnePlaylist\.Providers\.Tidal($|\.)/,
      "Providers: Subsonic": ~r/^OnePlaylist\.Providers\.(Subsonic|Navidrome)/,

      # Playlists that are files rather than services — the counterpart to
      # Providers, and deliberately not modelled as one.
      "Playlist files": ~r/^OnePlaylist\.(Formats($|\.)|Imports$|Exports$)/,

      # The outside reference data, and the two tiers that keep us off it.
      MusicBrainz: ~r/^OnePlaylist\.MusicBrainz($|\.)/,
      "Catalogue and caching": ~r/^OnePlaylist\.(Catalogue|Cache)($|\.)/,

      # Who is asking, and what is kept for them.
      Accounts: ~r/^OnePlaylist\.Accounts($|\.)/,
      "Storage and encryption": ~r/^OnePlaylist\.(Storage($|\.)|Vault$|Encrypted\.)/,

      # The seams onto Postgres, Supabase and OTP.
      Platform: ~r/^OnePlaylist\.(Repo|Supabase|Application|Mailer)$/,

      # Everything web-facing, kept apart from the contexts above. The last of
      # these is a catch-all and must stay last.
      "Web: pages": ~r/^OnePlaylistWeb\.\w+Live\./,
      "Web: controllers": ~r/^OnePlaylistWeb\.\w*(Controller|HTML|JSON)$/,
      "Web: components": ~r/^OnePlaylistWeb\.(\w*Components|Layouts)$/,
      "Web: plumbing": ~r/^OnePlaylistWeb($|\.)/
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

      # RFC 4180 CSV. Hand-rolling this is a classic own goal: quoting, embedded
      # newlines, CRLF and Excel's UTF-8 BOM are each a bug waiting to be found
      # by a user's real export rather than by us.
      {:nimble_csv, "~> 1.2"},
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

      # Supabase Auth (GoTrue), via the community Elixir SDK. Used for the API
      # calls only — `OnePlaylistWeb.UserAuth` keeps owning the session, the
      # plug and the `on_mount`, because that is the layer that has to inject
      # JWT claims into Postgres for RLS. See docs/reference/supabase.md.
      {:supabase_potion, "~> 0.8"},
      {:supabase_auth, "~> 1.0"},
      {:supabase_storage, "~> 0.6"},

      # First-party libraries, from Hex rather than by path. See CLAUDE.md: the
      # path deps are the dogfooding mechanism and this is a deliberate step
      # back from them, taken because a mid-refactor in a sibling checkout twice
      # stopped work here — the second time by renaming a function whose caller
      # had not been updated, which failed every module in this project carrying
      # a precondition.
      #
      # Switch a single dep back to `path:` when actively working on that
      # library with this application; that is a one-line change and the reason
      # these are listed one per line.
      #
      # `external_service` is a release candidate, so the version is exact: `~>`
      # does not match pre-releases from a non-pre-release requirement.
      # L1 of the catalogue cache. Chosen for `Nebulex.Adapters.Local`'s
      # generational eviction, which bounds memory without the flush-everything
      # cliff a hand-rolled cap produces. See OnePlaylist.Cache.
      # The transfer/sync job pipeline. Postgres-backed, which matters here:
      # the queue lives in the same database as the transfers it drives, so a
      # job and the row it advances commit or roll back together.
      {:oban, "~> 2.23"},
      {:nebulex, "~> 3.0"},
      {:nebulex_local, "~> 3.0"},
      {:external_service, "3.0.0-rc.4"},
      {:errata, "~> 1.7"},
      {:bond, "~> 1.15"},
      {:wait_for_it, "~> 2.4"},

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
      # RLS policies are enforced by Postgres, so they are tested in Postgres.
      # Deliberately *not* part of `precommit`: it needs the Docker stack up,
      # which `mix test` does not. See supabase/tests/rls.test.sql.
      "test.rls": ["cmd supabase test db"],
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
        # `--warnings-as-errors` because without it this step *reported* six
        # broken references and passed anyway, which is how they accumulated
        # over several sessions. The commonest cause is a callback written as
        # `Mod.fun/arity`: ExDoc resolves that as a function and needs `c:` for
        # a callback.
        #
        # Runs in :dev because ex_doc is `only: :dev`, unlike everything above it.
        "cmd env MIX_ENV=dev mix docs --warnings-as-errors",
        "coveralls"
      ]
    ]
  end
end
