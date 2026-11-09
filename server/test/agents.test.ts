// The agents connected to the account (plan 32; docs/specs/2026-11-09-ai-agents-design.md, section 3.1): GET /v1/agents
// lists every OAuth client holding a consent or a live refresh token for it, newest connection first.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import {
  AGENT_CALLBACK,
  Browser,
  CLAUDE_AI,
  connectAgent,
  connectClaude,
  decideCode,
  exchangeCode,
  finishInBrowser,
  LOOPBACK,
  mcp,
  openConnect,
  refresh,
  startFlow,
} from './claude.ts'
import { request, signUp } from './helpers.ts'
import { readRpc } from './mcp/rpc.ts'

interface Agent {
  client_id: string
  name: string
  host: string
  known_host: boolean
  connected_at: string
  last_used_at: string | null
}

async function agents(appToken: string): Promise<Agent[]> {
  const res = await request('GET', '/v1/agents', { token: appToken })
  expect(res.status).toBe(200)
  return (await res.json<{ agents: Agent[] }>()).agents
}

/** Sets when the owner approved the client, in Better Auth's form of a time (toISOString). */
const consentedAt = (clientId: string, userId: string, iso: string) =>
  env.DB.prepare('UPDATE oauthConsent SET createdAt = ?3 WHERE clientId = ?1 AND userId = ?2')
    .bind(clientId, userId, iso).run()

describe('GET /v1/agents', () => {
  it("lists each agent with its name, host and whether the host is Claude's, newest connection first", async () => {
    const c = await connectClaude()
    const muse = await connectAgent(c.appToken, { name: 'Muse' })
    const claude = await connectAgent(c.appToken, { name: 'Claude', redirectUri: CLAUDE_AI })
    await consentedAt(c.clientId, c.userId, '2026-11-01T08:00:00.000Z')
    await consentedAt(muse.clientId, c.userId, '2026-11-09T01:20:00.000Z')
    await consentedAt(claude.clientId, c.userId, '2026-11-05T12:30:15.250Z')
    expect(await agents(c.appToken)).toEqual([
      {
        client_id: muse.clientId, name: 'Muse', host: 'agent.meta.ai', known_host: false,
        connected_at: '2026-11-09T01:20:00.000000Z', last_used_at: null,
      },
      {
        client_id: claude.clientId, name: 'Claude', host: 'claude.ai', known_host: true,
        connected_at: '2026-11-05T12:30:15.250000Z', last_used_at: null,
      },
      {
        client_id: c.clientId, name: 'Claude Code', host: '127.0.0.1:33418', known_host: false,
        connected_at: '2026-11-01T08:00:00.000000Z', last_used_at: null,
      },
    ])
  })

  it('names an agent by its host when it registered no name', async () => {
    const { token } = await signUp()
    const unnamed = await connectAgent(token)
    expect(await agents(token)).toMatchObject([
      { client_id: unnamed.clientId, name: new URL(AGENT_CALLBACK).host, host: 'agent.meta.ai' },
    ])
  })

  it('gives each agent its own last use, the newest of its audited calls', async () => {
    const c = await connectClaude()
    const muse = await connectAgent(c.appToken, { name: 'Muse' })
    for (const id of [2, 3]) {
      // Read to the end: the audit row is written as the answer is.
      await readRpc(await mcp(muse.tokens.access_token, 'tools/call', { name: 'get_profile', arguments: {} }, id))
    }
    const newest = await env.DB.prepare(
      'SELECT max(at) AS at FROM mcp_audit WHERE user_id = ?1 AND client_id = ?2',
    ).bind(c.userId, muse.clientId).first<{ at: string }>()
    const byId = Object.fromEntries((await agents(c.appToken)).map((a) => [a.client_id, a.last_used_at]))
    expect(byId).toEqual({ [muse.clientId]: newest!.at, [c.clientId]: null })
    expect(newest!.at).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/)
  })

  it('lists a client that holds only a live refresh token, as connected when its first token was', async () => {
    const c = await connectClaude()
    await env.DB.prepare('DELETE FROM oauthConsent WHERE userId = ?1').bind(c.userId).run()
    const first = await env.DB.prepare(
      'SELECT min(createdAt) AS at FROM oauthRefreshToken WHERE userId = ?1 AND clientId = ?2',
    ).bind(c.userId, c.clientId).first<{ at: string }>()
    const [listed] = await agents(c.appToken)
    expect(listed).toMatchObject({ client_id: c.clientId, name: 'Claude Code' })
    expect(listed!.connected_at).toBe(first!.at.replace(/Z$/, '000Z'))
    await env.DB.prepare("UPDATE oauthRefreshToken SET expiresAt = '2026-01-01T00:00:00.000Z' WHERE userId = ?1")
      .bind(c.userId).run()
    expect(await agents(c.appToken)).toEqual([])
  })

  it("lists only the account's own agents", async () => {
    const mine = await connectClaude()
    const theirs = await connectClaude()
    await connectAgent(theirs.appToken, { name: 'Muse' })
    expect((await agents(mine.appToken)).map((a) => a.client_id)).toEqual([mine.clientId])
    expect(await agents((await signUp()).token)).toEqual([])
  })

  it("needs the app's session: no token, or an agent's, is 401", async () => {
    const c = await connectClaude()
    expect((await request('GET', '/v1/agents')).status).toBe(401)
    expect((await request('GET', '/v1/agents', { token: c.tokens.access_token })).status).toBe(401)
  })
})

