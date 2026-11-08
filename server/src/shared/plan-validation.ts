// TypeScript port of PlanChangeValidator + PlanChangeValidator+Families (Swift, GymCore). Validates Claude's
// proposals against the closed change list, value ranges and the current plan.
//
// Ported EXACTLY from:
//   ios/Packages/GymCore/Sources/GymCore/Plan/PlanChangeValidator.swift
//   ios/Packages/GymCore/Sources/GymCore/Plan/PlanChangeValidator+Families.swift
//   ios/Packages/GymCore/Sources/GymCore/Plan/PlanChange.swift
// Shares the fixture app/fixtures/plan-changes.json with the Swift tests — see plan-validation.test.ts. The
// Swift behavior is the reference; keep this file in sync with it by hand, not by re-deriving the rules.
import { DomainLimits } from './domain-limits.ts'

export type PlanChangeType =
  | 'add-exercise'
  | 'remove-exercise'
  | 'swap-exercise'
  | 'sets'
  | 'reps'
  | 'repsMin'
  | 'sec'
  | 'weight'
  | 'cardio'
  | 'reorder'
  | 'superset'
  | 'routine-prog'
  | 'exercise-prog'
  | 'inc'
  | 'add-routine'
  | 'remove-routine'
  | 'rename-routine'
  | 'pause-routine'
  | 'week'
  | 'today'

export type ProgressionPolicy = 'off' | 'linear' | 'greyskull' | 'double' | 'time'

/** One proposed plan edit. Field names are the JSON contract shared with the MCP server and the app. */
export interface PlanChange {
  id: string
  type: PlanChangeType
  routineId?: string
  exerciseId?: string
  toExerciseId?: string
  withExerciseId?: string
  sets?: number
  reps?: number
  repsMin?: number
  sec?: number
  weightKg?: number
  minutes?: number
  speed?: number
  incKg?: number
  policy?: ProgressionPolicy
  position?: number
  name?: string
  weekday?: number
  paused?: boolean
  /** `today` only: the owner's local date (YYYY-MM-DD) the one-off routine is for. */
  date?: string
  reason?: string
}

export interface PlanProposal {
  summary: string
  changes: PlanChange[]
}

export interface RoutineRef {
  id: string
  name: string
  exerciseIds: string[]
  /** Effective top-of-range reps per exerciseId, when known. */
  reps?: Record<string, number>
  /** Effective bottom-of-range reps per exerciseId, when known. */
  repsMin?: Record<string, number>
  /** Paused routines can't be picked for a `today` change. */
  paused?: boolean
}

export interface PlanSnapshot {
  routines: RoutineRef[]
}

export interface PlanViolation {
  changeId: string | null
  field: string
  message: string
}

// Limits — mirrors PlanChangeValidator's `static let`s in Swift.
const MAX_CHANGES = 25
const MAX_ROUTINES = 7
const MAX_EXERCISES_PER_ROUTINE = DomainLimits.routineExercisesMax
const MAX_SUMMARY = 500
const MAX_REASON = 300
const MAX_NAME = DomainLimits.routineNameMax

/** Value ranges a change may carry — mirrors PlanChangeLimits (Swift, PlanChange.swift). */
export const PlanChangeLimits = {
  sets: { min: 1, max: 10 },
  reps: { min: 1, max: 100 },
  sec: { min: 5, max: 3600 },
  minutes: { min: 1, max: 300 },
  speed: { min: 0, max: 50 },
  weightKg: { min: 0, max: 500 },
  incKg: { min: 0.1, max: 20 },
  position: { min: 0, max: DomainLimits.routineExercisesMax - 1 },
  /** How many days after the owner's date a `today` change may be for (0 = today). */
  todayDaysAhead: { min: 0, max: 7 },
} as const
type Bounds = { readonly min: number; readonly max: number }

/**
 * Routine state threaded through a proposal: exercise membership plus effective rep ranges (exerciseId →
 * value), so a later change can validate against reps/repsMin an earlier change in the same proposal set,
 * without re-reading the original snapshot. Mirrors PlanChangeValidator.RoutineState (Swift).
 */
