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

> #### Depended on from Hex, not by path {: .warning}
>
> `mix.exs` pins all four to Hex releases. The path deps described below are the
> dogfooding mechanism and this is a deliberate step back from them, taken 2026-08-23 after a
> mid-refactor in a sibling checkout stopped work here twice — the second time by renaming a
> compiler function whose caller had not been updated, which failed every module in this
> project carrying a precondition.
>
> Switch a single dependency back to `path:` when actively working on that library together
> with this application. That is a one-line change, and it is why they are listed one per line.
> The intent below is unchanged: improvements still flow both ways, just through a release.

| Library | Local path | Where it belongs in this app |
| --- | --- | --- |
| [`external_service`](https://hexdocs.pm/external_service) | `../external_service` (3.0.0-rc.4) | **Every** outbound call to Spotify / Apple Music / YouTube / Tidal / Plex. One service module per provider. |
| [`errata`](https://hexdocs.pm/errata) | `../errata` (1.7.0) | Every error the domain can produce. `TrackNotMatched`, `ProviderUnavailable`, `TokenExpired`, `PlaylistTooLarge`, … |
| [`bond`](https://hexdocs.pm/bond) | `../bond` (1.14.1) | Contracts on the matching engine and the transfer state machine — the places where a silent wrong answer is worse than a crash. |
| [`wait_for_it`](https://hexdocs.pm/wait_for_it) | `../wait_for_it` (2.4.0) | `Transfers.await/2` waits on an Oban-run transfer with `case_wait`. Deeper use still ahead: scheduled sync, and polling providers with genuinely async jobs. |

```elixir
# mix.exs — the working configuration
{:external_service, "3.0.0-rc.4"},   # exact: `~>` does not match a pre-release
{:errata, "~> 1.7"},
{:bond, "~> 1.15"},                  # 1.15.0 or later: earlier cannot compile
{:wait_for_it, "~> 2.4"}             # an @invariant on an Ecto.Schema
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
  `mix phx.gen.auth` because it delivers goals 2 and 3 at once. Email + password is built;
  magic link and Google OAuth are next, and all three feed one session spine.
  The `supabase_auth` SDK is used for the **GoTrue API calls only**: the session, the plug and
  the `on_mount` stay in `OnePlaylistWeb.UserAuth`, because that is the layer that will have
  to inject JWT claims into Postgres for RLS. `current_scope` is a shim over our own session
  struct. **The `Agent`-based `use Supabase.Client` pattern is deprecated for security
  reasons** — build the client per call. See `docs/reference/supabase.md`.
- **The session cookie is encrypted, not merely signed**, because it carries the GoTrue
  refresh token. That is a departure from the Phoenix default and `OnePlaylistWeb.Endpoint`
  says why.
- **RLS applies to this application's own reads and to its `provider_connections` writes**,
  via `OnePlaylist.Repo.as_user/3`: a
  transaction that steps down from `postgres` (which holds `BYPASSRLS`) to `authenticated`
  and sets the claims `auth.uid()` reads. The user-facing reads in `Providers` and
  `Transfers` run inside it, so a forgotten `where user_id` returns nothing rather than
  everybody's rows. Writes and background work stay privileged — `authenticated` has no
  access to the `oban` schema and only `select` on transfers, which is the grants saying
  users read their transfers while the system writes them.
  `as_user/3` is **re-entrant** — it restores whatever scope it found rather than reverting to
  `postgres` — because `disconnect/2` nests `fetch_connection/2` inside itself.
  Four traps, all documented in `docs/reference/supabase.md`: `auth.uid()` prefers the
  *singular* `request.jwt.claim.sub`, so set and clear both; `SET LOCAL` is not undone by
  releasing a savepoint, which is what the Ecto sandbox gives you; a constraint violation
  inside the scope aborts the transaction and its `25P02` replaces the real error, so writes
  use `mode: :savepoint`; and reads, updates and deletes of another user's row fail
  *silently* while an insert raises `42501`.
- **Provider connections** (`provider`, `user_id`, encrypted access + refresh token, expiry,
  scopes) are a first-class context with proactive refresh. This is the highest-risk component.
- **One `ExternalService` module per provider**, each with its own breaker / rate limit /
  concurrency limit sized to that provider's real limits. Honour `Retry-After` explicitly.
- **Matching engine** as a pure, contracted (`Bond`) core: ISRC → UPC+position → normalized
  text + duration → fuzzy → embeddings, producing a confidence value. Never silently drop a
  track; every miss is a typed Errata error in an inspectable report.
- **Oban** for the transfer/sync job pipeline; **Supabase Queues and pg_cron** used
  deliberately elsewhere for learning. `pg_cron` is in use as of the catalogue cache: it prunes
  expired negative lookups nightly, scheduled from the migration and best-effort so a project
  without the extension still migrates.
- **Catalogue cache** in two tiers — `OnePlaylist.Cache` (Nebulex, per node) over
  `catalogue_release_lookups` in Postgres (shared, survives deploys), with request coalescing
  in `OnePlaylist.Cache.Singleflight`. Nebulex is used for L1 only and deliberately not for L2:
  `nebulex_adapters_ecto` pins to `nebulex ~> 2.5`, and L2 is a queryable domain table with RLS
  and scheduled pruning rather than opaque cache rows. This is the first table here whose rows
  **belong to nobody**, so the usual `auth.uid()` policy shape does not apply — see the
  migration for the reasoning.
- **Errors**: an application-level `OnePlaylist.Errors.to_error/1` normalizing at boundaries,
  a Phoenix fallback controller driven by `Errata.http_status/1`, and
  `config :errata, redact: [...]` covering every token-shaped key.
- **Bond in production**: preconditions on, everything else `false` — compiled in but gated,
  so postconditions can be enabled from a remote console mid-incident via `Bond.Config`
  (`config/prod.exs`). Not `:purge`d, which would leave nothing to enable.

---

## Local development

Toolchain is pinned in `.tool-versions` (asdf): **Erlang 29.0.5 / Elixir 1.20.3-otp-29**.

The **Supabase CLI is installed globally via Homebrew** (`brew install supabase/tap/supabase`),
currently **2.115.0**. It is not pinned in `.tool-versions` — the only asdf plugin for it is
third-party. If `config.toml` ever fails to parse, check the CLI version first; the schema is
tied to it.

### Navidrome — the second provider, run locally

```sh
docker compose -f dev/navidrome/docker-compose.yml up -d
python3 dev/navidrome/generate_library.py        # 30 tracks; --no-isrc for the hard case
open http://localhost:4533                       # admin / oneplaylist
bin/remote dev/navidrome/connect.exs             # attaches it to a signed-up user
```

The last step is scripted convenience, not the only way in: `/connections` has a form, and
the script calls the same `Providers.connect_subsonic/2` it does. Use the script to rebuild an
environment without a browser; use the form when testing what a user actually experiences.

Port **4533**. The sample library is *synthetic audio with real metadata* taken from the TIDAL
corpus — so it matches against TIDAL, and no copyrighted audio is in the repository. Both the
music and Navidrome's database are gitignored; the generator and compose file are not.

Subsonic is deliberately unlike TIDAL — token auth with no expiry, flat JSON, HTTP 200 on
failure, ISRC as an array. See `docs/reference/domain.md`. It exists to find the places the
adapter behaviour encoded TIDAL's assumptions.

```sh
supabase start     # boots the stack in Docker (12 containers)
supabase status    # prints URLs and local keys — never commit these, just re-run this
supabase stop      # halts without deleting data
supabase db reset  # re-applies migrations + supabase/seed.sql
```

#### Scheduled Storage pruning needs two Vault secrets

`public.prune_stored_exports/1` deletes old export files by calling the Storage API through
`pg_net`, which needs a credential. The migration deliberately does **not** create it: a
migration is committed and a service role key must not be. Without the secrets the function
reports and returns zero, so a fresh checkout migrates and runs its other jobs normally.

```sh
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" <<SQL
select vault.create_secret(
  'http://supabase_kong_one_playlist:8000', 'one_playlist_storage_url',
  'Base URL pg_net uses to reach Supabase Storage');
select vault.create_secret(
  '$(supabase status -o env | grep ^SERVICE_ROLE_KEY= | cut -d= -f2- | tr -d '"')',
  'one_playlist_service_key',
  'Service role key for scheduled Storage pruning');
SQL
```

The URL is a **container name**, not `127.0.0.1:54321`: `pg_net` runs inside Postgres, which is
in its own container and cannot see the host's port mapping. In production it is the project
URL. Both values change per environment, which is why the URL is a secret rather than a
constant in the migration.

`vault.decrypted_secrets` is readable by `postgres` and `service_role` only, so a compromised
`authenticated` session cannot reach the key. The application itself never uses it:
`OnePlaylist.Storage` acts as the signed-in user, so the bucket policies apply to everything
outside this one scheduled function.

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
One consequence to keep in mind when writing assertions: **never assert on a global row count**.
The sandbox rolls back what a test writes; it does not hide the dev data already sitting in the
same tables, so `Repo.aggregate(Transfer, :count) == 0` fails against a database somebody has
been using. Scope the count to the test's own user.
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

### A test that writes global state cannot be `async: true`

Cost a day's worth of confusion twice now, in two different disguises, and the symptom is the
same both times: **an unrelated test fails, about one run in seven.**

  * `Req.Test` stubs registered under the same name by several `async: true` files, without
    per-test ownership. Fixed with `setup :set_req_test_from_context`.
  * `Application.put_env/3` in an `async: true` test, nulling out `client_id` to prove
    `OAuth.config/0` reports it missing. Every concurrent TIDAL test in that window got
    `NotConfigured`. Fixed by moving that one test to its own `async: false` file — ExUnit runs
    sync tests after every async one has finished, so nothing is left running to see the
    mutation.

Diagnosing these is worth a checklist, because the failing test is never the guilty one:

1. Run the suspect file **alone**, repeatedly. Clean in isolation and flaky in the suite means
   cross-file shared state, full stop.
2. Read the actual failure message rather than theorising from the test's name. The second bug
   above was mistaken for circuit-breaker exhaustion — a plausible story, since
   `Tidal.Service` tolerates 5 failures within 30s and the suite finishes in 3 — and the fix
   built on it changed twelve files and did nothing. The message said `NotConfigured`, which
   named the real cause immediately.
3. `grep -rn "put_env\|delete_env" test/` before anything else.

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

### Running the app, and probing it while it runs

Start the server **as a named node**, so it can be reached without stopping it:

```sh
elixir --sname oneplaylist --cookie oneplaylist-dev -S mix phx.server
```

Then evaluate a script inside the running server with `bin/remote`:

```sh
bin/remote path/to/probe.exs
```

This exists because `mix run` boots a second copy of the application, which then
fails to bind port 4000 while the server holds it — and stopping the server for every probe
drops whatever the browser was mid-way through. `bin/remote` scripts see the same processes,
the same `ExternalService` breakers and rate limiters, and the same connections as live
requests, which also means a probe is subject to the same rate limiting rather than quietly
bypassing it.

**Write probes that return values.** The script is evaluated on the server, so `IO.puts` inside
one lands in the *server log*; only the final value comes back to the caller. See the header of
`bin/remote` for the details, including why a closure cannot be used across the node boundary.

The cookie is a local convenience, not a secret — the node listens only on loopback via epmd.

> #### `bin/remote` can kill a running Oban job {: .warning}
>
> Every probe calls `Phoenix.CodeReloader.reload/1`, and loading a module a second time
> **purges** the oldest copy, killing any process still executing it. A background job caught
> mid-flight dies without Oban being told, and its row sits in `executing` with no process
> behind it — which looks exactly like a hang.
>
> Diagnose it by looking for the process rather than by waiting: nothing in `Process.list/0`
> with `Enrichment`, `ExternalService` or a provider module on its stack means the row is stale,
> not busy. `Oban.retry_job/1` will **not** move it — that only acts on finished jobs.
> `Oban.Plugins.Lifeline` is what rescues it, after `rescue_after` (30 minutes here), and doing
> the same `update … set state = 'available'` by hand is safe once the row is confirmed stale.
>
> So: probe freely while the queues are idle, and expect this while a backfill is draining.

### Local credentials

Real provider credentials for driving the live APIs go in **`config/dev_local.exs`**, which is
gitignored. `config/dev_local.example.exs` is the committed template:

```sh
cp config/dev_local.example.exs config/dev_local.exs
```

It is imported at the end of `config/dev.exs`, so it wins over everything above it.
`config/runtime.exs` runs later still but only assigns keys whose environment variable is
actually set, so an unset `TIDAL_CLIENT_ID` does not clobber the file. Environment variables
remain the right answer in production.

Redirect URIs must be registered on the provider's application **byte for byte** — a mismatch
fails at the authorize step with an error that does not say which part disagreed.

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
| `mix test.rls` | pgTAP tests for the RLS policies themselves, run inside Postgres. Needs the Docker stack up, so it is outside `precommit`. |

**First run on a fresh checkout:** `mix dialyzer --plt` builds the PLT (~30s, one-off). It is
stored under `priv/plts/`, which is gitignored — kept out of `_build` so `mix clean` or an env
switch does not throw it away.

Two configuration decisions worth not re-litigating, both recorded in place:

- `.credo.exs` must not gain an `enabled:` list. `checks: %{enabled: [...]}` **replaces** the
  default check set rather than adding to it — measured here as 1 check running instead of 68.
- Dialyzer's `:extra_return` flag is off. It fires on every Errata-generated `code/1` and
  `retryable?/1`, and the count would grow with each error type we define.

Depends on **bond 1.15.0 or later**: earlier versions cannot compile an `@invariant` on an
`Ecto.Schema`, which is where three of this project's domain types keep their laws.

**Bond contract coverage** prints after every `mix test` run (`config :bond, coverage: true`).
An assertion marked `⚠ never failed` is a prompt: either write a test proving it can fail, or
delete it. Before adding or changing any contract, read **`docs/reference/contracts.md`** — it
is the house style, and every rule in it was learned by getting something wrong first. (The `:ets.new/2` workaround `test/test_helper.exs` used to carry for this is gone as of
bond 1.15.0.)

## Working agreements

- Run `mix precommit` when a change is complete and fix everything it reports.
- Prefer reading a library's `guides/` over guessing at its API; these libraries are unusually
  well documented and the guides are executed in CI.
- When a decision trades one standing goal against another, **state the trade in the commit
  message or the PR body** — that record is part of the project's value.
- Keep `docs/reference/*.md` current as understanding deepens. They exist so a fresh session
  starts informed.
- Nothing about a user's OAuth tokens is ever logged, serialized into an error context
  unredacted, or sent to a third party. **`redact: true` protects `inspect/1` and nothing
  else** — an exception crossing `:erpc` (which is every `bin/remote` probe) has its
  arguments formatted by Erlang, which never consults the `Inspect` protocol. A probe that
  raises with a `%Connection{}` in scope prints both tokens in full. See the header of
  `bin/remote`.
- A new contract follows the checklist at the end of `docs/reference/contracts.md`. The two
  steps most often skipped are the ones that matter: prove it can fail with a `Bond.Test`
  assertion, and for anything load-bearing, mutate the implementation and confirm it fires.
- This project is intended as a flagship example of `bond`, `external_service`, `errata` and
  `wait_for_it` used deeply. Prefer the demonstrative-but-honest option: a contract that earns
  its place and is proven to fire, over either a decorative one or none at all.

---

## Where the project is (updated 2026-08-24)

A fresh session should read this before proposing what to build.

**Working end to end, verified against live services:**

| | |
| --- | --- |
| Accounts | **Supabase Auth**: email + password sign-up, sign-in, sign-out, with session renewal and local ES256 verification of the JWT |
| Providers | **TIDAL** (OAuth + PKCE, encrypted tokens, refresh) and **any Subsonic server** (Navidrome) |
| Matching | The full ladder — ISRC, UPC+position, text, fuzzy — with a version veto, a duration conflict that makes the text rung decline, and a confidence threshold |
| Transfers | Oban pipeline: idempotent (snapshot-and-diff), resumable, per-track report, writes verified after the fact |
| UI | LiveView: connect a service, list transfers, pick a source and destination from your connections, watch the report fill in row by row |
| Caching | Two tiers — Nebulex L1, Postgres L2 — with request coalescing |
| Files | CSV playlists read and written, round-trip property tested; a private Supabase Storage bucket with per-user policies |
| Import | Upload a CSV at `/imports/new` and it becomes a queued transfer, matched against a connected service |
| Export | Download a playlist as CSV at `/exports/new`, via a signed URL |
| Pruning | Four nightly `pg_cron` jobs: negative catalogue lookups, parsed import tracks, old export files, and uploads no transfer refers to. The last two call the Storage API through `pg_net` with a service key from Vault, because `storage.objects` refuses direct `DELETE` |
| Correcting | A row shows the candidates the engine rejected and why each lost, and one click puts the right one in. Stored in `transfer_overrides` and read *before* the ladder on every later run, so a correction survives a retry. A row that already **matched** offers *Replace*: the chosen track is added and the superseded one removed, add-first so a partial failure leaves an extra track rather than a report naming a track that is gone. Gated on `:remove_tracks`, which is the capability's reason for existing. A row that matched on an exact identifier still offers nothing — the runner keeps no candidates for those |
| Reissues | An ISRC the destination does not carry is looked up in **MusicBrainz**, which says which codes name one recording, and the candidates already in hand are re-matched against the family. One request, only after a match has already failed, cached in two tiers with nightly `pg_cron` pruning. `Strategy.IsrcFamily` scores it below an exact identifier and keeps a duration check the rung above deliberately skips |
| Capabilities | `Providers.Adapter.capabilities/0` declares only what *varies* between services — `:artwork` (TIDAL yes, Subsonic no, because its cover endpoint wants credentials on the request) and `:remove_tracks` (both, since 2026-08-24). `Providers.supports?/2` is the question |
| Identity spine | Where a recording lives at every service, in `recording_identities`, hung off a **library recording** so a TIDAL→Navidrome transfer teaches the spine both ids and a later transfer out of the library gets them free. A recalled identity costs **no request**: the row carries a snapshot of what the destination called the track, because no adapter can fetch one track by id. Two rules do the work — an identity is anchored on a **canonical ISRC** or not recorded at all, so the duplicate-recording risk is structurally impossible; and only evidence at `:exact_upc` or better gets in, which is deliberately stricter than the transfer threshold because a wrong row here is asserted about every future transfer, unreviewed |
| Library | **One Playlist is itself a place playlists live.** `Providers.Library` implements the whole adapter behaviour over `library_recordings` (ownerless, shared, the asset that compounds) and `library_playlists` (the user's). It is a transfer source *and* destination with no pipeline branch — `:file` remains the only branch, because a file is source-only. Every user gets a `:library` connection carrying no credential; `Connection.usable?/1` has a clause saying so. See `docs/reference/domain.md` §5 |
| My playlists | `/playlists` lists everything a user has, grouped by where it is stored: the library first, then one group per connected service. Each service group is its own `assign_async/3`, so a slow or failing service degrades inside its own box rather than taking the page — 216 playlists at TIDAL is eleven requests before anything can be drawn |
| Editing | `/playlists/:id` — rename, delete, remove an entry, move one up or down. Every action names an **entry** rather than a recording, because a playlist may hold the same recording twice and a recording id cannot answer "remove this one". Deleting a playlist takes its entries and leaves the recordings, which belong to nobody. Reordering is a **drag from a handle**, and the hook reports what was dropped where rather than submitting an ordering — `place_entry/5` derives it, so a client cannot say anything the server does not check. The handle is a button, so the arrow keys still work; HTML5 drag does not fire on touch, which is the known gap. Dense integers were kept: §5 guessed at fractional ranks and measurement rejected it |
| Storing, not missing | A destination declaring `:accepts_any_track` inverts what a failed match means: the library has no catalogue, so a miss is an instruction to **store** the track via `accept_track/4`, reported `stored`. An `:unmatched` row is impossible for a library destination. Deduplication replaces matching as the risk, so `Library.find_or_create/1` joins only on a canonical ISRC and never on a title — a wrong join is not undoable by adding |
| Removing | `remove_tracks/4` on the adapter, implemented for both. **Neither provider can remove by track id**: TIDAL needs the track id *and* `meta.itemId` and rejects either alone with a `400` naming neither field, and Subsonic removes by zero-based *index* with no song id at all. So each adapter reads the playlist and resolves occurrences itself, which is also what makes a stale removal safe. Removes **every** occurrence, so calling it twice is harmless. Both verified live against TIDAL and Navidrome 0.58.0 |
| Limits | A source playlist over `max_tracks` (10,000 by default) is refused with `PlaylistTooLarge`, before a track is read past the limit. The worker cancels rather than retries any error whose `retryable?/1` says not to |
| Deleting | A transfer can be deleted from its page. `transfer_items` and `transfer_sources` cascade; the uploaded file goes too, best effort, with the nightly orphan sweep as the backstop |
| Classical | `Music.Work` reads a **work signature** out of a title — catalogue number, form and number, key, movement — and `Strategy.Work` matches on it. Classical went from **0 of 8** to 24 work matches plus 13 text of 57. A last-resort MusicBrainz *works* lookup supplies a catalogue number the title omits, on three conditions: the match already failed, the source names no work, and some candidate does |
| Artwork | Cover art on the report, in the candidate list and in the library. From TIDAL via an `albums.coverArt` include, free of extra requests; for a library recording from the **Cover Art Archive**, asked of the *release group* — the album across all its pressings — because which pressing wins a barcode has nothing to do with which one somebody scanned. The archive has its own `ExternalService`: no one-per-second rule, a redirect to archive.org, and failures that cost a thumbnail rather than a transfer. Subsonic's cover endpoint wants credentials, so it declares no `:artwork` capability and no placeholder is drawn |
| Enrichment | A library recording is resolved against **MusicBrainz** in the background — ISRC, MBID, album, barcode, duration, cover — on an Oban queue of one, sized to the one-request-a-second limit rather than fighting it. Enqueued as each new recording arrives and swept nightly for backfill. Two rules, both load-bearing: **gaps are filled, never corrected** (a `Bond` postcondition, proven by mutation), and a candidate found by *search* is scored through the matching ladder at `:high` rather than trusted — MusicBrainz scores a live bootleg 100 for a studio track, and taking the top hit would attach the wrong ISRC. Backfilled the 150-recording dev library: **150 enriched, 140 identified, cover art from 8 to 104**, nothing overwritten. The 10 misses are MusicBrainz coverage rather than matching — soundtracks, extended versions and a bootleg whose ISRCs it does not index |
| Match quality | Two corpora, both replayable offline. `dev/measure/replay.exs`: **82 certain, 12 duration-corroborated, 5 none, 1 wrong** of 100 random MusicBrainz recordings. `dev/corpus/replay_credit_cases.exs`: **96 correct, 12 equivalent, 7 missed, 0 wrong** of 115 hard credit cases, and **5 of 5** hand-labelled decline cases correctly declined. See `docs/reference/domain.md` |

**Proven live, not just in tests:** a TIDAL→TIDAL transfer (8/8 by ISRC, order and
ISRCs identical, a second run adding nothing), and a TIDAL→Navidrome transfer whose
report matched what actually landed in the destination.

**Evaluate a matching change against the corpora, never by argument.** Three separate ideas this
project was confident about were measured and *rejected* — a same-release exception to the version
veto, strict credit equality, and querying the primary artist instead of the whole credit. Each
looked right and each is recorded in `docs/reference/domain.md` as a negative result. The replays
cost seconds and need no API call.

**Owed by hand:** two TIDAL playlists named `hard_playlist` (one is an accidental duplicate).
The orphaned *Neil Young — Powderfinger [Rust Never Sleeps]* in the Pearl Jam destination no
longer needs hand-removal — open that transfer's report and use **Replace** on the row, which
is exactly the case the button was built for.

**Where this is going.** `docs/reference/domain.md` §5 defines the direction: One Playlist as a
*place* playlists live, not only a pipe between services — an editable, enriched library that is
itself a transfer source and destination, and that holds the cross-service identity of a
recording so a match made once is never made again. Read it before proposing anything large; the
backlog below is the road to it, not a separate list.

**Not built yet**, roughly in value order:

  * **Magic link, then Google OAuth.** Both are ways of obtaining a GoTrue session and feed the
    same spine that email+password already proved. Magic link adds the `/auth/callback` code
    exchange; Google reuses it. Note GoTrue's local `email_sent = 2` per hour, which makes
    magic-link iteration painful until raised in `supabase/config.toml`.

  * **Scheduled sync** — the retention feature both incumbents charge for, and the reason
    `wait_for_it` and pg_cron are already in the stack.
  * **Skip the search on a same-provider transfer.** A TIDAL→TIDAL transfer searches
    TIDAL for tracks it already has TIDAL ids for. `Identities.recall/3` deliberately
    refuses to answer with the source track itself, because that shortcut is a different
    feature from recall and should be reasoned about on its own — but it is real, free,
    and would make a same-service copy cost no searches at all.

  * **Resolve the album, not each track.** Enrichment picks a MusicBrainz release per
    *recording*, with a rule that makes an album agree with itself where it can. Seven
    of the dev library's albums still span more than one release, because a widely
    reissued album's pressings are not all listed against every one of its recordings.
    Covers agree; barcodes do not. The fix is to resolve the album once and map its
    tracks onto it.

  * **Editing a recording's own metadata.** Roon's CSV export writes the **album
    artist** into the track artist column, so every track on a compilation or tribute
    album is credited to its subject: *Crucible*'s twelve different performers all
    arrive as "Hunters & Collectors", and *Throw Your Arms Around Me* — actually Neil
    Finn & Eddie Vedder — cannot be found at MusicBrainz from that credit. No enrichment
    fixes this, because a search is only as good as the credit it is given.

    The fix is to let a user correct title, artists, album and version in the app. That
    raises a design question worth answering before building: the editor works one row
    at a time, and correcting a whole album's credits one row at a time is miserable.
    Options are an inline edit on the expanded row, a table view over the playlist, or
    a bulk "set the artist for these rows" action; a table is the obvious shape and the
    worst one for the *reordering* the same screen has to support. It also needs an
    answer to what an edit means for enrichment — a corrected field must be re-enriched
    and must not be overwritten, which is what `Enrichment.reset/1` and the
    fill-gaps-never-correct rule are already built around.

  * **Adding a track to a library playlist by hand.** L2 covers rename, delete,
    remove and reorder; *adding* needs something to add **from**, which is a
    search UI over either the shared recording store or a connected service.
    Tracks arrive by transfer and import meanwhile.

  * **Replace-mode scheduled sync.** `remove_tracks/4` is the piece that was missing and it is
    now in place and spent once, on corrections. Sync is the other caller: a destination track
    whose source track is gone should go too, which is the difference between Soundiiz's Add and
    Replace modes — see `docs/reference/domain.md`.

  * **Tighten the classical corpus filter.** `dev/corpus/harvest_classical.py` matches on words
    like *symphony*, *prelude* and *mass*, so roughly half of `classical_cases.json` is pop music —
    Justin Timberlake, The Verve, Gang Starr, Rihanna. Every classical number is therefore a floor.

  * **Search recall, not the ladder.** With the duration fix in, the engine picks correctly from
    what it is offered; the binding constraint is that TIDAL's text search returns an
    ISRC-matching candidate for only 86% of the corpus. A better query or a second lookup is
    worth more than any further work on scoring. `bin/remote dev/measure/replay.exs` scores an
    engine change against the captured candidates without an API call.
  * A third provider. Apple Music needs $99/yr and a browser flow; Qobuz is partner-only
    (email `api@qobuz.com`); Spotify is self-serve but permanently capped at 5 users.

**Local state that is not in this repository.** Running `supabase start`, the Navidrome
container, and a TIDAL connection in the dev database. The TIDAL account was reconnected on
2026-08-22 to grant `search.read`; without it, text search fails with a `400
INVALID_RESOURCE_ID` that names neither scopes nor the parameter.

---

## Reference documents

| File | Contents |
| --- | --- |
| `AGENTS.md` | Phoenix/Elixir/LiveView coding conventions (generated; authoritative for code style) |
| `docs/reference/jv-libraries.md` | Deep reference for `external_service`, `errata`, `bond`, `wait_for_it` |
| `docs/reference/supabase.md` | Supabase platform reference oriented to Elixir/Phoenix |
| `docs/reference/domain.md` | Soundiiz/TuneMyMusic feature analysis, track matching, platform API limits, and (§5) where the product is going |
| `docs/reference/contracts.md` | **House style for Bond contracts** — read before adding or changing one |
| `docs/library-feedback.md` | Running log of friction found while dogfooding the four libraries |
| `docs/supabase-sdk-issues.md` | Defects found in the Supabase Elixir SDK, with offline reproductions and upstream status |