const disconnect = (appToken: string | undefined, clientId: string) =>
  request('POST', `/v1/agents/${encodeURIComponent(clientId)}/disconnect`, appToken ? { token: appToken } : {})

/** An agent the owner approved again, whose browser holds its /connect session and whose code isn't swapped yet. */
async function approvedUnswapped(appToken: string, clientId: string, redirectUri: string) {
  const flow = await startFlow(clientId, redirectUri)
  const browser = new Browser()
  const { code } = await openConnect(browser, flow)
  expect((await decideCode(appToken, code, 'approve')).status).toBe(200)
  return { flow, code: await finishInBrowser(browser, flow) }
}

/** The account's rows for one client in each table a disconnect clears. */
async function grantsOf(userId: string, clientId: string) {
  return await env.DB.prepare(
    'SELECT (SELECT count(*) FROM oauthAccessToken WHERE userId = ?1 AND clientId = ?2) AS access, ' +
      '(SELECT count(*) FROM oauthRefreshToken WHERE userId = ?1 AND clientId = ?2) AS refresh, ' +
      '(SELECT count(*) FROM oauthConsent WHERE userId = ?1 AND clientId = ?2) AS consent, ' +
      '(SELECT count(*) FROM connect_requests WHERE user_id = ?1 AND client_id = ?2) AS requests, ' +
      "(SELECT count(*) FROM verification WHERE json_valid(value) AND json_extract(value, '$.userId') = ?1 " +
      "AND json_extract(value, '$.query.client_id') = ?2) AS codes",
  ).bind(userId, clientId).first()
}

const browserSessions = async (userId: string) =>
  (await env.DB.prepare('SELECT count(*) AS n FROM session WHERE userId = ?1 AND claudeConnect = 1').bind(userId)
    .first<{ n: number }>())!.n

describe('POST /v1/agents/:clientId/disconnect', () => {
  it('cuts that agent off, its tokens and its approval, and leaves another agent working', async () => {
    const c = await connectClaude()
    const muse = await connectAgent(c.appToken, { name: 'Muse' })
    const res = await disconnect(c.appToken, muse.clientId)
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ disconnected: true })
    expect((await mcp(muse.tokens.access_token, 'tools/list')).status).toBe(401)
    expect((await refresh(muse.clientId, muse.tokens.refresh_token)).status).toBe(400)
    expect(await grantsOf(c.userId, muse.clientId)).toEqual({ access: 0, refresh: 0, consent: 0, requests: 0, codes: 0 })
    expect((await mcp(c.tokens.access_token, 'tools/list')).status).toBe(200)
    expect(await grantsOf(c.userId, c.clientId)).toMatchObject({ consent: 1, requests: 1 })
    expect((await agents(c.appToken)).map((a) => a.client_id)).toEqual([c.clientId])
    const client = await env.DB.prepare('SELECT count(*) AS n FROM oauthClient WHERE clientId = ?1')
      .bind(muse.clientId).first()
    expect(client).toEqual({ n: 1 })
  })

  it("ends that agent's approved browser and its unredeemed code, and no other agent's", async () => {
    const c = await connectClaude()
    const muse = await connectAgent(c.appToken, { name: 'Muse' })
    const museAgain = await approvedUnswapped(c.appToken, muse.clientId, AGENT_CALLBACK)
    const claudeAgain = await approvedUnswapped(c.appToken, c.clientId, LOOPBACK)
    expect(await grantsOf(c.userId, muse.clientId)).toMatchObject({ codes: 1 })
    expect(await browserSessions(c.userId)).toBe(2)
    expect((await disconnect(c.appToken, muse.clientId)).status).toBe(200)
    expect(await grantsOf(c.userId, muse.clientId)).toMatchObject({ codes: 0, requests: 0 })
    expect(await browserSessions(c.userId)).toBe(1)
    expect((await exchangeCode(museAgain.flow, museAgain.code)).status).toBe(400)
    expect((await exchangeCode(claudeAgain.flow, claudeAgain.code)).status).toBe(200)
  })

  it("answers 404 unknown_agent for a client the account never connected, or another account's", async () => {
    const mine = await connectClaude()
    const theirs = await connectClaude()
    const unknown = {
      error: { code: 'unknown_agent', message: 'No agent with this id is connected to your account.' },
    }
    for (const clientId of ['no-such-client', theirs.clientId, 'x'.repeat(300)]) {
      const res = await disconnect(mine.appToken, clientId)
      expect(res.status, clientId).toBe(404)
      expect(await res.json()).toEqual(unknown)
    }
    expect((await mcp(theirs.tokens.access_token, 'tools/list')).status).toBe(200)
    expect((await disconnect(mine.appToken, mine.clientId)).status).toBe(200)
    expect((await disconnect(mine.appToken, mine.clientId)).status).toBe(404)
  })

  it('leaves Disconnect all cutting every agent at once', async () => {
    const c = await connectClaude()
    const muse = await connectAgent(c.appToken, { name: 'Muse' })
    expect(await (await request('POST', '/v1/claude/revoke', { token: c.appToken })).json()).toEqual({ revoked: 2 })
    for (const token of [c.tokens.access_token, muse.tokens.access_token]) {
      expect((await mcp(token, 'tools/list')).status).toBe(401)
    }
    expect(await agents(c.appToken)).toEqual([])
  })

  it("needs the app's session", async () => {
    const c = await connectClaude()
    expect((await disconnect(undefined, c.clientId)).status).toBe(401)
    expect((await disconnect(c.tokens.access_token, c.clientId)).status).toBe(401)
    expect((await mcp(c.tokens.access_token, 'tools/list')).status).toBe(200)
  })
})
