-- Row level security, tested where it is actually enforced: in Postgres.
--
--     supabase test db
--
-- These are the counterpart to test/one_playlist/repo_test.exs, not a duplicate
-- of it. That file proves the *application* reaches the database as the right
-- role; this one proves the policies themselves say what they should, for any
-- caller — including PostgREST, which is how a hosted project exposes these
-- tables to the internet and is the door RLS has always been guarding here.
--
-- Everything runs inside a transaction that is rolled back, so the users and
-- rows created below never reach the database a developer is using. That is
-- worth stating because GoTrue's own writes do not have this property: an
-- account created through the Auth API persists, which is why the Elixir
-- integration tests need unique addresses and these do not.

begin;

create extension if not exists pgtap with schema extensions;

select plan(34);

-- Two users, written straight into auth.users. Fine here: this is a test
-- fixture inside a doomed transaction, not a sign-up path.
insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
values
  ('11111111-1111-4111-8111-111111111111', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'alice@pgtap.test', now(), now()),
  ('22222222-2222-4222-8222-222222222222', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'bob@pgtap.test', now(), now());

insert into public.provider_connections
  (id, user_id, provider, provider_user_id, display_name, access_token, scopes, status,
   inserted_at, updated_at)
values
  (gen_random_uuid(), '11111111-1111-4111-8111-111111111111', 'tidal', 'a', 'alice tidal',
   'secret-a', '{}', 'active', now(), now()),
  (gen_random_uuid(), '22222222-2222-4222-8222-222222222222', 'tidal', 'b', 'bob tidal',
   'secret-b', '{}', 'active', now(), now());

-- A transfer each, and a correction against alice's. `transfer_overrides` is
-- the table a person's hand-made match lives in, so somebody else reading or
-- rewriting one would be editing another user's playlist by proxy.
insert into public.transfers
  (id, user_id, source_provider, source_playlist_id, destination_provider, threshold,
   status, inserted_at, updated_at)
values
  ('aaaaaaaa-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
   'tidal', 'alice-src', 'tidal', 0.75, 'completed', now(), now()),
  ('bbbbbbbb-0000-4000-8000-000000000002', '22222222-2222-4222-8222-222222222222',
   'tidal', 'bob-src', 'tidal', 0.75, 'completed', now(), now());

insert into public.transfer_overrides
  (id, transfer_id, user_id, position, destination_track_id, destination_title, inserted_at)
values
  (gen_random_uuid(), 'aaaaaaaa-0000-4000-8000-000000000001',
   '11111111-1111-4111-8111-111111111111', 0, 'alice-pick', 'Alice''s choice', now()),
  (gen_random_uuid(), 'bbbbbbbb-0000-4000-8000-000000000002',
   '22222222-2222-4222-8222-222222222222', 0, 'bob-pick', 'Bob''s choice', now());

-- A sync each. A sync is the sharpest of these tables: it is a standing
-- instruction the *system* acts on, unattended, with the owner's provider
-- credentials. A caller able to write one could point somebody else's
-- credentials at somebody else's playlist and have the application do it on a
-- schedule — which is why `authenticated` is granted select and nothing more.
insert into public.syncs
  (id, user_id, source_provider, source_playlist_id, source_playlist_name,
   destination_provider, interval_minutes, enabled, inserted_at, updated_at)
values
  (gen_random_uuid(), '11111111-1111-4111-8111-111111111111',
   'tidal', 'alice-src', 'Alice''s weekly', 'tidal', 1440, true, now(), now()),
  (gen_random_uuid(), '22222222-2222-4222-8222-222222222222',
   'tidal', 'bob-src', 'Bob''s weekly', 'tidal', 1440, true, now(), now());

-- Alice's is a mirror, which is the setting that deletes. It exists in this
-- fixture so the test below is asking about a row where being able to write
-- `mode` would matter most.
update public.syncs set mode = 'replace'
 where user_id = '11111111-1111-4111-8111-111111111111';

-- ---------------------------------------------------------------------------
-- The starting position: protection is opt-in, so assert it was opted into.
-- ---------------------------------------------------------------------------

