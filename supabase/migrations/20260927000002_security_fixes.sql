-- Security-review and Codex-review fixes on top of 20260926000001_schema.sql.

-- L1: pgcrypto belongs in `extensions`, not `public` (gen_random_uuid() is in pg_catalog on PG13+ anyway). ---------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pgcrypto' and extnamespace <> 'extensions'::regnamespace) then
    alter extension pgcrypto set schema extensions;
  end if;
end $$;

-- H1: children must hang off a parent the caller owns. ---------------------------------------------------------------
drop policy workout_entries_write on public.workout_entries;
create policy workout_entries_write on public.workout_entries for all to authenticated
  using (user_id = auth.uid() and not public.is_mcp_client())
  with check (
    user_id = auth.uid() and not public.is_mcp_client()
    and exists (select 1 from public.workouts w where w.id = workout_id and w.user_id = auth.uid())
  );

drop policy workout_sets_write on public.workout_sets;
create policy workout_sets_write on public.workout_sets for all to authenticated
  using (user_id = auth.uid() and not public.is_mcp_client())
  with check (
    user_id = auth.uid() and not public.is_mcp_client()
    and exists (select 1 from public.workout_entries e where e.id = entry_id and e.user_id = auth.uid())
  );

-- L3: a weekday may only point at the caller's own routine (or be a rest day). -------------------------------------
drop policy week_schedule_write on public.week_schedule;
create policy week_schedule_write on public.week_schedule for all to authenticated
  using (user_id = auth.uid() and not public.is_mcp_client())
  with check (
    user_id = auth.uid() and not public.is_mcp_client()
    and (routine_id is null
         or exists (select 1 from public.routines r where r.id = routine_id and r.user_id = auth.uid()))
  );

-- L4: value ranges the app can produce (timed/cardio sets, workout volume). ------------------------------------------
alter table public.workout_sets
  add constraint workout_sets_min_range check (min between 0 and 1440),
  add constraint workout_sets_dist_m_range check (dist_m between 0 and 1000000);
alter table public.workouts add constraint workouts_vol_kg_nonnegative check (vol_kg >= 0);

-- Codex P1: upsert_workout replaces children only if the parent write was actually applied. -----------------------
-- The existing row is locked first so two devices writing the same workout serialize; the upsert itself carries the
-- last-write-wins condition, and a skipped write (no RETURNING row) answers `stale` without touching children.
create or replace function public.upsert_workout(payload jsonb) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  wid uuid := (payload ->> 'id')::uuid;
  incoming timestamptz := (payload ->> 'client_updated_at')::timestamptz;
  existing public.workouts;
  applied uuid;
  e jsonb; s jsonb;
begin
  if auth.uid() is null or public.is_mcp_client() then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into existing from public.workouts where id = wid for update;
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
      client_updated_at = excluded.client_updated_at, deleted_at = excluded.deleted_at
    where public.workouts.client_updated_at <= excluded.client_updated_at
  returning id into applied;

  if applied is null then
    return jsonb_build_object('status', 'stale',
                              'updated_at', (select updated_at from public.workouts where id = wid));
  end if;

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

-- M1: RPCs and helpers are for signed-in users only. -------------------------------------------------------------------
revoke execute on function public.upsert_workout(jsonb) from public, anon;
revoke execute on function public.mcp_flag(text) from public, anon;
revoke execute on function public.is_mcp_client() from public, anon;
revoke execute on function public.set_updated_at() from public, anon;
revoke execute on function public.lww_guard() from public, anon;
grant execute on function public.upsert_workout(jsonb) to authenticated;
grant execute on function public.mcp_flag(text) to authenticated;
grant execute on function public.is_mcp_client() to authenticated;

-- L2: anon gets nothing in public (the app reads everything, including the exercise library, while signed in). ------
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke all on sequences from anon;
alter default privileges for role postgres in schema public revoke execute on functions from anon;
alter default privileges for role postgres in schema public revoke execute on functions from public;
