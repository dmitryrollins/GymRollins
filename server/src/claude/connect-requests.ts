// connect_requests in D1: what /connect writes and the app decides (spec section 4, "Claude's connection",
// steps 3–5). Every change of status is one conditional UPDATE, so a code is decided once and used once.
import { NOW_SQL } from '../sync/time.ts'
import { newCode } from './connect-code.ts'

/** Codes and their browser sessions last this long (spec section 4). */
export const CONNECT_MINUTES = 10
/** Wrong codes an account may type per CONNECT_MINUTES. */
export const WRONG_CODES_ALLOWED = 5

const later = (modifier: string) => `(strftime('%Y-%m-%dT%H:%M:%f', 'now', '${modifier}') || '000Z')`
const EXPIRES_SQL = later(`+${CONNECT_MINUTES} minutes`)
const WINDOW_START_SQL = later(`-${CONNECT_MINUTES} minutes`)
const STALE_SQL = later('-1 day')

export type ConnectStatus = 'waiting' | 'approved' | 'denied' | 'used'

export interface ConnectRequest {
  code: string
  client_id: string
  client_name: string | null
  redirect_host: string
  query: string
  status: ConnectStatus
  expires_at: string
  /** 1 while expires_at is in the future. */
  live: number
}

/** Sign-ins one client may start per CONNECT_MINUTES: /connect is public, so its writes are capped. */
export const SIGN_INS_PER_CLIENT = 20

/**
 * A new waiting request for one browser, or null when the client started SIGN_INS_PER_CLIENT already. A code
 * already taken (1 in 2^40 per live code) is drawn again. Old requests and tries go a day after they expire.
 */
export async function createRequest(
  db: D1Database,
  r: { browserHash: string; clientId: string; redirectHost: string; query: string },
): Promise<string | null> {
  for (let attempt = 0;; attempt++) {
    const code = newCode()
    try {
      const [, , inserted] = await db.batch([
        db.prepare(`DELETE FROM connect_requests WHERE expires_at < ${STALE_SQL}`),
        db.prepare(`DELETE FROM connect_attempts WHERE at < ${STALE_SQL}`),
        db.prepare(
          'INSERT INTO connect_requests (code, browser_hash, client_id, redirect_host, query, status, ' +
            `created_at, expires_at) SELECT ?1, ?2, ?3, ?4, ?5, 'waiting', ${NOW_SQL}, ${EXPIRES_SQL} ` +
            'WHERE (SELECT count(*) FROM connect_requests WHERE client_id = ?3 ' +
            `AND created_at > ${WINDOW_START_SQL}) < ?6 RETURNING code`,
        ).bind(code, r.browserHash, r.clientId, r.redirectHost, r.query, SIGN_INS_PER_CLIENT),
      ])
      return inserted!.results.length === 1 ? code : null
    } catch (error) {
      if (attempt >= 2 || !/UNIQUE constraint failed: connect_requests\.code/.test(String(error))) throw error
    }
  }
}

const SELECT_REQUEST =
  'SELECT r.code, r.client_id, c.name AS client_name, r.redirect_host, r.query, r.status, ' +
  `r.expires_at, r.expires_at > ${NOW_SQL} AS live FROM connect_requests r ` +
  'LEFT JOIN oauthClient c ON c.clientId = r.client_id'

/** The request this browser's cookie belongs to, in any state. */
export async function requestForBrowser(db: D1Database, browserHash: string): Promise<ConnectRequest | null> {
  return await db.prepare(`${SELECT_REQUEST} WHERE r.browser_hash = ?1`).bind(browserHash).first<
    ConnectRequest
  >()
}

/** A waiting, unexpired request by its code: what the app shows before Approve and Deny. */
export async function waitingRequest(db: D1Database, code: string): Promise<ConnectRequest | null> {
  return await db.prepare(
    `${SELECT_REQUEST} WHERE r.code = ?1 AND r.status = 'waiting' AND r.expires_at > ${NOW_SQL}`,
  )
    .bind(code).first<ConnectRequest>()
}

/** The owner's decision on a waiting, unexpired code; false when there is none. */
export async function decide(
  db: D1Database,
  code: string,
  userId: string,
  decision: 'approved' | 'denied',
): Promise<boolean> {
  const row = await db.prepare(
    'UPDATE connect_requests SET status = ?3, user_id = ?2 ' +
      `WHERE code = ?1 AND status = 'waiting' AND expires_at > ${NOW_SQL} RETURNING code`,
  ).bind(code, userId, decision).first()
  return row !== null
}

/** Marks this browser's decided request used, once; the approver's id for an approval. */
export async function useDecision(
  db: D1Database,
  code: string,
  browserHash: string,
  status: 'approved' | 'denied',
): Promise<{ user_id: string } | null> {
  return await db.prepare(
    "UPDATE connect_requests SET status = 'used' " +
      `WHERE code = ?1 AND browser_hash = ?2 AND status = ?3 AND expires_at > ${NOW_SQL} RETURNING user_id`,
  ).bind(code, browserHash, status).first<{ user_id: string }>()
}

/** The browser session /connect created, so Disconnect Claude can end it. */
export async function recordSession(db: D1Database, code: string, sessionId: string): Promise<void> {
  await db.prepare('UPDATE connect_requests SET session_id = ?2 WHERE code = ?1').bind(code, sessionId).run()
}

/**
 * Takes one try for the account in a single statement: an id while fewer than WRONG_CODES_ALLOWED tries are
 * recorded for the last CONNECT_MINUTES, else null. A right code gives its try back (refundAttempt), so only
 * wrong ones count, and concurrent guesses can't get past the limit.
 */
export async function takeAttempt(db: D1Database, userId: string): Promise<number | null> {
  const row = await db.prepare(
    `INSERT INTO connect_attempts (user_id, at) SELECT ?1, ${NOW_SQL} WHERE (SELECT count(*) FROM ` +
      `connect_attempts ` +
      `WHERE user_id = ?1 AND at > ${WINDOW_START_SQL}) < ?2 RETURNING id`,
  ).bind(userId, WRONG_CODES_ALLOWED).first<{ id: number }>()
  return row?.id ?? null
}

export async function refundAttempt(db: D1Database, id: number): Promise<void> {
  await db.prepare('DELETE FROM connect_attempts WHERE id = ?1').bind(id).run()
}
