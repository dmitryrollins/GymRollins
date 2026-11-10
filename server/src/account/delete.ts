import { ApiError } from '../http/errors.ts'
import { NOW_SQL } from '../sync/time.ts'

// Deleting an account, after the app removed its gym photos (delete_my_account,
// the Postgres migration 20261030000006_gym_moderation.sql). Shared gyms and listings stay without their author, because
// they describe the gym, but the author's own words go: a listing's notes and photo, the brand and model of an item
// only they used (their listings fall back to the kind's generic item), and the note on every report they filed. Then
// the account goes, and its rows cascade (D1 enforces the foreign keys).

const photosRemain = () => new ApiError(422, 'photos_remain', 'Delete your gym photos first.')

/** Every statement waits for no photo being left, so one that lands mid-way stops them all. */
const NO_PHOTOS = 'NOT EXISTS (SELECT 1 FROM photo_objects WHERE owner_id = ?1)'

const STEPS = [
  `UPDATE gym_equipment SET photo_path = NULL, notes = NULL, updated_at = ${NOW_SQL}
   WHERE added_by = ?1 AND visibility = 'public' AND ${NO_PHOTOS}`,
  `UPDATE gym_equipment SET updated_at = ${NOW_SQL}, item_id = (SELECT g.id FROM equipment_items g
     WHERE g.kind_id = i.kind_id AND g.brand IS NULL AND g.model IS NULL)
   FROM equipment_items i
   WHERE gym_equipment.item_id = i.id AND i.created_by = ?1 AND (i.brand IS NOT NULL OR i.model IS NOT NULL)
     AND gym_equipment.added_by = ?1 AND gym_equipment.visibility = 'public'
     AND NOT EXISTS (SELECT 1 FROM gym_equipment o WHERE o.item_id = i.id AND o.added_by IS NOT ?1) AND ${NO_PHOTOS}`,
  `DELETE FROM equipment_items WHERE created_by = ?1
     AND NOT EXISTS (SELECT 1 FROM gym_equipment e WHERE e.item_id = equipment_items.id) AND ${NO_PHOTOS}`,
  `UPDATE reports SET note = NULL WHERE reporter_id = ?1 AND ${NO_PHOTOS}`,
  // Postgres recounted confirm_count in a trigger when the confirmations cascaded away; D1 has no such trigger.
  `UPDATE gym_equipment SET updated_at = ${NOW_SQL}, confirm_count = (SELECT count(*) FROM equipment_confirmations c
     WHERE c.listing_id = gym_equipment.id AND c.user_id IS NOT ?1)
   WHERE id IN (SELECT listing_id FROM equipment_confirmations WHERE user_id = ?1) AND ${NO_PHOTOS}`,
  `DELETE FROM "user" WHERE id = ?1 AND ${NO_PHOTOS}`,
]

export async function deleteAccount(db: D1Database, userId: string): Promise<void> {
  if (await db.prepare(`SELECT 1 FROM photo_objects WHERE owner_id = ?1 LIMIT 1`).bind(userId).first()) {
    throw photosRemain()
  }
  await db.batch(STEPS.map((sql) => db.prepare(sql).bind(userId)))
  if (await db.prepare('SELECT 1 FROM "user" WHERE id = ?1').bind(userId).first()) throw photosRemain()
}
