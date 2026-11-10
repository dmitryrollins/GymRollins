import { Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { deleteAccount } from './delete.ts'

/** /v1/account. */
export const accountRoutes = new Hono<AppEnv>()

accountRoutes.delete('/', async (c) => {
  await deleteAccount(c.env.DB, c.var.userId)
  return c.body(null, 204)
})
