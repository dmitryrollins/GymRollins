// The data side of log_workout (plan 32; docs/specs/2026-11-09-ai-agents-design.md, section 3.4) against real D1: the
// Add workouts switch, the exercises an agent may log, its name, and a workout written by the app's own save path, so
// the caps hold and the phone pulls it.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import type { LoggedWorkout } from '../../src/mcp/db.ts'
import { D1Db } from '../../src/mcp/d1-db.ts'
import { ToolError } from '../../src/mcp/tools/result.ts'
import { DomainLimits } from '../../src/shared/domain-limits.ts'
import { AGENT_WORKOUT_CAPS } from '../../src/sync/caps.ts'
import { countOf, kept, seedCount, seedRows } from '../cap-fixtures.ts'
import { request, signUp } from '../helpers.ts'

const T = '2026-11-07T10:00:00.000000Z'
const DB = env.DB

const LOGGED: LoggedWorkout = {
  started_at: '2026-10-08T17:02:00.000000Z',
  ended_at: '2026-10-08T18:05:00.000000Z',
  name: 'Upper',
  note: 'From Fitbod',
  exercises: [
    {
      exercise_id: '0025',
      sets: [
        { reps: 10, weight_kg: 20, sec: null, dist_m: null, warmup: true },
        { reps: 8, weight_kg: 63.5, sec: null, dist_m: null, warmup: false },
      ],
    },
    { exercise_id: '0001', sets: [{ reps: 0, weight_kg: 0, sec: 60, dist_m: 250, warmup: false }] },
  ],
}

/** A new account with a saved profile: Add workouts on unless `on` is false. */
async function owner(on = true): Promise<{ token: string; userId: string }> {
  const account = await signUp()
  await DB.prepare(
    'INSERT INTO profiles (user_id, mcp_log_workouts, client_updated_at, updated_at) VALUES (?1, ?2, ?3, ?3)',
  ).bind(account.userId, on ? 1 : 0, T).run()
  return account
}

const agentDb = (userId: string, clientId = 'agent-client') => new D1Db(DB, userId, clientId)

describe('the Add workouts switch', () => {
  it('is on only when the owner turned it on', async () => {
    expect(await agentDb((await owner(true)).userId).mayLogWorkouts()).toBe(true)
    expect(await agentDb((await owner(false)).userId).mayLogWorkouts()).toBe(false)
    expect(await agentDb((await signUp()).userId).mayLogWorkouts()).toBe(false)
  })

  it('refuses a workout while it is off, writing nothing', async () => {
    const { userId } = await owner(false)
    await expect(agentDb(userId).insertWorkout(LOGGED, 'Muse')).rejects.toThrow(ToolError)
    expect(await countOf('workouts', userId)).toBe(0)
  })
})

