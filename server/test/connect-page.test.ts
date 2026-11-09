// /connect, Claude's sign-in page (spec sections 4 and 5): the code, the browser's cookie, the page's own
// security.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { newCode, normalizeCode, sha256Hex } from '../src/claude/connect-code.ts'
import { SIGN_INS_PER_CLIENT } from '../src/claude/connect-requests.ts'
import {
  Browser,
  call,
  decideCode,
  finishInBrowser,
  metaRefresh,
  openConnect,
  registerClient,
  shownCode,
  startFlow,
} from './claude.ts'
import { signUp } from './helpers.ts'

describe('the approval code', () => {
  it('is 8 characters of the 32-letter alphabet', () => {
    const codes = Array.from({ length: 200 }, () => newCode())
    expect(codes.every((c) => /^[0-9A-HJKMNP-TV-Z]{8}$/.test(c))).toBe(true)
    expect(new Set(codes.join('')).size).toBeGreaterThan(28)
  })

  it('reads what the owner types: any case, a dash or spaces, O for 0 and I or L for 1', () => {
    expect(normalizeCode('abcd-efgh')).toBe('ABCDEFGH')
    expect(normalizeCode(' 7k2m 9pqr ')).toBe('7K2M9PQR')
    expect(normalizeCode('O0IL-1234')).toBe('00111234')
    expect(normalizeCode('ABCD-EFG')).toBeNull()
    expect(normalizeCode('ABCD-EFGU')).toBeNull()
  })
})

