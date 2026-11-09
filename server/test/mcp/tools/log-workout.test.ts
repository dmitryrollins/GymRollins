// log_workout's rules (plan 32; docs/specs/2026-11-09-ai-agents-design.md, section 3.4) on FakeDb: the switch, each
// workout's checks, and what reaches the Db. test/log-workout.test.ts runs the tool against D1 through /mcp.
import { describe, expect, it } from 'vitest'
import { DomainLimits } from '../../../src/shared/domain-limits.ts'
import { AGENT_WORKOUT_CAPS } from '../../../src/sync/caps.ts'
import {
  type LogWorkoutArgs,
  logWorkouts,
  NOT_ALLOWED_WORKOUTS,
  UNNAMED_AGENT,
} from '../../../src/mcp/tools/log-workout.ts'
import type { ToolResult } from '../../../src/mcp/tools/result.ts'
import { FakeDb, loadOwnerData } from '../fake-db.ts'

const NOW = new Date('2026-11-09T12:00:00Z')
type WorkoutArg = LogWorkoutArgs['workouts'][number]

const UPPER: WorkoutArg = {
  started_at: '2026-10-08T17:02:00Z',
  ended_at: '2026-10-08T18:05:00+00:00',
  name: '  Upper ',
  note: ' From Fitbod ',
  exercises: [{ exercise_id: '0025', sets: [{ reps: 8, weight_kg: 63.5 }, { reps: 10, weight_kg: 20, warmup: true }] }],
}

/** UPPER `days` days later, so workouts in one call don't overlap. */
function later(days: number, overrides: Partial<WorkoutArg> = {}): WorkoutArg {
  const shift = (iso: string) => new Date(Date.parse(iso) + days * 86_400_000).toISOString()
  return { ...UPPER, started_at: shift(UPPER.started_at), ended_at: shift(UPPER.ended_at), ...overrides }
}

async function fakeDb(logWorkouts = true): Promise<FakeDb> {
  const db = new FakeDb(await loadOwnerData())
  db.logWorkouts = logWorkouts
  return db
}

const run = (db: FakeDb, workouts: WorkoutArg[]) => logWorkouts({ db, now: NOW }, { workouts })
const results = (r: ToolResult) => JSON.parse(r.content[0]!.text).results

describe('the Add workouts switch', () => {
  it('refuses every workout while it is off, and reads nothing else', async () => {
    const db = await fakeDb(false)
    const read = () => {
      throw new Error('read while not allowed')
    }
    db.loggableExerciseIds = read
    db.agentName = read
    const r = await run(db, [UPPER, later(1)])
    expect(r.isError).toBe(true)
    expect(results(r)).toEqual([0, 1].map((index) => ({
      index,
      status: 'refused',
      reason: 'not_allowed',
      message: NOT_ALLOWED_WORKOUTS,
    })))
    expect(db.insertedWorkouts).toEqual([])
  })
})

