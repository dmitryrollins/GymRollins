-- Report, block, moderate and account deletion for shared gym data (spec §5, §9).
begin;
create extension if not exists pgtap with schema extensions;
select plan(68);

insert into auth.users (id, email, aud, role)
select ('cccccccc-0000-0000-0000-00000000000' || n)::uuid, 'mod-' || n || '@test.local', 'authenticated', 'authenticated'
from generate_series(1, 8) n;
insert into public.app_admins (user_id) values ('cccccccc-0000-0000-0000-000000000005');
insert into storage.objects (bucket_id, name, owner_id, metadata)
  values ('gym-photos', 'dddddddd-0000-4000-8000-000000000001.jpg', 'cccccccc-0000-0000-0000-000000000001', '{"mimetype":"image/jpeg"}');

create function pg_temp.as_user(n int) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    format('{"sub":"cccccccc-0000-0000-0000-00000000000%s","role":"authenticated"}', n), true);
end $$;
create function pg_temp.as_mcp(n int) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    format('{"sub":"cccccccc-0000-0000-0000-00000000000%s","role":"authenticated","client_id":"claude"}', n), true);
end $$;
create function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
end $$;
grant execute on function pg_temp.as_user(int), pg_temp.as_mcp(int), pg_temp.as_anon() to anon, authenticated;

-- User 1 shares a gym with two listings: a branded one and a generic one.
select pg_temp.as_user(1);
select set_config('t.gym', public.find_or_create_gym('mod-p1', 'Mod Gym', null, 1, 2)::text, true);
select is(public.share_listing('dddddddd-0000-0000-0000-000000000001', current_setting('t.gym')::uuid, 'lat-pulldown',
    'Acme', 'X1', '{"type":"none"}', 1, 'call me on 555', 'dddddddd-0000-4000-8000-000000000001.jpg')->>'status',
  'created', 'setup: branded listing');
select is(public.share_listing('dddddddd-0000-0000-0000-000000000002', current_setting('t.gym')::uuid, 'dumbbells',
    null, null, '{"type":"none"}', 1, null, null)->>'status', 'created', 'setup: generic listing');
reset role;
select set_config('t.item', (select item_id::text from public.gym_equipment where id = 'dddddddd-0000-0000-0000-000000000001'), true);
select set_config('t.generic', (select item_id::text from public.gym_equipment where id = 'dddddddd-0000-0000-0000-000000000002'), true);

-- Who can call what ------------------------------------------------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.report_content(text,uuid,text,text)', 'execute'), 'anon cannot report');
select ok(not has_function_privilege('anon', 'public.block_author(text,uuid)', 'execute'), 'anon cannot block');
select ok(not has_function_privilege('anon', 'public.unblock_all()', 'execute'), 'anon cannot unblock');
select ok(not has_function_privilege('anon', 'public.moderate_content(text,uuid,text)', 'execute'), 'anon cannot moderate');
select ok(not has_function_privilege('anon', 'public.moderation_queue()', 'execute'), 'anon cannot read the queue');
select ok(not has_function_privilege('anon', 'public.my_gym_photos()', 'execute'), 'anon cannot list photos');
select ok(not has_function_privilege('authenticated', 'gym_private.public_target(text,uuid)', 'execute'), 'target lookup is internal');
select ok(not has_function_privilege('authenticated', 'gym_private.set_status(text,uuid,text)', 'execute'), 'setting a status is internal');
select pg_temp.as_mcp(2);
select throws_ok($$ select public.report_content('listing', 'dddddddd-0000-0000-0000-000000000001', 'spam') $$,
  '42501'::char(5), null, 'an MCP client cannot report');
select throws_ok($$ select public.block_author('listing', 'dddddddd-0000-0000-0000-000000000001') $$,
  '42501'::char(5), null, 'an MCP client cannot block');
select throws_ok($$ select public.delete_my_account() $$, '42501'::char(5), null, 'an MCP client cannot delete the account');

-- Reporting --------------------------------------------------------------------------------------------------------
select pg_temp.as_user(2);
select is(public.report_content('listing', 'dddddddd-0000-0000-0000-000000000001', 'person-in-photo', '  a face  ')->>'status',
  'reported', 'a report is stored');
select is(public.report_content('listing', 'dddddddd-0000-0000-0000-000000000001', 'spam')->>'status',
  'already', 'a second report by the same user changes nothing');
