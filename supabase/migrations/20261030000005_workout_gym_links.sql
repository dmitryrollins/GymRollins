-- upsert_workout carries the workout's gym and each entry's listing. A link the caller can't see becomes null (the
-- triggers in 20261030000001), so it never blocks a workout. "This phone only" gyms are never sent. Only those columns
-- differ from 20260928000001.
create or replace function public.upsert_workout(payload jsonb) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  wid uuid := (payload ->> 'id')::uuid;
  incoming timestamptz := (payload ->> 'client_updated_at')::timestamptz;
  base timestamptz := (payload ->> 'base_updated_at')::timestamptz;
  force boolean := coalesce((payload ->> 'force')::boolean, false);
  stored_edit timestamptz;
  existing public.workouts;
  applied uuid;
  e jsonb; s jsonb;
begin
  if auth.uid() is null or public.is_mcp_client() then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into existing from public.workouts where id = wid for update;
  if found and not force then
    if existing.updated_at is distinct from base
       and not (base is null and existing.client_updated_at = incoming) then
      return jsonb_build_object('status', 'stale', 'updated_at', existing.updated_at);
    end if;
    if existing.client_updated_at > incoming then
      return jsonb_build_object('status', 'stale', 'updated_at', existing.updated_at);
    end if;
  end if;
  stored_edit := case when found and force then greatest(incoming, existing.client_updated_at) else incoming end;

  insert into public.workouts (id, started_at, ended_at, paused_sec, routine_id, name, source, note, vol_kg, records,
                               client_updated_at, deleted_at, gym_id)
  values (wid, (payload->>'started_at')::timestamptz, (payload->>'ended_at')::timestamptz,
          coalesce((payload->>'paused_sec')::numeric, 0), (payload->>'routine_id')::uuid, payload->>'name',
          coalesce(payload->>'source', 'app'), payload->>'note', coalesce((payload->>'vol_kg')::numeric, 0),
          coalesce(payload->'records', '[]'), stored_edit, (payload->>'deleted_at')::timestamptz,
          (payload->>'gym_id')::uuid)
  on conflict (id) do update set started_at = excluded.started_at, ended_at = excluded.ended_at,
      paused_sec = excluded.paused_sec, routine_id = excluded.routine_id, name = excluded.name,
      source = excluded.source, note = excluded.note, vol_kg = excluded.vol_kg, records = excluded.records,
      client_updated_at = excluded.client_updated_at, deleted_at = excluded.deleted_at, gym_id = excluded.gym_id
    where force or public.workouts.client_updated_at <= excluded.client_updated_at
  returning id into applied;

  if applied is null then
    return jsonb_build_object('status', 'stale',
                              'updated_at', (select updated_at from public.workouts where id = wid));
  end if;

  delete from public.workout_entries where workout_id = wid;
  for e in select * from jsonb_array_elements(coalesce(payload->'entries', '[]')) loop
    insert into public.workout_entries (id, workout_id, exercise_id, position, note, superset_group, gym_equipment_id)
    values ((e->>'id')::uuid, wid, e->>'exercise_id', (e->>'position')::int, e->>'note', e->>'superset_group',
            (e->>'gym_equipment_id')::uuid);
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

revoke execute on function public.upsert_workout(jsonb) from public, anon;
grant execute on function public.upsert_workout(jsonb) to authenticated;
