import type { Context } from 'hono'
import type { AppEnv, Env } from '../env.ts'
import { isCleanText } from '../gyms/text.ts'
import { errorBody } from '../http/errors.ts'
import { createAuth } from './auth.ts'
import { isConnectSession } from './connect-plugin.ts'
import { ACCESS_TOKEN_PREFIX, hashToken, isAllowedRedirectUri } from './oauth.ts'

/**
 * The Better Auth routes the app and Claude use. Every other route Better Auth serves (its web redirect flow,
 * account linking, password reset, OAuth client and consent management, …) answers 404, so nothing unused is
 * reachable.
 */
const APP_ROUTES = new Set([
  'POST /api/auth/sign-in/social',
  'POST /api/auth/sign-up/email',
  'POST /api/auth/sign-in/email',
  'POST /api/auth/sign-out',
  'GET /api/auth/get-session',
])

/**
 * Claude's OAuth: discovery, registration, authorize (a browser), token and revocation (Claude's servers).
 */
const OAUTH_ROUTES = new Set([
  'GET /api/auth/.well-known/oauth-authorization-server',
  'POST /api/auth/oauth2/register',
  'GET /api/auth/oauth2/authorize',
  'POST /api/auth/oauth2/token',
  'POST /api/auth/oauth2/revoke',
])

/** Dynamic registration is open, so it's capped: at most this many new clients an hour, across everyone. */
export const REGISTRATIONS_PER_HOUR = 30

const registrationCap = (env: Env) => Number(env.OAUTH_REGISTRATIONS_PER_HOUR ?? REGISTRATIONS_PER_HOUR)

export async function authHandler(c: Context<AppEnv>): Promise<Response> {
  const route = `${c.req.method} ${new URL(c.req.url).pathname}`
  if (OAUTH_ROUTES.has(route)) return await oauthHandler(c, route)
  if (!APP_ROUTES.has(route)) return c.json(errorBody('not_found', 'No such route.'), 404)
  if (route === 'POST /api/auth/sign-in/social') {
    const refusal = await appleNonceRefusal(c.req.raw)
    if (refusal !== null) return c.json(errorBody('bad_request', refusal), 400)
  }
  const res = await createAuth(c.env).handler(withoutCookies(c.req.raw))
  if (res.status >= 400) return await inErrorShape(res)
  return route === 'GET /api/auth/get-session' ? await appSessionOnly(res) : res
}

/**
 * Added after review: the app's routes see no Cookie header. The app sends none, so a browser's cookie (the
 * /connect session's) can't sign it in, out or ask who it is. The OAuth routes keep cookies: authorize needs
 * the browser's.
 */
function withoutCookies(request: Request): Request {
  const headers = new Headers(request.headers)
  headers.delete('cookie')
  return new Request(request, { headers })
}

/**
 * Added after review: get-session answers null for the /connect browser session, as for no session, so its
 * token (sent as a bearer) learns nothing and gets no new one.
 */
async function appSessionOnly(res: Response): Promise<Response> {
  const body = await res.clone().json().catch(() => null) as { session?: { claudeConnect?: unknown } } | null
  if (!body?.session || !isConnectSession(body.session)) return res
  return Response.json(null, { headers: { 'cache-control': 'no-store' } })
}

/** OAuth answers keep RFC 6749's error shape ({error, error_description}), which Claude reads. */
async function oauthHandler(c: Context<AppEnv>, route: string): Promise<Response> {
  let request = c.req.raw
  if (route === 'POST /api/auth/oauth2/register') {
    const checked = await checkedRegistration(c)
    if (checked instanceof Response) return checked
    request = withoutSession(checked)
  }
  if (route === 'GET /api/auth/oauth2/authorize') request = await withConnectSessionOnly(c.env, request)
  const res = await createAuth(c.env).handler(request)
  if (route === 'POST /api/auth/oauth2/token' && res.ok) {
    // The session expires within 10 minutes anyway: a failed delete mustn't cost Claude the tokens.
    await endConnectSession(c.env.DB, res).catch((error) => console.error('connect session not ended', error))
  }
  return res
}

