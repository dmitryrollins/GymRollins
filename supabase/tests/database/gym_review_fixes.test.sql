-- Fixes from the review of plan 22: daily limits on blocking, a removed listing keeping its photo name until the object is
-- gone, a queue that shows every reported target, and detaching photos before an account is deleted.
begin;
create extension if not exists pgtap with schema extensions;
select plan(50);

create function pg_temp.uid(n int) returns uuid language sql immutable as $$
  select ('b0b0b0b0-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
insert into auth.users (id, email, aud, role)
select pg_temp.uid(n), 'fix-' || n || '@test.local', 'authenticated', 'authenticated' from generate_series(1, 40) n;
insert into public.app_admins (user_id) values (pg_temp.uid(5));

create function pg_temp.as_user(n int) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', pg_temp.uid(n)), true);
end $$;
create function pg_temp.as_mcp(n int) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated","client_id":"claude"}', pg_temp.uid(n)), true);
end $$;
create function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
end $$;
grant execute on function pg_temp.uid(int), pg_temp.as_user(int), pg_temp.as_mcp(int), pg_temp.as_anon() to anon, authenticated;

-- A public gym with one listing per author 11..32 ------------------------------------------------------------------------
insert into public.gyms (id, visibility, name, address, maps_place_id)
  values ('b0b0b0b0-0000-4000-8000-0000000000a0', 'public', 'Review Gym', '1 Main St', 'review-1');
insert into public.gym_equipment (id, gym_id, item_id, visibility, added_by)
  select pg_temp.uid(1000 + n), 'b0b0b0b0-0000-4000-8000-0000000000a0',
         (select id from public.equipment_items where kind_id = 'flat-bench' and brand is null), 'public', pg_temp.uid(n)
  from generate_series(11, 32) n;

-- Blocking is limited ------------------------------------------------------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.moderation_photo_deleted(text)', 'execute'), 'anon cannot confirm a photo is gone');
select ok(not has_function_privilege('anon', 'public.detach_my_gym_photos()', 'execute'), 'anon cannot detach photos');
select pg_temp.as_user(6);
select lives_ok(format($$ select public.block_author('listing', %L) $$, pg_temp.uid(1000 + 11)), 'a first block works');
select is((select count(*) from (select public.block_author('listing', pg_temp.uid(1000 + n)) from generate_series(12, 30) n) b)::int,
  19, 'up to 20 blocks a day');
select throws_ok(format($$ select public.block_author('listing', %L) $$, pg_temp.uid(1000 + 31)),
  'P0001'::char(5), 'daily_limit', 'the 21st is refused');
select lives_ok(format($$ select public.block_author('listing', %L) $$, pg_temp.uid(1000 + 11)),
  'blocking someone already blocked is a no-op at the limit, so a retry succeeds');
reset role;
select is((select count(*) from public.user_blocks where blocker_id = pg_temp.uid(6))::int, 20, 'and it added nothing');
update public.user_blocks set created_at = now() - interval '2 days' where blocker_id = pg_temp.uid(6) and blocked_id = pg_temp.uid(11);
select pg_temp.as_user(6);
select lives_ok(format($$ select public.block_author('listing', %L) $$, pg_temp.uid(1000 + 31)), 'a block older than a day frees a slot');

-- Unblocking is limited --------------------------------------------------------------------------------------------------------
select pg_temp.as_user(7);
select public.block_author('listing', pg_temp.uid(1000 + 11));
select is(public.unblock_all(), 1, 'the first unblock returns the count');
select is(public.unblock_all(), 0, 'and an empty one returns 0');
select public.block_author('listing', pg_temp.uid(1000 + 11));
select is(public.unblock_all(), 1, 'a second');
select public.block_author('listing', pg_temp.uid(1000 + 11));
select is(public.unblock_all(), 1, 'a third');
select public.block_author('listing', pg_temp.uid(1000 + 11));
select throws_ok($$ select public.unblock_all() $$, 'P0001'::char(5), 'daily_limit', 'a fourth in a day is refused');
select is((select count(*) from public.public_gym_equipment where id = pg_temp.uid(1000 + 11))::int, 0, 'and the block stands');
reset role;
select is((select count(*) from gym_private.unblocks where user_id = pg_temp.uid(7))::int, 3, 'only unblocks that cleared something are logged');
update gym_private.unblocks set created_at = now() - interval '2 days' where user_id = pg_temp.uid(7);
select pg_temp.as_user(7);
select is(public.unblock_all(), 1, 'they count for a day');
reset role;
delete from auth.users where id = pg_temp.uid(7);
select is((select count(*) from gym_private.unblocks where user_id = pg_temp.uid(7))::int, 0, 'and go with the account');

-- A removed listing keeps its photo name until the object is gone ----------------------------------------------------------------
insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'b0b0b0b0-0000-4000-8000-000000000001.jpg', pg_temp.uid(1)::text, '{"mimetype":"image/jpeg"}'),
  ('gym-photos', 'b0b0b0b0-0000-4000-8000-000000000002.jpg', pg_temp.uid(1)::text, '{"mimetype":"image/jpeg"}');
