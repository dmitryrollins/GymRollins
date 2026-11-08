import type { Env } from '../env.ts'
import { ApiError } from '../http/errors.ts'
import { badRequest, boolOr, intOrNull, numberOrNull, objectBody, textOf, textOrNull, uuidOf } from '../http/input.ts'
import { ownedStoredPhotos, SHARED_BUCKET } from '../photos/objects.ts'
import { DomainLimits } from '../shared/domain-limits.ts'
import { DAY_AGO_SQL, laterStamp, NOW_SQL } from '../sync/time.ts'
import { PLACE_ID } from './catalogue.ts'
import { parseLoads } from './loads.ts'
import { Refusals } from './refusals.ts'
import { foldKey, requireCleanText, trimmedOrNull, trimSpaces } from './text.ts'
import { blockedAuthor } from './visibility.ts'

// Writing public gym data: find_or_create_gym, share_listing and confirm_listing (supabase/migrations/
// 20261030000002_gym_functions.sql). Each daily limit sits in the one statement or batch that writes, so requests that
// arrive together can't each see a count under it: D1 runs writes one at a time. When nothing was written, a read
// afterwards says why.

type Row = Record<string, unknown>

// ---- find_or_create_gym ----

export interface GymPlace {
  readonly mapsPlaceId: string
  readonly name: string
  readonly address: string | null
  readonly latitude: number | null
  readonly longitude: number | null
}

export function parsePlace(body: unknown): GymPlace {
  const b = objectBody(body)
  if (typeof b.maps_place_id !== 'string' || !PLACE_ID.test(b.maps_place_id)) throw badRequest('invalid place')
  return {
    mapsPlaceId: b.maps_place_id,
    name: textOf(b.name, 'name'),
    address: textOrNull(b.address, 'address'),
    latitude: numberOrNull(b.latitude, 'latitude'),
    longitude: numberOrNull(b.longitude, 'longitude'),
  }
}

const FIND_GYM = "SELECT id FROM gyms WHERE visibility = 'public' AND status <> 'removed' AND maps_place_id = ?1"

/** A removed gym gives its place back (the partial unique index), so one bad gym can't hold a real place forever. */
const CREATE_GYM = `INSERT INTO gyms (id, visibility, name, address, latitude, longitude, maps_place_id, created_by,
    status, client_updated_at, created_at, updated_at)
SELECT ?1, 'public', ?2, ?3, ?4, ?5, ?6, ?7, 'active', ${NOW_SQL}, ${NOW_SQL}, ${NOW_SQL}
WHERE (SELECT count(*) FROM gyms WHERE visibility = 'public' AND created_by = ?7
  AND created_at > ${DAY_AGO_SQL}) < ${DomainLimits.dailyGymCreations}
ON CONFLICT (maps_place_id) WHERE visibility = 'public' AND status <> 'removed' DO NOTHING
RETURNING id`

/** The public gym for a Maps place, created on the first share. The first caller's text stands. */
export async function findOrCreateGym(db: D1Database, me: string, place: GymPlace): Promise<string> {
  const found = await db.prepare(FIND_GYM).bind(place.mapsPlaceId).first<{ id: string }>()
  if (found) return found.id
  const name = trimSpaces(place.name)
  const address = trimmedOrNull(place.address)
  requireCleanText(name, 'name')
  requireCleanText(address, 'address')
  const { results } = await db.prepare(CREATE_GYM)
    .bind(crypto.randomUUID(), name, address, place.latitude, place.longitude, place.mapsPlaceId, me)
    .all<{ id: string }>()
  if (results.length > 0) return results[0].id
  // Someone else created it in the meantime, or the day's 10 are used up.
  const raced = await db.prepare(FIND_GYM).bind(place.mapsPlaceId).first<{ id: string }>()
  if (raced) return raced.id
  throw Refusals.dailyLimit()
}

// ---- share_listing ----

