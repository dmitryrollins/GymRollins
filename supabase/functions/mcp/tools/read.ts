// Read-only tools: profile, plan, workouts, bodyweight, exercise search. History and the training summary live in
// history.ts / summary.ts and are re-exported here.
import type { EntryRow, ExerciseRow, SetRow, WeightUnit, WorkoutRow } from '../db.ts'
import { exerciseMap, ownerUnit, preferenceMap, WEEKDAYS } from './common.ts'
import {
  clamp,
  daysBefore,
  isoDate,
  parseBound,
  round,
  setVolumeKg,
  slopePerWeek,
  topSet,
  weight,
  workingSets,
} from './format.ts'
import { compact, ok, type ToolCtx, ToolError, type ToolResult } from './result.ts'

export { getExerciseHistory } from './history.ts'
export { getTrainingSummary } from './summary.ts'

const DEFAULT_WINDOW_DAYS = 84 // 12 weeks
export const LIST_LIMIT = { min: 1, max: 60, default: 20 }
export const SEARCH_LIMIT = { min: 1, max: 25, default: 10 }

export async function getProfile({ db }: ToolCtx): Promise<ToolResult> {
  const p = await db.profile()
  if (!p) {
    return ok({
      profile_saved: false,
      unit: 'lb',
      note: 'The owner has not saved a profile yet; the app defaults apply (lb, 4 training days).',
    })
  }
  return ok({
    unit: p.unit,
    goal: {
      ...(p.goal_weight_kg !== null ? weight(p.goal_weight_kg, p.unit) : {}),
      date: p.goal_date,
    },
    height_cm: p.height_cm,
    training_days: p.training_days,
    experience: p.experience,
    limits: p.limits,
    deload_pct: p.deload_pct,
    rest_sec: p.rest_sec,
    permissions: {
      read_plan: p.mcp_read_plan,
      read_workouts: p.mcp_read_workouts,
      read_body: p.mcp_read_body,
      propose: p.mcp_propose,
      auto_apply: p.mcp_auto_apply,
    },
  })
}

export async function getPlan({ db }: ToolCtx): Promise<ToolResult> {
  const [unit, routines, schedule, prefs] = await Promise.all([
    ownerUnit(db),
    db.routines(),
    db.weekSchedule(),
    db.exercisePreferences(),
  ])
  const names = await exerciseMap(db, [
    ...routines.flatMap((r) => r.exercises.map((e) => e.exercise_id)),
    ...prefs.map((p) => p.exercise_id),
  ])
  const preferred = (pref: string) =>
    prefs.filter((p) => p.pref === pref).map((p) => ({
      id: p.exercise_id,
      name: names.get(p.exercise_id)?.n ?? null,
    }))
  const routineName = new Map(routines.map((r) => [r.id, r.name]))
  const byDay = new Map(schedule.map((s) => [s.weekday, s.routine_id]))
  return ok({
    unit,
    routines: routines.map((r) => ({
      id: r.id,
      name: r.name,
      paused: r.paused,
      policy: r.policy,
      exercises: [...r.exercises].sort((a, b) => a.position - b.position).map((e) =>
        compact({
          id: e.exercise_id,
          name: names.get(e.exercise_id)?.n ?? null,
          sets: e.sets,
          reps: e.reps,
          reps_min: e.reps_min,
          sec: e.sec,
          mode: e.mode,
          ...(e.weight_kg != null ? weight(e.weight_kg, unit) : {}),
          prog: e.prog,
          inc_kg: e.inc_kg,
          superset_group: e.sg,
        })
      ),
    })),
    week: WEEKDAYS.map((day, i) => {
      const routineId = byDay.get(i + 1) ?? null
      return {
        weekday: i + 1,
        day,
        routine_id: routineId,
        routine: routineId ? routineName.get(routineId) ?? null : null,
      }
    }),
    exercise_preferences: { more: preferred('more'), less: preferred('less'), never: preferred('never') },
  })
}

function durationMin(w: WorkoutRow): number | null {
  if (!w.ended_at) return null
  const ms = new Date(w.ended_at).getTime() - new Date(w.started_at).getTime() - w.paused_sec * 1000
  return Math.max(0, Math.round(ms / 60_000))
}

const byPosition = <T extends { position: number }>(xs: T[]): T[] =>
  [...xs].sort((a, b) => a.position - b.position)

function workoutSummary(w: WorkoutRow, names: Map<string, ExerciseRow>, unit: WeightUnit) {
  const entries = byPosition(w.workout_entries)
  return {
    id: w.id,
    date: isoDate(w.started_at),
    name: w.name,
    duration_min: durationMin(w),
    working_sets: entries.reduce((n, e) => n + workingSets(e.workout_sets).length, 0),
    volume_kg: round(entries.reduce((v, e) => v + setVolumeKg(e.workout_sets), 0), 1),
    top_sets: entries.flatMap((e) => {
      const top = topSet(e.workout_sets)
      if (!top) return []
      return [{
        exercise_id: e.exercise_id,
        exercise: names.get(e.exercise_id)?.n ?? null,
        reps: top.r,
        ...weight(top.w_kg, unit),
      }]
    }),
  }
}

