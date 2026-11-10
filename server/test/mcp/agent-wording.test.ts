// Any agent uses these tools now (plan 32; docs/specs/2026-11-09-ai-agents-design.md, section 3.6), so what they say
// about the owner's permissions names agents, not Claude. The server's MCP instructions keep their Claude-specific
// advice (test/mcp/instructions.test.ts).
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { D1Db } from '../../src/mcp/d1-db.ts'
import { listGyms } from '../../src/mcp/tools/gyms.ts'
import { getTrainingInsights } from '../../src/mcp/tools/insights.ts'
import { TOOL_SPECS } from '../../src/mcp/tools/register.ts'
import { notAllowed } from '../../src/mcp/tools/permissions.ts'
import { getStrengthLevels } from '../../src/mcp/tools/strength.ts'
import { signUp } from '../helpers.ts'
import { FakeDb, loadOwnerData } from './fake-db.ts'

const NOW = new Date('2026-11-09T12:00:00Z')
const T = '2026-11-07T10:00:00.000000Z'

describe("what the tools say about the owner's permissions", () => {
  it('names agents in every description, never Claude', () => {
    for (const s of TOOL_SPECS) expect(s.description, s.name).not.toContain('Claude')
    const byName = Object.fromEntries(TOOL_SPECS.map((s) => [s.name, s.description]))
    expect(byName.get_profile).toContain('which permissions agents have')
    expect(byName.propose_plan_changes).toContain('permissions.auto_apply')
    expect(byName.propose_plan_changes).not.toContain('never change anything by themselves')
    expect(byName.log_bodyweight).toContain('the owner allowed agents to access body data')
    for (const name of ['get_training_insights', 'get_strength_levels', 'list_gyms', 'get_gym_equipment']) {
      expect(byName[name], name).toContain('Only works if the owner allowed agents to read')
    }
  })

  it('refuses a read in words for any agent', async () => {
    const data = await loadOwnerData()
    data.profile = { ...data.profile!, mcp_read_workouts: false, mcp_read_gyms: false }
    const ctx = { db: new FakeDb(data), now: NOW }
    await expect(getTrainingInsights(ctx, {})).rejects.toThrow(notAllowed(['workouts']))
    await expect(getStrengthLevels(ctx, {})).rejects.toThrow(notAllowed(['workouts']))
    await expect(listGyms(ctx)).rejects.toThrow(notAllowed(['gyms']))
    for (const words of [notAllowed(['workouts']), notAllowed(['gyms'])]) expect(words).not.toContain('Claude')
  })

  it('refuses a write in words for any agent', async () => {
    const { userId } = await signUp()
    await env.DB.prepare(
      'INSERT INTO profiles (user_id, mcp_read_body, mcp_propose, client_updated_at, updated_at) ' +
        'VALUES (?1, 0, 0, ?2, ?2)',
    ).bind(userId, T).run()
    const db = new D1Db(env.DB, userId, 'agent-client')
    const refusal = "Not allowed: the owner's permissions for agents in the app don't allow this."
    await expect(db.insertBodyweight({ id: crypto.randomUUID(), measured_at: T, w_kg: 82 })).rejects.toThrow(refusal)
    await expect(db.insertProposal({ summary: 'Bench', changes: [{ id: 'c1' }] })).rejects.toThrow(refusal)
  })
})
