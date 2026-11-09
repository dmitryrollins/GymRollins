// What plan 32 adds to sync (docs/specs/2026-11-09-ai-agents-design.md, section 3.5): the Add workouts switch on the
// profile, and the agent a workout was added by.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { request, signUp } from './helpers.ts'
import { type Row, SAMPLES, T2, type WorkoutJSON, workoutSample } from './samples.ts'

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

async function saveWorkout(token: string, workout: Row): Promise<{ status: string; updated_at: string }> {
  const res = await request('POST', '/v1/sync/workouts', { token, body: workout })
  expect(res.status).toBe(200)
  return await res.json<{ status: string; updated_at: string }>()
}

async function pulledWorkouts(token: string): Promise<WorkoutJSON[]> {
  const res = await request('GET', '/v1/sync/workouts', { token })
  expect(res.status).toBe(200)
  return (await res.json<{ rows: WorkoutJSON[] }>()).rows
}

/** What log_workout leaves on a workout it added (src/sync/workouts.ts writes it only on insert). */
const markAdded = (id: string, name: string) =>
  env.DB.prepare('UPDATE workouts SET added_by = ?2 WHERE id = ?1').bind(id.toLowerCase(), name).run()

describe("a workout's added_by", () => {
  it("is null on the app's own workouts, in a pull and a fetch", async () => {
    const { token } = await signUp()
    const w = workoutSample()
    await saveWorkout(token, w)
    expect((await pulledWorkouts(token)).map((p) => p.added_by)).toEqual([null])
    const fetched = await request('GET', `/v1/sync/workouts/${w.id}`, { token })
    expect((await fetched.json<WorkoutJSON>()).added_by).toBeNull()
  })

  it("is pulled as the agent's name, and an edit from the app keeps it", async () => {
    const { token } = await signUp()
    const w = workoutSample()
    const first = await saveWorkout(token, w)
    await markAdded(w.id, 'Muse')
    const edit = { ...w, name: 'Upper', client_updated_at: T2, base_updated_at: first.updated_at, added_by: null }
    expect((await saveWorkout(token, edit)).status).toBe('ok')
    expect(await pulledWorkouts(token)).toMatchObject([{ name: 'Upper', added_by: 'Muse' }])
  })

  it('is never set by the app: a save that sends one leaves it as it was', async () => {
    const { token } = await signUp()
    const fresh = workoutSample({ added_by: 'Forged' })
    await saveWorkout(token, fresh)
    const marked = workoutSample()
    const first = await saveWorkout(token, marked)
    await markAdded(marked.id, 'Muse')
    await saveWorkout(token, { ...marked, client_updated_at: T2, base_updated_at: first.updated_at, added_by: 'Forged' })
    const byId = Object.fromEntries((await pulledWorkouts(token)).map((p) => [p.id, p.added_by]))
    expect(byId).toEqual({ [fresh.id.toLowerCase()]: null, [marked.id.toLowerCase()]: 'Muse' })
  })
})
