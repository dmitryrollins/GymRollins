// Approve a connection (spec section 4, "Claude's connection", steps 4–5): the code typed in the app, then
// the same browser signed in and sent back to Claude with a code that buys tokens.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { CONNECT_SESSION_SECONDS } from '../src/auth/connect-plugin.ts'
import { ACCESS_TOKEN_PREFIX, hashToken } from '../src/auth/oauth.ts'
import { WRONG_CODES_ALLOWED } from '../src/claude/connect-requests.ts'
import {
  Browser,
  call,
  CLAUDE_AI,
  connectClaude,
  decideCode,
  exchangeCode,
  finishInBrowser,
  LOOPBACK,
  metaRefresh,
  openConnect,
  registerClient,
  RESOURCE,
  startFlow,
  tokenRequest,
  type Tokens,
} from './claude.ts'
import { request, signUp } from './helpers.ts'

const preview = (token: string, code: string) => request('GET', `/v1/claude/connect/${code}`, { token })

async function waiting(redirectUri?: string) {
  const { token } = await signUp()
  const flow = await startFlow(await registerClient(redirectUri), redirectUri)
  const browser = new Browser()
  const { code } = await openConnect(browser, flow)
  return { token, flow, browser, code }
}

describe('the app sees the request', () => {
  it("by its code: the client's name and where it returns, flagged when that isn't Claude", async () => {
    const { token, code } = await waiting()
    const res = await preview(token, code)
    expect(res.status).toBe(200)
    const body = await res.json<Record<string, unknown>>()
    expect(body).toMatchObject({
      code,
      client_name: 'Claude Code',
      redirect_host: '127.0.0.1:33418',
      known_host: false,
    })
    expect(body.expires_at).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/)
    const claude = await waiting(CLAUDE_AI)
    expect(await (await preview(claude.token, claude.code)).json()).toMatchObject({
      redirect_host: 'claude.ai',
      known_host: true,
    })
  })

  // Added after review: when and from where the page was opened, so the owner can tell a code that isn't on
  // their own screen. Cloudflare sets request.cf (country, city); locally there is none, and the test's
  // browser sends no User-Agent.
  it('with when it was opened, and no place or browser when none was sent', async () => {
    const { token, code } = await waiting()
    const body = await (await preview(token, code)).json<Record<string, unknown>>()
    expect(body).toMatchObject({ country: null, city: null, user_agent: null })
    expect(body.opened_at).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/)
    const opened = Date.parse(body.opened_at as string)
    expect(Math.abs(opened - Date.now())).toBeLessThan(5000)
    expect(Date.parse(body.expires_at as string) - opened).toBe(10 * 60 * 1000)
  })

  it("with the opener's country, city and browser as Cloudflare's request.cf said, cleaned and cut short", async () => {
    const { token } = await signUp()
    const flow = await startFlow(await registerClient())
    const safari =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) ' +
      'Version/26.1 Safari/605.1.15'
    const { code } = await openConnect(new Browser(), flow, { 'user-agent': safari }, {
      country: 'CA',
      city: 'Toronto',
    })
    expect(await (await preview(token, code)).json()).toMatchObject({
      country: 'CA',
      city: 'Toronto',
      user_agent: safari,
    })
    const long = await openConnect(new Browser(), flow, { 'user-agent': 'x'.repeat(300) }, {
      country: 'C\u0001A',
      city: `T\u0085${'o'.repeat(100)}`,
    })
    expect(await (await preview(token, long.code)).json()).toMatchObject({
      country: 'CA',
      city: `T${'o'.repeat(63)}`,
      user_agent: 'x'.repeat(256),
    })
    const blank = await openConnect(new Browser(), flow, { 'user-agent': ' ' }, { country: '\u0001' })
    expect(await (await preview(token, blank.code)).json()).toMatchObject({
      country: null,
      city: null,
      user_agent: null,
    })
  })

  it('never from cf-ipcountry or cf-ipcity, which a client can send itself', async () => {
    const { token } = await signUp()
    const flow = await startFlow(await registerClient())
    const forged = { 'cf-ipcountry': 'XX', 'cf-ipcity': 'Nowhere' }
    const bare = await openConnect(new Browser(), flow, forged)
    expect(await (await preview(token, bare.code)).json()).toMatchObject({ country: null, city: null })
    const real = await openConnect(new Browser(), flow, forged, { country: 'CA', city: 'Toronto' })
    expect(await (await preview(token, real.code)).json()).toMatchObject({ country: 'CA', city: 'Toronto' })
  })

  it('as typed: lower case, without the dash', async () => {
    const { token, code } = await waiting()
    expect((await preview(token, code.toLowerCase().replace('-', ''))).status).toBe(200)
  })

  it('only with an app session', async () => {
    const { code } = await waiting()
    expect((await preview('', code)).status).toBe(401)
  })
})

