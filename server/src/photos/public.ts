import { type Context, Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { errorBody } from '../http/errors.ts'
import { PHOTO_NAME } from './objects.ts'

// Photos anyone can read, outside /v1 and its session (spec section 3): shared listing photos, and GymRollins' own
// exercise and kind photos with their manifest.json. Answers carry ETag and Cache-Control, and a matching
// If-None-Match gets 304, so phones and Cloudflare's edge keep copies. A removed listing's photo is served until
// moderation deletes it, as Supabase's public URLs served it. Nothing here writes: gym photos are uploaded through
// /v1/photos, and exercise photos by scripts/upload-photos.mjs.

/** The uploader's names: own-<exercise id>-<frame>.jpg and kind-<kind id>.jpg. */
const EXERCISE_PHOTO = /^(own-\d+-\d+|kind-[a-z0-9-]{1,40})\.jpg$/
const MANIFEST = 'manifest.json'

/** The app uploaded shared photos with an hour (FileOptions cacheControl "3600"); a deleted one leaves caches in it. */
const SHARED_CACHE = 'public, max-age=3600'
/** A regenerated exercise photo gets a new ?v=<rev> from the manifest, so an old URL can be kept for a year. */
const EXERCISE_CACHE = 'public, max-age=31536000'
/** The manifest says which ?v= is current; the uploader gave it a minute. */
const MANIFEST_CACHE = 'public, max-age=60'

const notFound = (c: Context<AppEnv>) => c.json(errorBody('not_found', 'No such photo.'), 404)

async function serve(c: Context<AppEnv>, bucket: R2Bucket, name: string, type: string, cacheControl: string) {
  const seen = c.req.header('if-none-match')
  const object = await bucket.get(name, seen ? { onlyIf: new Headers({ 'if-none-match': seen }) } : {})
  if (object === null) return notFound(c)
  const headers = new Headers({
    'content-type': type, 'cache-control': cacheControl, etag: object.httpEtag, 'x-content-type-options': 'nosniff',
  })
  if (!('body' in object)) return new Response(null, { status: 304, headers })
  headers.set('content-length', String(object.size))
  return new Response(object.body, { headers })
}

/** /photos. Hono answers HEAD from these GET routes, without the body. */
export const publicPhotoRoutes = new Hono<AppEnv>()

publicPhotoRoutes.get('/shared/:name', (c) => {
  const name = c.req.param('name')
  return PHOTO_NAME.test(name) ? serve(c, c.env.GYM_PHOTOS, name, 'image/jpeg', SHARED_CACHE) : notFound(c)
})

publicPhotoRoutes.get('/exercises/:name', (c) => {
  const name = c.req.param('name')
  if (name === MANIFEST) return serve(c, c.env.EXERCISE_PHOTOS, name, 'application/json', MANIFEST_CACHE)
  return EXERCISE_PHOTO.test(name) ? serve(c, c.env.EXERCISE_PHOTOS, name, 'image/jpeg', EXERCISE_CACHE) : notFound(c)
})
