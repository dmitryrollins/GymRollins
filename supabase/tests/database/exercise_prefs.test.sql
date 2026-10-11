-- exercise_prefs: owner read/write, per-user isolation, MCP read-only behind mcp_read_plan, LWW guard, value
-- checks, no anon access, and account deletion removes the rows.
begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

insert into auth.users (id, email, aud, role) values
  ('88888888-1111-1111-1111-888888888888', 'prefs-owner@test.local', 'authenticated', 'authenticated'),
  ('88888888-2222-2222-2222-888888888888', 'prefs-other@test.local', 'authenticated', 'authenticated');

set local role authenticated;
set local request.jwt.claims = '{"sub":"88888888-1111-1111-1111-888888888888","role":"authenticated"}';

insert into public.exercise_prefs (exercise_id, pref, client_updated_at) values
  ('0025', 'more', '2026-09-29T10:00:00Z'),
  ('custom-3f1c2a9e-0000-4000-8000-000000000001', 'never', '2026-09-29T10:00:00Z');
select is((select count(*) from public.exercise_prefs)::int, 2, 'the owner stores preferences');
select is((select user_id from public.exercise_prefs where exercise_id = '0025'),
  '88888888-1111-1111-1111-888888888888'::uuid, 'user_id defaults to the caller');

-- The app's upsert (PostgREST on_conflict=user_id,exercise_id) replaces a row with a newer edit ...
insert into public.exercise_prefs (exercise_id, pref, client_updated_at) values ('0025', 'less', '2026-09-29T11:00:00Z')
  on conflict (user_id, exercise_id) do update set pref = excluded.pref, client_updated_at = excluded.client_updated_at;
select is((select pref from public.exercise_prefs where exercise_id = '0025'), 'less', 'a newer edit replaces the row');
-- ... and the LWW guard skips an older one.
insert into public.exercise_prefs (exercise_id, pref, client_updated_at) values ('0025', 'more', '2026-09-29T09:00:00Z')
  on conflict (user_id, exercise_id) do update set pref = excluded.pref, client_updated_at = excluded.client_updated_at;
select is((select pref from public.exercise_prefs where exercise_id = '0025'), 'less', 'an older edit is skipped (LWW)');

select throws_ok(
  $$ insert into public.exercise_prefs (exercise_id, pref) values ('0070', 'sometimes') $$,
  '23514'::char(5), null, 'pref must be more/normal/less/never'
);
select throws_ok(
  $$ insert into public.exercise_prefs (exercise_id, pref) values ('bad id;drop', 'more') $$,
  '23514'::char(5), null, 'exercise_id must be a plain id'
);
select throws_ok(
  $$ insert into public.exercise_prefs (user_id, exercise_id, pref)
     values ('88888888-2222-2222-2222-888888888888', '0070', 'never') $$,
  '42501'::char(5), null, 'cannot write another user''s preferences'
);

-- Another user sees nothing of the owner's rows and can't change them.
set local request.jwt.claims = '{"sub":"88888888-2222-2222-2222-888888888888","role":"authenticated"}';
select is((select count(*) from public.exercise_prefs)::int, 0, 'another user sees no preferences');
with changed as (update public.exercise_prefs set pref = 'more' returning 1)
select is((select count(*) from changed)::int, 0, 'another user cannot update them');

-- MCP client: read-only, gated by mcp_read_plan.
set local request.jwt.claims = '{"sub":"88888888-1111-1111-1111-888888888888","role":"authenticated"}';
insert into public.profiles (user_id) values ('88888888-1111-1111-1111-888888888888');
set local request.jwt.claims =
  '{"sub":"88888888-1111-1111-1111-888888888888","role":"authenticated","client_id":"claude-test"}';
select is((select count(*) from public.exercise_prefs)::int, 2, 'MCP client reads preferences when mcp_read_plan');
select throws_ok(
  $$ insert into public.exercise_prefs (exercise_id, pref) values ('0070', 'more') $$,
  '42501'::char(5), null, 'MCP client cannot insert preferences'
);
with changed as (update public.exercise_prefs set pref = 'more', client_updated_at = now() + interval '1 day' returning 1)
select is((select count(*) from changed)::int, 0, 'MCP client cannot update preferences');
with gone as (delete from public.exercise_prefs returning 1)
select is((select count(*) from gone)::int, 0, 'MCP client cannot delete preferences');

set local request.jwt.claims = '{"sub":"88888888-1111-1111-1111-888888888888","role":"authenticated"}';
update public.profiles set mcp_read_plan = false;
set local request.jwt.claims =
  '{"sub":"88888888-1111-1111-1111-888888888888","role":"authenticated","client_id":"claude-test"}';
select is((select count(*) from public.exercise_prefs)::int, 0, 'MCP client reads none once mcp_read_plan is off');
select is(public.never_exercise_ids(array['0025', 'custom-3f1c2a9e-0000-4000-8000-000000000001', '9999']),
  array['custom-3f1c2a9e-0000-4000-8000-000000000001'],
  'the proposal check still sees the caller''s never exercises with mcp_read_plan off');

-- Disconnect Claude: every permission off. An outstanding MCP token learns nothing from the check.
set local request.jwt.claims = '{"sub":"88888888-1111-1111-1111-888888888888","role":"authenticated"}';
update public.profiles set mcp_propose = false, mcp_read_workouts = false, mcp_read_body = false;
set local request.jwt.claims =
  '{"sub":"88888888-1111-1111-1111-888888888888","role":"authenticated","client_id":"claude-test"}';
select is(public.never_exercise_ids(array['custom-3f1c2a9e-0000-4000-8000-000000000001']), '{}'::text[],
  'after Disconnect Claude the check reveals nothing to an MCP token');

set local request.jwt.claims = '{"sub":"88888888-1111-1111-1111-888888888888","role":"authenticated"}';
select is((select count(*) from public.exercise_prefs)::int, 2, 'the app session is unaffected by mcp_read_plan');

set local request.jwt.claims = '{"sub":"88888888-2222-2222-2222-888888888888","role":"authenticated"}';
select is(public.never_exercise_ids(array['custom-3f1c2a9e-0000-4000-8000-000000000001']), '{}'::text[],
  'another user never sees the owner''s never flags');
select is(public.never_exercise_ids('{}'::text[]), '{}'::text[], 'no ids, no flags');

reset role;
select ok(not has_table_privilege('anon', 'public.exercise_prefs', 'select'), 'anon cannot read preferences');
select ok(not has_function_privilege('anon', 'public.never_exercise_ids(text[])', 'execute'),
  'anon cannot call never_exercise_ids');

delete from auth.users where id = '88888888-1111-1111-1111-888888888888';
select is((select count(*) from public.exercise_prefs)::int, 0, 'deleting the account deletes its preferences');

select * from finish();
rollback;
