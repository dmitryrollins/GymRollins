// log_workout through /mcp against D1 (plan 32; docs/specs/2026-11-09-ai-agents-design.md, sections 3.4 and 5): an
// agent adds past workouts behind the owner's Add workouts switch, each checked on its own, and the phone pulls them
// marked with the agent's name.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { NOT_ALLOWED_WORKOUTS } from '../src/mcp/tools/log-workout.ts'
import { DomainLimits } from '../src/shared/domain-limits.ts'
import { AGENT_WORKOUT_CAPS } from '../src/sync/caps.ts'
import { countOf, seedRows } from './cap-fixtures.ts'
import { connectAgent, connectClaude, type Connection, mcp } from './claude.ts'
import { request } from './helpers.ts'
import { readRpc, toolJson } from './mcp/rpc.ts'

const T = '2026-11-07T10:00:00.000000Z'

interface Result {
  index: number
  status: 'added' | 'refused'
  workout_id?: string
  reason?: string
  message?: string
}

/** A past session on 2026-10-`day`, 17:00 to 18:00 UTC, with `overrides`. */
function session(day: number, overrides: Record<string, unknown> = {}) {
  const date = `2026-10-${String(day).padStart(2, '0')}`
  return {
    started_at: `${date}T17:00:00Z`,
    ended_at: `${date}T18:00:00Z`,
    name: 'Upper',
    exercises: [{ exercise_id: '0025', sets: [{ reps: 8, weight_kg: 63.5 }, { reps: 8, weight_kg: 63.5 }] }],
    ...overrides,
  }
}

/** A connected account whose profile has Add workouts on, unless `on` is false. */
async function owner(on = true): Promise<Connection> {
  const c = await connectClaude()
  await env.DB.prepare(
    'INSERT INTO profiles (user_id, mcp_log_workouts, client_updated_at, updated_at) VALUES (?1, ?2, ?3, ?3)',
  ).bind(c.userId, on ? 1 : 0, T).run()
  return c
}

async function logWorkout(token: string, workouts: unknown[]): Promise<{ isError: boolean; results: Result[] }> {
  const msg = await readRpc(await mcp(token, 'tools/call', { name: 'log_workout', arguments: { workouts } }, 2))
  return { isError: msg.result.isError === true, results: toolJson(msg).results }
}

async function pulled(appToken: string): Promise<Record<string, any>[]> {
  const res = await request('GET', '/v1/sync/workouts', { token: appToken })
  expect(res.status).toBe(200)
  return (await res.json<{ rows: Record<string, any>[] }>()).rows
}

const lastAudit = (userId: string) =>
  env.DB.prepare("SELECT ok FROM mcp_audit WHERE user_id = ?1 AND tool = 'log_workout' ORDER BY id DESC LIMIT 1")
    .bind(userId).first()

describe('log_workout', () => {
  it('adds past workouts to the history, marked with the agent, and the phone pulls them', async () => {
    const c = await owner()
    const { isError, results } = await logWorkout(c.tokens.access_token, [session(6), session(8)])
    expect(isError).toBe(false)
    expect(results).toEqual([
      { index: 0, status: 'added', workout_id: expect.stringMatching(/^[0-9a-f-]{36}$/) },
      { index: 1, status: 'added', workout_id: expect.stringMatching(/^[0-9a-f-]{36}$/) },
    ])
    const rows = await pulled(c.appToken)
    expect(rows.map((w) => w.id).sort()).toEqual(results.map((r) => r.workout_id).sort())
    expect(rows.find((w) => w.id === results[0]!.workout_id)).toMatchObject({
      started_at: '2026-10-06T17:00:00.000000Z',
      ended_at: '2026-10-06T18:00:00.000000Z',
      name: 'Upper',
      source: 'import',
      added_by: 'Claude Code',
      vol_kg: 1016,
      entries: [{ exercise_id: '0025', sets: [{ w_kg: 63.5, r: 8, done: true }, { w_kg: 63.5, r: 8, done: true }] }],
    })
    expect(await lastAudit(c.userId)).toEqual({ ok: 1 })
  })

  it('marks a workout "Agent" when its client registered no name', async () => {
    const c = await owner()
    const unnamed = await connectAgent(c.appToken)
    expect((await logWorkout(unnamed.tokens.access_token, [session(6)])).results[0]!.status).toBe('added')
    expect((await pulled(c.appToken)).map((w) => w.added_by)).toEqual(['Agent'])
  })

  it('refuses every workout while Add workouts is off, as a failed call, and adds nothing', async () => {
    for (const c of [await owner(false), await connectClaude()]) {
      const { isError, results } = await logWorkout(c.tokens.access_token, [session(6), session(8)])
      expect(isError).toBe(true)
      expect(results).toEqual([0, 1].map((index) => ({
        index,
        status: 'refused',
        reason: 'not_allowed',
        message: NOT_ALLOWED_WORKOUTS,
      })))
      expect(await countOf('workouts', c.userId)).toBe(0)
      expect(await lastAudit(c.userId)).toEqual({ ok: 0 })
    }
  })

  it("takes the owner's custom exercise, and refuses only the workout naming an unknown one", async () => {
    const c = await owner()
    const custom = `custom-${crypto.randomUUID()}`
    await env.DB.prepare(
      'INSERT INTO custom_exercises (id, user_id, n, bp, eq, tg, mode, client_updated_at, updated_at) ' +
        "VALUES (?1, ?2, 'Sled push', 'upper legs', 'sled machine', 'quads', 'reps', ?3, ?3)",
    ).bind(custom, c.userId, T).run()
    const sets = [{ reps: 10, weight_kg: 90 }]
    const { isError, results } = await logWorkout(c.tokens.access_token, [
      session(6, { exercises: [{ exercise_id: custom, sets }] }),
      session(8, { exercises: [{ exercise_id: 'not-an-exercise', sets }] }),
    ])
    expect(isError).toBe(false)
    expect(results.map((r) => [r.status, r.reason])).toEqual([['added', undefined], ['refused', 'unknown_exercise']])
    expect(results[1]!.message).toContain('not-an-exercise')
    expect((await pulled(c.appToken)).map((w) => w.entries[0].exercise_id)).toEqual([custom])
  })

  it('refuses a workout with bad times as invalid, and adds the rest', async () => {
    const c = await owner()
    const { results } = await logWorkout(c.tokens.access_token, [
      session(6, { ended_at: '2026-10-06T16:00:00Z' }),
      session(7, { started_at: '2099-01-01T10:00:00Z', ended_at: '2099-01-01T11:00:00Z' }),
      session(8),
    ])
    expect(results.map((r) => r.reason ?? r.status)).toEqual(['invalid', 'invalid', 'added'])
    expect(await countOf('workouts', c.userId)).toBe(1)
  })

  it("refuses a workout past the account's cap with the cap's code", async () => {
    const c = await owner()
    await seedRows('workouts', c.userId, DomainLimits.workoutsMax - 1)
    const { results } = await logWorkout(c.tokens.access_token, [session(6), session(8)])
    expect(results).toEqual([
      { index: 0, status: 'added', workout_id: expect.any(String) },
      { index: 1, status: 'refused', reason: 'too_many_workouts', message: AGENT_WORKOUT_CAPS.too_many_workouts },
    ])
    expect(await countOf('workouts', c.userId)).toBe(DomainLimits.workoutsMax)
  })
})