describe('each workout', () => {
  it('reaches the Db checked: times in the stored form, trimmed text, warm-ups flagged, the agent named', async () => {
    const db = await fakeDb()
    const r = await run(db, [UPPER, later(1, { name: undefined, note: '  ' })])
    expect(r.isError).toBeUndefined()
    expect(results(r)).toEqual([
      { index: 0, status: 'added', workout_id: 'workout-1' },
      { index: 1, status: 'added', workout_id: 'workout-2' },
    ])
    expect(db.insertedWorkouts[0]).toEqual({
      addedBy: 'Claude',
      workout: {
        started_at: '2026-10-08T17:02:00.000000Z',
        ended_at: '2026-10-08T18:05:00.000000Z',
        name: 'Upper',
        note: 'From Fitbod',
        exercises: [{
          exercise_id: '0025',
          sets: [
            { reps: 8, weight_kg: 63.5, sec: null, dist_m: null, warmup: false },
            { reps: 10, weight_kg: 20, sec: null, dist_m: null, warmup: true },
          ],
        }],
      },
    })
    expect(db.insertedWorkouts[1]!.workout).toMatchObject({ name: 'Workout', note: null })
  })

  it(`is marked "${UNNAMED_AGENT}" when the client registered no name`, async () => {
    const db = await fakeDb()
    db.agent = null
    await run(db, [UPPER])
    expect(db.insertedWorkouts.map((w) => w.addedBy)).toEqual([UNNAMED_AGENT])
  })

  it('is refused as invalid for bad times, alone, while the others are added', async () => {
    const db = await fakeDb()
    const r = await run(db, [
      later(0, { ended_at: UPPER.started_at }),
      later(1, { started_at: 'yesterday' }),
      later(2, { ended_at: '2026-11-09T12:06:00Z', started_at: '2026-11-09T11:00:00Z' }),
      later(3, { ended_at: later(4).ended_at }),
      later(5),
    ])
    expect(results(r)).toEqual([
      { index: 0, status: 'refused', reason: 'invalid', message: 'ended_at must be after started_at.' },
      {
        index: 1,
        status: 'refused',
        reason: 'invalid',
        message: "started_at isn't a timestamp like 2026-10-08T17:02:00Z.",
      },
      { index: 2, status: 'refused', reason: 'invalid', message: 'The workout ends in the future.' },
      { index: 3, status: 'refused', reason: 'invalid', message: 'A workout can last at most 24 hours.' },
      { index: 4, status: 'added', workout_id: 'workout-1' },
    ])
  })

  it('takes a workout that ends up to 5 minutes past the clock', async () => {
    const db = await fakeDb()
    const r = await run(db, [later(0, { started_at: '2026-11-09T11:00:00Z', ended_at: '2026-11-09T12:05:00Z' })])
    expect(results(r)).toEqual([{ index: 0, status: 'added', workout_id: 'workout-1' }])
  })

  it('is refused as invalid for a value out of range, naming it', async () => {
    const db = await fakeDb()
    const set = (s: Record<string, unknown>) =>
      later(0, { exercises: [{ exercise_id: '0025', sets: [{ reps: 8, weight_kg: 60, ...s }] }] })
    const r = await run(db, [
      set({ reps: 1001 }),
      set({ weight_kg: -1 }),
      set({ sec: 86_401 }),
      set({ dist_m: 1_000_001 }),
      later(0, { name: 'x'.repeat(DomainLimits.workoutNameMax + 1) }),
      later(0, { exercises: [] }),
      later(0, { exercises: [{ exercise_id: '0025', sets: [] }] }),
    ])
    expect(results(r).map((x: { message: string }) => x.message)).toEqual([
      'exercises[0].sets[0].reps must be 0–1,000.',
      'exercises[0].sets[0].weight_kg must be 0–1,000.',
      'exercises[0].sets[0].sec must be 0–86,400.',
      'exercises[0].sets[0].dist_m must be 0–1,000,000.',
      'name must be 1–80 characters.',
      'A workout needs at least one exercise.',
      'exercises[0] needs at least one set.',
    ])
    expect(results(r).every((x: { reason: string }) => x.reason === 'invalid')).toBe(true)
    expect(r.isError).toBe(true)
    expect(db.insertedWorkouts).toEqual([])
  })

  it("is refused past one workout's caps, with the cap's code", async () => {
    const db = await fakeDb()
    const exercise = UPPER.exercises[0]!
    const r = await run(db, [
      later(0, { exercises: Array.from({ length: DomainLimits.workoutEntriesMax + 1 }, () => exercise) }),
      later(1, {
        exercises: [{ exercise_id: '0025', sets: Array.from({ length: DomainLimits.entrySetsMax + 1 }, () => exercise.sets[0]!) }],
      }),
      later(2, { exercises: Array.from({ length: DomainLimits.workoutEntriesMax }, () => exercise) }),
    ])
    expect(results(r)).toEqual([
      {
        index: 0,
        status: 'refused',
        reason: 'too_many_workout_exercises',
        message: AGENT_WORKOUT_CAPS.too_many_workout_exercises,
      },
      { index: 1, status: 'refused', reason: 'too_many_exercise_sets', message: AGENT_WORKOUT_CAPS.too_many_exercise_sets },
      { index: 2, status: 'added', workout_id: 'workout-1' },
    ])
  })

  it('is refused as unknown_exercise when an id is neither a library id nor a custom exercise, naming them', async () => {
    const db = await fakeDb()
    const r = await run(db, [
      later(0, { exercises: [{ exercise_id: 'nope', sets: [{ reps: 5, weight_kg: 50 }] }, ...UPPER.exercises] }),
      later(1, {
        exercises: [
          { exercise_id: 'zzz', sets: [{ reps: 5, weight_kg: 50 }] },
          { exercise_id: 'nope', sets: [{ reps: 5, weight_kg: 50 }] },
          { exercise_id: 'zzz', sets: [{ reps: 5, weight_kg: 50 }] },
        ],
      }),
    ])
    expect(results(r)).toEqual([
      {
        index: 0,
        status: 'refused',
        reason: 'unknown_exercise',
        message: "Unknown exercise id: nope. Use search_exercises for library ids and the owner's custom exercises.",
      },
      {
        index: 1,
        status: 'refused',
        reason: 'unknown_exercise',
        message: "Unknown exercise ids: zzz, nope. Use search_exercises for library ids and the owner's custom exercises.",
      },
    ])
  })
})
