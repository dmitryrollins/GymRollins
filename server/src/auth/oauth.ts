// Claude's OAuth (spec section 4, "Claude's connection"): Better Auth's mcp plugin, which is its
// oauth-provider set up for one MCP resource. Opaque tokens stored hashed in D1, so /mcp checks each one
// there and a revoke is immediate.
import { mcp } from '@better-auth/mcp'
import type { Env } from '../env.ts'

/** The resource's own scope: /mcp serves only a token that has it (added after review). */
export const MCP_SCOPE = 'mcp'
/** `mcp`, and `offline_access`, which is what earns a refresh token. */
export const MCP_SCOPES = [MCP_SCOPE, 'offline_access']

/** Prefixes on the tokens Claude gets (not stored): /mcp tells a Claude token apart before touching D1. */
export const ACCESS_TOKEN_PREFIX = 'gra_'
export const REFRESH_TOKEN_PREFIX = 'grr_'

/** Claude's sign-in page: Better Auth's login and consent steps both send the browser here. */
export const CONNECT_PATH = '/connect'

const LOOPBACK_CALLBACK = /^http:\/\/(localhost|127\.0\.0\.1)(:\d{1,5})?\/[^?#]*$/
/** A public DNS name as the URL parser leaves it (lower case): two labels or more, the last one not a number. */
const DOMAIN_NAME = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$/
const REDIRECT_URI_MAX = 512

/**
 * Any agent's https callback on a domain name (claude.ai's, Meta's, …), or a loopback address on any port (Claude
 * Code). Opened to every agent on 2026-11-09 (the owner): the app still shows each connection's host before Approve
 * and warns when it isn't Claude's. No fragment, no credentials, no IP address, no control characters or spaces.
 */
export function isAllowedRedirectUri(uri: string): boolean {
  if (uri.length > REDIRECT_URI_MAX || /[\s\u0000-\u001f\u007f#]/.test(uri)) return false
  if (LOOPBACK_CALLBACK.test(uri)) return true
  if (!uri.startsWith('https://')) return false
  let url: URL
  try {
    url = new URL(uri)
  } catch {
    return false
  }
  return url.protocol === 'https:' && url.username === '' && url.password === '' && DOMAIN_NAME.test(url.hostname) &&
    url.hostname !== 'localhost' && !url.hostname.endsWith('.localhost')
}

/** The MCP server's address: the resource every Claude token is issued for. */
export const mcpResource = (env: Env): string => `${env.PUBLIC_BASE_URL}/mcp`

/** Better Auth's issuer (its base URL with the base path). */
export const issuer = (env: Env): string => `${env.PUBLIC_BASE_URL}/api/auth`

/** SHA-256, base64url: how codes and tokens are stored, and how /mcp looks a token up. */
export async function hashToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token))
  return btoa(String.fromCharCode(...new Uint8Array(digest))).replace(/\+/g, '-').replace(/\//g, '_').replace(
    /=+$/,
    '',
  )
}

export function claudeOAuth(env: Env) {
  return mcp({
    resource: mcpResource(env),
    loginPage: CONNECT_PATH,
    consentPage: CONNECT_PATH,
    scopes: MCP_SCOPES,
    grantTypes: ['authorization_code', 'refresh_token'],
    // Opaque access tokens, looked up in D1 on every call (no JWTs that stay valid after a revoke).
    disableJwtPlugin: true,
    storeTokens: { hash: (token) => hashToken(token) },
    prefix: { opaqueAccessToken: ACCESS_TOKEN_PREFIX, refreshToken: REFRESH_TOKEN_PREFIX },
    // Agents register themselves (RFC 7591); src/auth/routes.ts refuses what isAllowedRedirectUri doesn't take.
    allowDynamicClientRegistration: true,
    allowUnauthenticatedClientRegistration: true,
    clientRegistrationDefaultApplicationType: 'infer',
    validateRedirectUri: (uri, _registered, matched) => matched && isAllowedRedirectUri(uri),
  })
}
