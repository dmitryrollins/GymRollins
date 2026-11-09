// The agents connected to the account (plan 32; docs/specs/2026-11-09-ai-agents-design.md, section 3.1): every OAuth
// client that holds a consent or a live refresh token for it. Settings › AI agents lists them.
import { normalizeTimestamp } from '../sync/time.ts'
import { CLAUDE_HOSTS } from './hosts.ts'

export interface ConnectedAgent {
  client_id: string
  /** The registered client_name, or the host when it gave none. */
  name: string
  /** The host (and port, if any) of its first redirect URL, as the approve sheet shows it. */
  host: string
  /** True for Claude's own hosts (CLAUDE_HOSTS). */
  known_host: boolean
  /** When the owner approved it (the consent), in the stored form. */
  connected_at: string
  /** Its newest audited call for the account, or null. */
  last_used_at: string | null
}

/** Better Auth's clock in SQL: it stores dates as toISOString() text (YYYY-MM-DDTHH:MM:SS.sssZ), which this matches. */
const AUTH_NOW_SQL = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"

/** The clients the account (?1) granted: a consent, or a refresh token that is neither revoked nor expired. */
const GRANTED = 'SELECT clientId FROM oauthConsent WHERE userId = ?1 UNION ' +
  `SELECT clientId FROM oauthRefreshToken WHERE userId = ?1 AND revoked IS NULL AND expiresAt > ${AUTH_NOW_SQL}`

/**
 * connected_at is the consent's createdAt, or the first refresh token's for a client whose consent is gone (a refresh
 * that raced a Disconnect; /mcp refuses it, src/claude/tokens.ts). Listing it lets the owner disconnect it.
 */
const LIST = `SELECT c.clientId AS client_id, c.name AS client_name,
  CASE WHEN json_valid(c.redirectUris) THEN json_extract(c.redirectUris, '$[0]') END AS redirect_uri,
  coalesce(
    (SELECT min(k.createdAt) FROM oauthConsent k WHERE k.clientId = c.clientId AND k.userId = ?1),
    (SELECT min(r.createdAt) FROM oauthRefreshToken r WHERE r.clientId = c.clientId AND r.userId = ?1)
  ) AS connected_at,
  (SELECT max(a.at) FROM mcp_audit a WHERE a.user_id = ?1 AND a.client_id = c.clientId) AS last_used_at
FROM oauthClient c WHERE c.clientId IN (${GRANTED})
ORDER BY connected_at DESC, c.clientId`

interface ListRow {
  client_id: string
  client_name: string | null
  redirect_uri: string | null
  connected_at: string
  last_used_at: string | null
}

/** A redirect URL's host as the approve sheet has it (src/claude/connect-page.ts), or '' when it isn't a URL. */
function hostOf(uri: string | null): string {
  if (uri === null) return ''
  try {
    return new URL(uri).host
  } catch {
    return ''
  }
}

/** The account's agents, newest connection first. */
export async function connectedAgents(db: D1Database, userId: string): Promise<ConnectedAgent[]> {
  const { results } = await db.prepare(LIST).bind(userId).all<ListRow>()
  return results.map((r) => {
    const host = hostOf(r.redirect_uri)
    return {
      client_id: r.client_id,
      name: r.client_name ?? host,
      host,
      known_host: CLAUDE_HOSTS.has(host),
      connected_at: normalizeTimestamp(r.connected_at) ?? r.connected_at,
      last_used_at: r.last_used_at,
    }
  })
}
