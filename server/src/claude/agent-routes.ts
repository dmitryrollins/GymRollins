// /v1/agents: Settings › AI agents, behind the app's session like /v1/claude (plan 32; docs/specs/
// 2026-11-09-ai-agents-design.md, section 3). POST /v1/claude/revoke stays as Disconnect all.
import { Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { ApiError } from '../http/errors.ts'
import { connectedAgents, disconnectAgent } from './agents.ts'

/** Better Auth's client ids are 32 letters; anything far longer is no client of the account. */
const MAX_CLIENT_ID_LENGTH = 255

export const agentRoutes = new Hono<AppEnv>()

agentRoutes.get('/', async (c) => c.json({ agents: await connectedAgents(c.env.DB, c.var.userId) }))

/** Disconnect one agent. Its own code, not `not_found`, so the app can tell it from a missing route. */
agentRoutes.post('/:clientId/disconnect', async (c) => {
  const clientId = c.req.param('clientId')
  const known = clientId.length <= MAX_CLIENT_ID_LENGTH && await disconnectAgent(c.env.DB, c.var.userId, clientId)
  if (!known) throw new ApiError(404, 'unknown_agent', 'No agent with this id is connected to your account.')
  return c.json({ disconnected: true })
})
