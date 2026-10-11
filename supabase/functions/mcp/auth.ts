// Bearer auth for the MCP endpoint and OAuth 2.0 Protected Resource Metadata (RFC 9728). Only access tokens
// Supabase Auth issued to an OAuth client (such as Claude) are accepted: the verifier checks the signature and
// expiry with Auth, and the token must carry a non-empty `client_id` claim. The app's own session tokens (no
// client_id) are refused, because RLS treats them as the owner with full write access rather than as an MCP
// client restricted by the profile's mcp_* flags.

export interface AuthContext {
  userId: string
  /** OAuth client id of the token (always present: tokens without one are rejected). */
  clientId: string
  token: string
}

/** Resolves a token to its user, or null when the token is invalid/expired. Throws when Auth is unreachable. */
export type TokenVerifier = (token: string) => Promise<{ id: string } | null>

const MAX_TOKEN_LENGTH = 8192
const METADATA_SUFFIX = '/functions/v1/mcp/oauth-protected-resource'

export const CORS_HEADERS: Record<string, string> = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET, POST, DELETE, OPTIONS',
  'access-control-allow-headers':
    'authorization, content-type, accept, mcp-session-id, mcp-protocol-version, last-event-id',
  'access-control-expose-headers': 'www-authenticate, mcp-session-id',
}

const trimBase = (base: string) => base.replace(/\/+$/, '')

export const resourceMetadataUrl = (base: string): string => `${trimBase(base)}${METADATA_SUFFIX}`

export function bearerToken(req: Request): string | null {
  const match = /^Bearer\s+(\S+)$/i.exec(req.headers.get('authorization') ?? '')
  if (!match || match[1].length > MAX_TOKEN_LENGTH) return null
  return match[1]
}

/** Decodes a JWT payload without verifying it — use only after the verifier accepted the token. */
export function jwtClaims(token: string): Record<string, unknown> | null {
  const part = token.split('.')[1]
  if (!part) return null
  try {
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '=')
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
    const claims = JSON.parse(new TextDecoder().decode(bytes))
    return claims && typeof claims === 'object' && !Array.isArray(claims) ? claims : null
  } catch {
    return null
  }
}

export async function authenticate(req: Request, verify: TokenVerifier): Promise<AuthContext | null> {
  const token = bearerToken(req)
  if (!token) return null
  const user = await verify(token)
  if (!user) return null
  const claims = jwtClaims(token)
  if (!claims || claims.sub !== user.id) return null
  const clientId = claims.client_id
  if (typeof clientId !== 'string' || clientId === '') return null
  return { userId: user.id, clientId, token }
}

export function metadataDocument(base: string): Record<string, unknown> {
  const origin = trimBase(base)
  return {
    resource: `${origin}/functions/v1/mcp`,
    authorization_servers: [`${origin}/auth/v1`],
    scopes_supported: ['email', 'profile'],
    bearer_methods_supported: ['header'],
    resource_name: 'GymRollins',
  }
}

export function jsonResponse(body: unknown, status: number, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json', ...headers },
  })
}

export function metadataResponse(base: string): Response {
  return jsonResponse(metadataDocument(base), 200, { 'cache-control': 'public, max-age=3600' })
}

export function unauthorized(base: string): Response {
  return jsonResponse(
    { error: 'invalid_token', error_description: 'A valid Supabase access token is required.' },
    401,
    { 'www-authenticate': `Bearer resource_metadata="${resourceMetadataUrl(base)}"` },
  )
}

export function preflight(): Response {
  return new Response(null, { status: 204, headers: { ...CORS_HEADERS, 'access-control-max-age': '86400' } })
}

/** A copy of the response with CORS headers added (the MCP SDK's responses carry none). */
export function withCors(res: Response): Response {
  const headers = new Headers(res.headers)
  for (const [k, v] of Object.entries(CORS_HEADERS)) if (!headers.has(k)) headers.set(k, v)
  return new Response(res.body, { status: res.status, statusText: res.statusText, headers })
}
