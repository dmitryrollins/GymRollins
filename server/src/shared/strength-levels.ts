// Strength levels (Beginner → Elite) for squat, bench press and deadlift: a hand-maintained TypeScript port of
// GymCore's Strength/StrengthStandards.swift, StrengthLevel.swift and StrengthReport.swift (the source of truth).
// Both run the shared fixture fixtures/strength-levels.json on the same table (strength-standards.json, a copy of
// the app's Resources/strength-standards.json kept identical by scripts/build-strength-standards.test.mjs), so a
// change on one side only fails a test suite. Pure: no I/O, `now` is a parameter; ages use the UTC year.
import { limitedMuscles } from './insights.ts'

export const LIFTS = ['squat', 'bench', 'deadlift'] as const
export type Lift = typeof LIFTS[number]
export type Sex = 'male' | 'female'
export const LEVELS = ['beginner', 'novice', 'intermediate', 'advanced', 'elite'] as const
export type Level = typeof LEVELS[number]

/** StrengthLift.exerciseIds: the competition lifts and their duplicates, all at full e1RM. */
export const LIFT_EXERCISES: Record<Lift, readonly string[]> = {
  squat: ['0043', '1461', '1462', '1435', '1436'],
  bench: ['0025'],
  deadlift: ['0032', '0117'],
}
export const LEGS_LIFTS: ReadonlySet<Lift> = new Set(['squat', 'deadlift'])
export const WINDOW_DAYS = 365
export const MIN_AGE = 14
const E1RM_MAX_REPS = 12

export interface Bin {
  bw: number
  n: number
  kg: number[]
}

export interface Standards {
  formatVersion: number
  source: { name: string; url: string; license: string; version: string }
  percentiles: number[]
  ageGroups: { id: string; label: string; min: number; max: number }[]
  levels: { id: string; name: string; percentile: number; fraction: number }[]
  tables: Record<string, Record<string, Record<string, Bin[]>>>
}

export interface StrengthSet {
  w_kg: number
  r: number
  done: boolean
  warmup: boolean
}

export interface StrengthWorkout {
  started_at: string
  workout_entries: { exercise_id: string; workout_sets: StrengthSet[] }[]
}

export interface Assessment {
  level: Level
  percentile: number
  percentile_text: string
  thresholds: Record<Level, number>
  next: Level | null
  next_target_kg: number | null
  gap_kg: number | null
  progress: number
}

export interface LiftEstimate {
  e1rm_kg: number
  date: string
  exercise_id: string
}

export interface StrengthRow {
  lift: Lift
  estimate: LiftEstimate | null
  assessment: Assessment | null
  paused: boolean
}

export type Missing = 'profile' | 'bodyweight'

export interface StrengthReport {
  rows: StrengthRow[]
  missing: Missing[]
  age: number | null
}

const tableKey = (sex: Sex) => (sex === 'male' ? 'M' : 'F')

export function ageGroup(s: Standards, age: number) {
  return s.ageGroups.find((g) => age >= g.min && age <= g.max) ?? null
}

/** StrengthStandards.curve: linear between the bins bracketing the bodyweight, end bins beyond. */
export function curve(
  s: Standards,
  sex: Sex,
  lift: Lift,
  age: number,
  bodyweightKg: number,
): number[] | null {
  const group = ageGroup(s, age)
  const bins = group ? s.tables[tableKey(sex)]?.[lift]?.[group.id] : undefined
  if (!bins || bins.length === 0) return null
  const first = bins[0]
  const last = bins[bins.length - 1]
  if (bodyweightKg <= first.bw) return first.kg
  if (bodyweightKg >= last.bw) return last.kg
  const upper = bins.findIndex((b) => b.bw >= bodyweightKg)
  if (upper <= 0) return first.kg
  const lo = bins[upper - 1]
  const hi = bins[upper]
  const t = hi.bw > lo.bw ? (bodyweightKg - lo.bw) / (hi.bw - lo.bw) : 0
  return lo.kg.map((v, i) => v + (hi.kg[i] - v) * t)
}

export function valueAt(p: number, c: number[], ps: number[]): number {
  if (p <= ps[0]) return c[0]
  if (p >= ps[ps.length - 1]) return c[c.length - 1]
  const hi = ps.findIndex((x) => x >= p)
  const lo = hi - 1
  return c[lo] + (c[hi] - c[lo]) * ((p - ps[lo]) / (ps[hi] - ps[lo]))
}

export function percentileOf(kg: number, c: number[], ps: number[]): number {
  if (kg < c[0]) return c[0] > 0 ? (ps[0] * kg) / c[0] : 0
  if (kg >= c[c.length - 1]) return 100
  const hi = c.findIndex((x) => x > kg)
  const lo = hi - 1
  return ps[lo] + (ps[hi] - ps[lo]) * ((kg - c[lo]) / (c[hi] - c[lo]))
}

