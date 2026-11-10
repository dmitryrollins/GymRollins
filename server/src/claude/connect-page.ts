// GET /connect: an agent's sign-in page (spec sections 4 and 5). Better Auth's authorize step sends the browser
// here with its signed query. The page shows an approval code with a Copy button, and its one script asks
// GET /connect/status every 2 seconds, reloading only once the owner has decided (owner, 2026-11-09: a reload every
// 2 seconds kept the code from being copied); without script, a meta refresh does it. Once the owner approves the
// code in the app, the same browser
// (its cookie) gets a 10-minute Better Auth session for the owner, Claude's consent is recorded, and the
// browser re-enters the authorize step, which redirects to Claude with a code. A denial sends Claude
// `access_denied`.
import { verifyOAuthQueryParams } from '@better-auth/oauth-provider'
import type { Context } from 'hono'
import { createAuth } from '../auth/auth.ts'
import { CONNECT_PATH, issuer, MCP_SCOPES } from '../auth/oauth.ts'
import type { AppEnv, Env } from '../env.ts'
import { displayCode, newBrowserSecret, sha256Hex } from './connect-code.ts'
import {
  CONNECT_MINUTES,
  type ConnectRequest,
  createRequest,
  type Opener,
  OPENER_LIMITS,
  openerText,
  recordSession,
  requestForBrowser,
  useDecision,
} from './connect-requests.ts'

const COOKIE = 'gr_connect'
/**
 * The parameters Better Auth adds when it signs the authorize query; they aren't part of the request itself.
 */
const SIGNATURE_PARAMS = ['sig', 'exp', 'ba_iat', 'ba_pl', 'ba_param']
const POLL_SECONDS = 2
const DENIED_SECONDS = 3
const EXPIRED = 'This code has expired. Start again from your agent.'

export async function connectPage(c: Context<AppEnv>): Promise<Response> {
  const signed = new URL(c.req.url).search.slice(1)
  if (signed === '' || !(await verifyOAuthQueryParams(signed, c.env.BETTER_AUTH_SECRET))) {
    return message(400, 'This sign-in link is invalid or has expired. Start again from your agent.')
  }
  const query = authorizeQuery(signed)
  const secret = browserSecret(c)
  const browserHash = secret ? await sha256Hex(secret) : null
  const existing = browserHash ? await requestForBrowser(c.env.DB, browserHash) : null
  if (existing && browserHash && existing.query === query.toString()) {
    if (existing.live !== 1 || existing.status === 'used') return message(410, EXPIRED)
    if (existing.status === 'approved') return await continueToClaude(c, existing, browserHash, query)
    if (existing.status === 'denied') return await deniedPage(c.env, existing, browserHash, query)
    return codePage(existing)
  }
  const clientId = query.get('client_id') ?? ''
  const redirectHost = new URL(query.get('redirect_uri') ?? '').host
  const fresh = newBrowserSecret()
  const freshHash = await sha256Hex(fresh)
  const created = await createRequest(c.env.DB, {
    browserHash: freshHash,
    clientId,
    redirectHost,
    query: query.toString(),
    opener: openerOf(c),
  })
  if (created === null) return message(429, 'Too many sign-ins from this client. Try again in 10 minutes.')
  const res = codePage((await requestForBrowser(c.env.DB, freshHash))!)
  res.headers.append('set-cookie', browserCookie(c.env, fresh, CONNECT_MINUTES * 60))
  return res
}

/**
 * GET /connect/status: what the code page's script asks. Read-only, so asking never uses the approval the page itself
 * needs: `waiting`, `approved`, `denied` or `expired` for this browser's request (its cookie) on this signed query;
 * `unknown` (404) without one, `invalid` (400) for a query that isn't signed.
 */
export async function connectStatus(c: Context<AppEnv>): Promise<Response> {
  const signed = new URL(c.req.url).search.slice(1)
  if (signed === '' || !(await verifyOAuthQueryParams(signed, c.env.BETTER_AUTH_SECRET))) {
    return statusJson(400, 'invalid')
  }
  const query = authorizeQuery(signed)
  const secret = browserSecret(c)
  const existing = secret ? await requestForBrowser(c.env.DB, await sha256Hex(secret)) : null
  if (existing === null || existing.query !== query.toString()) return statusJson(404, 'unknown')
  if (existing.live !== 1 || existing.status === 'used') return statusJson(200, 'expired')
  return statusJson(200, existing.status)
}

