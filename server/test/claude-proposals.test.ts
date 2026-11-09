// The app's side of Claude's data (spec section 3, "Routes"): pending proposals, resolving one, and when
// Claude was last used. Bodies keep the fields ProposalDTO and the old transport read and wrote.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { D1Db } from '../src/mcp/d1-db.ts'
import { request, signUp } from './helpers.ts'

const CHANGE = { id: 'c1', type: 'weight', routineId: 'r1', exerciseId: '0025', weightKg: 65 }

async function propose(userId: string, summary = 'Bench +5 lb') {
  return await new D1Db(env.DB, userId, 'claude').insertProposal({ summary, changes: [CHANGE] })
}

const resolve = (token: string, id: string, body: Record<string, unknown>) =>
  request('PATCH', `/v1/claude/proposals/${id}`, { token, body })

/** `ms` from now, in the stored six-digit form: a resolution must be newer than the proposal Claude just wrote. */
const fromNow = (ms: number) => new Date(Date.now() + ms).toISOString().replace(/Z$/, '000Z')

const RESOLVED = {
  status: 'applied',
  applied_change_ids: ['c1'],
  resolved_at: fromNow(60 * 60_000),
  client_updated_at: fromNow(60 * 60_000),
}

describe('GET /v1/claude/proposals', () => {
  it("lists the account's pending proposals, oldest first, with their changes as JSON", async () => {
    const { token, userId } = await signUp()
    const first = await propose(userId, 'First')
    const second = await propose(userId, 'Second')
    await propose((await signUp()).userId, 'Not yours')
    const res = await request('GET', '/v1/claude/proposals', { token })
    expect(res.status).toBe(200)
    const { rows } = await res.json<{ rows: Record<string, unknown>[] }>()
    expect(rows.map((r) => r.id)).toEqual([first.id, second.id])
    expect(rows[0]).toEqual({
      id: first.id,
      created_at: first.created_at,
      source: 'claude',
      summary: 'First',
      changes: [CHANGE],
      status: 'pending',
      applied_change_ids: [],
      resolved_at: null,
      from_agent: null,
    })
  })
})

describe('PATCH /v1/claude/proposals/:id', () => {
  it('stores the resolution, and the proposal leaves the pending list', async () => {
    const { token, userId } = await signUp()
    const { id } = await propose(userId)
    const res = await resolve(token, id.toUpperCase(), RESOLVED)
    expect(res.status).toBe(200)
    const ack = await res.json<{ id: string; updated_at: string }>()
    expect(ack.id).toBe(id)
    const row = await env.DB.prepare(
      'SELECT status, applied_change_ids, resolved_at, client_updated_at, updated_at FROM proposals WHERE ' +
        'id = ?1',
    ).bind(id).first()
    expect(row).toEqual({
      status: 'applied',
      applied_change_ids: '["c1"]',
      resolved_at: RESOLVED.resolved_at,
      client_updated_at: RESOLVED.client_updated_at,
      updated_at: ack.updated_at,
    })
    expect((await (await request('GET', '/v1/claude/proposals', { token })).json<{ rows: unknown[] }>()).rows)
      .toEqual([])
  })

  it('keeps a newer resolution over an older one, and answers the stored row', async () => {
    const { token, userId } = await signUp()
    const { id } = await propose(userId)
    const newer =
      await (await resolve(token, id, { ...RESOLVED, status: 'dismissed', applied_change_ids: [] })).json()
    const older = await resolve(token, id, { ...RESOLVED, client_updated_at: fromNow(30 * 60_000) })
    expect(older.status).toBe(200)
    expect(await older.json()).toEqual(newer)
    const row = await env.DB.prepare('SELECT status FROM proposals WHERE id = ?1').bind(id).first()
    expect(row).toEqual({ status: 'dismissed' })
  })

  // Added after review: its own code, so the app counts only this 404 as sent, never a missing route's
  // (`not_found`) or a proxy's.
  it("answers 404 no_such_proposal for another account's proposal and an unknown id", async () => {
    const { userId } = await signUp()
    const { id } = await propose(userId)
    const { token } = await signUp()
    for (const unknown of [id, crypto.randomUUID(), 'not-a-uuid']) {
      const res = await resolve(token, unknown, RESOLVED)
      expect(res.status).toBe(404)
      expect(await res.json()).toEqual({ error: { code: 'no_such_proposal', message: 'No such proposal.' } })
    }
  })

  it.each([
    [{ status: 'pending' }, 'status'],
    [{ status: 'approved' }, 'status'],
    [{ applied_change_ids: 'c1' }, 'applied_change_ids'],
    [{ applied_change_ids: Array.from({ length: 26 }, (_, i) => `c${i}`) }, 'applied_change_ids'],
    [{ resolved_at: 'yesterday' }, 'resolved_at'],
    [{ client_updated_at: null }, 'client_updated_at'],
  ])('refuses %o as row_rejected (%s)', async (change, field) => {
    const { token, userId } = await signUp()
    const { id } = await propose(userId)
    const res = await resolve(token, id, { ...RESOLVED, ...change })
    expect(res.status).toBe(422)
    const body = await res.json<{ error: { code: string; message: string } }>()
    expect(body.error.code).toBe('row_rejected')
    expect(body.error.message.startsWith(`${field}:`)).toBe(true)
  })
})

describe('GET /v1/claude/last-use', () => {
  it("is null until Claude calls a tool, then the newest audit row's time", async () => {
    const { token, userId } = await signUp()
    expect(await (await request('GET', '/v1/claude/last-use', { token })).json()).toEqual({ at: null })
    await new D1Db(env.DB, userId, 'claude').audit('get_plan', true, 'a'.repeat(64))
    const { at } = await (await request('GET', '/v1/claude/last-use', { token })).json<{ at: string }>()
    expect(Math.abs(Date.parse(at) - Date.now())).toBeLessThan(120_000)
    await new D1Db(env.DB, (await signUp()).userId, 'claude').audit('get_plan', true, 'b'.repeat(64))
    expect((await (await request('GET', '/v1/claude/last-use', { token })).json<{ at: string }>()).at).toBe(
      at,
    )
  })
})
