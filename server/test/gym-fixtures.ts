import { env } from 'cloudflare:workers'
import { foldKey } from '../src/gyms/text.ts'
import { NOW_SQL } from '../src/sync/time.ts'

// Gym rows written straight into D1. Plan 28 adds the routes that create them.

const T = '2026-11-07T10:00:00.000000Z'
type Status = 'active' | 'flagged' | 'removed'

export async function insertGym(g: {
  visibility: 'public' | 'private'
  owner?: string
  createdBy?: string
  status?: Status
}): Promise<string> {
  const id = crypto.randomUUID()
  await env.DB.prepare(
    'INSERT INTO gyms (id, visibility, owner_id, name, maps_place_id, created_by, status, client_updated_at, ' +
      "created_at, updated_at) VALUES (?1, ?2, ?3, 'Test gym', ?4, ?5, ?6, ?7, ?7, ?7)",
  ).bind(
    id,
    g.visibility,
    g.visibility === 'private' ? (g.owner ?? null) : null,
    g.visibility === 'public' ? `place-${id}` : null,
    g.createdBy ?? null,
    g.status ?? 'active',
    T,
  ).run()
  return id
}

/** The seeded generic item of a kind. */
export async function genericItem(kind = 'dumbbells'): Promise<string> {
  const row = await env.DB.prepare('SELECT id FROM equipment_items WHERE kind_id = ?1 AND brand IS NULL AND model IS NULL')
    .bind(kind).first<{ id: string }>()
  return row!.id
}

export async function insertItem(i: { brand: string; model: string; createdBy: string; kind?: string }): Promise<string> {
  const id = crypto.randomUUID()
  await env.DB.prepare(
    'INSERT INTO equipment_items (id, kind_id, brand, model, brand_key, model_key, created_by, created_at, updated_at) ' +
      'VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)',
  ).bind(id, i.kind ?? 'dumbbells', i.brand, i.model, foldKey(i.brand), foldKey(i.model), i.createdBy, T).run()
  return id
}

export async function insertListing(l: {
  gym: string
  item: string
  visibility: 'public' | 'private'
  owner?: string
  addedBy?: string
  status?: Status
  notes?: string
  photo?: string
  createdAt?: string
}): Promise<string> {
  const id = crypto.randomUUID()
  await env.DB.prepare(
    'INSERT INTO gym_equipment (id, gym_id, item_id, visibility, owner_id, photo_path, notes, added_by, status, ' +
      'client_updated_at, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?10)',
  ).bind(
    id,
    l.gym,
    l.item,
    l.visibility,
    l.visibility === 'private' ? (l.owner ?? null) : null,
    l.photo ?? null,
    l.notes ?? null,
    l.addedBy ?? null,
    l.status ?? 'active',
    T,
    l.createdAt ?? T,
  ).run()
  return id
}

export async function setStatus(table: 'gyms' | 'gym_equipment' | 'equipment_items', id: string, status: Status) {
  await env.DB.prepare(`UPDATE ${table} SET status = ?2 WHERE id = ?1`).bind(id, status).run()
}

export async function makeAdmin(userId: string) {
  await env.DB.prepare('INSERT INTO app_admins (user_id, created_at) VALUES (?1, ?2)').bind(userId, T).run()
}

export async function block(blocker: string, blocked: string) {
  await env.DB.prepare('INSERT INTO user_blocks (blocker_id, blocked_id, created_at) VALUES (?1, ?2, ?3)')
    .bind(blocker, blocked, T).run()
}

/** A photo object the account still owns (plan 28 writes these on upload). */
export async function insertPhoto(owner: string, bucket: 'gym-photos' | 'gym-photos-private' = 'gym-photos-private') {
  const name = `${crypto.randomUUID()}.jpg`
  await env.DB.prepare('INSERT INTO photo_objects (bucket, name, owner_id, created_at) VALUES (?1, ?2, ?3, ?4)')
    .bind(bucket, name, owner, T).run()
  return name
}

/** A confirmation and its count on the listing, as confirm_listing and its trigger left them. */
export async function confirm(listing: string, userId: string) {
  await env.DB.batch([
    env.DB.prepare('INSERT INTO equipment_confirmations (listing_id, user_id, created_at) VALUES (?1, ?2, ?3)')
      .bind(listing, userId, T),
    env.DB.prepare('UPDATE gym_equipment SET confirm_count = confirm_count + 1 WHERE id = ?1').bind(listing),
  ])
}

export async function insertReport(r: {
  reporter: string
  targetType: 'gym' | 'item' | 'listing'
  targetId: string
  note: string
}): Promise<string> {
  const id = crypto.randomUUID()
  await env.DB.prepare(
    "INSERT INTO reports (id, target_type, target_id, reporter_id, reason, note, created_at) VALUES (?1, ?2, ?3, ?4, 'other', ?5, ?6)",
  ).bind(id, r.targetType, r.targetId, r.reporter, r.note, T).run()
  return id
}

/** The smallest bytes the server takes as a JPEG. */
export const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10])

