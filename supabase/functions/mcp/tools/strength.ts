// get_strength_levels: the app's strength levels (Beginner → Elite) for squat, bench press and deadlift, from the
// synced workouts (best e1RM of the last 365 days), the latest weigh-in and the profile's sex/birth year, against
// raw powerlifting competitors (OpenPowerlifting, public domain). Same maths as GymCore via
// _shared/strength-levels.ts and the shared fixture. The owner's sex and birth year are inputs only: they are
// never returned.
import standardsJson from '../../_shared/strength-standards.json' with { type: 'json' }
import {
  gapText,
  LEVELS,
  report,
  type Sex,
  type Standards,
  WINDOW_DAYS,
} from '../../_shared/strength-levels.ts'
import { round, weight } from './format.ts'
import { ok, type ToolCtx, ToolError, type ToolResult } from './result.ts'
import { FUTURE_SLACK_MS } from './write.ts'

const standards = standardsJson as unknown as Standards
const MAX_WORKOUTS = 1000
const DAY_MS = 86_400_000

const LIFT_NAMES = { squat: 'Squat', bench: 'Bench press', deadlift: 'Deadlift' } as const

async function latestBodyweightKg(ctx: ToolCtx): Promise<number | null> {
  // Same horizon log_bodyweight accepts, so a date-only weigh-in logged today (stored at 12:00 UTC) counts at once.
  const until = new Date(ctx.now.getTime() + FUTURE_SLACK_MS).toISOString()
  return (await ctx.db.latestBodyweight(until))?.w_kg ?? null
}

export async function getStrengthLevels(ctx: ToolCtx, _args: Record<string, never>): Promise<ToolResult> {
  const { db, now } = ctx
  // Workouts give the e1RMs, body the bodyweight, and the plan permission covers the profile (sex, birth year,
  // limits note), which RLS hides otherwise.
  const allowed = await db.readPermissions()
  if (!allowed.workouts || !allowed.body || !allowed.plan) {
    throw new ToolError(
      "Not allowed: strength levels need the owner's Claude permissions to read workouts, body and the plan in " +
        'the app.',
    )
  }
  const profile = await db.profile()
  const unit = profile?.unit ?? 'lb'
  const since = new Date(now.getTime() - WINDOW_DAYS * DAY_MS).toISOString()
  const [workouts, bodyweightKg] = await Promise.all([
    db.workouts({ since, limit: MAX_WORKOUTS }),
    latestBodyweightKg(ctx),
  ])
  const sex: Sex | null = profile?.sex === 'male' || profile?.sex === 'female' ? profile.sex : null
  const r = report(standards, {
    workouts,
    sex,
    birthYear: profile?.birth_year ?? null,
    bodyweightKg,
    limits: profile?.limits ?? '',
    now,
  })

  return ok({
    as_of: now.toISOString(),
    missing: r.missing.map((m) =>
      m === 'profile'
        ? 'sex_and_birth_year (the owner sets them in the app: Body tab, Strength level)'
        : 'bodyweight (no weigh-in yet)'
    ),
    bodyweight: bodyweightKg === null ? null : weight(bodyweightKg, unit),
    lifts: r.rows.map((row) => {
      const a = row.assessment
      return {
        lift: row.lift,
        name: LIFT_NAMES[row.lift],
        e1rm: row.estimate
          ? { ...weight(row.estimate.e1rm_kg, unit), date: row.estimate.date.slice(0, 10) }
          : null,
        exercise_id: row.estimate?.exercise_id ?? null,
        level: a?.level ?? null,
        percentile_of_raw_competitors: a ? round(a.percentile, 1) : null,
        percentile_text: a?.percentile_text ?? null,
        next_level: a?.next ?? null,
        next_level_target: a?.next_target_kg != null ? weight(a.next_target_kg, unit) : null,
        to_next_level: a?.gap_kg != null ? gapText(a.gap_kg, unit) : null,
        thresholds: a
          ? Object.fromEntries(LEVELS.slice(1).map((l) => [l, weight(a.thresholds[l], unit).weight_display]))
          : null,
        paused_by_injury_note: row.paused,
      }
    }),
    source: {
      name: standards.source.name,
      data_version: standards.source.version,
      license: standards.source.license,
      url: standards.source.url,
    },
    method:
      'e1RM = best Epley estimate (1–12 reps, done non-warm-up sets) of the last 365 days: squat = barbell ' +
      'back squat (ids 0043, 1461, 1462, 1435, 1436), bench = barbell bench press (0025), deadlift = conventional ' +
      'or sumo (0032, 0117). Compared with raw powerlifting competitors (OpenPowerlifting, meets since 2012, each ' +
      "lifter's best once) of the owner's sex, age group and bodyweight. Levels: Novice ≥ 45% and Intermediate " +
      "≥ 65% of the competitors' median, Advanced ≥ their 20th percentile, Elite ≥ their 80th. " +
      'paused_by_injury_note: the limits note mentions a knee/legs (display only).',
  })
}
