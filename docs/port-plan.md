# Porting One Playlist to TypeScript + Supabase

**Audience:** a Claude Code agent starting the new repository from nothing, on a machine that
does not have this one checked out. Read this whole file before writing code. Everything it
cites lives in this repository, `github.com/jvoegele/one_playlist`, which is public; fetch the
files by raw URL or clone it read-only.

**Status of this document:** written 2026-09-12 from decisions Jason made that day. The
decisions in §1 are settled; everything after them is the plan that follows from them, and is
to be revised as the port learns things — in the new repository's own `docs/`, not here.

---

## 0. Why a port, and what changed about the goals

`one_playlist` is a playlist-transfer tool — Soundiiz / TuneMyMusic territory — built in
Elixir/Phoenix over the last month with three standing goals: (1) dogfood Jason's Elixir
libraries, (2) learn Supabase deeply, (3) build something genuinely useful. Goal 1 has been
served: the four libraries have been used load-bearingly and a long feedback log exists.

Jason has since started at Supabase as a software engineer on the **Realtime team**, and one of
the engineering onboarding tasks is a Supabase dogfood project. Doing that in Elixir turned out
to be the wrong vehicle: the Elixir project talks to Postgres through Ecto and runs its own job
system (Oban), so the Data API, Queues, Edge Functions, the JavaScript SDK, the UI Library and
most of the platform's actual developer experience never come into play.

So the goals of the **new** project are, in order:

1. **Dogfood Supabase** — use as much of the platform as possible, the way its customers do:
   `supabase-js`, `@supabase/ssr`, the Data API with RLS, Queues, Cron, Edge Functions,
   Storage, Realtime, Vault, pgvector, Branching, the CLI and pgTAP. Prefer the Supabase-native
   way even when a plainer way exists, **and say so in the commit when making that trade**.
2. **Learn TypeScript and its ecosystem** — Jason knows Elixir well and TypeScript/Node barely.
   The plan is prescriptive about tooling (one blessed choice each) so that one way is learned
   well. Explain idioms in code comments where an Elixir developer would be surprised.
3. **Build something useful** — the same product: transfer playlists between services, keep
   them in sync, and hold a library that is itself a place playlists live.

The Elixir libraries are **not** part of the new project. The Elixir repository is **frozen as a
reference**: no new features, but its documentation and its *measured* behaviour remain the
source of truth for what the port must reproduce.

---

## 1. Decisions already made

| Decision | Choice | Why |
| --- | --- | --- |
| Framework | **Next.js, App Router**, TypeScript | What Supabase's docs, `@supabase/ssr` guides, starter templates, UI Library and Studio use. Alternatives (TanStack Start, SvelteKit) are pleasanter but you would translate every example. |
| Background work | **All-Supabase: pgmq + pg_cron + pg_net + Edge Functions** | Next.js has no long-running process, so there is no Oban equivalent. That is the point: it forces transfers onto the platform's own primitives. Edge Functions have a wall-clock limit, so a transfer becomes chunked, resumable messages — the existing design already supports that. |
| Hosting | **Vercel + a hosted Supabase project** | The canonical pairing. Which Supabase org is **undecided** (see §17); plan for local first, hosted as its own milestone. |
| Scope | **Core product first, matching ladder included** | Auth, provider connections, library, transfers with per-track reports, scheduled sync, CSV import/export, the four-rung ladder measured against the existing corpora. Enrichment, classical, artwork and the identity spine are later phases. |
| Providers | **TIDAL, Subsonic/Navidrome, Spotify, YouTube Music**, plus the library | In that order. YouTube Music is new (never built in Elixir). |
| Data | **Corpora + replay scripts; Jason's library; Jason's playlists** | Corpora are language-neutral JSON — port the replays *first* so parity is a number. The library is 654 MusicBrainz-enriched recordings that would take weeks to rebuild. |
| Realtime | **Broadcast from Database, Realtime Authorization, Presence, and Postgres Changes once for contrast** | Jason's team. Transfer progress is the first use. |
| Repository | **`github.com/jvoegele/one-playlist`, public** | Public from day one, which makes §16's rule about local data a hard rule. |
| TypeScript practice | **Prescriptive** | See §3. |
| Elixir repo | **Frozen as reference** | Noted at the top of its `CLAUDE.md`. |

---

## 2. What to read in the Elixir repository, and what not to port

Read these, in this order. They are long; they are also where a month of mistakes is recorded.

| File | Why |
| --- | --- |
| `CLAUDE.md` | The goals, the hard constraints (§ "Hard constraints"), the architecture, and the **status table** — a row per feature, with what was measured and what was *not* exercised. The "Not built yet" list is the backlog. |
| `docs/reference/domain.md` | §2 the matching problem; §3 every provider's API limits and quirks (long, and every line was learned the hard way); §5 where the product is going — *One Playlist as a place playlists live*; §6 the schema's known conflation and the decision to wait on it. |
| `docs/reference/supabase.md` | The platform reference, oriented to a server-side app. §4 Auth (the magic-link `token_hash` decision, Google, `env()` behaviour), §5 RLS traps, Storage, Vault, pg_cron. Much of it transfers directly. |
| `docs/supabase-sdk-issues.md` | Defects in the **Elixir** SDK. Not directly relevant, but the *method* — an offline reproduction per defect, filed upstream — is the standard for anything found in `supabase-js`. |
| `supabase/config.toml`, `supabase/templates/*.html`, `supabase/tests/*.sql` | Local-stack configuration, the sign-in email templates, and **533 lines of pgTAP** RLS tests. All three are language-neutral; copy and adapt. |
| `priv/repo/migrations/` | 36 Ecto migrations, 23 of which are mostly raw SQL. The RLS, grants, triggers, `pg_cron` schedules and Vault usage are in the `execute` blocks. §7 says how to translate them. |
| `dev/corpus/*.json`, `dev/measure/*.exs`, `dev/corpus/replay_*.exs` | The corpora and the replays that score the matching engine. §11. |

