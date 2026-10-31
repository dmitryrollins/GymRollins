-- Gyms, the shared catalogue and listings: who can read what, who can write what, and the sharing functions.
-- Spec §5 "Reads and access rules" and "Sharing, confirming, reporting", §8. Criteria 2 and 4 at the database level.
begin;
create extension if not exists pgtap with schema extensions;
select plan(146);

insert into auth.users (id, email, aud, role) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'gym-a@test.local', 'authenticated', 'authenticated'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'gym-b@test.local', 'authenticated', 'authenticated'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'gym-c@test.local', 'authenticated', 'authenticated');

create function pg_temp.as_user(n int) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    format('{"sub":"aaaaaaaa-0000-0000-0000-00000000000%s","role":"authenticated"}', n), true);
end $$;
create function pg_temp.as_mcp(n int) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    format('{"sub":"aaaaaaaa-0000-0000-0000-00000000000%s","role":"authenticated","client_id":"claude"}', n), true);
end $$;
create function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
end $$;
grant execute on function pg_temp.as_user(int), pg_temp.as_mcp(int), pg_temp.as_anon() to anon, authenticated;

-- Photos the Storage API would have stored. Names are bare: a folder per user would show every reader the uploader's id.
insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'cccccccc-0000-4000-8000-000000000001.jpg', 'aaaaaaaa-0000-0000-0000-000000000001', '{"mimetype":"image/jpeg"}'),
  ('gym-photos', 'cccccccc-0000-4000-8000-000000000002.jpg', 'aaaaaaaa-0000-0000-0000-000000000002', '{"mimetype":"image/jpeg"}'),
  ('gym-photos', 'cccccccc-0000-4000-8000-000000000003.jpg', 'aaaaaaaa-0000-0000-0000-000000000001', '{"mimetype":"image/jpeg"}'),
  ('gym-photos-private', 'cccccccc-0000-4000-8000-000000000004.jpg', 'aaaaaaaa-0000-0000-0000-000000000002', '{"mimetype":"image/jpeg"}');

-- Seeds ---------------------------------------------------------------------------------------------------------------
select is((select count(*) from public.equipment_kinds)::int, 46, '46 kinds are seeded');
select is((select count(*) from public.exercise_requirements)::int, 1107, 'requirements are seeded');
select is((select count(*) from public.equipment_items where brand is null and model is null)::int, 46,
  'one generic item per kind');
select is((select id from public.equipment_items where kind_id = 'dumbbells' and brand is null and model is null),
  'cdd9d434-9eca-5d33-8406-2bdea6b4c561'::uuid, 'the generic item id is the one the phone derives');

-- Curated data is read-only -------------------------------------------------------------------------------------------
select pg_temp.as_anon();
select is((select count(*) from public.equipment_kinds)::int, 46, 'anon reads kinds');
select is((select count(*) from public.public_equipment_items)::int, 46, 'anon sees the generic items');
select throws_ok($$ insert into public.equipment_kinds (id, name, category, load_type) values ('x','x','rack','none') $$,
  '42501'::char(5), null, 'anon cannot add kinds');
select pg_temp.as_user(1);
select throws_ok($$ update public.equipment_kinds set name = 'x' $$, '42501'::char(5), null, 'users cannot edit kinds');
select throws_ok($$ insert into public.equipment_items (kind_id, brand) values ('dumbbells', 'Acme') $$,
  '42501'::char(5), null, 'items are not written directly');

-- find_or_create_gym --------------------------------------------------------------------------------------------------
select pg_temp.as_anon();
select throws_ok($$ select public.find_or_create_gym('p1', 'Iron', null, 1, 2) $$, '42501'::char(5), null,
  'anon cannot create a gym');
select pg_temp.as_mcp(1);
select throws_ok($$ select public.find_or_create_gym('p1', 'Iron', null, 1, 2) $$, '42501'::char(5), null,
  'an MCP client cannot create a gym');
select pg_temp.as_user(1);
select lives_ok($$ select set_config('t.gym', public.find_or_create_gym('p1', 'Iron Works', ' 1 Main St ', 40, -74)::text, true) $$,
  'a user creates a public gym');
select is(public.find_or_create_gym('p1', 'Other name', null, 0, 0), current_setting('t.gym')::uuid,
  'the same place returns the same gym');
select is((select name from public.public_gyms where maps_place_id = 'p1'), 'Iron Works', 'the first name stands');
select is((select is_mine from public.public_gyms where maps_place_id = 'p1'), true, 'is_mine for its creator');
select throws_ok($$ select public.find_or_create_gym('', 'Iron', null, 1, 2) $$, '22023'::char(5), null,
  'a place id is required');

-- Direct writes to public rows are refused ----------------------------------------------------------------------------
select throws_ok(format($$ update public.gyms set created_by = null where id = %L $$, current_setting('t.gym')),
  '42501'::char(5), null, 'created_by is not writable');
select throws_ok($$ insert into public.gyms (visibility, name, client_updated_at) values ('public', 'Mine', now()) $$,
  '42501'::char(5), null, 'a client cannot create a public gym directly');
