// get_exercise_history: per-session working sets (with logged effort), top set and e1RM for one exercise, newest
// first.
import type { Db, ExerciseRow } from '../db.ts'
import { ownerUnit } from './common.ts'
import { bestE1rm, isoDate, parseBound, round, topSet, weight, workingSets } from './format.ts'
import { compact, ok, type ToolCtx, ToolError, type ToolResult } from './result.ts'

const MAX_SESSIONS = 30
const MAX_CANDIDATES = 10

const brief = (e: ExerciseRow) => ({ id: e.id, name: e.n })

/**
 * Resolves an exercise id or name. Names match when every word appears in the exercise name; ties are broken by
 * an exact (case-insensitive) name, then by what the owner has actually logged. Still ambiguous → ToolError with
 * the candidates.
 */
export async function resolveExercise(db: Db, input: string): Promise<ExerciseRow> {
  const text = input.trim()
  const [byId] = await db.exercises([text])
  if (byId) return byId
  const candidates = await db.searchExercises({ query: text, limit: 25 })
  if (candidates.length === 0) {
    throw new ToolError(`No exercise matches "${text}". Use search_exercises to find the exercise id.`)
  }
  if (candidates.length === 1) return candidates[0]
  const exact = candidates.filter((c) => c.n.toLowerCase() === text.toLowerCase())
  if (exact.length === 1) return exact[0]
  const performed = await db.performedExerciseIds(candidates.map((c) => c.id))
  const logged = candidates.filter((c) => performed.has(c.id))
  if (logged.length === 1) return logged[0]
  const shortlist = (logged.length > 1 ? logged : candidates).slice(0, MAX_CANDIDATES)
  throw new ToolError(`Ambiguous exercise "${text}". Call again with one of these ids.`, {
    candidates: shortlist.map(brief),
  })
}

export async function getExerciseHistory(
  { db }: ToolCtx,
  args: { exercise: string; since?: string },
): Promise<ToolResult> {
  const since = args.since ? parseBound(args.since, 'since').toISOString() : undefined
  const exercise = await resolveExercise(db, args.exercise)
  const [unit, sessions] = await Promise.all([ownerUnit(db), db.exerciseSets(exercise.id, since)])
  const rows = sessions.flatMap((s) => {
    const top = topSet(s.sets)
    if (!top) return []
    const e1rm = bestE1rm(s.sets)
    return [{
      date: isoDate(s.started_at),
      workout_id: s.workout_id,
      working_sets: workingSets(s.sets).map((w) =>
        compact({ reps: w.r, ...weight(w.w_kg, unit), rir: w.rir, rpe: w.rpe })
      ),
      top_set: { reps: top.r, ...weight(top.w_kg, unit) },
      e1rm_kg: e1rm === null ? null : round(e1rm, 1),
      e1rm_display: e1rm === null ? null : weight(e1rm, unit).weight_display,
    }]
  })
  return ok({ exercise: brief(exercise), unit, sessions: rows.slice(0, MAX_SESSIONS) })
}
