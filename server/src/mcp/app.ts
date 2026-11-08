// The MCP endpoint (ported from supabase/functions/mcp/app.ts): bearer auth with Claude tokens only → a
// rate-limit slot → MCP Streamable HTTP, stateless (a new McpServer per request, no sessions, no Durable
// Objects). Dependencies are injected: src/claude/mcp-route.ts wires the D1 ones, test/mcp/app.test.ts fakes.
import { createMcpHandler, McpServer } from '@modelcontextprotocol/server'
import { CORS_HEADERS, preflight, withCors } from '../http/cors.ts'
import type { Db } from './db.ts'
import { CALLS_PER_MINUTE } from './d1-db.ts'
import { SERVER_INSTRUCTIONS } from './instructions.ts'
import { registerTools } from './tools/register.ts'

/** Who a Claude access token belongs to (src/claude/tokens.ts). */
export interface McpCaller {
  userId: string
  clientId: string
  token: string
}

export interface McpDeps {
  /** RFC 9728 metadata, named in the 401 so Claude can start its OAuth. */
  resourceMetadataUrl: string
  /** The caller of a live Claude access token, or null. */
  verify: (token: string) => Promise<McpCaller | null>
  dbFor: (caller: McpCaller) => Db
  now?: () => Date
}

export const RATE_LIMIT_PER_MINUTE = CALLS_PER_MINUTE
/** Also src/index.ts's body limit on /mcp, which bounds a chunked body before anything here reads it. */
export const MAX_BODY_BYTES = 256 * 1024
const MAX_TOKEN_LENGTH = 8192
const SERVER_INFO = { name: 'gymrollins', version: '0.1.0' }

const errorMessage = (e: unknown) => (e instanceof Error ? e.message : String(e))

export function jsonResponse(body: unknown, status: number, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'content-type': 'application/json', ...headers },
  })
}

export function bearerToken(req: Request): string | null {
  const match = /^Bearer\s+(\S+)$/i.exec(req.headers.get('authorization') ?? '')
  if (!match || match[1]!.length > MAX_TOKEN_LENGTH) return null
  return match[1]!
}

function unauthorized(resourceMetadataUrl: string): Response {
  return jsonResponse(
    { error: 'invalid_token', error_description: 'A valid GymRollins access token for Claude is required.' },
    401,
    { 'www-authenticate': `Bearer resource_metadata="${resourceMetadataUrl}"` },
  )
}

/** A POST whose body is a JSON array. A body over the limit is left to the handler, which answers 413. */
async function isBatch(req: Request): Promise<boolean> {
  if (req.method !== 'POST') return false
  if (Number(req.headers.get('content-length') ?? 0) > MAX_BODY_BYTES) return false
  return (await req.clone().text()).trimStart().startsWith('[')
}

async function serveMcp(
  req: Request,
  caller: McpCaller,
  deps: McpDeps,
  requestId: string,
): Promise<Response> {
  const db = deps.dbFor(caller)
  if (!(await db.takeCall())) {
    return jsonResponse(
      { error: 'rate_limited', error_description: 'Too many requests; try again in a minute.' },
      429,
      { 'retry-after': '60' },
    )
  }
  // The slot above is per HTTP request, and @modelcontextprotocol/server 2.4.0 accepts a JSON-RPC batch of up to
  // 100 messages, so an array body could run 100 tool calls for one slot: refuse it (added after review).
  if (await isBatch(req)) {
    return withCors(Response.json({
      jsonrpc: '2.0',
      error: { code: -32600, message: 'Invalid Request: JSON-RPC batches are not supported.' },
      id: null,
    }, { status: 400 }))
  }
  const handler = createMcpHandler(() => {
    const server = new McpServer(SERVER_INFO, { instructions: SERVER_INSTRUCTIONS })
    registerTools(server, { db, requestId, now: deps.now })
    return server
  }, {
    maxRequestBodySize: MAX_BODY_BYTES,
    onerror: (e) => console.error(requestId, 'mcp', e.message),
  })
  const res = await handler.fetch(req, {
    authInfo: { token: caller.token, clientId: caller.clientId, scopes: [] },
  })
  return withCors(res)
}

export function createMcpApp(deps: McpDeps): (req: Request) => Promise<Response> {
  return async (req) => {
    const requestId = crypto.randomUUID()
    try {
      if (req.method === 'OPTIONS') return preflight()
      const token = bearerToken(req)
      const caller = token === null ? null : await deps.verify(token)
      if (!caller) return unauthorized(deps.resourceMetadataUrl)
      return await serveMcp(req, caller, deps, requestId)
    } catch (e) {
      console.error(requestId, 'request', errorMessage(e))
      return jsonResponse({ error: 'server_error', error_description: 'Temporarily unavailable.' }, 503)
    }
  }
}
