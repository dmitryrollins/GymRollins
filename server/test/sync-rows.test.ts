import { describe, expect, it } from 'vitest'
import { ENTITIES } from '../src/sync/entities.ts'
import { request, signUp } from './helpers.ts'
import { BAD, KEY, pulled, type Row, SAMPLES, T0, T1, T2 } from './samples.ts'

interface Ack {
  id: string
  updated_at: string
}

const STAMP = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/

const push = (token: string, entity: string, rows: unknown) =>
  request('POST', `/v1/sync/${entity}`, { token, body: { rows } })

async function acks(token: string, entity: string, rows: Row[]): Promise<Ack[]> {
  const res = await push(token, entity, rows)
  expect(res.status).toBe(200)
  return (await res.json<{ acks: Ack[] }>()).acks
}

async function pull(token: string, entity: string, query = ''): Promise<Row[]> {
  const res = await request('GET', `/v1/sync/${entity}${query}`, { token })
  expect(res.status).toBe(200)
  return (await res.json<{ rows: Row[] }>()).rows
}

describe.each(Object.keys(ENTITIES))('%s', (entity) => {
  it('stores a row and answers it back as the app sent it', async () => {
    const { token, userId } = await signUp()
    const row = SAMPLES[entity]()
    const [ack, ...more] = await acks(token, entity, [row])
    expect(more).toEqual([])
    expect(ack.id).toBe(KEY[entity](row, userId))
    expect(ack.updated_at).toMatch(STAMP)
    expect(await pull(token, entity)).toEqual([pulled(entity, row, ack.updated_at, userId)])
  })

  it('takes an equal or newer edit, and skips an older one without an ack', async () => {
    const { token } = await signUp()
    const row = SAMPLES[entity]()
    await acks(token, entity, [{ ...row, client_updated_at: T1 }])
    expect(await acks(token, entity, [{ ...row, client_updated_at: T1 }])).toHaveLength(1)
    expect(await acks(token, entity, [{ ...row, client_updated_at: T2 }])).toHaveLength(1)
    expect(await acks(token, entity, [{ ...row, client_updated_at: T0 }])).toEqual([])
    const [stored] = await pull(token, entity)
    expect(stored.client_updated_at).toBe(T2)
  })

  it('keeps accounts apart', async () => {
    const a = await signUp()
    const b = await signUp()
    const row = SAMPLES[entity]()
    await acks(a.token, entity, [{ ...row, client_updated_at: T1 }])
    expect(await pull(b.token, entity)).toEqual([])
    const res = await push(b.token, entity, [{ ...row, client_updated_at: T2 }])
    if (ENTITIES[entity].conflict.includes('user_id')) {
      expect(res.status).toBe(200)
      expect(await pull(b.token, entity)).toHaveLength(1)
    } else {
      expect(res.status).toBe(403)
      expect(await res.json()).toMatchObject({ error: { code: 'not_allowed' } })
    }
    const [mine] = await pull(a.token, entity)
    expect(mine.client_updated_at).toBe(T1)
  })

  it('refuses a row that breaks a rule, and stores nothing from that push', async () => {
    const { token } = await signUp()
    const bad = { ...SAMPLES[entity](), ...BAD[entity] }
    const res = await push(token, entity, entity === 'profile' ? [bad] : [SAMPLES[entity](), bad])
    expect(res.status).toBe(422)
    const body = await res.json<{ error: { code: string; message: string } }>()
    expect(body.error.code).toBe('row_rejected')
    expect(body.error.message).toMatch(/CHECK constraint failed/)
    expect(await pull(token, entity)).toEqual([])
  })

  it('refuses a value of the wrong type, naming the row and column', async () => {
    const { token } = await signUp()
    const res = await push(token, entity, [SAMPLES[entity](), { ...SAMPLES[entity](), client_updated_at: 'yesterday' }])
    expect(res.status).toBe(422)
    expect(await res.json()).toEqual({
      error: { code: 'row_rejected', message: 'rows[1].client_updated_at is not a valid ts' },
    })
  })
})

