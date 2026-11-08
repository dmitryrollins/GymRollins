import { type Context, Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { errorBody } from '../http/errors.ts'
import { type GymBucket, PHOTO_HEADERS, PRIVATE_BUCKET, SHARED_BUCKET } from './objects.ts'
import { deletePhoto, detachMyPhotos, myPhotos, privatePhoto, uploadPhoto } from './store.ts'

/** /v1/photos: the caller's gym photos (spec section 3, "Photos"). Shared photos are read at /photos/shared. */
export const photoRoutes = new Hono<AppEnv>()

const put = (bucket: GymBucket) => async (c: Context<AppEnv>) => {
  const name = c.req.param('name') ?? ''
  const bytes = new Uint8Array(await c.req.arrayBuffer())
  await uploadPhoto(c.env, c.var.userId, bucket, name, c.req.header('content-type'), bytes)
  return c.json({ name })
}

const remove = (bucket: GymBucket) => async (c: Context<AppEnv>) => {
  await deletePhoto(c.env, c.var.userId, bucket, c.req.param('name') ?? '')
  return c.body(null, 204)
}

photoRoutes.get('/mine', async (c) => c.json({ rows: await myPhotos(c.env.DB, c.var.userId) }))

photoRoutes.post('/detach', async (c) => {
  await detachMyPhotos(c.env.DB, c.var.userId)
  return c.body(null, 204)
})

/** The app keeps its URL cache off for these too (spec section 7). */
photoRoutes.get('/private/:name', async (c) => {
  const object = await privatePhoto(c.env, c.var.userId, c.req.param('name'))
  if (object === null) return c.json(errorBody('not_found', 'No such photo.'), 404)
  return new Response(object.body, {
    headers: { ...PHOTO_HEADERS, 'content-type': 'image/jpeg', 'cache-control': 'private, no-store' },
  })
})

photoRoutes.put('/private/:name', put(PRIVATE_BUCKET))
photoRoutes.put('/shared/:name', put(SHARED_BUCKET))
photoRoutes.delete('/private/:name', remove(PRIVATE_BUCKET))
photoRoutes.delete('/shared/:name', remove(SHARED_BUCKET))
