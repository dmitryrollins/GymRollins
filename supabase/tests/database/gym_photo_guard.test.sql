-- The trigger on storage.objects (20261030000003): the rules for gym photos that must hold even for the write that runs
-- after an upload token was issued, with no session. Driven here as the database owner, which is what that write is.
begin;
create extension if not exists pgtap with schema extensions;
select plan(26);

insert into auth.users (id, email, aud, role) values
  ('abababab-0000-0000-0000-000000000001', 'photo-a@test.local', 'authenticated', 'authenticated'),
  ('abababab-0000-0000-0000-000000000002', 'photo-b@test.local', 'authenticated', 'authenticated');

create function pg_temp.as_user(n int) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    format('{"sub":"abababab-0000-0000-0000-00000000000%s","role":"authenticated"}', n), true);
end $$;
grant execute on function pg_temp.as_user(int) to authenticated;

-- n photo rows for a user with the given age, as Storage would have written them
create function pg_temp.photos(owner text, n int, age interval default interval '0') returns void
language sql as $$
  insert into storage.objects (bucket_id, name, owner_id, created_at, metadata)
  select 'gym-photos', gen_random_uuid()::text || '.jpg', owner, now() - age, '{"mimetype":"image/jpeg"}'
  from generate_series(1, n)
$$;

select is(gym_private.daily_photo_limit(), 60, 'the daily limit is 60 (DomainLimits.dailyPhotoUploads)');

-- Inserts ---------------------------------------------------------------------------------------------------------------
select lives_ok($$ insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'abcdabcd-0000-4000-8000-000000000001.jpg', 'abababab-0000-0000-0000-000000000001', '{"mimetype":"image/jpeg"}') $$,
  'a JPEG from an existing user is stored');
select lives_ok($$ insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos-private', 'abcdabcd-0000-4000-8000-000000000002.jpg', 'abababab-0000-0000-0000-000000000001', '{"mimetype":"image/jpeg"}') $$,
  'and in the private bucket');
select throws_ok($$ insert into storage.objects (bucket_id, name, metadata) values
  ('gym-photos', 'abcdabcd-0000-4000-8000-000000000003.jpg', '{"mimetype":"image/jpeg"}') $$,
  '42501'::char(5), 'photo_owner_missing', 'an upload with no owner is refused');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'abcdabcd-0000-4000-8000-000000000003.jpg', 'abababab-0000-0000-0000-0000000000ff', '{"mimetype":"image/jpeg"}') $$,
  '42501'::char(5), 'photo_owner_missing', 'an owner whose account is gone is refused (a token outlives it)');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'abcdabcd-0000-4000-8000-000000000003.jpg', 'not-a-uuid', '{"mimetype":"image/jpeg"}') $$,
  '42501'::char(5), 'photo_owner_missing', 'an owner that is no id is refused');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'abcdabcd-0000-4000-8000-000000000003.jpg', 'abababab-0000-0000-0000-000000000001', '{"mimetype":"image/svg+xml"}') $$,
  '42501'::char(5), 'photo_not_jpeg', 'SVG is refused');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'abcdabcd-0000-4000-8000-000000000003.jpg', 'abababab-0000-0000-0000-000000000001', '{"mimetype":"application/octet-stream"}') $$,
  '42501'::char(5), 'photo_not_jpeg', 'so is the type a resumable upload gets without a content type');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id) values
  ('gym-photos', 'abcdabcd-0000-4000-8000-000000000003.jpg', 'abababab-0000-0000-0000-000000000001') $$,
  '42501'::char(5), 'photo_not_jpeg', 'a missing type is refused on the write with no session');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'abababab-0000-0000-0000-000000000001/abcdabcd-0000-4000-8000-000000000003.jpg',
   'abababab-0000-0000-0000-000000000001', '{"mimetype":"image/jpeg"}') $$,
  '42501'::char(5), 'photo_bad_name', 'a name with a folder (the uploader''s id) is refused');

-- A name a listing uses -------------------------------------------------------------------------------------------------
insert into public.gyms (id, visibility, name, maps_place_id)
  values ('abcdabcd-0000-4000-8000-0000000000a0', 'public', 'Photo Gym', 'photo-guard');
insert into public.gym_equipment (id, gym_id, item_id, visibility, photo_path, loads, added_by)
  values ('abcdabcd-0000-4000-8000-0000000000a1', 'abcdabcd-0000-4000-8000-0000000000a0',
          (select id from public.equipment_items where kind_id = 'flat-bench' and brand is null and model is null),
          'public', 'abcdabcd-0000-4000-8000-000000000001.jpg', '{"type":"none"}', 'abababab-0000-0000-0000-000000000001');
