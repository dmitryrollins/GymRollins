import type { MiddlewareHandler } from 'hono'
import type { AppEnv } from '../env.ts'
import { ApiError } from '../http/errors.ts'
import { createAuth } from './auth.ts'

/**
 * The app's routes: the user of the Better Auth session in `Authorization: Bearer <token>`, or 401 signed_out.
 * Cookies are never accepted: the app sends none, and a browser's cookie must not drive these routes. Better Auth's
 * bearer plugin falls back to the Cookie header when a bearer fails its signature check, so getSession sees the
 * authorization header alone.
 */
export const requireUser: MiddlewareHandler<AppEnv> = async (c, next) => {
  const authorization = c.req.header('authorization') ?? ''
  if (!/^Bearer \S+$/.test(authorization)) throw new ApiError(401, 'signed_out', 'Sign in required.')
  const session = await createAuth(c.env).api.getSession({ headers: new Headers({ authorization }) })
  if (!session) throw new ApiError(401, 'signed_out', 'Sign in required.')
  c.set('userId', session.user.id)
  await next()
}
