import { env } from 'cloudflare:workers'

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
    'INSERT INTO equipment_items (id, kind_id, brand, model, created_by, created_at, updated_at) ' +
      'VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)',
  ).bind(id, i.kind ?? 'dumbbells', i.brand, i.model, i.createdBy, T).run()
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
}): Promise<string> {
  const id = crypto.randomUUID()
  await env.DB.prepare(
    'INSERT INTO gym_equipment (id, gym_id, item_id, visibility, owner_id, photo_path, notes, added_by, status, ' +
      'client_updated_at, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10, ?10)',
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
