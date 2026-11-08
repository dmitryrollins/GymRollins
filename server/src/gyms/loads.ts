import { DomainLimits } from '../shared/domain-limits.ts'

// A listing's loads (gym_private.valid_loads and valid_kg, supabase/migrations/20261030000001_gyms.sql): exact keys and
// numbers within the limits, because every client decodes these rows and one unreadable row would break a whole gym.
// Stored as compact JSON rebuilt from the checked values, so what D1 holds is short and in one key order.

export type Loads =
  | { readonly type: 'none' | 'plates' }
  | { readonly type: 'stack'; readonly maxKg: number; readonly stepKg?: number }
  | { readonly type: 'fixed'; readonly kg: readonly number[] }

interface Range {
  readonly min: number
  readonly max: number
}

/** valid_kg: a number within the range, whose text is short enough for every client to decode. */
function isKg(value: unknown, range: Range): value is number {
  return typeof value === 'number' && Number.isFinite(value) && String(value).length <= 24 &&
    value >= range.min && value <= range.max
}

/** Exactly these keys, compared one by one (a key may itself hold a comma). */
function hasKeys(value: object, keys: readonly string[]): boolean {
  const actual = Object.keys(value).sort()
  const wanted = [...keys].sort()
  return actual.length === wanted.length && actual.every((key, i) => key === wanted[i])
}

/** The loads to store, or null for anything valid_loads refused. A null stepKg means none and is dropped. */
export function parseLoads(raw: unknown): Loads | null {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return null
  const loads = raw as Record<string, unknown>
  switch (loads.type) {
    case 'none':
    case 'plates':
      return hasKeys(loads, ['type']) ? { type: loads.type } : null
    case 'stack': {
      if (!hasKeys(loads, ['maxKg', 'type']) && !hasKeys(loads, ['maxKg', 'stepKg', 'type'])) return null
      const { maxKg, stepKg } = loads
      if (!isKg(maxKg, DomainLimits.listingStackKg)) return null
      if (stepKg === undefined || stepKg === null) return { type: 'stack', maxKg }
      if (!isKg(stepKg, DomainLimits.listingStepKg) || stepKg > maxKg) return null
      return { type: 'stack', maxKg, stepKg }
    }
    case 'fixed': {
      const { kg } = loads
      if (!hasKeys(loads, ['kg', 'type']) || !Array.isArray(kg)) return null
      if (kg.length < 1 || kg.length > DomainLimits.listingFixedWeightsMax) return null
      if (!kg.every((weight) => isKg(weight, DomainLimits.listingFixedKg))) return null
      return { type: 'fixed', kg: kg as number[] }
    }
    default:
      return null
  }
}
