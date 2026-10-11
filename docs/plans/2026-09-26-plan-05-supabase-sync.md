# Plan 05: Supabase backend (local), auth, offline-first sync

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local Supabase backend (Postgres schema, RLS, last-write-wins guards, MCP-client write restrictions,
workout upsert RPC, account deletion) with database tests, plus a `GymSync` Swift package (DTOs, auth, sync engine)
wired into the app. Workouts, routines, the week schedule, bodyweight, profile and custom exercises sync both ways,
and logging works fully offline.

**Architecture:**
- **Aggregates sync as units** (spec change, recorded in Task 1). A routine stores its exercises as `jsonb`, and a
  workout is written through the `upsert_workout(payload)` RPC, which replaces entries/sets in one transaction.
  Workout sets stay relational so the MCP server (plan 06) can query history with SQL.
- **Conflict rule:** every row carries `client_updated_at` (the device edit time). A `BEFORE UPDATE` trigger skips
  updates whose `client_updated_at` is older than the stored one (last write wins, by edit time). `upsert_workout`
  returns `stale` instead of skipping silently, so the app can offer "Keep this iPhone's / Keep other".
- **Proposals are applied on the device**, not in SQL (spec change). The app validates with GymCore's
  `PlanChangeValidator`, applies with `PlanChangeApplier` (plan 06), then syncs the changed routines. Auto-apply
  happens the next time the app syncs.
- **MCP clients are read-mostly at the database level:** OAuth tokens carry a `client_id` claim. RLS denies writes to
  every table for such tokens except inserting `proposals` (and `bodyweight` when allowed), and filters reads by the
  profile's `mcp_read_*` flags. This is defense in depth under the MCP server's own checks.
- **GymSync** (a new Swift package, depending on GymData, GymCore and supabase-swift) owns the DTOs, `AuthService`,
  `SupabaseTransport` and `SyncEngine`. GymData gains a `SyncStore` facade (dirty rows out, remote rows in) so the
  engine never touches `@Model` classes.

**Tech Stack:** Supabase CLI 2.118 (`npx supabase`), Postgres 17, pgTAP, supabase-swift 2.55.x, Swift 6.2,
Swift Testing, XCUITest. Docker via colima (`colima start --cpu 4 --memory 6`).

**Depends on:** Plans 02–04 merged. **Spec:** §2, §4, §5 Sync/Auth, §8 Security.

**Conventions:** Branch `plan-05-supabase-sync`. Commit per task with the trailer lines. Never `git add -A`. Local
Supabase only; **never** run commands against a cloud project (no `supabase link`, no `db push`). Secrets: the local
anon key is public by design; never commit the service-role key. Tests read it from `npx supabase status -o env`.

---

## File structure

```
app/supabase/
  config.toml
  migrations/20260926000001_schema.sql        tables, triggers, RLS, RPCs
  migrations/20260926000002_exercises_seed.sql generated library rows (from exercises.json)
  tests/database/rls.test.sql
  tests/database/sync.test.sql
  tests/database/mcp_client.test.sql
scripts/
  gen-exercise-seed.mjs                         exercises.json -> migration SQL
  supabase-up.sh                                colima + supabase start + status env file
  test-db.sh                                    supabase test db
ios/Packages/GymData/Sources/GymData/Sync/
  SyncStore.swift                               dirty rows out, remote rows in, cursors
  SyncModels.swift                              SyncRow<T>, SyncCursor, ConflictResolution
ios/Packages/GymSync/
  Package.swift
  Sources/GymSync/DTO/*.swift                    ProfileDTO, RoutineDTO, WeekdayDTO, WorkoutDTO, BodyweightDTO, CustomExerciseDTO, ProposalDTO
  Sources/GymSync/SupabaseConfig.swift
  Sources/GymSync/AuthService.swift
  Sources/GymSync/SyncTransport.swift           protocol + SupabaseTransport
  Sources/GymSync/SyncEngine.swift
  Tests/GymSyncTests/DTOTests.swift, SyncEngineTests.swift (fake transport)
  Tests/GymSyncIntegrationTests/SupabaseTransportTests.swift (skips unless SUPABASE_URL set)
ios/GymRollins/
  App/AppEnvironment.swift                      (modify) auth + sync lifecycle
  Features/Account/AccountView.swift            sign in/out, sync now, status (folded into Settings in plan 07)
  Features/Sync/SyncStatusBanner.swift          offline / syncing / conflict capsule
  Features/Sync/ConflictSheet.swift
ios/GymRollinsUITests/SyncUITests.swift
```