select is(public.report_content('listing', 'dddddddd-0000-0000-0000-000000000001', 'not-a-reason')->>'status',
  'already', 'the repeat check comes first, so nothing is written');
select throws_ok(format($$ select public.report_content('item', %L, 'spam') $$, current_setting('t.item')),
  'P0001'::char(5), 'unknown target', 'items are not a target: their text comes through a listing');
select throws_ok($$ select public.report_content('listing', 'dddddddd-0000-0000-0000-00000000dead', 'spam') $$,
  'P0001'::char(5), 'unknown target', 'an unknown target is refused');
select throws_ok($$ select public.report_content('nonsense', 'dddddddd-0000-0000-0000-000000000001', 'spam') $$,
  'P0001'::char(5), 'unknown target', 'an unknown target type is refused');
select throws_ok(format($$ select public.report_content('gym', %L, 'not-a-reason') $$, current_setting('t.gym')),
  '23514'::char(5), null, 'an unknown reason is refused');
select throws_ok(format($$ select public.report_content('gym', %L, 'spam', repeat('x', 281)) $$, current_setting('t.gym')),
  '23514'::char(5), null, 'a long note is refused');
select throws_ok($$ select * from public.reports $$, '42501'::char(5), null, 'reports are not readable');
select pg_temp.as_user(1);
select is(public.report_content('listing', 'dddddddd-0000-0000-0000-000000000001', 'spam')->>'status', 'own',
  'an author''s report of their own listing is not stored');
select pg_temp.as_user(2);
reset role;
select is((select note from public.reports where reporter_id = 'cccccccc-0000-0000-0000-000000000002'), 'a face',
  'the note is trimmed');

-- Three reports hide it --------------------------------------------------------------------------------------------
select pg_temp.as_user(3);
select public.report_content('listing', 'dddddddd-0000-0000-0000-000000000001', 'spam');
select pg_temp.as_anon();
select is((select count(*) from public.public_gym_equipment where id = 'dddddddd-0000-0000-0000-000000000001')::int, 1,
  'two reports leave it visible');
select pg_temp.as_user(4);
select public.report_content('listing', 'dddddddd-0000-0000-0000-000000000001', 'other', 'wrong gym');
select is((select count(*) from public.public_gym_equipment where id = 'dddddddd-0000-0000-0000-000000000001')::int, 0,
  'the third report hides it from signed-in users');
select pg_temp.as_anon();
select is((select count(*) from public.public_gym_equipment where id = 'dddddddd-0000-0000-0000-000000000001')::int, 0,
  'and from anon');
select pg_temp.as_user(1);
select is((select status from public.public_gym_equipment where id = 'dddddddd-0000-0000-0000-000000000001'), 'flagged',
  'its author still reads it, for "Under review"');

-- Moderation -------------------------------------------------------------------------------------------------------
select throws_ok($$ select * from public.moderation_queue() $$, '42501'::char(5), null, 'a user cannot read the queue');
select throws_ok($$ select public.moderate_content('listing', 'dddddddd-0000-0000-0000-000000000001', 'remove') $$,
  '42501'::char(5), null, 'a user cannot moderate');
select pg_temp.as_user(5);
select is((select report_count from public.moderation_queue() where target_id = 'dddddddd-0000-0000-0000-000000000001'),
  3::bigint, 'the admin sees the count');
select is((select reasons from public.moderation_queue() where target_id = 'dddddddd-0000-0000-0000-000000000001'),
  '{"person-in-photo":1,"spam":1,"other":1}'::jsonb, 'and the reasons');
select is((select photo_path from public.moderation_queue() where target_id = 'dddddddd-0000-0000-0000-000000000001'),
  'dddddddd-0000-4000-8000-000000000001.jpg', 'and the photo');
select is((select notes from public.moderation_queue() where target_id = 'dddddddd-0000-0000-0000-000000000001'),
  '["a face","wrong gym"]'::jsonb, 'and the notes');
select is((select title from public.moderation_queue() where target_id = 'dddddddd-0000-0000-0000-000000000001'),
  'Acme X1', 'and what it is');
select throws_ok($$ select public.moderate_content('listing', 'dddddddd-0000-0000-0000-000000000001', 'nuke') $$,
  '22023'::char(5), null, 'an unknown action is refused');