export interface ShareInput {
  readonly listingId: string
  readonly gymId: string
  readonly kindId: string
  readonly brand: string | null
  readonly model: string | null
  readonly loads: unknown
  readonly quantity: number | null
  readonly notes: string | null
  readonly photoPath: string | null
  readonly forceNew: boolean
}

export function parseShare(body: unknown): ShareInput {
  const b = objectBody(body)
  return {
    listingId: uuidOf(b.listing_id, 'listing_id'),
    gymId: uuidOf(b.gym_id, 'gym_id'),
    kindId: textOf(b.kind_id, 'kind_id'),
    brand: textOrNull(b.brand, 'brand'),
    model: textOrNull(b.model, 'model'),
    loads: b.loads,
    quantity: intOrNull(b.quantity, 'quantity'),
    notes: textOrNull(b.notes, 'notes'),
    photoPath: textOrNull(b.photo_path, 'photo_path'),
    forceNew: boolOr(b.force_new, 'force_new', false),
  }
}

export type ShareAnswer =
  | { readonly status: 'created'; readonly listing_id: string }
  | { readonly status: 'duplicates'; readonly listings: readonly Row[] }

/**
 * What every write of a share repeats, so the item and the listing are written together or not at all:
 * ?1 the caller, ?2 the listing id, ?3 the gym, ?6 the photo.
 */
const SHARE_GATE = `(SELECT count(*) FROM gym_equipment WHERE visibility = 'public' AND added_by = ?1
    AND created_at > ${DAY_AGO_SQL}) < ${DomainLimits.dailyShares}
  AND (?6 IS NULL OR (NOT EXISTS (SELECT 1 FROM gym_equipment WHERE photo_path = ?6)
    AND EXISTS (SELECT 1 FROM photo_objects WHERE bucket = 'gym-photos' AND name = ?6 AND owner_id = ?1)))
  AND (SELECT count(*) FROM gym_equipment WHERE gym_id = ?3 AND visibility = 'public' AND status = 'active'
    AND deleted_at IS NULL) < ${DomainLimits.gymActiveListingsMax}
  AND EXISTS (SELECT 1 FROM gyms WHERE id = ?3 AND visibility = 'public' AND status = 'active')
  AND NOT EXISTS (SELECT 1 FROM gym_equipment WHERE id = ?2)`

/** ensure_equipment_item: ?4 the kind, ?5 the brand, ?7 the model, ?8 and ?9 their fold keys, ?10 a new id. */
const ENSURE_ITEM = `INSERT INTO equipment_items (id, kind_id, brand, model, brand_key, model_key, created_by, status,
    created_at, updated_at)
SELECT ?10, ?4, ?5, ?7, ?8, ?9, ?1, 'active', ${NOW_SQL}, ${NOW_SQL} WHERE ${SHARE_GATE}
ON CONFLICT DO NOTHING`

/** The listing, on the item of that identity: ?11 the loads, ?12 the quantity, ?13 the notes. */
const INSERT_LISTING = `INSERT INTO gym_equipment (id, gym_id, item_id, visibility, photo_path, loads, quantity, notes,
    added_by, status, confirm_count, client_updated_at, created_at, updated_at)
SELECT ?2, ?3, (SELECT id FROM equipment_items WHERE kind_id = ?4 AND coalesce(brand_key, '') = coalesce(?8, '')
    AND coalesce(model_key, '') = coalesce(?9, '')),
  'public', ?6, ?11, ?12, ?13, ?1, 'active', 0, ${NOW_SQL}, ${NOW_SQL}, ${NOW_SQL}
WHERE ${SHARE_GATE}`

/** The gym's active listings of a kind, by authors the caller hasn't blocked: ?1 the caller, ?2 the gym, ?3 the kind. */
const DUPLICATES = `SELECT e.id, i.kind_id, i.brand, i.model, e.photo_path, e.loads, e.quantity, e.confirm_count
FROM gym_equipment e JOIN equipment_items i ON i.id = e.item_id
WHERE e.gym_id = ?2 AND e.visibility = 'public' AND e.status = 'active' AND i.kind_id = ?3 AND i.status = 'active'
  AND NOT ${blockedAuthor('e.added_by', '?1')} AND NOT ${blockedAuthor('i.created_by', '?1')}
ORDER BY e.confirm_count DESC, e.id`

