import type { Context } from 'hono'
import type { AppEnv, Env } from '../env.ts'
import { errorBody } from '../http/errors.ts'
import { createAuth } from './auth.ts'
import { isAllowedRedirectUri } from './oauth.ts'

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
  const res = await createAuth(c.env).handler(c.req.raw)
  return res.status >= 400 ? inErrorShape(res) : res
}

/** OAuth answers keep RFC 6749's error shape ({error, error_description}), which Claude reads. */
async function oauthHandler(c: Context<AppEnv>, route: string): Promise<Response> {
  let request = c.req.raw
  if (route === 'POST /api/auth/oauth2/register') {
    const checked = await checkedRegistration(c)
    if (checked instanceof Response) return checked
    request = checked
  }
  return await createAuth(c.env).handler(request)
}

const oauthError = (error: string, description: string, status: 400 | 429) =>
  Response.json({ error, error_description: description }, {
    status,
    headers: { 'cache-control': 'no-store' },
  })

/**
 * A registration only for Claude's redirect URLs, within the hourly cap. Every client gets refresh tokens: a
 * client that names no grant types is registered for authorization_code and refresh_token (RFC 7591's default
 * is the first).
 */
async function checkedRegistration(c: Context<AppEnv>): Promise<Request | Response> {
  const body = await c.req.raw.clone().json().catch(() => null) as Record<string, unknown> | null
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    return oauthError('invalid_client_metadata', 'The body must be a JSON object.', 400)
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
