-- Plan 06 security-review fixes:
--   * mcp_read_plan: a profile flag (default true) gating what MCP clients may read of the plan and profile
--     (profiles, routines, week_schedule, custom_exercises). The app's own session is unaffected.
--   * mcp_take_call(): an atomic rate-limit slot for the MCP Edge Function (replaces its check-then-insert on
--     mcp_calls_last_minute()). Calls are serialized per user with a transaction-scoped advisory lock, counted in
--     the trailing minute and recorded in mcp_calls only when allowed.

-- mcp_read_plan -------------------------------------------------------------------------------------------------
alter table public.profiles add column mcp_read_plan boolean not null default true;

-- SECURITY DEFINER (as before) so an MCP client can evaluate its flags even when profiles is hidden from it.
create or replace function public.mcp_flag(flag text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select case flag
      when 'workouts' then mcp_read_workouts when 'body' then mcp_read_body when 'propose' then mcp_propose
      when 'plan' then mcp_read_plan end
    from public.profiles where user_id = auth.uid()), true)
$$;
revoke execute on function public.mcp_flag(text) from public, anon;
grant execute on function public.mcp_flag(text) to authenticated;

drop policy profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (user_id = auth.uid() and (not public.is_mcp_client() or public.mcp_flag('plan')));

do $$
declare t text;
begin
  foreach t in array array['custom_exercises','routines','week_schedule'] loop
    execute format('drop policy %1$s_select on public.%1$I', t);
    execute format('create policy %1$s_select on public.%1$I for select to authenticated using (user_id = auth.uid() and (not public.is_mcp_client() or public.mcp_flag(''plan'')))', t);
  end loop;
end $$;

-- Atomic MCP rate limit -----------------------------------------------------------------------------------------
create table public.mcp_calls (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  at timestamptz not null default now()
);
create index mcp_calls_user_at on public.mcp_calls (user_id, at desc);

alter table public.mcp_calls enable row level security;
create policy mcp_calls_select on public.mcp_calls for select to authenticated using (user_id = auth.uid());
-- The invoker needs insert/delete for mcp_take_call(), and an OAuth client can reach this table over PostgREST
-- directly: it may only record a call stamped now and only delete expired rows, so it can't reset its budget.
create policy mcp_calls_insert on public.mcp_calls for insert to authenticated
  with check (user_id = auth.uid() and at = now());
create policy mcp_calls_delete on public.mcp_calls for delete to authenticated
  using (user_id = auth.uid() and at <= now() - interval '1 minute');

-- Takes one call slot for the caller: true (and the call is recorded) while fewer than 60 calls were taken in the
-- trailing minute, false otherwise. Concurrent calls for one user serialize on the advisory lock, so the count and
-- the insert are one atomic step; the lock is released at the end of the (PostgREST request) transaction.
create or replace function public.mcp_take_call() returns boolean
language plpgsql volatile security invoker set search_path = public as $$
declare
  uid uuid := auth.uid();
  taken int;
begin
  if uid is null then raise exception 'not allowed' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mcp_take_call:' || uid::text, 0));
  delete from public.mcp_calls where user_id = uid and at <= now() - interval '1 minute';
  select count(*) into taken from public.mcp_calls where user_id = uid;
  if taken >= 60 then return false; end if;
  insert into public.mcp_calls (user_id) values (uid);
  return true;
end $$;

revoke all on public.mcp_calls from public, anon, authenticated;
revoke all on sequence public.mcp_calls_id_seq from public, anon, authenticated;
revoke all on function public.mcp_take_call() from public, anon, authenticated;
grant select, insert, delete on public.mcp_calls to authenticated;
grant usage on sequence public.mcp_calls_id_seq to authenticated;
grant execute on function public.mcp_take_call() to authenticated;
