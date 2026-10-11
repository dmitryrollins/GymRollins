-- muscle_targets: owner-only RLS, MCP clients read-only behind mcp_read_plan, value CHECKs, last-write-wins,
-- account deletion cascade.
begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

insert into auth.users (id, email, aud, role) values
  ('12121212-1111-1111-1111-121212121212', 'targets-a@test.local', 'authenticated', 'authenticated'),
  ('12121212-2222-2222-2222-121212121212', 'targets-b@test.local', 'authenticated', 'authenticated');

set local role authenticated;
set local request.jwt.claims = '{"sub":"12121212-1111-1111-1111-121212121212","role":"authenticated"}';
insert into public.profiles (user_id) values ('12121212-1111-1111-1111-121212121212');

select lives_ok(
  $$ insert into public.muscle_targets (muscle, min_sets, max_sets, client_updated_at)
     values ('chest', 12, 18, '2026-09-29T10:00:00Z'), ('biceps', 6, 10, '2026-09-29T10:00:00Z') $$,
  'owner inserts targets (user_id defaults to auth.uid())');

select is((select min_sets from public.muscle_targets where muscle = 'chest'), 12, 'owner reads own target');

-- CHECKs ---------------------------------------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.muscle_targets (muscle, min_sets, max_sets) values ('neck', 1, 2) $$,
  '23514', null, 'unknown muscle id is rejected');
select throws_ok(
  $$ insert into public.muscle_targets (muscle, min_sets, max_sets) values ('lats', 12, 10) $$,
  '23514', null, 'min above max is rejected');
select throws_ok(
  $$ insert into public.muscle_targets (muscle, min_sets, max_sets) values ('lats', 10, 51) $$,
  '23514', null, 'more than 50 sets is rejected');
select throws_ok(
  $$ insert into public.muscle_targets (muscle, min_sets, max_sets) values ('lats', -1, 10) $$,
  '23514', null, 'negative sets are rejected');
select throws_ok(
  $$ insert into public.muscle_targets (muscle, min_sets, max_sets) values ('chest', 10, 20) $$,
  '23505', null, 'one row per muscle');

-- Last write wins by device edit time ---------------------------------------------------------------------------
update public.muscle_targets set min_sets = 4, client_updated_at = '2026-09-29T09:00:00Z' where muscle = 'chest';
select is((select min_sets from public.muscle_targets where muscle = 'chest'), 12, 'an older edit is skipped');
update public.muscle_targets set min_sets = 14, client_updated_at = '2026-09-29T11:00:00Z' where muscle = 'chest';
select is((select min_sets from public.muscle_targets where muscle = 'chest'), 14, 'a newer edit applies');

-- Isolation: user B sees nothing and can't touch A's rows ---------------------------------------------------------
set local request.jwt.claims = '{"sub":"12121212-2222-2222-2222-121212121212","role":"authenticated"}';
select is((select count(*) from public.muscle_targets)::int, 0, 'another user reads none of the owner''s targets');
with changed as (update public.muscle_targets set min_sets = 0 returning 1)
select is((select count(*) from changed)::int, 0, 'another user updates none of the owner''s targets');

-- MCP client: reads while mcp_read_plan, never writes -------------------------------------------------------------
set local request.jwt.claims =
  '{"sub":"12121212-1111-1111-1111-121212121212","role":"authenticated","client_id":"claude-test"}';
select is((select count(*) from public.muscle_targets)::int, 2, 'MCP client reads targets when mcp_read_plan');
select throws_ok(
  $$ insert into public.muscle_targets (muscle, min_sets, max_sets) values ('lats', 10, 20) $$,
  '42501', null, 'MCP client cannot insert targets');

set local request.jwt.claims = '{"sub":"12121212-1111-1111-1111-121212121212","role":"authenticated"}';
update public.profiles set mcp_read_plan = false where user_id = '12121212-1111-1111-1111-121212121212';
set local request.jwt.claims =
  '{"sub":"12121212-1111-1111-1111-121212121212","role":"authenticated","client_id":"claude-test"}';
select is((select count(*) from public.muscle_targets)::int, 0, 'MCP client reads no targets once mcp_read_plan is off');

-- Deleting the account removes its targets (cascade from auth.users).
reset role;
delete from auth.users where id = '12121212-1111-1111-1111-121212121212';
select is((select count(*) from public.muscle_targets where user_id = '12121212-1111-1111-1111-121212121212')::int,
  0, 'account deletion removes the targets');

select * from finish();
rollback;
