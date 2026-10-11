-- MCP audit log: a user (app or MCP-client session) sees and can insert only their own audit rows;
-- mcp_calls_last_minute() counts only the caller's own trailing-minute rows; anon has no access at all.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email, aud, role) values
  ('66666666-1111-1111-1111-666666666666', 'audit-a@test.local', 'authenticated', 'authenticated'),
  ('66666666-2222-2222-2222-666666666666', 'audit-b@test.local', 'authenticated', 'authenticated');

-- A's app session inserts an audit row for itself.
set local role authenticated;
set local request.jwt.claims = '{"sub":"66666666-1111-1111-1111-666666666666","role":"authenticated"}';
insert into public.mcp_audit (tool, ok, args_digest) values ('get_plan', true, 'digest-1');

select is((select count(*) from public.mcp_audit)::int, 1, 'A sees their own 1 audit row');

-- A's MCP-client session (JWT carries client_id) can also insert and read its own audit rows.
set local request.jwt.claims =
  '{"sub":"66666666-1111-1111-1111-666666666666","role":"authenticated","client_id":"claude-test"}';
insert into public.mcp_audit (tool, ok, args_digest, client_id)
values ('list_workouts', true, 'digest-2', 'claude-test');

select is((select count(*) from public.mcp_audit)::int, 2, 'MCP client can insert and read its own audit rows');

-- B's session inserts its own row and cannot see A's rows.
set local request.jwt.claims = '{"sub":"66666666-2222-2222-2222-666666666666","role":"authenticated"}';
insert into public.mcp_audit (tool, ok) values ('get_profile', false);

select is((select count(*) from public.mcp_audit)::int, 1, 'B sees only their own 1 audit row');

-- B cannot insert an audit row on A's behalf (RLS check on user_id).
select throws_ok(
  $$ insert into public.mcp_audit (user_id, tool, ok)
     values ('66666666-1111-1111-1111-666666666666', 'get_plan', true) $$,
  '42501'::char(5), null,
  'B cannot insert an audit row for A'
);

-- mcp_calls_last_minute() counts only the caller's own rows in the trailing minute.
select is(public.mcp_calls_last_minute(), 1, 'B has made 1 call in the last minute');

set local request.jwt.claims = '{"sub":"66666666-1111-1111-1111-666666666666","role":"authenticated"}';
select is(public.mcp_calls_last_minute(), 2, 'A has made 2 calls in the last minute');

-- anon has no access at all: no table grants, no function grant.
reset role;
select ok(not has_table_privilege('anon', 'public.mcp_audit', 'select'), 'anon cannot select mcp_audit');
select ok(not has_table_privilege('anon', 'public.mcp_audit', 'insert'), 'anon cannot insert into mcp_audit');
select ok(not has_function_privilege('anon', 'public.mcp_calls_last_minute()', 'execute'),
  'anon cannot execute mcp_calls_last_minute');

select * from finish();
rollback;
