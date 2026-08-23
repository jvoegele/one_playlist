# Reference: Supabase for Elixir/Phoenix

Everything learned about Supabase relevant to building `one_playlist` on it, and to
Jason's goal of knowing Supabase deeply before starting there.

> **Meta-fact worth keeping in mind:** Supabase Realtime is itself written in **Elixir with
> the Phoenix Framework** (`github.com/supabase/realtime`, Apache 2.0). It listens to
> Postgres logical replication (via `cainophile` / `pgoutput_decoder`), serializes changes to
> JSON, and fans them out over Phoenix Channels. Supavisor, the connection pooler, is also
> Elixir. Reading those two repos is the highest-leverage Supabase-and-Elixir study available.

---

## 1. The platform in one paragraph

Supabase is a managed Postgres with a set of services bolted onto the same database:
**PostgREST** (auto REST API over your schema), **Auth** (GoTrue — users, OAuth, JWTs),
**Storage** (S3-backed object store with RLS), **Realtime** (Broadcast / Presence / Postgres
Changes), **Edge Functions** (Deno), and a set of Postgres extensions surfaced as products —
**Queues** (pgmq), **Cron** (pg_cron), **Vault** (encrypted secrets), **Vector** (pgvector),
**Wrappers** (FDWs). The unifying idea is that **authorization lives in the database** as Row
Level Security policies, and every client — browser, edge function, or Phoenix app — is just
a Postgres role.

For a Phoenix app the important consequence is: you have a choice between *going through
Supabase's HTTP APIs* (PostgREST/Auth/Storage) and *talking to the Postgres directly with
Ecto*. Both are legitimate, and this project should deliberately use both so as to learn both.

---

## 2. Connecting Postgres from Ecto

Four connection paths:

| Method | Host | Port | Best for | IP |
| --- | --- | --- | --- | --- |
| **Direct** | `db.<ref>.supabase.co` | 5432 | persistent servers, migrations, `pg_dump` | IPv6 (IPv4 add-on) |
| **Supavisor session mode** | `aws-<region>.pooler.supabase.com` | 5432 | persistent backends on IPv4-only networks | IPv4 |
| **Supavisor transaction mode** | `aws-<region>.pooler.supabase.com` | 6543 | serverless / edge, many transient connections | IPv4 |
| **Dedicated pooler (PgBouncer)** | `db.<ref>.supabase.co` | 6543 | high-perf paid tier, co-located | IPv6 (IPv4 add-on) |

- A Phoenix app is a **persistent server** → prefer **direct connection**, or **Supavisor
  session mode** if the host is IPv4-only. Fly.io is IPv6-capable; most CI is not.
- **Transaction mode does not support (Postgres-level) prepared statements.** With Ecto that
  means `prepare: :unnamed`. Supavisor has added support for parsing/broadcasting named
  prepared statements, but the safe configuration on transaction mode remains
  `prepare: :unnamed`. Session mode supports them normally.
- Username format differs: direct is `postgres`; pooler is `postgres.<project-ref>`.
- The IPv4 add-on **swaps** the AAAA record for an A record — it is not dual-stack.
- Always use SSL.

Working Ecto shape:

```elixir
# config/runtime.exs
config :one_playlist, OnePlaylist.Repo,
  url: System.fetch_env!("DATABASE_URL"),
  ssl: true,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
  # add `prepare: :unnamed` if and only if using the transaction pooler (:6543)
```

Ecto migrations run fine against the direct connection. Two schema-management styles are
possible; **pick one and be consistent**:
- Ecto migrations only (Supabase is "just Postgres"), with RLS policies written as raw SQL
  inside migrations via `execute/2`.
- Supabase CLI migrations (`supabase migration new`, `supabase db diff|push|reset`) as the
  source of truth, with Ecto in `:read`-schema mode.

Reserved Supabase schemas you must not clobber: `auth`, `storage`, `realtime`, `extensions`,
`graphql`, `vault`, `cron`, `pgmq`, `supabase_functions`. Your tables go in `public` (or your
own schema exposed to PostgREST).

---

## 3. API keys and Postgres roles

Supabase is migrating from JWT-format keys to prefixed keys. Both work during the transition;
the new ones become standard by end of 2026.