describe('a workout an agent adds', () => {
  it('is an import marked with the agent, with done sets and its volume, which the app pulls', async () => {
    const { token, userId } = await owner()
    const added = await agentDb(userId).insertWorkout(LOGGED, 'Muse')
    expect(added).toEqual({ added: true, id: expect.stringMatching(/^[0-9a-f-]{36}$/) })
    const res = await request('GET', '/v1/sync/workouts', { token })
    const [pulled] = (await res.json<{ rows: Record<string, any>[] }>()).rows
    expect(pulled).toMatchObject({
      id: (added as { id: string }).id,
      started_at: LOGGED.started_at,
      ended_at: LOGGED.ended_at,
      name: 'Upper',
      note: 'From Fitbod',
      source: 'import',
      added_by: 'Muse',
      routine_id: null,
      gym_id: null,
      paused_sec: 0,
      vol_kg: 508,
      records: [],
      deleted_at: null,
    })
    expect(pulled!.updated_at).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/)
    expect(pulled!.entries.map((e: Record<string, any>) => [e.exercise_id, e.position])).toEqual([['0025', 0], ['0001', 1]])
    expect(pulled!.entries[0].sets).toMatchObject([
      { position: 0, w_kg: 20, r: 10, sec: null, dist_m: null, done: true, warmup: true, multiplier: 1 },
      { position: 1, w_kg: 63.5, r: 8, done: true, warmup: false, multiplier: 1 },
    ])
    expect(pulled!.entries[1].sets).toMatchObject([{ w_kg: 0, r: 0, sec: 60, dist_m: 250, done: true }])
    expect([await countOf('workouts', userId), await kept('workout_entries', userId), await kept('workout_sets', userId)])
      .toEqual([1, 2, 3])
  })

  it("is refused at the account's workout cap with the agent's words, and nothing is written", async () => {
    const { userId } = await owner()
    await seedRows('workouts', userId, DomainLimits.workoutsMax)
    expect(await agentDb(userId).insertWorkout(LOGGED, 'Muse')).toEqual({
      added: false,
      reason: 'too_many_workouts',
      message: AGENT_WORKOUT_CAPS.too_many_workouts,
    })
    expect(await countOf('workouts', userId)).toBe(DomainLimits.workoutsMax)
  })

  it('is refused whole when its sets would pass the sets the account may log', async () => {
    const { userId } = await owner()
    await seedCount('workout_sets', userId, DomainLimits.accountSetsMax - 2)
    expect(await agentDb(userId).insertWorkout(LOGGED, 'Muse')).toMatchObject({
      added: false,
      reason: 'too_many_logged_sets',
    })
    expect([await countOf('workouts', userId), await kept('workout_sets', userId)])
      .toEqual([0, DomainLimits.accountSetsMax - 2])
  })

  it('is refused past the per-workout caps, before anything is written', async () => {
    const { userId } = await owner()
    const exercise = LOGGED.exercises[1]!
    const wide = { ...LOGGED, exercises: Array.from({ length: DomainLimits.workoutEntriesMax + 1 }, () => exercise) }
    expect(await agentDb(userId).insertWorkout(wide, 'Muse')).toEqual({
      added: false,
      reason: 'too_many_workout_exercises',
      message: AGENT_WORKOUT_CAPS.too_many_workout_exercises,
    })
    const sets = Array.from({ length: DomainLimits.entrySetsMax + 1 }, () => exercise.sets[0]!)
    const deep = { ...LOGGED, exercises: [{ exercise_id: '0001', sets }] }
    expect(await agentDb(userId).insertWorkout(deep, 'Muse')).toMatchObject({ reason: 'too_many_exercise_sets' })
    expect(await countOf('workouts', userId)).toBe(0)
  })
})

describe('what an agent may log', () => {
  it("takes library ids and the owner's live custom exercises, whatever the plan switch says", async () => {
    const { userId } = await owner()
    const other = await owner()
    const custom = (user: string, deleted: string | null) => {
      const id = `custom-${crypto.randomUUID()}`
      return DB.prepare(
        'INSERT INTO custom_exercises (id, user_id, n, bp, eq, tg, mode, client_updated_at, updated_at, deleted_at) ' +
          "VALUES (?1, ?2, 'Sled push', 'upper legs', 'sled machine', 'quads', 'reps', ?3, ?3, ?4)",
      ).bind(id, user, T, deleted).run().then(() => id)
    }
    const [mine, gone, theirs] = [await custom(userId, null), await custom(userId, T), await custom(other.userId, null)]
    await DB.prepare('UPDATE profiles SET mcp_read_plan = 0 WHERE user_id = ?1').bind(userId).run()
    const known = await agentDb(userId).loggableExerciseIds(['0025', mine, gone, theirs, 'nope'])
    expect([...known].sort()).toEqual(['0025', mine].sort())
    expect(await agentDb(userId).loggableExerciseIds([])).toEqual(new Set())
  })

  it('labels the agent by its registered name and its host (src/claude/hosts.ts, agentLabel)', async () => {
    const { userId } = await owner()
    const client = (name: string | null) => {
      const clientId = crypto.randomUUID()
      return DB.prepare('INSERT INTO oauthClient (id, clientId, name, redirectUris) VALUES (?1, ?2, ?3, ?4)')
        .bind(crypto.randomUUID(), clientId, name, '["https://agent.meta.ai/cb"]').run().then(() => clientId)
    }
    expect(await agentDb(userId, await client('Muse')).agentName()).toBe('Muse (agent.meta.ai)')
    expect(await agentDb(userId, await client(null)).agentName()).toBe('agent.meta.ai')
    expect(await agentDb(userId, await client('x'.repeat(65))).agentName()).toBe('agent.meta.ai')
    expect(await agentDb(userId, 'no-such-client').agentName()).toBeNull()
  })
})