interface RoutineState {
  exerciseIds: string[]
  reps: Record<string, number>
  repsMin: Record<string, number>
  paused: boolean
}

/**
 * The reference date for `today` changes. `today` is the owner's YYYY-MM-DD (omit it to check only the format);
 * `slackDays` widens the allowed window on both sides — the server passes 1 because it only knows UTC, and the
 * app re-checks against the owner's own date when applying.
 */
export interface ValidateOptions {
  today?: string
  slackDays?: number
}

/** Days since 1970-01-01 for a real calendar date written YYYY-MM-DD, or undefined. Mirrors PlanDay (Swift). */
export function dayNumber(value: string): number | undefined {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value)
  if (!m) return undefined
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])]
  const ms = Date.UTC(y, mo - 1, d)
  const back = new Date(ms)
  if (back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d) {
    return undefined
  }
  return Math.round(ms / 86_400_000)
}

/** YYYY-MM-DD of `date` in UTC. */
export function utcDay(date: Date): string {
  return date.toISOString().slice(0, 10)
}

function isNil(value: unknown): value is undefined | null {
  return value === undefined || value === null
}

function cloneRoutines(routines: Record<string, RoutineState>): Record<string, RoutineState> {
  const out: Record<string, RoutineState> = {}
  for (const [id, state] of Object.entries(routines)) {
    out[id] = {
      exerciseIds: [...state.exerciseIds],
      reps: { ...state.reps },
      repsMin: { ...state.repsMin },
      paused: state.paused,
    }
  }
  return out
}

/**
 * Mutable per-change validation scratchpad shared by every change family: field helpers (fail/require/range/
 * name), routine/exercise lookups, and the routine state after applying this one change (only actually applied
 * when the change turned out valid). Mirrors PlanChangeChecker (Swift).
 */
class PlanChangeChecker {
  readonly violations: PlanViolation[] = []
  routines: Record<string, RoutineState>
  routineExercises: string[] | undefined

  constructor(
    private readonly exerciseExists: (id: string) => boolean,
    private readonly change: PlanChange,
    routines: Record<string, RoutineState>,
  ) {
    this.routines = routines
  }

  /** Resolves `change.routineId` (when this change type needs one) before any family runs. */
  prepare(): void {
    this.routineExercises = this.resolveRoutine()
  }

  // ---- Shared field helpers -----------------------------------------------------------------------------

  fail(field: string, message: string): void {
    this.violations.push({ changeId: this.change.id, field, message })
  }

  requireField<T>(value: T | undefined | null, field: string): T | undefined {
    if (isNil(value)) {
      this.fail(field, `Required for ${this.change.type}`)
      return undefined
    }
    return value
  }

  range(value: number | undefined, field: string, bounds: Bounds, required = true): void {
    const v = required ? this.requireField(value, field) : value
    if (isNil(v)) return
    // NaN/±Infinity fail too (Swift's ClosedRange.contains rejects NaN; JSON can't carry Infinity).
    if (!Number.isFinite(v) || v < bounds.min || v > bounds.max) {
      this.fail(field, `Must be ${bounds.min}–${bounds.max}`)
    }
  }

  name(value: string | undefined): void {
    const v = this.requireField(value, 'name')
    if (isNil(v)) return
    const trimmed = v.trim()
    if (trimmed.length === 0 || trimmed.length > MAX_NAME) {
      this.fail('name', `Name must be 1–${MAX_NAME} characters`)
    }
  }

  private resolveRoutine(): string[] | undefined {
    if (this.change.type === 'add-routine' || this.change.type === 'week') return undefined
    const id = this.requireField(this.change.routineId, 'routineId')
    if (isNil(id)) return undefined
    const state = this.routines[id]
    if (!state) {
      this.fail('routineId', `Unknown routine '${id}'`)
      return undefined
    }
    return state.exerciseIds
  }