describe('approve', () => {
  it('signs the browser in for 10 minutes, records consent, and Claude gets tokens', async () => {
    const { token, flow, browser, code } = await waiting()
    expect((await decideCode(token, code, 'approve')).status).toBe(200)
    const page = await browser.get(flow.connectUrl)
    const html = await page.text()
    expect(html).toContain('Approved, returning to Claude…')
    const [seconds, url] = metaRefresh(html)!
    expect(seconds).toBe(0)
    const reentry = new URLSearchParams(url!.slice('/api/auth/oauth2/authorize?'.length))
    expect(reentry.get('prompt')).toBeNull()
    expect(reentry.get('scope')).toBe('mcp offline_access')
    expect(browser.cookies.has('better-auth.session_token')).toBe(true)
    expect(browser.cookies.has('gr_connect')).toBe(false)

    const userId =
      (await (await request('GET', '/api/auth/get-session', { token })).json<{ user: { id: string } }>()).user
        .id
    const session = await env.DB.prepare(
      'SELECT s.expiresAt FROM session s JOIN connect_requests r ON r.session_id = s.id WHERE r.user_id = ?1',
    ).bind(userId).first<{ expiresAt: string }>()
    expect(Math.abs(Date.parse(session!.expiresAt) - Date.now() - CONNECT_SESSION_SECONDS * 1000))
      .toBeLessThan(5000)
    const consent = await env.DB.prepare(
      'SELECT scopes, resources FROM oauthConsent WHERE userId = ?1 AND clientId = ?2',
    )
      .bind(userId, flow.clientId).first()
    expect(consent).toEqual({ scopes: '["mcp","offline_access"]', resources: '["http://localhost/mcp"]' })

    const back = await browser.get(url!)
    const location = new URL(back.headers.get('location')!)
    expect(back.status).toBe(302)
    expect(`${location.origin}${location.pathname}`).toBe(flow.redirectUri)
    expect(location.searchParams.get('state')).toBe(flow.state)
    expect(location.searchParams.get('iss')).toBe('http://localhost/api/auth')
    const res = await exchangeCode(flow, location.searchParams.get('code')!)
    expect(res.status).toBe(200)
    const tokens = await res.json<Tokens>()
    expect(tokens.access_token).toMatch(/^gra_[A-Za-z]{32}$/)
    expect(tokens.refresh_token).toMatch(/^grr_[A-Za-z]{32}$/)
    expect(tokens.scope).toBe('mcp offline_access')
    expect(tokens.expires_in).toBe(3600)
  })

  it('works once: a second decision finds nothing, and the page starts over with a new code', async () => {
    const { token, flow, browser, code } = await waiting()
    await decideCode(token, code, 'approve')
    expect((await decideCode(token, code, 'deny')).status).toBe(404)
    await finishInBrowser(browser, flow)
    expect((await openConnect(browser, flow)).code).not.toBe(code)
    expect((await preview(token, code)).status).toBe(404)
  })

  it('continues only in the browser that showed the code', async () => {
    const { token, flow, browser, code } = await waiting()
    await decideCode(token, code, 'approve')
    const other = new Browser()
    const { code: otherCode } = await openConnect(other, flow)
    expect(otherCode).not.toBe(code)
    expect(other.cookies.has('better-auth.session_token')).toBe(false)
    expect(await finishInBrowser(browser, flow)).toBeTruthy()
  })

  it("gives the browser a session that /v1 never takes: the app's routes read only the bearer", async () => {
    const { token, flow, browser, code } = await waiting()
    await decideCode(token, code, 'approve')
    const [, url] = metaRefresh(await (await browser.get(flow.connectUrl)).text())!
    expect(browser.cookies.has('better-auth.session_token')).toBe(true)
    const cookie = `better-auth.session_token=${browser.cookies.get('better-auth.session_token')}`
    for (const path of ['/v1/sync/routines', '/v1/claude/connect/ZZZZ-ZZZZ']) {
      expect((await browser.get(path)).status).toBe(401)
      const beside = await call(path, { headers: { cookie, authorization: 'Bearer forged.signature' } })
      expect(beside.status).toBe(401)
    }
    // The same cookie still does what it is for: the authorize step takes it and returns to Claude.
    const back = await browser.get(url!)
    expect(back.status).toBe(302)
    expect(new URL(back.headers.get('location')!).searchParams.get('code')).toBeTruthy()
  })

  it('refuses the wrong PKCE verifier and a second use of the code', async () => {
    const { token, flow, browser, code } = await waiting()
    await decideCode(token, code, 'approve')
    const claudeCode = await finishInBrowser(browser, flow)
    expect((await exchangeCode(flow, claudeCode, 'x'.repeat(43))).status).toBe(400)
    const again = await exchangeCode(flow, claudeCode)
    expect(again.status).toBe(400)
    expect((await again.json<{ error: string }>()).error).toBe('invalid_grant')
  })
})

