// get_training_summary: sessions and volume per calendar week (Mon–Sun, UTC), PRs, stalls and the bodyweight trend.
import type { ExerciseRow, SetRow, WeightUnit, WorkoutRow } from '../db.ts'
import { exerciseMap, ownerUnit } from './common.ts'
import {
  bestE1rm,
  clamp,
  daysBefore,
  isoDate,
  mondayOf,
  round,
  setVolumeKg,
  slopePerWeek,
  topSet,
  WEEK_MS,
  weight,
  workingSets,
} from './format.ts'
import { ok, type ToolCtx, type ToolResult } from './result.ts'

export const SUMMARY_WEEKS = { min: 1, max: 12, default: 4 }
/** Extra history before the window, as the baseline for PRs and stalls. */
const LOOKBACK_WEEKS = 26
const MAX_WORKOUTS = 400
const STALL_SESSIONS = 3
const BODYWEIGHT_SLOPE_DAYS = 28
const BODYWEIGHT_LOOKBACK_DAYS = 90

interface Session {
  date: string
  time: number
  top: SetRow
  e1rm: number | null
}

/** Chronological sessions (with at least one working set) per exercise id. */
function sessionsByExercise(workouts: WorkoutRow[]): Map<string, Session[]> {
  const out = new Map<string, Session[]>()
  const at = (w: WorkoutRow) => new Date(w.started_at).getTime()
  const chronological = [...workouts].sort((a, b) => at(a) - at(b))
  for (const w of chronological) {
    for (const e of w.workout_entries) {
      const top = topSet(e.workout_sets)
      if (!top) continue
      const session = {
        date: isoDate(w.started_at),
        time: new Date(w.started_at).getTime(),
        top,
        e1rm: bestE1rm(e.workout_sets),
      }
      out.set(e.exercise_id, [...(out.get(e.exercise_id) ?? []), session])
    }
  }
  return out
}

function weekly(workouts: WorkoutRow[], start: Date, weeks: number, names: Map<string, ExerciseRow>) {
  return Array.from({ length: weeks }, (_, i) => {
    const from = start.getTime() + i * WEEK_MS
    const inWeek = workouts.filter((w) => {
      const t = new Date(w.started_at).getTime()
      return t >= from && t < from + WEEK_MS
    })
    const sets: Record<string, number> = {}
    const volume: Record<string, number> = {}
    for (const e of inWeek.flatMap((w) => w.workout_entries)) {
      const bp = names.get(e.exercise_id)?.bp ?? 'other'
      sets[bp] = (sets[bp] ?? 0) + workingSets(e.workout_sets).length
      volume[bp] = (volume[bp] ?? 0) + setVolumeKg(e.workout_sets)
    }
    return {
      week_start: isoDate(new Date(from).toISOString()),
      sessions: inWeek.length,
      working_sets: Object.values(sets).reduce((a, b) => a + b, 0),
      volume_kg: round(Object.values(volume).reduce((a, b) => a + b, 0), 1),
      sets_by_body_part: sets,
      volume_kg_by_body_part: Object.fromEntries(Object.entries(volume).map(([k, v]) => [k, round(v, 1)])),
    }
  })
}

function prs(
  byExercise: Map<string, Session[]>,
  windowStart: number,
  names: Map<string, ExerciseRow>,
  unit: WeightUnit,
) {
  return [...byExercise].flatMap(([id, sessions]) =>
    sessions.flatMap((s, i) => {
      if (s.time < windowStart || s.e1rm === null) return []
      const previous = sessions.slice(0, i).map((p) => p.e1rm).filter((v): v is number => v !== null)
      if (previous.length === 0 || s.e1rm <= Math.max(...previous)) return []
      return [{
        date: s.date,
        exercise_id: id,
        exercise: names.get(id)?.n ?? null,
        e1rm_kg: round(s.e1rm, 1),
        e1rm_display: weight(s.e1rm, unit).weight_display,
        previous_best_e1rm_kg: round(Math.max(...previous), 1),
        top_set: { reps: s.top.r, ...weight(s.top.w_kg, unit) },
      }]
    })
  )
}

/** Same top weight for the last 3 sessions and top-set reps never rising, with the last one inside the window. */
function stalls(
  byExercise: Map<string, Session[]>,
  windowStart: number,
  names: Map<string, ExerciseRow>,
  unit: WeightUnit,
) {
  return [...byExercise].flatMap(([id, sessions]) => {
    const last = sessions.slice(-STALL_SESSIONS)
    if (last.length < STALL_SESSIONS || last[last.length - 1].time < windowStart) return []
    const sameWeight = last.every((s) => Math.abs(s.top.w_kg - last[0].top.w_kg) < 0.01)
    const notRising = last.every((s, i) => i === 0 || s.top.r <= last[i - 1].top.r)
    if (!sameWeight || !notRising) return []
    return [{
      exercise_id: id,
      exercise: names.get(id)?.n ?? null,
      ...weight(last[0].top.w_kg, unit),
      reps: last.map((s) => s.top.r),
      dates: last.map((s) => s.date),
    }]
  })
}

export async function getTrainingSummary(
  { db, now }: ToolCtx,
  args: { weeks?: number },
): Promise<ToolResult> {
  const weeks = clamp(Math.trunc(args.weeks ?? SUMMARY_WEEKS.default), SUMMARY_WEEKS.min, SUMMARY_WEEKS.max)
  const windowStart = new Date(mondayOf(now).getTime() - (weeks - 1) * WEEK_MS)
  const lookback = new Date(windowStart.getTime() - LOOKBACK_WEEKS * WEEK_MS)
  const [unit, workouts, bodyweight] = await Promise.all([
    ownerUnit(db),
    db.workouts({ since: lookback.toISOString(), limit: MAX_WORKOUTS }),
    db.bodyweight(daysBefore(now, BODYWEIGHT_LOOKBACK_DAYS).toISOString()),
  ])
  const names = await exerciseMap(db, workouts.flatMap((w) => w.workout_entries.map((e) => e.exercise_id)))
  const byExercise = sessionsByExercise(workouts)
  const week = weekly(workouts, windowStart, weeks, names)
  const slopeFrom = daysBefore(now, BODYWEIGHT_SLOPE_DAYS).getTime()
  const latest = bodyweight[bodyweight.length - 1]
  return ok({
    unit,
    weeks,
    since: windowStart.toISOString(),
    sessions_per_week_avg: round(week.reduce((n, w) => n + w.sessions, 0) / weeks, 1),
    weekly: week,
    prs: prs(byExercise, windowStart.getTime(), names, unit),
    stalls: stalls(byExercise, windowStart.getTime(), names, unit),
    bodyweight: latest
      ? {
        latest: { date: isoDate(latest.measured_at), ...weight(latest.w_kg, unit) },
        slope_kg_per_week: slopePerWeek(
          bodyweight
            .map((b) => ({ t: new Date(b.measured_at).getTime(), v: b.w_kg }))
            .filter((p) => p.t >= slopeFrom),
        ),
      }
      : null,
  })
}