describe('pulling', () => {
  it('pages by (updated_at, key) without gaps or repeats', async () => {
    const { token } = await signUp()
    const rows = Array.from({ length: 5 }, () => SAMPLES.routines())
    await acks(token, 'routines', rows)
    const seen: Row[] = []
    let query = '?limit=2'
    for (;;) {
      const page = await pull(token, 'routines', query)
      seen.push(...page)
      if (page.length < 2) break
      const last = page[page.length - 1]
      query = `?limit=2&since=${encodeURIComponent(String(last.updated_at))}&after=${encodeURIComponent(String(last.id))}`
    }
    expect(seen.map((r) => r.id).sort()).toEqual(rows.map((r) => String(r.id).toLowerCase()).sort())
  })

  it('pages the week by weekday number', async () => {
    const { token } = await signUp()
    await acks(token, 'weekdays', [1, 2, 3].map((weekday) => ({ ...SAMPLES.weekdays(), weekday })))
    const first = await pull(token, 'weekdays', '?limit=1')
    expect(first.map((r) => r.weekday)).toEqual([1])
    const since = encodeURIComponent(String(first[0].updated_at))
    expect((await pull(token, 'weekdays', `?limit=5&since=${since}&after=1`)).map((r) => r.weekday)).toEqual([2, 3])
  })

  it('answers only rows changed after `since`', async () => {
    const { token } = await signUp()
    const [ack] = await acks(token, 'routines', [SAMPLES.routines()])
    expect(await pull(token, 'routines', `?since=${encodeURIComponent(ack.updated_at)}`)).toEqual([])
  })

  it('answers as many rows as the limit asks for (the app stops at a short page)', async () => {
    const { token } = await signUp()
    await acks(token, 'routines', Array.from({ length: 3 }, () => SAMPLES.routines()))
    expect(await pull(token, 'routines', '?limit=3')).toHaveLength(3)
  })

  it.each(['?limit=0', '?limit=1001', '?limit=two', '?since=yesterday', '?after=x'])('refuses %s', async (query) => {
    const { token } = await signUp()
    const res = await request('GET', `/v1/sync/routines${query}`, { token })
    expect(res.status).toBe(400)
    expect(await res.json()).toMatchObject({ error: { code: 'bad_request' } })
  })
})

describe('the week', () => {
  it("takes a day with one of your routines, and refuses someone else's", async () => {
    const a = await signUp()
    const b = await signUp()
    const routine = SAMPLES.routines()
    await acks(a.token, 'routines', [routine])
    const [ack] = await acks(a.token, 'weekdays', [{ ...SAMPLES.weekdays(), weekday: 1, routine_id: routine.id }])
    expect(ack.id).toBe('1')
    const res = await push(b.token, 'weekdays', [{ ...SAMPLES.weekdays(), routine_id: routine.id }])
    expect(res.status).toBe(422)
    expect(await res.json()).toMatchObject({ error: { code: 'row_rejected' } })
  })
})

describe('the sync routes', () => {
  it('need a session', async () => {
    for (const res of [await request('GET', '/v1/sync/routines'), await push('not-a-token', 'routines', [])]) {
      expect(res.status).toBe(401)
      expect(await res.json()).toEqual({ error: { code: 'signed_out', message: 'Sign in required.' } })
    }
  })

  it('answer an unknown table with 404', async () => {
    const { token } = await signUp()
    expect((await request('GET', '/v1/sync/nope', { token })).status).toBe(404)
  })

  it('refuse a body that is not JSON, has no rows, or has too many', async () => {
    const { token } = await signUp()
    expect((await request('POST', '/v1/sync/routines', { token, body: 'nope' })).status).toBe(400)
    expect((await request('POST', '/v1/sync/routines', { token, body: {} })).status).toBe(400)
    const many = Array.from({ length: 501 }, () => SAMPLES.routines())
    expect((await push(token, 'routines', many)).status).toBe(400)
  })

  it('answer an empty push with no acks', async () => {
    const { token } = await signUp()
    expect(await acks(token, 'routines', [])).toEqual([])
  })
})
