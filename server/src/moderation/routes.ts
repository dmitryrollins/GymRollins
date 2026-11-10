import { Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { jsonBody } from '../http/body.ts'
import { objectBody } from '../http/input.ts'
import { isAdmin, moderate, moderationPhotoDeleted, moderationQueue } from './admin.ts'
import { blockAuthor, reportContent, unblockAll } from './reports.ts'
import { targetOf } from './targets.ts'

/** /v1/reports, /v1/blocks and /v1/admin (spec section 3, "Moderation"). */
export const moderationRoutes = new Hono<AppEnv>()

moderationRoutes.post('/reports', async (c) => {
  const body = objectBody(await jsonBody(c))
  return c.json(await reportContent(c.env.DB, c.var.userId, targetOf(body), body.reason, body.note))
})

moderationRoutes.post('/blocks', async (c) => {
  await blockAuthor(c.env.DB, c.var.userId, targetOf(objectBody(await jsonBody(c))))
  return c.body(null, 204)
})

moderationRoutes.delete('/blocks', async (c) => c.json({ cleared: await unblockAll(c.env.DB, c.var.userId) }))

moderationRoutes.get('/admin/me', async (c) => c.json({ admin: await isAdmin(c.env.DB, c.var.userId) }))

moderationRoutes.get('/admin/queue', async (c) => c.json({ rows: await moderationQueue(c.env.DB, c.var.userId) }))

moderationRoutes.post('/admin/moderate', async (c) =>
  c.json(await moderate(c.env.DB, c.var.userId, objectBody(await jsonBody(c)))))

moderationRoutes.post('/admin/photo-deleted', async (c) => {
  await moderationPhotoDeleted(c.env.DB, c.var.userId, objectBody(await jsonBody(c)))
  return c.body(null, 204)
})
