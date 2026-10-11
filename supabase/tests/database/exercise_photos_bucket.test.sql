-- exercise-photos bucket: public read (GET /storage/v1/object/public/exercise-photos/<name> needs no policy),
-- JPEG photos + the JSON manifest only, small files, and no writes by anyone but the service role (the upload
-- script, scripts/upload-photos.mjs), which bypasses RLS.
begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

select is((select public from storage.buckets where id = 'exercise-photos'), true, 'exercise-photos bucket is public');
select is((select allowed_mime_types from storage.buckets where id = 'exercise-photos'),
  array['image/jpeg', 'application/json'], 'only JPEG photos and the JSON manifest can be uploaded');
select is((select file_size_limit from storage.buckets where id = 'exercise-photos'), 5242880::bigint,
  'objects are capped at 5 MB (the app rejects bigger photos anyway)');

-- An object written by the service role (as the upload script does).
insert into storage.objects (bucket_id, name) values ('exercise-photos', 'own-9999-0.jpg');
insert into auth.users (id, email, aud, role) values
  ('e0000000-0000-0000-0000-00000000000e', 'photos@test.local', 'authenticated', 'authenticated');

set local role anon;
select throws_ok(
  $$ insert into storage.objects (bucket_id, name) values ('exercise-photos', 'own-evil-0.jpg') $$,
  '42501'::char(5), null, 'anon cannot upload');
with changed as (update storage.objects set name = 'own-hacked-0.jpg' where bucket_id = 'exercise-photos' returning 1)
select is((select count(*) from changed)::int, 0, 'anon cannot overwrite or rename');
select is((select count(*) from storage.objects where bucket_id = 'exercise-photos')::int, 0,
  'anon cannot list the bucket through the API (public object URLs still work)');
select throws_ok(
  $$ insert into storage.buckets (id, name, public) values ('evil', 'evil', true) $$,
  '42501'::char(5), null, 'anon cannot create buckets');
with changed as (update storage.buckets set public = false where id = 'exercise-photos' returning 1)
select is((select count(*) from changed)::int, 0, 'anon cannot change the bucket');

set local role authenticated;
set local request.jwt.claims = '{"sub":"e0000000-0000-0000-0000-00000000000e","role":"authenticated"}';
select throws_ok(
  $$ insert into storage.objects (bucket_id, name) values ('exercise-photos', 'own-evil-1.jpg') $$,
  '42501'::char(5), null, 'a signed-in user cannot upload');
with changed as (update storage.objects set name = 'own-hacked-1.jpg' where bucket_id = 'exercise-photos' returning 1)
select is((select count(*) from changed)::int, 0, 'a signed-in user cannot overwrite or rename');
with changed as (update storage.buckets set public = false where id = 'exercise-photos' returning 1)
select is((select count(*) from changed)::int, 0, 'a signed-in user cannot change the bucket');

reset role;
-- Deletes can't be probed with SQL (Supabase blocks direct deletes from storage tables), so assert that no policy
-- gives anon/authenticated/public any access to storage objects (delete included); only the service role writes.
select is((select count(*) from pg_policies where schemaname = 'storage' and tablename in ('objects', 'buckets')
           and roles && array['anon', 'authenticated', 'public']::name[])::int, 0,
  'no storage policy grants anon or signed-in users anything (no insert, update, delete or list)');
select is((select name from storage.objects where bucket_id = 'exercise-photos'), 'own-9999-0.jpg',
  'the service-role object is untouched');

select * from finish();
rollback;
