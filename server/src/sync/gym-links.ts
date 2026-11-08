import { gymLinkSurvives, gymReadable, listingLinkSurvives, listingReadable } from '../gyms/visibility.ts'

/** The ids among `ids` whose row in `table` (as `alias`) meets `condition`, which reads the caller as ?2. */
async function idsWhere(
  db: D1Database,
  table: string,
  alias: string,
  condition: string,
  userId: string,
  ids: readonly string[],
): Promise<Set<string>> {
  if (ids.length === 0) return new Set()
  const { results } = await db.prepare(
    `SELECT ${alias}.id FROM ${table} ${alias} WHERE ${alias}.id IN (SELECT value FROM json_each(?1)) AND ${condition}`,
  ).bind(JSON.stringify(ids), userId).all<{ id: string }>()
  return new Set(results.map((r) => r.id))
}

/**
 * The gym a saved workout keeps. A link the phone left out or sent again stays while it survives: the phone can't
 * unset a gym, so null means "unknown here". A new link is taken only if the caller can read that gym.
 */
export async function workoutGym(
  db: D1Database,
  userId: string,
  stored: string | null,
  incoming: string | null,
): Promise<string | null> {
  if (incoming === null || incoming === stored) {
    if (stored === null) return null
    return (await idsWhere(db, 'gyms', 'g', gymLinkSurvives('g', '?2'), userId, [stored])).has(stored) ? stored : null
  }
  return (await idsWhere(db, 'gyms', 'g', gymReadable('g', '?2'), userId, [incoming])).has(incoming) ? incoming : null
}

export interface EntryLink {
  readonly id: string
  readonly gymEquipmentId: string | null
}

/**
 * Each saved entry's listing: the phone's, or else the entry's previous one. The previous listing is kept while it
 * survives; any other is taken only if the caller can read it.
 */
export async function entryListings(
  db: D1Database,
  userId: string,
  entries: readonly EntryLink[],
  previous: ReadonlyMap<string, string>,
): Promise<Map<string, string | null>> {
  const wanted = entries.map((e) => ({ id: e.id, listing: e.gymEquipmentId ?? previous.get(e.id) ?? null }))
  const listings = [...new Set(wanted.flatMap((w) => (w.listing === null ? [] : [w.listing])))]
  const [surviving, readable] = await Promise.all([
    idsWhere(db, 'gym_equipment', 'e', listingLinkSurvives('e', '?2'), userId, listings),
    idsWhere(db, 'gym_equipment', 'e', listingReadable('e', '?2'), userId, listings),
  ])
  return new Map(wanted.map(({ id, listing }): [string, string | null] => {
    if (listing === null) return [id, null]
    const kept = previous.get(id) === listing && surviving.has(listing)
    return [id, kept || readable.has(listing) ? listing : null]
  }))
}