  inRoutine(id: string | undefined, field: string): string | undefined {
    const v = this.requireField(id, field)
    if (isNil(v) || isNil(this.routineExercises)) return undefined
    if (!this.routineExercises.includes(v)) {
      this.fail(field, `'${v}' is not in this routine`)
      return undefined
    }
    return v
  }

  inLibrary(id: string | undefined, field: string): string | undefined {
    const v = this.requireField(id, field)
    if (isNil(v)) return undefined
    if (!this.exerciseExists(v)) {
      this.fail(field, `Unknown exercise '${v}'`)
      return undefined
    }
    return v
  }

  // ---- Routine/effective-reps mutation (only takes effect when this change is valid so far) --------------

  updateRoutine(id: string, exerciseIds: string[]): void {
    if (this.violations.length > 0) return
    const state = this.routines[id]
    if (state) state.exerciseIds = exerciseIds
  }

  addRoutine(id: string): void {
    if (this.violations.length > 0) return
    this.routines[id] = { exerciseIds: [], reps: {}, repsMin: {}, paused: false }
  }

  removeRoutine(id: string): void {
    if (this.violations.length > 0) return
    delete this.routines[id]
  }

  effectiveReps(routineId: string | undefined, exerciseId: string | undefined): number | undefined {
    if (isNil(routineId) || isNil(exerciseId)) return undefined
    return this.routines[routineId]?.reps[exerciseId]
  }

  effectiveRepsMin(routineId: string | undefined, exerciseId: string | undefined): number | undefined {
    if (isNil(routineId) || isNil(exerciseId)) return undefined
    return this.routines[routineId]?.repsMin[exerciseId]
  }

  setEffectiveReps(
    routineId: string,
    exerciseId: string,
    reps: number | undefined,
    repsMin: number | undefined,
  ): void {
    if (this.violations.length > 0) return
    const state = this.routines[routineId]
    if (!state) return
    if (!isNil(reps)) state.reps[exerciseId] = reps
    if (!isNil(repsMin)) state.repsMin[exerciseId] = repsMin
  }

  moveEffectiveReps(routineId: string, from: string, to: string): void {
    if (this.violations.length > 0) return
    const state = this.routines[routineId]
    if (!state) return
    if (from in state.reps) {
      state.reps[to] = state.reps[from]
      delete state.reps[from]
    }
    if (from in state.repsMin) {
      state.repsMin[to] = state.repsMin[from]
      delete state.repsMin[from]
    }
  }

  removeEffectiveReps(routineId: string, exerciseId: string): void {
    if (this.violations.length > 0) return
    const state = this.routines[routineId]
    if (!state) return
    delete state.reps[exerciseId]
    delete state.repsMin[exerciseId]
  }

  // ---- Exercise edits (add/remove/swap an exercise within a routine) --------------------------------------

  checkExerciseEdit(): void {
    const c = this.change
    switch (c.type) {
      case 'add-exercise':
        this.checkAddExercise()
        break
      case 'remove-exercise': {
        const id = this.inRoutine(c.exerciseId, 'exerciseId')
        if (!isNil(id) && !isNil(c.routineId) && this.routineExercises) {
          const rid = c.routineId
          const list = this.routineExercises
          this.updateRoutine(rid, list.filter((x) => x !== id))
          this.removeEffectiveReps(rid, id)
        }
        break
      }
      case 'swap-exercise':
        this.checkSwapExercise()
        break
      default:
        break
    }
  }

  private checkAddExercise(): void {
    const c = this.change
    const id = this.inLibrary(c.exerciseId, 'exerciseId')
    this.range(c.sets, 'sets', PlanChangeLimits.sets)
    this.range(c.reps, 'reps', PlanChangeLimits.reps)
    this.optionalTargets(c.reps)
    this.range(c.position, 'position', PlanChangeLimits.position, false)
    if (isNil(id) || isNil(this.routineExercises) || isNil(c.routineId)) return
    const list = this.routineExercises
    const rid = c.routineId
    if (list.includes(id)) {
      this.fail('exerciseId', 'Already in routine')
    } else if (list.length >= MAX_EXERCISES_PER_ROUTINE) {
      this.fail('exerciseId', 'Routine is full')
    } else if (this.violations.length === 0) {
      this.updateRoutine(rid, [...list, id])
      this.setEffectiveReps(rid, id, c.reps, c.repsMin)
    }
  }