select throws_ok($$ select created_by from public.gyms limit 1 $$, '42501'::char(5), null, 'created_by is not readable');
select throws_ok($$ select owner_id from public.gyms limit 1 $$, '42501'::char(5), null, 'owner_id is not readable');
select throws_ok($$ select added_by from public.gym_equipment limit 1 $$, '42501'::char(5), null, 'added_by is not readable');
select throws_ok($$ select created_by from public.equipment_items limit 1 $$, '42501'::char(5), null,
  'an item''s created_by is not readable');

-- share_listing -------------------------------------------------------------------------------------------------------
select is(public.share_listing('bbbbbbbb-0000-0000-0000-000000000001', current_setting('t.gym')::uuid, 'lat-pulldown',
    null, null, '{"type":"stack","maxKg":113.4,"stepKg":4.5}', 1, 'by the window',
    'cccccccc-0000-4000-8000-000000000001.jpg') ->> 'status', 'created',
  'the first listing of a kind is created');
select is(public.share_listing('bbbbbbbb-0000-0000-0000-000000000001', current_setting('t.gym')::uuid, 'lat-pulldown',
    null, null, '{"type":"none"}', 1, null, null) ->> 'status', 'created',
  'a retry with the same id finds the listing');
select is((select count(*) from public.public_gym_equipment)::int, 1, 'and does not add another');
select is(public.share_listing('bbbbbbbb-0000-0000-0000-000000000002', current_setting('t.gym')::uuid, 'lat-pulldown',
    null, null, '{"type":"none"}', 1, null, null) ->> 'status', 'duplicates',
  'criterion 4: the same kind returns what is there');
select is(jsonb_array_length(public.share_listing('bbbbbbbb-0000-0000-0000-000000000002', current_setting('t.gym')::uuid,
    'lat-pulldown', null, null, '{"type":"none"}', 1, null, null) -> 'listings'), 1, 'with the existing listings');
select is(public.share_listing('bbbbbbbb-0000-0000-0000-000000000002', current_setting('t.gym')::uuid, 'lat-pulldown',
    'Hammer Strength', 'Pro', '{"type":"plates"}', 2, null, null, true) ->> 'status', 'created',
  'force_new adds a different one');
select throws_ok(format($$ select public.share_listing(gen_random_uuid(), %L, 'barbell', null, null, '{"type":"none"}', 1, null,
    'cccccccc-0000-4000-8000-000000000002.jpg') $$, current_setting('t.gym')),
  'P0001'::char(5), 'photo_missing', 'someone else''s photo is refused');
select throws_ok(format($$ select public.share_listing(gen_random_uuid(), %L, 'barbell', null, null, '{"type":"none"}', 1, null,
    '../evil.jpg') $$, current_setting('t.gym')), 'P0001'::char(5), 'photo_missing', 'a made-up path is refused');
select throws_ok(format($$ select public.share_listing(gen_random_uuid(), %L, 'barbell', null, null, '{"type":"none"}', 1, null,
    'cccccccc-0000-4000-8000-000000000001.jpg') $$, current_setting('t.gym')),
  'P0001'::char(5), 'photo_in_use', 'a photo cannot be used twice');
select throws_ok(format($$ select public.share_listing(gen_random_uuid(), %L, 'barbell', null, null, '{"type":"stack","maxKg":-1}', 1, null, null) $$,
    current_setting('t.gym')), '22023'::char(5), null, 'bad loads are refused');
select throws_ok(format($$ select public.share_listing(gen_random_uuid(), %L, 'barbell', null, null, '{"type":"fixed","kg":["x"]}', 1, null, null) $$,
    current_setting('t.gym')), '22023'::char(5), null, 'non-numeric weights are refused');
-- Shapes a range check alone would pass. Every client decodes these rows, so they must be exactly what the app writes.
select throws_ok(format($$ select public.share_listing(gen_random_uuid(), %L, 'barbell', null, null, %L, 1, null, null, true) $$,
    current_setting('t.gym'), '{"type":"stack","maxKg":1e-400}'), '22023'::char(5), null, 'a number JSONDecoder cannot read is refused');
select throws_ok(format($$ select public.share_listing(gen_random_uuid(), %L, 'barbell', null, null, %L, 1, null, null, true) $$,
    current_setting('t.gym'), '{"type":"fixed","kg":[1e-400]}'), '22023'::char(5), null, 'also in a fixed set');
select throws_ok(format($$ select public.share_listing(gen_random_uuid(), %L, 'barbell', null, null, %L, 1, null, null, true) $$,
    current_setting('t.gym'), '{"type":"plates","html":"<script>"}'), '22023'::char(5), null, 'extra keys are refused');
select throws_ok(format($$ select public.share_listing(gen_random_uuid(), %L, 'barbell', null, null, %L, 1, null, null, true) $$,
    current_setting('t.gym'), jsonb_build_object('type', 'none', 'evil', repeat('A', 3000))), '22023'::char(5), null, 'long loads are refused');
