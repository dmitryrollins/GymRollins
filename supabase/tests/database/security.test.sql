-- Security fixes: parent ownership for workout children and week_schedule, anon lockdown (tables + RPCs),
-- pgcrypto outside public, value checks for cardio/volume, and upsert_workout's stale path leaving children alone.
begin;
create extension if not exists pgtap with schema extensions;
select plan(29);

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'sec-a@test.local', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'sec-b@test.local', 'authenticated', 'authenticated');

-- A owns a workout with one entry + set, and a routine.
set local role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-0000-0000-00000000000a","role":"authenticated"}';

select public.upsert_workout('{
  "id": "a1000000-0000-0000-0000-000000000001",
  "started_at": "2026-01-01T10:00:00Z", "name": "A Workout", "client_updated_at": "2026-01-01T11:00:00Z",
  "entries": [{"id": "a2000000-0000-0000-0000-000000000001", "exercise_id": "0001", "position": 0,
               "sets": [{"id": "a3000000-0000-0000-0000-000000000001", "position": 0, "w_kg": 60, "r": 8}]}]
}'::jsonb);
insert into public.routines (id, name, exercises) values ('a4000000-0000-0000-0000-000000000001', 'A Routine', '[]');

-- H1: B cannot attach children to A's workout / entry ------------------------------------------------------------
set local request.jwt.claims = '{"sub":"b0000000-0000-0000-0000-00000000000b","role":"authenticated"}';

select throws_ok(
  $$ insert into public.workout_entries (id, workout_id, exercise_id, position)
     values ('b2000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', '0001', 5) $$,
  '42501'::char(5), null, 'B cannot insert an entry pointing at A''s workout');
select throws_ok(
  $$ insert into public.workout_sets (id, entry_id, position, w_kg, r)
     values ('b3000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 5, 1, 1) $$,
  '42501'::char(5), null, 'B cannot insert a set pointing at A''s entry');

-- B's own workout, then try to move B's entry under A's workout via update.
select public.upsert_workout('{
  "id": "b1000000-0000-0000-0000-000000000001",
  "started_at": "2026-01-01T10:00:00Z", "name": "B Workout", "client_updated_at": "2026-01-01T11:00:00Z",
  "entries": [{"id": "b2000000-0000-0000-0000-000000000002", "exercise_id": "0001", "position": 0,
               "sets": [{"id": "b3000000-0000-0000-0000-000000000002", "position": 0, "w_kg": 50, "r": 5}]}]
}'::jsonb);
select lives_ok(
  $$ insert into public.workout_entries (id, workout_id, exercise_id, position)
     values ('b2000000-0000-0000-0000-000000000003', 'b1000000-0000-0000-0000-000000000001', '0002', 1) $$,
  'B can insert an entry under B''s own workout');
select throws_ok(
  $$ update public.workout_entries set workout_id = 'a1000000-0000-0000-0000-000000000001'
     where id = 'b2000000-0000-0000-0000-000000000002' $$,
  '42501'::char(5), null, 'B cannot move an entry under A''s workout');
select throws_ok(
  $$ update public.workout_sets set entry_id = 'a2000000-0000-0000-0000-000000000001'
     where id = 'b3000000-0000-0000-0000-000000000002' $$,
  '42501'::char(5), null, 'B cannot move a set under A''s entry');

-- L3: week_schedule may reference only the caller's own routine ------------------------------------------------
select throws_ok(
  $$ insert into public.week_schedule (weekday, routine_id) values (1, 'a4000000-0000-0000-0000-000000000001') $$,
  '42501'::char(5), null, 'B cannot schedule A''s routine');
select lives_ok(
  $$ insert into public.week_schedule (weekday, routine_id) values (2, null) $$,
  'B can schedule a rest day (null routine)');
insert into public.routines (id, name, exercises) values ('b4000000-0000-0000-0000-000000000001', 'B Routine', '[]');
select lives_ok(
  $$ insert into public.week_schedule (weekday, routine_id) values (3, 'b4000000-0000-0000-0000-000000000001') $$,
  'B can schedule B''s own routine');
select throws_ok(
  $$ update public.week_schedule set routine_id = 'a4000000-0000-0000-0000-000000000001' where weekday = 3 $$,
  '42501'::char(5), null, 'B cannot switch a weekday to A''s routine');

-- L4: value checks -----------------------------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.workout_sets (id, entry_id, position, w_kg, r, min)
     values ('b3000000-0000-0000-0000-000000000010', 'b2000000-0000-0000-0000-000000000002', 10, 0, 0, 1441) $$,
  '23514'::char(5), null, 'min above 1440 is rejected');
select throws_ok(
  $$ insert into public.workout_sets (id, entry_id, position, w_kg, r, min)
     values ('b3000000-0000-0000-0000-000000000011', 'b2000000-0000-0000-0000-000000000002', 11, 0, 0, -1) $$,
  '23514'::char(5), null, 'negative min is rejected');