---

### Task 1: Supabase project, schema, RLS, RPCs

**Files:** `supabase/config.toml` (via `npx supabase init`), `supabase/migrations/20260926000001_schema.sql`,
`scripts/supabase-up.sh`, `scripts/test-db.sh`; modify the spec §4/§5 to record the two spec changes above.

- [ ] **Step 1:** `git checkout main && git checkout -b plan-05-supabase-sync && npx --yes supabase@2.118.0 init`
  (answer no to IDE settings). **Ports:** another project (portal-headshots) already runs local Supabase on the default
  5432x ports, and it must not be touched. So move every GymRollins port to 554xx in `config.toml`:
  `[api] port = 55421`, `[db] port = 55422`, `[db] shadow_port = 55420`, `[db.pooler] port = 55429`,
  `[studio] port = 55423`, `[inbucket] port = 55424`, `[analytics] port = 55427`,
  `[edge_runtime] inspector_port = 55483`. Everything below that says 54321 means **55421**.
  In `supabase/config.toml` set `project_id = "gymrollins"`,
  `[auth] site_url = "http://127.0.0.1:55421/functions/v1/oauth-consent"`, `enable_signup = true`,
  `[auth.email] enable_confirmations = false`, and add:
  ```toml
  [auth.oauth_server]
  enabled = true
  authorization_url_path = "/oauth/consent"
  allow_dynamic_registration = true
  ```
  (The consent page itself is plan 06. Keep `[auth.external.apple] enabled = false` locally with a comment: it's
  enabled with real Services ID credentials when a cloud project exists.)

- [ ] **Step 2: scripts**

`scripts/supabase-up.sh`:
```bash
#!/usr/bin/env bash
# Starts Docker (colima) and local Supabase; writes connection env to supabase/.env.local (gitignored).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
colima status >/dev/null 2>&1 || colima start --cpu 4 --memory 6
cd "$ROOT"
npx --yes supabase@2.118.0 start >/dev/null
npx --yes supabase@2.118.0 status -o env > supabase/.env.local
echo "Supabase running. Env written to supabase/.env.local"
```
`scripts/test-db.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" && npx --yes supabase@2.118.0 db reset >/dev/null && npx --yes supabase@2.118.0 test db
```
Add `supabase/.env.local` and `supabase/.temp/` to `.gitignore`.

- [ ] **Step 3: Migration** `supabase/migrations/20260926000001_schema.sql`

```sql
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
```

- [ ] **Step 4:** `scripts/supabase-up.sh && npx supabase db reset` → migrations apply cleanly.
- [ ] **Step 5: Commit** `feat(db): schema, RLS with MCP-client restrictions, LWW guard, workout upsert, account deletion`

---

### Task 2: Exercise seed migration

**Files:** `scripts/gen-exercise-seed.mjs`, `supabase/migrations/20260926000002_exercises_seed.sql` (generated, committed).

```js
#!/usr/bin/env node
// exercises.json (bundled in the app) -> SQL migration so the MCP server can search the same library.
import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
const root = resolve(import.meta.dirname, '..')
const rows = JSON.parse(readFileSync(resolve(root, 'ios/GymRollins/Resources/exercises.json'), 'utf8'))
const q = s => s == null ? 'null' : `'${String(s).replaceAll("'", "''")}'`
const arr = a => `array[${(a ?? []).map(q).join(',')}]::text[]`
const values = rows.map(e => `(${q(e.id)},${q(e.n)},${q(e.bp)},${q(e.eq)},${q(e.tg)},${q(e.mg)},${arr(e.sm)},${arr(e.st)})`)
writeFileSync(resolve(root, 'supabase/migrations/20260926000002_exercises_seed.sql'),
  `-- Generated by scripts/gen-exercise-seed.mjs. Exercise names/instructions: hasaneyldrm/exercises-dataset (MIT).\n` +
  `insert into public.exercises (id,n,bp,eq,tg,mg,sm,st) values\n${values.join(',\n')}\non conflict (id) do nothing;\n`)