/**
 * Added after review: registration is Claude's servers, which send no session. Better Auth would make a
 * client registered with one (the app's bearer, say) that account's own.
 */
function withoutSession(request: Request): Request {
  const headers = new Headers(request.headers)
  headers.delete('authorization')
  headers.delete('cookie')
  return new Request(request, { headers })
}

/**
 * Added after review: the authorize step takes the /connect browser session only. Its `Authorization` header
 * goes (the bearer plugin would turn the app's `Bearer <session>` into a session, and authorize would then
 * return a code for any client the owner approved before, with no code typed), and so does a Cookie whose
 * session isn't /connect's. Either way, the browser goes to /connect as one with no session does.
 */
async function withConnectSessionOnly(env: Env, request: Request): Promise<Request> {
  const headers = new Headers(request.headers)
  headers.delete('authorization')
  const cookie = headers.get('cookie')
  if (cookie !== null && !(await isConnectCookie(env, cookie))) headers.delete('cookie')
  return new Request(request, { headers })
}

/** True when the Cookie header signs in with a /connect browser session (Better Auth reads it, unrenewed). */
async function isConnectCookie(env: Env, cookie: string): Promise<boolean> {
  const session = await createAuth(env).api.getSession({
    headers: new Headers({ cookie }),
    query: { disableRefresh: true },
  })
  return session !== null && isConnectSession(session.session)
}

/**
 * Added after review: swapping the code for tokens is the /connect browser session's last use, so it ends
 * there. It can't end at the redirect to Claude: Better Auth refuses a code whose session has gone.
 * Deleted in SQL, not through Better Auth, whose session hook would revoke the access token just issued;
 * the tokens' sessionId goes null (ON DELETE SET NULL). A refresh's tokens have no session: nothing to do.
 */
async function endConnectSession(db: D1Database, res: Response): Promise<void> {
  const body = await res.clone().json().catch(() => null) as { access_token?: unknown } | null
  const token = body?.access_token
  if (typeof token !== 'string' || !token.startsWith(ACCESS_TOKEN_PREFIX)) return
  await db.prepare(
    'DELETE FROM session WHERE claudeConnect = 1 AND id = ' +
      '(SELECT sessionId FROM oauthAccessToken WHERE token = ?1)',
  ).bind(await hashToken(token.slice(ACCESS_TOKEN_PREFIX.length))).run()
}

const oauthError = (error: string, description: string, status: 400 | 429) =>
  Response.json({ error, error_description: description }, {
    status,
    headers: { 'cache-control': 'no-store' },
  })

/** The longest client_name taken, in characters (added after review). */
export const CLIENT_NAME_MAX = 64

/** Control, format (bidi and zero width among them), surrogate, private use and unassigned characters. */
const INVISIBLE = /\p{C}/u

/**
 * Added after review: the name the app shows before Approve, so short and visible. At most CLIENT_NAME_MAX
 * characters, none of them \p{C}, nor any clean_text refuses (plan 28's src/gyms/text.ts adds the line
 * separators, fillers and variation selectors), and not only spaces. A client may give none.
 */
function isClientName(name: unknown): boolean {
  if (name === undefined) return true
  return typeof name === 'string' && [...name].length <= CLIENT_NAME_MAX && !INVISIBLE.test(name) &&
    isCleanText(name) && name.trim() !== ''
}

/**
 * A registration only for Claude's redirect URLs, within the hourly cap. Every client gets refresh tokens: a
 * client that names no grant types is registered for authorization_code and refresh_token (RFC 7591's default
 * is the first). Added after review: its client_name is checked (isClientName).
 */
