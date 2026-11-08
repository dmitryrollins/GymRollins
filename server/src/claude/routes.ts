// /v1/claude: what Settings › Claude calls, behind the app's session (spec section 3, "Routes").
import { Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { jsonBody } from '../http/body.ts'
import { ApiError } from '../http/errors.ts'
import { displayCode, normalizeCode } from './connect-code.ts'
import {
  type ConnectRequest,
  decide,
  refundAttempt,
  takeAttempt,
  waitingRequest,
} from './connect-requests.ts'

/** Hosts the app shows without a warning: Claude's own. */
const CLAUDE_HOSTS = new Set(['claude.ai', 'claude.com'])

export const claudeRoutes = new Hono<AppEnv>()

/** What the Approve a connection sheet shows once a code is typed. */
claudeRoutes.get('/connect/:code', async (c) => {
  const db = c.env.DB
  const request = await withAttempt(db, c.var.userId, c.req.param('code'), (code) => waitingRequest(db, code))
  return c.json(connectView(request))
})

/** Approve or Deny: `{"decision": "approve" | "deny"}`. A bad body isn't a wrong code. */
claudeRoutes.post('/connect/:code', async (c) => {
  const body = await jsonBody(c) as { decision?: unknown } | null
  const decision = body?.decision === 'approve' ? 'approved' : body?.decision === 'deny' ? 'denied' : null
  if (decision === null) throw new ApiError(400, 'bad_request', 'decision must be approve or deny.')
  const [db, userId] = [c.env.DB, c.var.userId]
  await withAttempt(
    db,
    userId,
    c.req.param('code'),
    async (code) => (await decide(db, code, userId, decision)) || null,
  )
  return c.json({ status: decision })
})

/**
 * Runs `find` for a typed code within the account's tries: 429 when they're used up, 404 when the code
 * matches no waiting request (and the try is kept), the found value otherwise (and the try given back).
 */
async function withAttempt<T>(
  db: D1Database,
  userId: string,
  typed: string,
  find: (code: string) => Promise<T | null>,
): Promise<T> {
  const attempt = await takeAttempt(db, userId)
  if (attempt === null) {
    throw new ApiError(429, 'too_many_attempts', 'Too many wrong codes. Try again in 10 minutes.')
  }
  const code = normalizeCode(typed)
  const found = code === null ? null : await find(code)
  if (found === null) {
    throw new ApiError(404, 'unknown_code', 'No waiting request has this code. It may have expired.')
  }
  await refundAttempt(db, attempt)
  return found
}

function connectView(r: ConnectRequest) {
  return {
    code: displayCode(r.code),
    client_name: r.client_name,
    redirect_host: r.redirect_host,
    known_host: CLAUDE_HOSTS.has(r.redirect_host),
    expires_at: r.expires_at,
  }
}
