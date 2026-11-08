// /mcp with the real dependencies: Claude tokens checked in D1, and Claude's D1 Db for the token's user.
import type { Context } from 'hono'
import type { AppEnv } from '../env.ts'
import { createMcpApp } from '../mcp/app.ts'
import { D1Db } from '../mcp/d1-db.ts'
import { claudeCaller } from './tokens.ts'

export function mcpRoute(c: Context<AppEnv>): Promise<Response> {
  const env = c.env
  return createMcpApp({
    resourceMetadataUrl: `${env.PUBLIC_BASE_URL}/.well-known/oauth-protected-resource/mcp`,
    verify: (token) => claudeCaller(env, token),
    dbFor: (caller) => new D1Db(env.DB, caller.userId, caller.clientId),
  })(c.req.raw)
}
