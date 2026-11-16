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

const byId = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0)

/** An outside workout with its timestamps parsed once. */
interface Timed<T extends ActivitySpan> {
  item: T
  start: number
  end: number
  len: number
}

const timed = <T extends ActivitySpan>(item: T): Timed<T> => {
  const start = ms(item.started_at)
  const end = ms(item.ended_at)
  return { item, start, end, len: Math.max(0, end - start) }
}

/** Workout spans sorted by start, with the running maximum of their ends (for skipping spans already over). */
interface WorkoutIndex {
  spans: { span: WorkoutSpan; start: number; end: number; len: number }[]
  maxEnd: number[]
}

function indexWorkouts(workouts: readonly WorkoutSpan[]): WorkoutIndex {
  const spans = workouts
    .map((span) => {
      const start = ms(span.started_at)
      const end = ms(span.ended_at)
      return { span, start, end, len: Math.max(0, end - start) }
    })
    .sort((a, b) => a.start - b.start)
  const maxEnd: number[] = []
  let running = -Infinity
  for (const s of spans) {
    running = Math.max(running, s.end)
    maxEnd.push(running)
  }
  return { spans, maxEnd }
}

/** First index in a sorted numeric sequence whose value is > x (values read through `at`). */
function firstAbove(n: number, at: (i: number) => number, x: number): number {
  let lo = 0
  let hi = n
  while (lo < hi) {
    const mid = (lo + hi) >>> 1
    if (at(mid) > x) hi = mid
    else lo = mid + 1
  }
  return lo
}

/** Rule 6's workout: the largest overlap reaching ATTACH_SHARE of the shorter, then the earliest, the lowest id. */
function workoutFor(a: Timed<ActivitySpan>, index: WorkoutIndex): WorkoutSpan | null {
  let best: { span: WorkoutSpan; start: number; shared: number } | null = null
  const { spans, maxEnd } = index
  for (let i = firstAbove(spans.length, (k) => maxEnd[k], a.start); i < spans.length; i++) {
    const w = spans[i]
    if (w.start >= a.end) break
    const shared = Math.max(0, Math.min(a.end, w.end) - Math.max(a.start, w.start))
    const shorter = Math.min(a.len, w.len)
    if (shared <= 0 || shared < ATTACH_SHARE * shorter) continue
    const better = best === null || shared > best.shared ||
      (shared === best.shared && (w.start < best.start || (w.start === best.start && byId(w.span.id, best.span.id) < 0)))
    if (better) best = { span: w.span, start: w.start, shared }
  }
  return best?.span ?? null
}

function sameSession(a: Timed<ActivitySpan>, b: Timed<ActivitySpan>): boolean {
  const shared = Math.max(0, Math.min(a.end, b.end) - Math.max(a.start, b.start))
  return shared > 0 && shared >= SAME_SESSION_SHARE * Math.min(a.len, b.len)
}

/** Kept copies of one kind, sorted by start, so a candidate only meets the ones that can overlap it. */
class KeptOfKind {
  private readonly list: Timed<ActivitySpan>[] = []
  private longest = 0

  overlapsSession(a: Timed<ActivitySpan>): boolean {
    // A kept copy overlapping `a` starts after a.start - longest and before a.end.
    const from = firstAbove(this.list.length, (i) => this.list[i].start, a.start - this.longest - 1)
    for (let i = from; i < this.list.length && this.list[i].start < a.end; i++) {
      if (sameSession(this.list[i], a)) return true
    }
    return false
  }

  add(a: Timed<ActivitySpan>): void {
    const at = firstAbove(this.list.length, (i) => this.list[i].start, a.start)
    this.list.splice(at, 0, a)
    this.longest = Math.max(this.longest, a.len)
  }
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
  const index = indexWorkouts(workouts)
  const attached: { activity: T; workout_id: string }[] = []
  const free: Timed<T>[] = []
  for (const record of activities.map(timed)) {
    const span = workoutFor(record, index)
    if (span === null) {
      free.push(record)
    } else {
      attached.push({ activity: record.item, workout_id: span.id })
    }
  }
  const keptByKind = new Map<string, KeptOfKind>()
  const kept: T[] = []
  for (const record of free.sort((a, b) => preferred(a.item, b.item))) {
    let ofKind = keptByKind.get(record.item.kind)
    if (ofKind === undefined) {
      ofKind = new KeptOfKind()
      keptByKind.set(record.item.kind, ofKind)
    }
    if (ofKind.overlapsSession(record)) continue
    ofKind.add(record)
    kept.push(record.item)
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
