// /v1/agents: Settings › AI agents, behind the app's session like /v1/claude (plan 32; docs/specs/
// 2026-11-09-ai-agents-design.md, section 3). POST /v1/claude/revoke stays as Disconnect all.
import { Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { connectedAgents } from './agents.ts'

export const agentRoutes = new Hono<AppEnv>()

agentRoutes.get('/', async (c) => c.json({ agents: await connectedAgents(c.env.DB, c.var.userId) }))