describe('deny', () => {
  it('tells the page, then sends Claude access_denied with its state, and signs nobody in', async () => {
    const { token, flow, browser, code } = await waiting()
    expect(await (await decideCode(token, code, 'deny')).json()).toEqual({ status: 'denied' })
    const html = await (await browser.get(flow.connectUrl)).text()
    expect(html).toContain('Denied. Claude was not given access.')
    const [seconds, url] = metaRefresh(html)!
    expect(seconds).toBe(3)
    const back = new URL(url!)
    expect(`${back.origin}${back.pathname}`).toBe(flow.redirectUri)
    expect(back.searchParams.get('error')).toBe('access_denied')
    expect(back.searchParams.get('state')).toBe(flow.state)
    expect(browser.cookies.has('better-auth.session_token')).toBe(false)
  })
})

describe('codes', () => {
  it('expire after 10 minutes', async () => {
    const { token, code } = await waiting()
    await env.DB.prepare(
      "UPDATE connect_requests SET expires_at = '2026-01-01T00:00:00.000000Z' WHERE code = ?1",
    )
      .bind(code.replace('-', '')).run()
    expect((await preview(token, code)).status).toBe(404)
    expect((await decideCode(token, code, 'approve')).status).toBe(404)
  })

  it(`allow ${WRONG_CODES_ALLOWED} wrong ones per account per 10 minutes, then no tries at all`, async () => {
    const { token, code } = await waiting()
    for (let i = 0; i < WRONG_CODES_ALLOWED - 1; i++) {
      expect((await preview(token, 'ZZZZ-ZZZZ')).status).toBe(404)
    }
    expect((await preview(token, code)).status).toBe(200)
    expect((await preview(token, 'not a code')).status).toBe(404)
    const refused = await preview(token, code)
    expect(refused.status).toBe(429)
    expect(await refused.json()).toEqual({
      error: { code: 'too_many_attempts', message: 'Too many wrong codes. Try again in 10 minutes.' },
    })
    expect((await decideCode(token, code, 'approve')).status).toBe(429)
    const someoneElse = await signUp()
    expect((await preview(someoneElse.token, code)).status).toBe(200)
  })

  it('count concurrent guesses too', async () => {
    const { token } = await signUp()
    const statuses = await Promise.all(
      Array.from({ length: 12 }, () => preview(token, 'ZZZZ-ZZZZ').then((r) => r.status)),
    )
    expect(statuses.filter((s) => s === 404)).toHaveLength(WRONG_CODES_ALLOWED)
    expect(statuses.filter((s) => s === 429)).toHaveLength(12 - WRONG_CODES_ALLOWED)
  })

  it('need a decision of approve or deny, which is not a wrong code', async () => {
    const { token, code } = await waiting()
    for (const body of [{}, { decision: 'yes' }]) {
      expect((await request('POST', `/v1/claude/connect/${code}`, { token, body })).status).toBe(400)
    }
    expect((await preview(token, code)).status).toBe(200)
  })
})

