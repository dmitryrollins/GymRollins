import { parseLoads } from '../gyms/loads.ts'
import { Refusals } from '../gyms/refusals.ts'
import { isCleanText } from '../gyms/text.ts'
import { ownedStoredPhotos, PRIVATE_BUCKET } from '../photos/objects.ts'
import { RowError } from './columns.ts'
import type { PushContext } from './entities.ts'
import { inJson } from './sql.ts'

// The rules Postgres kept in CHECKs and triggers on private gyms and listings (supabase/migrations/
// 20261030000001_gyms.sql): clean_text on their text, valid_loads, and gym_equipment_check. The caps are triggers in
// migrations/0005_gyms_photos.sql.

type Row = Record<string, unknown>

function requireClean(row: Row, label: string, column: string, lines = false): void {
  const value = row[column]
  if (typeof value === 'string' && !isCleanText(value, lines)) {
    throw new RowError(`${label}.${column} has hidden or control characters`)
  }
}

/** A private gym: no hidden or control characters in its name or address. */
export function preparePrivateGym(row: Row, label: string): Row {
  requireClean(row, label, 'name')
  requireClean(row, label, 'address')
  return row
}

/** A private listing: clean text (notes may have lines), and loads the app can read, stored compact. */
export function preparePrivateListing(row: Row, label: string): Row {
  requireClean(row, label, 'notes', true)
  requireClean(row, label, 'private_brand')
  requireClean(row, label, 'private_model')
  const loads = parseLoads(JSON.parse(String(row.loads)))
  if (loads === null) throw new RowError(`${label}.loads is not a valid loads`)
  return { ...row, loads: JSON.stringify(loads) }
}

const strings = (values: readonly unknown[]) => [...new Set(values.filter((v): v is string => typeof v === 'string'))]

/**
 * gym_equipment_check for the caller's private listings, before anything is written:
 * - the gym is public or the caller's own private gym; any other reads as "unknown gym", so ids can't be probed;
 * - the item is its kind's generic one (brand and model stay on the listing, out of the shared catalogue);
 * - a photo that is new or changed is the caller's own upload to gym-photos-private, already stored.
 */
export async function checkPrivateListings(ctx: PushContext, rows: readonly Row[]): Promise<void> {
  const db = ctx.env.DB
  const listOf = (column: string) => JSON.stringify(strings(rows.map((r) => r[column])))
  const [gyms, items, stored] = await db.batch<{ id: string; photo_path: string | null }>([
    db.prepare(
      `SELECT id, NULL AS photo_path FROM gyms WHERE ${inJson('id', '?1')} AND (visibility = 'public' OR owner_id = ?2)`,
    ).bind(listOf('gym_id'), ctx.userId),
    db.prepare(
      `SELECT id, NULL AS photo_path FROM equipment_items WHERE ${inJson('id', '?1')} AND brand IS NULL AND model IS NULL`,
    ).bind(listOf('item_id')),
    db.prepare(`SELECT id, photo_path FROM gym_equipment WHERE ${inJson('id', '?1')}`).bind(listOf('id')),
  ])
  const knownGyms = new Set(gyms.results.map((r) => r.id))
  const genericItems = new Set(items.results.map((r) => r.id))
  rows.forEach((row, index) => {
    if (!knownGyms.has(row.gym_id as string)) throw new RowError(`rows[${index}].gym_id: unknown gym`)
    if (!genericItems.has(row.item_id as string)) {
      throw new RowError(`rows[${index}].item_id: a private listing uses a generic item`)
    }
  })
  const before = new Map(stored.results.map((r) => [r.id, r.photo_path]))
  const changed = strings(rows.filter((r) => r.photo_path !== null && r.photo_path !== before.get(r.id as string))
    .map((r) => r.photo_path))
  if (changed.length === 0) return
  const owned = await ownedStoredPhotos(ctx.env, ctx.userId, PRIVATE_BUCKET, changed)
  if (changed.some((name) => !owned.has(name))) throw Refusals.photoMissing()
}
