-- mcp_read_plan gates what MCP clients read of the plan/profile (the app session is unaffected), and
-- mcp_take_call() hands out at most 60 call slots per user per trailing minute.
begin;
create extension if not exists pgtap with schema extensions;
select plan(31);

insert into auth.users (id, email, aud, role) values
  ('77777777-1111-1111-1111-777777777777', 'plan-owner@test.local', 'authenticated', 'authenticated'),
  ('77777777-2222-2222-2222-777777777777', 'plan-other@test.local', 'authenticated', 'authenticated');

set local role authenticated;
set local request.jwt.claims = '{"sub":"77777777-1111-1111-1111-777777777777","role":"authenticated"}';

insert into public.profiles (user_id) values ('77777777-1111-1111-1111-777777777777');
insert into public.routines (id, name, exercises, client_updated_at)
values ('77777777-3333-3333-3333-777777777777', 'Push', '[]'::jsonb, now());
insert into public.week_schedule (weekday, routine_id) values (1, '77777777-3333-3333-3333-777777777777');
insert into public.custom_exercises (id, n, bp, eq, tg) values ('custom-plan-1', 'My curl', 'arms', 'cable', 'biceps');

select is((select mcp_read_plan from public.profiles), true, 'mcp_read_plan defaults to true');

-- MCP client with the flag on sees everything.
set local request.jwt.claims =
  '{"sub":"77777777-1111-1111-1111-777777777777","role":"authenticated","client_id":"claude-test"}';
select is((select count(*) from public.profiles)::int, 1, 'MCP client reads the profile when mcp_read_plan');
select is((select count(*) from public.routines)::int, 1, 'MCP client reads routines when mcp_read_plan');
select is((select count(*) from public.week_schedule)::int, 1, 'MCP client reads week_schedule when mcp_read_plan');
select is((select count(*) from public.custom_exercises)::int, 1,
  'MCP client reads custom_exercises when mcp_read_plan');

-- The owner turns it off in the app.
set local request.jwt.claims = '{"sub":"77777777-1111-1111-1111-777777777777","role":"authenticated"}';
update public.profiles set mcp_read_plan = false;

set local request.jwt.claims =
  '{"sub":"77777777-1111-1111-1111-777777777777","role":"authenticated","client_id":"claude-test"}';
select is((select count(*) from public.profiles)::int, 0, 'MCP client reads no profile once mcp_read_plan is off');
select is((select count(*) from public.routines)::int, 0, 'MCP client reads no routines once mcp_read_plan is off');
select is((select count(*) from public.week_schedule)::int, 0,
  'MCP client reads no week_schedule once mcp_read_plan is off');
select is((select count(*) from public.custom_exercises)::int, 0,
  'MCP client reads no custom_exercises once mcp_read_plan is off');
select is(public.mcp_flag('plan'), false, 'MCP client still evaluates its own flag (security definer)');
select is(public.mcp_flag('nonsense'), false, 'a flag that does not exist is off, not on');

-- The app session still sees its own data.
set local request.jwt.claims = '{"sub":"77777777-1111-1111-1111-777777777777","role":"authenticated"}';
select is((select count(*) from public.routines)::int + (select count(*) from public.profiles)::int, 2,
  'the app session is unaffected by mcp_read_plan');

-- mcp_take_call: 60 slots per trailing minute, per user.
select is((select count(*) from generate_series(1, 60) where public.mcp_take_call())::int, 60,
  'the first 60 calls in a minute are allowed');
select is(public.mcp_take_call(), false, 'call 61 is refused');
select is((select count(*) from public.mcp_calls)::int, 60, 'refused calls take no slot');

-- An MCP client can reach mcp_calls over PostgREST, but can't free slots by deleting fresh rows or backdating.
set local request.jwt.claims =
  '{"sub":"77777777-1111-1111-1111-777777777777","role":"authenticated","client_id":"claude-test"}';
with gone as (delete from public.mcp_calls returning 1)
select is((select count(*) from gone)::int, 0, 'fresh call rows cannot be deleted');
select throws_ok(
  $$ insert into public.mcp_calls (at) values (now() + interval '1 hour') $$,
  '42501'::char(5), null, 'call rows must be stamped now'
);

set local request.jwt.claims = '{"sub":"77777777-2222-2222-2222-777777777777","role":"authenticated"}';
select is(public.mcp_take_call(), true, 'another user has their own budget');

reset role;
select ok(not has_function_privilege('anon', 'public.mcp_take_call()', 'execute'), 'anon cannot take call slots');

-- mcp_read_gyms gates Claude's reads of gyms and listings (list_gyms / get_gym_equipment) -------------------------------
reset role;
set local request.jwt.claims = ''; -- seed as postgres: the triggers would otherwise stamp the last user as the author
insert into auth.users (id, email, aud, role) values
  ('88888888-1111-1111-1111-888888888888', 'gym-owner@test.local', 'authenticated', 'authenticated'),
  ('88888888-2222-2222-2222-888888888888', 'gym-stranger@test.local', 'authenticated', 'authenticated'),
  ('88888888-3333-3333-3333-888888888888', 'gym-blocked@test.local', 'authenticated', 'authenticated');
