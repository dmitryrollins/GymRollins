// The GymRollins API (docs/specs/2026-11-07-cloudflare-backend-design.md): one Worker, with Better Auth under /api/auth
// and the app's routes under /v1 behind its session.
import { Hono } from 'hono'
import { bodyLimit } from 'hono/body-limit'
import { accountRoutes } from './account/routes.ts'
import { authHandler } from './auth/routes.ts'
import { requireUser } from './auth/session.ts'
import { connectPage } from './claude/connect-page.ts'
import { wellKnownRoutes } from './claude/well-known.ts'
import type { AppEnv } from './env.ts'
import { catalogueRoutes } from './gyms/routes.ts'
import { errorBody, onError } from './http/errors.ts'
import { moderationRoutes } from './moderation/routes.ts'
import { publicPhotoRoutes } from './photos/public.ts'
import { photoRoutes } from './photos/routes.ts'
import { syncRoutes } from './sync/routes.ts'

/** A workout or 200 rows is far below this, and one bound JSON value must stay under D1's ~2 MB. */
const MAX_BODY_BYTES = 1024 * 1024

const app = new Hono<AppEnv>()
app.onError(onError)
app.notFound((c) => c.json(errorBody('not_found', 'No such route.'), 404))
/** Sign-in bodies are a token and a nonce, or an email and password. */
const MAX_AUTH_BODY_BYTES = 16 * 1024

app.use('/api/auth/*', bodyLimit({
  maxSize: MAX_AUTH_BODY_BYTES,
  onError: (c) => c.json(errorBody('too_large', 'The request body is too large.'), 413),
}))
app.on(['GET', 'POST'], '/api/auth/*', authHandler)

// Claude: OAuth discovery, the sign-in page and the MCP server (spec section 3). CORS only on /mcp and discovery.
app.route('/.well-known', wellKnownRoutes)
app.get('/connect', connectPage)

const v1 = new Hono<AppEnv>()
v1.use('*', bodyLimit({
  maxSize: MAX_BODY_BYTES,
  onError: (c) => c.json(errorBody('too_large', 'The request body is too large.'), 413),
}))
v1.use('*', requireUser)
v1.route('/sync', syncRoutes)
v1.route('/account', accountRoutes)
v1.route('/', catalogueRoutes)
v1.route('/', moderationRoutes)
v1.route('/photos', photoRoutes)
app.route('/v1', v1)
app.route('/photos', publicPhotoRoutes)

export default app