select throws_ok(format($$ select public.share_listing(gen_random_uuid(), %L, 'barbell', null, null, %L, 1, null, null, true) $$,
    current_setting('t.gym'), '{"type":"stack","maxKg":1000,"stepKg":1000}'), '22023'::char(5), null, 'a silly step is refused');
select ok(gym_private.valid_loads('{"type":"fixed","kg":[24.040395609999998,20]}'), 'the weights a phone really sends pass');
select ok(gym_private.valid_loads('{"type":"stack","maxKg":113.4}'), 'a stack needs no step');
-- Text anyone will read.
select throws_ok(format($$ select public.share_listing(gen_random_uuid(), %L, 'barbell', %L, null, '{"type":"none"}', 1, null, null, true) $$,
    current_setting('t.gym'), E'A\u202Eb'), '23514'::char(5), null, 'a text-direction override is refused');
select throws_ok($$ select public.find_or_create_gym('zw', E'\u200B', null, 0, 0) $$, '23514'::char(5), null, 'an invisible gym name is refused');
select throws_ok($$ select public.find_or_create_gym(E'p\n1', 'Iron', null, 0, 0) $$, '22023'::char(5), null, 'a place id with a line break is refused');
select is(public.share_listing('bbbbbbbb-0000-0000-0000-000000000009', current_setting('t.gym')::uuid, 'barbell', null, null,
    '{"type":"plates"}', 1, E'by the door\nleft side', null, true) ->> 'status', 'created', 'a note can have lines');
select throws_ok(format($$ select public.share_listing(gen_random_uuid(), %L, 'barbell', null, null, '{"type":"none"}', 51, null, null, true) $$,
    current_setting('t.gym')), '23514'::char(5), null, 'quantity is limited');
select throws_ok(format($$ select public.share_listing(gen_random_uuid(), %L, 'no-such-kind', null, null, '{"type":"none"}', 1, null, null) $$,
    current_setting('t.gym')), '22023'::char(5), null, 'an unknown kind is refused');
select throws_ok(format($$ select public.share_listing(gen_random_uuid(), %L, 'barbell', %L, null, '{"type":"none"}', 1, null, null, true) $$,
    current_setting('t.gym'), repeat('x', 61)), '23514'::char(5), null, 'brand length is limited');
select pg_temp.as_anon();
select throws_ok(format($$ select public.share_listing(gen_random_uuid(), %L, 'barbell', null, null, '{"type":"none"}', 1, null, null) $$,
    current_setting('t.gym')), '42501'::char(5), null, 'anon cannot share');
select pg_temp.as_mcp(1);
select throws_ok(format($$ select public.share_listing(gen_random_uuid(), %L, 'barbell', null, null, '{"type":"none"}', 1, null, null) $$,
    current_setting('t.gym')), '42501'::char(5), null, 'an MCP client cannot share');

-- Criterion 2: another user, and someone with no account, see the shared listing ---------------------------------------
select pg_temp.as_anon();
select is((select count(*) from public.public_gym_equipment where gym_id = current_setting('t.gym')::uuid)::int, 3,
  'anon reads the shared listings');
select is((select count(*) from public.public_gym_equipment where photo_path like '%aaaaaaaa%')::int, 0,
  'photo paths do not carry the uploader''s id');
select is((select bool_or(is_mine) from public.public_gym_equipment), false, 'nothing is mine for anon');
select is((select count(*) from public.public_equipment_items where brand = 'Hammer Strength')::int, 1,
  'a listed item is public');
select is((select gym_count from public.public_equipment_items where brand = 'Hammer Strength')::int, 1,
  'with how many gyms list it');
select throws_ok($$ insert into public.gym_equipment (gym_id, item_id, visibility) select id, id, 'public' from public.gyms $$,
  '42501'::char(5), null, 'anon cannot write listings');
select pg_temp.as_user(2);
select is((select count(*) from public.public_gym_equipment)::int, 3, 'user B reads them');
select is((select bool_or(is_mine) from public.public_gym_equipment), false, 'they are not B''s');
select is((select to_jsonb(v) ? 'added_by' from public.public_gym_equipment v limit 1), false, 'the view hides the author');

-- confirm_listing -----------------------------------------------------------------------------------------------------
select is(public.confirm_listing('bbbbbbbb-0000-0000-0000-000000000001'), 1, 'B confirms');
select is(public.confirm_listing('bbbbbbbb-0000-0000-0000-000000000001'), 1, 'confirming twice counts once');
select is((select confirmed_by_me from public.public_gym_equipment where id = 'bbbbbbbb-0000-0000-0000-000000000001'),
  true, 'the view says B confirmed');
select pg_temp.as_user(1);
select is(public.confirm_listing('bbbbbbbb-0000-0000-0000-000000000001'), 1, 'an author adds nothing to their own');
select pg_temp.as_anon();
select throws_ok($$ select public.confirm_listing('bbbbbbbb-0000-0000-0000-000000000001') $$, '42501'::char(5), null,
  'anon cannot confirm');

-- Private rows --------------------------------------------------------------------------------------------------------
select pg_temp.as_user(2);
insert into public.gyms (id, visibility, name, client_updated_at)
  values ('dddddddd-0000-0000-0000-000000000001', 'private', 'Home', '2026-10-30T10:00:00Z');
