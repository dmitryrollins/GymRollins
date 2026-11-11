// Write tools. Nothing here changes the plan: proposals are stored as `pending` and only the app applies them, after
// the owner's review or by itself when the owner turned on auto-apply.
import {
  type PlanChange,
  type PlanSnapshot,
  type PlanViolation,
  type RoutineRef,
  utcDay,
  validateProposal,
} from '../../shared/plan-validation.ts'
import type { Db, ProposalRow, RoutineRow } from '../db.ts'
import { ownerUnit } from './common.ts'
import { parseBound, weight } from './format.ts'
import { fail, ok, type ToolCtx, ToolError, type ToolResult } from './result.ts'

/** What a saved change's result tells the agent to say (owner, 2026-11-09: with "Apply changes without asking" on,
 *  an agent's changes are made, not proposed; the app applies them when it next syncs. Plan 35, 2026-11-11: agents
 *  still said "pending" while the phone was closed, so this says that status is expected). */
export const APPLIES_AUTOMATICALLY =
  'Done: the owner turned on "Apply changes without asking", so nobody reviews or approves this. The GymRollins ' +
  'app puts it into the plan by itself the next time it opens or syncs; until then this status is expected, not a ' +
  "problem. Tell the owner it's done and shows when they open the app; they can undo it there for 7 days. Don't " +
  'call it a proposal or say it is pending or waiting. If the plan changes before then so that part of it no ' +
  'longer fits (its day has passed, say), the app skips that part; get_plan_change shows what the app applied.'
export const APPLIES_AFTER_REVIEW =
  'Saved for review: the owner applies it in the GymRollins app. Tell them to review it there. To let agents ' +
  'change the plan without a review, they can turn on "Apply changes without asking" in Settings › AI agents.'

export function appliesNote(autoApply: boolean): string {
  return autoApply ? APPLIES_AUTOMATICALLY : APPLIES_AFTER_REVIEW
}

/** What a resolved proposal that didn't fully apply tells the agent, so it doesn't report a change that wasn't made. */
export const PARTIAL_NOTE =
  'Only the changes in applied_change_ids were applied: the owner kept those, or the app skipped the others ' +
  'because they no longer fit the plan.'
export const DISMISSED_NOTE = 'The owner turned this change down: nothing in it was applied.'
/** The app skips what no longer fits the plan without telling the server, so get_plan_change checks it itself. */
export const WONT_APPLY_NOTE =
  "None of it fits the plan any more (see wont_apply), so the app won't apply it and nothing changed. Tell the " +
  "owner, and make a new change if it's still wanted."
export const SOME_WONT_APPLY_NOTE =
  'The changes in wont_apply no longer fit the plan, so the app skips them and applies the rest. Tell the owner ' +
  "which part won't happen."

/** What agents see for a stored status: a pending row is either on its way in by itself or waiting for the owner. */
export function agentStatus(status: string, autoApply: boolean): string {
  if (status !== 'pending') return status
  return autoApply ? 'applies_when_app_opens' : 'waiting_for_review'
}

function statusNote(status: string): string | null {
  if (status === 'partial') return PARTIAL_NOTE
  if (status === 'dismissed') return DISMISSED_NOTE
  return null
}

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
    return fail(`Nothing was saved: ${violations.length} problem(s). Fix them and call change_plan again.`, {
      violations: violations.map((v) => ({ change_id: v.changeId, field: v.field, message: v.message })),
    })
  }
  const row = await db.insertProposal({ summary: args.summary, changes: args.changes })
  const warnings = swapWeightWarnings(args.changes, routines)
  const autoApply = await db.autoApply()
  return ok({
    id: row.id,
    status: agentStatus('pending', autoApply),
    auto_apply: autoApply,
    changes: args.changes.length,
    applies: appliesNote(autoApply),
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
        'with no planned weight (0 until the owner types one). Add a weight change for it.',
    }]
  })
}

export async function getProposal({ db, now }: ToolCtx, args: { id: string }): Promise<ToolResult> {
  const p = await db.proposal(args.id)
  if (!p) throw new ToolError('Plan change not found.')
  const autoApply = await db.autoApply()
  const changeCount = Array.isArray(p.changes) ? p.changes.length : 0
  const wontApply = p.status === 'pending' ? await noLongerFits(db, p, now) : []
  const noneApply = wontApply.length > 0 && wontApply.length >= changeCount
  const note = noneApply ? WONT_APPLY_NOTE : wontApply.length > 0 ? SOME_WONT_APPLY_NOTE : statusNote(p.status)
  return ok({
    id: p.id,
    created_at: p.created_at,
    status: noneApply ? 'wont_apply' : agentStatus(p.status, autoApply),
    summary: p.summary,
    change_count: changeCount,
    applied_change_ids: p.applied_change_ids,
    resolved_at: p.resolved_at,
    ...(p.status === 'pending' && !noneApply ? { applies: appliesNote(autoApply) } : {}),
    ...(wontApply.length > 0 ? { wont_apply: wontApply } : {}),
    ...(note ? { note } : {}),
  })
}

/** A waiting change checked again against the current plan, as the app checks it before applying (a `today` day that
 *  has passed, a routine that's gone): one entry per change the app will skip. With plan reads off the plan can't be
 *  read, so nothing is called stale. */
async function noLongerFits(db: Db, p: ProposalRow, now: Date): Promise<{ change_id: string; message: string }[]> {
  if (!Array.isArray(p.changes) || !(await db.readPermissions()).plan) return []
  const changes = p.changes as PlanChange[]
  const ids = referencedExerciseIds(changes)
  const [routines, known] = await Promise.all([
    db.routines(),
    ids.length ? db.exerciseExists(ids) : Promise.resolve(new Set<string>()),
  ])
  const violations = validateProposal({ summary: p.summary, changes }, planSnapshot(routines), (id) => known.has(id), {
    today: utcDay(now),
    slackDays: TODAY_SLACK_DAYS,
  })
  const byChange = new Map<string, string>()
  for (const v of violations) if (v.changeId !== null && !byChange.has(v.changeId)) byChange.set(v.changeId, v.message)
  return [...byChange].map(([change_id, message]) => ({ change_id, message }))
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