select is(public.moderate_content('listing', 'dddddddd-0000-0000-0000-000000000001', 'restore')->>'status', 'active',
  'restore makes it active');
select is((select count(*) from public.moderation_queue())::int, 0, 'and clears the queue');
select pg_temp.as_anon();
select is((select count(*) from public.public_gym_equipment where id = 'dddddddd-0000-0000-0000-000000000001')::int, 1,
  'anon sees it again');
select pg_temp.as_user(2);
select is(public.report_content('listing', 'dddddddd-0000-0000-0000-000000000001', 'spam')->>'status', 'already',
  'a restored target is not reported again by the same user');
select pg_temp.as_user(5);
select is(public.moderate_content('listing', 'dddddddd-0000-0000-0000-000000000001', 'remove')->>'photo_path',
  'dddddddd-0000-4000-8000-000000000001.jpg', 'remove returns the photo to delete');
select pg_temp.as_user(1);
select is((select count(*) from public.public_gym_equipment where id = 'dddddddd-0000-0000-0000-000000000001')::int, 0,
  'a removed listing is hidden from its author too');
select pg_temp.as_user(5);
select is(public.moderate_content('listing', 'dddddddd-0000-0000-0000-000000000001', 'restore')->>'status', 'active',
  'an admin can bring a removed listing back');

-- A removed gym takes its listings with it -------------------------------------------------------------------------
select public.moderate_content('gym', current_setting('t.gym')::uuid, 'remove');
select pg_temp.as_anon();
select is((select count(*) from public.public_gym_equipment where gym_id = current_setting('t.gym')::uuid)::int, 0,
  'listings of a removed gym are hidden');
select pg_temp.as_user(5);
select public.moderate_content('gym', current_setting('t.gym')::uuid, 'restore');

-- One person cannot reach three reports --------------------------------------------------------------------------------
select pg_temp.as_user(6);
select public.report_content('listing', 'dddddddd-0000-0000-0000-000000000002', 'spam');
reset role;
delete from auth.users where id = 'cccccccc-0000-0000-0000-000000000006';
select pg_temp.as_user(7);
select public.report_content('listing', 'dddddddd-0000-0000-0000-000000000002', 'spam');
reset role;
delete from auth.users where id = 'cccccccc-0000-0000-0000-000000000007';
select pg_temp.as_user(8);
select public.report_content('listing', 'dddddddd-0000-0000-0000-000000000002', 'spam');
reset role;
select is((select status from public.gym_equipment where id = 'dddddddd-0000-0000-0000-000000000002'), 'active',
  'three reports whose authors were deleted do not flag a listing');
select pg_temp.as_user(2);
select public.report_content('listing', 'dddddddd-0000-0000-0000-000000000002', 'spam');
select pg_temp.as_user(3);
select public.report_content('listing', 'dddddddd-0000-0000-0000-000000000002', 'spam');
reset role;
select is((select status from public.gym_equipment where id = 'dddddddd-0000-0000-0000-000000000002'), 'flagged',
  'three reports from live accounts do');
reset role;
delete from auth.users where id = 'cccccccc-0000-0000-0000-000000000008';
select is((select status from public.gym_equipment where id = 'dddddddd-0000-0000-0000-000000000002'), 'flagged',
  'and deleting one of the authors afterwards leaves it flagged');
select pg_temp.as_user(5);
select is((select report_count from public.moderation_queue() where target_id = 'dddddddd-0000-0000-0000-000000000002'), 5::bigint,
  'every report still shows in the queue');
select public.moderate_content('listing', 'dddddddd-0000-0000-0000-000000000002', 'restore');

-- Throwaway accounts cannot clear a flag's trail --------------------------------------------------------------------------
select pg_temp.as_user(2);
select public.report_content('gym', current_setting('t.gym')::uuid, 'spam');
select pg_temp.as_user(3);
select public.report_content('gym', current_setting('t.gym')::uuid, 'spam');
select pg_temp.as_user(4);
select public.report_content('gym', current_setting('t.gym')::uuid, 'other', 'wrong name');
reset role;
delete from auth.users where id in ('cccccccc-0000-0000-0000-000000000003', 'cccccccc-0000-0000-0000-000000000004');
select pg_temp.as_user(5);
select is((select report_count from public.moderation_queue() where target_type = 'gym'), 3::bigint,
  'a flagged gym stays in the queue, with its reports, after the reporters delete their accounts');