select is((select count(*) from public.gyms where id = 'dddddddd-0000-0000-0000-000000000001')::int, 1, 'the owner stores a private gym');
insert into public.gym_equipment (id, gym_id, item_id, visibility, loads, client_updated_at)
  values ('dddddddd-0000-0000-0000-000000000002', 'dddddddd-0000-0000-0000-000000000001',
          (select id from public.equipment_items where kind_id = 'kettlebells' and brand is null),
          'private', '{"type":"fixed","kg":[20,24]}', '2026-10-30T10:00:00Z');
select is((select count(*) from public.gym_equipment where id = 'dddddddd-0000-0000-0000-000000000002')::int, 1, 'and a private listing');
select is((select count(*) from public.public_gyms where name = 'Home')::int, 0, 'a private gym is not in the public view');
select is((select count(*) from public.public_gym_equipment where id = 'dddddddd-0000-0000-0000-000000000002')::int, 0,
  'nor is its listing');
update public.gyms set name = 'Older', client_updated_at = '2026-10-29T10:00:00Z' where id = 'dddddddd-0000-0000-0000-000000000001';
select is((select name from public.gyms where id = 'dddddddd-0000-0000-0000-000000000001'), 'Home', 'an older edit is skipped');
select throws_ok($$ update public.gyms set visibility = 'public' where id = 'dddddddd-0000-0000-0000-000000000001' $$,
  '42501'::char(5), null, 'a private gym can never become public directly');
select pg_temp.as_user(1);
select is((select count(*) from public.gyms where id = 'dddddddd-0000-0000-0000-000000000001')::int, 0, 'another user cannot see it');
select is((select count(*) from public.gym_equipment where id = 'dddddddd-0000-0000-0000-000000000002')::int, 0, 'nor its listing');
select throws_ok($$ insert into public.gym_equipment (gym_id, item_id, visibility)
    values ('dddddddd-0000-0000-0000-000000000001', (select id from public.equipment_items limit 1), 'private') $$,
  '23503'::char(5), 'unknown gym', 'nor add to it');
select throws_ok($$ insert into public.gym_equipment (gym_id, item_id, visibility)
    values ('dddddddd-0000-0000-0000-00000000dead', (select id from public.equipment_items limit 1), 'private') $$,
  '23503'::char(5), 'unknown gym', 'which reads the same as a gym that does not exist');
select throws_ok($$ select public.share_listing('dddddddd-0000-0000-0000-000000000002', null, 'barbell', null, null, '{"type":"none"}', 1, null, null) $$,
  '42501'::char(5), null, 'a private listing id cannot be taken over by sharing');
select pg_temp.as_anon();
select is((select count(*) from public.gyms where visibility = 'private')::int, 0, 'anon sees no private gym');
-- MCP clients read private rows behind the flag and never write them.
select pg_temp.as_mcp(2);
select is((select count(*) from public.gyms where id = 'dddddddd-0000-0000-0000-000000000001')::int, 1, 'MCP reads private gyms');
select throws_ok($$ insert into public.gyms (visibility, name) values ('private', 'x') $$, '42501'::char(5), null,
  'MCP cannot write private gyms');
reset role;
update public.profiles set mcp_read_gyms = false where user_id = 'aaaaaaaa-0000-0000-0000-000000000002';
insert into public.profiles (user_id, mcp_read_gyms) values ('aaaaaaaa-0000-0000-0000-000000000002', false)
  on conflict (user_id) do update set mcp_read_gyms = false;
select pg_temp.as_mcp(2);
select is((select count(*) from public.gyms where id = 'dddddddd-0000-0000-0000-000000000001')::int, 0, 'the flag hides them');

-- Private text stays out of the shared catalogue -------------------------------------------------------------------
select pg_temp.as_user(2);
select ok(not has_function_privilege('authenticated', 'public.ensure_equipment_item(text,text,text)', 'execute'),
  'clients cannot add catalogue items');
insert into public.gym_equipment (id, gym_id, item_id, visibility, private_brand, client_updated_at)
  values ('dddddddd-0000-0000-0000-000000000003', 'dddddddd-0000-0000-0000-000000000001',
          (select id from public.equipment_items where kind_id = 'barbell' and brand is null),
          'private', 'Secret Brand', '2026-10-30T10:00:00Z');
select is((select private_brand from public.gym_equipment where id = 'dddddddd-0000-0000-0000-000000000003'), 'Secret Brand',
  'a private listing keeps its brand itself');
select is((select count(*) from public.equipment_items where brand = 'Secret Brand')::int, 0, 'not in the catalogue');
select throws_ok(format($$ insert into public.gym_equipment (gym_id, item_id, visibility) values ('dddddddd-0000-0000-0000-000000000001', %L, 'private') $$,
    (select id from public.equipment_items where brand = 'Hammer Strength')),
  '23514'::char(5), null, 'a private listing uses a generic item');
select throws_ok($$ update public.gym_equipment set photo_path = 'cccccccc-0000-4000-8000-000000000001.jpg' where id = 'dddddddd-0000-0000-0000-000000000003' $$,
  'P0001'::char(5), 'photo_missing', 'a private listing cannot point at someone else''s photo');
