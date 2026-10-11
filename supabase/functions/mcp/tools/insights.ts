// get_training_insights: the app's recovery map, weekly set targets and streak, computed from the synced workouts
// the caller's RLS exposes (same maths as GymCore via _shared/insights.ts and the shared fixture).
import {
  assertTimeZone,
  defaultTarget,
  freshest,
  isoDay,
  limitedMuscles,
  MUSCLE_GROUPS,
  type MuscleGroup,
  recovery,
  streak,
  type TargetRange,
  weekKey,
  weeklySets,
} from '../../_shared/insights.ts'
import type { ExerciseRow, MuscleTargetRow } from '../db.ts'
import { exerciseMap } from './common.ts'
import { round } from './format.ts'
import { ok, type ToolCtx, ToolError, type ToolResult } from './result.ts'

const WINDOW_DAYS = 28
const MAX_WORKOUTS = 400
/** The app's default when no profile was saved (ProfileRecord.trainingDays). */
const DEFAULT_TRAINING_DAYS = 4

function targetsByGroup(rows: MuscleTargetRow[]): Map<MuscleGroup, TargetRange & { custom: boolean }> {
  const stored = new Map(rows.map((r) => [r.muscle, r]))
  return new Map(MUSCLE_GROUPS.map((g) => {
    const row = stored.get(g)
    return [
      g,
      row ? { min: row.min_sets, max: row.max_sets, custom: true } : { ...defaultTarget(g), custom: false },
    ]
  }))
}

export async function getTrainingInsights(
  { db, now }: ToolCtx,
  args: { time_zone?: string },
): Promise<ToolResult> {
  const tz = args.time_zone ?? 'UTC'
  try {
    assertTimeZone(tz)
  } catch {
    throw new ToolError(`Unknown time zone "${tz}". Use an IANA name such as Europe/Warsaw.`)
  }
  // Workouts give the numbers; the plan permission covers the profile (weekly goal, limits note), custom exercises
  // and weekly targets, which RLS hides otherwise. Without it the goal/targets would be silent guesses.
  const allowed = await db.readPermissions()
  if (!allowed.workouts || !allowed.plan) {
    throw new ToolError(
      "Not allowed: insights need the owner's Claude permissions to read workouts and read the plan in the app.",
    )
  }
  const profile = await db.profile()
  const since = new Date(now.getTime() - WINDOW_DAYS * 86_400_000).toISOString()
  const [workouts, dates, targetRows] = await Promise.all([
    db.workouts({ since, limit: MAX_WORKOUTS }),
    db.workoutDates(),
    db.muscleTargets(),
  ])
  const exercises: Map<string, ExerciseRow> = await exerciseMap(
    db,
    workouts.flatMap((w) => w.workout_entries.map((e) => e.exercise_id)),
  )
  const lookup = (id: string) => exercises.get(id)
  const limited = limitedMuscles(profile?.limits ?? '')
  const rec = recovery(workouts, lookup, now)
  const sets = weeklySets(workouts, lookup, now, tz)
  const targets = targetsByGroup(targetRows)
  const week = weekKey(now.getTime(), tz)
  const goal = profile?.training_days ?? DEFAULT_TRAINING_DAYS
  const s = streak(dates, goal, now, tz)

  return ok({
    time_zone: tz,
    as_of: now.toISOString(),
    recovery: rec.map((r) => ({
      muscle: r.group,
      recovered_pct: r.percent,
      status: r.status,
      last_trained: r.last_trained,
      fully_recovered_at: r.recovered_at,
      ...(limited.has(r.group) ? { limited_by_injury_note: true } : {}),
    })),
    fresh: freshest(rec, limited, now),
    limits_note: profile?.limits ?? '',
    weekly_sets: {
      week_start: isoDay(week),
      week_end: isoDay(week + 6 * 86_400_000),
      muscles: MUSCLE_GROUPS.map((g) => {
        const t = targets.get(g)!
        const n = round(sets.get(g) ?? 0, 1)
        return {
          muscle: g,
          hard_sets: n,
          target_min: t.min,
          target_max: t.max,
          custom_target: t.custom,
          status: n < t.min ? 'below' : n > t.max ? 'above' : 'within',
        }
      }),
    },
    streak: {
      current_weeks: s.current,
      longest_weeks: s.longest,
      goal_days_per_week: s.goal,
      this_week_days: s.this_week_days,
      this_week_met: s.this_week_met,
    },
    method:
      'Hard sets = done, non-warm-up, non-cardio sets; an exercise counts 1 set for its target muscle and 0.5 ' +
      'for each secondary muscle. Recovery: each session leaves fatigue min(1, load/6) (load = sets × effort ' +
      'from RIR/RPE) fading linearly over 24 + 6 × load hours (max 96 h); sessions add up. A streak week has ' +
      'at least goal_days_per_week distinct days with a workout; the current week never breaks it. ' +
      "limited_by_injury_note: the owner's limits note mentions a knee/legs (display only).",
  })
}
