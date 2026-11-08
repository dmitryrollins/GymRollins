// The whole connection (spec section 8): approval, Claude's tools on /mcp with its token, refresh, Disconnect
// Claude and the 401 after it, which token works where, and 70 concurrent calls giving exactly 60 successes.
import { env } from 'cloudflare:workers'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  ACCEPT,
  Browser,
  call,
  connectClaude,
  decideCode,
  exchangeCode,
  finishInBrowser,
  initialize,
  mcp,
  openConnect,
  PROTOCOL_VERSION,
  refresh,
  registerClient,
  startFlow,
  type Tokens,
} from './claude.ts'
import { request, signUp } from './helpers.ts'
import { readRpc } from './mcp/rpc.ts'

afterEach(() => vi.useRealTimers())

const callTool = (token: string, name: string, args: Record<string, unknown> = {}, id = 2) =>
  mcp(token, 'tools/call', { name, arguments: args }, id)

/** Added after review: an approved browser holding its /connect session, and Claude's code, unswapped. */
async function approvedBrowser() {
  const { token: appToken, userId } = await signUp()
  const flow = await startFlow(await registerClient())
  const browser = new Browser()
  const { code } = await openConnect(browser, flow)
  expect((await decideCode(appToken, code, 'approve')).status).toBe(200)
  const claudeCode = await finishInBrowser(browser, flow)
  return { appToken, userId, flow, browser, claudeCode }
}

