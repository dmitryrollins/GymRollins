import { Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { jsonBody } from '../http/body.ts'
import { entityNamed } from './entities.ts'
import { parsePullQuery, pullRows, pushRows } from './table-sync.ts'
import { fetchWorkout, pullWorkouts, pushWorkout } from './workouts.ts'

/** /v1/sync: what the app's SyncTransport calls (spec section 3, "Routes"). Specific routes go above /:entity. */
export const syncRoutes = new Hono<AppEnv>()

syncRoutes.post('/workouts', async (c) => c.json(await pushWorkout(c.env.DB, c.var.userId, await jsonBody(c))))

syncRoutes.get('/workouts', async (c) => {
  const rows = await pullWorkouts(c.env.DB, c.var.userId, parsePullQuery(c.req.query(), 'text'))
  return c.json({ rows })
})

syncRoutes.get('/workouts/:id', async (c) => c.json(await fetchWorkout(c.env.DB, c.var.userId, c.req.param('id'))))

syncRoutes.post('/:entity', async (c) => {
  const acks = await pushRows(c.env.DB, c.var.userId, entityNamed(c.req.param('entity')), await jsonBody(c))
  return c.json({ acks })
})

syncRoutes.get('/:entity', async (c) => {
  const entity = entityNamed(c.req.param('entity'))
  const rows = await pullRows(c.env.DB, c.var.userId, entity, parsePullQuery(c.req.query(), entity.tiebreak.kind))
  return c.json({ rows })
})