insert into public.gym_equipment (id, gym_id, item_id, visibility, added_by, photo_path)
  values ('b0b0b0b0-0000-4000-8000-0000000000b1', 'b0b0b0b0-0000-4000-8000-0000000000a0',
          (select id from public.equipment_items where kind_id = 'barbell' and brand is null), 'public', pg_temp.uid(1),
          'b0b0b0b0-0000-4000-8000-000000000001.jpg'),
         ('b0b0b0b0-0000-4000-8000-0000000000b2', 'b0b0b0b0-0000-4000-8000-0000000000a0',
          (select id from public.equipment_items where kind_id = 'dumbbells' and brand is null), 'public', pg_temp.uid(1),
          'b0b0b0b0-0000-4000-8000-000000000002.jpg');
select pg_temp.as_user(5);
select is(public.moderate_content('listing', 'b0b0b0b0-0000-4000-8000-0000000000b1', 'remove')->>'photo_path',
  'b0b0b0b0-0000-4000-8000-000000000001.jpg', 'remove returns the photo to delete');
reset role;
select is((select photo_path from public.gym_equipment where id = 'b0b0b0b0-0000-4000-8000-0000000000b1'),
  'b0b0b0b0-0000-4000-8000-000000000001.jpg', 'and the listing keeps the name');
select pg_temp.as_user(5);
select is(public.moderate_content('listing', 'b0b0b0b0-0000-4000-8000-0000000000b1', 'remove')->>'photo_path',
  'b0b0b0b0-0000-4000-8000-000000000001.jpg', 'removing again returns it again, for a retry');
select is((select status from public.moderation_queue() where target_id = 'b0b0b0b0-0000-4000-8000-0000000000b1'), 'removed',
  'the queue lists a removed listing whose photo is still named');
select pg_temp.as_user(1);
select throws_ok($$ select public.share_listing(gen_random_uuid(), 'b0b0b0b0-0000-4000-8000-0000000000a0', 'lat-pulldown', null, null,
  '{"type":"none"}', 1, null, 'b0b0b0b0-0000-4000-8000-000000000001.jpg', true) $$, 'P0001'::char(5), 'photo_in_use',
  'the author cannot reuse the name in a new listing');
reset role;
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'b0b0b0b0-0000-4000-8000-000000000001.jpg', pg_temp.uid(1)::text, '{"mimetype":"image/jpeg"}') $$,
  '42501'::char(5), 'photo_name_in_use', 'nor upload it again');
select pg_temp.as_user(1);
select throws_ok($$ select public.moderation_photo_deleted('b0b0b0b0-0000-4000-8000-000000000001.jpg') $$,
  '42501'::char(5), null, 'a user cannot confirm a deletion');
select pg_temp.as_mcp(5);
select throws_ok($$ select public.moderation_photo_deleted('b0b0b0b0-0000-4000-8000-000000000001.jpg') $$,
  '42501'::char(5), null, 'nor Claude on an admin''s account');
select pg_temp.as_user(5);
select lives_ok($$ select public.moderation_photo_deleted('b0b0b0b0-0000-4000-8000-0000000000ff.jpg') $$, 'an unknown name is a no-op');
select lives_ok($$ select public.moderation_photo_deleted('b0b0b0b0-0000-4000-8000-000000000002.jpg') $$,
  'and so is the name of a listing that is not removed');