export async function listWorkouts(
  { db, now }: ToolCtx,
  args: { since?: string; until?: string; limit?: number },
): Promise<ToolResult> {
  const since = args.since ? parseBound(args.since, 'since') : daysBefore(now, DEFAULT_WINDOW_DAYS)
  const until = args.until ? parseBound(args.until, 'until', 'end') : undefined
  const limit = clamp(Math.trunc(args.limit ?? LIST_LIMIT.default), LIST_LIMIT.min, LIST_LIMIT.max)
  const [unit, rows] = await Promise.all([
    ownerUnit(db),
    db.workouts({ since: since.toISOString(), until: until?.toISOString(), limit }),
  ])
  const names = await exerciseMap(db, rows.flatMap((w) => w.workout_entries.map((e) => e.exercise_id)))
  return ok({
    unit,
    since: since.toISOString(),
    until: until?.toISOString() ?? null,
    count: rows.length,
    workouts: rows.map((w) => workoutSummary(w, names, unit)),
  })
}

function setDetail(s: SetRow, unit: WeightUnit) {
  return compact({
    reps: s.r,
    ...weight(s.w_kg, unit),
    warmup: s.warmup ? true : null,
    done: s.done ? null : false,
    multiplier: s.multiplier !== 1 ? s.multiplier : null,
    sec: s.sec,
    min: s.min,
    dist_m: s.dist_m,
    rir: s.rir,
    rpe: s.rpe,
  })
}

function entryDetail(e: EntryRow, names: Map<string, ExerciseRow>, unit: WeightUnit) {
  return compact({
    exercise_id: e.exercise_id,
    exercise: names.get(e.exercise_id)?.n ?? null,
    note: e.note,
    superset_group: e.superset_group,
    sets: byPosition(e.workout_sets).map((s) => setDetail(s, unit)),
  })
}

export async function getWorkout({ db }: ToolCtx, args: { id: string }): Promise<ToolResult> {
  const [unit, w] = await Promise.all([ownerUnit(db), db.workout(args.id)])
  if (!w) throw new ToolError('Workout not found. Use list_workouts to find workout ids.')
  const names = await exerciseMap(db, w.workout_entries.map((e) => e.exercise_id))
  const summary = workoutSummary(w, names, unit)
  return ok(compact({
    id: w.id,
    date: summary.date,
    started_at: w.started_at,
    ended_at: w.ended_at,
    name: w.name,
    note: w.note,
    duration_min: summary.duration_min,
    working_sets: summary.working_sets,
    volume_kg: summary.volume_kg,
    unit,
    entries: byPosition(w.workout_entries).map((e) => entryDetail(e, names, unit)),
  }))
}

const SLOPE_WINDOW_DAYS = 28

export async function getBodyweight({ db, now }: ToolCtx, args: { since?: string }): Promise<ToolResult> {
  const since = args.since ? parseBound(args.since, 'since') : daysBefore(now, DEFAULT_WINDOW_DAYS)
  const slopeFrom = daysBefore(now, SLOPE_WINDOW_DAYS)
  const fetchFrom = since < slopeFrom ? since : slopeFrom
  const [unit, rows] = await Promise.all([ownerUnit(db), db.bodyweight(fetchFrom.toISOString())])
  const time = (iso: string) => new Date(iso).getTime()
  const recent = rows.filter((r) => time(r.measured_at) >= slopeFrom.getTime())
  return ok({
    unit,
    entries: rows
      .filter((r) => time(r.measured_at) >= since.getTime())
      .map((r) => compact({ date: isoDate(r.measured_at), ...weight(r.w_kg, unit), body_fat_pct: r.bf_pct })),
    slope_kg_per_week_4w: slopePerWeek(recent.map((r) => ({ t: time(r.measured_at), v: r.w_kg }))),
  })
}

export async function searchExercises(
  { db }: ToolCtx,
  args: { query?: string; body_part?: string; equipment?: string; limit?: number },
): Promise<ToolResult> {
  const query = args.query?.trim() || undefined
  const bodyPart = args.body_part?.trim().toLowerCase() || undefined
  const equipment = args.equipment?.trim().toLowerCase() || undefined
  if (!query && !bodyPart && !equipment) throw new ToolError('Give a query, body_part or equipment.')
  const limit = clamp(Math.trunc(args.limit ?? SEARCH_LIMIT.default), SEARCH_LIMIT.min, SEARCH_LIMIT.max)
  const rows = await db.searchExercises({ query, bodyPart, equipment, limit })
  const prefs = await preferenceMap(db, rows.map((r) => r.id))
  return ok({
    results: rows.map((r) =>
      compact({
        id: r.id,
        name: r.n,
        body_part: r.bp,
        equipment: r.eq,
        target: r.tg,
        custom: r.custom ? true : null,
        preference: prefs.get(r.id) ?? null,
      })
    ),
  })
}
