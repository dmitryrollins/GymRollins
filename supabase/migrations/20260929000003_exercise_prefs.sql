-- Per-exercise recommendation preferences ("Recommend more often / less often / Don't recommend again").
-- One row per (user, exercise); 'normal' is stored rather than deleted, so a reset syncs like any other edit.
-- exercise_id is a library id (public.exercises) or a custom exercise id ('custom-…'); no foreign key, because it
-- may name either table (same as routines.exercises and workout_entries.exercise_id).
-- Same sync rules as every other synced table: last write wins by device edit time (lww_guard), updated_at stamped
-- by the server (pull cursor). RLS: the owner reads and writes from the app; MCP clients may only read, and only
-- while the owner lets Claude read the plan (mcp_read_plan), like routines/week_schedule/custom_exercises.
create table public.exercise_prefs (
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  exercise_id text not null check (exercise_id ~ '^[A-Za-z0-9_-]{1,80}$'),
  pref text not null check (pref in ('more','normal','less','never')),
  client_updated_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, exercise_id)
);
-- Pull cursor: rows changed since the last pull, keyset-ordered by (updated_at, exercise_id).
create index exercise_prefs_user_updated on public.exercise_prefs (user_id, updated_at, exercise_id);

create trigger a_lww before update on public.exercise_prefs
  for each row execute function public.lww_guard();
create trigger b_updated_at before insert or update on public.exercise_prefs
  for each row execute function public.set_updated_at();

alter table public.exercise_prefs enable row level security;
create policy exercise_prefs_select on public.exercise_prefs for select to authenticated
  using (user_id = auth.uid() and (not public.is_mcp_client() or public.mcp_flag('plan')));
create policy exercise_prefs_write on public.exercise_prefs for all to authenticated
  using (user_id = auth.uid() and not public.is_mcp_client())
  with check (user_id = auth.uid() and not public.is_mcp_client());

revoke all on public.exercise_prefs from public, anon;
grant select, insert, update, delete on public.exercise_prefs to authenticated;

-- Which of `ids` the caller marked 'never' ("Don't recommend again"). The MCP server checks every proposal with it
-- (Claude must never add or swap to such an exercise). SECURITY DEFINER so the check also holds when the owner
-- turned mcp_read_plan off (RLS then hides the rows from an MCP client): it reveals only the 'never' flag of the
-- exercises the caller names, for the caller's own account, and to an MCP client only while it may read the plan or
-- propose changes (after Disconnect Claude turns every permission off, an outstanding token learns nothing).
create or replace function public.never_exercise_ids(ids text[]) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(exercise_id order by exercise_id), '{}')
  from public.exercise_prefs
  where user_id = auth.uid() and pref = 'never' and exercise_id = any(ids)
    and (not public.is_mcp_client() or public.mcp_flag('plan') or public.mcp_flag('propose'))
$$;
revoke all on function public.never_exercise_ids(text[]) from public, anon;
grant execute on function public.never_exercise_ids(text[]) to authenticated;
