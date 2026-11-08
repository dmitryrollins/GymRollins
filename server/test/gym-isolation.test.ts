import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { blocksToday, genericItem, insertGym, insertListing, JPEG, makeAdmin, unblocksToday } from './gym-fixtures.ts'
import { request, signUp, upload } from './helpers.ts'
import { appUUID, T1, T2 } from './samples.ts'

// Spec section 8: for every table, account B can't read, change or delete account A's rows. Plan 26 covered its
// tables; sync-gyms.test.ts and sync-rows.test.ts cover pulls and pushes of private gyms and listings. This covers
// the rest of the gym tables.

type Json = Record<string, any>
const json = async (res: Response) => res.json<Json>()
const privateGym = () => ({
  id: appUUID(), visibility: 'private', name: 'Home', address: null, latitude: null, longitude: null,
  client_updated_at: T1, deleted_at: null,
})

describe("one account's gym data, as another account meets it", () => {
  it("private gyms: another account can't tombstone or pull them", async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = privateGym()
    expect((await request('POST', '/v1/sync/gyms', { token: a.token, body: { rows: [gym] } })).status).toBe(200)
    const tombstone = { ...gym, deleted_at: T2, client_updated_at: T2 }
    expect((await request('POST', '/v1/sync/gyms', { token: b.token, body: { rows: [tombstone] } })).status).toBe(403)
    expect((await json(await request('GET', '/v1/sync/gyms', { token: b.token }))).rows).toEqual([])
    expect((await json(await request('GET', '/v1/sync/gyms', { token: a.token }))).rows[0]).toMatchObject({ deleted_at: null })
  })

  it("photos: another account can't read, list, replace or delete them", async () => {
    const a = await signUp()
    const b = await signUp()
    const privateName = `${crypto.randomUUID()}.jpg`
    const sharedName = `${crypto.randomUUID()}.jpg`
    expect((await upload(a.token, `/v1/photos/private/${privateName}`, JPEG)).status).toBe(200)
    expect((await upload(a.token, `/v1/photos/shared/${sharedName}`, JPEG)).status).toBe(200)
    expect((await request('GET', `/v1/photos/private/${privateName}`, { token: b.token })).status).toBe(404)
    expect((await json(await request('GET', '/v1/photos/mine', { token: b.token }))).rows).toEqual([])
    const other = new Uint8Array([0xff, 0xd8, 0xff, 0x01])
    expect((await upload(b.token, `/v1/photos/private/${privateName}`, other)).status).toBe(409)
    expect((await upload(b.token, `/v1/photos/shared/${sharedName}`, other)).status).toBe(409)
    for (const path of [`/v1/photos/private/${privateName}`, `/v1/photos/shared/${sharedName}`]) {
      expect((await request('DELETE', path, { token: b.token })).status).toBe(403)
    }
    const kept = await env.GYM_PHOTOS_PRIVATE.get(privateName)
    expect(new Uint8Array(await kept!.arrayBuffer())).toEqual(JPEG)
    expect(await env.GYM_PHOTOS.head(sharedName)).not.toBeNull()
  })

  it("confirmations: one account's don't count as another's", async () => {
    const author = await signUp()
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: author.userId })
    const listing = await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: author.userId })
    expect(await json(await request('POST', `/v1/listings/${listing}/confirm`, { token: a.token }))).toEqual({ confirm_count: 1 })
    const seen = (await json(await request('GET', `/v1/gyms/${gym}/listings`, { token: b.token }))).rows[0]
    expect(seen).toMatchObject({ confirm_count: 1, confirmed_by_me: false })
  })

  it("blocks and unblocks: one account's change only what it sees and what it may still do", async () => {
    const author = await signUp()
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: author.userId })
    const listing = await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: author.userId })
    const blocked = await request('POST', '/v1/blocks', { token: a.token, body: { target_type: 'listing', target_id: listing } })
    expect(blocked.status).toBe(204)
    expect((await json(await request('GET', `/v1/gyms/${gym}/listings`, { token: b.token }))).rows).toHaveLength(1)
    expect(await json(await request('DELETE', '/v1/blocks', { token: b.token }))).toEqual({ cleared: 0 })
    expect((await json(await request('GET', `/v1/gyms/${gym}/listings`, { token: a.token }))).rows).toEqual([])
    await unblocksToday(a.userId, 3)
    await blocksToday(b.userId, 1)
    expect(await json(await request('DELETE', '/v1/blocks', { token: b.token }))).toEqual({ cleared: 1 })
  })

  it('reports: nobody reads them back, and the queue never names a reporter', async () => {
    const author = await signUp()
    const a = await signUp()
    const boss = await signUp()
    await makeAdmin(boss.userId)
    const gym = await insertGym({ visibility: 'public', createdBy: author.userId })
    const body = { target_type: 'gym', target_id: gym, reason: 'spam', note: null }
    expect((await request('POST', '/v1/reports', { token: a.token, body })).status).toBe(200)
    expect((await request('GET', '/v1/reports', { token: a.token })).status).toBe(404)
    const row = (await json(await request('GET', '/v1/admin/queue', { token: boss.token }))).rows
      .find((r: Json) => r.target_id === gym)
    expect(row).toBeDefined()
    expect(JSON.stringify(row)).not.toContain(a.userId)
  })

  it('the catalogue: written only by sharing, never by a push of public rows', async () => {
    const a = await signUp()
    const gym = privateGym()
    expect((await request('POST', '/v1/sync/gyms', { token: a.token, body: { rows: [gym] } })).status).toBe(200)
    const listing = {
      id: appUUID(), gym_id: gym.id, item_id: await genericItem(), visibility: 'public', photo_path: null,
      loads: { type: 'none' }, quantity: 1, notes: null, private_brand: null, private_model: null, client_updated_at: T1,
      deleted_at: null,
    }
    const res = await request('POST', '/v1/sync/gym-listings', { token: a.token, body: { rows: [listing] } })
    expect(res.status).toBe(422)
    expect((await json(res)).error.code).toBe('row_rejected')
    const writes: [string, string][] = [['POST', '/v1/items'], ['POST', '/v1/gyms/public'], ['PUT', `/v1/gyms/${gym.id}/listings`]]
    for (const [method, path] of writes) {
      expect((await request(method, path, { token: a.token, body: {} })).status, `${method} ${path}`).toBe(404)
    }
  })

  it("admins: one account's role gives another nothing", async () => {
    const boss = await signUp()
    const b = await signUp()
    await makeAdmin(boss.userId)
    expect(await json(await request('GET', '/v1/admin/me', { token: b.token }))).toEqual({ admin: false })
    expect((await request('GET', '/v1/admin/queue', { token: b.token })).status).toBe(403)
  })
})
