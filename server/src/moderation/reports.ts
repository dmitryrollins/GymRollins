import { Refusals } from '../gyms/refusals.ts'
import { requireCleanText, trimmedOrNull } from '../gyms/text.ts'
import { badRequest, textOrNull } from '../http/input.ts'
import { DomainLimits } from '../shared/domain-limits.ts'
import { DAY_AGO_SQL, laterStamp, NOW_SQL } from '../sync/time.ts'
import { publicTarget, type Target, TARGET_TABLE } from './targets.ts'

// report_content, block_author and unblock_all (the Postgres migration 20261030000006_gym_moderation.sql). Each daily
// limit sits in the one batch that writes.

/** Unresolved reports from this many existing accounts hide a target until an admin decides. */
export const FLAG_REPORTS = 3

/**
 * A report on a public target in `table` (?3) that isn't removed. The insert checks the target itself, so one removed
 * after the first read gets no report.
 */
const fileReportSql = (table: string) => `INSERT INTO reports (id, target_type, target_id, reporter_id, reason, note,
    created_at)
SELECT ?1, ?2, ?3, ?4, ?5, ?6, ${NOW_SQL}
WHERE (SELECT count(*) FROM reports WHERE reporter_id = ?4 AND created_at > ${DAY_AGO_SQL}) < ${DomainLimits.dailyReports}
  AND EXISTS (SELECT 1 FROM ${table} WHERE id = ?3 AND visibility = 'public' AND status <> 'removed')
ON CONFLICT DO NOTHING`

/**
 * Flags an active target once enough accounts reported it. A report whose author has since deleted their account
 * (reporter_id is null) doesn't count, or a loop of sign up, report, delete would reach three alone; it stays for the
 * queue. ?1 the target, ?2 its type.
 */
const flagSql = (table: string) => `UPDATE ${table} SET status = 'flagged',
  updated_at = ${laterStamp(`${table}.updated_at`, NOW_SQL)}
WHERE id = ?1 AND status = 'active' AND (SELECT count(*) FROM reports WHERE target_type = ?2 AND target_id = ?1
  AND resolved_at IS NULL AND reporter_id IS NOT NULL) >= ${FLAG_REPORTS}`

const MY_REPORT = 'SELECT 1 FROM reports WHERE target_type = ?1 AND target_id = ?2 AND reporter_id = ?3'

export type ReportAnswer = { readonly status: 'reported' | 'own' | 'already' }

/** One report per account per target; your own content answers `own`, a second report `already`. */
export async function reportContent(
  db: D1Database,
  me: string,
  target: Target,
  reason: unknown,
  rawNote: unknown,
): Promise<ReportAnswer> {
  const { author, status } = await publicTarget(db, target)
  if (status === 'removed') throw Refusals.unknownTarget()
  if (author === me) return { status: 'own' }
  if (await db.prepare(MY_REPORT).bind(target.type, target.id, me).first()) return { status: 'already' }
  if (typeof reason !== 'string') throw badRequest('reason must be text.')
  const note = trimmedOrNull(textOrNull(rawNote, 'note'))
  requireCleanText(note, 'note', true)
  const table = TARGET_TABLE[target.type]
  const [, , mine] = await db.batch([
    db.prepare(fileReportSql(table)).bind(crypto.randomUUID(), target.type, target.id, me, reason, note),
    db.prepare(flagSql(table)).bind(target.id, target.type),
    db.prepare(MY_REPORT).bind(target.type, target.id, me),
  ])
  if (mine.results.length > 0) return { status: 'reported' }
  // Nothing written: the target was removed since the read above (publicTarget throws if it is gone), or the day's
  // 20 are used up.
  if ((await publicTarget(db, target)).status === 'removed') throw Refusals.unknownTarget()
  throw Refusals.dailyLimit()
}

const BLOCK = `INSERT INTO user_blocks (blocker_id, blocked_id, created_at)
SELECT ?1, ?2, ${NOW_SQL}
WHERE (SELECT count(*) FROM user_blocks WHERE blocker_id = ?1 AND created_at > ${DAY_AGO_SQL}) < ${DomainLimits.dailyBlocks}
ON CONFLICT DO NOTHING`

/**
 * Blocks the author of a target. Blocking tells a script whether two rows share an author, so the daily limit is the
 * control; blocking someone already blocked is a no-op that doesn't count, so a retry always works.
 */
export async function blockAuthor(db: D1Database, me: string, target: Target): Promise<void> {
  const { author } = await publicTarget(db, target)
  if (author === null || author === me) return
  const [, blocked] = await db.batch([
    db.prepare(BLOCK).bind(me, author),
    db.prepare('SELECT 1 FROM user_blocks WHERE blocker_id = ?1 AND blocked_id = ?2').bind(me, author),
  ])
  if (blocked.results.length === 0) throw Refusals.dailyLimit()
}

const UNBLOCK = `DELETE FROM user_blocks WHERE blocker_id = ?1
  AND (SELECT count(*) FROM gym_unblocks WHERE user_id = ?1 AND created_at > ${DAY_AGO_SQL}) < ${DomainLimits.dailyUnblocks}
RETURNING blocked_id`

/** Logged only when the DELETE before it cleared something: changes() counts the batch's previous statement. */
const LOG_UNBLOCK = `INSERT INTO gym_unblocks (user_id, created_at) SELECT ?1, ${NOW_SQL} WHERE changes() > 0`

const UNBLOCKS_TODAY = `SELECT count(*) AS n FROM gym_unblocks WHERE user_id = ?1 AND created_at > ${DAY_AGO_SQL}`

/**
 * Clears every block the caller made; answers how many. Unblocking is the other half of the block probe, so each
 * clearing is logged and counted: 3 a day, refused even when there is nothing to clear, as unblock_all was.
 */
export async function unblockAll(db: D1Database, me: string): Promise<number> {
  const [cleared] = await db.batch([db.prepare(UNBLOCK).bind(me), db.prepare(LOG_UNBLOCK).bind(me)])
  if (cleared.results.length > 0) return cleared.results.length
  const used = (await db.prepare(UNBLOCKS_TODAY).bind(me).first<{ n: number }>())!.n
  if (used >= DomainLimits.dailyUnblocks) throw Refusals.dailyLimit()
  return 0
}