  private checkSwapExercise(): void {
    const c = this.change
    const from = this.inRoutine(c.exerciseId, 'exerciseId')
    const to = this.inLibrary(c.toExerciseId, 'toExerciseId')
    if (!isNil(to) && this.routineExercises?.includes(to)) this.fail('toExerciseId', 'Already in routine')
    this.range(c.sets, 'sets', PlanChangeLimits.sets, false)
    this.range(c.reps, 'reps', PlanChangeLimits.reps, false)
    this.optionalTargets(c.reps ?? this.effectiveReps(c.routineId, from))
    if (
      this.violations.length > 0 ||
      isNil(from) ||
      isNil(to) ||
      isNil(c.routineId) ||
      isNil(this.routineExercises)
    ) {
      return
    }
    const rid = c.routineId
    const list = this.routineExercises
    this.updateRoutine(rid, list.map((x) => (x === from ? to : x)))
    this.moveEffectiveReps(rid, from, to)
    this.setEffectiveReps(rid, to, c.reps, c.repsMin)
  }

  /**
   * Optional prescription values an add/swap may carry (all consumed by the applier): each must be in range
   * when present, and repsMin must not exceed the top of the rep range (when known).
   */
  private optionalTargets(topReps: number | undefined): void {
    const c = this.change
    this.range(c.sec, 'sec', PlanChangeLimits.sec, false)
    this.range(c.minutes, 'minutes', PlanChangeLimits.minutes, false)
    this.range(c.weightKg, 'weightKg', PlanChangeLimits.weightKg, false)
    if (!isNil(c.repsMin)) {
      const top = topReps ?? PlanChangeLimits.reps.max
      if (!Number.isFinite(c.repsMin) || c.repsMin < 1 || c.repsMin > top) {
        this.fail('repsMin', 'Must be 1–reps')
      }
    }
  }

  // ---- Value edits (per-exercise numeric/policy fields on an existing routine exercise) -------------------

  checkValueEdit(): void {
    const c = this.change
    switch (c.type) {
      case 'sets':
        this.inRoutine(c.exerciseId, 'exerciseId')
        this.range(c.sets, 'sets', PlanChangeLimits.sets)
        break
      case 'reps':
        this.inRoutine(c.exerciseId, 'exerciseId')
        this.checkReps()
        break
      case 'repsMin':
        this.inRoutine(c.exerciseId, 'exerciseId')
        this.checkRepsMin()
        break
      case 'sec':
        this.inRoutine(c.exerciseId, 'exerciseId')
        this.range(c.sec, 'sec', PlanChangeLimits.sec)
        break
      case 'weight':
        this.inRoutine(c.exerciseId, 'exerciseId')
        this.range(c.weightKg, 'weightKg', PlanChangeLimits.weightKg)
        break
      case 'cardio':
        this.inRoutine(c.exerciseId, 'exerciseId')
        this.range(c.minutes, 'minutes', PlanChangeLimits.minutes)
        this.range(c.speed, 'speed', PlanChangeLimits.speed, false)
        break
      case 'reorder':
        this.inRoutine(c.exerciseId, 'exerciseId')
        this.range(c.position, 'position', PlanChangeLimits.position)
        break
      case 'superset':
        this.checkSuperset()
        break
      case 'routine-prog':
        this.requireField(c.policy, 'policy')
        break
      case 'exercise-prog':
        this.inRoutine(c.exerciseId, 'exerciseId')
        this.requireField(c.policy, 'policy')
        break
      case 'inc':
        this.inRoutine(c.exerciseId, 'exerciseId')
        this.range(c.incKg, 'incKg', PlanChangeLimits.incKg)
        break
      default:
        break
    }
  }

