import type { MiddlewareHandler } from 'hono'
import type { AppEnv } from '../env.ts'
import { ApiError } from '../http/errors.ts'
import { createAuth } from './auth.ts'

/** The app's routes: the user of the Better Auth session in `Authorization: Bearer <token>`, or 401 signed_out. */
export const requireUser: MiddlewareHandler<AppEnv> = async (c, next) => {
  const session = await createAuth(c.env).api.getSession({ headers: c.req.raw.headers })
  if (!session) throw new ApiError(401, 'signed_out', 'Sign in required.')
  c.set('userId', session.user.id)
  await next()
}
