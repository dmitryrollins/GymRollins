-- MCP OAuth clients (JWT has a client_id claim) are read-mostly: reads are gated by profiles.mcp_* flags, and
-- every write is rejected except inserting a pending proposal (mcp_propose) and inserting bodyweight (mcp_read_body).
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into auth.users (id, email, aud, role) values
  ('55555555-1111-1111-1111-555555555555', 'mcp-owner@test.local', 'authenticated', 'authenticated');

-- Owner (app) session: seed a profile (defaults: mcp_read_workouts/mcp_read_body/mcp_propose = true) and a workout.
set local role authenticated;
set local request.jwt.claims = '{"sub":"55555555-1111-1111-1111-555555555555","role":"authenticated"}';

insert into public.profiles (user_id) values ('55555555-1111-1111-1111-555555555555');

select public.upsert_workout('{
  "id": "55555555-2222-2222-2222-555555555555",
  "started_at": "2026-01-01T10:00:00Z",
  "ended_at": "2026-01-01T11:00:00Z",
  "name": "Push Day",
  "client_updated_at": "2026-01-01T11:00:00Z",
  "entries": []
}'::jsonb);

-- Now act as an MCP OAuth client for the same user (JWT carries a client_id claim).
set local request.jwt.claims =
  '{"sub":"55555555-1111-1111-1111-555555555555","role":"authenticated","client_id":"claude-test"}';

select is((select count(*) from public.workouts)::int, 1,
  'MCP client can read workouts when mcp_read_workouts is true');

-- The owner turns mcp_read_workouts off (back to the app session to make the change).
set local request.jwt.claims = '{"sub":"55555555-1111-1111-1111-555555555555","role":"authenticated"}';
update public.profiles set mcp_read_workouts = false where user_id = '55555555-1111-1111-1111-555555555555';
set local request.jwt.claims =
  '{"sub":"55555555-1111-1111-1111-555555555555","role":"authenticated","client_id":"claude-test"}';

select is((select count(*) from public.workouts)::int, 0,
  'MCP client reads 0 workouts once mcp_read_workouts is false');

-- Writes are rejected for MCP clients: routines insert, profiles update, upsert_workout.
select throws_ok(
  $$ insert into public.routines (id, name, exercises, client_updated_at)
     values ('55555555-3333-3333-3333-555555555555', 'MCP Routine', '[]'::jsonb, now()) $$,
  '42501'::char(5), null,
  'MCP client cannot insert a routine'
);

with updated as (
  update public.profiles set unit = 'kg' where user_id = '55555555-1111-1111-1111-555555555555' returning 1
)
select is((select count(*) from updated)::int, 0, 'MCP client updating the owner''s profile affects 0 rows');

select throws_ok(
  $$ select public.upsert_workout('{
       "id": "55555555-4444-4444-4444-555555555555",
       "started_at": "2026-01-01T10:00:00Z",
       "name": "MCP Workout",
       "client_updated_at": "2026-01-01T11:00:00Z",
       "entries": []
     }'::jsonb) $$,
  '42501'::char(5), null,
  'MCP client cannot call upsert_workout'
);

-- Proposals: inserting a pending proposal works (mcp_propose defaults to true).
insert into public.proposals (id, summary, changes)
values ('55555555-5555-5555-5555-555555555555', 'Increase bench weight', '[{"type":"weight"}]'::jsonb);

select is(
  (select count(*) from public.proposals
     where user_id = '55555555-1111-1111-1111-555555555555' and status = 'pending')::int,
  1,
  'MCP client can insert a pending proposal when mcp_propose is true'
);

-- Inserting with a non-pending status fails.
select throws_ok(
  $$ insert into public.proposals (id, summary, changes, status)
     values ('55555555-6666-6666-6666-555555555555', 'Already applied', '[{"type":"weight"}]'::jsonb, 'applied') $$,
  '42501'::char(5), null,
  'MCP client cannot insert a proposal with status other than pending'
);

-- The owner turns mcp_propose off; a further proposal insert fails.
set local request.jwt.claims = '{"sub":"55555555-1111-1111-1111-555555555555","role":"authenticated"}';
update public.profiles set mcp_propose = false where user_id = '55555555-1111-1111-1111-555555555555';
set local request.jwt.claims =
  '{"sub":"55555555-1111-1111-1111-555555555555","role":"authenticated","client_id":"claude-test"}';

select throws_ok(
  $$ insert into public.proposals (id, summary, changes)
     values ('55555555-7777-7777-7777-555555555555', 'Blocked proposal', '[{"type":"weight"}]'::jsonb) $$,
  '42501'::char(5), null,
  'MCP client cannot insert a proposal once mcp_propose is false'
);

-- Bodyweight: insert works only when mcp_read_body is true.
insert into public.bodyweight (id, measured_at, w_kg)
values ('55555555-8888-8888-8888-555555555555', now(), 80);

select is((select count(*) from public.bodyweight
  where user_id = '55555555-1111-1111-1111-555555555555')::int, 1,
  'MCP client can insert bodyweight when mcp_read_body is true');

set local request.jwt.claims = '{"sub":"55555555-1111-1111-1111-555555555555","role":"authenticated"}';
update public.profiles set mcp_read_body = false where user_id = '55555555-1111-1111-1111-555555555555';
set local request.jwt.claims =
  '{"sub":"55555555-1111-1111-1111-555555555555","role":"authenticated","client_id":"claude-test"}';

select throws_ok(
  $$ insert into public.bodyweight (id, measured_at, w_kg)
     values ('55555555-9999-9999-9999-555555555555', now(), 81) $$,
  '42501'::char(5), null,
  'MCP client cannot insert bodyweight once mcp_read_body is false'
);

-- delete_my_account is rejected outright for MCP clients.
select throws_ok(
  $$ select public.delete_my_account() $$,
  '42501'::char(5), null,
  'MCP client cannot call delete_my_account'
);

select * from finish();
rollback;