**Do not port** these; each has a different answer in TypeScript (§3):

  * `Bond` contracts (`@pre`/`@post`/`@invariant`) → Zod schemas at boundaries, explicit
    invariant functions, and property tests with `fast-check` for the laws that matter.
  * `Errata` error types → a `Result` type plus typed error codes (§3).
  * `ExternalService` (circuit breaker, rate limiter, retries) → `cockatiel` policies inside the
    worker, plus a shared `provider_health` table, because Edge Function isolates share no
    memory (§9).
  * `WaitForIt` → plain `await` and Realtime subscriptions; there is no polling loop to write.
  * Oban → pgmq + pg_cron + Edge Functions (§9). `Oban.Plugins.Cron` → pg_cron. Lifeline →
    pgmq visibility timeouts.
  * Nebulex L1 cache → nothing. Edge Functions are stateless; the Postgres L2 tables
    (`catalogue_release_lookups`, `musicbrainz_*`) are the cache.
  * Cloak-style app-level encryption of provider tokens → Vault (§8).
  * Phoenix PubSub → Realtime Broadcast from Database (§10).
  * LiveView → React Server Components for reads, Server Actions for writes, client components
    only where there is client state (drag-to-reorder, realtime subscriptions).

---

## 3. Toolchain and conventions (prescriptive)

One choice per concern. The other agent should not relitigate these; if one turns out wrong,
record why in the new repo's docs and change it once.

| Concern | Choice | Notes |
| --- | --- | --- |
| Node | current LTS, pinned in `.tool-versions` via the asdf `nodejs` plugin | Jason already uses asdf. |
| Package manager | **pnpm**, with a `pnpm-workspace.yaml` | Workspaces are needed for the shared core package (§12). Commit `pnpm-lock.yaml`. |
| Scaffold | `pnpm create next-app@latest` — TypeScript, App Router, Tailwind, `src/` dir, Turbopack | Then `npx shadcn@latest init`. |
| UI | **shadcn/ui** + **Supabase UI Library** blocks | `npx shadcn@latest add @supabase/password-based-auth-nextjs` etc. The library also ships Social Auth, Dropzone (Storage uploads), Realtime Cursor, Realtime Avatar Stack (Presence), Realtime Chat, an Infinite Query hook and Current User Avatar. Verify the current list at `supabase.com/ui`. Use the blocks as *starting points* and edit them; they install as source. |
| TypeScript | `"strict": true`, `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes` | Learn the strict dialect once. |
| Lint/format | **Biome** | One tool, fast, no plugin ecosystem to learn. `biome check --write` in a pre-commit script. |
| Validation | **Zod** at every boundary: form input, provider API responses, queue messages, Edge Function request bodies | Provider payloads are parsed with Zod *before* mapping, so a shape change fails loudly with a path. This replaces the role `Bond` played at boundaries. |
| Errors | A small in-repo `Result<T, E>` discriminated union (`{ ok: true, value } \| { ok: false, error }`) and error classes carrying a `code` from a closed union | Mirror Errata's split: *domain* errors the user can act on (`TRACK_NOT_MATCHED`, `PLAYLIST_TOO_LARGE`, `SIGN_IN_FAILED/link_expired`) vs *infrastructure* errors (`PROVIDER_UNAVAILABLE`, `TOKEN_EXPIRED`) with a `retryable` flag the worker reads. Do not adopt `neverthrow` or Effect; a learner should see the mechanism. |
| DB types | `supabase gen types typescript --local > src/lib/database.types.ts`, regenerated by a script after every migration, committed | The single biggest TypeScript-learning payoff: every query is typed from the schema. |
| Data access | **`supabase-js` through the Data API (PostgREST) with the user's JWT**, so RLS applies to every read and write. Postgres functions (`rpc`) for anything transactional or multi-row. **No ORM.** | Where the Elixir app used `Repo.as_user/3` to step down to `authenticated`, the Data API does this natively. Service-role access only inside Edge Functions and only for system writes (transfer reports, token refresh). |
| Unit tests | **Vitest** | Matching engine, normalizers, mappers, corpora replays. |
| DB tests | **pgTAP** via `supabase test db` | Port `supabase/tests/*.sql`. |
| Edge Function tests | `deno test` inside `supabase/functions/`, plus integration tests that call `supabase functions serve` | |
| E2E | **Playwright** against `supabase start` + `next dev`, reading sign-in email out of Mailpit's API (`http://127.0.0.1:54324/api/v1/search?query=to:"<addr>"`) — the Elixir suite already does this and it works | |
| CI | GitHub Actions: `supabase start`, `supabase db lint`, `supabase test db`, `pnpm test`, `pnpm build`, Playwright | |
| Env | `.env.local` (gitignored) for Next; `supabase/.env` (gitignored) for `env(...)` values in `config.toml`; `.env.example` for both, committed | Never a key in the repo, including the well-known local demo keys — keep the habit. |
| Commits | Conventional-ish, but the body carries the *reasoning*, and **states any trade between the three goals** | The Elixir repo's history is the model: `git log` there. |

Repository layout (a pnpm workspace so the pure core can be shared with Edge Functions — see
§12 for the caveat that must be spiked first):

```
one-playlist/
  apps/web/                 Next.js app
  packages/core/            pure TypeScript: matching ladder, normalizers, Track type, Result, error codes
  supabase/
    config.toml
    migrations/             SQL, one concern per file
    functions/              Edge Functions (Deno)
      _shared/              code shared by functions (see §12)
      transfer-worker/
      sync-sweeper/
      token-refresh/
      enrichment-worker/    (later phase)
    templates/              auth email templates
    tests/                  pgTAP
    seed.sql
  corpora/                  the JSON corpora, copied from the Elixir repo's dev/corpus/
  docs/                     this plan's successor documents live here
  .tool-versions
  pnpm-workspace.yaml
  biome.json
```

