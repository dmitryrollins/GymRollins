import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { genericItem, insertGym, insertItem, uploadedPhoto } from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'
import { appUUID, type Row, T1, T2 } from './samples.ts'

type Entity = 'gyms' | 'gym-listings'

const push = (token: string, entity: Entity, rows: unknown[]) =>
  request('POST', `/v1/sync/${entity}`, { token, body: { rows } })

async function pull(token: string, entity: Entity): Promise<Row[]> {
  const res = await request('GET', `/v1/sync/${entity}`, { token })
  expect(res.status).toBe(200)
  return (await res.json<{ rows: Row[] }>()).rows
}

async function refusal(res: Response, status = 422): Promise<{ code: string; message: string }> {
  expect(res.status).toBe(status)
  return (await res.json<{ error: { code: string; message: string } }>()).error
}

const count = async (sql: string, ...bindings: unknown[]) =>
  (await env.DB.prepare(sql).bind(...bindings).first<{ n: number }>())!.n

/** A private gym as GymDTO encodes it. */
const gymRow = (overrides: Row = {}): Row => ({
  id: appUUID(), visibility: 'private', name: 'Home', address: null, latitude: null, longitude: null,
  client_updated_at: T1, deleted_at: null, ...overrides,
})

/** A private listing as GymListingDTO encodes it: the kind's generic item, any brand and model on the listing. */
const listingRow = async (gymId: string, overrides: Row = {}): Promise<Row> => ({
  id: appUUID(), gym_id: gymId.toUpperCase(), item_id: (await genericItem('dumbbells')).toUpperCase(),
  visibility: 'private', photo_path: null, loads: { type: 'fixed', kg: [20, 24] }, quantity: 1, notes: null,
  private_brand: null, private_model: null, client_updated_at: T1, deleted_at: null, ...overrides,
})

/** An account with one private gym synced. */
async function withGym() {
  const account = await signUp()
  const gym = gymRow()
  expect((await push(account.token, 'gyms', [gym])).status).toBe(200)
  return { ...account, gymId: String(gym.id).toLowerCase() }
}

describe('private gyms', () => {
  it('are stored with the caller as owner and author, and a pull answers only their private gyms', async () => {
    const { token, userId } = await signUp()
    await insertGym({ visibility: 'public', createdBy: userId })
    const gym = gymRow()
    expect((await push(token, 'gyms', [gym])).status).toBe(200)
    const rows = await pull(token, 'gyms')
    expect(rows.map((r) => r.id)).toEqual([String(gym.id).toLowerCase()])
    const stored = await env.DB.prepare('SELECT owner_id, created_by, created_at, status FROM gyms WHERE id = ?1')
      .bind(String(gym.id).toLowerCase()).first<Row>()
    expect(stored).toMatchObject({ owner_id: userId, created_by: userId, status: 'active' })
    expect(stored!.created_at).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/)
  })

  it('refuse hidden characters, and a push that would make a gym public', async () => {
    const { token } = await signUp()
    expect(await refusal(await push(token, 'gyms', [gymRow({ name: 'Home\u200B' })]))).toEqual({
      code: 'row_rejected', message: 'rows[0].name has hidden or control characters',
    })
    expect((await refusal(await push(token, 'gyms', [gymRow({ visibility: 'public' })]))).code).toBe('row_rejected')
    expect(await pull(token, 'gyms')).toEqual([])
  })

  it('refuse an id that a public gym holds, and leave that gym alone', async () => {
    const { token, userId } = await signUp()
    const shared = await insertGym({ visibility: 'public', createdBy: userId })
    expect((await refusal(await push(token, 'gyms', [gymRow({ id: shared, client_updated_at: T2 })]), 403)).code)
      .toBe('not_allowed')
    expect(await count("SELECT count(*) AS n FROM gyms WHERE id = ?1 AND visibility = 'public' AND name = 'Test gym'",
      shared)).toBe(1)
  })

  it('hold 100 live gyms per account; the 101st is refused, an edit at the cap is not, and a deletion frees a slot',
    async () => {
      const { token } = await signUp()
      const gyms = Array.from({ length: 100 }, () => gymRow())
      expect((await push(token, 'gyms', gyms)).status).toBe(200)
      expect(await refusal(await push(token, 'gyms', [gymRow()]))).toEqual({
        code: 'too_many_gyms', message: "You've reached the limit of gyms on one account.",
      })
      expect((await push(token, 'gyms', [{ ...gyms[0], name: 'Renamed', client_updated_at: T2 }])).status).toBe(200)
      expect((await push(token, 'gyms', [{ ...gyms[1], deleted_at: T2, client_updated_at: T2 }])).status).toBe(200)
      expect((await push(token, 'gyms', [gymRow()])).status).toBe(200)
    })

  it("don't count tombstones, and refuse reviving past the cap without reviving any", async () => {
    const { token, userId } = await signUp()
    const live = Array.from({ length: 100 }, () => gymRow())
    const tombstones = Array.from({ length: 150 }, () => gymRow({ deleted_at: T1 }))
    expect((await push(token, 'gyms', live)).status).toBe(200)
    expect((await push(token, 'gyms', tombstones)).status).toBe(200)
    const revived = tombstones.slice(0, 3).map((g) => ({ ...g, deleted_at: null, client_updated_at: T2 }))
    expect((await refusal(await push(token, 'gyms', revived))).code).toBe('too_many_gyms')
    expect(await count('SELECT count(*) AS n FROM gyms WHERE owner_id = ?1 AND deleted_at IS NULL', userId)).toBe(100)
    const freed = live.slice(0, 3).map((g) => ({ ...g, deleted_at: T2, client_updated_at: T2 }))
    expect((await push(token, 'gyms', freed)).status).toBe(200)
    expect((await push(token, 'gyms', revived)).status).toBe(200)
  })
})