const statusJson = (status: number, value: string) =>
  new Response(JSON.stringify({ status: value }), {
    status,
    headers: {
      'content-type': 'application/json',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
    },
  })

/** The browser's own secret from its gr_connect cookie, or undefined. */
const browserSecret = (c: Context<AppEnv>) =>
  /(?:^|;\s*)gr_connect=([0-9a-f]{64})(?:;|$)/.exec(c.req.header('cookie') ?? '')?.[1]

/**
 * Added after review: where this page was opened, for the app to show before Approve: the location from
 * request.cf, which only Cloudflare sets (never the cf-ip* headers, which a client can send itself), and the
 * browser's User-Agent, cleaned and cut short (openerText).
 */
function openerOf(c: Context<AppEnv>): Opener {
  const cf = c.req.raw.cf
  return {
    country: openerText(cfText(cf?.country), OPENER_LIMITS.country),
    city: openerText(cfText(cf?.city), OPENER_LIMITS.city),
    userAgent: openerText(c.req.header('user-agent'), OPENER_LIMITS.userAgent),
  }
}

/** request.cf values are typed unknown; only a string is a place. */
const cfText = (value: unknown): string | null => (typeof value === 'string' ? value : null)

/** The authorize request's own parameters (Better Auth's signature removed), in their signed order. */
function authorizeQuery(signed: string): URLSearchParams {
  const query = new URLSearchParams(signed)
  for (const name of SIGNATURE_PARAMS) query.delete(name)
  return query
}

function browserCookie(env: Env, value: string, maxAge: number): string {
  const secure = env.PUBLIC_BASE_URL.startsWith('https:') ? '; Secure' : ''
  return `${COOKIE}=${value}; Path=${CONNECT_PATH}; Max-Age=${maxAge}; HttpOnly; SameSite=Lax${secure}`
}

/**
 * Approved: sign this browser in as the approver, record the consent, and send it back into the authorize
 * step. `prompt` is dropped (the approval in the app was the login and the consent) and `offline_access`
 * added, so Claude always gets a refresh token.
 */
async function continueToClaude(
  c: Context<AppEnv>,
  request: ConnectRequest,
  browserHash: string,
  query: URLSearchParams,
): Promise<Response> {
  const used = await useDecision(c.env.DB, request.code, browserHash, 'approved')
  if (!used) return message(410, EXPIRED)
  const scopes = [...new Set([...(query.get('scope') ?? '').split(' ').filter(Boolean), 'offline_access'])]
    .filter((s) => MCP_SCOPES.includes(s))
  const reentry = new URLSearchParams(query)
  reentry.delete('prompt')
  reentry.set('scope', scopes.join(' '))
  const { headers, response } = await createAuth(c.env).api.connectSignIn({
    body: { userId: used.user_id, clientId: request.client_id, scopes, resources: query.getAll('resource') },
    returnHeaders: true,
  })
  await recordSession(c.env.DB, request.code, response.sessionId)
  const back = `0;url=/api/auth/oauth2/authorize?${reentry}`
  const res = message(200, `Approved, returning to ${request.client_name ?? 'the agent'}…`, back)
  for (const cookie of headers.getSetCookie()) res.headers.append('set-cookie', cookie)
  res.headers.append('set-cookie', browserCookie(c.env, '', 0))
  return res
}

/** Denied: tell Claude, as RFC 6749 section 4.1.2.1 says, after the page has said so. */
async function deniedPage(
  env: Env,
  request: ConnectRequest,
  browserHash: string,
  query: URLSearchParams,
): Promise<Response> {
  if (!(await useDecision(env.DB, request.code, browserHash, 'denied'))) return message(410, EXPIRED)
  const back = new URL(query.get('redirect_uri') ?? '')
  back.searchParams.set('error', 'access_denied')
  back.searchParams.set('error_description', 'The owner denied access in the GymRollins app.')
  const state = query.get('state')
  if (state !== null) back.searchParams.set('state', state)
  back.searchParams.set('iss', issuer(env))
  const who = request.client_name ?? 'The agent'
  const res = message(200, `Denied. ${who} was not given access.`, `${DENIED_SECONDS};url=${back}`)
  res.headers.append('set-cookie', browserCookie(env, '', 0))
  return res
}