update public.gym_equipment set photo_path = 'cccccccc-0000-4000-8000-000000000004.jpg', client_updated_at = '2026-10-30T11:00:00Z'
  where id = 'dddddddd-0000-0000-0000-000000000003';
select is((select photo_path from public.gym_equipment where id = 'dddddddd-0000-0000-0000-000000000003'),
  'cccccccc-0000-4000-8000-000000000004.jpg', 'its own private photo is fine');

-- Limits on private rows -----------------------------------------------------------------------------------------------
select pg_temp.as_user(3);
insert into public.gyms (visibility, name) select 'private', 'Gym ' || n from generate_series(1, 100) n;
select throws_ok($$ insert into public.gyms (visibility, name) values ('private', 'One more') $$, 'P0001'::char(5), 'too_many_gyms',
  'private gyms are limited');
select lives_ok(format($$ insert into public.gyms (id, visibility, name, client_updated_at) values (%L, 'private', 'Renamed', now())
    on conflict (id) do update set name = excluded.name $$, (select id from public.gyms where name = 'Gym 1')),
  'an upsert of a gym you have still works at the limit');
select lives_ok($$ delete from public.gyms where name like 'Gym %' or name = 'Renamed' $$, 'cleanup');

-- Tombstones don't count, and clearing one is a new row for the limit
insert into public.gyms (visibility, name, deleted_at) select 'private', 'Tomb ' || n, now() from generate_series(1, 150) n;
select is((select count(*) from public.gyms where name like 'Tomb %')::int, 150, 'deleted gyms past the limit are stored');
select throws_ok($$ update public.gyms set deleted_at = null where name like 'Tomb %' $$, 'P0001'::char(5), 'too_many_gyms',
  'clearing the tombstones cannot go past the limit');
select is((select count(*) from public.gyms where name like 'Tomb %' and deleted_at is null)::int, 0, 'and none of them came back');
select lives_ok($$ update public.gyms set deleted_at = null where name in ('Tomb 1', 'Tomb 2', 'Tomb 3') $$,
  'clearing a tombstone within the limit works (sync needs it)');
select lives_ok($$ update public.gyms set deleted_at = now() where name = 'Tomb 1' $$, 'deleting frees a slot');
insert into public.gyms (visibility, name) select 'private', 'Live ' || n from generate_series(1, 98) n;
select throws_ok($$ insert into public.gyms (visibility, name) values ('private', 'Over') $$, 'P0001'::char(5), 'too_many_gyms',
  'at the limit with deleted ones around, a new gym is refused');
select lives_ok($$ delete from public.gyms where name like 'Tomb %' or name like 'Live %' $$, 'cleanup');

-- The same for private listings
insert into public.gyms (id, visibility, name) values ('dddddddd-0000-0000-0000-0000000000c1', 'private', 'Cap gym');
insert into public.gym_equipment (gym_id, item_id, visibility, deleted_at, private_brand)
  select 'dddddddd-0000-0000-0000-0000000000c1', (select id from public.equipment_items where kind_id = 'barbell' and brand is null),
         'private', now(), 'Tomb ' || n from generate_series(1, 1100) n;
select throws_ok($$ update public.gym_equipment set deleted_at = null where private_brand like 'Tomb %' $$,
  'P0001'::char(5), 'too_many_listings', 'clearing the tombstones cannot go past the listing limit');
select is((select count(*) from public.gym_equipment where private_brand like 'Tomb %' and deleted_at is null)::int,
  0, 'and none of them came back');
select lives_ok($$ update public.gym_equipment set deleted_at = null where private_brand in ('Tomb 1', 'Tomb 2') $$,
  'clearing a listing within the limit works');
select lives_ok($$ delete from public.gym_equipment where private_brand like 'Tomb %' $$, 'cleanup listings');
select lives_ok($$ delete from public.gyms where name = 'Cap gym' $$, 'cleanup gym');

-- Workout links --------------------------------------------------------------------------------------------------------
select pg_temp.as_user(1);
select set_config('t.public_link', (select public.upsert_workout(jsonb_build_object(
  'id', 'eeeeeeee-0000-0000-0000-000000000001', 'started_at', now(), 'name', 'W', 'client_updated_at', now(),
  'gym_id', current_setting('t.gym'),
  'entries', jsonb_build_array(jsonb_build_object('id', 'eeeeeeee-0000-0000-0000-000000000011', 'exercise_id', '0025', 'position', 0,
    'gym_equipment_id', 'bbbbbbbb-0000-0000-0000-000000000001')))))::text, true);
select is((select gym_id from public.workouts where id = 'eeeeeeee-0000-0000-0000-000000000001'), current_setting('t.gym')::uuid,
  'a workout keeps a public gym');
select is((select gym_equipment_id from public.workout_entries where id = 'eeeeeeee-0000-0000-0000-000000000011'),
  'bbbbbbbb-0000-0000-0000-000000000001'::uuid, 'and an entry keeps a public listing');
