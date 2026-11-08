// GET /connect: Claude's sign-in page (spec sections 4 and 5). Better Auth's authorize step sends the browser
// here with its signed query. The page shows an approval code and reloads itself every 2 seconds (a meta
// refresh: the page runs no script at all). Once the owner approves the code in the app, the same browser
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
const EXPIRED = 'This code has expired. Start again from Claude.'

export async function connectPage(c: Context<AppEnv>): Promise<Response> {
  const signed = new URL(c.req.url).search.slice(1)
  if (signed === '' || !(await verifyOAuthQueryParams(signed, c.env.BETTER_AUTH_SECRET))) {
    return message(400, 'This sign-in link is invalid or has expired. Start again from Claude.')
  }
  const query = authorizeQuery(signed)
  const secret = /(?:^|;\s*)gr_connect=([0-9a-f]{64})(?:;|$)/.exec(c.req.header('cookie') ?? '')?.[1]
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
  })
  if (created === null) return message(429, 'Too many sign-ins from this client. Try again in 10 minutes.')
  const res = codePage((await requestForBrowser(c.env.DB, freshHash))!)
  res.headers.append('set-cookie', browserCookie(c.env, fresh, CONNECT_MINUTES * 60))
  return res
}

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
  const res = message(200, 'Approved, returning to Claude…', `0;url=/api/auth/oauth2/authorize?${reentry}`)
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
  const res = message(200, 'Denied. Claude was not given access.', `${DENIED_SECONDS};url=${back}`)
  res.headers.append('set-cookie', browserCookie(env, '', 0))
  return res
}

function codePage(request: ConnectRequest): Response {
  const left = Math.max(0, Math.round((Date.parse(request.expires_at) - Date.now()) / 1000))
  const countdown = `${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`
  const who = escapeHtml(request.client_name ?? 'An MCP client')
  const host = escapeHtml(request.redirect_host)
  return page(
    200,
    `<p class="code">${displayCode(request.code)}</p>` +
      '<p>Open GymRollins › Settings › Claude › Approve a connection and type this code.</p>' +
      `<p><strong>${who}</strong> is asking, and returns to <strong>${host}</strong>.</p>` +
      `<p class="left">Expires in ${countdown}</p>`,
    String(POLL_SECONDS),
  )
}

const STYLE =
  'body{font:17px/1.5 system-ui,sans-serif;margin:0;padding:2rem 1rem;color:#111;background:#fff}' +
  'main{max-width:32rem;margin:auto}.code{font:600 2.6rem/1.2 ui-monospace,monospace;letter-spacing:.08em}' +
  '.left{color:#666}@media (prefers-color-scheme:dark){body{color:#eee;background:#111}.left{color:#aaa}}'

const message = (status: number, text: string, refresh?: string) =>
  page(status, `<p>${escapeHtml(text)}</p>`, refresh)

/** Plain HTML with a strict CSP: no script, no outside resource, only this page's own nonce'd style. */
function page(status: number, content: string, refresh?: string): Response {
  const nonce = newBrowserSecret().slice(0, 32)
  const body = '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width, initial-scale=1">' +
    (refresh ? `<meta http-equiv="refresh" content="${escapeHtml(refresh)}">` : '') +
    `<title>Connect Claude to GymRollins</title><style nonce="${nonce}">${STYLE}</style></head>` +
    `<body><main><h1>Connect Claude to GymRollins</h1>${content}</main></body></html>`
  return new Response(body, {
    status,
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'content-security-policy': `default-src 'none'; style-src 'nonce-${nonce}'; base-uri 'none'; ` +
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