export function percentileText(p: number, ps: number[]): string {
  const lo = ps[0]
  const hi = ps[ps.length - 1]
  if (p < lo) return `under ${Math.trunc(lo)}%`
  if (p > hi) return `over ${Math.trunc(hi)}%`
  return `${Math.floor(p)}%`
}

/** StrengthLevelCalculator.assess. */
export function assess(
  s: Standards,
  lift: Lift,
  e1rmKg: number,
  bodyweightKg: number,
  sex: Sex,
  age: number,
): Assessment | null {
  if (!(e1rmKg > 0) || !(bodyweightKg > 0)) return null
  const c = curve(s, sex, lift, age, bodyweightKg)
  if (!c) return null
  const thresholds = {} as Record<Level, number>
  let floor = 0
  for (const anchor of s.levels) {
    if (!(LEVELS as readonly string[]).includes(anchor.id)) continue
    floor = Math.max(floor, anchor.fraction * valueAt(anchor.percentile, c, s.percentiles))
    thresholds[anchor.id as Level] = floor
  }
  const level = [...LEVELS].reverse().find((l) => (thresholds[l] ?? Infinity) <= e1rmKg + 1e-9) ?? 'beginner'
  const i = LEVELS.indexOf(level)
  const next = i + 1 < LEVELS.length ? LEVELS[i + 1] : null
  const target = next ? thresholds[next] : null
  const base = thresholds[level] ?? 0
  const progress = target === null
    ? 1
    : target > base
    ? Math.min(1, Math.max(0, (e1rmKg - base) / (target - base)))
    : 1
  const percentile = percentileOf(e1rmKg, c, s.percentiles)
  return {
    level,
    percentile,
    percentile_text: percentileText(percentile, s.percentiles),
    thresholds,
    next,
    next_target_kg: target,
    gap_kg: target === null ? null : Math.max(0, target - e1rmKg),
    progress,
  }
}

function epley(kg: number, reps: number): number | null {
  if (kg <= 0 || reps < 1 || reps > E1RM_MAX_REPS) return null
  return reps === 1 ? kg : kg * (1 + reps / 30)
}

/** StrengthReport.best: best e1RM among the lift's exercises in the window; ties keep the most recent. */
export function best(workouts: StrengthWorkout[], lift: Lift, now: Date): LiftEstimate | null {
  const since = now.getTime() - WINDOW_DAYS * 86_400_000
  let out: (LiftEstimate & { t: number }) | null = null
  for (const w of workouts) {
    const t = Date.parse(w.started_at)
    if (t < since || t > now.getTime()) continue
    for (const e of w.workout_entries) {
      if (!LIFT_EXERCISES[lift].includes(e.exercise_id)) continue
      const values = e.workout_sets.filter((s) => s.done && !s.warmup).map((s) => epley(s.w_kg, s.r))
        .filter((v): v is number => v !== null)
      if (values.length === 0) continue
      const e1rm = Math.max(...values)
      if (out && (e1rm < out.e1rm_kg || (e1rm === out.e1rm_kg && t <= out.t))) continue
      out = { e1rm_kg: e1rm, date: w.started_at, exercise_id: e.exercise_id, t }
    }
  }
  return out && { e1rm_kg: out.e1rm_kg, date: out.date, exercise_id: out.exercise_id }
}

/** StrengthGap.text: "+15 lb" / "+7 kg", the gap rounded UP to 2.5 lb or 0.5 kg. */
export function gapText(kg: number, unit: 'kg' | 'lb'): string {
  const step = unit === 'lb' ? 2.5 : 0.5
  const value = unit === 'lb' ? kg / 0.45359237 : kg
  const rounded = Math.max(step, Math.ceil(value / step - 1e-9) * step)
  const r = Math.round(rounded * 10) / 10
  return `+${Number.isInteger(r) ? r : r.toFixed(1)} ${unit}`
}

/** StrengthReport.make (age from the UTC year of `now`). */
export function report(
  s: Standards,
  input: {
    workouts: StrengthWorkout[]
    sex: Sex | null
    birthYear: number | null
    bodyweightKg: number | null
    limits: string
    now: Date
  },
): StrengthReport {
  const age = input.birthYear === null ? null : input.now.getUTCFullYear() - input.birthYear
  const missing: Missing[] = []
  if (input.sex === null || age === null || age < MIN_AGE || !ageGroup(s, age)) missing.push('profile')
  if (input.bodyweightKg === null) missing.push('bodyweight')
  const legsLimited = limitedMuscles(input.limits).size > 0
  const rows = LIFTS.map((lift) => {
    const estimate = best(input.workouts, lift, input.now)
    const assessment =
      missing.length === 0 && estimate && input.sex && age !== null && input.bodyweightKg !== null
        ? assess(s, lift, estimate.e1rm_kg, input.bodyweightKg, input.sex, age)
        : null
    return { lift, estimate, assessment, paused: legsLimited && LEGS_LIFTS.has(lift) }
  })
  return { rows, missing, age }
}