select ok(
  (select relrowsecurity from pg_class where oid = 'public.provider_connections'::regclass),
  'provider_connections has row level security enabled'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.transfers'::regclass),
  'transfers has row level security enabled'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.transfer_items'::regclass),
  'transfer_items has row level security enabled'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.transfer_overrides'::regclass),
  'transfer_overrides has row level security enabled'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.syncs'::regclass),
  'syncs has row level security enabled'
);

-- A missing grant fails with 42501 *before* any policy runs, so the revoke is
-- the outer wall and the policies are the inner one. Both are load-bearing.
select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public'
      and table_name in ('provider_connections', 'transfers', 'transfer_items',
                         'transfer_overrides', 'syncs')),
  0,
  'anon has been granted nothing on the user-owned tables'
);

-- Read-only for the user, like `transfers` and for a sharper reason. The
-- application writes syncs as `postgres`; a client that could insert or update
-- one would be writing a job the system then executes with credentials it
-- holds.
select is(
  (select string_agg(distinct privilege_type, ',' order by privilege_type)
     from information_schema.role_table_grants
    where grantee = 'authenticated' and table_schema = 'public'
      and table_name = 'syncs'),
  'SELECT',
  'authenticated may only read syncs, never write one'
);

-- The ownerless tables are protected by the *absence* of a grant rather than by
-- a policy, because there is no owner to compare against. Nothing enforces that
-- but this: adding a policy-shaped table and forgetting the revoke leaves it
-- readable through PostgREST by anyone with the anon key.
select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where grantee in ('anon', 'authenticated') and table_schema = 'public'
      and table_name in ('catalogue_release_lookups', 'musicbrainz_isrc_lookups',
                         'musicbrainz_work_lookups', 'musicbrainz_releases')),
  0,
  'the ownerless caches are granted to nobody'
);

-- The *other* ownerless shape, and it is not the same one. `library_recordings`,
-- `recording_identities` and `recording_enrichments` are public metadata: every
-- signed-in user may read them, and none may write. So the assertion is not "no
-- grants" but "exactly one grant, and it is SELECT" — a write grant here would
-- let any anon-key holder rewrite the shared store through PostgREST.
select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public'
      and table_name in ('library_recordings', 'recording_identities',
                         'recording_enrichments')),
  0,
  'anon reaches no part of the shared recording store'
);

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where grantee = 'authenticated' and table_schema = 'public'
      and privilege_type <> 'SELECT'
      and table_name in ('library_recordings', 'recording_identities',
                         'recording_enrichments')),
  0,
  'authenticated may read the shared recording store and never write it'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.recording_enrichments'::regclass),
  'recording_enrichments has row level security enabled'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.musicbrainz_isrc_lookups'::regclass),
  'musicbrainz_isrc_lookups has row level security enabled'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.musicbrainz_work_lookups'::regclass),
  'musicbrainz_work_lookups has row level security enabled'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.musicbrainz_releases'::regclass),
  'musicbrainz_releases has row level security enabled'
);

-- ---------------------------------------------------------------------------
-- As Alice.
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);

select is(
  (select count(*)::int from public.provider_connections),
  1,
  'an unscoped select as alice returns only her own row'
);

select is(
  (select display_name from public.provider_connections),
  'alice tidal',
  'and it is the right one'
);

-- Naming the other user explicitly must not help: the policy is a filter on
-- every row considered, not a default that a WHERE clause can override.
select is(
  (select count(*)::int from public.provider_connections
    where user_id = '22222222-2222-4222-8222-222222222222'),
  0,
  'asking for bob''s row by his id still returns nothing'
);

-- The write side. `own connections insert` has a WITH CHECK, so a row that
-- would belong to somebody else must be refused rather than silently accepted.
select throws_ok(
  $$insert into public.provider_connections
      (id, user_id, provider, provider_user_id, display_name, access_token, scopes, status,
       inserted_at, updated_at)
    values (gen_random_uuid(), '22222222-2222-4222-8222-222222222222', 'navidrome', 'x',
            'planted', 'secret', '{}', 'active', now(), now())$$,
  '42501',
  'new row violates row-level security policy for table "provider_connections"',
  'alice cannot create a connection owned by bob'
);

-- Updating somebody else's row is not an error, it simply matches nothing —
-- the policy removes the row from consideration before the UPDATE sees it.
update public.provider_connections
   set display_name = 'stolen'
 where user_id = '22222222-2222-4222-8222-222222222222';

