// The caller of a Claude access token, read from D1 on every /mcp call (spec section 4, "Tokens"): Better
// Auth stores each opaque token's SHA-256, so a token that Disconnect Claude deleted, or that expired, stops
// working at once.
import { ACCESS_TOKEN_PREFIX, hashToken, mcpResource } from '../auth/oauth.ts'
import type { Env } from '../env.ts'
import type { McpCaller } from '../mcp/app.ts'

/** Ours are the prefix and 32 letters; anything much longer isn't worth hashing. */
const MAX_TOKEN_LENGTH = 128

interface TokenRow {
  userId: string
  clientId: string
  expiresAt: string
  resources: string | null
  revoked: string | null
}

/**
 * The user and client of a live Claude access token, or null. An app session token never matches (it isn't in
 * oauthAccessToken), nor does a token for another resource. A token issued without a `resource` is accepted:
 * this server is the only resource its issuer serves.
 */
export async function claudeCaller(env: Env, token: string): Promise<McpCaller | null> {
  if (!token.startsWith(ACCESS_TOKEN_PREFIX) || token.length > MAX_TOKEN_LENGTH) return null
  const row = await env.DB.prepare(
    'SELECT t.userId, t.clientId, t.expiresAt, t.resources, t.revoked FROM oauthAccessToken t ' +
      'JOIN oauthClient c ON c.clientId = t.clientId ' +
      'WHERE t.token = ?1 AND t.userId IS NOT NULL AND coalesce(c.disabled, 0) = 0',
  ).bind(await hashToken(token.slice(ACCESS_TOKEN_PREFIX.length))).first<TokenRow>()
  if (!row || row.revoked !== null || !(Date.parse(row.expiresAt) > Date.now())) return null
  const resources = row.resources === null ? [] : JSON.parse(row.resources) as unknown
  if (Array.isArray(resources) && resources.length > 0 && !resources.includes(mcpResource(env))) return null
  return { userId: row.userId, clientId: row.clientId, token }
}
