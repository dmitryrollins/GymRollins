import { badRequest } from '../http/input.ts'
import { gymReadable, itemReadable, listingReadable } from './visibility.ts'

// What the app reads of the shared catalogue: the public_gyms, public_gym_equipment and public_equipment_items views
// (supabase/migrations/20261030000001_gyms.sql) under the read policies they ran under, for the caller (?1). Author ids
// never leave the server: is_mine, confirmed_by_me and item_is_mine say what is the caller's.

/** find_or_create_gym's place rule, also the gyms CHECK. */
export const PLACE_ID = /^[A-Za-z0-9._:+/=-]{1,200}$/
export const KIND_ID = /^[a-z0-9-]{1,40}$/
/** A gym holds at most 300 active public listings, so the app reads one page, two at most. */
export const LISTINGS_PAGE = 500
/** PostgREST's max_rows, which capped the items view. */
const ITEMS_MAX = 1000
const OFFSET_MAX = 100_000

type Row = Record<string, unknown>
const flag = (value: unknown) => value === 1

export interface Page {
  readonly offset: number
  readonly limit: number
}

function whole(raw: string | undefined, name: string, fallback: number, min: number, max: number): number {
  if (raw === undefined) return fallback
  const value = /^\d+$/.test(raw) ? Number(raw) : Number.NaN
  if (!(value >= min && value <= max)) throw badRequest(`${name} must be ${min} to ${max}.`)
  return value
}

/** `?offset=&limit=`, as PostgREST's range: up to 500 listings a page. */
export const pageOf = (query: Record<string, string | undefined>): Page => ({
  offset: whole(query.offset, 'offset', 0, 0, OFFSET_MAX),
  limit: whole(query.limit, 'limit', LISTINGS_PAGE, 1, LISTINGS_PAGE),
})

/** The public gym of a Maps place, newest first, as the app asked public_gyms; null when the caller can't see one. */
export async function publicGym(db: D1Database, me: string, place: string): Promise<Row | null> {
  if (!PLACE_ID.test(place)) throw badRequest('invalid place')
  const row = await db.prepare(
    `SELECT g.id, g.name, g.address, g.latitude, g.longitude, g.maps_place_id, g.status, g.created_at, g.updated_at,
       coalesce(g.created_by = ?1, 0) AS is_mine
     FROM gyms g
     WHERE g.visibility = 'public' AND g.maps_place_id = ?2 AND g.status <> 'removed' AND ${gymReadable('g', '?1')}
     ORDER BY g.created_at DESC LIMIT 1`,
  ).bind(me, place).first<Row>()
  return row === null ? null : { ...row, is_mine: flag(row.is_mine) }
}

/** One page of a gym's public listings, oldest first (public_gym_equipment, ordered by created_at and id). */
export async function publicListings(db: D1Database, me: string, gymId: string, page: Page): Promise<Row[]> {
  const { results } = await db.prepare(
    `SELECT e.id, e.gym_id, e.item_id, i.kind_id, i.brand, i.model, e.photo_path, e.loads, e.quantity, e.notes,
       e.status, e.confirm_count, e.created_at, e.updated_at, coalesce(e.added_by = ?1, 0) AS is_mine,
       EXISTS (SELECT 1 FROM equipment_confirmations c WHERE c.listing_id = e.id AND c.user_id = ?1) AS confirmed_by_me,
       coalesce(i.created_by = ?1, 0) AS item_is_mine
     FROM gym_equipment e JOIN equipment_items i ON i.id = e.item_id JOIN gyms g ON g.id = e.gym_id
     WHERE e.gym_id = ?2 AND e.visibility = 'public' AND ${listingReadable('e', '?1')} AND ${itemReadable('i', '?1')}
       AND ${gymReadable('g', '?1')}
     ORDER BY e.created_at, e.id LIMIT ?3 OFFSET ?4`,
  ).bind(me, gymId, page.limit, page.offset).all<Row>()
  return results.map((row) => ({
    ...row,
    loads: JSON.parse(String(row.loads)),
    is_mine: flag(row.is_mine),
    confirmed_by_me: flag(row.confirmed_by_me),
    item_is_mine: flag(row.item_is_mine),
  }))
}

/**
 * A kind's active items the caller can read (public_equipment_items). An item's photo is its best shared listing's:
 * the most confirmed, then the oldest. It is never stored on the item, so a listing that is removed, flagged or loses
 * its photo, or whose author is blocked, simply lets the next one show.
 */
export async function publicItems(db: D1Database, me: string, kind: string): Promise<Row[]> {
  if (!KIND_ID.test(kind)) throw badRequest('invalid kind')
  const { results } = await db.prepare(
    `SELECT i.id, i.kind_id, i.brand, i.model, p.photo_path, p.id AS photo_listing_id, i.status, i.created_at,
       i.updated_at, coalesce(i.created_by = ?1, 0) AS is_mine,
       (SELECT count(DISTINCT c.gym_id) FROM gym_equipment c WHERE c.item_id = i.id AND c.visibility = 'public'
          AND c.status = 'active' AND ${listingReadable('c', '?1')}) AS gym_count
     FROM equipment_items i
     LEFT JOIN gym_equipment p ON p.id = (SELECT b.id FROM gym_equipment b WHERE b.item_id = i.id
       AND b.visibility = 'public' AND b.status = 'active' AND b.photo_path IS NOT NULL AND ${listingReadable('b', '?1')}
       ORDER BY b.confirm_count DESC, b.created_at, b.id LIMIT 1)
     WHERE i.kind_id = ?2 AND i.status = 'active' AND ${itemReadable('i', '?1')}
     ORDER BY i.id LIMIT ${ITEMS_MAX}`,
  ).bind(me, kind).all<Row>()
  return results.map((row) => ({ ...row, is_mine: flag(row.is_mine) }))
}
