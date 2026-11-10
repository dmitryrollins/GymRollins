import { describe, expect, it } from 'vitest'
import { request, signUp } from './helpers.ts'
import { appUUID, type Row, SAMPLES, T1, T2 } from './samples.ts'

async function acks(token: string, rows: Row[]): Promise<unknown[]> {
  const res = await request('POST', '/v1/sync/bodyweight', { token, body: { rows } })
  expect(res.status).toBe(200)
  return (await res.json<{ acks: unknown[] }>()).acks
}

async function stored(token: string): Promise<Row> {
  const res = await request('GET', '/v1/sync/bodyweight', { token })
  const { rows } = await res.json<{ rows: Row[] }>()
  expect(rows).toHaveLength(1)
  return rows[0]
}

const fromHealth = (): Row => ({ ...SAMPLES.bodyweight(), source: 'apple_health', health_sample_id: appUUID() })

describe('body weight from Apple Health', () => {
  it('keeps a weigh-in Health deleted deleted, even against a newer live edit', async () => {
    const { token } = await signUp()
    const row = fromHealth()
    await acks(token, [{ ...row, client_updated_at: T1, deleted_at: T1 }])
    expect(await acks(token, [{ ...row, client_updated_at: T2, deleted_at: null }])).toEqual([])
    expect((await stored(token)).deleted_at).toBe(T1)
  })

  it("lets Health's deletion win over a newer edit, keeping the newer edit's time", async () => {
    const { token } = await signUp()
    const row = fromHealth()
    await acks(token, [{ ...row, client_updated_at: T2 }])
    expect(await acks(token, [{ ...row, client_updated_at: T1, deleted_at: T1 }])).toHaveLength(1)
    const now = await stored(token)
    expect(now.deleted_at).toBe(T1)
    expect(now.client_updated_at).toBe(T2)
  })

  it('counts the sample id a deletion brings with it', async () => {
    const { token } = await signUp()
    const row = SAMPLES.bodyweight()
    await acks(token, [{ ...row, client_updated_at: T2 }])
    const deletion = { ...row, health_sample_id: appUUID(), client_updated_at: T1, deleted_at: T1 }
    expect(await acks(token, [deletion])).toHaveLength(1)
  })

  it('treats a weigh-in from the app by plain last-write-wins', async () => {
    const { token } = await signUp()
    const row = SAMPLES.bodyweight()
    await acks(token, [{ ...row, client_updated_at: T2 }])
    expect(await acks(token, [{ ...row, client_updated_at: T1, deleted_at: T1 }])).toEqual([])
    expect((await stored(token)).deleted_at).toBeNull()
    expect(await acks(token, [{ ...row, client_updated_at: T2, deleted_at: T2 }])).toHaveLength(1)
    expect(await acks(token, [{ ...row, client_updated_at: '2026-11-07T12:00:00.000000Z', deleted_at: null }]))
      .toHaveLength(1)
    expect((await stored(token)).deleted_at).toBeNull()
  })
})
