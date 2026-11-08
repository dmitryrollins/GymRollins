// Approve a connection (spec section 4, "Claude's connection", steps 4–5): the code typed in the app, then
// the same browser signed in and sent back to Claude with a code that buys tokens.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { CONNECT_SESSION_SECONDS } from '../src/auth/connect-plugin.ts'
import { WRONG_CODES_ALLOWED } from '../src/claude/connect-requests.ts'
import {
  Browser,
  call,
  CLAUDE_AI,
  decideCode,
  exchangeCode,
  finishInBrowser,
  metaRefresh,
  openConnect,
  registerClient,
  startFlow,
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
