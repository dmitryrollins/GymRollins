-- upsert_workout base-version conflict detection (v0.1.0 review, Codex P1): two devices edit the same workout.
-- Device A and device B are the same user; each sends the server `updated_at` it last saw as `base_updated_at`.
begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

insert into auth.users (id, email, aud, role) values
  ('c0000000-0000-0000-0000-00000000000c', 'conflict@test.local', 'authenticated', 'authenticated');

set local role authenticated;
set local request.jwt.claims = '{"sub":"c0000000-0000-0000-0000-00000000000c","role":"authenticated"}';

-- Device A creates the workout (never synced: base null).
select is(public.upsert_workout('{
  "id": "c1000000-0000-0000-0000-000000000001", "started_at": "2026-01-01T10:00:00Z", "name": "Created on A",
  "client_updated_at": "2026-01-01T11:00:00Z",
  "entries": [{"id": "c2000000-0000-0000-0000-000000000001", "exercise_id": "0001", "position": 0,
               "sets": [{"id": "c3000000-0000-0000-0000-000000000001", "position": 0, "w_kg": 60, "r": 8}]}]
}'::jsonb) ->> 'status', 'ok', 'device A inserts a new workout with no base');

-- Both devices now hold version v1. Simulate A's later sync bumping the server version to v2 (as the table owner,
-- trigger disabled: inside one transaction now() is constant, so trigger-driven versions would tie).
create temporary table versions (label text primary key, at timestamptz);
grant all on versions to authenticated;
insert into versions select 'v1', updated_at from public.workouts where id = 'c1000000-0000-0000-0000-000000000001';

select is(public.upsert_workout(jsonb_build_object(
  'id', 'c1000000-0000-0000-0000-000000000001', 'started_at', '2026-01-01T10:00:00Z', 'name', 'Edited on A',
  'client_updated_at', '2026-01-01T12:00:00Z', 'base_updated_at', (select at from versions where label = 'v1'),
  'entries', '[]'::jsonb)) ->> 'status', 'ok', 'device A edits with the current base: ok');

reset role;
alter table public.workouts disable trigger b_updated_at;
update public.workouts set updated_at = (select at from versions where label = 'v1') + interval '1 minute'
  where id = 'c1000000-0000-0000-0000-000000000001';
alter table public.workouts enable trigger b_updated_at;
insert into versions select 'v2', updated_at from public.workouts where id = 'c1000000-0000-0000-0000-000000000001';
set local role authenticated;
set local request.jwt.claims = '{"sub":"c0000000-0000-0000-0000-00000000000c","role":"authenticated"}';

-- Device B edited later on the wall clock but from v1: without the base check it would silently overwrite A.
select is(public.upsert_workout(jsonb_build_object(
  'id', 'c1000000-0000-0000-0000-000000000001', 'started_at', '2026-01-01T10:00:00Z', 'name', 'Edited on B',
  'client_updated_at', '2026-01-01T13:00:00Z', 'base_updated_at', (select at from versions where label = 'v1'),
  'entries', '[{"id": "c2000000-0000-0000-0000-000000000099", "exercise_id": "0009", "position": 0, "sets": []}]'::jsonb
)) ->> 'status', 'stale', 'device B with a stale base (and a newer edit time) gets stale');
select is((select name from public.workouts where id = 'c1000000-0000-0000-0000-000000000001'), 'Edited on A',
  'a stale-base write leaves the workout unchanged');
select is((select count(*) from public.workout_entries
  where id = 'c2000000-0000-0000-0000-000000000099')::int, 0, 'a stale-base write inserts no entries');
select is((select updated_at from public.workouts where id = 'c1000000-0000-0000-0000-000000000001'),
  (select at from versions where label = 'v2'), 'a stale-base write does not bump updated_at');

-- A never-synced (null base) write to an existing row with a different edit time is a conflict too.
select is(public.upsert_workout(jsonb_build_object(
  'id', 'c1000000-0000-0000-0000-000000000001', 'started_at', '2026-01-01T10:00:00Z', 'name', 'No base',
  'client_updated_at', '2026-01-01T14:00:00Z', 'entries', '[]'::jsonb)) ->> 'status', 'stale',
  'a null base against an existing row with another edit time is stale');

-- Device B picks "Keep this iPhone's": force overwrites even with the stale base and an older edit time.
select is(public.upsert_workout(jsonb_build_object(
  'id', 'c1000000-0000-0000-0000-000000000001', 'started_at', '2026-01-01T10:00:00Z', 'name', 'Kept from B',
  'client_updated_at', '2026-01-01T11:30:00Z', 'base_updated_at', (select at from versions where label = 'v1'),
  'force', true,
  'entries', '[{"id": "c2000000-0000-0000-0000-000000000099", "exercise_id": "0009", "position": 0, "sets": []}]'::jsonb
)) ->> 'status', 'ok', 'force (explicit keep-local) applies despite the stale base');
select is((select name from public.workouts where id = 'c1000000-0000-0000-0000-000000000001'), 'Kept from B',
  'the forced write replaced the workout');
select is((select array_agg(id::text) from public.workout_entries
  where workout_id = 'c1000000-0000-0000-0000-000000000001'), array['c2000000-0000-0000-0000-000000000099'],
  'the forced write replaced the children');
select is((select client_updated_at from public.workouts where id = 'c1000000-0000-0000-0000-000000000001'),
  '2026-01-01T12:00:00Z'::timestamptz, 'a forced older edit keeps the newer stored edit time (lww trigger safe)');

-- Non-force writes still honour the client_updated_at guard even with the current base.
select is(public.upsert_workout(jsonb_build_object(
  'id', 'c1000000-0000-0000-0000-000000000001', 'started_at', '2026-01-01T10:00:00Z', 'name', 'Older',
  'client_updated_at', '2026-01-01T09:00:00Z',
  'base_updated_at', (select updated_at from public.workouts where id = 'c1000000-0000-0000-0000-000000000001'),
  'entries', '[]'::jsonb)) ->> 'status', 'stale', 'current base but an older edit time is still stale');

select * from finish();
rollback;