set local storage.allow_delete_query = 'true';
delete from storage.objects where name = 'abcdabcd-0000-4000-8000-000000000001.jpg';
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'abcdabcd-0000-4000-8000-000000000001.jpg', 'abababab-0000-0000-0000-000000000001', '{"mimetype":"image/jpeg"}') $$,
  '42501'::char(5), 'photo_name_in_use', 'deleting a listing''s photo and uploading its name again is refused');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'abcdabcd-0000-4000-8000-000000000001.jpg', 'abababab-0000-0000-0000-000000000002', '{"mimetype":"image/jpeg"}') $$,
  '42501'::char(5), 'photo_name_in_use', 'and so is another user taking it');

-- The daily limit -------------------------------------------------------------------------------------------------------
select pg_temp.photos('abababab-0000-0000-0000-000000000002', 59);
select lives_ok($$ insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos-private', 'abcdabcd-0000-4000-8000-000000000010.jpg', 'abababab-0000-0000-0000-000000000002', '{"mimetype":"image/jpeg"}') $$,
  'the 60th photo of a day is stored');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'abcdabcd-0000-4000-8000-000000000011.jpg', 'abababab-0000-0000-0000-000000000002', '{"mimetype":"image/jpeg"}') $$,
  '42501'::char(5), 'photo_daily_limit', 'the 61st is refused, the two buckets counting together');
delete from storage.objects where name = 'abcdabcd-0000-4000-8000-000000000010.jpg';
select lives_ok($$ insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'abcdabcd-0000-4000-8000-000000000011.jpg', 'abababab-0000-0000-0000-000000000002', '{"mimetype":"image/jpeg"}') $$,
  'a delete frees a slot (accepted: only 60 stay stored per day)');
select pg_temp.photos('abababab-0000-0000-0000-000000000001', 70, interval '2 days');
select lives_ok($$ insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'abcdabcd-0000-4000-8000-000000000012.jpg', 'abababab-0000-0000-0000-000000000001', '{"mimetype":"image/jpeg"}') $$,
  'photos older than a day do not count');

-- The write that comes with a session (Storage's permission check, rolled back afterwards) -------------------------------
select pg_temp.as_user(1);
select lives_ok($$ insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'abcdabcd-0000-4000-8000-000000000020.jpg', 'abababab-0000-0000-0000-000000000001', '{"mimetype":"application/json"}') $$,
  'a signed upload''s permission check, declaring its own type, is let through');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'abcdabcd-0000-4000-8000-000000000021.jpg', 'abababab-0000-0000-0000-000000000002', '{"mimetype":"image/jpeg"}') $$,
  '42501'::char(5), null, 'but the owner is still the caller');
reset role;
select set_config('request.jwt.claims', '', true);

-- Updates ---------------------------------------------------------------------------------------------------------------
select lives_ok($$ update storage.objects set last_accessed_at = now() + interval '1 minute'
  where name = 'abcdabcd-0000-4000-8000-000000000002.jpg' $$, 'last_accessed_at can change');
select throws_ok($$ update storage.objects set name = 'abcdabcd-0000-4000-8000-0000000000ee.jpg'
  where name = 'abcdabcd-0000-4000-8000-000000000002.jpg' $$, '42501'::char(5), 'photo_immutable', 'a photo cannot be renamed');
select throws_ok($$ update storage.objects set bucket_id = 'gym-photos'
  where name = 'abcdabcd-0000-4000-8000-000000000002.jpg' $$, '42501'::char(5), 'photo_immutable', 'or moved between buckets');
select throws_ok($$ update storage.objects set version = 'new-version'
  where name = 'abcdabcd-0000-4000-8000-000000000002.jpg' $$, '42501'::char(5), 'photo_immutable',
  'or uploaded over (every upload gets a new version)');
select throws_ok($$ update storage.objects set owner_id = 'abababab-0000-0000-0000-000000000002'
  where name = 'abcdabcd-0000-4000-8000-000000000002.jpg' $$, '42501'::char(5), 'photo_immutable', 'or handed to someone else');
select throws_ok($$ update storage.objects set metadata = '{"mimetype":"image/svg+xml"}'
  where name = 'abcdabcd-0000-4000-8000-000000000002.jpg' $$, '42501'::char(5), 'photo_not_jpeg', 'or given another type');

-- Other buckets are not touched ------------------------------------------------------------------------------------------
select lives_ok($$ insert into storage.objects (bucket_id, name) values ('exercise-photos', 'anything-0.png') $$,
  'the exercise bucket takes no owner, any name and no type');
select lives_ok($$ update storage.objects set name = 'anything-1.png' where bucket_id = 'exercise-photos' $$,
  'and renames');

select * from finish();
rollback;
