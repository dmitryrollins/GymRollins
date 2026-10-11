-- Plan 12: weekly hard-set targets per muscle group (Settings → Weekly targets), synced like week_schedule:
-- one row per (user, muscle), no tombstones ("reset to defaults" writes the default values), last write wins by
-- device edit time. Muscle ids are GymCore's MuscleGroup raw values; the set range is
-- DomainLimits.weeklySetTarget (0…50, drift-guarded in _shared/domain-limits.ts).
create table public.muscle_targets (
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  muscle text not null check (muscle in (
    'chest','shoulders','traps','upper_back','lats','lower_back','biceps','triceps','forearms','abs',
    'glutes','quads','hamstrings','calves','adductors','abductors')),
  min_sets int not null check (min_sets between 0 and 50),
  max_sets int not null check (max_sets between 0 and 50),
  client_updated_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, muscle),
  constraint muscle_targets_range check (min_sets <= max_sets)
);

create trigger a_lww before update on public.muscle_targets
  for each row execute function public.lww_guard();
create trigger b_updated_at before insert or update on public.muscle_targets
  for each row execute function public.set_updated_at();

alter table public.muscle_targets enable row level security;

-- Owner reads; an MCP client (Claude) reads only while the owner lets it read the plan. Writes: the app only.
create policy muscle_targets_select on public.muscle_targets for select to authenticated
  using (user_id = auth.uid() and (not public.is_mcp_client() or public.mcp_flag('plan')));
create policy muscle_targets_write on public.muscle_targets for all to authenticated
  using (user_id = auth.uid() and not public.is_mcp_client())
  with check (user_id = auth.uid() and not public.is_mcp_client());

revoke all on public.muscle_targets from anon;
grant select, insert, update, delete on public.muscle_targets to authenticated;
