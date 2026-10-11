// Recovery %, weekly hard sets and weekly streaks: a hand-maintained TypeScript port of GymCore's Insights
// (ios/Packages/GymCore/Sources/GymCore/Insights/*.swift, the source of truth). Both run the shared fixture
// fixtures/insights.json, so a change on one side only fails a test suite. Keep in sync with the Swift source by
// hand. Pure: no I/O, `now` and the IANA time zone are parameters.

export const MUSCLE_GROUPS = [
  'chest',
  'shoulders',
  'traps',
  'upper_back',
  'lats',
  'lower_back',
  'biceps',
  'triceps',
  'forearms',
  'abs',
  'glutes',
  'quads',
  'hamstrings',
  'calves',
  'adductors',
  'abductors',
] as const
export type MuscleGroup = typeof MUSCLE_GROUPS[number]

export const LEGS: ReadonlySet<MuscleGroup> = new Set([
  'glutes',
  'quads',
  'hamstrings',
  'calves',
  'adductors',
  'abductors',
])
const MAJOR: ReadonlySet<MuscleGroup> = new Set([
  'chest',
  'shoulders',
  'upper_back',
  'lats',
  'glutes',
  'quads',
  'hamstrings',
])

export interface TargetRange {
  min: number
  max: number
}

export function defaultTarget(group: MuscleGroup): TargetRange {
  return MAJOR.has(group) ? { min: 10, max: 20 } : { min: 6, max: 12 }
}

/** Library/custom exercise fields the maths needs (`sm` = secondary muscles). */
export interface InsightExercise {
  id: string
  bp: string
  tg: string
  sm?: string[] | null
  mode?: string | null
}

export interface InsightSet {
  r: number
  sec?: number | null
  min?: number | null
  done: boolean
  warmup: boolean
  rir?: number | null
  rpe?: number | null
}

export interface InsightWorkout {
  started_at: string
  ended_at: string | null
  workout_entries: { exercise_id: string; workout_sets: InsightSet[] }[]
}

// ---- Taxonomy (MuscleTaxonomy.swift) ------------------------------------------------------------------------------

const TARGETS: Record<string, MuscleGroup[]> = {
  'pectorals': ['chest'],
  'serratus anterior': ['chest'],
  'delts': ['shoulders'],
  'traps': ['traps'],
  'levator scapulae': ['traps'],
  'upper back': ['upper_back'],
  'lats': ['lats'],
  'spine': ['lower_back'],
  'biceps': ['biceps'],
  'triceps': ['triceps'],
  'forearms': ['forearms'],
  'abs': ['abs'],
  'glutes': ['glutes'],
  'quads': ['quads'],
  'hamstrings': ['hamstrings'],
  'calves': ['calves'],
  'adductors': ['adductors'],
  'abductors': ['abductors'],
}

const MUSCLES: Record<string, MuscleGroup> = {
  'chest': 'chest',
  'upper chest': 'chest',
  'shoulders': 'shoulders',
  'deltoids': 'shoulders',
  'rear deltoids': 'shoulders',
  'rotator cuff': 'shoulders',
  'trapezius': 'traps',
  'traps': 'traps',
  'sternocleidomastoid': 'traps',
  'upper back': 'upper_back',
  'rhomboids': 'upper_back',
  'back': 'upper_back',
  'latissimus dorsi': 'lats',
  'lats': 'lats',
  'lower back': 'lower_back',
  'biceps': 'biceps',
  'brachialis': 'biceps',
  'triceps': 'triceps',
  'forearms': 'forearms',
  'wrists': 'forearms',
  'wrist flexors': 'forearms',
  'wrist extensors': 'forearms',
  'grip muscles': 'forearms',
  'hands': 'forearms',
  'core': 'abs',
  'obliques': 'abs',
  'abdominals': 'abs',
  'lower abs': 'abs',
  'hip flexors': 'abs',
  'glutes': 'glutes',
  'quadriceps': 'quads',
  'hamstrings': 'hamstrings',
  'calves': 'calves',
  'soleus': 'calves',
  'ankles': 'calves',
  'ankle stabilizers': 'calves',
  'feet': 'calves',
  'shins': 'calves',
  'inner thighs': 'adductors',
  'groin': 'adductors',
}

const BODY_PARTS: Record<string, MuscleGroup[]> = {
  'chest': ['chest'],
  'back': ['lats', 'upper_back'],
  'shoulders': ['shoulders'],
  'upper arms': ['biceps', 'triceps'],
  'lower arms': ['forearms'],
  'upper legs': ['quads', 'hamstrings', 'glutes'],
  'lower legs': ['calves'],
  'waist': ['abs'],
  'neck': ['traps'],
}

