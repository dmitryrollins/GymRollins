import { describe, expect, it } from 'vitest'
import swiftSource from '../../ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift?raw'
import planChangeSource from '../../ios/Packages/GymCore/Sources/GymCore/Plan/PlanChange.swift?raw'
import appSchema from '../migrations/0002_app_schema.sql?raw'
import capsMigration from '../migrations/0005_gyms_photos.sql?raw'
import accountCaps from '../migrations/0010_account_caps.sql?raw'
import activityMigration from '../migrations/0013_health_activities.sql?raw'
import measurementMigration from '../migrations/0014_workout_measurements.sql?raw'
import { DomainLimits } from '../src/shared/domain-limits.ts'
import { PlanChangeLimits } from '../src/shared/plan-validation.ts'

// Fails when the server's limits drift from the Swift source of truth, or from the D1 CHECKs that enforce them. The
// Swift file is read as text: `public static let name = 40` and `public static let name: ClosedRange<T> = lo...hi`.

type Limit = number | { readonly min: number; readonly max: number }

function swiftNumber(raw: string): number {
  if (!/^-?[\d_]+(\.[\d_]+)?$/.test(raw)) throw new Error(`not a Swift number literal: '${raw}'`)
  return Number(raw.replace(/_/g, ''))
}

function swiftLimits(source: string): Record<string, Limit> {
  const out: Record<string, Limit> = {}
  for (const [, name, rhs] of source.matchAll(/public static let (\w+)(?::\s*ClosedRange<\w+>)?\s*=\s*(.+)$/gm)) {
    const value = rhs.replace(/\/\/.*$/, '').trim()
    const range = /^(-?[\d_.]+?)\.\.\.(-?[\d_.]+)$/.exec(value)
    if (range) out[name] = { min: swiftNumber(range[1]), max: swiftNumber(range[2]) }
    else if (/^-?[\d_.]+$/.test(value)) out[name] = swiftNumber(value)
  }
  return out
}

/**
 * DomainLimits.swift's `enum MeasurementLimits` (plan 40), which migration 0014's CHECKs mirror. It is cut out before
 * the file is read as DomainLimits: its members aren't DomainLimits'.
 */
const MEASUREMENT_LIMITS = /public enum MeasurementLimits \{([\s\S]*?)\n\}/

function swiftMeasurementLimits(source: string): Record<string, Limit> {
  const body = MEASUREMENT_LIMITS.exec(source)?.[1]
  if (body === undefined) throw new Error("DomainLimits.swift has no 'enum MeasurementLimits'")
  return swiftLimits(body)
}

const swift = swiftLimits(swiftSource.replace(MEASUREMENT_LIMITS, ''))
const L = DomainLimits
const between = (column: string, range: { readonly min: number; readonly max: number }) =>
  `${column} BETWEEN ${range.min} AND ${range.max}`

/** The CHECK text in 0002_app_schema.sql that enforces each limit. */
const SCHEMA_CHECKS = [
  `length(name) BETWEEN 1 AND ${L.routineNameMax}`, `json_array_length(exercises) <= ${L.routineExercisesMax}`,
  `length(n) BETWEEN 1 AND ${L.customExerciseNameMax}`, `length(name) BETWEEN 1 AND ${L.workoutNameMax}`,
  between('w_kg', L.setWeightKg), between('r', L.setReps), between('sec', L.setSeconds), between('min', L.setMinutes),
  between('dist_m', L.setDistanceM), between('w_kg', L.bodyweightKg), between('bf_pct', L.bodyFatPct),
  between('rest_sec', L.restSec), between('warmup_rest_sec', L.restSec), between('height_cm', L.heightCm),
  between('goal_weight_kg', L.goalWeightKg), between('training_days', L.trainingDays),
  `length(limits) <= ${L.limitsTextMax}`, between('deload_pct', L.deloadPct), between('birth_year', L.birthYear),
  between('min_sets', L.weeklySetTarget), between('max_sets', L.weeklySetTarget),
  `length(name) BETWEEN 1 AND ${L.gymNameMax}`, `length(address) <= ${L.gymAddressMax}`,
  between('quantity', L.listingQuantity), `length(notes) <= ${L.listingNotesMax}`,
  `length(brand) BETWEEN 1 AND ${L.itemBrandMax}`, `length(model) BETWEEN 1 AND ${L.itemModelMax}`,
  `length(private_brand) BETWEEN 1 AND ${L.itemBrandMax}`, `length(private_model) BETWEEN 1 AND ${L.itemModelMax}`,
  `length(note) <= ${L.reportNoteMax}`,
]

/** The CHECK text in 0013_health_activities.sql that enforces each activity limit. */
const ACTIVITY_CHECKS = [
  `length(kind) BETWEEN 1 AND ${L.activityTextMax}`, `length(source_name) BETWEEN 1 AND ${L.activityTextMax}`,
  between('duration_s', L.activityDurationS), between('(kcal', L.activityKcal),
  between('distance_m', L.activityDistanceM),
  between('avg_hr', L.heartRateBpm), between('max_hr', L.heartRateBpm), between('avg_power_w', L.activityPowerW),
  between('avg_cadence_rpm', L.activityCadenceRpm), between('total_kcal', L.activityKcal), between('steps', L.daySteps),
  between('move_kcal', L.activityKcal), between('exercise_min', L.dayExerciseMin), between('stand_h', L.dayStandH),
]

