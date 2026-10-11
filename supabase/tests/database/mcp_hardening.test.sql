-- mcp_read_plan gates what MCP clients read of the plan/profile (the app session is unaffected), and
-- mcp_take_call() hands out at most 60 call slots per user per trailing minute.
begin;
create extension if not exists pgtap with schema extensions;
select plan(18);

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

select * from finish();
rollback;
