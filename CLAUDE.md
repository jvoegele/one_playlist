# CLAUDE.md — one_playlist

Guidance for Claude Code in this repository. Read this at the start of every session.

`AGENTS.md` (Phoenix-generated) holds the Elixir/Phoenix/LiveView coding conventions and is
authoritative for *how to write code here*. This file holds *what we are building and why*.

---

## The three standing goals

Every design decision in this project is judged against these. They are not equally weighted:
when they conflict, **(1) dogfooding wins over convenience**, and **(2) learning Supabase wins
over picking the tool with the least friction** — but neither is allowed to make the product
worse for its users.

### 1. Dogfood Jason's open-source Elixir libraries

Real, load-bearing use — not token usage. The libraries live in sibling directories and should
be depended on **by path** during development so improvements flow both ways.

| Library | Local path | Where it belongs in this app |
| --- | --- | --- |
| [`external_service`](https://hexdocs.pm/external_service) | `../external_service` (3.0.0-rc.4) | **Every** outbound call to Spotify / Apple Music / YouTube / Tidal / Plex. One service module per provider. |
| [`errata`](https://hexdocs.pm/errata) | `../errata` (1.7.0) | Every error the domain can produce. `TrackNotMatched`, `ProviderUnavailable`, `TokenExpired`, `PlaylistTooLarge`, … |
| [`bond`](https://hexdocs.pm/bond) | `../bond` (1.14.1) | Contracts on the matching engine and the transfer state machine — the places where a silent wrong answer is worse than a crash. |
| [`wait_for_it`](https://hexdocs.pm/wait_for_it) | `../wait_for_it` (2.4.0) | Polling async provider jobs; and `WaitForIt.Test` assertions throughout the test suite. |

```elixir
# mix.exs, during development — this is the working configuration
{:external_service, path: "../external_service"},
{:errata, path: "../errata", override: true},   # external_service also requires it from Hex
{:bond, path: "../bond"},
{:wait_for_it, path: "../wait_for_it"}
```

Verified against Elixir 1.20.3 / OTP 29: all four compile and interoperate. `external_service`
pulls `:fuse` (an Erlang/rebar3 package) from Hex. Note `ExternalService.start/2` returns a
bare `:ok`, not `{:ok, _}`.

Dogfooding includes **reporting friction back**. If an API is awkward, note it in
`docs/library-feedback.md` — that feedback is a deliverable of this project, not a distraction
from it.

Deep reference: **`docs/reference/jv-libraries.md`**. The libraries' own `guides/` directories
are authoritative and worth reading directly.

### 2. Learn Supabase deeply, and use as much of it as possible

Jason is starting a job at Supabase. This project is the vehicle for learning it. Prefer the
Supabase-native way even when a pure-Elixir alternative would be marginally easier, **and say
so explicitly when making that trade**.

Surface area to actually exercise, not just read about: Postgres + RLS, Auth (GoTrue, OAuth,
JWTs), Storage, Realtime, Queues (pgmq), Cron (pg_cron), Vault, pgvector, Edge Functions,
the CLI + local stack + pgTAP, and the Supabase Potion Elixir SDK.

Two things to remember: **Supabase Realtime and Supavisor are themselves Elixir/Phoenix
applications** — reading their source is direct preparation for the job. And where a
Supabase product and an Elixir product genuinely compete (Queues vs Oban, Vault vs
`cloak_ecto`, pg_cron vs Oban Cron), the resolution is *use the better tool for the workload,
and use the Supabase one somewhere deliberately so the lesson is learned*. Never run both for
the same workload.

Deep reference: **`docs/reference/supabase.md`**.

### 3. Build something genuinely useful for real users

Feature parity target: **Soundiiz** and **TuneMyMusic** — playlist/album/artist/liked-track
transfer between streaming services, scheduled sync, import/export, playlist tools.

Deep reference: **`docs/reference/domain.md`**.

---

## Hard constraints — read before promising anything

These are the facts most likely to invalidate a plan. They are not negotiable by writing
better code.

- **Spotify.** New apps are in Development Mode: **max 5 allowlisted users**, and the app
  owner needs Spotify Premium. Extended Quota Mode has required, since May 2025, an
  **organization with ≥ 250,000 MAU**. So Spotify support is a personal/small-group feature,
  not a public product feature, until that changes.
- **YouTube Music.** 10,000 quota units/day per Google Cloud project;
  `playlistItems.insert` costs 50 → **~200 track adds per day in total**. `search.list` costs
  100. Unusable at scale without a quota grant or per-user projects.
- **Apple Music.** Needs an Apple Developer Program membership and a `.p8` MusicKit key. The
  Music User Token can only be obtained **client-side** via MusicKit JS — there is no
  server-only path to a user's library.
- **Deezer.** New API tokens can no longer be obtained. Treat as closed.
- **Amazon Music.** Closed beta; requires a business development contact.
- **Tidal and self-hosted (Plex/Jellyfin/Navidrome/Subsonic/Emby) are open and unlimited.**
  These, plus file import/export, are where a v1 can ship to real users **today**.
- **Supabase does not store or refresh OAuth provider tokens.** `provider_token` and
  `provider_refresh_token` appear once in the session and are then gone. This app must capture,
  encrypt, persist, and refresh them itself. This is core infrastructure, not a detail.

---

## Architecture direction (working assumptions — revisit, don't assume settled)

- **Phoenix 1.8 + LiveView 1.2** app, DaisyUI/Tailwind v4, Bandit, Req (per `AGENTS.md`).
- **Supabase-hosted Postgres**, reached by **Ecto over a direct connection** (or Supavisor
  session mode on IPv4-only hosts). Only use the transaction pooler with `prepare: :unnamed`.
- **Supabase Auth** for sign-in, including Spotify/Google OAuth — chosen over
  `mix phx.gen.auth` because it delivers goals 2 and 3 at once. Phoenix's `current_scope`
  conventions in `AGENTS.md` get adapted around `supabase_auth`'s Plug/LiveView integration.
- **Provider connections** (`provider`, `user_id`, encrypted access + refresh token, expiry,
  scopes) are a first-class context with proactive refresh. This is the highest-risk component.
- **One `ExternalService` module per provider**, each with its own breaker / rate limit /
  concurrency limit sized to that provider's real limits. Honour `Retry-After` explicitly.
- **Matching engine** as a pure, contracted (`Bond`) core: ISRC → UPC+position → normalized
  text + duration → fuzzy → embeddings, producing a confidence value. Never silently drop a
  track; every miss is a typed Errata error in an inspectable report.
- **Oban** for the transfer/sync job pipeline; **Supabase Queues and pg_cron** used
  deliberately elsewhere for learning.
- **Errors**: an application-level `OnePlaylist.Errors.to_error/1` normalizing at boundaries,
  a Phoenix fallback controller driven by `Errata.http_status/1`, and
  `config :errata, redact: [...]` covering every token-shaped key.
- **Bond in production**: preconditions on, everything else `:purge`d (`config/prod.exs`).

---

## Local development

Toolchain is pinned in `.tool-versions` (asdf): **Erlang 29.0.5 / Elixir 1.20.3-otp-29**.

The **Supabase CLI is installed globally via Homebrew** (`brew install supabase/tap/supabase`),
currently **2.115.0**. It is not pinned in `.tool-versions` — the only asdf plugin for it is
third-party. If `config.toml` ever fails to parse, check the CLI version first; the schema is
tied to it.

```sh
supabase start     # boots the stack in Docker (12 containers)
supabase status    # prints URLs and local keys — never commit these, just re-run this
supabase stop      # halts without deleting data
supabase db reset  # re-applies migrations + supabase/seed.sql
```

| Service | URL |
| --- | --- |
| API gateway (REST, GraphQL, Functions, Realtime) | `http://127.0.0.1:54321` |
| Postgres (**17.6**) | `postgresql://postgres:postgres@127.0.0.1:54322/postgres` |
| Studio | `http://127.0.0.1:54323` |
| Mailpit (captures all outbound mail) | `http://127.0.0.1:54324` |

Notes:

- **Port 54322, not 5432.** Jason has a separate local Postgres on 5432; the two coexist and
  the Supabase one is what this project targets.
- Local keys are printed by `supabase status`. The `ANON_KEY`/`SERVICE_ROLE_KEY` JWTs are the
  well-known public Supabase demo keys — worthless, but keep the habit of not committing them.
- `auth.site_url` is set to `http://localhost:4000` (Phoenix), not the CLI's default of
  `:3000`, with `/auth/callback` in `additional_redirect_urls`.
- Extensions confirmed available in the local image: `vector` 0.8.2, `pgmq` 1.5.1, `pg_cron`
  1.6.4, `pg_net` 0.20.4, `pgtap` 1.3.3, `pgsodium` 3.1.8. `supabase_vault`, `pgcrypto`,
  `uuid-ossp` and `pg_stat_statements` are installed already.
- Docker Desktop's VM disk is 60 GB and *not* the same as host free space. If image pulls fail
  with "no space left on device", check `docker system df` — that is the real limit.

### Both `dev` and `test` use the `postgres` database

Not `one_playlist_dev` / `one_playlist_test`. This is forced, not stylistic: every Supabase
service is wired to the `postgres` database, and the `auth` / `storage` / `realtime` schemas
exist **only** there — a freshly created database inherits none of them from `template1`
(verified). Our tables have to live in `postgres` or PostgREST, Realtime and Storage cannot see
them and `auth.uid()` does not exist, which would make RLS untestable.

Test isolation therefore comes from the **Ecto SQL sandbox** rather than a separate database.
Verified empirically: a test that runs `create table` + `insert` leaves nothing behind, and
repeated runs do not accumulate. The trade-off is that a test escaping the sandbox would be
visible in dev; the gain is that tests see the real `auth` schema, the real
`anon`/`authenticated`/`service_role` roles, and real `auth.uid()`.

- **Never run `mix ecto.drop`.** It would delete the Supabase database out from under the
  running stack. `mix ecto.reset` has been redefined to `supabase db reset` + `ecto.migrate`.
- `MIX_TEST_PARTITION` is unusable here — it partitions by creating one database per partition.
- The test pool is capped at 16 (not the usual `schedulers_online() * 2` = 32): Supabase's own
  services already hold ~32 of the cluster's 100 connections.
- Ecto's `public.schema_migrations` coexists fine with Supabase's `supabase_migrations` schema.

### Migration convention: RLS is not on by default

Tables created in `public` are **not** protected until you say so, and Supabase's default
privileges already grant `anon`/`authenticated` a partial set on new tables (`TRUNCATE`,
`REFERENCES`, `TRIGGER` — verified on `schema_migrations`). Not currently reachable, since
those roles are only exposed through PostgREST and it issues no `TRUNCATE`, but it means the
starting position for a new table is "partially granted, unprotected".

So **every migration that creates a table in `public` must**: `enable row level security`,
`revoke all` from `anon, authenticated`, then `grant` only what that table genuinely needs, and
add policies with an explicit `TO` role. See `docs/reference/supabase.md` for the full pattern
and the `(select auth.uid())` performance note. `public.schema_migrations` should get a
`revoke all ... from anon, authenticated` alongside the first real migration.

## Tooling

`mix precommit` is the gate; it runs everything below plus the tests, ordered cheapest-first.
`mix ci` is the same minus the formatter's rewriting (it checks instead of fixing) and with
coverage.

| Tool | What it is for |
| --- | --- |
| `mix credo --strict` | Style and consistency over `lib/` and `mix.exs`. Tests are deliberately outside the gate. |
| `mix dialyzer` | Type analysis. ~2s once the PLT exists. |
| `mix sobelow --exit` | Phoenix security scanner — XSS, CSRF, config, SQL injection. |
| `mix deps.audit` | Dependencies against the Elixir security advisory database. |
| `mix coveralls.html` | Test coverage report. |
| `mix docs` | ExDoc, including the `docs/reference/` material as extras. |

**First run on a fresh checkout:** `mix dialyzer --plt` builds the PLT (~30s, one-off). It is
stored under `priv/plts/`, which is gitignored — kept out of `_build` so `mix clean` or an env
switch does not throw it away.

Two configuration decisions worth not re-litigating, both recorded in place:

- `.credo.exs` must not gain an `enabled:` list. `checks: %{enabled: [...]}` **replaces** the
  default check set rather than adding to it — measured here as 1 check running instead of 68.
- Dialyzer's `:extra_return` flag is off. It fires on every Errata-generated `code/1` and
  `retryable?/1`, and the count would grow with each error type we define.

**Bond contract coverage** prints after every `mix test` run (`config :bond, coverage: true`).
An assertion marked `⚠ never failed` is a prompt: either write a test proving it can fail, or
delete it. `test/test_helper.exs` carries a workaround for a Bond bug — see
`docs/library-feedback.md`.

## Working agreements

- Run `mix precommit` when a change is complete and fix everything it reports.
- Prefer reading a library's `guides/` over guessing at its API; these libraries are unusually
  well documented and the guides are executed in CI.
- When a decision trades one standing goal against another, **state the trade in the commit
  message or the PR body** — that record is part of the project's value.
- Keep `docs/reference/*.md` current as understanding deepens. They exist so a fresh session
  starts informed.
- Nothing about a user's OAuth tokens is ever logged, serialized into an error context
  unredacted, or sent to a third party.

---

## Reference documents

| File | Contents |
| --- | --- |
| `AGENTS.md` | Phoenix/Elixir/LiveView coding conventions (generated; authoritative for code style) |
| `docs/reference/jv-libraries.md` | Deep reference for `external_service`, `errata`, `bond`, `wait_for_it` |
| `docs/reference/supabase.md` | Supabase platform reference oriented to Elixir/Phoenix |
| `docs/reference/domain.md` | Soundiiz/TuneMyMusic feature analysis, track matching, platform API limits |
| `docs/library-feedback.md` | Running log of friction found while dogfooding the four libraries |
