// Rules 6 and 7 for outside workouts (plan 39; docs/specs/2026-11-16-health-activities-design.md, decisions 5–8): a
// hand-maintained TypeScript port of GymCore's ActivityRules.swift, the source of truth. Both run the shared fixture
// fixtures/activity.json, so a change on one side only fails a test suite. Pure: no I/O.

/** What the rules read of an outside workout (a health_activities row has more). */
export interface ActivitySpan {
  id: string
  kind: string
  started_at: string
  ended_at: string
  duration_s: number
  from_watch: boolean
}

/** A finished GymRollins workout's time span. */
export interface WorkoutSpan {
  id: string
  started_at: string
  ended_at: string
}

export interface Resolved<T extends ActivitySpan> {
  /** Shown and counted on their own: not attached, one per session; newest first. */
  shown: T[]
  /** Attached to a GymRollins workout (the same session, measured), newest first, with that workout's id. */
  attached: { activity: T; workout_id: string }[]
}

/** Rule 6: overlapping a GymRollins workout by this share of the shorter of the two attaches it. */
export const ATTACH_SHARE = 0.5
/** Rule 7: two of the same kind overlapping by this share of the shorter are one session. */
export const SAME_SESSION_SHARE = 0.8
/** Active seconds an outside workout needs to count toward the streak and the weekly goal (decision 5). */
export const COUNTING_MINIMUM_S = 600

const ms = (iso: string): number => Date.parse(iso)
const length = (start: string, end: string): number => Math.max(0, ms(end) - ms(start))

/** Milliseconds two spans share. */
function overlap(aStart: string, aEnd: string, bStart: string, bEnd: string): number {
  return Math.max(0, Math.min(ms(aEnd), ms(bEnd)) - Math.max(ms(aStart), ms(bStart)))
}

const byId = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0)

/** Rule 6's workout: the largest overlap reaching ATTACH_SHARE of the shorter, then the earliest, the lowest id. */
function workoutFor(a: ActivitySpan, workouts: readonly WorkoutSpan[]): WorkoutSpan | null {
  let best: { span: WorkoutSpan; shared: number } | null = null
  for (const span of workouts) {
    const shared = overlap(a.started_at, a.ended_at, span.started_at, span.ended_at)
    const shorter = Math.min(length(a.started_at, a.ended_at), length(span.started_at, span.ended_at))
    if (shared <= 0 || shared < ATTACH_SHARE * shorter) continue
    const better = best === null || shared > best.shared ||
      (shared === best.shared && (ms(span.started_at) < ms(best.span.started_at) ||
        (ms(span.started_at) === ms(best.span.started_at) && byId(span.id, best.span.id) < 0)))
    if (better) best = { span, shared }
  }
  return best?.span ?? null
}

function sameSession(a: ActivitySpan, b: ActivitySpan): boolean {
  if (a.kind !== b.kind) return false
  const shared = overlap(a.started_at, a.ended_at, b.started_at, b.ended_at)
  const shorter = Math.min(length(a.started_at, a.ended_at), length(b.started_at, b.ended_at))
  return shared > 0 && shared >= SAME_SESSION_SHARE * shorter
}

/** The copy kept of a session: the Apple Watch's, then the longer (active time), the earlier start, the lower id. */
export function preferred(a: ActivitySpan, b: ActivitySpan): number {
  if (a.from_watch !== b.from_watch) return a.from_watch ? -1 : 1
  if (a.duration_s !== b.duration_s) return b.duration_s - a.duration_s
  if (ms(a.started_at) !== ms(b.started_at)) return ms(a.started_at) - ms(b.started_at)
  return byId(a.id, b.id)
}

/** Newest first, then the lower id. */
export function newestFirst(a: ActivitySpan, b: ActivitySpan): number {
  if (ms(a.started_at) !== ms(b.started_at)) return ms(b.started_at) - ms(a.started_at)
  return byId(a.id, b.id)
}

/** Rules 6 and 7 (ActivityRules.resolve): attach to GymRollins workouts, then keep one copy per session. */
export function resolveActivities<T extends ActivitySpan>(
  activities: readonly T[],
  workouts: readonly WorkoutSpan[],
): Resolved<T> {
  const attached: { activity: T; workout_id: string }[] = []
  const free: T[] = []
  for (const activity of activities) {
    const span = workoutFor(activity, workouts)
    if (span === null) {
      free.push(activity)
    } else {
      attached.push({ activity, workout_id: span.id })
    }
  }
  const kept: T[] = []
  for (const activity of [...free].sort(preferred)) {
    if (!kept.some((k) => sameSession(k, activity))) kept.push(activity)
  }
  return {
    shown: kept.sort(newestFirst),
    attached: attached.sort((x, y) => newestFirst(x.activity, y.activity)),
  }
}

/** Shown outside workouts that count toward the streak and the weekly goal (ResolvedActivities.counted). */
export function counted<T extends ActivitySpan>(resolved: Resolved<T>): T[] {
  return resolved.shown.filter((a) => a.duration_s >= COUNTING_MINIMUM_S)
}