describe('Claude on /mcp', () => {
  it("lists the 15 tools and calls one with the owner's data, audited", async () => {
    const c = await connectClaude()
    const init = await readRpc(await initialize(c.tokens.access_token))
    expect(init.result.serverInfo.name).toBe('gymrollins')
    expect((await readRpc(await mcp(c.tokens.access_token, 'tools/list'))).result.tools).toHaveLength(15)
    const msg = await readRpc(await callTool(c.tokens.access_token, 'get_profile'))
    expect(msg.result.isError).toBeFalsy()
    const audit = await env.DB.prepare('SELECT tool, ok, client_id FROM mcp_audit WHERE user_id = ?1').bind(
      c.userId,
    ).all()
    expect(audit.results).toEqual([{ tool: 'get_profile', ok: 1, client_id: c.clientId }])
  })

  it('writes a proposal the app then pulls', async () => {
    const c = await connectClaude()
    const res = await callTool(c.tokens.access_token, 'propose_plan_changes', {
      summary: 'Add a Push day',
      changes: [{ id: 'c1', type: 'add-routine', routineId: 'new-push', name: 'Push' }],
    })
    expect((await readRpc(res)).result.isError).toBeFalsy()
    const pulled = await (await request('GET', '/v1/claude/proposals', { token: c.appToken })).json<
      { rows: unknown[] }
    >()
    expect(pulled.rows).toMatchObject([{ summary: 'Add a Push day', status: 'pending', source: 'claude' }])
  })

  it('answers 401 and the metadata pointer to no token, an expired one and an app session', async () => {
    const c = await connectClaude()
    const pointer = 'Bearer resource_metadata="http://localhost/.well-known/oauth-protected-resource/mcp"'
    for (const token of [undefined, c.appToken, `${c.tokens.access_token}x`]) {
      const res = await mcp(token, 'tools/list')
      expect(res.status).toBe(401)
      expect(res.headers.get('www-authenticate')).toBe(pointer)
    }
    await env.DB.prepare(
      "UPDATE oauthAccessToken SET expiresAt = '2026-01-01T00:00:00.000Z' WHERE userId = ?1",
    )
      .bind(c.userId).run()
    expect((await mcp(c.tokens.access_token, 'tools/list')).status).toBe(401)
    const audits = await env.DB.prepare('SELECT count(*) AS n FROM mcp_audit WHERE user_id = ?1').bind(
      c.userId,
    ).first()
    expect(audits).toEqual({ n: 0 })
  })

  it('gives exactly 60 of 70 concurrent calls an answer and the rest 429', async () => {
    const c = await connectClaude()
    const statuses = await Promise.all(
      Array.from(
        { length: 70 },
        (_, i) =>
          callTool(c.tokens.access_token, 'get_profile', {}, i + 1).then(async (r) => {
            await r.body?.cancel()
            return r.status
          }),
      ),
    )
    expect(statuses.filter((s) => s === 200)).toHaveLength(60)
    expect(statuses.filter((s) => s === 429)).toHaveLength(10)
  })

  // Added after review: a token is for /mcp only with the mcp scope. Before, a client that asked for
  // offline_access alone got a token without it, and /mcp served it.
  it('refuses a token without the mcp scope', async () => {
    const { token: appToken } = await signUp()
    const flow = await startFlow(await registerClient(), undefined, 'offline_access')
    const browser = new Browser()
    const { code } = await openConnect(browser, flow)
    expect((await decideCode(appToken, code, 'approve')).status).toBe(200)
    const tokens = await (await exchangeCode(flow, await finishInBrowser(browser, flow))).json<Tokens>()
    expect(tokens.scope).toBe('offline_access')
    const res = await mcp(tokens.access_token, 'tools/list')
    expect(res.status).toBe(401)
    await res.body?.cancel()
  })

  it('refuses a token whose stored scopes lost mcp, or are not a list', async () => {
    const c = await connectClaude()
    for (const scopes of ['["offline_access"]', '"mcp"', 'mcp', '[]']) {
      await env.DB.prepare('UPDATE oauthAccessToken SET scopes = ?2 WHERE userId = ?1').bind(c.userId, scopes)
        .run()
      const res = await mcp(c.tokens.access_token, 'tools/list')
      expect(res.status, scopes).toBe(401)
      await res.body?.cancel()
    }
  })

  // Added after review: the body limit runs before /mcp reads the body, so a chunked body (no Content-Length)
  // is bounded too, and an oversized one takes no rate-limit slot and runs no tool.
  it('refuses a body over 256 KiB with 413, chunked or not, before it takes a slot', async () => {
    const c = await connectClaude()
    const message = JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: { name: 'get_profile', arguments: { pad: 'x'.repeat(256 * 1024) } },
    })
    const bytes = new TextEncoder().encode(message)
    const CHUNK = 16 * 1024
    const headers = {
      'content-type': 'application/json',
      accept: ACCEPT,
      'mcp-protocol-version': PROTOCOL_VERSION,
      authorization: `Bearer ${c.tokens.access_token}`,
    }
    const chunked = () =>
      new ReadableStream<Uint8Array>({
        start(controller) {
          for (let at = 0; at < bytes.length; at += CHUNK) controller.enqueue(bytes.slice(at, at + CHUNK))
          controller.close()
        },
      })
    const sized = await call('/mcp', {
      method: 'POST',
      headers: { ...headers, 'content-length': String(bytes.length) },
      body: bytes,
    })
    const streamed = await call('/mcp', { method: 'POST', headers, body: chunked() })
    for (const res of [sized, streamed]) {
      expect(res.status).toBe(413)
      expect(res.headers.get('access-control-allow-origin')).toBe('*')
      await res.body?.cancel()
    }
    const used = await env.DB.prepare(
      'SELECT (SELECT count(*) FROM mcp_calls WHERE user_id = ?1) + ' +
        '(SELECT count(*) FROM mcp_audit WHERE user_id = ?1) AS n',
    ).bind(c.userId).first()
    expect(used).toEqual({ n: 0 })
  })
})

describe('which token works where', () => {
  it("refuses Claude's token on /v1 and on Better Auth's session routes", async () => {
    const { tokens } = await connectClaude()
    for (const path of ['/v1/sync/profile', '/v1/claude/proposals', '/v1/claude/last-use']) {
      expect((await request('GET', path, { token: tokens.access_token })).status).toBe(401)
    }
    expect((await request('POST', '/v1/claude/revoke', { token: tokens.access_token })).status).toBe(401)
    expect(await (await request('GET', '/api/auth/get-session', { token: tokens.access_token })).json())
      .toBeNull()
  })

  // Added after review: /mcp takes Claude's access token only, in no other form and from no other session.
  it("refuses Claude's refresh token and the /connect browser session on /mcp", async () => {
    const { tokens } = await connectClaude()
    const { browser } = await approvedBrowser()
    const cookie = browser.cookies.get('better-auth.session_token')!
    const signed = decodeURIComponent(cookie)
    for (const token of [tokens.refresh_token, cookie, signed, signed.split('.')[0]!]) {
      const res = await mcp(token, 'tools/list')
      expect(res.status, token).toBe(401)
      await res.body?.cancel()
    }
    const res = await call('/mcp', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        accept: ACCEPT,
        cookie: `better-auth.session_token=${cookie}`,
      },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }),
    })
    expect(res.status).toBe(401)
    await res.body?.cancel()
  })
})