  // A `.reps` (top-of-range) change: repsMin — given explicitly on this change, or otherwise the effective
  // repsMin carried over from an earlier change or the snapshot — must not exceed the new reps value.
  private checkReps(): void {
    const c = this.change
    this.range(c.reps, 'reps', PlanChangeLimits.reps)
    if (isNil(c.reps) || isNil(c.routineId) || isNil(c.exerciseId)) return
    const newReps = c.reps
    const rid = c.routineId
    const exerciseId = c.exerciseId
    if (!isNil(c.repsMin)) {
      if (c.repsMin < 1 || c.repsMin > newReps) this.fail('repsMin', 'Must be 1–reps')
    } else {
      const effectiveMin = this.effectiveRepsMin(rid, exerciseId)
      if (!isNil(effectiveMin) && effectiveMin > newReps) this.fail('repsMin', 'Must be 1–reps')
    }
    this.setEffectiveReps(rid, exerciseId, newReps, c.repsMin)
  }

  // A `.repsMin` change must not exceed the effective reps (top of range), when known.
  private checkRepsMin(): void {
    const c = this.change
    this.range(c.repsMin, 'repsMin', PlanChangeLimits.reps)
    if (isNil(c.repsMin) || isNil(c.routineId) || isNil(c.exerciseId)) return
    const newMin = c.repsMin
    const rid = c.routineId
    const exerciseId = c.exerciseId
    const effectiveMax = this.effectiveReps(rid, exerciseId)
    if (!isNil(effectiveMax) && newMin > effectiveMax) this.fail('repsMin', 'Must be ≤ reps')
    this.setEffectiveReps(rid, exerciseId, undefined, newMin)
  }

  private checkSuperset(): void {
    const c = this.change
    const a = this.inRoutine(c.exerciseId, 'exerciseId')
    const b = this.inRoutine(c.withExerciseId, 'withExerciseId')
    if (!isNil(a) && !isNil(b) && a === b) {
      this.fail('withExerciseId', "Can't superset an exercise with itself")
    }
  }

  // ---- Routine edits (whole-routine management) ------------------------------------------------------------

  checkRoutineEdit(): void {
    const c = this.change
    switch (c.type) {
      case 'add-routine': {
        this.name(c.name)
        const id = this.requireField(c.routineId, 'routineId')
        if (!isNil(id)) {
          if (this.routines[id] !== undefined) {
            this.fail('routineId', 'Routine id already exists')
          } else if (Object.keys(this.routines).length >= MAX_ROUTINES) {
            this.fail('routineId', `At most ${MAX_ROUTINES} routines`)
          } else {
            this.addRoutine(id)
          }
        }
        break
      }
      case 'remove-routine':
        if (!isNil(this.routineExercises) && !isNil(c.routineId)) this.removeRoutine(c.routineId)
        break
      case 'rename-routine':
        this.name(c.name)
        break
      case 'pause-routine': {
        const paused = this.requireField(c.paused, 'paused')
        const state = isNil(c.routineId) ? undefined : this.routines[c.routineId]
        if (this.violations.length === 0 && !isNil(paused) && state) state.paused = paused
        break
      }
      default:
        break
    }
  }

  // ---- Week (schedule) edits ---------------------------------------------------------------------------------

  checkWeek(): void {
    const c = this.change
    this.range(c.weekday, 'weekday', { min: 1, max: 7 })
    if (!isNil(c.routineId) && this.routines[c.routineId] === undefined) {
      this.fail('routineId', `Unknown routine '${c.routineId}'`)
    }
  }

  // ---- Today (a one-off routine for one date; the schedule is untouched) -------------------------------------

