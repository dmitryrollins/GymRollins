import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { signUp } from './helpers.ts'

// Migration 0014 (plan 40) on D1 itself: workout_measurements' CHECKs, its key and its foreign keys. The sync route's
// own rules are in test/sync-measurements.test.ts.

const T = '2026-09-19T19:00:00.000000Z'
const DB = env.DB

/** A finished workout of `userId`: `-seedHistory`'s Saturday session, 18:00 to 18:58:20 UTC. */
async function workoutOf(userId: string): Promise<string> {
  const id = crypto.randomUUID()
  await DB.prepare(
    'INSERT INTO workouts (id, user_id, started_at, ended_at, name, client_updated_at, updated_at) ' +
      "VALUES (?1, ?2, '2026-09-19T18:00:00.000000Z', '2026-09-19T18:58:20.000000Z', 'Push + Biceps', ?3, ?3)",
  ).bind(id, userId, T).run()
  return id
}

/** The Apple Watch's numbers for that workout, with `change` over them. */
function insert(userId: string, workoutId: string, change: Record<string, unknown> = {}) {
  const row: Record<string, unknown> = {
    user_id: userId, workout_id: workoutId, recorded_by: 'watch', duration_s: 3500, active_kcal: 412,
    total_kcal: 489, avg_hr: 128, max_hr: 162, post_hr: 124, effort: 6, effort_estimated: 0, client_updated_at: T,
    updated_at: T, deleted_at: null, ...change,
  }
  const columns = Object.keys(row)
  return DB.prepare(
    `INSERT INTO workout_measurements (${columns.join(', ')}) ` +
      `VALUES (${columns.map((_, i) => `?${i + 1}`).join(', ')})`,
  ).bind(...columns.map((c) => row[c])).run()
}

const rowsOf = async (userId: string) =>
  (await DB.prepare('SELECT count(*) AS n FROM workout_measurements WHERE user_id = ?1').bind(userId)
    .first<{ n: number }>())!.n

describe('workout_measurements', () => {
  it('stores what the Watch measured, and a row that knows only the effort', async () => {
    const { userId } = await signUp()
    await insert(userId, await workoutOf(userId))
    await insert(userId, await workoutOf(userId), {
      recorded_by: null, duration_s: null, active_kcal: null, total_kcal: null, avg_hr: null, max_hr: null,
      post_hr: null, effort: 5, effort_estimated: 1,
    })
    await insert(userId, await workoutOf(userId), { recorded_by: 'apple_workout', total_kcal: null, effort: null })
    expect(await rowsOf(userId)).toBe(3)
  })

  it.each([
    ['duration_s', 0, 86400, -1, 86401],
    ['active_kcal', 0, 20000, -1, 20001],
    ['total_kcal', 0, 20000, -1, 20001],
    ['avg_hr', 20, 250, 19, 251],
    ['max_hr', 20, 250, 19, 251],
    ['post_hr', 20, 250, 19, 251],
    ['effort', 1, 10, 0, 11],
  ])('takes %s from %i through %i, and refuses %i and %i', async (column, low, high, under, over) => {
    const { userId } = await signUp()
    for (const fits of [low, high]) {
      await expect(insert(userId, await workoutOf(userId), { [column]: fits }), `${column} = ${fits}`).resolves
        .toBeTruthy()
    }
    for (const bad of [under, over]) {
      await expect(insert(userId, await workoutOf(userId), { [column]: bad }), `${column} = ${bad}`).rejects
        .toThrow(/CHECK constraint failed/)
    }
  })

  it.each([
    ['recorded_by', 'phone'],
    ['effort_estimated', 2],
    ['client_updated_at', '2026-09-19T19:00:00Z'],
    ['updated_at', '2026-09-19 19:00:00.000000Z'],
    ['deleted_at', '2026-09-19T19:00:00.00000Z'],
  ])('refuses %s = %s', async (column, bad) => {
    const { userId } = await signUp()
    await expect(insert(userId, await workoutOf(userId), { [column]: bad })).rejects.toThrow(/CHECK constraint failed/)
  })

  it('keeps one row per account and workout', async () => {
    const { userId } = await signUp()
    const workoutId = await workoutOf(userId)
    await insert(userId, workoutId)
    await expect(insert(userId, workoutId, { effort: 7 })).rejects.toThrow(/UNIQUE constraint failed/)
  })

  it("needs its workout, and goes with the workout's row and with the account", async () => {
    const { userId } = await signUp()
    await expect(insert(userId, crypto.randomUUID())).rejects.toThrow(/FOREIGN KEY constraint failed/)
    const gone = await workoutOf(userId)
    await insert(userId, gone)
    await insert(userId, await workoutOf(userId))
    await DB.prepare('DELETE FROM workouts WHERE id = ?1').bind(gone).run()
    expect(await rowsOf(userId)).toBe(1)
    await DB.prepare('DELETE FROM "user" WHERE id = ?1').bind(userId).run()
    expect(await rowsOf(userId)).toBe(0)
  })
})
