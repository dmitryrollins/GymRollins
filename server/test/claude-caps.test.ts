// Claude's writes at an account's storage caps (plan 31), through the MCP tools as Claude calls them: at most 100
// proposals waiting for review and 5,000 in all, and the account's 20,000 weigh-ins.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { DomainLimits } from '../src/shared/domain-limits.ts'
import { CLAUDE_CAPS } from '../src/sync/caps.ts'
import { countOf, seedProposals, seedRows } from './cap-fixtures.ts'
import { connectClaude, mcp } from './claude.ts'
import { insertUser } from './gym-fixtures.ts'
import { request } from './helpers.ts'
import { readRpc, toolJson } from './mcp/rpc.ts'

const PROPOSAL = {
  summary: 'Add a Push day',
  changes: [{ id: 'c1', type: 'add-routine', routineId: 'new-push', name: 'Push' }],
}

const callTool = (token: string, name: string, args: Record<string, unknown>) =>
  mcp(token, 'tools/call', { name, arguments: args }, 2)

const pending = async (userId: string) => (await env.DB.prepare(
  "SELECT count(*) AS n FROM proposals WHERE user_id = ?1 AND status = 'pending'",
).bind(userId).first<{ n: number }>())!.n

/** Claude's call of change_plan: the tool's JSON, and whether it was an error. */
async function propose(token: string): Promise<{ isError: boolean; body: unknown }> {
  const msg = await readRpc(await callTool(token, 'change_plan', PROPOSAL))
  return { isError: msg.result.isError === true, body: toolJson(msg) }
}

describe("Claude's proposals, at most 100 waiting for review", () => {
  it('words the refusal for Claude', () => {
    expect(CLAUDE_CAPS.too_many_pending_proposals).toBe(
      'The owner already has 100 proposals waiting for review, the most one account holds. Nothing was saved: ask ' +
        'the owner to apply or dismiss some in the app, then call change_plan again.',
    )
  })

  it('takes the 99th and 100th, refuses the 101st, and never counts resolved ones', async () => {
    const c = await connectClaude()
    await seedProposals(c.userId, 5, 'dismissed')
    await seedProposals(c.userId, DomainLimits.pendingProposalsMax - 2)
    const token = c.tokens.access_token
    expect((await propose(token)).isError).toBe(false)
    expect((await propose(token)).isError).toBe(false)
    expect(await pending(c.userId)).toBe(100)
    expect(await propose(token))
      .toEqual({ isError: true, body: { error: CLAUDE_CAPS.too_many_pending_proposals } })
    expect(await pending(c.userId)).toBe(100)
    const audit = await env.DB.prepare(
      "SELECT ok FROM mcp_audit WHERE user_id = ?1 AND tool = 'change_plan' ORDER BY id DESC LIMIT 1",
    ).bind(c.userId).first<{ ok: number }>()
    expect(audit).toEqual({ ok: 0 })
  })

  it('takes one more once the owner resolves one in the app', async () => {
    const c = await connectClaude()
    const [first] = await seedProposals(c.userId, DomainLimits.pendingProposalsMax)
    expect((await propose(c.tokens.access_token)).isError).toBe(true)
    const later = new Date(Date.now() + 60_000).toISOString().replace(/Z$/, '000Z')
    const resolved = await request('PATCH', `/v1/claude/proposals/${first}`, {
      token: c.appToken,
      body: { status: 'dismissed', applied_change_ids: [], resolved_at: later, client_updated_at: later },
    })
    expect(resolved.status).toBe(200)
    expect((await propose(c.tokens.access_token)).isError).toBe(false)
    expect(await pending(c.userId)).toBe(100)
  })

  it("doesn't count another account's pending proposals", async () => {
    await seedProposals(await insertUser(), DomainLimits.pendingProposalsMax)
    const c = await connectClaude()
    expect((await propose(c.tokens.access_token)).isError).toBe(false)
  })
})

describe("Claude's proposals, at most 5,000 in all", () => {
  it('takes the 4,999th and 5,000th, and refuses the 5,001st though few are waiting', async () => {
    const c = await connectClaude()
    await seedProposals(c.userId, DomainLimits.proposalsMax - 2, 'dismissed')
    const token = c.tokens.access_token
    expect((await propose(token)).isError).toBe(false)
    expect((await propose(token)).isError).toBe(false)
    expect(await propose(token)).toEqual({ isError: true, body: { error: CLAUDE_CAPS.too_many_proposals } })
    expect(await pending(c.userId)).toBe(2)
    expect(await countOf('proposals', c.userId)).toBe(DomainLimits.proposalsMax)
  })

  it('frees no room when the owner resolves one: a resolved proposal still counts', async () => {
    const c = await connectClaude()
    await seedProposals(c.userId, DomainLimits.proposalsMax - 1, 'dismissed')
    const token = c.tokens.access_token
    expect((await propose(token)).isError).toBe(false)
    const waiting = await env.DB.prepare("SELECT id FROM proposals WHERE user_id = ?1 AND status = 'pending'")
      .bind(c.userId).first<{ id: string }>()
    const later = new Date(Date.now() + 60_000).toISOString().replace(/Z$/, '000Z')
    const resolved = await request('PATCH', `/v1/claude/proposals/${waiting!.id}`, {
      token: c.appToken,
      body: { status: 'dismissed', applied_change_ids: [], resolved_at: later, client_updated_at: later },
    })
    expect(resolved.status).toBe(200)
    expect(await pending(c.userId)).toBe(0)
    expect(await propose(token)).toEqual({ isError: true, body: { error: CLAUDE_CAPS.too_many_proposals } })
    expect(await countOf('proposals', c.userId)).toBe(DomainLimits.proposalsMax)
  })
})

describe("Claude's weigh-ins", () => {
  it("log_bodyweight refuses a weigh-in past the account's cap, with words for Claude", async () => {
    const c = await connectClaude()
    await seedRows('bodyweight', c.userId, DomainLimits.bodyweightsMax)
    const msg = await readRpc(await callTool(c.tokens.access_token, 'log_bodyweight', { weight_kg: 82 }))
    expect(msg.result.isError).toBe(true)
    expect(toolJson(msg)).toEqual({ error: CLAUDE_CAPS.too_many_body_weights })
    expect(await countOf('bodyweight', c.userId)).toBe(DomainLimits.bodyweightsMax)
  })
})
