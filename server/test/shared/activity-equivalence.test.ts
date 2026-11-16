// Equivalence and size tests for resolveActivities: the indexed implementation must equal the straightforward
// reference (the original quadratic logic, kept here verbatim) on dense pseudo-random data.
import { test } from 'vitest'
import { assert, assertEquals } from '../assert.ts'
import {
  ATTACH_SHARE,
  COUNTING_MINIMUM_S,
  SAME_SESSION_SHARE,
  resolveActivities,
  type ActivitySpan,
  type WorkoutSpan,
  type Resolved,
} from '../../src/shared/activity.ts'

// ---- reference: the original implementation ----
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
function preferred(a: ActivitySpan, b: ActivitySpan): number {
  if (a.from_watch !== b.from_watch) return a.from_watch ? -1 : 1
  if (a.duration_s !== b.duration_s) return b.duration_s - a.duration_s
  if (ms(a.started_at) !== ms(b.started_at)) return ms(a.started_at) - ms(b.started_at)
  return byId(a.id, b.id)
}

/** Newest first, then the lower id. */
function newestFirst(a: ActivitySpan, b: ActivitySpan): number {
  if (ms(a.started_at) !== ms(b.started_at)) return ms(b.started_at) - ms(a.started_at)
  return byId(a.id, b.id)
}

/** Rules 6 and 7 (ActivityRules.resolve): attach to GymRollins workouts, then keep one copy per session. */
function referenceResolve<T extends ActivitySpan>(
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


function lcg(seed: number): () => number {
  let state = seed >>> 0
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0
    return state / 0x100000000
  }
}

const BASE = Date.UTC(2026, 0, 1)
const KINDS = ['run', 'walk', 'cycle']

function generate(seed: number, nActivities: number, nWorkouts: number, horizonMin: number) {
  const rand = lcg(seed)
  // Coarse 5-minute grid so equal timestamps and equal overlaps are common.
  const stamp = (min: number) => new Date(BASE + min * 60_000).toISOString()
  const activities: ActivitySpan[] = []
  for (let i = 0; i < nActivities; i++) {
    const start = Math.floor(rand() * (horizonMin / 5)) * 5
    const len = (1 + Math.floor(rand() * 12)) * 5
    activities.push({
      id: `a${Math.floor(rand() * 1e6).toString(36)}-${i}`,
      kind: KINDS[Math.floor(rand() * KINDS.length)],
      started_at: stamp(start),
      ended_at: stamp(start + len),
      duration_s: (Math.floor(rand() * 4) + 1) * 300 + (rand() < 0.5 ? 0 : len * 30),
      from_watch: rand() < 0.4,
    })
  }
  const workouts: WorkoutSpan[] = []
  for (let i = 0; i < nWorkouts; i++) {
    const start = Math.floor(rand() * (horizonMin / 5)) * 5
    const len = (1 + Math.floor(rand() * 16)) * 5
    workouts.push({ id: `w${Math.floor(rand() * 1e6).toString(36)}-${i}`, started_at: stamp(start), ended_at: stamp(start + len) })
  }
  return { activities, workouts }
}

const ids = (r: Resolved<ActivitySpan>) => ({
  shown: r.shown.map((a) => a.id),
  attached: r.attached.map((a) => [a.activity.id, a.workout_id]),
})

test('resolveActivities equals the reference on dense random data', () => {
  assert(ATTACH_SHARE === 0.5 && SAME_SESSION_SHARE === 0.8 && COUNTING_MINIMUM_S === 600, 'constants')
  for (const [seed, horizon] of [[1, 3000], [2, 1500], [3, 600]] as const) {
    const { activities, workouts } = generate(seed, 300, 150, horizon)
    const want = referenceResolve(activities, workouts)
    assert(want.attached.length > 0 && want.shown.length > 0, 'data exercises both branches')
    assertEquals(ids(resolveActivities(activities, workouts)), ids(want))
  }
})

test('resolveActivities handles 5,000 outside workouts against 3,000 spans', () => {
  const { activities, workouts } = generate(7, 5000, 3000, 200_000)
  const got = resolveActivities(activities, workouts)
  assert(got.shown.length > 0 && got.attached.length > 0, 'both branches used')
  // The reference is quadratic, so compare on a slice of the activities against all the spans.
  const sample = activities.filter((_, i) => i % 10 === 0)
  assertEquals(ids(resolveActivities(sample, workouts)), ids(referenceResolve(sample, workouts)))
}, 60_000)