| Key | Unauthenticated request → role | Authenticated request → role |
| --- | --- | --- |
| **Publishable** `sb_publishable_...` (was `anon`) | `anon` | `authenticated` |
| **Secret** `sb_secret_...` (was `service_role`) | `service_role` (**bypasses RLS**) | `service_role` |

- The Phoenix backend uses the **secret key**. Never ship it to a browser. New-format secret
  keys additionally reject browser requests via User-Agent matching and can be rotated/deleted
  individually.
- Publishable keys are safe to expose; RLS is what protects the data behind them.

---

## 4. Auth (GoTrue)

### JWTs

`<header>.<payload>.<signature>`. Claims that matter: `iss`, `exp`, `sub` (user id),
`role` (**the Postgres role RLS policies run as**), `aud`, `email`, `app_metadata`,
`user_metadata`.

- **Asymmetric signing keys (ES256 / RS256) are the modern default and what you should use.**
  Public keys are published at
  `https://<ref>.supabase.co/auth/v1/.well-known/jwks.json` (10-minute cache), so a Phoenix
  backend can verify a token **locally** with no network round-trip and no shared secret.
- Legacy HS256 shared-secret projects cannot verify locally with equivalent safety; verification
  means calling `GET /auth/v1/user` with the JWT. Avoid.
- In Elixir, verify with `joken` (+ `JOSE`) or `jose` directly against the JWKS, caching the
  keys and honouring `kid`.

### Provider (OAuth) tokens — **the single most important constraint for this project**

When a user signs in with Spotify (or Google/YouTube etc.) via Supabase Auth, the session
contains `provider_token` and `provider_refresh_token`.

- **Supabase does not store them.** They appear once in the session response and are gone.
- **Supabase does not refresh them.** Renewing a Spotify access token with the Spotify refresh
  token is entirely your application's job.
- Supabase uses PKCE between *your app → Supabase Auth*, but the *Supabase Auth → Spotify* leg
  uses the plain Auth Code flow. This has historically made provider-token refresh awkward,
  especially for SPAs/mobile; a server-side app is the well-behaved case.

