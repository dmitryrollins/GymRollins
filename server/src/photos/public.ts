import { type Context, Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { errorBody } from '../http/errors.ts'
import { PHOTO_HEADERS, PHOTO_NAME } from './objects.ts'
import { sharedPhotoInUse } from './store.ts'

// Photos anyone can read, outside /v1 and its session (spec section 3): shared listing photos, and GymRollins' own
// exercise and kind photos with their manifest.json. Answers carry ETag and Cache-Control, and a matching
// If-None-Match gets 304, so phones and Cloudflare's edge keep copies. A shared photo is served only while a public
// listing that isn't removed names it (sharedPhotoInUse): a removed listing's photo stops at once, though caches keep
// it for up to SHARED_CACHE. Nothing here writes: gym photos are uploaded through /v1/photos, and exercise photos by
// scripts/upload-photos.mjs.

/** The uploader's names: own-<exercise id>-<frame>.jpg and kind-<kind id>.jpg. */
const EXERCISE_PHOTO = /^(own-\d{1,6}-\d{1,6}|kind-[a-z0-9-]{1,40})\.jpg$/
const MANIFEST = 'manifest.json'

/** The app uploaded shared photos with an hour (FileOptions cacheControl "3600"); a deleted one leaves caches in it. */
const SHARED_CACHE = 'public, max-age=3600'
/** A regenerated exercise photo gets a new ?v=<rev> from the manifest, so an old URL can be kept for a year. */
const EXERCISE_CACHE = 'public, max-age=31536000'
/** The manifest says which ?v= is current; the uploader gave it a minute. */
const MANIFEST_CACHE = 'public, max-age=60'

const notFound = (c: Context<AppEnv>) => c.json(errorBody('not_found', 'No such photo.'), 404)

/** An entity tag, strong or weak (RFC 9110 section 8.8.3), in printable ASCII. */
const ENTITY_TAG = String.raw`(?:W/)?"[\x21\x23-\x7e]*"`
/** `*`, or a comma-separated list of entity tags. R2 throws "Invalid ETag" for anything else. */
const IF_NONE_MATCH = new RegExp(String.raw`^(?:\*|${ENTITY_TAG}(?:[ \t]*,[ \t]*${ENTITY_TAG})*)$`)

/** The request's If-None-Match for R2, or undefined when there is none or R2 couldn't read it: then a plain get. */
function ifNoneMatch(c: Context<AppEnv>): Headers | undefined {
  const seen = c.req.header('if-none-match')?.trim()
  return seen !== undefined && IF_NONE_MATCH.test(seen) ? new Headers({ 'if-none-match': seen }) : undefined
}

async function serve(c: Context<AppEnv>, bucket: R2Bucket, name: string, type: string, cacheControl: string) {
  const onlyIf = ifNoneMatch(c)
  const object = await bucket.get(name, onlyIf ? { onlyIf } : {})
  if (object === null) return notFound(c)
  const headers = new Headers({
    ...PHOTO_HEADERS, 'content-type': type, 'cache-control': cacheControl, etag: object.httpEtag,
  })
  if (!('body' in object)) return new Response(null, { status: 304, headers })
  headers.set('content-length', String(object.size))
  return new Response(object.body, { headers })
}

/** /photos. Hono answers HEAD from these GET routes, without the body. */
export const publicPhotoRoutes = new Hono<AppEnv>()

publicPhotoRoutes.get('/shared/:name', async (c) => {
  const name = c.req.param('name')
  if (!PHOTO_NAME.test(name) || !(await sharedPhotoInUse(c.env.DB, name))) return notFound(c)
  return serve(c, c.env.GYM_PHOTOS, name, 'image/jpeg', SHARED_CACHE)
})

publicPhotoRoutes.get('/exercises/:name', (c) => {
  const name = c.req.param('name')
  if (name === MANIFEST) return serve(c, c.env.EXERCISE_PHOTOS, name, 'application/json', MANIFEST_CACHE)
  return EXERCISE_PHOTO.test(name) ? serve(c, c.env.EXERCISE_PHOTOS, name, 'image/jpeg', EXERCISE_CACHE) : notFound(c)
})
