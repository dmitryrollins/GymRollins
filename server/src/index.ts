// The GymRollins API (docs/specs/2026-11-07-cloudflare-backend-design.md): one Worker, with Better Auth under /api/auth
// and the app's routes under /v1 behind its session.
import { Hono } from 'hono'
import { bodyLimit } from 'hono/body-limit'
import { authHandler } from './auth/routes.ts'
import { requireUser } from './auth/session.ts'
import type { AppEnv } from './env.ts'
import { errorBody, onError } from './http/errors.ts'
import { syncRoutes } from './sync/routes.ts'

/** A workout or 200 rows is far below this. */
const MAX_BODY_BYTES = 4 * 1024 * 1024

const app = new Hono<AppEnv>()
app.onError(onError)
app.notFound((c) => c.json(errorBody('not_found', 'No such route.'), 404))
app.on(['GET', 'POST'], '/api/auth/*', authHandler)

const v1 = new Hono<AppEnv>()
v1.use('*', bodyLimit({
  maxSize: MAX_BODY_BYTES,
  onError: (c) => c.json(errorBody('too_large', 'The request body is too large.'), 413),
}))
v1.use('*', requireUser)
v1.route('/sync', syncRoutes)
app.route('/v1', v1)

export default app
