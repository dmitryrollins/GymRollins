// Write tools. Nothing here changes the plan: proposals are stored as `pending` and only the app applies them.
import {
  type PlanChange,
  type PlanSnapshot,
  type PlanViolation,
  type RoutineRef,
  utcDay,
  validateProposal,
} from '../../_shared/plan-validation.ts'
import type { RoutineRow } from '../db.ts'
import { ownerUnit } from './common.ts'
import { parseBound, weight } from './format.ts'
import { fail, ok, type ToolCtx, ToolError, type ToolResult } from './result.ts'

export const APPLIES_NOTE = 'when the owner reviews it in the app (or automatically if auto-apply is on)'
/** Allow a day of clock/time-zone slack for "today" weigh-ins. */
/** How far ahead a weigh-in may be dated (a date-only entry is stored at 12:00 UTC). */
export const FUTURE_SLACK_MS = 86_400_000
/** The server only knows UTC, so a `today` date may be a day either side of the UTC date (the owner's time zone);
 *  the app checks it against the owner's own date when applying. */
export const TODAY_SLACK_DAYS = 1

/** The validator's view of the current plan: routine ids, library exercise ids and effective rep ranges. */
export function planSnapshot(routines: RoutineRow[]): PlanSnapshot {
  return {
    routines: routines.map((r): RoutineRef => {
      const exercises = [...r.exercises].sort((a, b) => a.position - b.position)
      return {
        id: r.id,
        name: r.name,
        exerciseIds: exercises.map((e) => e.exercise_id),
        reps: Object.fromEntries(exercises.map((e) => [e.exercise_id, e.reps])),
        repsMin: Object.fromEntries(
          exercises.filter((e) => e.reps_min != null).map((e) => [e.exercise_id, e.reps_min as number]),
        ),
        paused: r.paused === true,
      }
    }),
  }
}

function referencedExerciseIds(changes: PlanChange[]): string[] {
  const ids = changes.flatMap((c) => [c.exerciseId, c.toExerciseId, c.withExerciseId])
  return [...new Set(ids.filter((id): id is string => typeof id === 'string' && id.length > 0))]
}

/** The exercise a change would put into the plan: add-exercise's exercise, swap-exercise's target. */
function incomingExercise(c: PlanChange): { field: 'exerciseId' | 'toExerciseId'; id: string } | null {
  if (c.type === 'add-exercise' && typeof c.exerciseId === 'string') {
    return { field: 'exerciseId', id: c.exerciseId }
  }
  if (c.type === 'swap-exercise' && typeof c.toExerciseId === 'string') {
    return { field: 'toExerciseId', id: c.toExerciseId }
  }
  return null
}

/** The owner marked these "Don't recommend again": Claude may remove them but never bring them into the plan. */
export function neverViolations(changes: PlanChange[], never: Set<string>): PlanViolation[] {
  return changes.flatMap((c) => {
    const incoming = incomingExercise(c)
    if (!incoming || !never.has(incoming.id)) return []
    return [{
      changeId: c.id ?? null,
      field: incoming.field,
      message: `The owner marked exercise ${incoming.id} "Don't recommend again"; pick another exercise.`,
    }]
  })
}

export async function proposePlanChanges(
  { db, now }: ToolCtx,
  args: { summary: string; changes: PlanChange[] },
): Promise<ToolResult> {
  const ids = referencedExerciseIds(args.changes)
  // The referenced exercises' 'never' flags, answered even when RLS hides the preferences from Claude.
  const [routines, never] = await Promise.all([db.routines(), db.neverExerciseIds(ids)])
  const known = ids.length ? await db.exerciseExists(ids) : new Set<string>()
  const violations = [
    ...validateProposal(args, planSnapshot(routines), (id) => known.has(id), {
      today: utcDay(now),
      slackDays: TODAY_SLACK_DAYS,
    }),
    ...(Array.isArray(args.changes) ? neverViolations(args.changes, never) : []),
  ]
  if (violations.length > 0) {
    return fail(`The proposal was not saved: ${violations.length} problem(s). Fix them and propose again.`, {
      violations: violations.map((v) => ({ change_id: v.changeId, field: v.field, message: v.message })),
    })
  }
  const row = await db.insertProposal({ summary: args.summary, changes: args.changes })
  const warnings = swapWeightWarnings(args.changes, routines)
  return ok({
    proposal_id: row.id,
    status: 'pending',
    changes: args.changes.length,
    applies: APPLIES_NOTE,
    ...(warnings.length ? { warnings } : {}),
  })
}

/** A swap drops the old exercise's planned weight (loads don't transfer between exercises), so a swap without
 *  weightKg away from a weighted exercise leaves the new one at 0 in the app. Saved anyway; Claude is told. */
function swapWeightWarnings(
  changes: PlanChange[],
  routines: RoutineRow[],
): { change_id: string; message: string }[] {
  return changes.flatMap((c) => {
    if (c.type !== 'swap-exercise' || c.weightKg !== undefined) return []
    const old = routines.find((r) => r.id === c.routineId)?.exercises.find((e) =>
      e.exercise_id === c.exerciseId
    )
    if (!old?.weight_kg) return []
    return [{
      change_id: c.id,
      message:
        `No weightKg: ${c.exerciseId}'s ${old.weight_kg} kg isn't carried over, so ${c.toExerciseId} starts ` +
        'with no planned weight (0 until the owner types one). Propose a weight change for it.',
    }]
  })
}

export async function getProposal({ db }: ToolCtx, args: { id: string }): Promise<ToolResult> {
  const p = await db.proposal(args.id)
  if (!p) throw new ToolError('Proposal not found.')
  return ok({
    id: p.id,
    created_at: p.created_at,
    status: p.status,
    summary: p.summary,
    change_count: Array.isArray(p.changes) ? p.changes.length : 0,
    applied_change_ids: p.applied_change_ids,
    resolved_at: p.resolved_at,
  })
}

export async function logBodyweight(
  { db, now }: ToolCtx,
  args: { weight_kg: number; date?: string; body_fat_pct?: number },
): Promise<ToolResult> {
  const measured = args.date
    ? (/^\d{4}-\d{2}-\d{2}$/.test(args.date)
      ? new Date(`${args.date}T12:00:00Z`)
      : parseBound(args.date, 'date'))
    : now
  if (Number.isNaN(measured.getTime())) throw new ToolError(`'date' must be a date like 2026-09-15`)
  if (measured.getTime() > now.getTime() + FUTURE_SLACK_MS) throw new ToolError('The date is in the future.')
  const row = {
    id: crypto.randomUUID(),
    measured_at: measured.toISOString(),
    w_kg: args.weight_kg,
    ...(args.body_fat_pct !== undefined ? { bf_pct: args.body_fat_pct } : {}),
  }
  await db.insertBodyweight(row)
  const unit = await ownerUnit(db)
  return ok({
    id: row.id,
    measured_at: row.measured_at,
    ...weight(row.w_kg, unit),
    body_fat_pct: args.body_fat_pct ?? null,
  })
}