select throws_ok(
  $$ insert into public.workout_sets (id, entry_id, position, w_kg, r, dist_m)
     values ('b3000000-0000-0000-0000-000000000012', 'b2000000-0000-0000-0000-000000000002', 12, 0, 0, 1000001) $$,
  '23514'::char(5), null, 'dist_m above 1,000,000 is rejected');
select lives_ok(
  $$ insert into public.workout_sets (id, entry_id, position, w_kg, r, min, dist_m)
     values ('b3000000-0000-0000-0000-000000000013', 'b2000000-0000-0000-0000-000000000002', 13, 0, 0, 30, 5000) $$,
  'in-range min and dist_m are accepted');
select throws_ok(
  $$ select public.upsert_workout('{"id": "b1000000-0000-0000-0000-000000000009", "started_at": "2026-01-01T10:00:00Z",
       "name": "Neg", "client_updated_at": "2026-01-01T11:00:00Z", "vol_kg": -1, "entries": []}'::jsonb) $$,
  '23514'::char(5), null, 'negative vol_kg is rejected');

-- Codex P1: a stale upsert_workout leaves children unchanged ------------------------------------------------------
select is(
  public.upsert_workout('{
    "id": "b1000000-0000-0000-0000-000000000001",
    "started_at": "2026-01-01T10:00:00Z", "name": "Stale", "client_updated_at": "2026-01-01T09:00:00Z",
    "entries": [{"id": "b2000000-0000-0000-0000-000000000099", "exercise_id": "0009", "position": 0,
                 "sets": [{"id": "b3000000-0000-0000-0000-000000000099", "position": 0, "w_kg": 1, "r": 1}]}]
  }'::jsonb) ->> 'status',
  'stale', 'an older upsert_workout returns stale');
select is(
  (select array_agg(id::text order by id) from public.workout_entries
    where workout_id = 'b1000000-0000-0000-0000-000000000001'),
  array['b2000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000003'],
  'a stale upsert_workout keeps the stored entries');
select is(
  (select w_kg from public.workout_sets where id = 'b3000000-0000-0000-0000-000000000002'), 50::numeric,
  'a stale upsert_workout keeps the stored sets');
select is(
  (select count(*) from public.workout_sets where id = 'b3000000-0000-0000-0000-000000000099')::int, 0,
  'a stale upsert_workout inserts none of its sets');
-- Equal client_updated_at still applies (the guard only skips strictly older edits).
select is(
  public.upsert_workout('{
    "id": "b1000000-0000-0000-0000-000000000001",
    "started_at": "2026-01-01T10:00:00Z", "name": "Same Time", "client_updated_at": "2026-01-01T11:00:00Z",
    "entries": []
  }'::jsonb) ->> 'status',
  'ok', 'an upsert_workout with an equal client_updated_at applies');

-- B cannot overwrite A's workout id through the RPC.
select throws_ok(
  $$ select public.upsert_workout('{"id": "a1000000-0000-0000-0000-000000000001", "started_at": "2026-01-01T10:00:00Z",
       "name": "Hijack", "client_updated_at": "2030-01-01T00:00:00Z", "entries": []}'::jsonb) $$,
  '42501'::char(5), null, 'B cannot overwrite A''s workout via upsert_workout');

-- M1 + L2: anon has no RPC or table access ------------------------------------------------------------------------
reset role;
select ok(not has_function_privilege('anon', 'public.upsert_workout(jsonb)', 'execute'), 'anon cannot execute upsert_workout');
select ok(not has_function_privilege('anon', 'public.mcp_flag(text)', 'execute'), 'anon cannot execute mcp_flag');
select ok(not has_function_privilege('anon', 'public.is_mcp_client()', 'execute'), 'anon cannot execute is_mcp_client');
select ok(has_function_privilege('authenticated', 'public.upsert_workout(jsonb)', 'execute'),
  'authenticated can execute upsert_workout');
select ok(has_function_privilege('authenticated', 'public.mcp_flag(text)', 'execute'),
  'authenticated can execute mcp_flag');
select is(
  (select count(*) from information_schema.role_table_grants
    where table_schema = 'public' and grantee in ('anon', 'PUBLIC'))::int,
  0, 'anon (and PUBLIC) hold no privileges on any public table');
select ok(
  not exists (select 1 from pg_default_acl d, aclexplode(d.defaclacl) a
              where d.defaclnamespace = 'public'::regnamespace and d.defaclrole = 'postgres'::regrole
                and d.defaclobjtype in ('r', 'S', 'f') and a.grantee = 'anon'::regrole),
  'future public tables/sequences/functions created by postgres grant nothing to anon');

set local role anon;
select throws_ok($$ select count(*) from public.exercises $$, '42501'::char(5), null, 'anon cannot read exercises');

-- L1: pgcrypto lives in extensions, gen_random_uuid still resolves ---------------------------------------------------
reset role;
select is((select extnamespace::regnamespace::text from pg_extension where extname = 'pgcrypto'), 'extensions',
  'pgcrypto is installed in the extensions schema');

select * from finish();
rollback;