select lives_ok($$ select public.upsert_workout(jsonb_build_object(
  'id', 'eeeeeeee-0000-0000-0000-000000000002', 'started_at', now(), 'name', 'W', 'client_updated_at', now(),
  'gym_id', 'dddddddd-0000-0000-0000-000000000001',
  'entries', jsonb_build_array(jsonb_build_object('id', 'eeeeeeee-0000-0000-0000-000000000012', 'exercise_id', '0025', 'position', 0,
    'gym_equipment_id', 'dddddddd-0000-0000-0000-000000000002')))) $$, 'someone else''s private ids do not block a workout');
select is((select gym_id from public.workouts where id = 'eeeeeeee-0000-0000-0000-000000000002'), null::uuid, 'the gym link is dropped');
select is((select gym_equipment_id from public.workout_entries where id = 'eeeeeeee-0000-0000-0000-000000000012'), null::uuid,
  'and so is the listing link');
select lives_ok($$ select public.upsert_workout(jsonb_build_object(
  'id', 'eeeeeeee-0000-0000-0000-000000000003', 'started_at', now(), 'name', 'W', 'client_updated_at', now(),
  'gym_id', 'dddddddd-0000-0000-0000-00000000dead')) $$, 'a gym that does not exist reads the same');
select is((select gym_id from public.workouts where id = 'eeeeeeee-0000-0000-0000-000000000003'), null::uuid, 'and is dropped');
select lives_ok($$ select public.upsert_workout(jsonb_build_object(
  'id', 'eeeeeeee-0000-0000-0000-000000000004', 'started_at', now(), 'name', 'W', 'client_updated_at', now())) $$,
  'a workout with no gym works as before');

-- Storage ---------------------------------------------------------------------------------------------------------------
select pg_temp.as_user(1);
select lives_ok($$ insert into storage.objects (bucket_id, name, owner_id) values ('gym-photos', 'cccccccc-0000-4000-8000-000000000010.jpg', 'aaaaaaaa-0000-0000-0000-000000000001') $$,
  'a user uploads under their own name');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id) values ('gym-photos', 'cccccccc-0000-4000-8000-000000000011.jpg', 'aaaaaaaa-0000-0000-0000-000000000002') $$,
  '42501'::char(5), null, 'not as someone else');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id) values ('gym-photos', 'aaaaaaaa-0000-0000-0000-000000000001/cccccccc-0000-4000-8000-000000000012.jpg', 'aaaaaaaa-0000-0000-0000-000000000001') $$,
  '42501'::char(5), null, 'not in a folder');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id) values ('gym-photos', '------------------------------------.jpg', 'aaaaaaaa-0000-0000-0000-000000000001') $$,
  '42501'::char(5), null, 'names must be real uuids');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id) values ('exercise-photos', 'cccccccc-0000-4000-8000-000000000013.jpg', 'aaaaaaaa-0000-0000-0000-000000000001') $$,
  '42501'::char(5), null, 'not in the exercise bucket');
reset role;
set local storage.allow_delete_query = 'true';
delete from storage.objects where name = 'cccccccc-0000-4000-8000-000000000001.jpg';
select pg_temp.as_user(1);
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id) values ('gym-photos', 'cccccccc-0000-4000-8000-000000000001.jpg', 'aaaaaaaa-0000-0000-0000-000000000001') $$,
  '42501'::char(5), null, 'a listing''s photo cannot be swapped by uploading the name again');
reset role;
insert into storage.objects (bucket_id, name, owner_id, created_at, metadata)
  select 'gym-photos', gen_random_uuid()::text || '.jpg', 'aaaaaaaa-0000-0000-0000-000000000003', now(), '{"mimetype":"image/jpeg"}'
  from generate_series(1, 60);
select pg_temp.as_user(3);
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id) values ('gym-photos', 'cccccccc-0000-4000-8000-000000000014.jpg', 'aaaaaaaa-0000-0000-0000-000000000003') $$,
  '42501'::char(5), null, 'uploads are limited per day');
select pg_temp.as_user(1);
select is((select count(*) from storage.objects where bucket_id = 'gym-photos-private')::int, 0, 'another user''s private photos are not readable');
select pg_temp.as_anon();
select is((select count(*) from storage.objects where bucket_id in ('gym-photos', 'gym-photos-private'))::int, 0, 'anon cannot list objects');

-- With the flag off, Claude learns nothing about what's the user's ------------------------------------------------------
reset role;
insert into public.equipment_confirmations (listing_id, user_id) values ('bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001');
insert into public.profiles (user_id, mcp_read_gyms) values ('aaaaaaaa-0000-0000-0000-000000000001', false)
  on conflict (user_id) do update set mcp_read_gyms = false;
