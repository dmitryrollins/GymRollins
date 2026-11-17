import { describe, expect, it } from 'vitest'
import { request, signUp } from './helpers.ts'
import { type Row, SAMPLES, T1, T2 } from './samples.ts'

// Plan 39: outside workouts and days of activity sync like the other tables (test/sync-rows.test.ts runs the generic
// rules on both). These are the parts of their own.

const push = (token: string, entity: string, rows: Row[]) =>
  request('POST', `/v1/sync/${entity}`, { token, body: { rows } })

async function pulled(token: string, entity: string): Promise<Row[]> {
  const res = await request('GET', `/v1/sync/${entity}`, { token })
  expect(res.status).toBe(200)
  return (await res.json<{ rows: Row[] }>()).rows
}

describe('outside workouts', () => {
  it("keep Health's deletion against an older live copy", async () => {
    const { token } = await signUp()
    const row = SAMPLES['health-activities']()
    expect((await push(token, 'health-activities', [{ ...row, client_updated_at: T1 }])).status).toBe(200)
    expect((await push(token, 'health-activities', [{ ...row, client_updated_at: T2, deleted_at: T2 }])).status)
      .toBe(200)
    const stale = await push(token, 'health-activities', [{ ...row, client_updated_at: T1, deleted_at: null }])
    expect((await stale.json<{ acks: unknown[] }>()).acks).toEqual([])
    expect((await pulled(token, 'health-activities'))[0]?.deleted_at).toBe(T2)
  })

  it("keep a ride's average power, average cadence and total kcal", async () => {
    const { token } = await signUp()
    const ride = {
      ...SAMPLES['health-activities'](), kind: 'cycling', distance_m: null, kcal: 40, avg_power_w: 138,
      avg_cadence_rpm: 62, total_kcal: 48,
    }
    expect((await push(token, 'health-activities', [ride])).status).toBe(200)
    expect((await pulled(token, 'health-activities'))[0])
      .toMatchObject({ avg_power_w: 138, avg_cadence_rpm: 62, total_kcal: 48, kcal: 40 })
  })

  it.each([
    ['avg_power_w', 2500, 2501],
    ['avg_cadence_rpm', 250, 251],
    ['total_kcal', 20000, 20001],
  ])('take %s from 0 through %i and refuse %i or below 0', async (column, max, over) => {
    const { token } = await signUp()
    for (const fits of [0, max]) {
      const res = await push(token, 'health-activities', [{ ...SAMPLES['health-activities'](), [column]: fits }])
      expect(res.status, `${column} = ${fits}`).toBe(200)
    }
    for (const bad of [-1, over]) {
      const res = await push(token, 'health-activities', [{ ...SAMPLES['health-activities'](), [column]: bad }])
      expect(res.status, `${column} = ${bad}`).toBe(422)
      expect((await res.json<{ error: { code: string } }>()).error.code).toBe('row_rejected')
    }
  })

  it('refuse one that ends before it starts', async () => {
    const { token } = await signUp()
    const res = await push(token, 'health-activities', [
      { ...SAMPLES['health-activities'](), ended_at: '2026-11-06T06:59:59.000000Z' },
    ])
    expect(res.status).toBe(422)
    expect((await res.json<{ error: { code: string } }>()).error.code).toBe('row_rejected')
  })
})

describe('days of activity', () => {
  it('keep one row per day, the newer edit winning, stand hours optional', async () => {
    const { token } = await signUp()
    const day = SAMPLES['activity-days']()
    await push(token, 'activity-days', [day])
    await push(token, 'activity-days', [{ ...day, steps: 9001, stand_h: 11, client_updated_at: T2 }])
    await push(token, 'activity-days', [{ ...day, steps: 1, client_updated_at: T1 }])
    const rows = await pulled(token, 'activity-days')
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({ day: day.day, steps: 9001, stand_h: 11, client_updated_at: T2 })
  })
})
