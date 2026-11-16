// get_activity (plan 39; docs/specs/2026-11-16-health-activities-design.md, section 5): what the owner did outside
// GymRollins, from Apple Health. Outside workouts after rules 6 and 7 (src/shared/activity.ts), newest first, and
// steps, move, exercise and stand per day and per Monday–Sunday week, in the agent's time zone.
import { resolveActivities } from '../../shared/activity.ts'
import { assertTimeZone, civilDay, isoDay, weekKey } from '../../shared/insights.ts'
import type { HealthActivityRow } from '../db.ts'
import { clamp, daysBefore, round } from './format.ts'
import { requireReads } from './permissions.ts'
import { compact, ok, type ToolCtx, ToolError, type ToolResult } from './result.ts'

export const ACTIVITY_DAYS = { min: 1, max: 84, default: 28 }
/** At most this many outside workouts in one answer; `outside_workouts_total` says how many there were. */
export const ACTIVITY_LIST_MAX = 60
const DAY_MS = 86_400_000

const METHOD =
  'Outside workouts are workouts other apps or the Apple Watch saved to Apple Health. One recorded during a ' +
  'GymRollins workout (overlapping at least half of the shorter of the two) is that session, measured: it carries ' +
  'during_workout_id and stays out of the day and week totals. Copies of one session from two apps (same kind, 80% ' +
  'overlap) are listed once, the Apple Watch copy first. move_kcal already includes the GymRollins workouts the app ' +
  'saved to Health: never add the two.'

interface Totals {
  steps: number
  move_kcal: number
  exercise_min: number
  stand_h: number | null
  outside_workouts: number
  outside_minutes: number
}

const empty = (): Totals => ({
  steps: 0, move_kcal: 0, exercise_min: 0, stand_h: null, outside_workouts: 0, outside_minutes: 0,
})

/** A `YYYY-MM-DD` day as a civil-date epoch (UTC midnight), like insights.ts' civilDay. */
const civil = (day: string): number => Date.parse(`${day}T00:00:00Z`)

function listed(a: HealthActivityRow, duringWorkoutId: string | undefined): Record<string, unknown> {
  return compact({
    kind: a.kind,
    started_at: a.started_at,
    duration_min: Math.round(a.duration_s / 60),
    distance_km: a.distance_m === null ? null : round(a.distance_m / 1000, 2),
    kcal: a.kcal === null ? null : Math.round(a.kcal),
    total_kcal: a.total_kcal === null ? null : Math.round(a.total_kcal),
    avg_hr: a.avg_hr,
    max_hr: a.max_hr,
    avg_power_w: a.avg_power_w,
    avg_cadence_rpm: a.avg_cadence_rpm,
    source: a.source_name,
    during_workout_id: duringWorkoutId ?? null,
  })
}

export async function getActivity(
  { db, now }: ToolCtx,
  args: { days?: number; time_zone?: string },
): Promise<ToolResult> {
  const tz = args.time_zone ?? 'UTC'
  try {
    assertTimeZone(tz)
  } catch {
    throw new ToolError(`Unknown time zone "${tz}". Use an IANA name such as Europe/Warsaw.`)
  }
  await requireReads(db, 'activity')
  const days = clamp(Math.trunc(args.days ?? ACTIVITY_DAYS.default), ACTIVITY_DAYS.min, ACTIVITY_DAYS.max)
  const today = civilDay(now.getTime(), tz)
  const first = today - (days - 1) * DAY_MS
  // A day of margin for the time zone, and one more for a GymRollins workout that started before the window.
  const [rows, spans, dayRows] = await Promise.all([
    db.healthActivities(daysBefore(now, days + 1).toISOString()),
    db.workoutSpans(daysBefore(now, days + 2).toISOString()),
    db.activityDays(isoDay(first)),
  ])
  const resolved = resolveActivities(rows.filter((a) => civilDay(Date.parse(a.started_at), tz) >= first), spans)
  const during = new Map(resolved.attached.map((x) => [x.activity.id, x.workout_id]))
  const all = [...resolved.shown, ...resolved.attached.map((x) => x.activity)]
    .sort((a, b) => Date.parse(b.started_at) - Date.parse(a.started_at) || (a.id < b.id ? -1 : 1))

  const byDay = new Map<number, Totals>()
  const totals = (day: number): Totals => {
    const known = byDay.get(day)
    if (known) return known
    const fresh = empty()
    byDay.set(day, fresh)
    return fresh
  }
  for (const d of dayRows) {
    const t = totals(civil(d.day))
    t.steps = d.steps
    t.move_kcal = d.move_kcal
    t.exercise_min = d.exercise_min
    t.stand_h = d.stand_h
  }
  // An attached outside workout is a GymRollins session, measured: it stays out of the totals.
  for (const a of resolved.shown) {
    const t = totals(civilDay(Date.parse(a.started_at), tz))
    t.outside_workouts += 1
    t.outside_minutes += Math.round(a.duration_s / 60)
  }
  const perDay = [...byDay.entries()].sort(([a], [b]) => b - a)
  const byWeek = new Map<number, Totals & { days_with_data: number }>()
  for (const [day, t] of perDay) {
    const week = weekKey(day, 'UTC')
    const w = byWeek.get(week) ?? { ...empty(), days_with_data: 0 }
    byWeek.set(week, {
      ...w,
      steps: w.steps + t.steps,
      move_kcal: w.move_kcal + t.move_kcal,
      exercise_min: w.exercise_min + t.exercise_min,
      outside_workouts: w.outside_workouts + t.outside_workouts,
      outside_minutes: w.outside_minutes + t.outside_minutes,
      days_with_data: w.days_with_data + 1,
    })
  }

  return ok({
    time_zone: tz,
    days,
    first_day: isoDay(first),
    outside_workouts: all.slice(0, ACTIVITY_LIST_MAX).map((a) => listed(a, during.get(a.id))),
    outside_workouts_total: all.length,
    days_of_activity: perDay.map(([day, t]) =>
      compact({
        day: isoDay(day),
        steps: t.steps,
        move_kcal: Math.round(t.move_kcal),
        exercise_min: t.exercise_min,
        stand_h: t.stand_h,
        outside_workouts: t.outside_workouts,
        outside_minutes: t.outside_minutes,
      })
    ),
    weeks: [...byWeek.entries()].sort(([a], [b]) => b - a).map(([week, w]) => ({
      week_start: isoDay(week),
      days_with_data: w.days_with_data,
      steps: w.steps,
      move_kcal: Math.round(w.move_kcal),
      exercise_min: w.exercise_min,
      outside_workouts: w.outside_workouts,
      outside_minutes: w.outside_minutes,
    })),
    method: METHOD,
  })
}
