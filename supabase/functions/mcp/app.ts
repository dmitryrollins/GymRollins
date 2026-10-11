// The MCP Edge Function's request handler, with its dependencies injected (index.ts wires the real ones):
//   GET  …/mcp/oauth-protected-resource  → RFC 9728 metadata (no auth)
//   *    …/mcp                           → bearer auth (OAuth client tokens only) → rate-limit slot → MCP
//                                           Streamable HTTP (stateless, SDK v2)
import { createMcpHandler, McpServer } from 'npm:@modelcontextprotocol/server@2.1.0'
import {
  type AuthContext,
  authenticate,
  jsonResponse,
  metadataResponse,
  preflight,
  type TokenVerifier,
  unauthorized,
  withCors,
} from './auth.ts'
import type { Db } from './db.ts'
import { registerTools } from './tools/register.ts'

export interface AppDeps {
  /** Public origin clients see, e.g. https://<ref>.supabase.co (not the runtime's internal URL). */
  publicBase: string
  verify: TokenVerifier
  /** A Db acting as the authenticated caller (user-scoped client). */
  dbFor: (auth: AuthContext) => Db
  now?: () => Date
}

/** Requests per user per trailing minute; enforced atomically in SQL by public.mcp_take_call(). */
export const RATE_LIMIT_PER_MINUTE = 60
const MAX_BODY_BYTES = 256 * 1024
const SERVER_INFO = { name: 'gymrollins', version: '0.1.0' }

const errorMessage = (e: unknown) => (e instanceof Error ? e.message : String(e))

async function serveMcp(
  req: Request,
  auth: AuthContext,
  deps: AppDeps,
  requestId: string,
): Promise<Response> {
  const db = deps.dbFor(auth)
  if (!(await db.takeCall())) {
    return jsonResponse(
      { error: 'rate_limited', error_description: 'Too many requests; try again in a minute.' },
      429,
      {
        'retry-after': '60',
      },
    )
  }
  const handler = createMcpHandler(() => {
    const server = new McpServer(SERVER_INFO)
    registerTools(server, { db, requestId, now: deps.now })
    return server
  }, {
    maxRequestBodySize: MAX_BODY_BYTES,
    onerror: (e) => console.error(requestId, 'mcp', e.message),
  })
  const res = await handler.fetch(req, {
    authInfo: { token: auth.token, clientId: auth.clientId, scopes: [] },
  })
  return withCors(res)
}

export function createApp(deps: AppDeps): (req: Request) => Promise<Response> {
  return async (req) => {
    const requestId = crypto.randomUUID()
    try {
      if (req.method === 'OPTIONS') return preflight()
      const path = new URL(req.url).pathname.replace(/\/+$/, '')
      if (path.endsWith('/oauth-protected-resource')) {
        return req.method === 'GET' || req.method === 'HEAD'
          ? metadataResponse(deps.publicBase)
          : jsonResponse({ error: 'method_not_allowed' }, 405, { allow: 'GET, HEAD, OPTIONS' })
      }
      const auth = await authenticate(req, deps.verify)
      if (!auth) return unauthorized(deps.publicBase)
      return await serveMcp(req, auth, deps, requestId)
    } catch (e) {
      console.error(requestId, 'request', errorMessage(e))
      return jsonResponse({ error: 'server_error', error_description: 'Temporarily unavailable.' }, 503)
    }
  }
}
