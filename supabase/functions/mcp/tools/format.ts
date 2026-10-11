// Formatting and training math shared by the tools. Mirrors the Swift app:
//   WeightFormatter / UnitConverter (GymCore/Units), OneRepMax (GymCore/Strength), WorkoutMetrics (GymCore/Metrics).
import type { SetRow, WeightUnit } from '../db.ts'
import { ToolError } from './result.ts'

export const KG_PER_LB = 0.45359237
const DAY_MS = 86_400_000
export const WEEK_MS = 7 * DAY_MS
/** OneRepMax.maxReps — estimates above this are unreliable and not reported. */
export const E1RM_MAX_REPS = 12

export const round = (value: number, decimals: number): number => {
  const f = 10 ** decimals
  return Math.round(value * f) / f
}

/** At most one decimal, trailing ".0" removed (WeightFormatter.number). */
export function formatNumber(value: number): string {
  const r = round(value, 1)
  return Number.isInteger(r) ? String(r) : r.toFixed(1)
}

/** "140 lb (63.5 kg)" for lb, "20 kg (44.1 lb)" for kg (WeightFormatter.format). */
export function displayWeight(kg: number, unit: WeightUnit): string {
  const lb = kg / KG_PER_LB
  return unit === 'lb'
    ? `${formatNumber(lb)} lb (${formatNumber(kg)} kg)`
    : `${formatNumber(kg)} kg (${formatNumber(lb)} lb)`
}

export function weight(kg: number, unit: WeightUnit): { weight_kg: number; weight_display: string } {
  return { weight_kg: round(kg, 2), weight_display: displayWeight(kg, unit) }
}

/** Epley estimate for 1…12 reps; 1 rep is the weight itself (OneRepMax.estimate). */
export function epley(weightKg: number, reps: number): number | null {
  if (weightKg <= 0 || reps < 1 || reps > E1RM_MAX_REPS) return null
  return reps === 1 ? weightKg : weightKg * (1 + reps / 30)
}

/** Done, non-warm-up sets (WorkoutMetrics.workingSets). */
export function workingSets(sets: SetRow[]): SetRow[] {
  return sets.filter((s) => s.done && !s.warmup)
}

export function setVolumeKg(sets: SetRow[]): number {
  return workingSets(sets).reduce((sum, s) => sum + s.w_kg * s.r * s.multiplier, 0)
}

/** Heaviest working set; ties go to more reps. */
export function topSet(sets: SetRow[]): SetRow | null {
  return workingSets(sets).reduce<SetRow | null>(
    (best, s) => (!best || s.w_kg > best.w_kg || (s.w_kg === best.w_kg && s.r > best.r) ? s : best),
    null,
  )
}

export function bestE1rm(sets: SetRow[]): number | null {
  const values = workingSets(sets).map((s) => epley(s.w_kg, s.r)).filter((v): v is number => v !== null)
  return values.length ? Math.max(...values) : null
}

/** UTC calendar date of an ISO timestamp. */
export function isoDate(ts: string): string {
  return new Date(ts).toISOString().slice(0, 10)
}

const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/

/**
 * Parses a tool date argument (YYYY-MM-DD or ISO timestamp). A date-only `end` bound is exclusive at the next
 * midnight UTC, so "until 2026-09-15" includes that whole day.
 */
export function parseBound(value: string, field: string, bound: 'start' | 'end' = 'start'): Date {
  const d = new Date(DATE_ONLY.test(value) ? `${value}T00:00:00Z` : value)
  if (Number.isNaN(d.getTime())) throw new ToolError(`'${field}' must be a date like 2026-09-15`)
  return DATE_ONLY.test(value) && bound === 'end' ? new Date(d.getTime() + DAY_MS) : d
}

export function daysBefore(now: Date, days: number): Date {
  return new Date(now.getTime() - days * DAY_MS)
}

/** Monday 00:00 UTC of the ISO week containing `d`. */
export function mondayOf(d: Date): Date {
  const midnight = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate())
  const sinceMonday = (d.getUTCDay() + 6) % 7
  return new Date(midnight - sinceMonday * DAY_MS)
}

/** Least-squares slope in value per week, rounded to 2 decimals; null with fewer than 2 points or no spread. */
export function slopePerWeek(points: { t: number; v: number }[]): number | null {
  if (points.length < 2) return null
  const n = points.length
  const mt = points.reduce((s, p) => s + p.t, 0) / n
  const mv = points.reduce((s, p) => s + p.v, 0) / n
  const sxx = points.reduce((s, p) => s + (p.t - mt) ** 2, 0)
  if (sxx === 0) return null
  const sxy = points.reduce((s, p) => s + (p.t - mt) * (p.v - mv), 0)
  return round((sxy / sxx) * WEEK_MS, 2)
}

export const clamp = (value: number, lo: number, hi: number): number => Math.min(hi, Math.max(lo, value))
