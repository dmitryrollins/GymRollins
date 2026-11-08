import type { Env } from '../env.ts'
import { Refusals } from '../gyms/refusals.ts'
import { ApiError } from '../http/errors.ts'
import { DomainLimits } from '../shared/domain-limits.ts'
import { DAY_AGO_SQL, laterStamp, NOW_SQL } from '../sync/time.ts'
import { bucketOf, type GymBucket, PHOTO_NAME, PRIVATE_BUCKET, SHARED_BUCKET } from './objects.ts'

// Gym photos (Storage with guard_gym_photo and the bucket policies, supabase/migrations/20261030000003_gym_photos_
// buckets.sql). R2 and D1 share no transaction, so:
// - an upload claims its photo_objects row first, in one conditional statement that holds every rule, then writes
//   the object; if the object can't be written, the row goes;
// - a delete removes the object first, then the row, so no object is ever left that nobody owns;
// - a write that lands after a delete took its row (the app's delete-all racing an upload) takes its object back.
// A row whose object is missing (the Worker stopped in between) still counts and is still listed by /v1/photos/mine,
// so the app deletes it like any other; its owner uploading the same name finishes it.

/** The buckets' file_size_limit. */
export const MAX_PHOTO_BYTES = 1_000_000

const isJpeg = (bytes: Uint8Array) => bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff

/** What Storage and the trigger checked before anything was written: the name, the size, the type and the bytes. */
function checkUpload(name: string, contentType: string | undefined, bytes: Uint8Array): void {
  if (!PHOTO_NAME.test(name)) throw Refusals.photoBadName()
  if (bytes.byteLength > MAX_PHOTO_BYTES) throw new ApiError(413, 'too_large', 'A photo is at most 1 MB.')
  const type = (contentType ?? '').split(';')[0].trim().toLowerCase()
  if (type !== 'image/jpeg' || !isJpeg(bytes)) throw Refusals.photoNotJpeg()
}

/**
 * guard_gym_photo, as one statement: the owner's account exists, no listing uses the name (not even after its object
 * was deleted, so a removed listing's photo can't come back), and the owner uploaded fewer than 60 today in both
 * buckets. Deleting a photo frees a slot, as it did: only 60 stay stored per day, which is what the limit is for.
 */
const CLAIM = `INSERT INTO photo_objects (bucket, name, owner_id, created_at)
SELECT ?1, ?2, ?3, ${NOW_SQL}
WHERE EXISTS (SELECT 1 FROM "user" WHERE id = ?3)
  AND NOT EXISTS (SELECT 1 FROM gym_equipment WHERE photo_path = ?2)
  AND (SELECT count(*) FROM photo_objects WHERE owner_id = ?3
    AND created_at > ${DAY_AGO_SQL}) < ${DomainLimits.dailyPhotoUploads}
ON CONFLICT (bucket, name) DO NOTHING
RETURNING name`

const WHY_NOT = `SELECT (SELECT owner_id FROM photo_objects WHERE bucket = ?1 AND name = ?2) AS holder,
  EXISTS (SELECT 1 FROM "user" WHERE id = ?3) AS account,
  EXISTS (SELECT 1 FROM gym_equipment WHERE photo_path = ?2) AS in_use`

const HELD = 'SELECT 1 FROM photo_objects WHERE bucket = ?1 AND name = ?2 AND owner_id = ?3'

/**
 * Writes the object, then checks the caller's row is still there. A delete that ran while the put was in flight found
 * no object to remove and took only the row, which would leave an object nobody owns: invisible to /v1/photos/mine and
 * account deletion, and public in the shared bucket. So it goes too, and the upload is refused. Not 409, which the
 * app takes as uploaded.
 */
async function putObject(env: Env, me: string, bucket: GymBucket, name: string, bytes: Uint8Array): Promise<void> {
  await bucketOf(env, bucket).put(name, bytes, { httpMetadata: { contentType: 'image/jpeg' } })
  if ((await env.DB.prepare(HELD).bind(bucket, name, me).first()) !== null) return
  await bucketOf(env, bucket).delete(name)
  throw Refusals.photoMissing()
}

export async function uploadPhoto(
  env: Env,
  me: string,
  bucket: GymBucket,
  name: string,
  contentType: string | undefined,
  bytes: Uint8Array,
): Promise<void> {
  checkUpload(name, contentType, bytes)
  const { results } = await env.DB.prepare(CLAIM).bind(bucket, name, me).all()
  if (results.length === 0) return finishOrRefuse(env, me, bucket, name, bytes)
  try {
    await putObject(env, me, bucket, name, bytes)
  } catch (error) {
    if (error instanceof ApiError) throw error
    // The other half failed: give the row back, unless another upload of this name stored the object meanwhile.
    if ((await bucketOf(env, bucket).head(name)) === null) {
      await env.DB.prepare('DELETE FROM photo_objects WHERE bucket = ?1 AND name = ?2 AND owner_id = ?3')
        .bind(bucket, name, me).run()
    }
    throw error
  }
}