async function checkedRegistration(c: Context<AppEnv>): Promise<Request | Response> {
  const body = await c.req.raw.clone().json().catch(() => null) as Record<string, unknown> | null
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    return oauthError('invalid_client_metadata', 'The body must be a JSON object.', 400)
  }
  if (!isClientName(body.client_name)) {
    return oauthError(
      'invalid_client_metadata',
      `client_name must be at most ${CLIENT_NAME_MAX} characters of visible text.`,
      400,
    )
  }
  const uris = body.redirect_uris
  if (
    !Array.isArray(uris) || uris.length === 0 ||
    !uris.every((u) => typeof u === 'string' && isAllowedRedirectUri(u))
  ) {
    return oauthError('invalid_redirect_uri', "Only Claude's redirect URLs can be registered.", 400)
  }
  const hourAgo = new Date(Date.now() - 3_600_000).toISOString()
  const recent = await c.env.DB.prepare('SELECT count(*) AS n FROM oauthClient WHERE createdAt > ?1').bind(
    hourAgo,
  )
    .first<{ n: number }>()
  if (recent!.n >= registrationCap(c.env)) {
    return oauthError('too_many_requests', 'Too many registrations; try again in an hour.', 429)
  }
  const registration = body.grant_types === undefined
    ? { ...body, grant_types: ['authorization_code', 'refresh_token'] }
    : body
  const headers = new Headers(c.req.raw.headers)
  headers.delete('content-length')
  return new Request(c.req.raw.url, { method: 'POST', headers, body: JSON.stringify(registration) })
}

/** Better Auth's error as the API's {"error": {"code", "message"}}, with its code lowercased (invalid_token, …). */
async function inErrorShape(res: Response): Promise<Response> {
  const body = await res.clone().json().catch(() => null) as { code?: unknown; message?: unknown } | null
  const code = typeof body?.code === 'string' && body.code !== '' ? body.code.toLowerCase() : 'auth_failed'
  const message = typeof body?.message === 'string' && body.message !== '' ? body.message : 'Sign-in failed.'
  const headers = new Headers(res.headers)
  headers.set('content-type', 'application/json')
  headers.delete('content-length')
  return new Response(JSON.stringify(errorBody(code, message)), { status: res.status, headers })
}

/**
 * Why a Sign in with Apple body is refused before Better Auth sees it, or null.
 * - Better Auth checks an id token's nonce only when the client sends one, and without an id token it starts a web
 *   redirect flow the app never uses. The app always sends both.
 * - The app sends the raw nonce and gave Apple its SHA-256 hex, so the token's nonce claim must be that hash. Better
 *   Auth also takes the claim itself sent back as the nonce, which anyone holding the token can do: no replay
 *   protection. The claim is read without the signature here; Better Auth verifies the token next.
 */
async function appleNonceRefusal(request: Request): Promise<string | null> {
  const body = await request.clone().json().catch(() => null) as { idToken?: { token?: unknown; nonce?: unknown } } | null
  const idToken = body?.idToken
  if (typeof idToken?.token !== 'string' || typeof idToken.nonce !== 'string' || idToken.nonce.length === 0) {
    return 'Sign in with Apple needs the id token and its nonce.'
  }
  const claim = unverifiedClaims(idToken.token)?.nonce
  if (typeof claim !== 'string' || claim !== (await sha256Hex(idToken.nonce))) {
    return "The nonce doesn't match the id token."
  }
  return null
}

/** A JWT's payload, unverified, or null when it isn't one. */
function unverifiedClaims(token: string): Record<string, unknown> | null {
  const parts = token.split('.')
  if (parts.length !== 3) return null
  try {
    const base64 = parts[1].replace(/-/g, '+').replace(/_/g, '/')
    const bytes = Uint8Array.from(atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, '=')), (ch) => ch.charCodeAt(0))
    const claims: unknown = JSON.parse(new TextDecoder().decode(bytes))
    const isObject = typeof claims === 'object' && claims !== null && !Array.isArray(claims)
    return isObject ? claims as Record<string, unknown> : null
  } catch {
    return null
  }
}

/** Lowercase hex SHA-256 of the UTF-8 text, as the app's AppleNonce.sha256 gives Apple. */
async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('')
}