select is(
  (select count(*)::int from public.provider_connections where display_name = 'stolen'),
  0,
  'alice cannot rename bob''s connection'
);

-- ---------------------------------------------------------------------------
-- The system/user boundary. `transfers` grants `authenticated` only SELECT:
-- users read their transfers, and the application writes them from a privileged
-- context because creating one also enqueues an Oban job, in a schema no user
-- can touch. That split is a decision, so it is asserted rather than assumed —
-- a stray `grant insert` would otherwise go unnoticed until it mattered.
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where grantee = 'authenticated' and table_schema = 'public'
      and table_name = 'transfers' and privilege_type <> 'SELECT'),
  0,
  'authenticated may only select from transfers, never write'
);

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where grantee = 'authenticated' and table_schema = 'public'
      and table_name = 'transfer_items' and privilege_type <> 'SELECT'),
  0,
  'authenticated may only select from transfer_items, never write'
);

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where grantee = 'authenticated' and table_schema = 'public'
      and table_name = 'transfer_overrides' and privilege_type <> 'SELECT'),
  0,
  'authenticated may only select from transfer_overrides, never write'
);

-- The application writes an override only after the destination has accepted
-- the track. A client able to insert one directly could claim a track had been
-- added that never was, and the next run would trust it over the engine.
select throws_ok(
  $$insert into public.transfer_overrides
      (id, transfer_id, user_id, position, destination_track_id, inserted_at)
    values (gen_random_uuid(), 'aaaaaaaa-0000-4000-8000-000000000001',
            '11111111-1111-4111-8111-111111111111', 5, 'forged', now())$$,
  '42501',
  'permission denied for table transfer_overrides',
  'a user cannot record a correction directly, grant refused before any policy runs'
);

select is(
  (select destination_track_id from public.transfer_overrides),
  'alice-pick',
  'alice sees her own correction and not bob''s'
);

select throws_ok(
  $$insert into public.transfers
      (id, user_id, source_provider, source_playlist_id, destination_provider, threshold,
       status, inserted_at, updated_at)
    values (gen_random_uuid(), '11111111-1111-4111-8111-111111111111', 'tidal', 'x', 'tidal',
            0.75, 'pending', now(), now())$$,
  '42501',
  'permission denied for table transfers',
  'a user cannot create a transfer directly, grant refused before any policy runs'
);

-- ---------------------------------------------------------------------------
-- As Bob, to prove the filter is per-caller rather than "alice sees one row".
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);

select is(
  (select display_name from public.provider_connections),
  'bob tidal',
  'bob sees his own row and not alice''s'
);

select is(
  (select count(*)::int from public.provider_connections where display_name = 'stolen'),
  0,
  'and bob''s row was never renamed'
);

select is(
  (select destination_track_id from public.transfer_overrides),
  'bob-pick',
  'and bob sees only his own correction'
);

select is(
  (select source_playlist_name from public.syncs),
  'Bob''s weekly',
  'and bob sees only his own standing instruction'
);

-- The one that matters most on this table. Pausing somebody else's sync, or
-- pointing it somewhere new, is an attack the read policy alone does not stop —
-- it is the missing grant that does, and a grant is easy to add back by
-- accident when a later migration needs one.
select throws_ok(
  $$update public.syncs set enabled = false$$,
  '42501',
  null,
  'bob cannot pause a sync, not even his own'
);

-- The sharpest version of the same wall. `mode = 'replace'` is the setting that
-- makes a sync delete tracks; a client that could set it could turn somebody's
-- add-only schedule into a destructive one, and the next sweep would carry it
-- out with the owner's own credentials.
select throws_ok(
  $$update public.syncs set mode = 'replace'$$,
  '42501',
  null,
  'and cannot turn a sync into a mirror'
);

-- ---------------------------------------------------------------------------
-- With no identity at all.
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', '', true);

select is(
  (select count(*)::int from public.provider_connections),
  0,
  'an authenticated session with no sub claim sees nothing'
);

select is(
  (select count(*)::int from public.transfer_overrides),
  0,
  'and no corrections either'
);

select is(
  (select count(*)::int from public.syncs),
  0,
  'and no standing instructions either'
);

reset role;

select * from finish();

rollback;
