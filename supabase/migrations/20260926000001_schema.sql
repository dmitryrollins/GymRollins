-- GymRollins schema. Weights in kg. All user tables: RLS by auth.uid(); MCP OAuth clients (JWT has client_id)
-- are read-only except proposals (and bodyweight when allowed).

create extension if not exists pgcrypto;

-- Helpers -------------------------------------------------------------------------------------------------------
create or replace function public.is_mcp_client() returns boolean
language sql stable as $$ select coalesce(auth.jwt() ->> 'client_id', '') <> '' $$;

create or replace function public.set_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

-- Skip updates older than the stored edit time (last write wins by device edit time).
create or replace function public.lww_guard() returns trigger
language plpgsql as $$
begin
  if new.client_updated_at < old.client_updated_at then return null; end if;
  return new;
end $$;

-- Profiles ------------------------------------------------------------------------------------------------------
create table public.profiles (
  user_id uuid primary key default auth.uid() references auth.users on delete cascade,
  unit text not null default 'lb' check (unit in ('kg','lb')),
  rest_sec int not null default 120 check (rest_sec between 0 and 900),
  warmup_rest_sec int not null default 60 check (warmup_rest_sec between 0 and 900),
  height_cm numeric check (height_cm between 100 and 250),
  goal_weight_kg numeric check (goal_weight_kg between 30 and 300),
  goal_date date,
  training_days int not null default 4 check (training_days between 1 and 7),
  experience text not null default 'intermediate',
  limits text not null default '' check (length(limits) <= 500),
  deload_pct numeric not null default 0.05 check (deload_pct between 0 and 0.5),
  bar_kg numeric not null default 20.411656,
  plates_kg numeric[] not null default '{20.411656,15.87573,11.339809,4.535924,2.267962,1.133981}',
  dumbbell_step_kg numeric not null default 1.133981,
  mcp_read_workouts boolean not null default true,
  mcp_read_body boolean not null default true,
  mcp_propose boolean not null default true,
  mcp_auto_apply boolean not null default false,
  client_updated_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Exercise library (global, read-only for users) -----------------------------------------------------------------
create table public.exercises (
  id text primary key,
  n text not null, bp text not null, eq text not null, tg text not null,
  mg text, sm text[] not null default '{}', st text[] not null default '{}'
);

create table public.custom_exercises (
  id text primary key check (id like 'custom-%'),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  n text not null check (length(n) between 1 and 80),
  bp text not null, eq text not null, tg text not null,
  mode text not null default 'reps' check (mode in ('reps','time','cardio')),
  bilateral boolean not null default false,
  client_updated_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

-- Plan ----------------------------------------------------------------------------------------------------------
create table public.routines (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  name text not null check (length(name) between 1 and 40),
  emoji text,
  policy text not null default 'double' check (policy in ('off','linear','greyskull','double','time')),
  position int not null default 0,
  paused boolean not null default false,
  exercises jsonb not null default '[]' check (jsonb_typeof(exercises) = 'array' and jsonb_array_length(exercises) <= 20),
  client_updated_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.week_schedule (
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  weekday int not null check (weekday between 1 and 7),
  routine_id uuid references public.routines on delete set null,
  client_updated_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, weekday)
);

-- Workouts (relational children for SQL history queries) ---------------------------------------------------------
create table public.workouts (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  started_at timestamptz not null,
  ended_at timestamptz,
  paused_sec numeric not null default 0 check (paused_sec >= 0),
  routine_id uuid,
  name text not null check (length(name) between 1 and 80),
  source text not null default 'app' check (source in ('app','import')),
  note text,
  vol_kg numeric not null default 0,
  records jsonb not null default '[]',
  client_updated_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index workouts_user_started on public.workouts (user_id, started_at desc);

create table public.workout_entries (
  id uuid primary key,
  workout_id uuid not null references public.workouts on delete cascade,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  exercise_id text not null,
  position int not null,
  note text,
  superset_group text
);
create index workout_entries_user_exercise on public.workout_entries (user_id, exercise_id);

create table public.workout_sets (
  id uuid primary key,
  entry_id uuid not null references public.workout_entries on delete cascade,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  position int not null,
  w_kg numeric not null check (w_kg between 0 and 1000),
  r int not null check (r between 0 and 1000),
  sec int check (sec between 0 and 86400),
  min numeric, dist_m numeric,
  done boolean not null default false,
  warmup boolean not null default false,
  rir numeric, rpe numeric,
  multiplier numeric not null default 1 check (multiplier between 0 and 10),
  completed_at timestamptz
);

-- Body ------------------------------------------------------------------------------------------------------------
create table public.bodyweight (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  measured_at timestamptz not null,
  w_kg numeric not null check (w_kg between 30 and 300),
  bf_pct numeric check (bf_pct between 3 and 60),
  t text,
  client_updated_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

-- Proposals from Claude -------------------------------------------------------------------------------------------
create table public.proposals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  source text not null default 'claude',
  summary text not null check (length(summary) between 1 and 500),
  changes jsonb not null check (jsonb_typeof(changes) = 'array' and jsonb_array_length(changes) between 1 and 25),
  status text not null default 'pending' check (status in ('pending','applied','dismissed','partial')),
  applied_change_ids jsonb not null default '[]',
  resolved_at timestamptz,
  client_updated_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Triggers --------------------------------------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['profiles','custom_exercises','routines','week_schedule','workouts','bodyweight','proposals'] loop
    execute format('create trigger a_lww before update on public.%I for each row execute function public.lww_guard()', t);
    execute format('create trigger b_updated_at before insert or update on public.%I for each row execute function public.set_updated_at()', t);
  end loop;
end $$;

-- RLS -------------------------------------------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.exercises enable row level security;
alter table public.custom_exercises enable row level security;
alter table public.routines enable row level security;
alter table public.week_schedule enable row level security;
alter table public.workouts enable row level security;
alter table public.workout_entries enable row level security;
alter table public.workout_sets enable row level security;
alter table public.bodyweight enable row level security;
alter table public.proposals enable row level security;

create or replace function public.mcp_flag(flag text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select case flag
      when 'workouts' then mcp_read_workouts when 'body' then mcp_read_body when 'propose' then mcp_propose end
    from public.profiles where user_id = auth.uid()), true)
$$;

create policy exercises_read on public.exercises for select to authenticated using (true);

-- Owner full access from the app; MCP clients read-only (gated by flags).
create policy profiles_select on public.profiles for select to authenticated using (user_id = auth.uid());
create policy profiles_write on public.profiles for all to authenticated
  using (user_id = auth.uid() and not public.is_mcp_client()) with check (user_id = auth.uid() and not public.is_mcp_client());

do $$
declare t text;
begin
  foreach t in array array['custom_exercises','routines','week_schedule'] loop
    execute format('create policy %1$s_select on public.%1$I for select to authenticated using (user_id = auth.uid())', t);
    execute format('create policy %1$s_write on public.%1$I for all to authenticated using (user_id = auth.uid() and not public.is_mcp_client()) with check (user_id = auth.uid() and not public.is_mcp_client())', t);
  end loop;
  foreach t in array array['workouts','workout_entries','workout_sets'] loop
    execute format('create policy %1$s_select on public.%1$I for select to authenticated using (user_id = auth.uid() and (not public.is_mcp_client() or public.mcp_flag(''workouts'')))', t);
    execute format('create policy %1$s_write on public.%1$I for all to authenticated using (user_id = auth.uid() and not public.is_mcp_client()) with check (user_id = auth.uid() and not public.is_mcp_client())', t);
  end loop;
end $$;

create policy bodyweight_select on public.bodyweight for select to authenticated
  using (user_id = auth.uid() and (not public.is_mcp_client() or public.mcp_flag('body')));
create policy bodyweight_insert on public.bodyweight for insert to authenticated
  with check (user_id = auth.uid() and (not public.is_mcp_client() or public.mcp_flag('body')));
create policy bodyweight_modify on public.bodyweight for update to authenticated
  using (user_id = auth.uid() and not public.is_mcp_client()) with check (user_id = auth.uid() and not public.is_mcp_client());
create policy bodyweight_delete on public.bodyweight for delete to authenticated
  using (user_id = auth.uid() and not public.is_mcp_client());

create policy proposals_select on public.proposals for select to authenticated using (user_id = auth.uid());
create policy proposals_insert on public.proposals for insert to authenticated
  with check (user_id = auth.uid() and status = 'pending' and (not public.is_mcp_client() or public.mcp_flag('propose')));
create policy proposals_update on public.proposals for update to authenticated
  using (user_id = auth.uid() and not public.is_mcp_client()) with check (user_id = auth.uid() and not public.is_mcp_client());

-- RPC: upsert a whole workout aggregate -------------------------------------------------------------------------
create or replace function public.upsert_workout(payload jsonb) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  wid uuid := (payload ->> 'id')::uuid;
  incoming timestamptz := (payload ->> 'client_updated_at')::timestamptz;
  existing public.workouts;
  e jsonb; s jsonb;
begin
  if auth.uid() is null or public.is_mcp_client() then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into existing from public.workouts where id = wid;
  if found and existing.user_id <> auth.uid() then raise exception 'not allowed' using errcode = '42501'; end if;
  if found and existing.client_updated_at > incoming then
    return jsonb_build_object('status', 'stale', 'updated_at', existing.updated_at);
  end if;

  insert into public.workouts (id, started_at, ended_at, paused_sec, routine_id, name, source, note, vol_kg, records,
                               client_updated_at, deleted_at)
  values (wid, (payload->>'started_at')::timestamptz, (payload->>'ended_at')::timestamptz,
          coalesce((payload->>'paused_sec')::numeric, 0), (payload->>'routine_id')::uuid, payload->>'name',
          coalesce(payload->>'source', 'app'), payload->>'note', coalesce((payload->>'vol_kg')::numeric, 0),
          coalesce(payload->'records', '[]'), incoming, (payload->>'deleted_at')::timestamptz)
  on conflict (id) do update set started_at = excluded.started_at, ended_at = excluded.ended_at,
      paused_sec = excluded.paused_sec, routine_id = excluded.routine_id, name = excluded.name,
      source = excluded.source, note = excluded.note, vol_kg = excluded.vol_kg, records = excluded.records,
      client_updated_at = excluded.client_updated_at, deleted_at = excluded.deleted_at;

  delete from public.workout_entries where workout_id = wid;
  for e in select * from jsonb_array_elements(coalesce(payload->'entries', '[]')) loop
    insert into public.workout_entries (id, workout_id, exercise_id, position, note, superset_group)
    values ((e->>'id')::uuid, wid, e->>'exercise_id', (e->>'position')::int, e->>'note', e->>'superset_group');
    for s in select * from jsonb_array_elements(coalesce(e->'sets', '[]')) loop
      insert into public.workout_sets (id, entry_id, position, w_kg, r, sec, min, dist_m, done, warmup, rir, rpe,
                                       multiplier, completed_at)
      values ((s->>'id')::uuid, (e->>'id')::uuid, (s->>'position')::int, (s->>'w_kg')::numeric, (s->>'r')::int,
              (s->>'sec')::int, (s->>'min')::numeric, (s->>'dist_m')::numeric, coalesce((s->>'done')::boolean, false),
              coalesce((s->>'warmup')::boolean, false), (s->>'rir')::numeric, (s->>'rpe')::numeric,
              coalesce((s->>'multiplier')::numeric, 1), (s->>'completed_at')::timestamptz);
    end loop;
  end loop;

  return jsonb_build_object('status', 'ok', 'updated_at', (select updated_at from public.workouts where id = wid));
end $$;

-- RPC: delete the caller's account and all data (App Store requirement) -----------------------------------------
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null or public.is_mcp_client() then raise exception 'not allowed' using errcode = '42501'; end if;
  delete from auth.users where id = auth.uid();
end $$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
grant execute on function public.upsert_workout(jsonb) to authenticated;
