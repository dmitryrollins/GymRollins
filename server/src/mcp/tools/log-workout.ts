// log_workout (plan 32; docs/specs/2026-11-09-ai-agents-design.md, section 3.4): past workouts an agent adds
// straight to the owner's history, behind the Add workouts switch. Each workout is checked on its own, so one bad
// workout doesn't block the rest, and the result lists every one as added (with its id) or refused (with a reason).
import type { z } from 'zod'
import { DomainLimits } from '../../shared/domain-limits.ts'
import { AGENT_WORKOUT_CAPS, grouped } from '../../sync/caps.ts'
import { isStorableText } from '../../sync/columns.ts'
import { normalizeTimestamp } from '../../sync/time.ts'
import type { LoggedSet, LoggedWorkout } from '../db.ts'
import { ok, type ToolCtx, type ToolResult } from './result.ts'
import type { schemas } from './schemas.ts'

export type LogWorkoutArgs = z.infer<typeof schemas.logWorkout>
type WorkoutArg = LogWorkoutArgs['workouts'][number]
type SetArg = WorkoutArg['exercises'][number]['sets'][number]

/** A workout's name when the agent gives none. */
export const DEFAULT_WORKOUT_NAME = 'Workout'
/** added_by for a client that registered no name. */
export const UNNAMED_AGENT = 'Agent'
/** How far past the server's clock a workout may end: the agent's clock may run a little ahead. */
export const END_SLACK_MS = 5 * 60_000
/** The longest workout taken. A longer one is a mistake (a wrong date), and would block a day of others. */
export const MAX_WORKOUT_MS = 24 * 3_600_000
export const NOT_ALLOWED_WORKOUTS =
  "Not allowed: the owner hasn't turned on Add workouts for agents in the app. Nothing was added."

type Refused = { index: number; status: 'refused'; reason: string; message: string }
type Outcome = { index: number; status: 'added'; workout_id: string } | Refused

const refused = (index: number, reason: string, message: string): Refused => ({
  index,
  status: 'refused',
  reason,
  message,
})

/** The set fields with a range, as DomainLimits (and the D1 CHECKs) bound them. */
const SET_RANGES = [
  ['reps', DomainLimits.setReps],
  ['weight_kg', DomainLimits.setWeightKg],
  ['sec', DomainLimits.setSeconds],
  ['dist_m', DomainLimits.setDistanceM],
] as const

/** Milliseconds since the epoch of a time in the stored form (YYYY-MM-DDTHH:MM:SS.ffffffZ). */
const msOf = (stored: string) => Date.parse(`${stored.slice(0, 23)}Z`)

/** The first value out of range in a set, as words, or null. */
function setProblem(s: SetArg): string | null {
  for (const [field, { min, max }] of SET_RANGES) {
    const value = s[field]
    if (value !== undefined && (value < min || value > max)) {
      return `${field} must be ${grouped(min)}–${grouped(max)}.`
    }
  }
  return null
}

/** The workout's exercises, checked: the first problem, as a refusal, or the sets as the Db takes them. */
function checkedExercises(w: WorkoutArg, index: number): LoggedWorkout['exercises'] | Refused {
  if (w.exercises.length === 0) return refused(index, 'invalid', 'A workout needs at least one exercise.')
  if (w.exercises.length > DomainLimits.workoutEntriesMax) {
    return refused(index, 'too_many_workout_exercises', AGENT_WORKOUT_CAPS.too_many_workout_exercises)
  }
  const exercises: LoggedWorkout['exercises'] = []
  for (const [i, e] of w.exercises.entries()) {
    if (e.sets.length === 0) return refused(index, 'invalid', `exercises[${i}] needs at least one set.`)
    if (e.sets.length > DomainLimits.entrySetsMax) {
      return refused(index, 'too_many_exercise_sets', AGENT_WORKOUT_CAPS.too_many_exercise_sets)
    }
    const sets: LoggedSet[] = []
    for (const [j, s] of e.sets.entries()) {
      const problem = setProblem(s)
      if (problem !== null) return refused(index, 'invalid', `exercises[${i}].sets[${j}].${problem}`)
      sets.push({
        reps: s.reps,
        weight_kg: s.weight_kg,
        sec: s.sec ?? null,
        dist_m: s.dist_m ?? null,
        warmup: s.warmup ?? false,
      })
    }
    exercises.push({ exercise_id: e.exercise_id, sets })
  }
  return exercises
}