function codePage(request: ConnectRequest): Response {
  const expires = Date.parse(request.expires_at)
  const left = Math.max(0, Math.round((expires - Date.now()) / 1000))
  const countdown = `${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`
  const who = escapeHtml(request.client_name ?? 'An MCP client')
  const host = escapeHtml(request.redirect_host)
  const code = displayCode(request.code)
  return page(
    200,
    `<p class="code">${code}</p>` +
      `<p><button id="copy" type="button" data-code="${code}">Copy code</button></p>` +
      '<p>Open GymRollins › Settings › AI agents › Approve a connection and type this code.</p>' +
      `<p><strong>${who}</strong> is asking, and returns to <strong>${host}</strong>.</p>` +
      `<p class="left" id="left" data-expires="${expires}">Expires in ${countdown}</p>`,
    {
      title: `Connect ${request.client_name ?? 'an agent'} to GymRollins`,
      refresh: String(POLL_SECONDS),
      script: CODE_SCRIPT,
    },
  )
}

/**
 * The code page's only script: Copy, the countdown, and a check of /connect/status every POLL_SECONDS that reloads
 * the page once the owner has decided or the code has expired (the page then does what the decision says). It
 * interpolates nothing: what it needs is in the page's data- attributes.
 */
const CODE_SCRIPT = `(() => {
  const copy = document.getElementById('copy')
  copy.addEventListener('click', () => {
    navigator.clipboard.writeText(copy.dataset.code).then(
      () => { copy.textContent = 'Copied' },
      () => { copy.textContent = 'Select the code to copy it' },
    )
  })
  const left = document.getElementById('left')
  const end = Number(left.dataset.expires)
  setInterval(() => {
    const s = Math.max(0, Math.round((end - Date.now()) / 1000))
    left.textContent = 'Expires in ' + Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0')
  }, 1000)
  const status = location.pathname + '/status' + location.search
  setInterval(async () => {
    try {
      const res = await fetch(status, { cache: 'no-store', credentials: 'same-origin' })
      const { status: now } = await res.json()
      if (now === 'approved' || now === 'denied' || now === 'expired') location.reload()
    } catch {}
  }, ${POLL_SECONDS * 1000})
})()`

const STYLE =
  'body{font:17px/1.5 system-ui,sans-serif;margin:0;padding:2rem 1rem;color:#111;background:#fff}' +
  'main{max-width:32rem;margin:auto}' +
  '.code{font:600 2.6rem/1.2 ui-monospace,monospace;letter-spacing:.08em;-webkit-user-select:all;user-select:all}' +
  'button{font:inherit;padding:.5rem 1rem;border-radius:.6rem;border:1px solid #888;background:none;color:inherit}' +
  '.left{color:#666}@media (prefers-color-scheme:dark){body{color:#eee;background:#111}.left{color:#aaa}}'

const message = (status: number, text: string, refresh?: string) =>
  page(status, `<p>${escapeHtml(text)}</p>`, { refresh })

interface PageParts {
  title?: string
  /** A meta refresh; with a script, it only runs where script doesn't (noscript). */
  refresh?: string
  script?: string
}

/**
 * Plain HTML with a strict CSP: no outside resource, only this page's own nonce'd style, and the code page's own
 * nonce'd script, which may fetch only from this origin.
 */
function page(status: number, content: string, parts: PageParts = {}): Response {
  const nonce = newBrowserSecret().slice(0, 32)
  const title = escapeHtml(parts.title ?? 'Connect to GymRollins')
  const refresh = parts.refresh === undefined
    ? ''
    : `<meta http-equiv="refresh" content="${escapeHtml(parts.refresh)}">`
  const body = '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width, initial-scale=1">' +
    (parts.script === undefined ? refresh : `<noscript>${refresh}</noscript>`) +
    `<title>${title}</title><style nonce="${nonce}">${STYLE}</style></head>` +
    `<body><main><h1>${title}</h1>${content}</main>` +
    (parts.script === undefined ? '' : `<script nonce="${nonce}">${parts.script}</script>`) +
    '</body></html>'
  const scripts = parts.script === undefined ? '' : `script-src 'nonce-${nonce}'; connect-src 'self'; `
  return new Response(body, {
    status,
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'content-security-policy': `default-src 'none'; style-src 'nonce-${nonce}'; ${scripts}base-uri 'none'; ` +
        "form-action 'none'; frame-ancestors 'none'",
      'referrer-policy': 'no-referrer',
      'x-content-type-options': 'nosniff',
      'x-frame-options': 'DENY',
    },
  })
}

const ESCAPES: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;',
}
const escapeHtml = (text: string) => text.replace(/[&<>"']/g, (ch) => ESCAPES[ch]!)
