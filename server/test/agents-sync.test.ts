// What plan 32 adds to sync (docs/specs/2026-11-09-ai-agents-design.md, section 3.5): the Add workouts switch on the
// profile, and the agent a workout was added by.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { request, signUp } from './helpers.ts'
import { type Row, SAMPLES, T2 } from './samples.ts'

async function pushProfile(token: string, row: Row): Promise<Response> {
  return await request('POST', '/v1/sync/profile', { token, body: { rows: [row] } })
}

async function pulledProfile(token: string): Promise<Row> {
  const res = await request('GET', '/v1/sync/profile', { token })
  expect(res.status).toBe(200)
  const { rows } = await res.json<{ rows: Row[] }>()
  expect(rows).toHaveLength(1)
  return rows[0]!
}

describe('the Add workouts switch', () => {
  it('syncs as mcp_log_workouts, a boolean, like the other switches', async () => {
    const { token, userId } = await signUp()
    expect((await pushProfile(token, { ...SAMPLES.profile(), mcp_log_workouts: true })).status).toBe(200)
    expect(await pulledProfile(token)).toMatchObject({ mcp_log_workouts: true, mcp_read_body: false })
    const stored = await env.DB.prepare('SELECT mcp_log_workouts FROM profiles WHERE user_id = ?1').bind(userId).first()
    expect(stored).toEqual({ mcp_log_workouts: 1 })
    const off = { ...SAMPLES.profile(), mcp_log_workouts: false, client_updated_at: T2 }
    expect((await pushProfile(token, off)).status).toBe(200)
    expect((await pulledProfile(token)).mcp_log_workouts).toBe(false)
  })

  it("takes the profile of an app that doesn't know the switch, and keeps Add workouts off", async () => {
    const { token } = await signUp()
    const { mcp_log_workouts: _, ...older } = SAMPLES.profile()
    expect((await pushProfile(token, older)).status).toBe(200)
    expect((await pulledProfile(token)).mcp_log_workouts).toBe(false)
  })

  it('refuses a value that is not a boolean, naming the column', async () => {
    const { token } = await signUp()
    const res = await pushProfile(token, { ...SAMPLES.profile(), mcp_log_workouts: 1 })
    expect(res.status).toBe(422)
    expect(await res.json()).toEqual({
      error: { code: 'row_rejected', message: 'rows[0].mcp_log_workouts is not a valid bool' },
    })
  })
})
