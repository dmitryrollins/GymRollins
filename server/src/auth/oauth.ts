// Claude's OAuth (spec section 4, "Claude's connection"): Better Auth's mcp plugin, which is its
// oauth-provider set up for one MCP resource. Opaque tokens stored hashed in D1, so /mcp checks each one
// there and a revoke is immediate.
import { mcp } from '@better-auth/mcp'
import type { Env } from '../env.ts'

/** `mcp` is the resource's own scope; `offline_access` is what earns a refresh token. */
export const MCP_SCOPES = ['mcp', 'offline_access']

/** Prefixes on the tokens Claude gets (not stored): /mcp tells a Claude token apart before touching D1. */
export const ACCESS_TOKEN_PREFIX = 'gra_'
export const REFRESH_TOKEN_PREFIX = 'grr_'

/** Claude's sign-in page: Better Auth's login and consent steps both send the browser here. */
export const CONNECT_PATH = '/connect'

const CLAUDE_CALLBACKS = new Set([
  'https://claude.ai/api/mcp/auth_callback',
  'https://claude.com/api/mcp/auth_callback',
])
const LOOPBACK_CALLBACK = /^http:\/\/(localhost|127\.0\.0\.1)(:\d{1,5})?\/[^?#]*$/

/** claude.ai's and claude.com's callbacks, or a loopback address on any port (Claude Code). */
export function isAllowedRedirectUri(uri: string): boolean {
  return CLAUDE_CALLBACKS.has(uri) || LOOPBACK_CALLBACK.test(uri)
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
    // Claude registers itself (RFC 7591). src/auth/routes.ts refuses any redirect URL but Claude's first.
    allowDynamicClientRegistration: true,
    allowUnauthenticatedClientRegistration: true,
    clientRegistrationDefaultApplicationType: 'infer',
    validateRedirectUri: (uri, _registered, matched) => matched && isAllowedRedirectUri(uri),
  })
}
