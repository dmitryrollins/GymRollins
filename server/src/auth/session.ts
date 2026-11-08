import type { MiddlewareHandler } from 'hono'
import type { AppEnv } from '../env.ts'
import { ApiError } from '../http/errors.ts'
import { createAuth } from './auth.ts'

/**
 * The app's routes: the user of the Better Auth session in `Authorization: Bearer <token>`, or 401 signed_out.
 * Cookies are never accepted: the app sends none, and a browser's cookie must not drive these routes.
 */
export const requireUser: MiddlewareHandler<AppEnv> = async (c, next) => {
  if (!/^Bearer \S+$/.test(c.req.header('authorization') ?? '')) throw new ApiError(401, 'signed_out', 'Sign in required.')
  const session = await createAuth(c.env).api.getSession({ headers: c.req.raw.headers })
  if (!session) throw new ApiError(401, 'signed_out', 'Sign in required.')
  c.set('userId', session.user.id)
  await next()
}
