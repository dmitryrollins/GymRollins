import { Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { uuidOf } from '../http/input.ts'
import { pageOf, publicGym, publicItems, publicListings } from './catalogue.ts'

/** /v1/gyms, /v1/items and /v1/listings: the shared catalogue (spec section 3, "Gyms"). */
export const catalogueRoutes = new Hono<AppEnv>()

catalogueRoutes.get('/gyms/public', async (c) =>
  c.json({ gym: await publicGym(c.env.DB, c.var.userId, c.req.query('place') ?? '') }))

catalogueRoutes.get('/gyms/:id/listings', async (c) => {
  const gymId = uuidOf(c.req.param('id'), 'id')
  return c.json({ rows: await publicListings(c.env.DB, c.var.userId, gymId, pageOf(c.req.query())) })
})

catalogueRoutes.get('/items', async (c) =>
  c.json({ rows: await publicItems(c.env.DB, c.var.userId, c.req.query('kind') ?? '') }))