describe('refresh', () => {
  it('rotates: a new pair each time; an old refresh token replays its answer for 30 s only', async () => {
    const c = await connectClaude()
    const first = await refresh(c.clientId, c.tokens.refresh_token)
    expect(first.status).toBe(200)
    const next = await first.json<Tokens>()
    expect(next.refresh_token).not.toBe(c.tokens.refresh_token)
    expect(next.access_token).not.toBe(c.tokens.access_token)
    expect((await mcp(next.access_token, 'tools/list')).status).toBe(200)
    const replay = await (await refresh(c.clientId, c.tokens.refresh_token)).json<Tokens>()
    expect(replay.refresh_token).toBe(next.refresh_token)

    vi.useFakeTimers({ now: Date.now() + 31_000, toFake: ['Date'] })
    const reuse = await refresh(c.clientId, c.tokens.refresh_token)
    expect(reuse.status).toBe(400)
    expect((await reuse.json<{ error: string }>()).error).toBe('invalid_grant')
    expect((await mcp(next.access_token, 'tools/list')).status).toBe(401)
  })
})

describe('Disconnect Claude', () => {
  it('removes every grant and token: the next call is 401 and the refresh token is dead', async () => {
    const c = await connectClaude()
    expect((await mcp(c.tokens.access_token, 'tools/list')).status).toBe(200)
    const res = await request('POST', '/v1/claude/revoke', { token: c.appToken })
    expect(await res.json()).toEqual({ revoked: 1 })
    expect((await mcp(c.tokens.access_token, 'tools/list')).status).toBe(401)
    const again = await refresh(c.clientId, c.tokens.refresh_token)
    expect(again.status).toBe(400)
    for (const table of ['oauthAccessToken', 'oauthRefreshToken', 'oauthConsent']) {
      const row = await env.DB.prepare(`SELECT count(*) AS n FROM "${table}" WHERE userId = ?1`).bind(
        c.userId,
      ).first()
      expect(row, table).toEqual({ n: 0 })
    }
    const sessions = await env.DB.prepare('SELECT count(*) AS n FROM session WHERE userId = ?1').bind(
      c.userId,
    ).first()
    expect(sessions).toEqual({ n: 1 })
    expect(await (await request('POST', '/v1/claude/revoke', { token: c.appToken })).json()).toEqual({
      revoked: 0,
    })
  })

  // Added after review: an approved browser whose code Claude hasn't swapped yet still holds its /connect
  // session. Disconnect Claude ends it by its mark (session.claudeConnect), whatever its request recorded,
  // and the code it bought can't be swapped after.
  it("ends an approved browser's session and its unredeemed code", async () => {
    const { appToken, userId, flow, claudeCode } = await approvedBrowser()
    await env.DB.prepare('UPDATE connect_requests SET session_id = NULL WHERE user_id = ?1').bind(userId)
      .run()
    const browserSessions = () =>
      env.DB.prepare('SELECT count(*) AS n FROM session WHERE userId = ?1 AND claudeConnect = 1').bind(userId)
        .first()
    const codes = () =>
      env.DB.prepare(
        'SELECT count(*) AS n FROM verification ' +
          "WHERE json_valid(value) AND json_extract(value, '$.userId') = ?1",
      ).bind(userId).first()
    expect([await browserSessions(), await codes()]).toEqual([{ n: 1 }, { n: 1 }])
    expect(await (await request('POST', '/v1/claude/revoke', { token: appToken })).json()).toEqual({
      revoked: 1,
    })
    expect([await browserSessions(), await codes()]).toEqual([{ n: 0 }, { n: 0 }])
    expect((await exchangeCode(flow, claudeCode)).status).toBe(400)
    expect((await request('GET', '/v1/claude/last-use', { token: appToken })).status).toBe(200)
  })

  // Added after review: Better Auth marks a refresh token rotated, then inserts the new pair in another
  // statement, so a Disconnect landing between the two leaves a pair it never saw. /mcp also needs the
  // consent Disconnect deletes, so that pair is refused.
  it('refuses a token whose consent is gone, and the pair a refresh mints after', async () => {
    const c = await connectClaude()
    expect((await mcp(c.tokens.access_token, 'tools/list')).status).toBe(200)
    await env.DB.prepare('DELETE FROM oauthConsent WHERE userId = ?1').bind(c.userId).run()
    expect((await mcp(c.tokens.access_token, 'tools/list')).status).toBe(401)
    // Better Auth's refresh doesn't look at consents: the pair it mints is the one a racing refresh leaves.
    const late = await refresh(c.clientId, c.tokens.refresh_token)
    expect(late.status).toBe(200)
    expect((await mcp((await late.json<Tokens>()).access_token, 'tools/list')).status).toBe(401)
  })

  // Added after review: Claude reuses its client id, so approving it again recreates the consent. A pair left
  // by that race must not come back to life with it.
  it('keeps a pair that outlived its consent dead when the owner approves the client again', async () => {
    const c = await connectClaude()
    await env.DB.prepare('DELETE FROM oauthConsent WHERE userId = ?1').bind(c.userId).run()
    const flow = await startFlow(c.clientId)
    const browser = new Browser()
    const { code } = await openConnect(browser, flow)
    expect((await decideCode(c.appToken, code, 'approve')).status).toBe(200)
    const again = await (await exchangeCode(flow, await finishInBrowser(browser, flow))).json<Tokens>()
    expect((await mcp(again.access_token, 'tools/list')).status).toBe(200)
    expect((await mcp(c.tokens.access_token, 'tools/list')).status).toBe(401)
    expect((await refresh(c.clientId, c.tokens.refresh_token)).status).toBe(400)
  })

  it("needs its own account's consent: another account's for the same client doesn't do", async () => {
    const mine = await connectClaude()
    const other = await signUp()
    await env.DB.prepare(
      'INSERT INTO oauthConsent (id, clientId, userId, scopes, createdAt, updatedAt) ' +
        `VALUES (?1, ?2, ?3, '["mcp"]', '2026-11-08T00:00:00.000Z', '2026-11-08T00:00:00.000Z')`,
    ).bind(crypto.randomUUID(), mine.clientId, other.userId).run()
    expect((await mcp(mine.tokens.access_token, 'tools/list')).status).toBe(200)
    await env.DB.prepare('DELETE FROM oauthConsent WHERE userId = ?1').bind(mine.userId).run()
    expect((await mcp(mine.tokens.access_token, 'tools/list')).status).toBe(401)
  })

  it("leaves another account's Claude connected", async () => {
    const mine = await connectClaude()
    const theirs = await connectClaude()
    await request('POST', '/v1/claude/revoke', { token: mine.appToken })
    expect((await mcp(theirs.tokens.access_token, 'tools/list')).status).toBe(200)
  })

  it("goes with the account: deleting it ends Claude's access and its grants", async () => {
    const c = await connectClaude()
    expect((await request('DELETE', '/v1/account', { token: c.appToken })).status).toBe(204)
    expect((await mcp(c.tokens.access_token, 'tools/list')).status).toBe(401)
    const left = await env.DB.prepare(
      'SELECT (SELECT count(*) FROM oauthAccessToken WHERE userId = ?1) + ' +
        '(SELECT count(*) FROM oauthRefreshToken WHERE userId = ?1) + ' +
        '(SELECT count(*) FROM oauthConsent WHERE userId = ?1) + ' +
        '(SELECT count(*) FROM connect_requests WHERE user_id = ?1) AS n',
    ).bind(c.userId).first()
    expect(left).toEqual({ n: 0 })
  })

  it('works for an account that never connected Claude', async () => {
    const { token } = await signUp()
    expect(await (await request('POST', '/v1/claude/revoke', { token })).json()).toEqual({ revoked: 0 })
  })
})
