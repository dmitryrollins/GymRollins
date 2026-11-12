import { env } from 'cloudflare:workers'
import { beforeAll, describe, expect, it } from 'vitest'
import app from '../src/index.ts'
import { storedRow } from '../src/sync/columns.ts'
import { ENTITIES } from '../src/sync/entities.ts'
import { upsertSql } from '../src/sync/table-sync.ts'
import { ORIGIN, request, signUp } from './helpers.ts'
import { appUUID, BAD, KEY, pulled, type Row, SAMPLES, sampleNeeds, T0, T1, T2 } from './samples.ts'

beforeAll(sampleNeeds)

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

describe.each(Object.keys(SAMPLES))('%s', (entity) => {
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

  it.each(['?limit=0', '?limit=1001', '?limit=two', '?since=yesterday', '?after=x',
    '?since=2026-11-07T10:00:00Z&after='])('refuses %s', async (query) => {
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

  it('ignore a session cookie without a bearer token', async () => {
    // Better Auth's own signed session cookie, as a browser would hold it.
    const signedUp = await request('POST', '/api/auth/sign-up/email', {
      body: { email: `c-${crypto.randomUUID()}@test.local`, password: 'correct-horse-battery', name: 'Cookie' },
    })
    const cookie = signedUp.headers.get('set-cookie')!.split(';')[0]!
    const res = await app.fetch(new Request(`${ORIGIN}/v1/sync/routines`, { headers: { cookie } }), env)
    expect(res.status).toBe(401)
    expect(await res.json()).toMatchObject({ error: { code: 'signed_out' } })
  })

  it("ignore a session cookie next to a bearer token that fails its signature (Better Auth's cookie fallback)",
    async () => {
      const signedUp = await request('POST', '/api/auth/sign-up/email', {
        body: { email: `c-${crypto.randomUUID()}@test.local`, password: 'correct-horse-battery', name: 'Cookie' },
      })
      const cookie = signedUp.headers.get('set-cookie')!.split(';')[0]!
      const token = signedUp.headers.get('set-auth-token')!
      const headers = (authorization: string) => ({ cookie, authorization })
      for (const bearer of ['Bearer x.y', 'Bearer not-a-token', `Bearer ${token.split('.')[0]}.forged`]) {
        const res = await app.fetch(new Request(`${ORIGIN}/v1/sync/routines`, { headers: headers(bearer) }), env)
        expect(res.status, bearer).toBe(401)
        expect(await res.json()).toMatchObject({ error: { code: 'signed_out' } })
      }
      const ok = await app.fetch(new Request(`${ORIGIN}/v1/sync/routines`, { headers: { authorization: `Bearer ${token}` } }), env)
      expect(ok.status).toBe(200)
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

describe('review follow-ups', () => {
  it("the upsert's own WHERE keeps another account's row, without the pre-check", async () => {
    const a = await signUp()
    const b = await signUp()
    const row = SAMPLES.routines()
    await acks(a.token, 'routines', [row])
    const hijack = storedRow(ENTITIES.routines.columns, { ...row, name: 'Hijacked', client_updated_at: T2 }, 'rows[0]')
    const { results } = await env.DB.prepare(upsertSql(ENTITIES.routines)).bind(JSON.stringify([hijack]), b.userId).all()
    expect(results).toEqual([])
    const [mine] = await pull(a.token, 'routines')
    expect(mine.name).toBe('Push')
  })

  it('takes the same key twice in one push, the later edit winning', async () => {
    const { token } = await signUp()
    const row = SAMPLES.routines()
    const res = await push(token, 'routines', [
      { ...row, name: 'A', client_updated_at: T1 },
      { ...row, name: 'B', client_updated_at: T2 },
    ])
    expect(res.status).toBe(200)
    const [stored] = await pull(token, 'routines')
    expect(stored.name).toBe('B')
    expect(stored.client_updated_at).toBe(T2)
  })

  it('pulls tombstones', async () => {
    const { token } = await signUp()
    await acks(token, 'routines', [{ ...SAMPLES.routines(), deleted_at: T1 }])
    const [stored] = await pull(token, 'routines')
    expect(stored.deleted_at).toBe(T1)
  })

  it('lets a day go back to a rest day, and point at a tombstoned routine of yours', async () => {
    const { token } = await signUp()
    const routine = SAMPLES.routines()
    await acks(token, 'routines', [routine])
    await acks(token, 'weekdays', [{ ...SAMPLES.weekdays(), weekday: 1, routine_id: routine.id }])
    await acks(token, 'weekdays', [{ ...SAMPLES.weekdays(), weekday: 1, routine_id: null, client_updated_at: T2 }])
    expect((await pull(token, 'weekdays'))[0].routine_id).toBeNull()
    const gone: Row = { ...SAMPLES.routines(), deleted_at: T1 }
    await acks(token, 'routines', [gone])
    expect(await acks(token, 'weekdays', [{ ...SAMPLES.weekdays(), weekday: 2, routine_id: gone.id }])).toHaveLength(1)
  })

  it('answers 413 for a body over 1 MiB', async () => {
    const { token } = await signUp()
    const res = await push(token, 'routines', [{ ...SAMPLES.routines(), name: 'x'.repeat(1024 * 1024 + 1) }])
    expect(res.status).toBe(413)
    expect(await res.json()).toMatchObject({ error: { code: 'too_large' } })
  })

  it('refuses a JSON column with half a UTF-16 pair inside, which the app could not decode back', async () => {
    const { token } = await signUp()
    const row = SAMPLES.routines()
    const exercises = [{ ...(row.exercises as Row[])[0], exercise_id: 'bench\uD800' }]
    const res = await push(token, 'routines', [{ ...row, exercises }])
    expect(res.status).toBe(422)
    expect(await res.json()).toEqual({ error: { code: 'row_rejected', message: 'rows[0].exercises is not a valid json' } })
    expect(await pull(token, 'routines')).toEqual([])
  })

  it('refuses a non-numeric after on the week', async () => {
    const { token } = await signUp()
    const res = await request('GET', '/v1/sync/weekdays?since=2026-11-07T10:00:00Z&after=1x', { token })
    expect(res.status).toBe(400)
  })
})

describe("a routine exercise's pound number", () => {
  it('is kept in the exercises JSON as weight_lb, and an exercise without it stays as it was', async () => {
    const { token } = await signUp()
    const row = SAMPLES.routines()
    const [kgOnly] = row.exercises as Record<string, unknown>[]
    row.exercises = [{ ...kgOnly, weight_kg: 20.41165665, weight_lb: 45 }, { ...kgOnly, id: appUUID(), position: 1 }]
    await acks(token, 'routines', [row])
    const [pulled] = await pull(token, 'routines')
    const [a, b] = pulled.exercises as Record<string, unknown>[]
    expect([a.weight_kg, a.weight_lb]).toEqual([20.41165665, 45])
    expect(b.weight_lb).toBeUndefined()
  })
})
