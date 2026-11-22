// What Apple Health measured during a GymRollins workout, as get_workout and list_workouts tell agents (plan 40;
// docs/specs/2026-11-16-native-design-stage-1-design.md, section 6.3). Read only while the owner lets agents read
// activity from Apple Health. A workout with nothing measured reads as before: the calorie estimate is the app's.
import type { Db, WorkoutMeasurementRow } from '../db.ts'
import { switchedOff, withheld } from './permissions.ts'
import { compact } from './result.ts'

/** Apple's effort words, as GymCore's WorkoutEffortLevel: 1–3 Easy, 4–6 Moderate, 7–8 Hard, 9–10 All Out. */
export function effortWord(score: number): string {
  if (score <= 3) return 'Easy'
  if (score <= 6) return 'Moderate'
  if (score <= 8) return 'Hard'
  return 'All Out'
}

/** "6/10 Moderate"; the Apple Watch's estimate adds " (estimated)". Null without an effort. */
function effortText(m: WorkoutMeasurementRow): string | null {
  if (m.effort === null) return null
  return `${m.effort}/10 ${effortWord(m.effort)}${m.effort_estimated ? ' (estimated)' : ''}`
}

/** "412 active kcal (489 total)", "412 active kcal", "489 total kcal", or null. */
function kcalText(m: WorkoutMeasurementRow): string | null {
  const total = m.total_kcal === null ? null : Math.round(m.total_kcal)
  if (m.active_kcal === null) return total === null ? null : `${total} total kcal`
  return `${Math.round(m.active_kcal)} active kcal${total === null ? '' : ` (${total} total)`}`
}

/** "heart rate avg 128 / max 162", either half alone, or null. */
function heartRateText(m: WorkoutMeasurementRow): string | null {
  const parts = [m.avg_hr === null ? null : `avg ${m.avg_hr}`, m.max_hr === null ? null : `max ${m.max_hr}`]
    .filter((p) => p !== null)
  return parts.length === 0 ? null : `heart rate ${parts.join(' / ')}`
}

const RECORDED_BY: Readonly<Record<string, string>> = { watch: 'Apple Watch', apple_workout: 'Apple Workout' }

/**
 * get_workout's `measured`: "Apple Watch: 58 min, 412 active kcal (489 total), heart rate avg 128 / max 162, 124 BPM 2
 * min after, effort 6/10 Moderate", each part only when it is known, and "Effort 6/10 Moderate" when nothing recorded
 * the workout. Null when nothing is known.
 */
export function measuredText(m: WorkoutMeasurementRow): string | null {
  const effort = effortText(m)
  const parts = [
    m.duration_s === null ? null : `${Math.round(m.duration_s / 60)} min`,
    kcalText(m),
    heartRateText(m),
    m.post_hr === null ? null : `${m.post_hr} BPM 2 min after`,
    effort === null ? null : `effort ${effort}`,
  ].filter((p) => p !== null)
  if (parts.length === 0) return null
  const text = parts.join(', ')
  const by = m.recorded_by === null ? undefined : RECORDED_BY[m.recorded_by]
  return by === undefined ? text.charAt(0).toUpperCase() + text.slice(1) : `${by}: ${text}`
}

/** list_workouts' fields for one workout: active kcal, average heart rate and effort, each only when known. */
export function listedMeasurement(m: WorkoutMeasurementRow | undefined): Record<string, unknown> {
  if (m === undefined) return {}
  return compact({
    active_kcal: m.active_kcal === null ? null : Math.round(m.active_kcal),
    avg_hr: m.avg_hr,
    effort: effortText(m),
  })
}

/**
 * The measured numbers of these workouts, by workout id. While the owner keeps activity from agents: none, and the
 * words that say they are withheld (the workouts themselves are still answered).
 */
export async function measurementsFor(
  db: Db,
  workoutIds: string[],
): Promise<{ byId: Map<string, WorkoutMeasurementRow>; withheld?: string[] }> {
  const off = await switchedOff(db, 'activity')
  if (off.length > 0) return { byId: new Map(), withheld: [withheld(off, 'What Apple Health measured')] }
  const rows = workoutIds.length === 0 ? [] : await db.workoutMeasurements(workoutIds)
  return { byId: new Map(rows.map((m) => [m.workout_id, m])) }
}