/** Each column of 0014_workout_measurements.sql with a range, and the MeasurementLimits member its CHECK uses. */
const MEASUREMENT_COLUMNS = [
  ['duration_s', 'durationS'], ['active_kcal', 'kcal'], ['total_kcal', 'kcal'], ['avg_hr', 'heartRate'],
  ['max_hr', 'heartRate'], ['post_hr', 'heartRate'], ['effort', 'effort'],
] as const

/**
 * PlanChange.swift's `enum PlanChangeLimits`, with `(DomainLimits.name - n)` worked out from the Swift
 * values.
 */
function swiftPlanChangeLimits(source: string): Record<string, Limit> {
  const body = /public enum PlanChangeLimits \{([\s\S]*?)\n\}/.exec(source)?.[1]
  if (body === undefined) throw new Error("PlanChange.swift has no 'enum PlanChangeLimits'")
  return swiftLimits(
    body.replace(
      /\(DomainLimits\.(\w+) - (\d+)\)/g,
      (_, name: string, n: string) => String(Number(swift[name]) - Number(n)),
    ),
  )
}

describe('domain limits', () => {
  it('finds the Swift constants (a parser that matched nothing would pass everything)', () => {
    expect(Object.keys(swift).length).toBeGreaterThanOrEqual(53)
  })

  it('has every Swift limit in the server, with the same value, and no others', () => {
    expect(DomainLimits).toEqual(swift)
  })

  it("keeps the D1 schema's CHECKs at the same numbers", () => {
    for (const check of SCHEMA_CHECKS) expect(appSchema, check).toContain(check)
  })

  it('keeps the cap triggers at the same numbers', () => {
    const caps = [[DomainLimits.privateGymsMax, 'too_many_gyms'], [DomainLimits.privateListingsMax, 'too_many_listings']]
    for (const [max, code] of caps) {
      const trigger = `id <> NEW.id) >= ${max}\nBEGIN\n  SELECT RAISE(ABORT, '${code}');`
      expect(capsMigration.split(trigger).length - 1, String(code)).toBe(2)
    }
  })

  it("keeps the activity tables' CHECKs and caps at the same numbers", () => {
    for (const check of ACTIVITY_CHECKS) expect(activityMigration, check).toContain(check)
    const caps = [
      ['health_activities', DomainLimits.healthActivitiesMax, 'too_many_health_activities'],
      ['activity_days', DomainLimits.activityDaysMax, 'too_many_activity_days'],
    ] as const
    for (const [table, max, code] of caps) {
      const trigger = `tbl = '${table}'), 0) >= ${max}\nBEGIN\n  SELECT RAISE(ABORT, '${code}');`
      expect(activityMigration.split(trigger).length - 1, code).toBe(1)
    }
  })

  it("keeps migration 0014's CHECKs at GymCore's MeasurementLimits", () => {
    const limits = swiftMeasurementLimits(swiftSource)
    expect(Object.keys(limits).sort()).toEqual(['durationS', 'effort', 'heartRate', 'kcal'])
    for (const [column, name] of MEASUREMENT_COLUMNS) {
      const check = between(column, limits[name] as { min: number; max: number })
      expect(measurementMigration, check).toContain(check)
    }
  })

  it('keeps the account caps in their triggers at the same numbers', () => {
    const counted = [
      ['workouts', DomainLimits.workoutsMax, 'too_many_workouts'],
      ['bodyweight', DomainLimits.bodyweightsMax, 'too_many_body_weights'],
      ['routines', DomainLimits.routinesMax, 'too_many_routines'],
      ['custom_exercises', DomainLimits.customExercisesMax, 'too_many_custom_exercises'],
      ['exercise_prefs', DomainLimits.exercisePrefsMax, 'too_many_exercise_prefs'],
      ['proposals', DomainLimits.proposalsMax, 'too_many_proposals'],
      ['gyms', DomainLimits.privateGymsTotalMax, 'too_many_gyms_total'],
      ['gym_equipment', DomainLimits.privateListingsTotalMax, 'too_many_listings_total'],
    ] as const
    for (const [table, max, code] of counted) {
      const trigger = `tbl = '${table}'), 0) >= ${max}\nBEGIN\n  SELECT RAISE(ABORT, '${code}');`
      expect(accountCaps.split(trigger).length - 1, code).toBe(1)
    }
    const logged = [
      [DomainLimits.accountEntriesMax, 'too_many_logged_exercises'],
      [DomainLimits.accountSetsMax, 'too_many_logged_sets'],
    ] as const
    for (const [max, code] of logged) {
      const trigger = `NEW.n > OLD.n AND NEW.n > ${max}\nBEGIN\n  SELECT RAISE(ABORT, '${code}');`
      expect(accountCaps.split(trigger).length - 1, code).toBe(1)
    }
    const pending = `status = 'pending') >= ${DomainLimits.pendingProposalsMax}\nBEGIN\n` +
      "  SELECT RAISE(ABORT, 'too_many_pending_proposals');"
    expect(accountCaps.split(pending).length - 1).toBe(1)
  })

  it("has PlanChange.swift's PlanChangeLimits in the server's plan validation", () => {
    const planChange = swiftPlanChangeLimits(planChangeSource)
    expect(Object.keys(planChange).length).toBeGreaterThanOrEqual(9)
    expect(PlanChangeLimits).toEqual(planChange)
  })
})
