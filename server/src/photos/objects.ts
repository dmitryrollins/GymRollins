import type { Env } from '../env.ts'
import { inJson } from '../sync/sql.ts'

// Gym photos live in R2; who owns each one lives in D1's photo_objects, as storage.objects.owner_id did. Names are bare
// random <uuid>.jpg: a folder per user in a public URL would give every reader that user's id.

export const SHARED_BUCKET = 'gym-photos'
export const PRIVATE_BUCKET = 'gym-photos-private'
export type GymBucket = typeof SHARED_BUCKET | typeof PRIVATE_BUCKET

/** guard_gym_photo's name rule: a lowercase UUID and .jpg. */
export const PHOTO_NAME = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$/

/**
 * On every photo answer, private and public: the bytes are never sniffed as another type, and a document opened from
 * one runs nothing and loads nothing.
 */
export const PHOTO_HEADERS = {
  'x-content-type-options': 'nosniff',
  'content-security-policy': "default-src 'none'; sandbox",
} as const

export const bucketOf = (env: Env, bucket: GymBucket): R2Bucket =>
  bucket === SHARED_BUCKET ? env.GYM_PHOTOS : env.GYM_PHOTOS_PRIVATE

/**
 * The names among `names` that the caller owns in `bucket` and whose object is stored. A row whose upload never wrote
 * its object (the Worker stopped in between) doesn't count: a listing can't point at a photo nobody can load.
 */
export async function ownedStoredPhotos(
  env: Env,
  userId: string,
  bucket: GymBucket,
  names: readonly string[],
): Promise<Set<string>> {
  const valid = names.filter((name) => PHOTO_NAME.test(name))
  if (valid.length === 0) return new Set()
  const { results } = await env.DB.prepare(
    `SELECT name FROM photo_objects WHERE bucket = ?1 AND owner_id = ?2 AND ${inJson('name', '?3')}`,
  ).bind(bucket, userId, JSON.stringify(valid)).all<{ name: string }>()
  const stored = await Promise.all(results.map(async ({ name }) =>
    (await bucketOf(env, bucket).head(name)) === null ? null : name))
  return new Set(stored.filter((name): name is string => name !== null))
}
