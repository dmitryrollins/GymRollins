-- RLS isolation: two users, cross-user reads/writes, exercise library visibility, account deletion cascade.
begin;
create extension if not exists pgtap with schema extensions;
select plan(23);

-- Fixtures: two auth users (as postgres, RLS does not apply to the table owner).
insert into auth.users (id, email, aud, role) values
  ('11111111-1111-1111-1111-111111111111', 'a@test.local', 'authenticated', 'authenticated'),
  ('22222222-2222-2222-2222-222222222222', 'b@test.local', 'authenticated', 'authenticated');

-- Act as user A (app session): insert a routine, a bodyweight entry and a workout (via upsert_workout).
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

insert into public.routines (id, name, exercises, client_updated_at)
values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Push Day', '[]'::jsonb, now());

insert into public.bodyweight (id, measured_at, w_kg, client_updated_at)
values ('cccccccc-cccc-cccc-cccc-cccccccccccc', now(), 82.5, now());

select is(
  public.upsert_workout('{
    "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    "started_at": "2026-01-01T10:00:00Z",
    "ended_at": "2026-01-01T11:00:00Z",
    "name": "Push Day",
    "client_updated_at": "2026-01-01T11:00:00Z",
    "entries": [
      {"id": "dddddddd-dddd-dddd-dddd-dddddddddddd", "exercise_id": "0001", "position": 0,
       "sets": [{"id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", "position": 0, "w_kg": 60, "r": 8, "done": true}]}
    ]
  }'::jsonb) ->> 'status',
  'ok',
  'A can upsert_workout their own workout'
);

select is((select count(*) from public.routines)::int, 1, 'A sees their own 1 routine');
select is((select count(*) from public.bodyweight)::int, 1, 'A sees their own 1 bodyweight entry');
select is((select count(*) from public.workouts)::int, 1, 'A sees their own 1 workout');

-- Act as user B: none of A's rows are visible.
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';

select is((select count(*) from public.routines)::int, 0, 'B sees 0 routines (A''s routine is hidden)');
select is((select count(*) from public.bodyweight)::int, 0, 'B sees 0 bodyweight entries (A''s entry is hidden)');
select is((select count(*) from public.workouts)::int, 0, 'B sees 0 workouts (A''s workout is hidden)');
select is((select count(*) from public.workout_entries)::int, 0, 'B sees 0 workout_entries (A''s entry is hidden)');

with updated as (
  update public.routines set name = 'hacked' where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' returning 1
)
select is((select count(*) from updated)::int, 0, 'B updating A''s routine affects 0 rows');

select is((select count(*) from public.exercises)::int, 1324, 'B sees all 1324 library exercises');

-- Back to A: the exercise library is visible too.
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
select is((select count(*) from public.exercises)::int, 1324, 'A sees all 1324 library exercises');

-- Give B their own data, so we can prove account deletion leaves it intact.
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';

insert into public.routines (id, name, exercises, client_updated_at)
values ('ffffffff-ffff-ffff-ffff-ffffffffffff', 'Leg Day', '[]'::jsonb, now());

insert into public.bodyweight (id, measured_at, w_kg, client_updated_at)
values ('11111111-aaaa-aaaa-aaaa-111111111111', now(), 70, now());

select is(
  public.upsert_workout('{
    "id": "22222222-aaaa-aaaa-aaaa-222222222222",
    "started_at": "2026-01-02T10:00:00Z",
    "ended_at": "2026-01-02T11:00:00Z",
    "name": "Leg Day",
    "client_updated_at": "2026-01-02T11:00:00Z",
    "entries": []
  }'::jsonb) ->> 'status',
  'ok',
  'B can upsert_workout their own workout'
);

select is((select count(*) from public.routines)::int, 1, 'B sees their own 1 routine');
select is((select count(*) from public.bodyweight)::int, 1, 'B sees their own 1 bodyweight entry');
select is((select count(*) from public.workouts)::int, 1, 'B sees their own 1 workout');

-- A deletes their own account.
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
select lives_ok($$ select public.delete_my_account() $$, 'A can delete their own account');

-- Back to postgres: A's rows are gone (cascaded from auth.users), B's rows are untouched.
reset role;

select is((select count(*) from public.routines where user_id = '11111111-1111-1111-1111-111111111111')::int, 0,
  'A''s routines are removed after delete_my_account');
select is((select count(*) from public.workouts where user_id = '11111111-1111-1111-1111-111111111111')::int, 0,
  'A''s workouts are removed after delete_my_account');
select is((select count(*) from public.workout_sets where user_id = '11111111-1111-1111-1111-111111111111')::int, 0,
  'A''s workout_sets are removed after delete_my_account');
select is((select count(*) from public.bodyweight where user_id = '11111111-1111-1111-1111-111111111111')::int, 0,
  'A''s bodyweight entries are removed after delete_my_account');

select is((select count(*) from public.routines where user_id = '22222222-2222-2222-2222-222222222222')::int, 1,
  'B''s routine is intact after A''s account deletion');
select is((select count(*) from public.workouts where user_id = '22222222-2222-2222-2222-222222222222')::int, 1,
  'B''s workout is intact after A''s account deletion');
select is((select count(*) from public.bodyweight where user_id = '22222222-2222-2222-2222-222222222222')::int, 1,
  'B''s bodyweight entry is intact after A''s account deletion');

select * from finish();
rollback;