console.log(`Seeded ${rows.length} exercises`)
```
Run it, then `npx supabase db reset` and check
`psql "$DB_URL" -c "select count(*) from exercises"` = 1324 (`DB_URL` from `supabase/.env.local`).
**Commit:** `feat(db): exercise library seed migration`

---

### Task 3: Database tests (pgTAP)

**Files:** `supabase/tests/database/rls.test.sql`, `sync.test.sql`, `mcp_client.test.sql`.

Test helpers inline in each file (no extension needed):
```sql
begin;
create extension if not exists pgtap with schema extensions;
select plan(N);
-- two users
insert into auth.users (id, email, aud, role) values
  ('11111111-1111-1111-1111-111111111111', 'a@test.local', 'authenticated', 'authenticated'),
  ('22222222-2222-2222-2222-222222222222', 'b@test.local', 'authenticated', 'authenticated');
-- act as user A (app session)
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
```
To act as an MCP client, use claims `{"sub":"…1111","role":"authenticated","client_id":"claude-test"}`. Switch users by
running `set local request.jwt.claims` again (reset the role to `postgres` first when inserting fixtures).

Required assertions (write each as a pgTAP `is`, `ok`, `throws_ok` or `lives_ok`):
- **rls.test.sql**: A inserts a routine, a bodyweight entry and a workout (via `upsert_workout`), then B selects
  each table and gets 0 rows; B updating A's routine affects 0 rows; `exercises` count = 1324 for both;
  `delete_my_account()` as A removes A's routines/workouts/sets (count 0 as postgres) and leaves B's data intact.
- **sync.test.sql**: an LWW update with an older `client_updated_at` leaves the row unchanged; a newer one
  applies; `updated_at` is set by the trigger (greater than the old value). `upsert_workout` inserts 2 entries / 3
  sets. Upserting again with fewer sets replaces the children (the count drops). An older `client_updated_at`
  returns `{"status":"stale"}` and doesn't change anything. The check constraints reject `w_kg = 2000`.
- **mcp_client.test.sql**: with MCP claims, selecting workouts works when `mcp_read_workouts` is true and returns 0
  rows after the owner sets it false. Inserting into routines, updating profiles and calling `upsert_workout` all
  fail (`throws_ok` with 42501 or an RLS violation). Inserting a pending proposal works, and fails with
  status 'applied' or when `mcp_propose` is false. A bodyweight insert works only when `mcp_read_body` is true.
  `delete_my_account()` is rejected.

Run `scripts/test-db.sh` → all pass. **Commit:** `test(db): RLS isolation, LWW/stale sync, MCP client restrictions`

---

### Task 4: GymData SyncStore

**Files:** `GymData/Sources/GymData/Sync/SyncModels.swift`, `Sync/SyncStore.swift`; Test `GymDataTests/SyncStoreTests.swift`.

`SyncStore` (`@MainActor`) is the only sync-facing API over SwiftData:
```swift
public struct SyncRow<Value: Sendable>: Sendable { public let value: Value; public let clientUpdatedAt: Date; public let deletedAt: Date? }
public enum SyncEntity: String, CaseIterable, Sendable { case profile, customExercises, routines, weekSchedule, workouts, bodyweight }

