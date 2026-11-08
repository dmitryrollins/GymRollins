import { describe, expect, it } from 'vitest'
import swiftSource from '../../ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift?raw'
import appSchema from '../migrations/0002_app_schema.sql?raw'
import capsMigration from '../migrations/0005_gyms_photos.sql?raw'
import { DomainLimits } from '../src/shared/domain-limits.ts'

// Fails when the server's limits drift from the Swift source of truth, or from the D1 CHECKs that enforce them. The
// Swift file is read as text: `public static let name = 40` and `public static let name: ClosedRange<T> = lo...hi`.
// The Deno test beside supabase/functions/_shared checks the Supabase copy until plan 30.

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

const swift = swiftLimits(swiftSource)
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

describe('domain limits', () => {
  it('finds the Swift constants (a parser that matched nothing would pass everything)', () => {
    expect(Object.keys(swift).length).toBeGreaterThanOrEqual(40)
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
})