insert into public.app_admins (user_id) values ('aaaaaaaa-0000-0000-0000-000000000001');
select pg_temp.as_mcp(1);
select is((select bool_or(is_mine) from public.public_gyms), false, 'public_gyms does not say which are mine');
select is((select bool_or(is_mine) from public.public_gym_equipment), false, 'nor does the listing view');
select is((select bool_or(confirmed_by_me) from public.public_gym_equipment), false, 'nor which I confirmed');
select is((select bool_or(is_mine) from public.public_equipment_items), false, 'nor which items I typed');
select is((select count(*) from storage.objects where bucket_id like 'gym-photos%')::int, 0, 'Claude lists no photos');
select is((select public.is_app_admin()), false, 'Claude is never an admin');
reset role;
delete from public.app_admins where user_id = 'aaaaaaaa-0000-0000-0000-000000000001';
delete from public.equipment_confirmations where listing_id = 'bbbbbbbb-0000-0000-0000-000000000002';
update public.profiles set mcp_read_gyms = true where user_id = 'aaaaaaaa-0000-0000-0000-000000000001';

-- Flagged and removed rows ----------------------------------------------------------------------------------------------
reset role;
update public.gym_equipment set status = 'flagged' where id = 'bbbbbbbb-0000-0000-0000-000000000002';
select pg_temp.as_anon();
select is((select count(*) from public.public_gym_equipment where id = 'bbbbbbbb-0000-0000-0000-000000000002')::int, 0,
  'anon cannot see a flagged listing');
select pg_temp.as_user(2);
select is((select count(*) from public.public_gym_equipment where id = 'bbbbbbbb-0000-0000-0000-000000000002')::int, 0,
  'nor another user');
select pg_temp.as_user(1);
select is((select count(*) from public.public_gym_equipment where id = 'bbbbbbbb-0000-0000-0000-000000000002')::int, 1,
  'its author can');

-- A removed gym: gone from every read, and its place is free again --------------------------------------------------------
reset role;
update public.gyms set status = 'removed' where id = current_setting('t.gym')::uuid;
select pg_temp.as_anon();
select is((select count(*) from public.gym_equipment where gym_id = current_setting('t.gym')::uuid)::int, 0,
  'anon cannot read its listings, even from the table');
select pg_temp.as_user(2);
select is((select count(*) from public.gym_equipment where gym_id = current_setting('t.gym')::uuid and visibility = 'public')::int, 0,
  'nor can a user');
select throws_ok($$ select public.confirm_listing('bbbbbbbb-0000-0000-0000-000000000001') $$, 'P0001'::char(5), 'unknown listing',
  'its listings cannot be confirmed');
select is((select count(*) from public.public_equipment_items where brand = 'Hammer Strength')::int, 0,
  'an item only that gym listed leaves the catalogue');
select isnt(public.find_or_create_gym('p1', 'Real name', null, 1, 2), current_setting('t.gym')::uuid,
  'the place can get a new gym');
reset role;
delete from public.gyms where maps_place_id = 'p1' and id <> current_setting('t.gym')::uuid;
update public.gyms set status = 'active' where id = current_setting('t.gym')::uuid;

-- Blocks hide an author's listings -------------------------------------------------------------------------------------
reset role;
insert into public.user_blocks (blocker_id, blocked_id)
  values ('aaaaaaaa-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001');
select pg_temp.as_user(3);
select is((select count(*) from public.public_gym_equipment)::int, 0, 'a blocked author''s listings are hidden');
select throws_ok($$ select public.is_blocked_author('aaaaaaaa-0000-0000-0000-000000000001') $$, '42883'::char(5), null,
  'and nobody can ask whether a given id is blocked');
select throws_ok($$ select public.confirm_listing('bbbbbbbb-0000-0000-0000-000000000001') $$, 'P0001'::char(5), null,
  'and cannot be confirmed');
select throws_ok($$ select * from public.user_blocks $$, '42501'::char(5), null, 'blocks are not readable');

-- An item's photo comes from its best shared listing ----------------------------------------------------------------
reset role;
delete from public.user_blocks where blocker_id = 'aaaaaaaa-0000-0000-0000-000000000003';
insert into public.equipment_items (id, kind_id, brand, model)
  values ('eeeeeeee-0000-4000-8000-000000000001', 'leg-curl', 'PhotoBrand', 'One');
insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'cccccccc-0000-4000-8000-0000000000a1.jpg', 'aaaaaaaa-0000-0000-0000-000000000001', '{"mimetype":"image/jpeg"}'),
  ('gym-photos', 'cccccccc-0000-4000-8000-0000000000a2.jpg', 'aaaaaaaa-0000-0000-0000-000000000002', '{"mimetype":"image/jpeg"}');
insert into public.gym_equipment (id, gym_id, item_id, visibility, photo_path, loads, added_by, created_at, confirm_count) values
  ('bbbbbbbb-0000-4000-8000-0000000000a1', current_setting('t.gym')::uuid, 'eeeeeeee-0000-4000-8000-000000000001',
   'public', 'cccccccc-0000-4000-8000-0000000000a1.jpg', '{"type":"none"}', 'aaaaaaaa-0000-0000-0000-000000000001', now() - interval '2 days', 0),
  ('bbbbbbbb-0000-4000-8000-0000000000a2', current_setting('t.gym')::uuid, 'eeeeeeee-0000-4000-8000-000000000001',
   'public', 'cccccccc-0000-4000-8000-0000000000a2.jpg', '{"type":"none"}', 'aaaaaaaa-0000-0000-0000-000000000002', now() - interval '1 day', 0),
  ('bbbbbbbb-0000-4000-8000-0000000000a3', current_setting('t.gym')::uuid, 'eeeeeeee-0000-4000-8000-000000000001',
   'public', null, '{"type":"none"}', 'aaaaaaaa-0000-0000-0000-000000000002', now(), 0);

