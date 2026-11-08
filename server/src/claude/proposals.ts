// Proposals for the app (spec section 3, "Routes"): the pending ones it pulls, and how it marks one resolved.
// Same rows and fields as SupabaseTransport.pendingProposals and resolveProposal read and wrote through
// PostgREST.
import { ApiError } from '../http/errors.ts'
import { laterStamp, normalizeTimestamp, NOW_SQL } from '../sync/time.ts'

/** A pull returns at most this many; Claude can't keep more than a few pending. */
export const MAX_PENDING = 200
const RESOLVED = new Set(['applied', 'dismissed', 'partial'])
const MAX_CHANGE_IDS = 25
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

export interface Resolution {
  status: string
  applied_change_ids: string[]
  resolved_at: string
  client_updated_at: string
}

/** Pending proposals, oldest first: `changes` and `applied_change_ids` as JSON, times in the stored form. */
export async function pendingProposals(db: D1Database, userId: string): Promise<Record<string, unknown>[]> {
  const { results } = await db.prepare(
    'SELECT id, created_at, source, summary, changes, status, applied_change_ids, resolved_at FROM ' +
      'proposals ' +
      "WHERE user_id = ?1 AND status = 'pending' ORDER BY created_at, id LIMIT ?2",
  ).bind(userId, MAX_PENDING).all<Record<string, unknown>>()
  return results.map((r) => ({
    ...r,
    changes: JSON.parse(r.changes as string),
    applied_change_ids: JSON.parse(r.applied_change_ids as string),
  }))
}

const rejected = (field: string, message: string) => new ApiError(422, 'row_rejected', `${field}: ${message}`)

/** The app's update body, checked: refused fields answer 422 row_rejected, as Postgres's 22xxx/23xxx did. */
export function parseResolution(body: unknown): Resolution {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    throw rejected('body', 'must be an object')
  }
  const b = body as Record<string, unknown>
  if (typeof b.status !== 'string' || !RESOLVED.has(b.status)) {
    throw rejected('status', 'must be applied, dismissed or partial')
  }
  const ids = b.applied_change_ids
  if (
    !Array.isArray(ids) || ids.length > MAX_CHANGE_IDS ||
    !ids.every((i) => typeof i === 'string' && i.length >= 1 && i.length <= 64)
  ) {
    throw rejected('applied_change_ids', `must be at most ${MAX_CHANGE_IDS} change ids`)
  }
  const stamp = (field: 'resolved_at' | 'client_updated_at') => {
    const value = typeof b[field] === 'string' ? normalizeTimestamp(b[field] as string) : null
    if (value === null) throw rejected(field, 'must be a timestamp')
    return value
  }
  return {
    status: b.status,
    applied_change_ids: ids,
    resolved_at: stamp('resolved_at'),
    client_updated_at: stamp('client_updated_at'),
  }
}

/**
 * Resolves one of the account's proposals. An older edit than the stored one changes nothing, as lww_guard
 * did, and still answers the stored row; another account's or an unknown id answers 404.
 */
export async function resolveProposal(
  db: D1Database,
  userId: string,
  id: string,
  r: Resolution,
): Promise<{ id: string; updated_at: string }> {
  const key = id.toLowerCase()
  if (!UUID.test(key)) throw new ApiError(404, 'not_found', 'No such proposal.')
  const updated = await db.prepare(
    'UPDATE proposals SET status = ?3, applied_change_ids = ?4, resolved_at = ?5, client_updated_at = ?6, ' +
      `updated_at = ${laterStamp('updated_at', NOW_SQL)} ` +
      'WHERE id = ?1 AND user_id = ?2 AND ?6 >= client_updated_at RETURNING id, updated_at',
  ).bind(key, userId, r.status, JSON.stringify(r.applied_change_ids), r.resolved_at, r.client_updated_at)
    .first<{ id: string; updated_at: string }>()
  if (updated) return updated
  const stored = await db.prepare('SELECT id, updated_at FROM proposals WHERE id = ?1 AND user_id = ?2')
    .bind(key, userId).first<{ id: string; updated_at: string }>()
  if (!stored) throw new ApiError(404, 'not_found', 'No such proposal.')
  return stored
}

/** When Claude last called a tool for the account (the newest audit row), or null. */
export async function lastClaudeUse(db: D1Database, userId: string): Promise<string | null> {
  const row = await db.prepare('SELECT at FROM mcp_audit WHERE user_id = ?1 ORDER BY at DESC LIMIT 1').bind(
    userId,
  )
    .first<{ at: string }>()
  return row?.at ?? null
}
