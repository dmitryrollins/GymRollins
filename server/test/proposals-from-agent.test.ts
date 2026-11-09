// Which agent sent a proposal (plan 32; docs/specs/2026-11-09-ai-agents-design.md, section 3.3): propose_plan_changes
// stores the calling client's registered name, and the app's pull of pending proposals serves it as from_agent.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { D1Db } from '../src/mcp/d1-db.ts'
import { connectAgent, connectClaude, mcp } from './claude.ts'
import { request } from './helpers.ts'
import { readRpc } from './mcp/rpc.ts'

const PROPOSAL = {
  summary: 'Add a Push day',
  changes: [{ id: 'c1', type: 'add-routine', routineId: 'new-push', name: 'Push' }],
}

async function propose(token: string): Promise<void> {
  const msg = await readRpc(await mcp(token, 'tools/call', { name: 'propose_plan_changes', arguments: PROPOSAL }, 2))
  expect(msg.result.isError).toBeFalsy()
}

async function pendingFromAgents(appToken: string): Promise<unknown[]> {
  const res = await request('GET', '/v1/claude/proposals', { token: appToken })
  expect(res.status).toBe(200)
  return (await res.json<{ rows: { from_agent: unknown }[] }>()).rows.map((r) => r.from_agent)
}

describe("a proposal's agent", () => {
  it("is the calling client's registered name, stored and served to the app", async () => {
    const c = await connectClaude()
    const muse = await connectAgent(c.appToken, { name: 'Muse' })
    await propose(c.tokens.access_token)
    await propose(muse.tokens.access_token)
    // Two proposals can share a millisecond, and then their order is their ids'.
    expect((await pendingFromAgents(c.appToken)).sort()).toEqual(['Claude Code', 'Muse'])
    const stored = await env.DB.prepare('SELECT from_agent FROM proposals WHERE user_id = ?1 ORDER BY from_agent')
      .bind(c.userId).all()
    expect(stored.results).toEqual([{ from_agent: 'Claude Code' }, { from_agent: 'Muse' }])
  })

  it('is null when the client registered no name', async () => {
    const c = await connectClaude()
    const unnamed = await connectAgent(c.appToken)
    await propose(unnamed.tokens.access_token)
    expect(await pendingFromAgents(c.appToken)).toEqual([null])
  })

  it('is null for a proposal whose client is gone', async () => {
    const c = await connectClaude()
    await new D1Db(env.DB, c.userId, 'no-such-client').insertProposal({ summary: 'Old', changes: [{ id: 'c1' }] })
    expect(await pendingFromAgents(c.appToken)).toEqual([null])
  })
})
