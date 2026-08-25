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
      docs: docs(),
      usage_rules: usage_rules()
    ]
  end

  # Where `mix usage_rules.sync` puts what our dependencies say about
  # themselves. `AGENTS.md` is already the authoritative file for how code is
  # written here, so the rules land beside the Phoenix conventions rather than
  # in a file of their own.
  #
  # **The list is named explicitly, and both halves of that are deliberate.**
  #
  # `sync` treats this config as the source of truth and **deletes any managed
  # block not named in it**. So `[:bond]` alone would silently remove the five
  # Phoenix blocks that were already here — naming `:phoenix` beside it is what
  # keeps them. A parent pulls its own sub-rules in, which is why neither needs
  # `"bond:all"` or `"phoenix:all"` spelling out; naming both a parent and its
  # `:all` duplicates the lot.
  #
  # The alternative, `:all`, auto-discovers every dependency that ships rules,
  # and measured here that is 3755 lines where 1300 are wanted. It pulls in
  # 2080 lines of Nebulex — a cache adapter used for one module's L1 tier —
  # along with `sobelow` and `usage_rules`' own rules about itself. Two of those
  # are a *third* and *fourth* general Elixir style guide sitting beside
  # `phoenix:elixir`, from libraries with no reason to agree with each other or
  # with us. `AGENTS.md` is read at the start of every session, so its size is a
  # standing cost and disagreement in it is worse than absence.
  #
  # Add a dependency here when this project writes code *against* it and its
  # rules would change what that code looks like. That is the test `nebulex`
  # fails and `bond` passes.
  #
  # `docs/reference/contracts.md` stays authoritative for this project's house
  # style; these are the library-level layer beneath it, and much of Bond's was
  # distilled from that file in the first place.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [:bond, :phoenix],
      skills: [
        location: ".claude/skills",
        package_skills: [:bond]
      ]
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

  # Grouped by where the code lives rather than by module name, and that is
  # forced rather than chosen. ExDoc matches a regex against the module *name*,
  # but hands a **function** only the module's metadata — `:kind`,
  # `:behaviours`, `:source_path` — never the name. A group that means "this
  # part of the application, except the errors in it" therefore has to be a
  # function, and a function can only match on the file.
  #
  # It has to mean that because `groups_for_modules` is one list serving two
  # jobs: `Enum.find_value/2` picks the first pattern that matches, and
  # `Enum.find_index/2` on the same list decides where the group is drawn. Match
  # order *is* display order. So a group that must be matched before the others
  # is also drawn before them — which is why `Errors` can only sit at the bottom
  # if every group above it declines to claim an error module first.
  #
  # `source/1` is that declining. Everything else follows from it.
  defp groups_for_modules do
    [
      # The landing page, and the only module that names no part of the tree.
      Overview: [OnePlaylist],

      # The vocabulary every other group is written in.
      Music: source(~r{/one_playlist/music/}),

      # The technical core, and then the rungs of its ladder. The lookahead is
      # what lets the shared module be listed above the strategies rather than
      # below them, since the more specific pattern would otherwise have to win
      # by being first.
      Matching: source(~r{/one_playlist/matching(\.ex$|/(?!strategy))}),
      "Matching: the ladder": source(~r{/one_playlist/matching/strategy}),

      # The pipeline that drives it.
      Transfers: source(~r{/one_playlist/transfers(\.ex$|/)}),

      # The behaviour and the shared types, then one group per service. The same
      # lookahead device, and it is also what puts `subsonic_credentials.ex`
      # with Subsonic rather than in the shared group.
      Providers: source(~r{/one_playlist/providers(\.ex$|/(?!tidal|subsonic|navidrome))}),
      "Providers: TIDAL": source(~r{/one_playlist/providers/tidal(\.ex$|/)}),
      "Providers: Subsonic": source(~r{/one_playlist/providers/(subsonic|navidrome)}),

      # Playlists that are files rather than services — the counterpart to
      # Providers, and deliberately not modelled as one. `nimble_csv` is here
      # because `NimbleCSV.define/2` generates our two separator parsers with
      # their source pointing into the dependency; matching the dependency
      # rather than naming them keeps a third separator from being stranded.
      "Playlist files":
        source(~r{/one_playlist/(formats(\.ex$|/)|imports\.ex$|exports\.ex$)|/nimble_csv/}),

      # The outside reference data, and the two tiers that keep us off it.
      MusicBrainz: source(~r{/one_playlist/musicbrainz(\.ex$|/)}),
      "Catalogue and caching": source(~r{/one_playlist/(catalogue|cache)(\.ex$|/)}),

      # Who is asking, and what is kept for them.
      Accounts: source(~r{/one_playlist/accounts(\.ex$|/)}),
      "Storage and encryption":
        source(~r{/one_playlist/(storage(\.ex$|/)|vault\.ex$|encrypted/)}),

      # The seams onto Postgres, Supabase and OTP.
      Platform: source(~r{/one_playlist/(repo|supabase|application|mailer)\.ex$}),

      # Everything web-facing, kept apart from the contexts above. The last of
      # these is a catch-all and must stay last of the four.
      "Web: pages": source(~r{/one_playlist_web/live/}),
      "Web: controllers": source(~r{/one_playlist_web/controllers/}),
      "Web: components": source(~r{/one_playlist_web/components/}),
      "Web: plumbing": source(~r{/one_playlist_web}),

      # Every error the domain can produce, in one list — the errata sheet
      # `errata` is named for, and last because that is where a reader expects
      # a reference section rather than a chapter.
      #
      # ExDoc appends its own `Exceptions` group after this list and would
      # collect these unaided; declaring it here costs one line and names the
      # group for what these are. Either way the test is `:kind`, which is what
      # the module *is*. Deliberately not a rule about names: nothing here is
      # called `*Error`, Errata's own README names its examples `OrderNotFound`
      # and `PaymentDeclined`, and a naming rule would strand the first error
      # type somebody spelled differently.
      Errors: &(&1[:kind] == :exception)
    ]
  end

  # A group that matches on the module's source file, and never on an error.
  #
  # The second half is the load-bearing one: it is what leaves every error type
  # unclaimed for the `Errors` group at the bottom of the list. Without it they
  # are swallowed by whichever part of the tree they happen to live in, which is
  # how seven of them once ended up under `Providers` and the other eight under
  # ExDoc's automatic `Exceptions` bucket.
  defp source(pattern) do
    fn metadata ->
      metadata[:kind] != :exception and
        Regex.match?(pattern, to_string(metadata[:source_path]))
    end
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
      {:bond, "~> 1.17"},
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
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Collects the usage rules a dependency ships for AI coding agents into
      # `AGENTS.md`, and installs any skills it carries. See `usage_rules/0`.
      {:usage_rules, "~> 1.2", only: [:dev]}
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
      #
      # `docs` is here for the same reason and was not, which is why the broken
      # references the `ci` note below describes kept arriving one per session:
      # this is the gate anyone actually runs, and it was the one that could not
      # see them. It costs ~1.7s, and needs the same `MIX_ENV=dev` hop `ci` uses,
      # because `ex_doc` is `only: :dev` while this alias runs in `:test`.
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "sobelow --exit",
        "deps.audit",
        "dialyzer",
        "cmd env MIX_ENV=dev mix docs --warnings-as-errors",
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
