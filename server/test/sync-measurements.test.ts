import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { request, signUp } from './helpers.ts'
import { appUUID, type Row, T0, T1, T2, workoutSample } from './samples.ts'

// Plan 40: what Apple Health measured during a workout syncs at /v1/sync/workout-measurements, one row per workout,
// keyed by the account and the workout's id (migrations/0014_workout_measurements.sql). Not among test/samples.ts'
// SAMPLES, which test/sync-rows.test.ts pushes for a new account: a row needs one of the caller's workouts first.

const STAMP = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/

interface Ack {
  id: string
  updated_at: string
}

const push = (token: string, rows: unknown) =>
  request('POST', '/v1/sync/workout-measurements', { token, body: { rows } })

async function acks(token: string, rows: Row[]): Promise<Ack[]> {
  const res = await push(token, rows)
  expect(res.status).toBe(200)
  return (await res.json<{ acks: Ack[] }>()).acks
}

async function pulled(token: string, query = ''): Promise<Row[]> {
  const res = await request('GET', `/v1/sync/workout-measurements${query}`, { token })
  expect(res.status).toBe(200)
  return (await res.json<{ rows: Row[] }>()).rows
}

/** A workout of this account, saved as the app saves it: `-seedHistory`'s Saturday session. Its id as sent. */
async function savedWorkout(token: string, change: Row = {}): Promise<{ id: string; updatedAt: string }> {
  const workout = workoutSample({
    name: 'Push + Biceps', started_at: '2026-09-19T18:00:00.000000Z', ended_at: '2026-09-19T18:58:20.000000Z',
    ...change,
  })
  const res = await request('POST', '/v1/sync/workouts', { token, body: workout })
  expect(res.status).toBe(200)
  return { id: workout.id, updatedAt: (await res.json<{ updated_at: string }>()).updated_at }
}

/** What the Apple Watch recorded for it, as WorkoutMeasurementDTO encodes it. */
const watch = (workoutId: string, change: Row = {}): Row => ({
  workout_id: workoutId, recorded_by: 'watch', duration_s: 3500, active_kcal: 412, total_kcal: 489, avg_hr: 128,
  max_hr: 162, post_hr: 124, effort: 6, effort_estimated: false, client_updated_at: T1, deleted_at: null, ...change,
})

describe('workout measurements', () => {
  it('store a row and answer it back as the app sent it, the workout id lowercased', async () => {
    const { token } = await signUp()
    const { id } = await savedWorkout(token)
    const row = watch(id)
    const [ack, ...more] = await acks(token, [row])
    expect(more).toEqual([])
    expect(ack.id).toBe(id.toLowerCase())
    expect(ack.updated_at).toMatch(STAMP)
    expect(await pulled(token)).toEqual([{ ...row, workout_id: id.toLowerCase(), updated_at: ack.updated_at }])
  })

  it('keep the numbers a row knows, an effort alone included', async () => {
    const { token } = await signUp()
    const { id } = await savedWorkout(token)
    const effortOnly = watch(id, {
      recorded_by: null, duration_s: null, active_kcal: null, total_kcal: null, avg_hr: null, max_hr: null,
      post_hr: null, effort: 5, effort_estimated: true,
    })
    await acks(token, [effortOnly])
    expect((await pulled(token))[0])
      .toMatchObject({ recorded_by: null, active_kcal: null, effort: 5, effort_estimated: true })
  })

  it('take an equal or newer edit, and skip an older one without an ack', async () => {
    const { token } = await signUp()
    const { id } = await savedWorkout(token)
    await acks(token, [watch(id)])
    expect(await acks(token, [watch(id)])).toHaveLength(1)
    expect(await acks(token, [watch(id, { effort: 8, client_updated_at: T2 })])).toHaveLength(1)
    expect(await acks(token, [watch(id, { effort: 3, client_updated_at: T0 })])).toEqual([])
    expect((await pulled(token))[0]).toMatchObject({ effort: 8, client_updated_at: T2 })
  })

  it.each([
    ['duration_s', 86401], ['active_kcal', -1], ['total_kcal', 20001], ['avg_hr', 19], ['max_hr', 251],
    ['post_hr', 251], ['effort', 0], ['effort', 11], ['recorded_by', 'phone'],
  ])('refuse %s = %s, and store nothing from that push', async (column, bad) => {
    const { token } = await signUp()
    const fine = await savedWorkout(token)
    const other = await savedWorkout(token)
    const res = await push(token, [watch(fine.id), watch(other.id, { [column]: bad })])
    expect(res.status).toBe(422)
    const body = await res.json<{ error: { code: string; message: string } }>()
    expect(body.error.code).toBe('row_rejected')
    expect(body.error.message).toMatch(/CHECK constraint failed/)
    expect(await pulled(token)).toEqual([])
  })

  it('refuse a value of the wrong type, naming the row and column', async () => {
    const { token } = await signUp()
    const { id } = await savedWorkout(token)
    const res = await push(token, [watch(id), watch(id, { effort_estimated: 'no' })])
    expect(res.status).toBe(422)
    expect(await res.json()).toEqual({
      error: { code: 'row_rejected', message: 'rows[1].effort_estimated is not a valid bool' },
    })
  })

  it("refuse numbers for another account's workout, or for none, and keep accounts apart", async () => {
    const a = await signUp()
    const b = await signUp()
    const { id } = await savedWorkout(a.token)
    for (const workoutId of [id, appUUID()]) {
      const res = await push(b.token, [watch(workoutId)])
      expect(res.status, workoutId).toBe(422)
      expect(await res.json()).toEqual({
        error: { code: 'row_rejected', message: `workout_id ${workoutId.toLowerCase()} is not one of your workouts` },
      })
    }
    await acks(a.token, [watch(id)])
    expect(await pulled(b.token)).toEqual([])
    expect(await pulled(a.token)).toHaveLength(1)
  })

  it('take the numbers of a workout another phone deleted: nothing reads them', async () => {
    const { token } = await signUp()
    const saved = await savedWorkout(token)
    await savedWorkout(token, {
      id: saved.id, deleted_at: T2, client_updated_at: T2, base_updated_at: saved.updatedAt,
    })
    expect(await acks(token, [watch(saved.id)])).toHaveLength(1)
  })

  it("go with their workout's row", async () => {
    const { token } = await signUp()
    const gone = await savedWorkout(token)
    const kept = await savedWorkout(token)
    await acks(token, [watch(gone.id), watch(kept.id)])
    await env.DB.prepare('DELETE FROM workouts WHERE id = ?1').bind(gone.id.toLowerCase()).run()
    expect((await pulled(token)).map((r) => r.workout_id)).toEqual([kept.id.toLowerCase()])
  })

  it('page by (updated_at, workout_id) without gaps or repeats', async () => {
    const { token } = await signUp()
    const ids = [(await savedWorkout(token)).id, (await savedWorkout(token)).id, (await savedWorkout(token)).id]
    await acks(token, ids.map((id) => watch(id)))
    const seen: Row[] = []
    let query = '?limit=2'
    for (;;) {
      const page = await pulled(token, query)
      seen.push(...page)
      if (page.length < 2) break
      const last = page[page.length - 1]!
      query = `?limit=2&since=${encodeURIComponent(String(last.updated_at))}` +
        `&after=${encodeURIComponent(String(last.workout_id))}`
    }
    expect(seen.map((r) => r.workout_id).sort()).toEqual(ids.map((id) => id.toLowerCase()).sort())
  })
})
