import type { Context } from 'hono'
import type { AppEnv } from '../env.ts'
import { errorBody } from '../http/errors.ts'
import { createAuth } from './auth.ts'

/**
 * The Better Auth routes the app uses. Every other route Better Auth serves (its web redirect flow, account linking,
 * password reset, …) answers 404, so nothing the app doesn't use is reachable. Plan 29 adds Claude's OAuth routes.
 */
const ALLOWED = new Set([
  'POST /api/auth/sign-in/social',
  'POST /api/auth/sign-up/email',
  'POST /api/auth/sign-in/email',
  'POST /api/auth/sign-out',
  'GET /api/auth/get-session',
])

export async function authHandler(c: Context<AppEnv>): Promise<Response> {
  const route = `${c.req.method} ${new URL(c.req.url).pathname}`
  if (!ALLOWED.has(route)) return c.json(errorBody('not_found', 'No such route.'), 404)
  if (route === 'POST /api/auth/sign-in/social') {
    const refusal = await appleNonceRefusal(c.req.raw)
    if (refusal !== null) return c.json(errorBody('bad_request', refusal), 400)
  }
  const res = await createAuth(c.env).handler(c.req.raw)
  return res.status >= 400 ? inErrorShape(res) : res
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