describe('private listings', () => {
  it('round-trip as GymListingDTO decodes them: the kind nested, loads parsed, brand and model on the listing',
    async () => {
      const { token, gymId } = await withGym()
      const row = await listingRow(gymId, { private_brand: 'Secret Brand', private_model: 'X', notes: 'by the door\nleft' })
      const res = await push(token, 'gym-listings', [row])
      expect(res.status).toBe(200)
      const [ack] = (await res.json<{ acks: { id: string; updated_at: string }[] }>()).acks
      expect(await pull(token, 'gym-listings')).toEqual([{
        ...row, id: String(row.id).toLowerCase(), gym_id: gymId, item_id: String(row.item_id).toLowerCase(),
        updated_at: ack.updated_at, equipment_items: { kind_id: 'dumbbells' },
      }])
      expect(await count("SELECT count(*) AS n FROM equipment_items WHERE brand = 'Secret Brand'")).toBe(0)
    })

  it('store loads compact, and refuse a shape the app could not read', async () => {
    const { token, gymId } = await withGym()
    const row = await listingRow(gymId, { loads: { kg: [20, 24], type: 'fixed' } })
    expect((await push(token, 'gym-listings', [row])).status).toBe(200)
    const stored = await env.DB.prepare('SELECT loads FROM gym_equipment WHERE id = ?1')
      .bind(String(row.id).toLowerCase()).first<{ loads: string }>()
    expect(stored!.loads).toBe('{"type":"fixed","kg":[20,24]}')
    const bad = await listingRow(gymId, { loads: { type: 'plates', html: '<script>' } })
    expect(await refusal(await push(token, 'gym-listings', [bad]))).toEqual({
      code: 'row_rejected', message: 'rows[0].loads is not a valid loads',
    })
  })

  it("refuse a gym that is missing or someone else's private gym with the same answer, and take a public gym",
    async () => {
      const a = await withGym()
      const b = await withGym()
      const missing = await refusal(await push(a.token, 'gym-listings', [await listingRow(crypto.randomUUID())]))
      const theirs = await refusal(await push(a.token, 'gym-listings', [await listingRow(b.gymId)]))
      expect(missing).toEqual({ code: 'row_rejected', message: 'rows[0].gym_id: unknown gym' })
      expect(theirs).toEqual(missing)
      const shared = await insertGym({ visibility: 'public', createdBy: b.userId })
      expect((await push(a.token, 'gym-listings', [await listingRow(shared)])).status).toBe(200)
    })

  it('refuse a branded catalogue item: brand and model stay on the listing', async () => {
    const { token, userId, gymId } = await withGym()
    const item = await insertItem({ brand: 'Acme', model: 'P1', createdBy: userId })
    expect(await refusal(await push(token, 'gym-listings', [await listingRow(gymId, { item_id: item })]))).toEqual({
      code: 'row_rejected', message: 'rows[0].item_id: a private listing uses a generic item',
    })
  })

  it("take the caller's own stored photo, and refuse a missing, unfinished or someone else's", async () => {
    const a = await withGym()
    const b = await signUp()
    const mine = await uploadedPhoto(a.userId, 'gym-photos-private')
    expect((await push(a.token, 'gym-listings', [await listingRow(a.gymId, { photo_path: mine })])).status).toBe(200)
    const theirs = await uploadedPhoto(b.userId, 'gym-photos-private')
    const unfinished = await uploadedPhoto(a.userId, 'gym-photos-private', { stored: false })
    const shared = await uploadedPhoto(a.userId, 'gym-photos')
    for (const photo of [theirs, unfinished, shared, `${crypto.randomUUID()}.jpg`]) {
      const res = await push(a.token, 'gym-listings', [await listingRow(a.gymId, { photo_path: photo })])
      expect(await refusal(res)).toEqual({ code: 'photo_missing', message: "That photo isn't uploaded." })
    }
  })

  it('check a photo only when it is new or changed', async () => {
    const { token, userId, gymId } = await withGym()
    const photo = await uploadedPhoto(userId, 'gym-photos-private')
    const row = await listingRow(gymId, { photo_path: photo })
    expect((await push(token, 'gym-listings', [row])).status).toBe(200)
    await env.GYM_PHOTOS_PRIVATE.delete(photo)
    await env.DB.prepare('DELETE FROM photo_objects WHERE name = ?1').bind(photo).run()
    expect((await push(token, 'gym-listings', [{ ...row, quantity: 2, client_updated_at: T2 }])).status).toBe(200)
  })

  it("refuse another account's listing id, and keep each account's listings to itself", async () => {
    const a = await withGym()
    const b = await withGym()
    const row = await listingRow(a.gymId)
    expect((await push(a.token, 'gym-listings', [row])).status).toBe(200)
    const hijack = await push(b.token, 'gym-listings', [{ ...row, gym_id: b.gymId, client_updated_at: T2 }])
    expect((await refusal(hijack, 403)).code).toBe('not_allowed')
    const tombstone = await push(b.token, 'gym-listings', [{ ...row, gym_id: b.gymId, deleted_at: T2, client_updated_at: T2 }])
    expect((await refusal(tombstone, 403)).code).toBe('not_allowed')
    expect(await pull(b.token, 'gym-listings')).toEqual([])
    expect((await pull(a.token, 'gym-listings'))[0]).toMatchObject({ client_updated_at: T1, deleted_at: null })
  })

  it('hold 1000 live listings per account; the 1001st is refused, and a deletion frees a slot', async () => {
    const { token, gymId } = await withGym()
    const base = await listingRow(gymId)
    const rows = Array.from({ length: 1000 }, () => ({ ...base, id: appUUID() }))
    expect((await push(token, 'gym-listings', rows.slice(0, 500))).status).toBe(200)
    expect((await push(token, 'gym-listings', rows.slice(500))).status).toBe(200)
    expect(await refusal(await push(token, 'gym-listings', [{ ...base, id: appUUID() }]))).toEqual({
      code: 'too_many_listings', message: "You've reached the limit of equipment on one account.",
    })
    expect((await push(token, 'gym-listings', [{ ...rows[0], deleted_at: T2, client_updated_at: T2 }])).status).toBe(200)
    expect((await push(token, 'gym-listings', [{ ...base, id: appUUID() }])).status).toBe(200)
  })

  it('refuse hidden characters in notes, brand and model, and a tab even in notes', async () => {
    const { token, gymId } = await withGym()
    for (const [column, value] of [['private_brand', 'Acme\u202E'], ['private_model', '\u{F0000}'], ['notes', 'a\tb']]) {
      const res = await push(token, 'gym-listings', [await listingRow(gymId, { [column]: value })])
      expect(await refusal(res)).toEqual({
        code: 'row_rejected', message: `rows[0].${column} has hidden or control characters`,
      })
    }
  })
})
