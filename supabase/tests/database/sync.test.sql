-- LWW conflict guard, updated_at trigger, upsert_workout aggregate replace/stale, and a value check constraint.
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id, email, aud, role) values
  ('33333333-3333-3333-3333-333333333333', 'sync@test.local', 'authenticated', 'authenticated');

set local role authenticated;
set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';

-- LWW guard: routines -----------------------------------------------------------------------------------------
insert into public.routines (id, name, exercises, client_updated_at)
values ('44444444-4444-4444-4444-444444444444', 'A', '[]'::jsonb, '2026-01-01T12:00:00Z');

create temporary table sync_capture (label text primary key, updated_at timestamptz);
insert into sync_capture select 'initial', updated_at from public.routines
  where id = '44444444-4444-4444-4444-444444444444';

-- Backdate updated_at (as the table owner, with the trigger disabled) so the "greater than" check below is
-- meaningful: within one transaction now() is constant, so two now()-driven trigger writes would tie.
reset role;
alter table public.routines disable trigger b_updated_at;
update public.routines set updated_at = '2000-01-01T00:00:00Z'
  where id = '44444444-4444-4444-4444-444444444444';
alter table public.routines enable trigger b_updated_at;
insert into sync_capture select 'backdated', updated_at from public.routines
  where id = '44444444-4444-4444-4444-444444444444';
set local role authenticated;
set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';

-- An update with an OLDER client_updated_at than the stored one is skipped by the lww_guard trigger.
update public.routines set name = 'B', client_updated_at = '2026-01-01T11:00:00Z'
  where id = '44444444-4444-4444-4444-444444444444';

select is((select name from public.routines where id = '44444444-4444-4444-4444-444444444444'), 'A',
  'LWW guard: an older client_updated_at leaves the row unchanged');
select is((select updated_at from public.routines where id = '44444444-4444-4444-4444-444444444444'),
  (select updated_at from sync_capture where label = 'backdated'),
  'LWW guard: an older client_updated_at does not bump updated_at either');

-- An update with a NEWER client_updated_at applies, and the trigger bumps updated_at.
update public.routines set name = 'C', client_updated_at = '2026-01-01T13:00:00Z'
  where id = '44444444-4444-4444-4444-444444444444';

select is((select name from public.routines where id = '44444444-4444-4444-4444-444444444444'), 'C',
  'A newer client_updated_at applies the update');
select ok(
  (select updated_at from public.routines where id = '44444444-4444-4444-4444-444444444444')
    > (select updated_at from sync_capture where label = 'backdated'),
  'updated_at is set by the trigger and is greater than the old value'
);

-- upsert_workout: replace children, and stale detection ------------------------------------------------------
select is(
  public.upsert_workout('{
    "id": "55555555-5555-5555-5555-555555555555",
    "started_at": "2026-01-01T10:00:00Z",
    "ended_at": "2026-01-01T11:00:00Z",
    "name": "Full Body",
    "client_updated_at": "2026-01-01T11:00:00Z",
    "entries": [
      {"id": "66666666-6666-6666-6666-666666666666", "exercise_id": "0001", "position": 0,
       "sets": [
         {"id": "77777777-7777-7777-7777-777777777777", "position": 0, "w_kg": 60, "r": 8, "done": true},
         {"id": "88888888-8888-8888-8888-888888888888", "position": 1, "w_kg": 60, "r": 8, "done": true}
       ]},
      {"id": "99999999-9999-9999-9999-999999999999", "exercise_id": "0002", "position": 1,
       "sets": [
         {"id": "aaaaaaaa-0000-0000-0000-000000000001", "position": 0, "w_kg": 20, "r": 12, "done": true}
       ]}
    ]
  }'::jsonb) ->> 'status',
  'ok',
  'upsert_workout inserts the workout'
);

select is((select count(*) from public.workout_entries where workout_id = '55555555-5555-5555-5555-555555555555')::int,
  2, 'upsert_workout inserted 2 entries');
select is((select count(*) from public.workout_sets ws join public.workout_entries e on e.id = ws.entry_id
  where e.workout_id = '55555555-5555-5555-5555-555555555555')::int,
  3, 'upsert_workout inserted 3 sets');

-- Upserting again with fewer sets replaces the children (the count drops).
select is(
  public.upsert_workout('{
    "id": "55555555-5555-5555-5555-555555555555",
    "started_at": "2026-01-01T10:00:00Z",
    "ended_at": "2026-01-01T11:05:00Z",
    "name": "Full Body",
    "client_updated_at": "2026-01-01T12:00:00Z",
    "entries": [
      {"id": "66666666-6666-6666-6666-666666666666", "exercise_id": "0001", "position": 0,
       "sets": [{"id": "77777777-7777-7777-7777-777777777777", "position": 0, "w_kg": 65, "r": 6, "done": true}]}
    ]
  }'::jsonb || jsonb_build_object('base_updated_at',
      (select updated_at from public.workouts where id = '55555555-5555-5555-5555-555555555555'))) ->> 'status',
  'ok',
  'upsert_workout replaces the workout on a second call'
);

select is((select count(*) from public.workout_entries where workout_id = '55555555-5555-5555-5555-555555555555')::int,
  1, 'the second upsert_workout call replaced entries (2 -> 1)');
select is((select count(*) from public.workout_sets ws join public.workout_entries e on e.id = ws.entry_id
  where e.workout_id = '55555555-5555-5555-5555-555555555555')::int,
  1, 'the second upsert_workout call replaced sets (3 -> 1)');

-- An older client_updated_at returns {"status":"stale"} and does not change anything.
select is(
  public.upsert_workout('{
    "id": "55555555-5555-5555-5555-555555555555",
    "started_at": "2026-01-01T10:00:00Z",
    "ended_at": "2026-01-01T11:05:00Z",
    "name": "Stale Write",
    "client_updated_at": "2026-01-01T09:00:00Z",
    "entries": []
  }'::jsonb) ->> 'status',
  'stale',
  'a stale upsert_workout call (older client_updated_at) returns status stale'
);

select is((select name from public.workouts where id = '55555555-5555-5555-5555-555555555555'), 'Full Body',
  'a stale upsert_workout call does not change the stored workout');
select is((select count(*) from public.workout_entries where workout_id = '55555555-5555-5555-5555-555555555555')::int,
  1, 'a stale upsert_workout call does not change the entries');

-- Check constraints reject an out-of-range w_kg.
select throws_ok(
  $$ insert into public.workout_sets (id, entry_id, position, w_kg, r)
     values ('bbbbbbbb-0000-0000-0000-000000000002', '66666666-6666-6666-6666-666666666666', 99, 2000, 5) $$,
  '23514'::char(5), null,
  'the w_kg check constraint rejects 2000 kg'
);

select * from finish();
rollback;