select pg_temp.as_anon();
select is((select photo_path from public.public_equipment_items where id = 'eeeeeeee-0000-4000-8000-000000000001'),
  'cccccccc-0000-4000-8000-0000000000a1.jpg', 'an item shows the oldest shared photo when confirmations tie');
select is((select photo_listing_id from public.public_equipment_items where id = 'eeeeeeee-0000-4000-8000-000000000001'),
  'bbbbbbbb-0000-4000-8000-0000000000a1'::uuid, 'and says which listing it came from, so it can be reported');

reset role;
update public.gym_equipment set confirm_count = 3 where id = 'bbbbbbbb-0000-4000-8000-0000000000a2';
select pg_temp.as_anon();
select is((select photo_path from public.public_equipment_items where id = 'eeeeeeee-0000-4000-8000-000000000001'),
  'cccccccc-0000-4000-8000-0000000000a2.jpg', 'the most confirmed listing wins');

reset role;
insert into public.user_blocks (blocker_id, blocked_id)
  values ('aaaaaaaa-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000002');
select pg_temp.as_user(3);
select is((select photo_path from public.public_equipment_items where id = 'eeeeeeee-0000-4000-8000-000000000001'),
  'cccccccc-0000-4000-8000-0000000000a1.jpg', 'a blocked author''s photo is skipped for the person who blocked them');
reset role;
delete from public.user_blocks where blocker_id = 'aaaaaaaa-0000-0000-0000-000000000003';

update public.gym_equipment set status = 'flagged' where id = 'bbbbbbbb-0000-4000-8000-0000000000a2';
select pg_temp.as_anon();
select is((select photo_path from public.public_equipment_items where id = 'eeeeeeee-0000-4000-8000-000000000001'),
  'cccccccc-0000-4000-8000-0000000000a1.jpg', 'a flagged listing''s photo stops showing at once');

reset role;
update public.gym_equipment set status = 'removed' where id = 'bbbbbbbb-0000-4000-8000-0000000000a1';
select pg_temp.as_anon();
select is((select photo_path from public.public_equipment_items where id = 'eeeeeeee-0000-4000-8000-000000000001'),
  null, 'with no shared photo left the item has none');
select is((select photo_listing_id from public.public_equipment_items where id = 'eeeeeeee-0000-4000-8000-000000000001'),
  null::uuid, 'and no listing to report');

reset role;
insert into public.gym_equipment (id, gym_id, item_id, visibility, owner_id, photo_path, loads, added_by) values
  ('bbbbbbbb-0000-4000-8000-0000000000a4', 'dddddddd-0000-0000-0000-000000000001',
   (select id from public.equipment_items where kind_id = 'leg-press' and brand is null and model is null),
   'private', 'aaaaaaaa-0000-0000-0000-000000000002', 'cccccccc-0000-4000-8000-0000000000a5.jpg', '{"type":"none"}',
   'aaaaaaaa-0000-0000-0000-000000000002');
select pg_temp.as_user(2);
select is((select photo_path from public.public_equipment_items
           where kind_id = 'leg-press' and brand is null and model is null), null,
  'a private listing''s photo never becomes the catalogue photo, even for its owner');
reset role;
delete from public.gym_equipment where id in ('bbbbbbbb-0000-4000-8000-0000000000a1', 'bbbbbbbb-0000-4000-8000-0000000000a2',
  'bbbbbbbb-0000-4000-8000-0000000000a3', 'bbbbbbbb-0000-4000-8000-0000000000a4');
delete from public.equipment_items where id = 'eeeeeeee-0000-4000-8000-000000000001';
insert into public.user_blocks (blocker_id, blocked_id)
  values ('aaaaaaaa-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001');

-- Daily limits ----------------------------------------------------------------------------------------------------------
select is(
  (select count(*) from generate_series(1, 10) n, lateral (select public.find_or_create_gym('limit-' || n, 'Gym', null, 0, 0)) g)::int,
  10, 'gyms up to the limit');
select throws_ok($$ select public.find_or_create_gym('limit-11', 'Gym', null, 0, 0) $$, 'P0001'::char(5), 'daily_limit',
  'the eleventh gym today is refused');

-- Account deletion keeps shared data without the author ----------------------------------------------------------------
reset role;
delete from auth.users where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select is((select added_by from public.gym_equipment where id = 'bbbbbbbb-0000-0000-0000-000000000001'), null::uuid,
  'a shared listing stays, without its author');
delete from auth.users where id = 'aaaaaaaa-0000-0000-0000-000000000002';
select is((select count(*) from public.gyms where id = 'dddddddd-0000-0000-0000-000000000001')::int, 0, 'a private gym goes with its owner');

select * from finish();
rollback;