const norm = (s: string) => s.trim().toLowerCase()

export interface Contribution {
  group: MuscleGroup
  weight: number
  primary: boolean
}

function isCardio(ex: InsightExercise): boolean {
  return ex.mode ? ex.mode === 'cardio' : ex.bp === 'cardio'
}

export function contributions(ex: InsightExercise): Contribution[] {
  if (isCardio(ex)) return []
  const key = norm(ex.tg)
  let primary = TARGETS[key] ?? (MUSCLES[key] ? [MUSCLES[key]] : [])
  if (primary.length === 0) primary = BODY_PARTS[norm(ex.bp)] ?? []
  const share = primary.length === 0 ? 0 : 1 / primary.length
  const seen = new Set<MuscleGroup>(primary)
  const out: Contribution[] = primary.map((group) => ({ group, weight: share, primary: true }))
  for (const muscle of ex.sm ?? []) {
    const group = MUSCLES[norm(muscle)]
    if (!group || seen.has(group)) continue
    seen.add(group)
    out.push({ group, weight: 0.5, primary: false })
  }
  return out
}

// ---- Hard sets (HardSets.swift) -------------------------------------------------------------------------------

export function isHard(s: InsightSet): boolean {
  if (!s.done || s.warmup) return false
  return s.r > 0 || (s.sec ?? 0) > 0 || (s.min ?? 0) > 0
}

export function effort(s: InsightSet): number {
  const rir = s.rir ?? (s.rpe != null ? 10 - s.rpe : null)
  if (rir == null) return 1
  const band = Math.floor(rir)
  if (band < 2) return 1
  if (band === 2) return 0.9
  if (band === 3) return 0.75
  if (band === 4) return 0.6
  return 0.5
}

interface Load {
  sets: number
  load: number
}

function loads(
  w: InsightWorkout,
  exercise: (id: string) => InsightExercise | undefined,
): Map<MuscleGroup, Load> {
  const out = new Map<MuscleGroup, Load>()
  for (const entry of w.workout_entries) {
    const ex = exercise(entry.exercise_id)
    if (!ex) continue
    const cs = contributions(ex)
    const hard = entry.workout_sets.filter(isHard)
    if (cs.length === 0 || hard.length === 0) continue
    const eff = hard.reduce((a, s) => a + effort(s), 0)
    for (const c of cs) {
      const cur = out.get(c.group) ?? { sets: 0, load: 0 }
      out.set(c.group, { sets: cur.sets + hard.length * c.weight, load: cur.load + eff * c.weight })
    }
  }
  return out
}

// ---- Recovery (RecoveryModel.swift) -----------------------------------------------------------------------------

export const RECOVERY_MAX_HOURS = 96
export const recoveryHours = (load: number) => Math.min(Math.max(24 + 6 * load, 24), RECOVERY_MAX_HOURS)

export interface MuscleRecovery {
  group: MuscleGroup
  percent: number
  status: 'fresh' | 'recovering' | 'fatigued'
  last_trained: string | null
  recovered_at: string | null
}

export const statusOf = (percent: number): MuscleRecovery['status'] =>
  percent >= 90 ? 'fresh' : percent >= 50 ? 'recovering' : 'fatigued'

const HOUR = 3_600_000

export function recovery(
  workouts: InsightWorkout[],
  exercise: (id: string) => InsightExercise | undefined,
  now: Date,
): MuscleRecovery[] {
  const fatigue = new Map<MuscleGroup, number>()
  const last = new Map<MuscleGroup, number>()
  const done = new Map<MuscleGroup, number>()
  for (const w of workouts) {
    const at = new Date(w.ended_at ?? w.started_at).getTime()
    if (at > now.getTime()) continue
    const elapsed = (now.getTime() - at) / HOUR
    for (const [group, l] of loads(w, exercise)) {
      last.set(group, Math.max(last.get(group) ?? -Infinity, at))
      const hours = recoveryHours(l.load)
      if (elapsed >= hours) continue
      fatigue.set(group, (fatigue.get(group) ?? 0) + Math.min(1, l.load / 6) * (1 - elapsed / hours))
      done.set(group, Math.max(done.get(group) ?? -Infinity, at + hours * HOUR))
    }
  }
  return MUSCLE_GROUPS.map((group) => {
    const f = Math.min(1, fatigue.get(group) ?? 0)
    const percent = Math.round(100 * (1 - f))
    const l = last.get(group)
    const d = done.get(group)
    return {
      group,
      percent,
      status: statusOf(percent),
      last_trained: l !== undefined ? new Date(l).toISOString() : null,
      recovered_at: f > 0 && d !== undefined ? new Date(d).toISOString() : null,
    }
  })
}

