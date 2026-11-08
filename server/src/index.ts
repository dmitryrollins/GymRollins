// The GymRollins API (docs/specs/2026-11-07-cloudflare-backend-design.md): one Worker, with Better Auth under /api/auth
// and the app's routes under /v1 behind its session.
import { Hono } from 'hono'
import { authHandler } from './auth/routes.ts'
import type { AppEnv } from './env.ts'
import { errorBody, onError } from './http/errors.ts'

const app = new Hono<AppEnv>()
app.onError(onError)
app.notFound((c) => c.json(errorBody('not_found', 'No such route.'), 404))
app.on(['GET', 'POST'], '/api/auth/*', authHandler)

export default app
