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
  if (route === 'POST /api/auth/sign-in/social' && !(await hasIdTokenAndNonce(c.req.raw))) {
    return c.json(errorBody('bad_request', 'Sign in with Apple needs the id token and its nonce.'), 400)
  }
  return createAuth(c.env).handler(c.req.raw)
}

/**
 * Better Auth checks an id token's nonce only when the client sends one, and without an id token it starts a web
 * redirect flow the app never uses. The app always sends both.
 */
async function hasIdTokenAndNonce(request: Request): Promise<boolean> {
  const body = await request.clone().json().catch(() => null) as { idToken?: { token?: unknown; nonce?: unknown } } | null
  const idToken = body?.idToken
  return typeof idToken?.token === 'string' && typeof idToken.nonce === 'string' && idToken.nonce.length > 0
}