/** A photo the account uploaded: its photo_objects row and, unless `stored` is false, its R2 object. */
export async function uploadedPhoto(
  owner: string,
  bucket: 'gym-photos' | 'gym-photos-private',
  options: { stored?: boolean } = {},
): Promise<string> {
  const name = await insertPhoto(owner, bucket)
  if (options.stored ?? true) {
    await (bucket === 'gym-photos' ? env.GYM_PHOTOS : env.GYM_PHOTOS_PRIVATE).put(name, JPEG)
  }
  return name
}

/** A timestamp two days back: outside every daily limit. */
export const DAYS_AGO = '2020-01-01T00:00:00.000000Z'

/** `count` public gyms the account created just now, as find_or_create_gym would have. */
export async function gymsCreatedToday(userId: string, count: number) {
  const ids = Array.from({ length: count }, () => crypto.randomUUID())
  await env.DB.prepare(
    `INSERT INTO gyms (id, visibility, name, maps_place_id, created_by, status, client_updated_at, created_at, updated_at)
     SELECT value, 'public', 'Earlier gym', 'place-' || value, ?2, 'active', ${NOW_SQL}, ${NOW_SQL}, ${NOW_SQL}
     FROM json_each(?1)`,
  ).bind(JSON.stringify(ids), userId).run()
  return ids
}

/** `count` active public listings at a gym, added just now by `addedBy`, as share_listing would have. */
export async function listingsSharedToday(gym: string, addedBy: string, count: number) {
  const ids = Array.from({ length: count }, () => crypto.randomUUID())
  await env.DB.prepare(
    `INSERT INTO gym_equipment (id, gym_id, item_id, visibility, added_by, status, client_updated_at, created_at,
       updated_at)
     SELECT value, ?2, ?3, 'public', ?4, 'active', ${NOW_SQL}, ${NOW_SQL}, ${NOW_SQL} FROM json_each(?1)`,
  ).bind(JSON.stringify(ids), gym, await genericItem(), addedBy).run()
  return ids
}

/** Moves every row the account wrote to `table` (by `column`) two days back. */
export async function agedRows(table: string, column: string, userId: string) {
  await env.DB.prepare(`UPDATE ${table} SET created_at = ?2 WHERE ${column} = ?1`).bind(userId, DAYS_AGO).run()
}

/** An account with no session, as an author to block: cheaper than signing up. */
export async function insertUser(): Promise<string> {
  const id = crypto.randomUUID()
  await env.DB.prepare(
    'INSERT INTO "user" (id, name, email, "emailVerified", "createdAt", "updatedAt") VALUES (?1, ?2, ?3, 0, ?4, ?4)',
  ).bind(id, 'Fixture', `f-${id}@test.local`, T).run()
  return id
}

/** `count` reports the account filed just now, on targets nobody else reported. */
export async function reportsToday(userId: string, count: number) {
  const ids = Array.from({ length: count }, () => crypto.randomUUID())
  await env.DB.prepare(
    `INSERT INTO reports (id, target_type, target_id, reporter_id, reason, created_at)
     SELECT value, 'listing', value, ?2, 'spam', ${NOW_SQL} FROM json_each(?1)`,
  ).bind(JSON.stringify(ids), userId).run()
}

/** `count` accounts the user blocked just now. */
export async function blocksToday(userId: string, count: number): Promise<string[]> {
  const blocked = await Promise.all(Array.from({ length: count }, () => insertUser()))
  await env.DB.prepare(
    `INSERT INTO user_blocks (blocker_id, blocked_id, created_at) SELECT ?2, value, ${NOW_SQL} FROM json_each(?1)`,
  ).bind(JSON.stringify(blocked), userId).run()
  return blocked
}

/** `count` unblock-alls the account made just now. */
export async function unblocksToday(userId: string, count: number) {
  for (let i = 0; i < count; i++) {
    await env.DB.prepare(`INSERT INTO gym_unblocks (user_id, created_at) VALUES (?1, ${NOW_SQL})`).bind(userId).run()
  }
}

/**
 * `db`, with `change` run just before its first batch: another request landing between a function's check and its
 * write, made deterministic.
 */
export function changedBeforeBatch(db: D1Database, change: () => Promise<unknown>): D1Database {
  let pending = true
  return new Proxy(db, {
    get(target, key) {
      if (key === 'batch') {
        return async (statements: D1PreparedStatement[]) => {
          if (pending) {
            pending = false
            await change()
          }
          return target.batch(statements)
        }
      }
      const value: unknown = Reflect.get(target, key, target)
      return typeof value === 'function' ? value.bind(target) : value
    },
  })
}

/** `count` photos the account uploaded just now (rows only), towards the daily limit. */
export async function photosToday(owner: string, count: number, bucket: 'gym-photos' | 'gym-photos-private') {
  const names = Array.from({ length: count }, () => `${crypto.randomUUID()}.jpg`)
  await env.DB.prepare(
    `INSERT INTO photo_objects (bucket, name, owner_id, created_at) SELECT ?2, value, ?3, ${NOW_SQL} FROM json_each(?1)`,
  ).bind(JSON.stringify(names), bucket, owner).run()
  return names
}