@MainActor public final class SyncStore {
    public init(context: ModelContext)
    // Outgoing
    public func dirtyRoutines() throws -> [SyncRow<Routine>]
    public func dirtyWorkouts() throws -> [SyncRow<(workout: Workout, records: [PersonalRecord], volumeKg: Double)>]
    public func dirtyBodyweight() throws -> [SyncRow<BodyweightEntry>]
    public func dirtyProfile() throws -> SyncRow<Profile>?
    public func dirtyWeekdays() throws -> [SyncRow<(weekday: Int, routineId: UUID?)>]
    public func dirtyCustomExercises() throws -> [SyncRow<Exercise>]
    public func markSynced(_ entity: SyncEntity, id: String, serverUpdatedAt: Date) throws  // clears dirty only if updatedAt unchanged since read
    // Incoming (server wins unless the local row is dirty; returns ids skipped as conflicts)
    @discardableResult public func applyRemote(routines: [SyncRow<Routine>], serverUpdatedAt: [UUID: Date]) throws -> [UUID]
    @discardableResult public func applyRemote(workouts: [SyncRow<(workout: Workout, records: [PersonalRecord])>], serverUpdatedAt: [UUID: Date]) throws -> [UUID]
    public func applyRemote(bodyweight: [SyncRow<BodyweightEntry>], serverUpdatedAt: [UUID: Date]) throws
    public func applyRemote(profile: SyncRow<Profile>, serverUpdatedAt: Date) throws
    public func applyRemote(weekdays: [SyncRow<(weekday: Int, routineId: UUID?)>]) throws
    public func applyRemote(customExercises: [SyncRow<Exercise>]) throws
    // Conflict resolution for workouts
    public func resolveWorkoutConflict(id: UUID, keepLocal: Bool, remote: Workout?) throws
    // Cursors (stored in UserDefaults suite injected in init for tests)
    public func cursor(for entity: SyncEntity) -> Date?
    public func setCursor(_ date: Date, for entity: SyncEntity)
    public func resetAll() throws   // sign-out / account deletion: wipe all records + cursors
}
```
Key rules (each covered by a test in `SyncStoreTests`):
1. `dirty*` returns tombstoned rows too (`deletedAt` set) so deletions sync.
2. `markSynced` clears `dirty` and sets `serverUpdatedAt`, but only if the record's `updatedAt` equals the
   `clientUpdatedAt` that was pushed. An edit made during the push keeps the row dirty.
3. `applyRemote` inserts new rows and overwrites clean rows. **Dirty local rows are left alone** and their ids
   returned as conflicts (workouts) or re-pushed next round (others). Remote tombstones set `deletedAt` locally.
4. Applying remote rows never marks them dirty.
5. The active workout is never returned by `dirtyWorkouts()` and is never overwritten by `applyRemote`.
6. `resetAll` empties every model and the cursors.

Write the tests first (in-memory container, `UserDefaults(suiteName: "test-\(UUID())")`), then implement. Keep the
file under 400 lines by splitting per entity into `SyncStore+Routines.swift` etc. if needed. **Commit:**
`feat(data): sync store for dirty rows, remote apply, cursors`

---

### Task 5: GymSync package — DTOs, transport, engine (fake-transport tests)

**Files:** `ios/Packages/GymSync/**`.

- [ ] `Package.swift`: dependencies `../GymCore`, `../GymData`,
  `.package(url: "https://github.com/supabase/supabase-swift", from: "2.55.0")`. Targets `GymSync` (product
  `Supabase`), `GymSyncTests`, and `GymSyncIntegrationTests`.
- [ ] **DTOs** (`Codable`, snake_case keys matching the SQL columns exactly) with `init(_ domain…)` and
  `func toDomain()` for each entity. `WorkoutDTO` includes nested `entries[].sets[]` for the RPC payload, and decodes
  the PostgREST embed shape `workout_entries(*, workout_sets(*))` on pull. Dates are ISO 8601 with fractional
  seconds. `DTOTests`: round trip every DTO ↔ domain; decode a captured PostgREST JSON sample for workouts.
- [ ] **SyncTransport** protocol:
```swift
public protocol SyncTransport: Sendable {
    func push(routines: [RoutineDTO]) async throws -> [RowAck]           // upsert on_conflict=id, returning id,updated_at
    func push(workout: WorkoutDTO) async throws -> WorkoutPushResult     // rpc upsert_workout -> .ok(updatedAt) | .stale(updatedAt)
    func push(bodyweight: [BodyweightDTO]) async throws -> [RowAck]
    func push(profile: ProfileDTO) async throws -> RowAck
    func push(weekdays: [WeekdayDTO]) async throws -> [RowAck]
    func push(customExercises: [CustomExerciseDTO]) async throws -> [RowAck]
    func pull<T: Decodable & Sendable>(_ entity: SyncEntity, since: Date?, as: T.Type) async throws -> [T]  // updated_at > since, ordered asc, limit 500 pages
    func pendingProposals() async throws -> [ProposalDTO]
    func resolveProposal(id: UUID, status: String, appliedChangeIds: [String], at: Date) async throws
}
```
`SupabaseTransport` implements it with `SupabaseClient` (`from("routines").upsert(dtos, onConflict: "id").select("id,updated_at")`,
`rpc("upsert_workout", params: ["payload": dto])`, and
`from("workouts").select("*, workout_entries(*, workout_sets(*))").gt("updated_at", value: iso).order("updated_at")`).
- [ ] **SyncEngine** (`@MainActor @Observable`): `status: SyncStatus` (`.idle`, `.syncing`, `.offline`,
  `.error(String)`, `.conflicts([UUID])`), `lastSyncedAt`, and `func sync() async`. Order: push the profile, custom
  exercises, routines, weekdays, bodyweight, then workouts (one RPC each; `stale` → conflict), then pull each entity
  since its cursor and apply. Cursor = max(`updated_at`) seen. URL errors → `.offline` (local data untouched). It
  never runs two syncs at once (a flag, or an actor-isolated task). `func resolve(conflict:keepLocal:)` either
  re-pushes local with `client_updated_at = now` or applies the remote.
- [ ] **SyncEngineTests** with an in-memory `FakeTransport` (a dictionary-backed server that implements the LWW/stale
  rules like the SQL): (1) the first sync pushes all dirty rows and marks them synced; (2) a remote-only row is pulled
  and appears locally; (3) editing the same workout on the "server" and locally leads to `.conflicts([id])`, then
  `resolve(keepLocal: true)` makes the server hold the local version; (4) a transport throwing `URLError(.notConnectedToInternet)`
  gives `.offline` with local data intact and still dirty; (5) a tombstoned routine syncs as deleted and the pull
  keeps it hidden; (6) the cursor advances and a second sync pulls nothing new.
- [ ] Run `cd ios/Packages/GymSync && swift test --filter GymSyncTests` → PASS. **Commit:**
  `feat(sync): GymSync DTOs, Supabase transport and sync engine`

---

### Task 6: AuthService, integration tests against local Supabase

**Files:** `Sources/GymSync/AuthService.swift`, `SupabaseConfig.swift`, `Tests/GymSyncIntegrationTests/SupabaseTransportTests.swift`,
`scripts/test-sync-integration.sh`.

- [ ] `SupabaseConfig { url: URL; anonKey: String }`, loaded from `Bundle.main` Info keys `SUPABASE_URL` /
  `SUPABASE_ANON_KEY` (set via xcconfig: `ios/Config/Base.xcconfig` holds the local defaults
  `http:/$()/127.0.0.1:55421` and the public local anon key; a cloud build overrides them in `Local.xcconfig`).
- [ ] `AuthService` (`@MainActor @Observable`): `state: .signedOut | .signedIn(userId: UUID, email: String?)`,
  `signInWithApple(idToken:nonce:)` (`OpenIDConnectCredentials(provider: .apple, idToken:, nonce:)`),
  `signIn(email:password:)` and `signUp(email:password:)` (`#if DEBUG` only), `signOut()`, `deleteAccount()`
  (`rpc("delete_my_account")`, then sign out), and `restore()` on launch from the SDK's Keychain session. Errors map
  to user-facing messages ("Couldn't sign in. Check your connection and try again.").
- [ ] Integration tests (skip unless `SUPABASE_URL` and `SUPABASE_ANON_KEY` are in the environment): sign up
  `sync-<uuid>@test.local`, then push a routine, a workout (3 sets) and a weigh-in, pull them back, and assert
  equality. Push a stale workout and get `.stale`. A second user can't see the first user's rows. Delete the account
  and the rows are gone.
  `scripts/test-sync-integration.sh` sources `supabase/.env.local` (maps `API_URL`→`SUPABASE_URL`, `ANON_KEY`→`SUPABASE_ANON_KEY`)
  and runs `swift test --filter GymSyncIntegrationTests`.
- [ ] Run it → PASS. **Commit:** `feat(sync): auth service and Supabase integration tests`

---

### Task 7: App wiring, account screen, sync status and conflict UI

**Files:** modify `project.yml` (add the GymSync package dependency; `SUPABASE_URL`/`SUPABASE_ANON_KEY` Info keys
from build settings), `App/AppEnvironment.swift`, `App/LaunchOptions.swift`; create
`Features/Account/AccountView.swift`, `Features/Sync/SyncStatusBanner.swift`, `Features/Sync/ConflictSheet.swift`;
modify `Features/Log/LogView.swift` (the gear opens AccountView until plan 07), `TodayView` (the banner).

- AppEnvironment gains `auth: AuthService`, `sync: SyncEngine` (nil when signed out) and `syncStore: SyncStore`.
  Sync triggers: `scenePhase == .active`, after a workout finishes, after a weigh-in or plan change
  (`dataChanged()`/`planChanged()` schedule a debounced sync 2 s later), pull-to-refresh on Log/Today, and a 5-minute
  timer while active. Signing out calls `syncStore.resetAll()` after a confirmation ("Remove this iPhone's copy of
  your data? It stays in your account.").
- LaunchOptions: `-uiTestingBackend local` enables sync against local Supabase in UI tests; the default `-uiTesting`
  keeps sync disabled (no network) so existing tests stay hermetic.
- **AccountView**: when signed out, "Sign in with Apple" (`SignInWithAppleButton`, nonce SHA-256 per the Supabase
  docs), plus a DEBUG email/password form (`account.email`, `account.password`, `account.signIn`,
  `account.signUp`). When signed in, it shows the email, "Sync now" `account.syncNow`, "Last synced 2 min ago"
  `account.lastSync`, the status, "Sign out" `account.signOut` and a destructive "Delete account and data"
  `account.delete` (a two-step confirmation that types DELETE).
- **SyncStatusBanner** (on Today and Log): a glass capsule when `.offline` ("Offline · changes saved on this iPhone"),
  `.error`, or `.conflicts` ("1 workout changed on another device · Review") → `ConflictSheet`. Identifier `sync.banner`.
- **ConflictSheet**: for each conflicting workout, a side-by-side summary (this iPhone vs other device: name, date,
  sets, volume) with "Keep this iPhone's" `conflict.keepLocal` and "Keep other" `conflict.keepRemote`.
- Commit: `feat(app): Supabase auth, sync lifecycle, account screen, sync status and conflicts`

---

### Task 8: E2E sync UI test against local Supabase

**Files:** `GymRollinsUITests/SyncUITests.swift`, `scripts/ios-test-sync.sh`.

`scripts/ios-test-sync.sh` runs `scripts/supabase-up.sh`, then the SyncUITests class only
(`-only-testing:GymRollinsUITests/SyncUITests`), passing `SUPABASE_URL`/`ANON_KEY` to the app through the test's
`launchEnvironment` (the app reads the environment before Info.plist in DEBUG).

Test `testWorkoutSyncsAcrossFreshInstall`:
1. Launch `-uiTesting -uiTestingBackend local -diskStore -resetStore -fixedNow 2026-09-26T09:00:00Z`. Log → gear →
   sign up `ui-<uuid>@test.local` / `Passw0rd!`. `account.lastSync` shows "Just now".
2. Start a workout from Today, log all bench sets, finish (discard empty), Done.
3. Log → gear → Sync now → wait for `account.lastSync`.
4. Terminate. Relaunch with `-resetStore` (the local data is wiped), sign in with the same credentials, and wait
   for the sync to finish.
5. Log shows a workout card for today. Open it; bench shows the logged sets.

Test `testOfflineLoggingSyncsLater`: sign in, set `launchEnvironment["GYM_SIMULATE_OFFLINE"] = "1"` (the transport
throws `URLError(.notConnectedToInternet)` while set, a DEBUG-only hook), log a weigh-in, and `sync.banner` shows
"Offline". Relaunch without the flag, Sync now, and the banner disappears; after a fresh-install relaunch, Body shows
the weigh-in.

Add `scripts/ios-test-sync.sh` to `scripts/test-all.sh` **only when `SYNC_E2E=1`** (it needs Docker).
**Commit:** `test(e2e): cross-install sync and offline-later sync against local Supabase`

---

### Task 9: Verify, review, merge

- [ ] `scripts/test-all.sh`, `scripts/test-db.sh`, `scripts/test-sync-integration.sh` and `SYNC_E2E=1 scripts/ios-test-sync.sh` all pass.
- [ ] Security review: dispatch the security-reviewer agent on `supabase/migrations` + GymSync (RLS completeness,
  SECURITY DEFINER functions with a fixed `search_path`, MCP-client restrictions, no service key in the app, input
  constraints). Fix CRITICAL/HIGH.
- [ ] `codex review --base main`; fix P0–P2.
- [ ] Merge with `--no-ff`, then delete the branch.