/** RecoveryModel.freshest: fresh, trained within `rotationDays`, not limited; most recovered, longest ago first. */
export function freshest(
  rows: MuscleRecovery[],
  limited: ReadonlySet<MuscleGroup>,
  now: Date,
  rotationDays = 28,
  count = 3,
): MuscleGroup[] {
  const since = now.getTime() - rotationDays * 24 * HOUR
  const order = (g: MuscleGroup) => MUSCLE_GROUPS.indexOf(g)
  const t = (r: MuscleRecovery) => (r.last_trained ? new Date(r.last_trained).getTime() : -Infinity)
  return rows
    .filter((r) => r.last_trained !== null && r.status === 'fresh' && t(r) >= since && !limited.has(r.group))
    .sort((a, b) => b.percent - a.percent || t(a) - t(b) || order(a.group) - order(b.group))
    .slice(0, count)
    .map((r) => r.group)
}

/** LimitedMuscles.swift: a knee/leg mention in the free-text limits note flags the leg groups (display only). */
export function limitedMuscles(limits: string): Set<MuscleGroup> {
  const words = limits.toLowerCase().split(/[^\p{L}]+/u)
  return words.some((w) => ['knee', 'knees', 'leg', 'legs'].includes(w)) ? new Set(LEGS) : new Set()
}

// ---- Weeks (TrainingWeek.swift): Monday–Sunday in an IANA time zone ------------------------------------------------

/** Throws RangeError for an unknown IANA zone. */
export function assertTimeZone(tz: string): void {
  new Intl.DateTimeFormat('en-US', { timeZone: tz })
}

const DAY_MS = 24 * HOUR

/** The civil date (yyyy-mm-dd, as a UTC-midnight epoch) of `t` in `tz`. */
function civilDay(t: number, tz: string): number {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: tz,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  })
    .formatToParts(new Date(t))
  const get = (type: string) => Number(parts.find((p) => p.type === type)?.value)
  return Date.UTC(get('year'), get('month') - 1, get('day'))
}

/** The Monday (civil date epoch) of the week containing `t` in `tz`. */
export function weekKey(t: number, tz: string): number {
  const day = civilDay(t, tz)
  const weekday = (new Date(day).getUTCDay() + 6) % 7 // Monday = 0
  return day - weekday * DAY_MS
}

export const isoDay = (civil: number) => new Date(civil).toISOString().slice(0, 10)

/** WeeklySets.count: hard sets (primary 1, secondary 0.5) of workouts that started in `now`'s week. */
export function weeklySets(
  workouts: InsightWorkout[],
  exercise: (id: string) => InsightExercise | undefined,
  now: Date,
  tz: string,
): Map<MuscleGroup, number> {
  const week = weekKey(now.getTime(), tz)
  const out = new Map<MuscleGroup, number>()
  for (const w of workouts) {
    if (weekKey(new Date(w.started_at).getTime(), tz) !== week) continue
    for (const [group, l] of loads(w, exercise)) out.set(group, (out.get(group) ?? 0) + l.sets)
  }
  return out
}

// ---- Streak (StreakCalculator.swift) --------------------------------------------------------------------------

export interface Streak {
  current: number
  longest: number
  goal: number
  this_week_days: number
  this_week_met: boolean
}

export function streak(startedAt: string[], rawGoal: number, now: Date, tz: string): Streak {
  const goal = Math.min(Math.max(Math.trunc(rawGoal), 1), 7)
  const days = new Map<number, Set<number>>()
  for (const iso of startedAt) {
    const t = new Date(iso).getTime()
    if (t > now.getTime()) continue
    const week = weekKey(t, tz)
    days.set(week, (days.get(week) ?? new Set()).add(civilDay(t, tz)))
  }
  const count = (week: number) => days.get(week)?.size ?? 0
  const met = (week: number) => count(week) >= goal
  const thisWeek = weekKey(now.getTime(), tz)
  let current = 0
  for (let week = met(thisWeek) ? thisWeek : thisWeek - 7 * DAY_MS; met(week); week -= 7 * DAY_MS) current++
  let longest = 0
  let run = 0
  let prev: number | null = null
  for (const week of [...days.keys()].sort((a, b) => a - b)) {
    if (!met(week)) continue
    run = prev !== null && week - 7 * DAY_MS === prev ? run + 1 : 1
    longest = Math.max(longest, run)
    prev = week
  }
  return { current, longest, goal, this_week_days: count(thisWeek), this_week_met: met(thisWeek) }
}