/** Why a share wrote nothing: ?1 the caller, ?2 the listing id, ?3 the gym, ?4 the photo. */
const WHY_NOT = `SELECT
  EXISTS (SELECT 1 FROM gyms WHERE id = ?3 AND visibility = 'public' AND status = 'active') AS shareable,
  (?4 IS NULL OR EXISTS (SELECT 1 FROM photo_objects WHERE bucket = 'gym-photos' AND name = ?4 AND owner_id = ?1))
    AS photo_owned,
  (SELECT count(*) FROM gym_equipment WHERE visibility = 'public' AND added_by = ?1 AND created_at > ${DAY_AGO_SQL})
    AS shared_today,
  (?4 IS NOT NULL AND EXISTS (SELECT 1 FROM gym_equipment WHERE photo_path = ?4)) AS photo_used,
  (SELECT count(*) FROM gym_equipment WHERE gym_id = ?3 AND visibility = 'public' AND status = 'active'
    AND deleted_at IS NULL) AS at_gym,
  (SELECT added_by FROM gym_equipment WHERE id = ?2) AS taken_by`

interface ListingOwner {
  readonly added_by: string | null
  readonly visibility: string
}

/** A listing with this id already exists: a retry of the caller's own share, or not theirs to take over. */
function sameShareOrRefuse(listing: ListingOwner, me: string, id: string): ShareAnswer {
  if (listing.added_by !== me || listing.visibility !== 'public') throw Refusals.notAllowed()
  return { status: 'created', listing_id: id }
}

/**
 * Creates a public listing, or answers the gym's active listings of that kind when there are some and force_new is
 * false. The listing id is the phone's, so a retry after a lost answer finds the listing instead of adding another.
 * The photo must be the caller's own upload, stored and unused, so a listing can't borrow someone else's image.
 */
export async function shareListing(env: Env, me: string, input: ShareInput): Promise<ShareAnswer> {
  const db = env.DB
  const existing = await db.prepare('SELECT added_by, visibility FROM gym_equipment WHERE id = ?1')
    .bind(input.listingId).first<ListingOwner>()
  if (existing) return sameShareOrRefuse(existing, me, input.listingId)
  const gym = await db.prepare("SELECT 1 FROM gyms WHERE id = ?1 AND visibility = 'public' AND status = 'active'")
    .bind(input.gymId).first()
  if (!gym) throw Refusals.gymNotShareable()
  if (input.photoPath !== null &&
    !(await ownedStoredPhotos(env, me, SHARED_BUCKET, [input.photoPath])).has(input.photoPath)) {
    throw Refusals.photoMissing()
  }
  const loads = parseLoads(input.loads)
  if (loads === null) throw badRequest('invalid loads')
  if (!input.forceNew) {
    const { results } = await db.prepare(DUPLICATES).bind(me, input.gymId, input.kindId).all<Row>()
    if (results.length > 0) {
      return { status: 'duplicates', listings: results.map((r) => ({ ...r, loads: JSON.parse(String(r.loads)) })) }
    }
  }
  if (!(await db.prepare('SELECT 1 FROM equipment_kinds WHERE id = ?1').bind(input.kindId).first())) {
    throw badRequest('unknown kind')
  }
  const brand = trimmedOrNull(input.brand)
  const model = trimmedOrNull(input.model)
  const notes = trimmedOrNull(input.notes)
  requireCleanText(brand, 'brand')
  requireCleanText(model, 'model')
  requireCleanText(notes, 'notes', true)
  const gate = [me, input.listingId, input.gymId, input.kindId, brand, input.photoPath, model, foldKey(brand), foldKey(model)]
  const [, , written] = await db.batch([
    db.prepare(ENSURE_ITEM).bind(...gate, crypto.randomUUID()),
    db.prepare(INSERT_LISTING).bind(...gate, null, JSON.stringify(loads), input.quantity ?? 1, notes),
    db.prepare('SELECT added_by, visibility FROM gym_equipment WHERE id = ?1').bind(input.listingId),
  ])
  const listing = written.results[0] as ListingOwner | undefined
  if (listing !== undefined) return sameShareOrRefuse(listing, me, input.listingId)
  throw await whyNotShared(db, me, input)
}

