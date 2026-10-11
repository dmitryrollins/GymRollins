-- Plan 06: MCP audit log + rate-limit helper. Every MCP tool call (read or write) is audited by the Edge
-- Function; mcp_calls_last_minute() backs the 60/min rate limit enforced there. Matches the revoke/grant
-- pattern from 20260927000002_security_fixes.sql: anon (and PUBLIC) get nothing here, explicitly; authenticated
-- gets exactly what it needs, explicitly granted (default privileges for postgres-created objects already
-- exclude anon per that migration, but this stays explicit rather than relying on it).

create table public.mcp_audit (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  client_id text,
  tool text not null,
  ok boolean not null,
  args_digest text,
  at timestamptz not null default now()
);
create index mcp_audit_user_at on public.mcp_audit (user_id, at desc);

alter table public.mcp_audit enable row level security;
create policy mcp_audit_select on public.mcp_audit for select to authenticated using (user_id = auth.uid());
create policy mcp_audit_insert on public.mcp_audit for insert to authenticated with check (user_id = auth.uid());

-- Calls in the last minute for the caller (rate limit = 60/min, enforced in the function).
create or replace function public.mcp_calls_last_minute() returns int
language sql stable security invoker set search_path = public as $$
  select count(*)::int from public.mcp_audit where user_id = auth.uid() and at > now() - interval '1 minute'
$$;

-- Explicit grants: revoke the default (broader) grant from authenticated too, then re-grant exactly what's
-- needed, so table-level privileges match the RLS policies above (select/insert only — no update/delete/
-- truncate) rather than relying on Supabase's default ALL-privileges-to-authenticated grant. anon (and PUBLIC)
-- get nothing at all.
revoke all on public.mcp_audit from public, anon, authenticated;
revoke all on sequence public.mcp_audit_id_seq from public, anon, authenticated;
revoke all on function public.mcp_calls_last_minute() from public, anon, authenticated;
grant select, insert on public.mcp_audit to authenticated;
grant usage on sequence public.mcp_audit_id_seq to authenticated;
grant execute on function public.mcp_calls_last_minute() to authenticated;
