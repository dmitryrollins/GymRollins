// Plan 32's columns (migrations/0011_ai_agents.sql): the Add workouts switch is off unless the owner turns it on, and
// the names of the agent that added a workout or sent a proposal hold 1 to 64 characters, or nothing.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { signUp } from './helpers.ts'

const T = '2026-11-09T10:00:00.000000Z'
const CHECK = /CHECK constraint failed/

async function newWorkout(userId: string, addedBy: string | null) {
  await env.DB.prepare(
    'INSERT INTO workouts (id, user_id, started_at, name, client_updated_at, updated_at, added_by) ' +
      "VALUES (?1, ?2, ?3, 'Upper', ?3, ?3, ?4)",
  ).bind(crypto.randomUUID(), userId, T, addedBy).run()
}

async function newProposal(userId: string, fromAgent: string | null) {
  await env.DB.prepare(
    'INSERT INTO proposals (id, user_id, created_at, summary, changes, client_updated_at, updated_at, from_agent) ' +
      `VALUES (?1, ?2, ?3, 'Bench', '[{"id":"c1"}]', ?3, ?3, ?4)`,
  ).bind(crypto.randomUUID(), userId, T, fromAgent).run()
}

describe('migration 0011', () => {
  it('stores a profile with Add workouts off, and only 0 or 1', async () => {
    const { userId } = await signUp()
    await env.DB.prepare('INSERT INTO profiles (user_id, client_updated_at, updated_at) VALUES (?1, ?2, ?2)')
      .bind(userId, T).run()
    const row = await env.DB.prepare('SELECT mcp_log_workouts FROM profiles WHERE user_id = ?1').bind(userId).first()
    expect(row).toEqual({ mcp_log_workouts: 0 })
    const set = (value: unknown) =>
      env.DB.prepare('UPDATE profiles SET mcp_log_workouts = ?2 WHERE user_id = ?1').bind(userId, value).run()
    await expect(set(1)).resolves.toBeTruthy()
    await expect(set(2)).rejects.toThrow(CHECK)
    await expect(set(null)).rejects.toThrow(/NOT NULL constraint failed/)
  })

  it("takes a workout's added_by of 1 to 64 characters or none", async () => {
    const { userId } = await signUp()
    await expect(newWorkout(userId, null)).resolves.toBeUndefined()
    await expect(newWorkout(userId, 'M')).resolves.toBeUndefined()
    await expect(newWorkout(userId, 'é'.repeat(64))).resolves.toBeUndefined()
    await expect(newWorkout(userId, '')).rejects.toThrow(CHECK)
    await expect(newWorkout(userId, 'x'.repeat(65))).rejects.toThrow(CHECK)
  })

  it("takes a proposal's from_agent of 1 to 64 characters or none", async () => {
    const { userId } = await signUp()
    await expect(newProposal(userId, null)).resolves.toBeUndefined()
    await expect(newProposal(userId, 'Muse')).resolves.toBeUndefined()
    await expect(newProposal(userId, 'é'.repeat(64))).resolves.toBeUndefined()
    await expect(newProposal(userId, '')).rejects.toThrow(CHECK)
    await expect(newProposal(userId, 'x'.repeat(65))).rejects.toThrow(CHECK)
  })

  it('leaves added_by and from_agent empty when a row names neither', async () => {
    const { userId } = await signUp()
    await env.DB.prepare(
      "INSERT INTO workouts (id, user_id, started_at, name, client_updated_at, updated_at) VALUES (?1, ?2, ?3, 'A', ?3, ?3)",
    ).bind(crypto.randomUUID(), userId, T).run()
    await env.DB.prepare(
      'INSERT INTO proposals (id, user_id, created_at, summary, changes, client_updated_at, updated_at) ' +
        `VALUES (?1, ?2, ?3, 'Bench', '[{"id":"c1"}]', ?3, ?3)`,
    ).bind(crypto.randomUUID(), userId, T).run()
    const row = await env.DB.prepare(
      'SELECT (SELECT added_by FROM workouts WHERE user_id = ?1) AS added_by, ' +
        '(SELECT from_agent FROM proposals WHERE user_id = ?1) AS from_agent',
    ).bind(userId).first()
    expect(row).toEqual({ added_by: null, from_agent: null })
  })
})
