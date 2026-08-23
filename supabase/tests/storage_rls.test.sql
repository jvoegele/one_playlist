-- The Supabase Storage policies for the `playlists` bucket.
--
--     mix test.rls
--
-- The counterpart to `rls.test.sql` for objects rather than rows, and it exists
-- for a sharper reason. `storage.objects` grants `authenticated` every
-- privilege — INSERT, SELECT, UPDATE, DELETE, and more — because Supabase
-- granted them, not us. On the tables in `public` a missing grant is an outer
-- wall that fails with 42501 before any policy runs; here there is no such wall.
-- These four policies are the only thing between one user's uploads and
-- another's.

begin;

create extension if not exists pgtap with schema extensions;

select plan(8);

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'alice@storage.test', now(), now()),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'bob@storage.test', now(), now());

-- ---------------------------------------------------------------------------
-- The bucket, and the position we start from.
-- ---------------------------------------------------------------------------

select is(
  (select public from storage.buckets where id = 'playlists'),
  false,
  'the playlists bucket is private, so every download needs a signed URL'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'storage.objects'::regclass),
  'storage.objects has row level security enabled'
);

select is(
  (select count(*)::int from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname like 'own playlist files%'),
  4,
  'all four policies exist — select, insert, update and delete'
);

-- The update policy needs *both* halves. `using` alone would let a user move
-- their own object into somebody else's folder: it would pass the read test on
-- the way in and land where they cannot write.
select isnt(
  (select with_check from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname = 'own playlist files update'),
  null,
  'the update policy has a with-check, not only a using clause'
);

-- ---------------------------------------------------------------------------
-- As Alice.
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', true);

insert into storage.objects (bucket_id, name, owner_id)
values ('playlists', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/imports/mine.csv',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');

select is(
  (select count(*)::int from storage.objects where bucket_id = 'playlists'),
  1,
  'alice sees the object she just created'
);

-- The path is the ownership model: the policies compare auth.uid() against the
-- first folder, so a file stored anywhere else is a file nobody can read.
select throws_ok(
  $$insert into storage.objects (bucket_id, name, owner_id)
    values ('playlists', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/imports/planted.csv',
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')$$,
  '42501',
  'new row violates row-level security policy for table "objects"',
  'alice cannot write into bob''s folder'
);

-- Moving her own object into Bob's folder is the case a using-only policy would
-- allow, and the reason the with-check above is asserted separately.
select throws_ok(
  $$update storage.objects
       set name = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/imports/moved.csv'
     where name = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/imports/mine.csv'$$,
  '42501',
  'new row violates row-level security policy for table "objects"',
  'alice cannot move her own object into bob''s folder'
);

-- ---------------------------------------------------------------------------
-- As Bob.
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  '{"sub":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', true);

select is(
  (select count(*)::int from storage.objects
    where name = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/imports/mine.csv'),
  0,
  'bob cannot see alice''s object, even naming its exact path'
);

-- The delete policy is deliberately *not* exercised here. `storage.objects`
-- carries a `protect_objects_delete` trigger that refuses any direct DELETE
-- outright — "Direct deletion from storage tables is not allowed. Use the
-- Storage API instead." — so a pgTAP assertion about it would be testing the
-- trigger and not the policy.
--
-- It is covered instead in `test/one_playlist/storage_integration_test.exs`,
-- which goes through the real Storage API: Bob's delete of Alice's object
-- removes nothing and her file survives. That is also where the interesting
-- half lives, since Storage reports a successful deletion of zero objects and
-- `OnePlaylist.Storage.delete/2` turns that silence into `:not_found`.

reset role;

select * from finish();

rollback;