**Therefore:** `one_playlist` must capture `provider_token` / `provider_refresh_token` at
sign-in and persist them itself, encrypted, with its own refresh scheduler. See
[Vault](#8-vault--encrypted-secrets) and the "provider connections" note in `CLAUDE.md`.

### Spotify provider setup

1. Create an app at `developer.spotify.com/dashboard`.
2. Redirect URI: `https://<ref>.supabase.co/auth/v1/callback`
   (local: `http://localhost:54321/auth/v1/callback`).
3. Supabase Dashboard → Authentication → Providers → Spotify → client id + secret.
4. Request scopes at sign-in time (`playlist-read-private`, `playlist-modify-public`,
   `playlist-modify-private`, `user-library-read`, `user-library-modify`,
   `user-follow-read`, `user-follow-modify`, `user-top-read`).

### Elixir integration

`supabase_auth` (v1.0.0, part of the Potion SDK) ships Plug and LiveView integrations
(`Supabase.Auth.Plug`, `Supabase.Auth.LiveView`), covering email+password, phone+password,
magic link / OTP, OAuth, SSO, anonymous and MFA.

> #### What was actually built here, and why not the Plug {: .info}
>
> `one_playlist` uses the SDK for the **GoTrue API calls only**, and keeps its own session
> layer in `OnePlaylistWeb.UserAuth`. The reason is the RLS note below: the session layer is
> what has to step Postgres down from `postgres` to `authenticated` and set
> `request.jwt.claims`, and that seam has to be somewhere this repository controls.
>
> The rest of this section is what using the SDK actually taught, most of which contradicts
> what was written here before anything was built.

### The Agent-based client is deprecated, for security reasons

This document previously recommended the module-based client as the default:

```elixir
defmodule OnePlaylist.Supabase do
  use Supabase.Client, otp_app: :one_playlist   # starts an Agent
end
```

That pattern is deprecated as of `supabase_potion` 0.8, and the notice is a **security**
warning rather than a style note — paraphrasing it: the shared `Agent` state causes race
conditions in multi-user servers, and *user tokens can become mixed, allowing User A to
access User B's data.*

The mechanism is `set_auth/2`, which writes one user's access token into the single struct
every concurrent request reads. In a Phoenix application that is a data breach waiting for a
second simultaneous request.

**Build the client per call instead.** It is a struct built from config already in memory, so
there is nothing to amortise, and removing the shared state beats guarding it:

```elixir
def client do
  Supabase.init_client(base_url, api_key, %{})       # {:ok, %Supabase.Client{}}
end

def client_for(access_token) do
  with {:ok, client} <- client() do
    {:ok, Supabase.Client.update_access_token(client, access_token)}  # a *new* struct
  end
end
```

### Version pinning: the two `~> 1.0` entries below cannot coexist

`supabase_auth 1.0.0` requires `supabase_potion ~> 0.7`, so asking for `supabase_potion ~> 1.0`
fails resolution outright. Use `{:supabase_potion, "~> 0.8"}`.

### Errors: `Supabase.Error.code` is the HTTP status, not GoTrue's reason

`supabase_auth` installs no GoTrue-specific error parser, so the default one runs and reports
the **status class** — `:bad_request`, `:unprocessable_entity`, `:too_many_requests`. GoTrue's
own `error_code` (`invalid_credentials`, `email_not_confirmed`, `weak_password`,
`user_already_exists`, `over_email_send_rate_limit`) is left in `metadata.resp_body`.

That matters because a status class is not something a sign-in form can act on: "check your
password" and "check your inbox" are both 400. Dig the real code out and map it —
`OnePlaylist.Accounts` does, in two tiers, falling back to the status class so an
unrecognised code is reported loudly rather than as "wrong password".

### `sign_out` lives under `Supabase.Auth.Admin`

`Supabase.Auth.Admin.sign_out(client, session, scope)`. The module name suggests it needs the
service role key; it does not. It is `POST /logout` with the *user's own* access token, and is
the ordinary way a user signs out.

### `get_claims/3` raises on most malformed tokens

Wrap it if the token's provenance is uncertain, which is the only reason to be verifying one.
Characterised and filed — see `docs/supabase-sdk-issues.md`.

What it does well is the happy path: for a project with asymmetric signing keys it fetches the
JWKS, caches it, and verifies **in process**, so establishing identity from a token costs no
network round trip. Only HS256 projects fall back to asking the server.

### Sign-up has two shapes, and only one of them signs the user in

With email confirmation off (the CLI default locally) `sign_up/2` returns a session. With it
on — the likely production setting — it returns the user and a `nil` session, and the account
is not signed in until the link is clicked. Handle both, or development quietly diverges from
production on the one flow every user takes.

### Storage: `Supabase.Storage.File.list/3` cannot be called at all

Every call raises before reaching the network, so listing is unavailable and this project does
without it. Reproduction and analysis in `docs/supabase-sdk-issues.md`.

### Storage answers HTTP 400 for everything

The real status is in the body:

```
resp_status: 400
resp_body: {"statusCode": "404", "error": "not_found", "message": "Object not found"}
resp_body: {"statusCode": "403", "error": "Unauthorized",
            "message": "new row violates row-level security policy"}
```

So `Supabase.Error.code` is `:bad_request` for a missing object, a forbidden one, and a genuine
malformed request alike. Classifying on it reports a file that is simply not there as a
retryable infrastructure fault. Read `metadata.resp_body` — decoded or raw depending on content
type, exactly as GoTrue's errors arrive.

### `storage.objects` refuses direct DELETE

A `protect_objects_delete` trigger: *"Direct deletion from storage tables is not allowed. Use
the Storage API instead."* It fires on DELETE only — INSERT and UPDATE go straight through — so
a pgTAP test can set up objects by hand but cannot exercise the delete policy. That half is
covered through the real API in `test/one_playlist/storage_integration_test.exs`.

### The grant/policy balance is the opposite of `public`

Worth knowing before designing around it. On a table in `public` a missing grant is an outer
wall that fails with `42501` before any policy runs, so `revoke all` and the policies are two
independent defences. On `storage.objects`, Supabase has already granted `authenticated`
**every** privilege — INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER — and there
is no owner column to key on either. The path convention *is* the access control model: the
policies compare `auth.uid()` against `(storage.foldername(name))[1]`.

Two consequences this project acts on. Objects are only ever addressed through
`OnePlaylist.Storage.path_for/3`, whose postcondition states that the first segment is the owner
— a rewrite that reordered the segments would satisfy the type and file every upload where no
policy can match it. And the storage calls use the **user's access token**, not the service key,
which would bypass all four policies at once.

### Testing: `Req.Test` cannot reach it

The SDK selects its HTTP client per request, inside itself, so the `Req.Test` stubs used for
other providers here do not intercept it. The options are a swappable behaviour configured
through application env — global state, and `CLAUDE.md` records what that costs in async tests
— or integration tests against the local stack, which this suite already requires for its
database. This project took the second, tagged `:supabase` and excluded by default.

**Design decision to make deliberately:** Supabase Auth vs `mix phx.gen.auth`. Supabase Auth
is the right call *for this project* because (a) it gives us Spotify/Google OAuth for free,
(b) it is what Jason wants to learn, and (c) `auth.uid()` is what makes RLS work. The cost is
that Phoenix's `current_scope` conventions (see `AGENTS.md`) must be adapted rather than
generated.

---

## 5. Row Level Security

The heart of Supabase. Two sequential checks: **grants** (may this role do this at all?) then
**policies** (which rows?). A missing grant fails with `42501` before any policy runs, and
adding a policy does not remove a grant.

> #### Which door RLS is guarding here {: .info}
>
> Measured 2026-08-23. There are two ways into these tables and they are protected by
> different things:
>
> | | PostgREST | Ecto |
> | --- | --- | --- |
> | Connects as | `anon` / `authenticated` | `postgres` (`BYPASSRLS`) |
> | Exposed at | `:54321` locally, the public internet on a hosted project | localhost |
> | Protected by | grants, then policies | `Repo.as_user/3`, then the `where` clause |
>
> The policies were never inert — an earlier draft of this note said so and was wrong.
> Verified by signing up two users and asking as each: B gets `[]` from a table holding
> three rows, even when naming A's `user_id` explicitly. On the PostgREST door they have
> been doing real work all along.
>
> What they did *not* do was constrain this application's own queries, because `postgres`
> holds `rolbypassrls`. That gap shipped a real bug: `TransferLive.Show.mount/3` fetched a
> transfer by id with no owner check, so any signed-in user could read any transfer.
>
> `OnePlaylist.Repo.as_user/3` closes it, by making the Ecto door use the same policies as
> the PostgREST one — `set local role authenticated` plus the claims `auth.uid()` reads,
> per transaction. The read paths that serve a user now run inside it. Verified by
> mutation: deleting `user_id` from `Transfers.fetch/2`'s query leaves the whole suite
> passing, because Postgres refuses to return the row.
>
> Two things that cost time and are worth knowing before you build this:
>
>   * **`auth.uid()` is `coalesce(request.jwt.claim.sub, request.jwt.claims->>'sub')`.**
>     The *singular* legacy setting wins. Set only the plural one and anything that touched
>     the singular one silently redirects your queries to the wrong user. Set both, clear
>     both.
>   * **`SET LOCAL` is undone at transaction end, and under the Ecto sandbox there is no
>     such end.** The sandbox holds one transaction per test; `Repo.transaction/2` inside it
>     opens a *savepoint*, and releasing a savepoint does not undo a `SET LOCAL` made
>     within it. Without an explicit revert the connection stays `authenticated` for the
>     rest of the test and some unrelated later query fails.
>   * **Revert to what was there, not to `postgres`.** `Providers.disconnect/2` runs as a
>     user and calls `fetch_connection/2`, which does too. An inner scope that reverts to a
>     hard-coded role drops the outer one halfway through, so the enclosing write runs
>     privileged — the protection silently absent exactly where it was being added. Capture
>     the role and both claim settings on the way in and put them back on the way out.
>   * **A constraint violation inside the scope poisons the whole transaction.** Postgres
>     aborts on any error, so every later statement — including the revert — fails with
>     `25P02`, and that exception *replaces* the real one. `Repo.insert(…, mode: :savepoint)`
>     keeps a foreign-key error a changeset error, and the revert additionally tolerates an
>     already-doomed transaction, since rollback discards `SET LOCAL` anyway.

### Deleting a stored file needs an HTTP call, even from inside Postgres

`storage.objects` carries a `protect_delete` trigger:

```
ERROR: Direct deletion from storage tables is not allowed. Use the Storage API instead.
HINT:  This prevents accidental data loss from orphaned objects.
```

It is right to: a row there is half of a stored file, and the other half is a blob in the
backing store. Deleting the row alone orphans it. `INSERT` and `UPDATE` go straight through,
which is why a pgTAP test can set objects up but cannot exercise the delete policy.

So a scheduled tidy-up takes three extensions to do one thing: **`pg_cron`** runs it,
**`pg_net`** makes the request, **`supabase_vault`** holds the credential. This project does it
in `20260823180000_prune_stored_exports.exs`. Four things that cost time:

  * **`pg_net` cannot see `127.0.0.1:54321`.** It runs inside Postgres, in its own container,
    with no view of the host's port mapping. Locally the URL is a container name
    (`http://supabase_kong_one_playlist:8000`); in production it is the project URL. It changes
    per environment, so it belongs in Vault beside the key rather than in the migration.
  * **Only a service role key will do.** Deleting somebody's object means authenticating as
    somebody who may, and a user's token expires in an hour and lives in a browser cookie.
    `vault.decrypted_secrets` is readable by `postgres` and `service_role` only, so an
    `authenticated` session cannot reach it — which is what makes keeping it there acceptable.
  * **`pg_net` is asynchronous.** `net.http_delete` returns a request id; the response lands in
    `net._http_response` later. A scheduled function cannot confirm the deletion it asked for,
    which is fine when the job is idempotent: a failed request leaves the objects in place and
    tomorrow's run finds them again.
  * **The queued request is visible before it is sent**, in `net.http_request_queue`. That is
    what makes the whole thing testable inside the Ecto sandbox: build the request, assert its
    URL, method and body, roll back, and nothing ever leaves the machine. Note `body` is
    `bytea`, so it needs `convert_from(body, 'UTF8')` before it is JSON again.

### Storage has no rollback, so a transaction that touches it always leaks

Not a bug, just a consequence worth designing around. `OnePlaylist.Imports.import/4` stores an
upload before the transaction that creates its transfer, because there is no way to make the
two atomic: Postgres can roll back its half, and Storage cannot roll back the file.

So a failed insert leaves an object nobody refers to. The tests demonstrate it every run — the
Ecto sandbox rolls back the transfer while Storage keeps the file, which had left 106 orphans
by the time anybody counted.

The answer is not to avoid it but to sweep it: `public.prune_orphaned_imports/1` deletes
`imports` objects that no `transfers.source_playlist_id` points at. The grace period is the
part that matters — every successful upload is briefly an orphan too, in the window between
the file landing and the transaction committing, so a sweep with no grace would race it.

### Reads fail quietly; inserts fail loudly

Worth knowing before you design around either, because the asymmetry is not obvious and it
is the policy clause that decides it:

| Operation | Clause | What happens to another user's row |
| --- | --- | --- |
| `select` | `USING` | filtered out — you get nothing, no error |
| `update` | `USING` | matches nothing — `{0, nil}`, no error |
| `delete` | `USING` | matches nothing — `{0, nil}`, no error |
| `insert` | `WITH CHECK` | **raises** `42501 new row violates row-level security policy` |

So a read or a write *of* somebody else's data is silence, and creating a row *for* somebody
else is an exception. That is the right way round — silently discarding an insert would
leave a caller believing it had stored something — but it means "no error" is not evidence
that a write happened, and code that cares must check the affected count.

Verified by mutation, and worth doing before trusting any of this: remove the line in
`Providers.connect/3` that forces `user_id` to the caller, pass a different user's id, and
the insert is refused with `42501`. The application safeguard and the database policy are
genuinely independent — either alone stops it.

```sql
alter table public.playlists enable row level security;

revoke all on table public.playlists from anon, authenticated;
grant select, insert, update, delete on table public.playlists to authenticated;

create policy "owner can read" on public.playlists
  for select to authenticated
  using ( (select auth.uid()) = user_id );

create policy "owner can insert" on public.playlists
  for insert to authenticated
  with check ( (select auth.uid()) = user_id );

create policy "owner can update" on public.playlists
  for update to authenticated
  using ( (select auth.uid()) = user_id )
  with check ( (select auth.uid()) = user_id );
```

Rules and gotchas:

- `USING` filters existing rows (SELECT/UPDATE/DELETE); `WITH CHECK` validates new/resulting
  rows (INSERT/UPDATE). An UPDATE also needs a SELECT policy.
- **Always name the role with `TO`.** Without it the policy is evaluated for every role.
- `auth.uid()` returns `NULL` for unauthenticated requests, so `auth.uid() = user_id` fails
  *silently* rather than erroring. Prefer explicit null checks where it matters.
- `auth.jwt()` gives the whole token. **`raw_app_meta_data` is user-immutable and safe for
  authorization; `raw_user_meta_data` is user-writable and is not.**
- **Performance:** wrap auth functions in a subselect — `(select auth.uid()) = user_id` — so
  Postgres hoists it into an `initPlan` and evaluates it once per statement rather than per
  row. And **index every column a policy filters on**.
- Views: Postgres 15+ `create view ... with (security_invoker = true)` so the view respects
  the underlying table's policies.
- Bypass: the secret key / `service_role`, or a role with `bypassrls`. Server-side only.
- **Test policies with pgTAP** (`supabase test new`, `supabase test db`), switching roles with
  `set local role` and identity with `set local request.jwt.claim.sub`. A wrong policy fails
  quietly, which is exactly the failure mode that needs tests.

Because our Phoenix backend connects as the Postgres owner via Ecto, **RLS does not protect
us from our own bugs by default**. Two options, and this is a real architectural decision:
1. Connect Ecto as a role subject to RLS and set the request JWT claims per checkout
   (`set_config('request.jwt.claims', ...)`) — genuinely defence-in-depth, more machinery.
2. Enforce scoping in Elixir (Phoenix `current_scope` conventions) and keep RLS as protection
   for anything that reaches Postgres through PostgREST/Realtime/Storage.

Option 2 is the pragmatic default; option 1 is the better *learning* exercise. Consider doing
1 for the tables that Realtime/Storage also touch.

---

## 6. Realtime

Three products over one WebSocket:

- **Broadcast** — ephemeral low-latency client↔client messages. Also **Broadcast from the
  Database**: a trigger calls `realtime.broadcast_changes()` / `realtime.send()` to push a
  message on a topic. This is the scalable modern replacement for Postgres Changes.
- **Presence** — synchronized shared state (who's online, who's viewing a transfer).
- **Postgres Changes** — logical-replication-driven insert/update/delete events. Simpler, but
  authorization is evaluated per-subscriber and it scales worse than broadcast-from-database.

### Authorization

- A `realtime.messages` table in the `realtime` schema is the RLS surface. On channel join,
  Realtime runs a query against it and **rolls back** — no messages are stored.
- Policies check `realtime.topic()` (the channel topic the client is joining) and the
  `extension` column (`'broadcast'` / `'presence'`).
- **Private channels:** disable "Allow public access" in Realtime Settings and set
  `private: true` client-side.
- Policies are **cached for the life of the connection**. Clients must send a fresh JWT via
  the `access_token` message; a client whose JWT expires without renewal is disconnected. Keep
  JWT lifetimes short.

### For this project

Phoenix already has its own PubSub and LiveView, so in-app live updates should use those —
there is no reason to round-trip through Supabase Realtime for our own UI. Realtime earns its
place for:
- multi-device / multi-tab sync of transfer progress,
- anything a future non-Phoenix client (mobile, browser extension) would consume,
- and as a deliberate learning exercise: connect Phoenix *as a Realtime client* via
  `supabase_realtime`, and read `supabase/realtime` to see how a Phoenix app is built at scale.

---

## 7. Queues (pgmq)

Postgres-native durable message queue with guaranteed delivery and exactly-once semantics
within a **visibility timeout** window.

- Enable the `pgmq` extension; queues live in the `pgmq` schema.
- Core operations (via the `pgmq` SQL functions, surfaced by Supabase as
  `pgmq_public.*` for API access): create queue, `send` / `send_batch`, `read` (with vt),
  `pop`, `archive`, `delete`.
- Queue variants: standard, **unlogged** (faster, not crash-safe), **partitioned** (needs
  `pg_partman`).
- Access control via API permissions + RLS on the queue tables.
- Dashboard has queue creation/monitoring UI.

**For this project:** a transfer job is a natural queue payload. The alternative is **Oban**
(pure Elixir, Postgres-backed, mature, with cron/uniqueness/retries/telemetry and a good
Phoenix story). Recommendation: use **Oban** for the real work queue and use **Supabase
Queues** for at least one deliberate learning slice (e.g. a webhook-ingest queue), because
Oban is the better tool and Supabase Queues is the better lesson. Do not run both for the same
workload.

---

## 8. Vault — encrypted secrets

- A table of metadata plus an encrypted text column, using `pgsodium` for **AEAD**
  (encrypted *and* signed).
- Supabase pre-generates a per-database **root key stored outside SQL**, accessible only to
  libsodium inside the Postgres server. Only a key **ID** is stored in the database, so
  secrets are encrypted at rest *and in database dumps*.
- Explicitly recommended for "API keys, access tokens, and other secrets from external
  services that you need to access within your database."
- `pgsodium` itself is pending deprecation as a directly-used extension; use Vault's interface.

**This is the natural home for Spotify/Apple/Google provider refresh tokens** — with the
caveat that if the Phoenix app is the only consumer, `cloak_ecto` (application-side envelope
encryption) keeps the plaintext out of Postgres entirely and is more idiomatic Elixir. Decide
explicitly; do not do both.

---

## 9. Storage

- **Buckets** (public or private) containing **objects**; RLS policies on `storage.objects`
  give fine-grained control.
- Signed URLs for time-limited access to private objects.
- **TUS resumable uploads**; **S3-compatible protocol** with dedicated access keys (so any S3
  client, including `ex_aws_s3`, works).
- Global CDN (285+ cities) and on-the-fly **image transformations** (resize/compress).
- Newer bucket types: **Analytics buckets** (Apache Iceberg) and **Vector buckets**.

**For this project:** playlist cover art (uploaded and generated), CSV/M3U/XSPF/JSON exports
that users download, and transfer reports.

---

## 10. Cron (pg_cron)

- `cron` schema with `cron.job` and `cron.job_run_details`.
- Schedules SQL, database functions, or **HTTP requests via `pg_net`** (which is how you
  invoke an Edge Function on a schedule).
- Granularity from every second to once a year.
- Supabase guidance: **≤ 8 concurrent jobs, ≤ 10 minutes per job.**
- Manage via SQL (`cron.schedule` / `cron.unschedule`) or the Dashboard Integrations UI.

For scheduled playlist **sync** (the paid-tier feature in Soundiiz/TuneMyMusic), Oban Cron in
the Phoenix app is the better fit — it can hold OAuth refresh logic and rate-limited API calls.
Use `pg_cron` for database housekeeping (archiving old jobs, refreshing materialized views).

---

## 11. Edge Functions

- **Deno** / TypeScript. `supabase functions serve` locally, `supabase functions deploy`.
- Globally distributed; **cold starts are real** — design for short-lived, idempotent work.
- Secrets via project secrets → environment variables.
- The edge gateway validates Supabase JWTs and applies rate limits before your code runs;
  functions can also verify internally.
- Treat Postgres as a remote pooled service from a function (transaction-mode pooler).

**For this project, Edge Functions are mostly the wrong tool** — a Phoenix app already has a
better place for every long-running or stateful task. Use them for exactly what they are good
at, and as a learning exercise: OAuth callback shims, webhook receivers that must respond in
milliseconds, or anything that must run at the edge close to the user.

---

## 12. Vector / pgvector

- `vector` extension; `vector(n)` and **`halfvec(n)`** (16-bit floats — needed for >2000
  dimensions; HNSW supports up to 4000 halfvec dimensions; pgvector 0.7+ stores up to 16,000).
- **HNSW** is the recommended index (performance + robustness to changing data);
  IVFFlat is the alternative.

```sql
create table track_embeddings (id bigint primary key, embedding halfvec(1536));
create index on track_embeddings using hnsw (embedding halfvec_cosine_ops);
-- query with the matching operator: <=> for cosine
```

- Supabase also offers **automatic embeddings** (a pgmq + pg_cron + pg_net pipeline that
  keeps an embedding column in sync with a text column).

**For this project:** semantic track matching as a *fallback* after ISRC and fuzzy-text
matching fail, and "playlists like this one" / AI playlist generation (a headline Soundiiz
feature).

---

## 13. Local development

```
brew install supabase/tap/supabase     # needs a Docker-compatible runtime
supabase init                          # creates supabase/ + config.toml
supabase start                         # boots the whole stack in Docker
supabase stop                          # halts without deleting data
```

Default local ports:

| Service | Port |
| --- | --- |
| API gateway (REST, GraphQL, Edge Functions, Realtime) | 54321 |
| Postgres | 54322 |
| Studio | 54323 |
| Mailpit (SMTP capture) | 54324 |

Other commands worth knowing: `supabase link --project-ref <ref>`, `supabase db pull`,
`supabase db diff`, `supabase db push`, `supabase db reset` (re-applies migrations + `seed.sql`),
`supabase migration new <name>`, `supabase functions serve|deploy`, `supabase test new|db`
(pgTAP), `supabase gen types`.

Disable telemetry with `supabase telemetry disable` / `SUPABASE_TELEMETRY_DISABLED=1`.

The local stack is the right target for the test suite — it gives real RLS, real Auth, and
real Realtime without touching a hosted project.

---

## 14. The Elixir SDK (Supabase Potion)

Community-maintained monorepo: `github.com/supabase-community/supabase-ex`.

| Package | Version | Purpose |
| --- | --- | --- |
| `supabase_potion` | **~> 0.8** | base SDK / `Supabase.Client` |
| `supabase_auth` | ~> 1.0 (was `supabase_gotrue`) | Auth + Plug + LiveView integration |
| `supabase_postgrest` | ~> 1.0 | PostgREST query builder |
| `supabase_storage` | ~> 0.4 | Storage |
| `supabase_realtime` | ~> 0.1 | Realtime client |
| `supabase_functions` | ~> 0.1 | Edge Function invocation |

`supabase_potion` is pinned to `~> 0.8` rather than `~> 1.0` because `supabase_auth 1.0.0`
requires `~> 0.7` and the two `1.0`s cannot resolve together. Verified, not assumed.

**Build the client per call.** The module-based `use Supabase.Client` client that this section
used to recommend keeps its struct in an `Agent`, and that is deprecated for security reasons —
see §4. What this project does:

```elixir
defmodule OnePlaylist.Supabase do
  def client do
    config = Application.get_env(:one_playlist, __MODULE__, [])
    Supabase.init_client(config[:base_url], config[:api_key], %{})
  end
end
```

> #### The api_key is the publishable key, never the service role key {: .error}
>
> This section previously showed `api_key: System.fetch_env!("SUPABASE_SECRET_KEY")`. That is
> wrong and dangerous: the service role key carries `role: "service_role"`, which Postgres
> grants `BYPASSRLS`, so every policy in the schema is ignored. Signing a user in with it
> would authenticate anybody as anybody.
>
> Use the **anon / publishable** key. It is designed to be exposed — it ships inside browser
> bundles — and grants nothing RLS does not already allow. The service role key belongs only
> in trusted server-side jobs that deliberately need to bypass RLS, and never on a request
> path carrying a user's identity.

HTTP layer is configurable via `:http_client`, `:finch_name`, `:finch_pool`. Note the SDK uses
**Finch**, while Phoenix 1.8 ships **Req** (which is itself Finch-based) — `AGENTS.md` says to
use Req for our own HTTP calls. Both can coexist; keep provider HTTP calls on Req and let the
SDK use its own Finch pool.

Older/abandoned alternatives you may encounter in search results: `treebee/supabase-elixir`,
`jehrhardt/supabase-elixir`. Prefer the `supabase-community` monorepo.

---

## 15. Study list (for the "learn Supabase before starting there" goal)

1. `github.com/supabase/realtime` — a large production Elixir/Phoenix app. Read the channel
   authorization path and the replication pipeline.
2. `github.com/supabase/supavisor` — Elixir multi-tenant Postgres pooler.
3. `github.com/supabase/auth` (GoTrue, Go) — how the JWT/session/provider-token model actually
   works, including the PKCE-vs-provider-refresh-token issue that bites this project.
4. `github.com/supabase/storage` and `postgrest/postgrest`.
5. Supabase blog posts on Supavisor 1.0, Realtime Multiplayer GA, Vault, and Automatic
   Embeddings.
6. pgTAP-based RLS testing — the practice Supabase itself recommends and that most users skip.