// Added after review: the browser's session and Claude's tokens are for the authorize step and /mcp only.
// Before, the browser's cookie value as a bearer (or the raw token get-session gave for the cookie) worked on
// /v1 as the owner, and any use as a bearer extended the 10-minute session to 60 days.
describe("Claude's side never reaches the app (added after review)", () => {
  const SESSION_COOKIE = 'better-auth.session_token'
  const SIGNED_OUT = { error: { code: 'signed_out', message: 'Sign in required.' } }
  const V1: [string, string][] = [
    ['GET', '/v1/sync/routines'],
    ['GET', '/v1/claude/connect/ZZZZ-ZZZZ'],
    ['DELETE', '/v1/account'],
  ]

  /** After an approval: the page signed the browser in; `reentry` is the authorize step it goes to next. */
  async function approved() {
    const { token, flow, browser, code } = await waiting()
    await decideCode(token, code, 'approve')
    const [, reentry] = metaRefresh(await (await browser.get(flow.connectUrl)).text())!
    const cookieValue = browser.cookies.get(SESSION_COOKIE)!
    const signed = decodeURIComponent(cookieValue)
    return { token, flow, browser, reentry: reentry!, cookieValue, signed, raw: signed.split('.')[0]! }
  }

  /** Claude's code from the authorize step the approved browser re-enters. */
  async function claudeCode(s: { browser: Browser; reentry: string }): Promise<string> {
    const back = await s.browser.get(s.reentry)
    expect(back.status).toBe(302)
    return new URL(back.headers.get('location')!).searchParams.get('code')!
  }

  /** Every form of the browser's session token a bearer could carry: as the cookie has it, decoded, raw. */
  const bearers = (s: { cookieValue: string; signed: string; raw: string }) => [
    s.cookieValue,
    s.signed,
    s.raw,
  ]

  const cookieHeader = (browser: Browser) => [...browser.cookies].map(([k, v]) => `${k}=${v}`).join('; ')

  const sessionRow = (raw: string) =>
    env.DB.prepare('SELECT id, expiresAt, claudeConnect FROM session WHERE token = ?1').bind(raw).first<
      { id: string; expiresAt: string; claudeConnect: number | null }
    >()

  async function expectRefusedOnV1(bearer: string) {
    for (const [method, path] of V1) {
      const res = await request(method, path, { token: bearer })
      expect(res.status, `${method} ${path} with ${bearer}`).toBe(401)
      expect(await res.json()).toEqual(SIGNED_OUT)
    }
  }

  it("marks the browser session as /connect's, and no other", async () => {
    const { token, raw } = await approved()
    expect((await sessionRow(raw))?.claudeConnect).toBe(1)
    expect((await sessionRow(token))?.claudeConnect).toBe(0)
  })

  it("refuses the browser's session token on /v1 in every form, and never extends it", async () => {
    const s = await approved()
    const before = await sessionRow(s.raw)
    for (const bearer of bearers(s)) await expectRefusedOnV1(bearer)
    expect(await sessionRow(s.raw)).toEqual(before)
    expect((await request('GET', '/v1/sync/routines', { token: s.token })).status).toBe(200)
  })

  it('gives the browser nothing on get-session: no cookies there, its token is no app session', async () => {
    const s = await approved()
    const before = await sessionRow(s.raw)
    const byCookie = await call('/api/auth/get-session', { headers: { cookie: cookieHeader(s.browser) } })
    expect(byCookie.status).toBe(200)
    expect(await byCookie.json()).toBeNull()
    for (const bearer of bearers(s)) {
      const res = await request('GET', '/api/auth/get-session', { token: bearer })
      expect(res.status, bearer).toBe(200)
      expect(await res.json(), bearer).toBeNull()
      expect(res.headers.get('set-auth-token')).toBeNull()
      expect(res.headers.get('set-cookie')).toBeNull()
    }
    expect(await sessionRow(s.raw)).toEqual(before)
  })

  it('never extends the browser session on the authorize step, even without dont_remember', async () => {
    const s = await approved()
    const before = await sessionRow(s.raw)
    await call(s.reentry, { headers: { accept: 'text/html', cookie: `${SESSION_COOKIE}=${s.cookieValue}` } })
    await call(s.reentry, { headers: { accept: 'text/html', authorization: `Bearer ${s.signed}` } })
    expect((await sessionRow(s.raw))?.expiresAt).toBe(before!.expiresAt)
  })

  it("keeps the app's bearer session working, with the browser's cookie sent beside it", async () => {
    const s = await approved()
    const headers = { authorization: `Bearer ${s.token}`, cookie: cookieHeader(s.browser) }
    const session = await (await call('/api/auth/get-session', { headers })).json<{ user: { id: string } }>()
    const own = await (await request('GET', '/api/auth/get-session', { token: s.token })).json<
      { user: { id: string } }
    >()
    expect(session.user.id).toBe(own.user.id)
    expect((await call('/v1/sync/routines', { headers })).status).toBe(200)
  })

  it('completes the OAuth flow; the code exchange ends the browser session, not the tokens', async () => {
    const s = await approved()
    const res = await exchangeCode(s.flow, await claudeCode(s))
    expect(res.status).toBe(200)
    const tokens = await res.json<Tokens>()
    expect(await sessionRow(s.raw)).toBeNull()
    const stored = await env.DB.prepare('SELECT sessionId, revoked FROM oauthAccessToken WHERE token = ?1')
      .bind(await hashToken(tokens.access_token.slice(ACCESS_TOKEN_PREFIX.length))).first()
    expect(stored).toEqual({ sessionId: null, revoked: null })
    // No second code without a new approval: authorize sends the browser back to /connect.
    const again = await s.browser.get(s.reentry)
    expect(again.status).toBe(302)
    expect(again.headers.get('location')).toMatch(/^\/connect\?/)
    const refreshed = await tokenRequest({
      grant_type: 'refresh_token',
      refresh_token: tokens.refresh_token,
      client_id: s.flow.clientId,
      resource: RESOURCE,
    })
    expect(refreshed.status).toBe(200)
  })

  it("refuses Claude's access and refresh tokens on /v1 and get-session", async () => {
    const s = await approved()
    const tokens = await (await exchangeCode(s.flow, await claudeCode(s))).json<Tokens>()
    for (const token of [tokens.access_token, tokens.refresh_token]) {
      await expectRefusedOnV1(token)
      expect(await (await request('GET', '/api/auth/get-session', { token })).json()).toBeNull()
    }
    expect((await request('GET', '/v1/sync/routines', { token: s.token })).status).toBe(200)
  })
})