select is(public.moderate_content('gym', current_setting('t.gym')::uuid, 'restore')->>'status', 'active', 'and an admin can restore it');
reset role;
update public.gyms set status = 'flagged' where id = current_setting('t.gym')::uuid;
delete from public.reports where target_type = 'gym';
select pg_temp.as_user(5);
select is((select count(*) from public.moderation_queue() where target_type = 'gym')::int, 1, 'flagged with no reports still shows');
select is((select reasons from public.moderation_queue() where target_type = 'gym'), '{}'::jsonb, 'with nothing to list');
select public.moderate_content('gym', current_setting('t.gym')::uuid, 'restore');

-- A restored gym whose place was taken in the meantime ---------------------------------------------------------------
select public.moderate_content('gym', current_setting('t.gym')::uuid, 'remove');
select pg_temp.as_user(2);
select set_config('t.gym2', public.find_or_create_gym('mod-p1', 'Real Gym', null, 1, 2)::text, true);
select pg_temp.as_user(5);
select throws_ok(format($$ select public.moderate_content('gym', %L, 'restore') $$, current_setting('t.gym')),
  'P0001'::char(5), 'place_taken', 'a removed gym cannot come back over the new one');
reset role;
delete from public.gyms where id = current_setting('t.gym2')::uuid;
select pg_temp.as_user(5);
select public.moderate_content('gym', current_setting('t.gym')::uuid, 'restore');

-- Blocking ---------------------------------------------------------------------------------------------------------
select pg_temp.as_user(2);
select lives_ok($$ select public.block_author('listing', 'dddddddd-0000-0000-0000-000000000002') $$, 'block by listing');
select is((select count(*) from public.public_gym_equipment where gym_id = current_setting('t.gym')::uuid)::int, 0,
  'everything from that author is hidden');
select is(public.unblock_all(), 1, 'unblock returns the count');
select is((select count(*) from public.public_gym_equipment where gym_id = current_setting('t.gym')::uuid)::int, 2,
  'and they come back');

-- Account deletion -------------------------------------------------------------------------------------------------
select pg_temp.as_user(1);
select is((select count(*) from public.my_gym_photos())::int, 1, 'a user can list their photos, to remove them first');
-- An upload that was never linked to a listing, and one in the private bucket: both owned, neither on any listing.
reset role;
insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'dddddddd-0000-4000-8000-000000000002.jpg', 'cccccccc-0000-0000-0000-000000000001', '{"mimetype":"image/jpeg"}'),
  ('gym-photos-private', 'dddddddd-0000-4000-8000-000000000003.jpg', 'cccccccc-0000-0000-0000-000000000001', '{"mimetype":"image/jpeg"}');
select pg_temp.as_user(1);
select is((select count(*) from public.my_gym_photos())::int, 3, 'it lists an orphan upload too, and the private bucket');
select is((select count(*) from public.my_gym_photos() where bucket_id = 'gym-photos-private')::int, 1, 'with its bucket');
select throws_ok($$ select public.delete_my_account() $$, 'P0001'::char(5), 'photos_remain',
  'the account stays while photos remain, whoever asks');
reset role;
select is((select count(*) from auth.users where id = 'cccccccc-0000-0000-0000-000000000001')::int, 1, 'and is still there');
select pg_temp.as_user(2);
select is((select count(*) from public.my_gym_photos())::int, 0, 'nobody sees another user''s photos');
-- Storage deletes objects through its API; this stands in for it.
reset role;
select set_config('storage.allow_delete_query', 'true', true);
delete from storage.objects where owner_id = 'cccccccc-0000-0000-0000-000000000001';
select pg_temp.as_user(1);
select is((select count(*) from public.my_gym_photos())::int, 0, 'once they are removed none are listed');
select lives_ok($$ select public.delete_my_account() $$, 'and the account can go');
reset role;
select is((select notes from public.gym_equipment where id = 'dddddddd-0000-0000-0000-000000000001'), null,
  'and without their note');
select is((select added_by from public.gym_equipment where id = 'dddddddd-0000-0000-0000-000000000001'), null,
  'the shared listing stays without its author');
select is((select photo_path from public.gym_equipment where id = 'dddddddd-0000-0000-0000-000000000001'), null,
  'and without the deleted photo');

select * from finish();
rollback;