/** One workout, checked against everything but the exercise ids and the history: the Db's workout, or a refusal. */
function checked(w: WorkoutArg, index: number, now: Date): LoggedWorkout | Refused {
  const invalid = (message: string) => refused(index, 'invalid', message)
  const started = normalizeTimestamp(w.started_at)
  if (started === null) return invalid("started_at isn't a timestamp like 2026-10-08T17:02:00Z.")
  const ended = normalizeTimestamp(w.ended_at)
  if (ended === null) return invalid("ended_at isn't a timestamp like 2026-10-08T18:05:00Z.")
  if (ended <= started) return invalid('ended_at must be after started_at.')
  if (msOf(ended) > now.getTime() + END_SLACK_MS) return invalid('The workout ends in the future.')
  if (msOf(ended) - msOf(started) > MAX_WORKOUT_MS) return invalid('A workout can last at most 24 hours.')
  const name = w.name?.trim() || DEFAULT_WORKOUT_NAME
  if ([...name].length > DomainLimits.workoutNameMax || !isStorableText(name)) {
    return invalid(`name must be 1–${DomainLimits.workoutNameMax} characters.`)
  }
  const note = w.note?.trim() || null
  if (note !== null && !isStorableText(note)) return invalid('note has a character that cannot be stored.')
  const exercises = checkedExercises(w, index)
  if (!Array.isArray(exercises)) return exercises
  return { started_at: started, ended_at: ended, name, note, exercises }
}

const isRefused = (c: LoggedWorkout | Refused): c is Refused => 'status' in c

/** The ids among the workout's that the owner can't log, each once, in the order sent. */
const unknownIds = (w: LoggedWorkout, known: Set<string>) =>
  [...new Set(w.exercises.map((e) => e.exercise_id))].filter((id) => !known.has(id))

function unknownExercise(index: number, ids: string[]): Refused {
  const which = ids.length === 1 ? `id: ${ids[0]}` : `ids: ${ids.join(', ')}`
  return refused(
    index,
    'unknown_exercise',
    `Unknown exercise ${which}. Use search_exercises for library ids and the owner's custom exercises.`,
  )
}

/** The results, as an error for the client and the audit when nothing was added. */
function answer(results: Outcome[]): ToolResult {
  const result = ok({ results })
  return results.some((r) => r.status === 'added') ? result : { ...result, isError: true }
}

export async function logWorkouts({ db, now }: ToolCtx, args: LogWorkoutArgs): Promise<ToolResult> {
  if (!(await db.mayLogWorkouts())) {
    return answer(args.workouts.map((_, index) => refused(index, 'not_allowed', NOT_ALLOWED_WORKOUTS)))
  }
  const all = args.workouts.map((w, index) => checked(w, index, now))
  const candidates = all.filter((c): c is LoggedWorkout => !isRefused(c))
  if (candidates.length === 0) return answer(all as Refused[])
  const known = await db.loggableExerciseIds(candidates.flatMap((w) => w.exercises.map((e) => e.exercise_id)))
  const agent = (await db.agentName()) ?? UNNAMED_AGENT
  /** One checked workout, in the call's order: refused for its exercises, or written. */
  const add = async (w: LoggedWorkout, index: number): Promise<Outcome> => {
    const unknown = unknownIds(w, known)
    if (unknown.length > 0) return unknownExercise(index, unknown)
    const written = await db.insertWorkout(w, agent)
    if (!written.added) return refused(index, written.reason, written.message)
    return { index, status: 'added', workout_id: written.id }
  }
  const results: Outcome[] = []
  // One at a time: each write must see the ones before it.
  for (const [index, c] of all.entries()) results.push(isRefused(c) ? c : await add(c, index))
  return answer(results)
}