/** The refusal share_listing would have raised, in its order. */
async function whyNotShared(db: D1Database, me: string, input: ShareInput): Promise<ApiError> {
  const why = (await db.prepare(WHY_NOT).bind(me, input.listingId, input.gymId, input.photoPath).first<{
    shareable: number
    photo_owned: number
    shared_today: number
    photo_used: number
    at_gym: number
    taken_by: string | null
  }>())!
  if (why.taken_by !== null) return Refusals.notAllowed()
  if (why.shareable !== 1) return Refusals.gymNotShareable()
  if (why.photo_owned !== 1) return Refusals.photoMissing()
  if (why.shared_today >= DomainLimits.dailyShares) return Refusals.dailyLimit()
  if (why.photo_used === 1) return Refusals.photoInUse()
  if (why.at_gym >= DomainLimits.gymActiveListingsMax) return Refusals.gymFull()
  return new ApiError(503, 'try_again', 'The share could not be saved. Try again.')
}

// ---- confirm_listing ----

/** A public listing that is active under an active gym and item, by an author the caller (?2) hasn't blocked. */
const CONFIRMABLE = `SELECT e.added_by, e.confirm_count FROM gym_equipment e
WHERE e.id = ?1 AND e.visibility = 'public' AND e.status = 'active'
  AND EXISTS (SELECT 1 FROM gyms g WHERE g.id = e.gym_id AND g.status = 'active')
  AND EXISTS (SELECT 1 FROM equipment_items i WHERE i.id = e.item_id AND i.status = 'active')
  AND NOT ${blockedAuthor('e.added_by', '?2')}`

const CONFIRM = `INSERT INTO equipment_confirmations (listing_id, user_id, created_at)
SELECT ?1, ?2, ${NOW_SQL}
WHERE (SELECT count(*) FROM equipment_confirmations WHERE user_id = ?2
  AND created_at > ${DAY_AGO_SQL}) < ${DomainLimits.dailyConfirmations}
ON CONFLICT DO NOTHING`

/** gym_equipment_count_confirmations, which was a trigger; updated_at moves as set_updated_at moved it. */
const RECOUNT = `UPDATE gym_equipment SET
  confirm_count = (SELECT count(*) FROM equipment_confirmations WHERE listing_id = ?1),
  updated_at = ${laterStamp('gym_equipment.updated_at', NOW_SQL)}
WHERE id = ?1 AND confirm_count <> (SELECT count(*) FROM equipment_confirmations WHERE listing_id = ?1)`

const AFTER_CONFIRM = `SELECT confirm_count,
  EXISTS (SELECT 1 FROM equipment_confirmations WHERE listing_id = ?1 AND user_id = ?2) AS confirmed
FROM gym_equipment WHERE id = ?1`

/** "Yes, that's it (+1)". Idempotent; the author's own listing already counts for them. Answers the count. */
export async function confirmListing(db: D1Database, me: string, listingId: string): Promise<number> {
  const listing = await db.prepare(CONFIRMABLE).bind(listingId, me)
    .first<{ added_by: string | null; confirm_count: number }>()
  if (!listing) throw Refusals.unknownListing()
  if (listing.added_by === me) return listing.confirm_count
  const [, , after] = await db.batch([
    db.prepare(CONFIRM).bind(listingId, me),
    db.prepare(RECOUNT).bind(listingId),
    db.prepare(AFTER_CONFIRM).bind(listingId, me),
  ])
  const row = after.results[0] as { confirm_count: number; confirmed: number }
  if (row.confirmed !== 1) throw Refusals.dailyLimit()
  return row.confirm_count
}
