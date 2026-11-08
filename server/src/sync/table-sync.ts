import { ApiError } from '../http/errors.ts'
import { storedRow, wireRow } from './columns.ts'
import type { Entity } from './entities.ts'
import { laterStamp, normalizeTimestamp, NOW_SQL } from './time.ts'

export interface Ack {
  readonly id: string
  readonly updated_at: string
}

export interface PullQuery {
  readonly since: string | null
  readonly after: string | number | null
  readonly limit: number
}

/** The app pushes at most 200 rows at a time. */
export const MAX_PUSH_ROWS = 500
export const DEFAULT_PULL_LIMIT = 500
export const MAX_PULL_LIMIT = 1000

const bad = (message: string) => new ApiError(400, 'bad_request', message)

/**
 * The keyset condition for a pull, with since as ?2 and after as ?3: rows changed after `since`, or at `since` with a
 * tiebreak after `after` (KeysetPager's next page). No since: every row.
 */
export const afterSql = (tiebreak: string) =>
  `(?2 IS NULL OR updated_at > ?2 OR (?3 IS NOT NULL AND updated_at = ?2 AND ${tiebreak} > ?3))`

/**
 * Stores a push in one statement. A row whose edit is older than the stored one (or that another account holds) is
 * skipped and gets no ack, as Postgres's lww_guard skipped it; the app keeps it dirty and the next pull overwrites it.
 */
export async function pushRows(db: D1Database, userId: string, entity: Entity, body: unknown): Promise<Ack[]> {
  const raw = (body as { rows?: unknown } | null)?.rows
  if (!Array.isArray(raw)) throw bad('Expected {"rows": [...]}.')
  if (raw.length > MAX_PUSH_ROWS) throw bad(`At most ${MAX_PUSH_ROWS} rows per push.`)
  const rows = raw.map((row, index) => storedRow(entity.columns, row, `rows[${index}]`))
  if (rows.length === 0) return []
  await entity.check?.(db, userId, rows)
  const json = JSON.stringify(rows)
  if (!entity.conflict.includes('user_id')) await refuseOthersRows(db, userId, entity, json)
  const { results } = await db.prepare(upsertSql(entity)).bind(json, userId)
    .all<{ id: string | number; updated_at: string }>()
  return results.map((r) => ({ id: String(r.id), updated_at: r.updated_at }))
}

/** A row id another account holds is refused outright, as Postgres's RLS refused it (42501). */
async function refuseOthersRows(db: D1Database, userId: string, entity: Entity, json: string) {
  const key = entity.conflict[0]
  const other = await db.prepare(
    `SELECT 1 FROM ${entity.table} WHERE ${key} IN (SELECT json_extract(value, '$.${key}') FROM json_each(?1)) ` +
      'AND user_id <> ?2 LIMIT 1',
  ).bind(json, userId).first()
  if (other) throw new ApiError(403, 'not_allowed', 'That row belongs to another account.')
}

export function upsertSql(entity: Entity): string {
  const names = entity.columns.map((c) => c.name)
  const updates = names.filter((n) => !entity.conflict.includes(n))
    .map((n) => `${n} = ${entity.onUpdate?.[n] ?? `excluded.${n}`}`)
  const applies = entity.applies ?? `excluded.client_updated_at >= ${entity.table}.client_updated_at`
  const stampSql = `updated_at = ${laterStamp(`${entity.table}.updated_at`, 'excluded.updated_at')}`
  return `INSERT INTO ${entity.table} (user_id, ${names.join(', ')}, updated_at)
SELECT ?2, ${names.map((n) => `json_extract(value, '$.${n}')`).join(', ')}, ${NOW_SQL} FROM json_each(?1) WHERE true
ON CONFLICT (${entity.conflict.join(', ')}) DO UPDATE SET ${[...updates, stampSql].join(', ')}
WHERE ${entity.table}.user_id = excluded.user_id AND (${applies})
RETURNING ${entity.ackKey} AS id, updated_at`
}

/** One page of the caller's rows, oldest change first, tombstones included. */
export async function pullRows(db: D1Database, userId: string, entity: Entity, query: PullQuery) {
  const select = [...(entity.pullsUserId ? ['user_id'] : []), ...entity.columns.map((c) => c.name), 'updated_at']
  const { results } = await db.prepare(
    `SELECT ${select.join(', ')} FROM ${entity.table} WHERE user_id = ?1 AND ${afterSql(entity.tiebreak.column)} ` +
      `ORDER BY updated_at, ${entity.tiebreak.column} LIMIT ?4`,
  ).bind(userId, query.since, query.after, query.limit).all<Record<string, unknown>>()
  return results.map((row) => wireRow(entity.columns, row))
}

/** `?since=<timestamp>&after=<tiebreak>&limit=<n>`. The limit is never cut silently: the app stops at a short page. */
export function parsePullQuery(query: Record<string, string | undefined>, tiebreak: 'text' | 'int'): PullQuery {
  const since = query.since === undefined ? null : normalizeTimestamp(query.since)
  if (query.since !== undefined && since === null) throw bad('since must be a timestamp.')
  let after: string | number | null = null
  if (query.after !== undefined) {
    if (since === null) throw bad('after needs since.')
    if (query.after === '') throw bad('after must not be empty.')
    if (tiebreak === 'int' && !/^\d+$/.test(query.after)) throw bad('after must be a whole number.')
    after = tiebreak === 'int' ? Number(query.after) : query.after
  }
  const limit = query.limit === undefined ? DEFAULT_PULL_LIMIT : Number(query.limit)
  if (!Number.isInteger(limit) || limit < 1 || limit > MAX_PULL_LIMIT) throw bad(`limit must be 1 to ${MAX_PULL_LIMIT}.`)
  return { since, after, limit }
}