reset role;
select is((select photo_path from public.gym_equipment where id = 'b0b0b0b0-0000-4000-8000-0000000000b2'),
  'b0b0b0b0-0000-4000-8000-000000000002.jpg', 'which keeps its photo');
select pg_temp.as_user(1);
select is((select count(*) from public.my_gym_photos())::int, 2, 'the author still lists both objects');
select throws_ok($$ select public.delete_my_account() $$, 'P0001'::char(5), 'photos_remain', 'and cannot leave with them');
select pg_temp.as_user(5);
select public.moderation_photo_deleted('b0b0b0b0-0000-4000-8000-000000000001.jpg');
reset role;
select is((select photo_path from public.gym_equipment where id = 'b0b0b0b0-0000-4000-8000-0000000000b1'), null,
  'confirming the deletion clears the name');
select pg_temp.as_user(5);
select is((select count(*) from public.moderation_queue() where target_id = 'b0b0b0b0-0000-4000-8000-0000000000b1')::int, 0,
  'and the listing leaves the queue');
select is(public.moderate_content('listing', 'b0b0b0b0-0000-4000-8000-0000000000b1', 'restore')->>'status', 'active',
  'a removed listing can still be restored');

-- The queue shows every reported target -------------------------------------------------------------------------------------------
reset role;
insert into public.gym_equipment (id, gym_id, item_id, visibility, added_by, notes) values
  ('b0b0b0b0-0000-4000-8000-0000000000c1', 'b0b0b0b0-0000-4000-8000-0000000000a0',
   (select id from public.equipment_items where kind_id = 'cable-station' and brand is null), 'public', pg_temp.uid(2), 'text me 555');
update public.gym_equipment set status = 'flagged' where id = 'b0b0b0b0-0000-4000-8000-0000000000b2';
delete from public.reports;
insert into public.reports (target_type, target_id, reporter_id, reason)
select 'listing', 'b0b0b0b0-0000-4000-8000-0000000000b2', pg_temp.uid(n), 'spam' from generate_series(1, 3) n;
insert into public.reports (target_type, target_id, reporter_id, reason)
select 'gym', 'b0b0b0b0-0000-4000-8000-0000000000a0', pg_temp.uid(n), 'wrong-info' from generate_series(1, 2) n;
insert into public.reports (target_type, target_id, reporter_id, reason)
values ('listing', 'b0b0b0b0-0000-4000-8000-0000000000c1', pg_temp.uid(1), 'person-in-photo');
select pg_temp.as_user(5);
select is((select array_agg(target_id order by ord) from (select target_id, row_number() over () as ord from public.moderation_queue()) q),
  array['b0b0b0b0-0000-4000-8000-0000000000b2', 'b0b0b0b0-0000-4000-8000-0000000000a0',
        'b0b0b0b0-0000-4000-8000-0000000000c1']::uuid[], 'flagged first, then by the most reports, a single report included');
select is((select status from public.moderation_queue() where target_id = 'b0b0b0b0-0000-4000-8000-0000000000c1'), 'active',
  'each with its status');
select is((select listing_notes from public.moderation_queue() where target_id = 'b0b0b0b0-0000-4000-8000-0000000000c1'), 'text me 555',
  'a listing with its notes');
select is((select address from public.moderation_queue() where target_id = 'b0b0b0b0-0000-4000-8000-0000000000a0'), '1 Main St',
  'a gym with its address');
select is((select title from public.moderation_queue() where target_id = 'b0b0b0b0-0000-4000-8000-0000000000a0'), 'Review Gym',
  'and the name as before');
select is(public.moderate_content('listing', 'b0b0b0b0-0000-4000-8000-0000000000c1', 'restore')->>'status', 'active',
  'restore works on a target that is still active');
select is((select count(*) from public.moderation_queue() where target_id = 'b0b0b0b0-0000-4000-8000-0000000000c1')::int, 0,
  'and resolves its reports');
select is(public.moderate_content('gym', 'b0b0b0b0-0000-4000-8000-0000000000a0', 'remove')->>'status', 'removed',
  'remove works on one that is still active');