// Added after review: the authorize step takes the /connect browser session only. Before, the bearer plugin
// turned `Authorization: Bearer <app session>` into a session there, so the app's token alone got Claude a
// code (and then tokens) for any client the owner had approved before, with no code typed.
describe('the authorize step takes only the /connect browser session (added after review)', () => {
  const SESSION_COOKIE = 'better-auth.session_token'

  /** Authorize as the re-entry asks it (no prompt) for a client the owner already approved. */
  function authorizeAgain(clientId: string, headers: Record<string, string>): Promise<Response> {
    const query = new URLSearchParams({
      response_type: 'code',
      client_id: clientId,
      redirect_uri: LOOPBACK,
      state: 'again',
      code_challenge: 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      code_challenge_method: 'S256',
      scope: 'mcp offline_access',
      resource: RESOURCE,
    })
    return call(`/api/auth/oauth2/authorize?${query}`, { headers: { accept: 'text/html', ...headers } })
  }

  const codesFor = (userId: string) =>
    env.DB.prepare(
      "SELECT count(*) AS n FROM verification WHERE json_valid(value) AND json_extract(value, '$.type') = " +
        "'authorization_code' AND json_extract(value, '$.userId') = ?1",
    ).bind(userId).first()

  it("sends the app's session to /connect, as a bearer or a cookie, for an approved client", async () => {
    const c = await connectClaude()
    const appCookie = `${SESSION_COOKIE}=${c.appCookie}`
    const sessions: Record<string, string>[] = [
      { authorization: `Bearer ${c.appToken}` },
      { authorization: `Bearer ${decodeURIComponent(c.appCookie)}` },
      { cookie: appCookie },
      { authorization: `Bearer ${c.appToken}`, cookie: appCookie },
    ]
    for (const headers of sessions) {
      const res = await authorizeAgain(c.clientId, headers)
      expect(res.status, JSON.stringify(headers)).toBe(302)
      expect(res.headers.get('location'), JSON.stringify(headers)).toMatch(/^\/connect\?/)
    }
    expect(await codesFor(c.userId)).toEqual({ n: 0 })
  })

  it("still returns the approved browser to Claude, with the app's bearer beside its cookie", async () => {
    const { token } = await signUp()
    const flow = await startFlow(await registerClient())
    const browser = new Browser()
    const { code } = await openConnect(browser, flow)
    await decideCode(token, code, 'approve')
    const [, reentry] = metaRefresh(await (await browser.get(flow.connectUrl)).text())!
    const cookie = `${SESSION_COOKIE}=${browser.cookies.get(SESSION_COOKIE)}`
    const back = await call(reentry!, {
      headers: { accept: 'text/html', cookie, authorization: `Bearer ${token}` },
    })
    expect(back.status).toBe(302)
    const location = new URL(back.headers.get('location')!)
    expect(`${location.origin}${location.pathname}`).toBe(flow.redirectUri)
    expect((await exchangeCode(flow, location.searchParams.get('code')!)).status).toBe(200)
  })
})
