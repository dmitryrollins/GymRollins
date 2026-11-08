// The caller of a Claude access token, read from D1 on every /mcp call (spec section 4, "Tokens"): Better
// Auth stores each opaque token's SHA-256, so a token that Disconnect Claude deleted, or that expired, stops
// working at once.
import { ACCESS_TOKEN_PREFIX, hashToken, MCP_SCOPE, mcpResource } from '../auth/oauth.ts'
import type { Env } from '../env.ts'
import type { McpCaller } from '../mcp/app.ts'

/** Ours are the prefix and 32 letters; anything much longer isn't worth hashing. */
const MAX_TOKEN_LENGTH = 128

interface TokenRow {
  userId: string
  clientId: string
  expiresAt: string
  resources: string | null
  scopes: string
  revoked: string | null
}

/** A stored JSON list, or null when the text isn't one. */
function storedList(text: string): unknown[] | null {
  try {
    const value: unknown = JSON.parse(text)
    return Array.isArray(value) ? value : null
  } catch {
    return null
  }
}

/**
 * The user and client of a live Claude access token, or null. An app session token never matches (it isn't in
 * oauthAccessToken), nor does a token for another resource. A token issued without a `resource` is accepted:
 * this server is the only resource its issuer serves.
 * Added after review:
 * - The token's scopes must include `mcp`.
 * - Its account's consent for the client must still exist. Disconnect Claude deletes consents with the
 *   tokens, but Better Auth's refresh marks the old token rotated and inserts the new pair in separate
 *   statements, so a pair inserted after the Disconnect would otherwise live on.
 */
export async function claudeCaller(env: Env, token: string): Promise<McpCaller | null> {
  if (!token.startsWith(ACCESS_TOKEN_PREFIX) || token.length > MAX_TOKEN_LENGTH) return null
  const row = await env.DB.prepare(
    'SELECT t.userId, t.clientId, t.expiresAt, t.resources, t.scopes, t.revoked FROM oauthAccessToken t ' +
      'JOIN oauthClient c ON c.clientId = t.clientId ' +
      'WHERE t.token = ?1 AND t.userId IS NOT NULL AND coalesce(c.disabled, 0) = 0 AND EXISTS ' +
      '(SELECT 1 FROM oauthConsent k WHERE k.clientId = t.clientId AND k.userId = t.userId)',
  ).bind(await hashToken(token.slice(ACCESS_TOKEN_PREFIX.length))).first<TokenRow>()
  if (!row || row.revoked !== null || !(Date.parse(row.expiresAt) > Date.now())) return null
  if (!storedList(row.scopes)?.includes(MCP_SCOPE)) return null
  const resources = row.resources === null ? [] : storedList(row.resources)
  if (resources === null || (resources.length > 0 && !resources.includes(mcpResource(env)))) return null
  return { userId: row.userId, clientId: row.clientId, token }
}