insert into public.profiles (user_id) values ('88888888-1111-1111-1111-888888888888');
insert into public.gyms (id, visibility, owner_id, name, created_by) values
  ('88888888-aaaa-4aaa-8aaa-000000000001', 'private', '88888888-1111-1111-1111-888888888888', 'Garage',
   '88888888-1111-1111-1111-888888888888'),
  ('88888888-aaaa-4aaa-8aaa-000000000002', 'private', '88888888-2222-2222-2222-888888888888', 'Cellar',
   '88888888-2222-2222-2222-888888888888');
insert into public.gyms (id, visibility, name, maps_place_id, created_by, status) values
  ('88888888-aaaa-4aaa-8aaa-000000000003', 'public', 'Iron Works', 'mcp-p1', '88888888-2222-2222-2222-888888888888', 'active'),
  ('88888888-aaaa-4aaa-8aaa-000000000004', 'public', 'My flagged gym', 'mcp-p2', '88888888-1111-1111-1111-888888888888', 'flagged');
insert into public.gym_equipment (id, gym_id, item_id, visibility, owner_id, added_by, private_brand) values
  ('88888888-bbbb-4bbb-8bbb-000000000001', '88888888-aaaa-4aaa-8aaa-000000000001',
   (select id from public.equipment_items where kind_id = 'barbell' and brand is null), 'private',
   '88888888-1111-1111-1111-888888888888', '88888888-1111-1111-1111-888888888888', 'Rogue'),
  ('88888888-bbbb-4bbb-8bbb-000000000002', '88888888-aaaa-4aaa-8aaa-000000000002',
   (select id from public.equipment_items where kind_id = 'barbell' and brand is null), 'private',
   '88888888-2222-2222-2222-888888888888', '88888888-2222-2222-2222-888888888888', null);
insert into public.gym_equipment (id, gym_id, item_id, visibility, added_by) values
  ('88888888-bbbb-4bbb-8bbb-000000000003', '88888888-aaaa-4aaa-8aaa-000000000003',
   (select id from public.equipment_items where kind_id = 'dumbbells' and brand is null), 'public',
   '88888888-1111-1111-1111-888888888888'),
  ('88888888-bbbb-4bbb-8bbb-000000000004', '88888888-aaaa-4aaa-8aaa-000000000003',
   (select id from public.equipment_items where kind_id = 'flat-bench' and brand is null), 'public',
   '88888888-3333-3333-3333-888888888888');
insert into public.user_blocks (blocker_id, blocked_id)
  values ('88888888-1111-1111-1111-888888888888', '88888888-3333-3333-3333-888888888888');
insert into public.workouts (id, user_id, started_at, name, gym_id)
  values ('88888888-cccc-4ccc-8ccc-000000000001', '88888888-1111-1111-1111-888888888888', now(), 'W',
          '88888888-aaaa-4aaa-8aaa-000000000003');

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"88888888-1111-1111-1111-888888888888","role":"authenticated","client_id":"claude-test"}';
select is((select count(*) from public.gyms where visibility = 'private')::int, 1,
  'Claude reads only its own private gym while mcp_read_gyms is on');
select is((select count(*) from public.gym_equipment where visibility = 'private')::int, 1,
  'and only its own private listings');
select is((select count(*) from public.gyms where id = '88888888-aaaa-4aaa-8aaa-000000000004')::int, 0,
  'Claude never sees the owner''s own flagged public gym, flag on or not');
select is((select count(*) from public.public_gym_equipment where gym_id = '88888888-aaaa-4aaa-8aaa-000000000003')::int, 1,
  'a blocked author''s public listing is hidden from Claude through the view');
select is((select array_agg(g) from public.my_shared_gym_ids() g), array['88888888-aaaa-4aaa-8aaa-000000000003'::uuid],
  'my_shared_gym_ids returns the public gyms the owner shared to');
select is((select count(distinct gym_id) from public.workouts where gym_id is not null)::int, 1,
  'workouts.gym_id is readable while mcp_read_workouts is on');
select cmp_ok((select count(*) from public.exercise_requirements)::int, '>', 1000,
  'Claude reads the exercise requirements the matcher needs');

set local request.jwt.claims = '{"sub":"88888888-1111-1111-1111-888888888888","role":"authenticated"}';
update public.profiles set mcp_read_gyms = false, mcp_read_workouts = false;
set local request.jwt.claims =
  '{"sub":"88888888-1111-1111-1111-888888888888","role":"authenticated","client_id":"claude-test"}';
select is((select count(*) from public.gyms where visibility = 'private')::int, 0,
  'with mcp_read_gyms off Claude reads no private gym');
select is((select count(*) from public.gym_equipment where visibility = 'private')::int, 0, 'and no private listing');
select is((select count(*) from public.my_shared_gym_ids())::int, 0, 'and is told of no shared gym');
select is((select count(*) from public.workouts)::int, 0, 'with mcp_read_workouts off the gym links stay hidden too');

set local request.jwt.claims = '{"sub":"88888888-1111-1111-1111-888888888888","role":"authenticated"}';
select is((select count(*) from public.gyms where visibility = 'private')::int, 1,
  'the app session still reads its private gym');

select * from finish();
rollback;