  checkToday(options: ValidateOptions): void {
    const c = this.change
    if (!isNil(this.routineExercises) && !isNil(c.routineId) && this.routines[c.routineId]?.paused) {
      this.fail('routineId', 'Routine is paused')
    }
    const date = this.requireField(c.date, 'date')
    if (isNil(date)) return
    const day = typeof date === 'string' ? dayNumber(date) : undefined
    if (day === undefined) {
      this.fail('date', 'Must be a date like 2026-10-03')
      return
    }
    const today = isNil(options.today) ? undefined : dayNumber(options.today)
    if (today === undefined) return
    const slack = options.slackDays ?? 0
    const ahead = day - today
    if (ahead < PlanChangeLimits.todayDaysAhead.min - slack) {
      this.fail('date', 'Date passed')
    } else if (ahead > PlanChangeLimits.todayDaysAhead.max + slack) {
      this.fail('date', `At most ${PlanChangeLimits.todayDaysAhead.max} days ahead`)
    }
  }
}

// Dispatches to the change family that knows how to validate (and, when valid, apply) this change type. Mirrors
// PlanChangeValidator.check (Swift).
function check(
  exerciseExists: (id: string) => boolean,
  change: PlanChange,
  routines: Record<string, RoutineState>,
  options: ValidateOptions,
): [PlanViolation[], Record<string, RoutineState>] {
  const checker = new PlanChangeChecker(exerciseExists, change, cloneRoutines(routines))
  checker.prepare()
  switch (change.type) {
    case 'add-exercise':
    case 'remove-exercise':
    case 'swap-exercise':
      checker.checkExerciseEdit()
      break
    case 'sets':
    case 'reps':
    case 'repsMin':
    case 'sec':
    case 'weight':
    case 'cardio':
    case 'reorder':
    case 'superset':
    case 'routine-prog':
    case 'exercise-prog':
    case 'inc':
      checker.checkValueEdit()
      break
    case 'add-routine':
    case 'remove-routine':
    case 'rename-routine':
    case 'pause-routine':
      checker.checkRoutineEdit()
      break
    case 'week':
      checker.checkWeek()
      break
    case 'today':
      checker.checkToday(options)
      break
  }
  return [checker.violations, checker.violations.length === 0 ? checker.routines : routines]
}

/** Validates a Claude plan proposal against the closed change list, value ranges and the current plan snapshot. */
export function validateProposal(
  proposal: PlanProposal,
  plan: PlanSnapshot,
  exerciseExists: (id: string) => boolean,
  options: ValidateOptions = {},
): PlanViolation[] {
  const out: PlanViolation[] = []
  const summary = proposal.summary.trim()
  if (summary.length === 0 || summary.length > MAX_SUMMARY) {
    out.push({ changeId: null, field: 'summary', message: `Summary must be 1–${MAX_SUMMARY} characters` })
  }
  if (proposal.changes.length === 0 || proposal.changes.length > MAX_CHANGES) {
    out.push({ changeId: null, field: 'changes', message: `1–${MAX_CHANGES} changes allowed` })
  }

  const seen = new Set<string>()
  let routines: Record<string, RoutineState> = {}
  for (const r of plan.routines) {
    routines[r.id] = {
      exerciseIds: [...r.exerciseIds],
      reps: { ...(r.reps ?? {}) },
      repsMin: { ...(r.repsMin ?? {}) },
      paused: r.paused === true,
    }
  }
  const todayDates = new Set<string>()

  for (const change of proposal.changes) {
    if (seen.has(change.id)) {
      out.push({ changeId: change.id, field: 'id', message: 'Duplicate change id' })
    } else {
      seen.add(change.id)
    }
    if (!isNil(change.reason) && change.reason.length > MAX_REASON) {
      out.push({ changeId: change.id, field: 'reason', message: 'Reason too long' })
    }
    if (change.type === 'today' && typeof change.date === 'string') {
      if (todayDates.has(change.date)) {
        out.push({ changeId: change.id, field: 'date', message: 'Another change already picks this date' })
      }
      todayDates.add(change.date)
    }
    const [violations, updated] = check(exerciseExists, change, routines, options)
    out.push(...violations)
    routines = updated
  }

  return out
}