---

## 4. Architecture

```
 Browser ──── Next.js (Vercel) ──────────────────────────────────────────────┐
   │  RSC reads: supabase-js (user JWT) → PostgREST → Postgres (RLS)          │
   │  Server Actions: writes via Data API / rpc()                             │
   │  Route Handlers: /auth/confirm, /auth/callback, /connect/:provider/*     │
   │  Client components: Realtime subscriptions, drag-to-reorder             │
   │                                                                          │
   └── WebSocket ──► Realtime ◄── WAL (realtime.messages) ◄── triggers ──────┤
                                                                              │
 Postgres ───────────────────────────────────────────────────────────────────┤
   public.*      tables with RLS; SECURITY DEFINER functions for invariants   │
   pgmq          queues: transfers, sync_runs, token_refresh, enrichment      │
   cron          schedules: drain queues, sweep syncs, prune, backfill        │
   pg_net        cron → HTTP POST → Edge Functions, secret from Vault         │
   vault         provider tokens, service key, function shared secret        │
   storage       bucket "playlists": imports and exports, per-user paths      │
                                                                              │
 Edge Functions (Deno) ◄── pg_net / direct invoke ───────────────────────────┘
   transfer-worker   reads N pgmq messages, runs one chunk each, writes report
   sync-sweeper      due syncs → enqueue transfers (or do it in SQL — §9)
   token-refresh     proactive OAuth refresh, writes back to Vault
   provider calls    cockatiel retry/breaker; Retry-After honoured
```

The rule that keeps this honest: **the browser and the Next.js server never hold a service-role
key.** Everything a user reads or writes goes through RLS as that user. Only Edge Functions run
privileged, and only for what the system does on the user's behalf.

---

## 5. Supabase feature map

What each product is used for, and what it replaces from the Elixir app. The phase column says
when it first appears (§15).

| Product | Used for | Replaces | Phase |
| --- | --- | --- | --- |
| Postgres + RLS | Every table; policies with explicit `TO` roles; `(select auth.uid())` | Same — carried over | 1 |
| pgTAP (`supabase test db`) | RLS tests, ported from `supabase/tests/` | Same | 1 |
| Auth: email+password, magic link (`token_hash` + six-digit code), Google | Accounts | Same; in TS via `@supabase/ssr` and the UI Library auth block | 1 |
| Auth: anonymous sign-in *(optional)* | "Try a CSV import before creating an account", then link identity | New | 6 |
| Data API (PostgREST) via `supabase-js` | All user-facing reads and writes | Ecto + `Repo.as_user/3` | 1 |
| Postgres functions (`rpc`) | Reorder playlist entries, create batch transfers, "run failed again" — anything that was a transaction | Ecto.Multi | 3, 5 |
| Generated types | `database.types.ts` | Ecto schemas | 1 |
| Vault | Provider access/refresh tokens; the pg_net shared secret; the service key for pruning | Cloak-style encrypted columns | 2 |
| Queues (pgmq) | `transfers`, `sync_runs`, `token_refresh`, later `enrichment` | Oban queues | 5 |
| Cron (pg_cron) | Drain queues every minute; sweep syncs every 15 min; nightly pruning ×4; enrichment backfill | Oban Cron + the existing pg_cron jobs | 5, 6, 7 |
| pg_net | Cron → Edge Function invocation; pruning Storage objects | Same for pruning; new for invocation | 5 |
| Edge Functions | The workers (§9), token refresh, OAuth token exchange for confidential clients if keeping the secret out of Vercel is preferred | Oban workers | 2, 5 |
| Realtime: Broadcast from Database + Authorization | Transfer report filling in row by row, over a private per-transfer topic | Phoenix PubSub | 5 |
| Realtime: Postgres Changes | The connections list, once, for contrast with Broadcast | — | 3 |
| Realtime: Presence | Who else has a shared library playlist open (needs sharing) | — | 10 |
| Storage | `playlists` bucket: CSV imports (`{uid}/imports/...`) and exports (`{uid}/exports/...`), signed download URLs, per-user path policies | Same | 6 |
| pgvector | Semantic search over library recordings via the *automatic embeddings* pattern (pgmq + cron + pg_net + Edge Function) — which is itself the canonical example of the §9 architecture | The never-built "embeddings" rung | 10 |
| Branching | Preview database per PR once hosted | — | 9 |
| Advisors, Logs, Reports, `supabase db lint` | Read them; fix what they say | — | 9 |
| Management API / MCP | Optional: let the agent inspect the hosted project | — | 9 |
| UI Library | Auth blocks, Dropzone, Realtime Avatar Stack, Realtime Cursor | DaisyUI hand-written forms | 1, 6, 10 |

---

## 6. Data model

The Elixir schema is mostly right and should be carried over with its RLS shape. Sixteen tables
in `public` today:

```
provider_connections       a user's connection to a service (provider, tokens*, scopes, status, failures)
transfers                  one transfer: source, destination, status, mode, batch_id, sync_id
transfer_sources           an uploaded CSV as a source
transfer_items             the per-track report: position, source track fields, outcome, matched id, source_isrc
transfer_overrides         a user's correction for a (transfer, position), read before the ladder
syncs                      a standing instruction: cadence, mode, next_run_at, pinned destination playlist
library_recordings         ownerless, shared: title, artists, album, isrc, mbid, barcode, duration, cover, isrc_disputed
recording_enrichments      enrichment bookkeeping per recording (split off the recording deliberately — domain.md §6)
recording_identities       where a recording lives at each service, anchored on a canonical ISRC
library_playlists          the user's playlists
library_playlist_items     entries: position, recording_id (nullable), and the item's OWN account of the track
catalogue_release_lookups  L2 cache of provider release lookups (negative entries pruned nightly)
musicbrainz_recordings, musicbrainz_releases, musicbrainz_isrc_lookups, musicbrainz_work_lookups
                           MusicBrainz caches (later phase)
```