select pg_temp.as_user(1);
select throws_ok($$ select * from public.moderation_queue() $$, '42501'::char(5), null, 'a user still cannot read the queue');
reset role;
update public.gyms set status = 'active' where id = 'b0b0b0b0-0000-4000-8000-0000000000a0';

-- Detaching photos before the account goes -------------------------------------------------------------------------------------------
select set_config('request.jwt.claims', '', true);
insert into public.gyms (id, visibility, name, owner_id)
  values ('b0b0b0b0-0000-4000-8000-0000000000d0', 'private', 'Home', pg_temp.uid(3));
insert into public.gym_equipment (id, gym_id, item_id, visibility, owner_id, added_by, photo_path) values
  ('b0b0b0b0-0000-4000-8000-0000000000d1', 'b0b0b0b0-0000-4000-8000-0000000000d0',
   (select id from public.equipment_items where kind_id = 'flat-bench' and brand is null), 'private', pg_temp.uid(3), pg_temp.uid(3),
   'b0b0b0b0-0000-4000-8000-000000000010.jpg'),
  ('b0b0b0b0-0000-4000-8000-0000000000d2', 'b0b0b0b0-0000-4000-8000-0000000000a0',
   (select id from public.equipment_items where kind_id = 'barbell' and brand is null), 'public', null, pg_temp.uid(3),
   'b0b0b0b0-0000-4000-8000-000000000011.jpg'),
  ('b0b0b0b0-0000-4000-8000-0000000000d3', 'b0b0b0b0-0000-4000-8000-0000000000a0',
   (select id from public.equipment_items where kind_id = 'dumbbells' and brand is null), 'public', null, pg_temp.uid(4),
   'b0b0b0b0-0000-4000-8000-000000000012.jpg');
insert into public.gyms (id, visibility, name, owner_id)
  values ('b0b0b0b0-0000-4000-8000-0000000000d4', 'private', 'Their home', pg_temp.uid(4));
insert into public.gym_equipment (id, gym_id, item_id, visibility, owner_id, added_by, photo_path)
  values ('b0b0b0b0-0000-4000-8000-0000000000d5', 'b0b0b0b0-0000-4000-8000-0000000000d4',
   (select id from public.equipment_items where kind_id = 'flat-bench' and brand is null), 'private', pg_temp.uid(4), pg_temp.uid(4),
   'b0b0b0b0-0000-4000-8000-000000000013.jpg');
-- One transaction has one now(), so push the stamp into the past to see it move.
set local session_replication_role = replica;
update public.gym_equipment set updated_at = now() - interval '1 day' where id = 'b0b0b0b0-0000-4000-8000-0000000000d1';
set local session_replication_role = origin;
select set_config('t.before', (select updated_at::text from public.gym_equipment where id = 'b0b0b0b0-0000-4000-8000-0000000000d1'), true);
select pg_temp.as_mcp(3);
select throws_ok($$ select public.detach_my_gym_photos() $$, '42501'::char(5), null, 'Claude cannot detach photos');
select pg_temp.as_user(3);
select lives_ok($$ select public.detach_my_gym_photos() $$, 'a user detaches their photos');
select is((select photo_path from public.gym_equipment where id = 'b0b0b0b0-0000-4000-8000-0000000000d1'), null,
  'from their private listing');
select is((select photo_path from public.public_gym_equipment where id = 'b0b0b0b0-0000-4000-8000-0000000000d2'), null,
  'and from the public listing they added, which stays listed');
select is((select count(*) from public.public_gym_equipment where id = 'b0b0b0b0-0000-4000-8000-0000000000d2')::int, 1, 'listed');
select ok((select updated_at from public.gym_equipment where id = 'b0b0b0b0-0000-4000-8000-0000000000d1') > current_setting('t.before')::timestamptz,
  'the row''s updated_at moves, so other phones pull it');
select is((select photo_path from public.public_gym_equipment where id = 'b0b0b0b0-0000-4000-8000-0000000000d3'),
  'b0b0b0b0-0000-4000-8000-000000000012.jpg', 'someone else''s public listing keeps its photo');
reset role;
select is((select photo_path from public.gym_equipment where id = 'b0b0b0b0-0000-4000-8000-0000000000d5'),
  'b0b0b0b0-0000-4000-8000-000000000013.jpg', 'and someone else''s private one');

select * from finish();
rollback;