/**
 * The claim wrote nothing. A name already held answers 409, which the app takes as uploaded, unless it is the
 * caller's own unfinished upload: then this finishes it, unless a listing names it by now (a delete that stopped
 * between the object and the row, under a removed listing, must not bring the photo back). Otherwise the refusal, in
 * guard_gym_photo's order.
 */
async function finishOrRefuse(env: Env, me: string, bucket: GymBucket, name: string, bytes: Uint8Array) {
  const why = (await env.DB.prepare(WHY_NOT).bind(bucket, name, me)
    .first<{ holder: string | null; account: number; in_use: number }>())!
  if (why.holder !== null) {
    if (why.holder === me && (await bucketOf(env, bucket).head(name)) === null) {
      if (why.in_use === 1) throw Refusals.photoNameInUse()
      await putObject(env, me, bucket, name, bytes)
      return
    }
    throw Refusals.photoDuplicate()
  }
  if (why.account !== 1) throw Refusals.photoOwnerMissing()
  if (why.in_use === 1) throw Refusals.photoNameInUse()
  throw Refusals.photoDailyLimit()
}

/** An admin may delete a shared photo while a removed public listing names it (moderate_content handed it over). */
const ADMIN_MAY_DELETE = `SELECT 1 WHERE EXISTS (SELECT 1 FROM app_admins WHERE user_id = ?1)
  AND EXISTS (SELECT 1 FROM gym_equipment WHERE photo_path = ?2 AND visibility = 'public' AND status = 'removed')`

/**
 * Deletes a photo the caller may delete. Nothing there is done already; someone else's photo answers not_allowed, so a
 * refused delete is never taken for a finished one.
 */
export async function deletePhoto(env: Env, me: string, bucket: GymBucket, name: string): Promise<void> {
  if (!PHOTO_NAME.test(name)) return
  const row = await env.DB.prepare('SELECT owner_id FROM photo_objects WHERE bucket = ?1 AND name = ?2')
    .bind(bucket, name).first<{ owner_id: string }>()
  if (row === null) return
  const allowed = row.owner_id === me ||
    (bucket === SHARED_BUCKET && (await env.DB.prepare(ADMIN_MAY_DELETE).bind(me, name).first()) !== null)
  if (!allowed) throw Refusals.notAllowed()
  await bucketOf(env, bucket).delete(name)
  await env.DB.prepare('DELETE FROM photo_objects WHERE bucket = ?1 AND name = ?2').bind(bucket, name).run()
}

/** A private photo of the caller's, or null: never anyone else's. */
export async function privatePhoto(env: Env, me: string, name: string): Promise<R2ObjectBody | null> {
  if (!PHOTO_NAME.test(name)) return null
  const owned = await env.DB.prepare('SELECT 1 FROM photo_objects WHERE bucket = ?1 AND name = ?2 AND owner_id = ?3')
    .bind(PRIVATE_BUCKET, name, me).first()
  return owned === null ? null : env.GYM_PHOTOS_PRIVATE.get(name)
}

/**
 * my_gym_photos: the caller's photos in both buckets, by owner and not by listing, so an upload that was never linked
 * is listed too. PostgREST capped it at 1,000 rows; the app lists again after each pass.
 */
export async function myPhotos(db: D1Database, me: string): Promise<{ bucket_id: string; name: string }[]> {
  const { results } = await db.prepare(
    'SELECT bucket AS bucket_id, name FROM photo_objects WHERE owner_id = ?1 ORDER BY bucket, name LIMIT 1000',
  ).bind(me).all<{ bucket_id: string; name: string }>()
  return results
}

/**
 * detach_my_gym_photos, for an account deletion that failed after the objects were removed: the caller's private
 * listings and the public ones they added lose the name, and their edit time moves so other phones take the change.
 * A removed listing keeps its name: it is what lets an admin delete the photo (ADMIN_MAY_DELETE), so detaching it
 * first would leave the photo stored for good.
 */
export async function detachMyPhotos(db: D1Database, me: string): Promise<void> {
  await db.prepare(
    `UPDATE gym_equipment SET photo_path = NULL, client_updated_at = max(client_updated_at, ${NOW_SQL}),
       updated_at = ${laterStamp('gym_equipment.updated_at', NOW_SQL)}
     WHERE photo_path IS NOT NULL AND ((visibility = 'private' AND owner_id = ?1)
       OR (visibility = 'public' AND added_by = ?1 AND status <> 'removed'))`,
  ).bind(me).run()
}

/**
 * Whether the shared bucket may serve `name`: a public listing that isn't removed names it. An upload no listing uses
 * isn't served (the bucket is no free file host), and neither is a removed listing's photo while it waits for an
 * admin's delete. Items take their photo from such a listing (catalogue.ts publicItems), so every photo the app shows
 * is served. One photo backs at most one listing (the gym_equipment_photo index).
 */
export async function sharedPhotoInUse(db: D1Database, name: string): Promise<boolean> {
  return (await db.prepare(
    "SELECT 1 FROM gym_equipment WHERE photo_path = ?1 AND visibility = 'public' AND status <> 'removed'",
  ).bind(name).first()) !== null
}
