import { Refusals } from '../gyms/refusals.ts'
import { badRequest } from '../http/input.ts'
import { laterStamp, NOW_SQL } from '../sync/time.ts'
import { publicTarget, TARGET_TABLE, targetOf } from './targets.ts'

// is_app_admin, moderation_queue, moderate_content and moderation_photo_deleted. Admins are app_admins rows; Claude's
// tokens never reach /v1, so it is never an admin.

export async function isAdmin(db: D1Database, me: string): Promise<boolean> {
  return (await db.prepare('SELECT 1 FROM app_admins WHERE user_id = ?1').bind(me).first()) !== null
}

async function requireAdmin(db: D1Database, me: string): Promise<void> {
  if (!(await isAdmin(db, me))) throw Refusals.notAllowed()
}

export interface QueueRow {
  readonly target_type: 'gym' | 'listing'
  readonly target_id: string
  readonly title: string
  readonly photo_path: string | null
  readonly report_count: number
  readonly reasons: Readonly<Record<string, number>>
  readonly notes: readonly string[]
  readonly status: string
  readonly address: string | null
  readonly listing_notes: string | null
}

/**
 * Every public target with an unresolved report, and every flagged one even when its reports are gone; and removed
 * listings whose photo is still named, so a failed delete can be retried. `address` and `listing_notes` are the
 * target's own words, to judge it by.
 */
const QUEUE_TARGETS = `SELECT 'gym' AS target_type, g.id AS target_id, g.name AS title, NULL AS photo_path, g.status,
  g.address, NULL AS listing_notes
FROM gyms g
WHERE g.visibility = 'public' AND g.status <> 'removed'
  AND (g.status = 'flagged' OR g.id IN (SELECT r.target_id FROM reports r
    WHERE r.target_type = 'gym' AND r.resolved_at IS NULL))
UNION ALL
SELECT 'listing', e.id, coalesce(nullif(concat_ws(' ', i.brand, i.model), ''), k.name), e.photo_path, e.status,
  concat_ws(', ', g.name, g.address), e.notes
FROM gym_equipment e JOIN gyms g ON g.id = e.gym_id JOIN equipment_items i ON i.id = e.item_id
  JOIN equipment_kinds k ON k.id = i.kind_id
WHERE e.visibility = 'public'
  AND ((e.status <> 'removed' AND (e.status = 'flagged' OR e.id IN (SELECT r.target_id FROM reports r
      WHERE r.target_type = 'listing' AND r.resolved_at IS NULL)))
    OR (e.status = 'removed' AND e.photo_path IS NOT NULL))`

/** Every unresolved report, in the order filed (rowid breaks a tie within one millisecond). Never who filed it. */
const OPEN_REPORTS = `SELECT target_type, target_id, reason, note FROM reports WHERE resolved_at IS NULL
ORDER BY created_at, rowid`

type QueueTarget = Omit<QueueRow, 'report_count' | 'reasons' | 'notes'>

/** Flagged first, then the most reported, then by id. */
const queueOrder = (a: QueueRow, b: QueueRow) =>
  Number(b.status === 'flagged') - Number(a.status === 'flagged') || b.report_count - a.report_count ||
  (a.target_id < b.target_id ? -1 : a.target_id > b.target_id ? 1 : 0)

export async function moderationQueue(db: D1Database, me: string): Promise<QueueRow[]> {
  await requireAdmin(db, me)
  const [targets, reports] = await db.batch<Record<string, unknown>>([
    db.prepare(QUEUE_TARGETS), db.prepare(OPEN_REPORTS),
  ])
  const open = new Map<string, { reason: string; note: string | null }[]>()
  for (const r of reports.results) {
    const key = `${r.target_type}:${r.target_id}`
    open.set(key, [...(open.get(key) ?? []), { reason: String(r.reason), note: r.note as string | null }])
  }
  return targets.results.map((raw): QueueRow => {
    const target = raw as unknown as QueueTarget
    const filed = open.get(`${target.target_type}:${target.target_id}`) ?? []
    const reasons: Record<string, number> = {}
    for (const { reason } of filed) reasons[reason] = (reasons[reason] ?? 0) + 1
    const notes = filed.flatMap(({ note }) => (note === null ? [] : [note]))
    return { ...target, report_count: filed.length, reasons, notes }
  }).sort(queueOrder)
}

export interface Moderation {
  readonly status: 'active' | 'removed'
  readonly photo_path: string | null
}

const ACTIONS = { restore: 'active', remove: 'removed' } as const

/**
 * Restores or removes a target and resolves its reports. Removing a listing keeps its photo_path and answers it, for
 * the app to delete the photo; the name stays until photo-deleted, so a failed delete leaves something to retry and
 * the name can't be reused meanwhile. Removing a gym keeps its listings' photos. Restoring a gym whose place another
 * gym has taken since answers place_taken.
 */
export async function moderate(db: D1Database, me: string, body: Record<string, unknown>): Promise<Moderation> {
  await requireAdmin(db, me)
  const action = body.action
  if (action !== 'restore' && action !== 'remove') throw badRequest('invalid action')
  const target = targetOf(body)
  const next = ACTIONS[action]
  const { status } = await publicTarget(db, target)
  let photo: string | null = null
  if (target.type === 'listing' && action === 'remove') {
    photo = (await db.prepare('SELECT photo_path FROM gym_equipment WHERE id = ?1').bind(target.id)
      .first<{ photo_path: string | null }>())!.photo_path
    if (status === 'removed') return { status: 'removed', photo_path: photo }
  }
  const table = TARGET_TABLE[target.type]
  try {
    await db.batch([
      db.prepare(`UPDATE ${table} SET status = ?2, updated_at = ${laterStamp(`${table}.updated_at`, NOW_SQL)} WHERE id = ?1`)
        .bind(target.id, next),
      db.prepare(`UPDATE reports SET resolved_at = ${NOW_SQL} WHERE target_type = ?1 AND target_id = ?2 AND resolved_at IS NULL`)
        .bind(target.type, target.id),
    ])
  } catch (error) {
    if (target.type === 'gym' && /UNIQUE constraint failed/.test(String(error))) throw Refusals.placeTaken()
    throw error
  }
  return { status: next, photo_path: photo }
}

/** The app deleted a removed listing's photo: the listing lets go of its name. */
export async function moderationPhotoDeleted(db: D1Database, me: string, body: Record<string, unknown>): Promise<void> {
  await requireAdmin(db, me)
  if (typeof body.path !== 'string') throw badRequest('path must be text.')
  await db.prepare(
    `UPDATE gym_equipment SET photo_path = NULL, updated_at = ${laterStamp('gym_equipment.updated_at', NOW_SQL)}
     WHERE photo_path = ?1 AND status = 'removed' AND visibility = 'public'`,
  ).bind(body.path).run()
}