describe('/connect', () => {
  it('shows the code, who is asking and the countdown, and checks again every 2 seconds', async () => {
    const flow = await startFlow(await registerClient())
    const { res, html, code } = await openConnect(new Browser(), flow)
    expect(res.status).toBe(200)
    expect(code).toMatch(/^[0-9A-Z]{4}-[0-9A-Z]{4}$/)
    expect(html).toContain('Open GymRollins › Settings › AI agents › Approve a connection and type this code.')
    expect(html).toContain(
      '<strong>Claude Code</strong> is asking, and returns to <strong>127.0.0.1:33418</strong>',
    )
    expect(html).toMatch(/Expires in (10:00|9:5\d)/)
    expect(html).toContain('<title>Connect Claude Code to GymRollins</title>')
    expect(html).toContain('<h1>Connect Claude Code to GymRollins</h1>')
    // The page checks by script without reloading (owner, 2026-11-09: a reload every 2 seconds kept the code from
    // being copied); a browser without script still reloads.
    expect(html).toContain('<noscript><meta http-equiv="refresh" content="2"></noscript>')
    expect(metaRefresh(html)).toEqual([2, null])
    expect(html).toContain(`<button id="copy" type="button" data-code="${code}">Copy code</button>`)
  })

  it('serves plain HTML under a strict Content-Security-Policy, never cached', async () => {
    const { res, html } = await openConnect(new Browser(), await startFlow(await registerClient()))
    const csp = res.headers.get('content-security-policy')!
    const nonce = /style-src 'nonce-([0-9a-f]{32})'/.exec(csp)![1]!
    expect(csp).toBe(
      `default-src 'none'; style-src 'nonce-${nonce}'; script-src 'nonce-${nonce}'; connect-src 'self'; ` +
        "base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    )
    expect(html.match(/<script/g)).toHaveLength(1)
    expect(html).toContain(`<script nonce="${nonce}">`)
    expect(html).not.toMatch(/<img|<link|https?:\/\/(?!127\.0\.0\.1)/)
    expect(res.headers.get('cache-control')).toBe('no-store')
    expect(res.headers.get('x-frame-options')).toBe('DENY')
    expect(res.headers.get('referrer-policy')).toBe('no-referrer')
  })

  it("sets the browser's secret as an HttpOnly cookie, and stores only its hash", async () => {
    const browser = new Browser()
    const { res, code } = await openConnect(browser, await startFlow(await registerClient()))
    expect(res.headers.get('set-cookie')).toMatch(
      /^gr_connect=[0-9a-f]{64}; Path=\/connect; Max-Age=600; HttpOnly; SameSite=Lax$/,
    )
    const secret = browser.cookies.get('gr_connect')!
    const row = await env.DB.prepare('SELECT browser_hash, status FROM connect_requests WHERE code = ?1')
      .bind(code.replace('-', '')).first<{ browser_hash: string; status: string }>()
    expect(row).toEqual({ browser_hash: await sha256Hex(secret), status: 'waiting' })
  })

  it('shows the same code to the same browser, and another one to another browser', async () => {
    const flow = await startFlow(await registerClient())
    const browser = new Browser()
    const first = await openConnect(browser, flow)
    expect((await openConnect(browser, flow)).code).toBe(first.code)
    expect((await openConnect(new Browser(), flow)).code).not.toBe(first.code)
  })

  it('starts a new code when the same browser comes back with a new sign-in', async () => {
    const clientId = await registerClient()
    const browser = new Browser()
    const first = await openConnect(browser, await startFlow(clientId))
    expect((await openConnect(browser, await startFlow(clientId))).code).not.toBe(first.code)
  })

  it('refuses a changed or unsigned request', async () => {
    const flow = await startFlow(await registerClient())
    const changed = flow.connectUrl.replace(/state=[^&]+/, 'state=other')
    expect((await call(changed)).status).toBe(400)
    expect((await call('/connect')).status).toBe(400)
    expect(shownCode(await (await call(changed)).text())).toBeNull()
  })

  it('says a code has expired after 10 minutes', async () => {
    const flow = await startFlow(await registerClient())
    const browser = new Browser()
    const { code } = await openConnect(browser, flow)
    await env.DB.prepare(
      "UPDATE connect_requests SET expires_at = '2026-01-01T00:00:00.000000Z' WHERE code = ?1",
    )
      .bind(code.replace('-', '')).run()
    const res = await browser.get(flow.connectUrl)
    expect(res.status).toBe(410)
    expect(await res.text()).toContain('This code has expired. Start again from your agent.')
  })

  it("escapes the client's name", async () => {
    const flow = await startFlow(await registerClient(undefined, '<img src=x onerror=alert(1)>'))
    const { html } = await openConnect(new Browser(), flow)
    expect(html).toContain('&lt;img src=x onerror=alert(1)&gt;')
    expect(html).not.toContain('<img')
  })

  it(`lets one client start ${SIGN_INS_PER_CLIENT} sign-ins per 10 minutes`, async () => {
    const flow = await startFlow(await registerClient())
    for (let i = 0; i < SIGN_INS_PER_CLIENT; i++) await openConnect(new Browser(), flow)
    const res = await new Browser().get(flow.connectUrl)
    expect(res.status).toBe(429)
    expect(await res.text()).toContain('Too many sign-ins from this client.')
    expect((await openConnect(new Browser(), await startFlow(await registerClient()))).code).toBeTruthy()
  })
})

// The code page's check (owner, 2026-11-09): read-only, so checking never uses the approval the page itself needs.
describe('/connect/status', () => {
  const statusUrl = (connectUrl: string) => connectUrl.replace('/connect?', '/connect/status?')

  it("answers this browser's request: waiting, then approved, and the page still finishes afterwards", async () => {
    const { token } = await signUp()
    const flow = await startFlow(await registerClient())
    const browser = new Browser()
    const { code } = await openConnect(browser, flow)
    const first = await browser.get(statusUrl(flow.connectUrl))
    expect(first.status).toBe(200)
    expect(first.headers.get('cache-control')).toBe('no-store')
    expect(await first.json()).toEqual({ status: 'waiting' })
    expect((await decideCode(token, code, 'approve')).status).toBe(200)
    expect(await (await browser.get(statusUrl(flow.connectUrl))).json()).toEqual({ status: 'approved' })
    expect(await (await browser.get(statusUrl(flow.connectUrl))).json()).toEqual({ status: 'approved' })
    expect(await finishInBrowser(browser, flow)).toBeTruthy()
  })

  it('says expired once the code has expired', async () => {
    const flow = await startFlow(await registerClient())
    const browser = new Browser()
    const { code } = await openConnect(browser, flow)
    await env.DB.prepare(
      "UPDATE connect_requests SET expires_at = '2026-01-01T00:00:00.000000Z' WHERE code = ?1",
    ).bind(code.replace('-', '')).run()
    expect(await (await browser.get(statusUrl(flow.connectUrl))).json()).toEqual({ status: 'expired' })
  })

  it("knows nothing for a browser without the page's cookie, or a link that isn't signed", async () => {
    const flow = await startFlow(await registerClient())
    await openConnect(new Browser(), flow)
    const stranger = await new Browser().get(statusUrl(flow.connectUrl))
    expect(stranger.status).toBe(404)
    expect(await stranger.json()).toEqual({ status: 'unknown' })
    expect((await new Browser().get('/connect/status?client_id=x')).status).toBe(400)
  })
})