Changes to make *in* the port, because the constraints changed:

  * **Tokens leave the table.** `provider_connections.access_token` / `refresh_token` become
    `access_token_secret_id` / `refresh_token_secret_id` referencing `vault.secrets`. §8.
  * **A `transfer_chunks` table** (or columns on `transfers`: `next_offset`, `chunk_size`,
    `lease_until`) so a transfer can be processed as a sequence of pgmq messages and resumed.
    §9.
  * **`provider_health`**: per-provider backoff state (`retry_after_until`, consecutive failures)
    shared across Edge Function isolates. §9.
  * **`oauth_flows`**: pending OAuth state/PKCE verifier keyed by a random id held in an
    httpOnly cookie, with an expiry and a nightly prune. Next.js has no encrypted server session
    to stash it in. §8.
  * Realtime triggers on `transfer_items` and `transfers`. §10.

Read `docs/reference/domain.md` §6 before changing anything else about the shape: it records
the known conflation in `library_recordings` (identity, release context, bookkeeping) and the
decision to leave it until album transfer exists. That decision still stands.

**Migration convention** (unchanged, and non-negotiable): every migration creating a table in
`public` must `enable row level security`, `revoke all ... from anon, authenticated`, `grant`
only what is needed, and add policies with an explicit `TO`. `docs/reference/supabase.md` §5 has
the pattern and the four traps; two of the four (`SET LOCAL` and savepoints, the singular
`request.jwt.claim.sub`) were artefacts of stepping down from `postgres` in Ecto and **do not
apply** when PostgREST sets the claims itself.

---

## 7. Translating the migrations

Do not port Ecto DSL; write SQL. Process:

1. Run the Elixir app's migrations once against a local stack (`supabase start && mix
   ecto.migrate` in the Elixir repo) and `supabase db dump --local --schema public > baseline.sql`
   — that gives you the *effective* schema including everything the `execute` blocks did.
2. Split that dump into topical migrations in the new repo (`accounts`, `connections`,
   `library`, `transfers`, `syncs`, `caches`, `cron`, `realtime`), applying the §6 changes as you
   go. `supabase migration new <name>`.
3. Keep the pg_cron schedules **best-effort** as the originals are — wrapped so a project
   without the extension still migrates.
4. Port `supabase/tests/rls.test.sql` and `storage_rls.test.sql` verbatim first; they should
   pass against the translated schema before any application code exists. That is the parity
   gate for this step.
5. `supabase gen types typescript --local` → commit.

Alternatively use **declarative schemas** (`supabase/schemas/*.sql` + `supabase db diff`) — this
is worth trying as a dogfooding exercise, with the caveat that pg_cron schedules, Vault secrets
and grants on `realtime.messages` are not well expressed declaratively and stay in migrations.

---

## 8. Auth and provider connections

### Accounts (`@supabase/ssr`)

Follow the Next.js server-side auth guide exactly: `createBrowserClient` for client components,
`createServerClient` with the cookie adapter for RSC/actions/route handlers, and the middleware
(the guide now calls it a proxy) that refreshes the session and **uses `getClaims()`**, never
`getSession()`, to protect pages.

Three ways in, one session — the same shape the Elixir app ended with:

  * **Password.** The UI Library block.
  * **Magic link = a `token_hash` link plus a six-digit code in one email.** The email templates
    in `supabase/templates/` already do this; point the link at `{{ .SiteURL }}/auth/confirm?
    token_hash={{ .TokenHash }}&type=email` (the guide's route) and verify with
    `supabase.auth.verifyOtp({ token_hash, type: 'email' })`. The code is verified with
    `verifyOtp({ email, token, type: 'email' })`. Both templates (`magic_link`,
    `confirmation`) carry both, because which one GoTrue sends depends on
    `enable_confirmations`. **Do not use the PKCE magic link** — it fails whenever the email
    is opened in a different browser, which for email is the common case. The reasoning is in
    `docs/reference/supabase.md` §4 and it transfers unchanged.
  * **Google.** `signInWithOAuth({ provider: 'google' })` with `redirectTo` at
    `/auth/callback`, which calls `exchangeCodeForSession(code)`. `@supabase/ssr` keeps the
    PKCE verifier in a cookie for you. Locally the provider needs `skip_nonce_check = true` and
    credentials in `supabase/.env` (`env(...)` in `config.toml` reads the shell *and* that
    file; an unset name passes through as the literal string, silently).

Hosted-project gotcha the local stack hides: **built-in email is limited to ~2 messages an hour
and is for development only.** Custom SMTP (Resend is the usual choice) is a prerequisite for
magic links on the hosted project, and the templates must be pasted into the dashboard —
`config.toml` templates do not reach a hosted project.

### Provider OAuth — this application's own flows, not Supabase Auth's providers

Unchanged decision, and worth restating because it *looks* like a missed dogfooding
opportunity: Supabase Auth's Spotify/Google providers hand over `provider_token` once and never
refresh it, which is fatal for a *scheduled* transfer. Sign-in with Google is an account
identity; connecting YouTube Music is an OAuth flow this app runs itself. (`CLAUDE.md` § "Hard
constraints", last bullet.)

Shape per provider (`docs/reference/domain.md` §3 has every quirk):

| Provider | Client type | Kept between legs | Removal model | Notes |
| --- | --- | --- | --- | --- |
| TIDAL | public + PKCE | verifier | needs track id **and** `meta.itemId` | redirect URI on `localhost` is fine |
| Spotify | confidential | nothing | by URI, `snapshot_id` makes a removal silently no-op | redirect URI **must be `127.0.0.1`**; `/playlists/{id}/items` not `/tracks`; Development Mode: 5 users, own playlists only |
| Subsonic | token auth, no OAuth | — | by zero-based index | HTTP 200 on failure; ISRC is an array |
| YouTube Music | confidential (Google) | nothing | by `playlistItem.id` | 10,000 units/day; `playlistItems.insert` = 50, `search.list` = 100 → ~200 adds/day |

Implementation:

  * Route handlers `GET /connect/[provider]` and `GET /connect/[provider]/callback`. State and
    verifier go in an **`oauth_flows` row** (id, user_id, provider, state, verifier, expires_at)
    with the id in an httpOnly, `SameSite=Lax` cookie. Compare `state` in constant time. Delete
    the row on every exit.
  * **Tokens in Vault.** A `SECURITY DEFINER` function `store_connection_tokens(connection_id,
    access, refresh, expires_at)` calls `vault.create_secret` / `vault.update_secret` and writes
    the secret ids onto the connection; grant it to `authenticated` with a check that the
    connection belongs to `auth.uid()`. A second function `connection_tokens(connection_id)`
    reads `vault.decrypted_secrets` and is granted **only to `service_role`** — Edge Functions
    call it; the Next.js app never sees a token after the callback. Note the trade in the
    commit: Vault over app-level encryption is goal 1 over familiarity.
  * **Refresh** is a `token-refresh` Edge Function: a pg_cron job every 5 minutes enqueues
    connections whose `expires_at` is within 10 minutes onto `pgmq` `token_refresh`; the
    function drains it. Rotation semantics per provider are in domain.md §3.
  * Never log a token. `Result` errors carry a `context` object; put connection **ids** in it,
    never the connection.

---

## 9. The job pipeline: pgmq + pg_cron + Edge Functions

This is the part with no Elixir precedent and the most Supabase in it. Design it carefully and
spike it first (§14).

### Constraints that shape it

  * Edge Functions: **150 s wall clock on Free, 400 s on paid; 2 s CPU time per request; 256 MB.**
    `EdgeRuntime.waitUntil` lets a function respond immediately and keep working within those
    limits. Locally, `[edge_runtime] policy = "per_worker"` is required for background tasks to
    complete (it is already the setting in the Elixir repo's `config.toml`).
  * Provider rate limits (from the Elixir services, per second): TIDAL 8, Spotify 10 (plus a
    global `Retry-After` you must sleep on), Subsonic effectively unbounded, MusicBrainz **1**,
    Cover Art Archive 2. A 10,000-track transfer at TIDAL is minutes of wall clock; it cannot
    be one invocation.
  * Isolates share nothing. A circuit breaker inside one invocation protects only that
    invocation.

### Design

  * **Queues:** `transfers` (one message = one *chunk* of one transfer), `sync_runs`,
    `token_refresh`, later `enrichment`. Create with `pgmq.create('transfers')` in a migration.
    Do **not** expose queues through PostgREST (`pgmq_public`) — nothing in the browser should
    touch them; the worker uses the service role over a direct SQL client or `rpc` on
    `SECURITY DEFINER` wrappers.
  * **A transfer is a state machine in Postgres.** `transfers.status`: `queued → running →
    completed | failed | cancelled`; `next_offset`, `chunk_size` (200 tracks by default, tuned
    per provider), `lease_until`. Creating a transfer inserts the row and `pgmq.send('transfers',
    {transfer_id, offset: 0})` in one transaction (`SECURITY DEFINER` function
    `create_transfer(...)` called from a Server Action).
  * **Drain:** `cron.schedule('drain-transfers', '* * * * *', $$ select net.http_post(url :=
    <functions_url>/transfer-worker, headers := jsonb_build_object('Authorization', 'Bearer ' ||
    <secret from vault>)) $$)`. The function `pgmq.read('transfers', vt := 120, qty := 5)`,
    processes each message, `pgmq.archive`s on success, and if the transfer has more tracks,
    `pgmq.send`s the next chunk **before** archiving the current one. A message whose visibility
    timeout lapses becomes visible again — that is Lifeline. Idempotency is what makes the
    retry safe, and the Elixir runner already has the property: **snapshot-and-diff** — read
    the destination, add only what is missing, verify after the fact. Keep it.
  * **One-minute cron latency is fine** for a transfer; for a snappier feel the Server Action
    that creates the transfer can also `fetch()` the worker directly (fire-and-forget), and the
    cron is the backstop. Say which in the docs.
  * **Chunk processing** = match each track (§11), add the matched ones to the destination,
    write `transfer_items` rows (which fire the Realtime trigger — §10), update `next_offset`.
    Honour `Retry-After` by writing `provider_health.retry_after_until` and **re-enqueueing the
    chunk with a delay** (`pgmq.send(..., delay := seconds)`) rather than sleeping in the
    function.
  * **Resilience inside an invocation:** `cockatiel` — retry with backoff on retryable errors,
    a breaker per provider per invocation, a bulkhead of provider concurrency (TIDAL 10,
    Spotify 10, MusicBrainz 1). Before calling a provider, consult `provider_health`; after a
    5xx/429 streak, write to it. That table is the cross-isolate breaker.
  * **Scheduled sync:** `cron.schedule('sweep-syncs', '*/15 * * * *', $$ select
    public.sweep_due_syncs() $$)` — a SQL function that, for each `syncs` row with
    `next_run_at <= now()`, **advances `next_run_at` first** and then creates a transfer (same
    function as above) with the sync's mode. No Edge Function needed for the sweep; that is the
    point of doing it in SQL. Replace mode's three rules (an unmatched row withholds the whole
    removal; an empty source removes nothing; whole tracks only) live in the worker and are
    tested there.
  * **Pruning:** the four nightly jobs carry over. Storage object deletion goes through an
    Edge Function called by cron with the service role, instead of pg_net calling the Storage
    API directly with a Vault key — simpler, and one privileged path instead of two.
  * **Enrichment (later):** the same shape, queue `enrichment`, 1 rps at MusicBrainz enforced
    by `chunk_size = 1` and a per-second cron is too coarse — use one invocation that drains up
    to 60 messages with a 1 s spacing under `waitUntil`, within the wall clock.

Write the message schemas with Zod and version them (`{ v: 1, transfer_id, offset }`); a queue
outlives a deploy.

---

## 10. Realtime

The first use is the transfer report page: rows appear as `transfer_items` are written.

  * **Broadcast from Database.** A trigger on `transfer_items` and on `transfers` calls
    `realtime.broadcast_changes('transfer:' || NEW.transfer_id, TG_OP, TG_OP, TG_TABLE_NAME,
    TG_TABLE_SCHEMA, NEW, OLD)`. Prefer this over Postgres Changes: it scales independently of
    the table, carries only what the trigger chooses, and it is the pattern the Realtime team
    recommends. (Postgres Changes is used once, on the connections list, so the docs can
    compare the two in the same app.)
  * **Authorization.** Private channels only. Policy on `realtime.messages`: `FOR SELECT TO
    authenticated USING (realtime.topic() like 'transfer:%' and exists (select 1 from transfers
    t where 'transfer:' || t.id = realtime.topic() and t.user_id = (select auth.uid())))`. Write
    a pgTAP test for it; a Realtime topic policy is exactly the kind of thing that passes for
    months while leaking.
  * **Client.** `await supabase.realtime.setAuth()` then `supabase.channel('transfer:' + id, {
    config: { private: true } }).on('broadcast', { event: 'INSERT' }, ...)`. Reconcile with a
    fresh read on subscribe, because a message can arrive before the initial RSC render is
    hydrated — the Elixir LiveView had the same race and solved it the same way.
  * **Presence** (phase 10, after playlist sharing exists): the UI Library's Realtime Avatar
    Stack on a shared playlist page, and possibly Realtime Cursor for the fun of it.
  * Jason is on this team. If something about the developer experience is awkward — an unclear
    error, a missing type, a docs gap — **write it down in `docs/realtime-notes.md`** with a
    reproduction. That is the most valuable artefact this project can produce for his job.

---

## 11. The matching engine, and proving parity

The ladder, from `docs/reference/domain.md` §2 and `lib/one_playlist/matching/`:

1. **ISRC** — exact identifier, certain.
2. **UPC + track position** — exact identifier.
3. **Normalized text + duration** — normalized title/artists/album; a *version veto*
   (`live`/`remix`/`demo`/`acoustic` tags must agree, strict set equality); a duration conflict
   (> 3 s after tolerance) makes this rung *decline* rather than score low. The demotion of
   duration to a soft signal was measured and **rejected** — it doubles wrong answers.
4. **Fuzzy** — **Jaro-Winkler** (`Similarity.jaro_winkler/2`, over `String.jaro_distance` with
   the Winkler prefix bonus) on normalized strings, below a confidence threshold. Use the
   `jaro-winkler` npm package or port the 40-line function; write a test that pins the
   Elixir values for a dozen pairs so the two implementations agree to the fourth decimal.

Later rungs — `IsrcFamily` via MusicBrainz, `Work` signatures for classical, release-first — are
phase 10.

Port `packages/core` **first**, before any provider adapter, and port the replays with it:

| Corpus (in `dev/corpus/`, `dev/measure/`) | Cases | Elixir result to match |
| --- | --- | --- |
| `replay.exs` — 100 random MusicBrainz recordings against captured TIDAL candidates | 100 | 82 certain, 12 duration-corroborated, 5 none, 1 wrong |
| `credit_cases.json` + `credit_sources.json` | 115 + 5 declines | 96 correct, 12 equivalent, 7 missed, 0 wrong; 5/5 declined |
| `enrichment_cases.json` | 255 (234 labelled) | 149 correct, 30 equivalent, 32 unverified, 23 missed, **0 wrong** — with the `tags withheld` control at 147/31/32/23/1 |
| `album_cases.json` | 493 pairs | `Normalize.album` 79.5% vs 76.1% baseline (note the noise floor: duplicate release groups) |
| `classical_cases.json` / `classical_sources.json` | 57 | 24 work + 13 text — later phase; and roughly half the corpus is pop, so the numbers are a floor |
| `dev/experiments/hard_playlist.csv` + `hard_playlist_categories.json` | ~60 | A playlist *built to break the matcher*, each row tagged with the failure mode it targets (version in title, featured credits, reprises…). No pinned score; run it as a live transfer once providers exist and read the report by category |

The replays become Vitest tests that print the same four-column table and **fail if any wrong
count rises**. Correct/missed may differ slightly while normalizers converge; *wrong* may not.
"The oracle is the binding constraint, not the engine" — read the CLAUDE.md paragraph with
that heading before believing a regression; several apparent regressions in the Elixir project
were the corpus being wrong.

Six ideas were measured and rejected in Elixir (CLAUDE.md, "Evaluate a matching change against
the corpora, never by argument"). Do not re-try them without re-measuring.

---

## 12. Sharing code between Next.js and Edge Functions — spike this first

The matching engine, normalizers, `Track` type and provider mappers are needed by both the
Next.js app (Node) and the workers (Deno). Deno can import npm packages and relative TypeScript,
but the Supabase CLI **bundles a function from its own directory** and the documented place for
shared code is `supabase/functions/_shared/`. Whether an import that reaches *outside*
`supabase/functions/` (to `packages/core`) survives `supabase functions deploy` must be verified
on day one, because the answer decides the repo layout:

  * If relative imports outside the functions directory deploy correctly → `packages/core` as
    planned, with a `deno.json` import map in each function mapping `@core/` to it.
  * If not → the core lives at `supabase/functions/_shared/core/` and the Next app aliases it
    (`"@core/*": ["../../supabase/functions/_shared/core/*"]` in `tsconfig.json`). Odd, but
    honest, and it keeps one copy.

Either way `packages/core` must have **zero Node-only dependencies** — no `node:` imports, no
`Buffer`. Zod and a fuzzy-matching library are fine (both are pure).

---

## 13. UI

Server Components for every list and report page; Server Actions for every mutation; client
components only for realtime subscriptions and the drag handle. The pages, in the order the
Elixir app arrived at them and with the design points that were hard-won:

  * `/connections` — connect/disconnect per provider; the library is "always on".
  * `/playlists` — everything the user has, grouped by where it lives, library first; each
    service group loads independently (`Suspense` per group) so a slow provider degrades inside
    its own box.
  * `/playlists/[id]` — rename, delete, remove, drag-to-reorder. **Actions name an entry, not a
    recording** (a playlist can hold a recording twice). Reorder is `rpc('place_entry', …)`; the
    client says what was dropped where, never an ordering. An item owns its own account of the
    track; the recording it links to supplies only catalogue facts (`domain.md` §5 says why —
    a wrong match used to destroy a track).
  * `/transfers/new`, `/transfers`, `/transfers/[id]` — pick source and destination from your
    connections; batch = one transfer per playlist sharing a `batch_id`; the report fills in
    over Realtime; unmatched rows show the rejected candidates and why each lost, with one
    click to override (`transfer_overrides`, read before the ladder on every later run).
  * `/syncs` — cadence, mode, pause/resume/delete; each run is an ordinary transfer.
  * `/imports/new` (Dropzone → Storage → transfer), `/exports/new` (signed URL).
  * **"Fix in my library"** on a completed transfer with unmatched rows — the bridge into
    curation, offered at the moment of friction.

---

## 14. Spikes to run before Phase 1 (one to two days total)

Each is a throwaway branch with a written result in `docs/spikes.md`.

1. **Shared code deploy** (§12). Decides the repo layout.
2. **pgmq → Edge Function round trip**: cron → pg_net → function → `pgmq.read` → archive.
   Measure end-to-end latency and confirm visibility-timeout re-delivery by killing a function
   mid-chunk.
3. **Vault token round trip**: store from an authenticated `rpc`, read from a service-role
   function, confirm `authenticated` cannot read `vault.decrypted_secrets`. pgTAP it.
4. **Broadcast from Database on a private channel** with an RLS topic policy, from a Server
   Component page with a client subscription. Confirm the unauthorized case *fails to
   subscribe* rather than silently receiving nothing.
5. **`@supabase/ssr` magic link with `token_hash`** locally through Mailpit, including the
   six-digit code path.

---

## 15. Phases and exit criteria

Each phase ends with a commit whose body records what was learned, and a line in the status
table of the new repo's `CLAUDE.md` (create one; copy the *structure* of the Elixir one).

| # | Phase | Delivers | Supabase surface introduced | Exit criterion |
| --- | --- | --- | --- | --- |
| 0 | Spikes | §14 answers in `docs/spikes.md` | pgmq, pg_net, Vault, Realtime, Edge runtime locally | All five written up |
| 1 | Foundation | Repo, toolchain (§3), CI, translated schema (§7), auth three ways (§8), generated types, ported pgTAP | Postgres/RLS, Auth, `@supabase/ssr`, UI Library, CLI, pgTAP | pgTAP green; Playwright signs in by password, link and code |
| 2 | Providers I | TIDAL + Subsonic adapters behind one interface (the Elixir `Providers.Adapter` callbacks: `whoami`, `streamPlaylists`, `streamTracks`, `searchTracks`, `createPlaylist`, `addTracks`, `removeTracks`, `playlistTrackIds`, `acceptTrack`, `capabilities`); OAuth route handlers; Vault tokens; `token-refresh` function | Vault, first Edge Function, pg_cron | Connect both locally; a refresh happens without the user |
| 3 | Library | Recordings + playlists + items; `/playlists` and `/playlists/[id]` with reorder via `rpc`; Postgres Changes on `/connections` | Data API in anger, `rpc`, Postgres Changes | Import of Jason's library seed (§16) visible and editable |
| 4 | Matching | `packages/core` ladder + Vitest replays | — | Corpus tables match §11 within tolerance; **0 wrong** on enrichment corpus |
| 5 | Transfers | pgmq pipeline (§9), chunked worker, report, overrides, batch, Realtime report (§10) with authorization | Queues, Cron drains, Edge Functions, Broadcast from DB, Realtime Authorization | A TIDAL→Navidrome transfer whose report matches what landed; a killed worker resumes; a second run adds nothing |
| 6 | Files | CSV import via Dropzone → Storage → transfer; CSV export via signed URL; pruning jobs | Storage, policies, signed URLs, pg_cron + Edge Function pruning | Round-trip property test on the CSV codec; storage pgTAP green |
| 7 | Sync | Cadence, replace mode, `/syncs`, "run failed again" | pg_cron sweep in SQL | A weekly sync leaves one destination playlist, not fifty-two |
| 8 | Providers II | Spotify (confidential, `127.0.0.1`, `/items`, non-track filtering, `Retry-After`), YouTube Music (quota-aware, `search.list` budgeted) | — | Spotify→library transfer of a real playlist; YouTube add within quota |
| 9 | Hosted | Vercel + hosted project, custom SMTP, templates pasted, Branching on PRs, Advisors clean, `db lint` clean | Branching, Advisors, Logs, Management API | Production sign-in by magic link from a phone |
| 10 | Later | MusicBrainz enrichment queue; pgvector automatic embeddings for library search; identity spine; classical works; artwork; playlist sharing + Presence; anonymous sign-in for try-before-signup | pgvector, Presence, anonymous auth | Each its own row |

Phases 2 and 4 are independent and can be interleaved. Phase 5 depends on 2, 3 and 4.

---

## 16. Data migration

Everything that was gitignored in the Elixir repo, or lived only in its local Docker database,
was exported on 2026-09-12 into a **handoff bundle** that Jason moves to the new machine by
hand. **Ask Jason where he put it**; the plan assumes `~/one_playlist-handoff/`. It must never
be committed, and its directory should be gitignored in the new repo before the first file
is read from it. Contents:

| File | What it is | Used in |
| --- | --- | --- |
| `README.md` | This table, plus the caveats below | — |
| `library-export.sql` | `pg_dump --data-only --column-inserts` of `library_recordings` (661), `recording_enrichments` (661), `musicbrainz_releases` (705), `recording_identities` (615), `library_playlists` (7), `library_playlist_items` (815), `transfer_overrides` (1) | Phase 3 seed; phase 10 identity spine |
| `library-schema.sql` | `pg_dump --schema-only` of the same seven tables — the *effective* Elixir schema, so the transform script has the column list without running Elixir | Phase 1 (§7), phase 3 |
| `playlists/*.csv` | Seven Roon exports of Jason's playlists (one is 139 KB) | Phase 6: re-import through the new CSV importer |
| `musicbrainz_corpus.json`, `match_rate_results.json` | The two files `dev/measure/replay.exs` reads; **also committed** in the Elixir repo, copied here for convenience | Phase 4 |
| `dev_local.exs` | The Elixir app's local credentials: TIDAL and Spotify client id/secret and redirect URIs, local Supabase keys | Phase 2 and 8 — see caveats |

Caveats the agent must apply:

  * **User ids do not carry over.** `library_playlists.user_id`, `recording_identities` and
    `transfer_overrides` reference `auth.users` rows in the *old* local project. The transform
    script takes a `--owner <new user id>` argument and rewrites every `user_id` to Jason's
    account in the new project. `library_recordings` are ownerless and need no rewrite.
  * **Re-register redirect URIs, do not reuse them.** The TIDAL and Spotify developer apps are
    the same; add the new app's URIs (`/connect/tidal/callback` etc., and whatever port
    `next dev` uses) at each provider's dashboard alongside the old ones. Spotify's must be
    `127.0.0.1`. The secrets in `dev_local.exs` go into `apps/web/.env.local`, never into git.
  * **Personal data on a work machine is Jason's call, and he made it** — but keep the bundle
    out of any synced or shared location, and out of the repo.
  * The corpora in `dev/corpus/*.json` (six files) are committed in the Elixir repo; copy them
    from there into `corpora/`. They contain MusicBrainz and TIDAL catalogue data only.
  * Jason's TIDAL playlists need no export: they re-enter through a TIDAL transfer, which is a
    test of the adapter.
  * Not carried over, deliberately: the Navidrome `music/` and `data/` directories (synthetic
    audio, regenerated by `dev/navidrome/generate_library.py`, which is committed), the local
    Vault secrets (regenerable per environment), 592 `provider_connections` rows (almost all
    test fixtures; the three real ones are re-created by connecting), and 21 transfers (the
    reports are history, not data).

**Hard rule, inherited from a near miss:** the Elixir repo's `dev/` looked gitignored and was
not, and `git add -A` once swept real listening history into a public commit. In the new repo:
`corpora/` is committed and contains only MusicBrainz/TIDAL catalogue data; anything derived
from Jason's own library or history goes under a directory that is gitignored **before the
first file lands**, and the agent checks `git status` before every `git add -A`.

---

## 17. Open questions for Jason

The plan is complete without these; they gate specific phases.

1. **Which Supabase org** hosts the project — work-provided or personal (Free pauses after a
   week idle and lacks Branching; Pro has both)? Gates phase 9.
2. **SMTP provider** for hosted magic links (Resend is the default suggestion). Phase 9.
3. **Domain** for the Vercel deployment, which becomes `site_url` and the OAuth redirect URIs
   at four providers. Phase 9.
4. **Google Cloud project** — the same one can hold the Google sign-in client and the YouTube
   Data API credentials; quota is per project. Phases 1 and 8.
5. Whether to use **anonymous sign-in** for try-before-signup. Optional, phase 10.

---

## 18. Working agreements for the agent

  * Start every session by reading the new repo's `CLAUDE.md`; create it in phase 1 from the
    Elixir one's structure (goals, constraints, architecture, local dev, status table, backlog).
  * **Measure matching changes against the corpora, never by argument.**
  * **State the trade** whenever a Supabase-native choice costs friction, or a convenient choice
    skips Supabase — in the commit body.
  * Every table gets RLS, revokes, grants and a pgTAP test in the same migration.
  * Never a token in a log, an error context, or a client bundle. Never a key in the repo.
  * When `supabase-js`, the CLI, Edge Functions or Realtime behave surprisingly: reproduce
    offline, write it in `docs/supabase-notes.md` (or `docs/realtime-notes.md`), and consider
    filing it. That log is a deliverable — for Jason's job more than for this project.
  * Prefer reading the Supabase docs page over remembering it; the platform moves monthly.
  * Keep phases small enough to commit daily. Report honestly what a phase did **not** exercise
    (the Elixir status table's "What that run did not exercise" paragraph is the model).
