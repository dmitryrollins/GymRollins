import { describe, expect, it } from 'vitest'
import { block, confirm, genericItem, insertGym, insertItem, insertListing, makeAdmin, setStatus } from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'

type Json = Record<string, any>

async function get(token: string, path: string): Promise<Json> {
  const res = await request('GET', path, { token })
  expect(res.status).toBe(200)
  return res.json<Json>()
}

const gymAt = async (token: string, gymId: string) =>
  (await get(token, `/v1/gyms/public?place=${encodeURIComponent(`place-${gymId}`)}`)).gym as Json | null
const listingsOf = async (token: string, gymId: string, query = '') =>
  (await get(token, `/v1/gyms/${gymId}/listings${query}`)).rows as Json[]
const itemsOf = async (token: string, kind: string) => (await get(token, `/v1/items?kind=${kind}`)).rows as Json[]
const itemIn = (rows: Json[], id: string) => rows.find((row) => row.id === id)

const AUTHOR_COLUMNS = ['created_by', 'owner_id', 'added_by']

describe('a public gym by its place', () => {
  it('answers the active gym, with is_mine for whoever created it, and no author ids', async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const seen = await gymAt(a.token, gym)
    expect(seen).toMatchObject({
      id: gym, name: 'Test gym', address: null, latitude: null, longitude: null, maps_place_id: `place-${gym}`,
      status: 'active', is_mine: true,
    })
    for (const column of AUTHOR_COLUMNS) expect(seen).not.toHaveProperty(column)
    expect(await gymAt(b.token, gym)).toMatchObject({ id: gym, is_mine: false })
  })

  it('shows a flagged gym only to its creator and admins, and a removed one to nobody', async () => {
    const a = await signUp()
    const b = await signUp()
    const admin = await signUp()
    await makeAdmin(admin.userId)
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId, status: 'flagged' })
    expect(await gymAt(a.token, gym)).toMatchObject({ id: gym, status: 'flagged' })
    expect(await gymAt(b.token, gym)).toBeNull()
    expect(await gymAt(admin.token, gym)).toMatchObject({ id: gym })
    await setStatus('gyms', gym, 'removed')
    expect(await gymAt(a.token, gym)).toBeNull()
    expect(await gymAt(admin.token, gym)).toBeNull()
  })

  it('refuses a place id that could not be one', async () => {
    const { token } = await signUp()
    for (const query of ['', '?place=', '?place=a%0Ab', `?place=${'x'.repeat(201)}`]) {
      const res = await request('GET', `/v1/gyms/public${query}`, { token })
      expect(res.status).toBe(400)
      expect(await res.json()).toEqual({ error: { code: 'bad_request', message: 'invalid place' } })
    }
  })

  it('needs a session', async () => {
    const res = await request('GET', '/v1/gyms/public?place=p1')
    expect(res.status).toBe(401)
  })
})

describe("a gym's listings", () => {
  it("answers the active public listings with what is the caller's, and no author ids", async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const item = await genericItem('dumbbells')
    const photo = `${crypto.randomUUID()}.jpg`
    const listing = await insertListing({ gym, item, visibility: 'public', addedBy: a.userId, photo, notes: 'by the door' })
    await confirm(listing, b.userId)
    const [seen, ...more] = await listingsOf(b.token, gym)
    expect(more).toEqual([])
    expect(seen).toMatchObject({
      id: listing, gym_id: gym, item_id: item, kind_id: 'dumbbells', brand: null, model: null, photo_path: photo,
      loads: { type: 'none' }, quantity: 1, notes: 'by the door', status: 'active', confirm_count: 1, is_mine: false,
      confirmed_by_me: true, item_is_mine: false,
    })
    for (const column of AUTHOR_COLUMNS) expect(seen).not.toHaveProperty(column)
    expect((await listingsOf(a.token, gym))[0]).toMatchObject({ is_mine: true, confirmed_by_me: false })
  })

  it('hides a flagged listing from all but its author and admins, and a removed one from all but admins', async () => {
    const a = await signUp()
    const b = await signUp()
    const admin = await signUp()
    await makeAdmin(admin.userId)
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const listing = await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: a.userId })
    await setStatus('gym_equipment', listing, 'flagged')
    expect(await listingsOf(a.token, gym)).toHaveLength(1)
    expect(await listingsOf(b.token, gym)).toEqual([])
    expect(await listingsOf(admin.token, gym)).toHaveLength(1)
    await setStatus('gym_equipment', listing, 'removed')
    expect(await listingsOf(a.token, gym)).toEqual([])
    expect((await listingsOf(admin.token, gym))[0]).toMatchObject({ id: listing, status: 'removed' })
  })

  it('hides every listing of a removed gym, and of a removed item', async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const item = await insertItem({ brand: 'Acme', model: 'C1', createdBy: a.userId })
    await insertListing({ gym, item, visibility: 'public', addedBy: a.userId })
    expect(await listingsOf(b.token, gym)).toHaveLength(1)
    await setStatus('gyms', gym, 'removed')
    expect(await listingsOf(b.token, gym)).toEqual([])
    await setStatus('gyms', gym, 'active')
    await setStatus('equipment_items', item, 'removed')
    expect(await listingsOf(b.token, gym)).toEqual([])
  })

  it("hides a blocked author's listings, and listings of an item whose creator is blocked, from the blocker only",
    async () => {
      const author = await signUp()
      const creator = await signUp()
      const blocker = await signUp()
      const other = await signUp()
      const gym = await insertGym({ visibility: 'public', createdBy: author.userId })
      await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: author.userId })
      const item = await insertItem({ brand: 'Acme', model: 'C2', createdBy: creator.userId })
      await insertListing({ gym, item, visibility: 'public', addedBy: other.userId })
      expect(await listingsOf(blocker.token, gym)).toHaveLength(2)
      await block(blocker.userId, author.userId)
      expect((await listingsOf(blocker.token, gym)).map((l) => l.item_id)).toEqual([item])
      await block(blocker.userId, creator.userId)
      expect(await listingsOf(blocker.token, gym)).toEqual([])
      expect(await listingsOf(other.token, gym)).toHaveLength(2)
    })

  it('never answers private listings, even to their owner', async () => {
    const a = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    await insertListing({ gym, item: await genericItem(), visibility: 'private', owner: a.userId })
    expect(await listingsOf(a.token, gym)).toEqual([])
  })

  it('pages by offset and limit, oldest first', async () => {
    const a = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const item = await genericItem()
    const ids = []
    for (const createdAt of ['2026-11-07T10:00:01.000000Z', '2026-11-07T10:00:02.000000Z', '2026-11-07T10:00:03.000000Z']) {
      ids.push(await insertListing({ gym, item, visibility: 'public', addedBy: a.userId, createdAt }))
    }
    expect((await listingsOf(a.token, gym, '?limit=2')).map((l) => l.id)).toEqual(ids.slice(0, 2))
    expect((await listingsOf(a.token, gym, '?offset=2&limit=2')).map((l) => l.id)).toEqual(ids.slice(2))
    for (const query of ['?limit=501', '?limit=0', '?offset=-1', '?offset=x']) {
      expect((await request('GET', `/v1/gyms/${gym}/listings${query}`, { token: a.token })).status).toBe(400)
    }
  })
})

describe('the items of a kind', () => {
  it("answer the kind's generic item, and a branded one to others only once it has an active shared listing",
    async () => {
      const a = await signUp()
      const b = await signUp()
      const generic = await genericItem('kettlebells')
      expect(itemIn(await itemsOf(b.token, 'kettlebells'), generic)).toMatchObject({
        kind_id: 'kettlebells', brand: null, model: null, status: 'active', is_mine: false,
      })
      const item = await insertItem({ brand: 'Acme', model: 'K1', createdBy: a.userId, kind: 'kettlebells' })
      expect(itemIn(await itemsOf(b.token, 'kettlebells'), item)).toBeUndefined()
      expect(itemIn(await itemsOf(a.token, 'kettlebells'), item)).toMatchObject({ is_mine: true, gym_count: 0 })
      const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
      await insertListing({ gym, item, visibility: 'public', addedBy: a.userId })
      expect(itemIn(await itemsOf(b.token, 'kettlebells'), item)).toMatchObject({ brand: 'Acme', model: 'K1', gym_count: 1 })
      for (const column of AUTHOR_COLUMNS) expect(itemIn(await itemsOf(b.token, 'kettlebells'), item)).not.toHaveProperty(column)
    })

  it('take the photo from the most confirmed listing, the oldest on a tie, skipping flagged ones and blocked authors',
    async () => {
      const a = await signUp()
      const c = await signUp()
      const viewer = await signUp()
      const item = await insertItem({ brand: 'Acme', model: 'K2', createdBy: a.userId, kind: 'kettlebells' })
      const photos = [`${crypto.randomUUID()}.jpg`, `${crypto.randomUUID()}.jpg`]
      const first = await insertListing({
        gym: await insertGym({ visibility: 'public', createdBy: a.userId }), item, visibility: 'public', addedBy: a.userId,
        photo: photos[0], createdAt: '2026-11-07T10:00:01.000000Z',
      })
      const second = await insertListing({
        gym: await insertGym({ visibility: 'public', createdBy: c.userId }), item, visibility: 'public', addedBy: c.userId,
        photo: photos[1], createdAt: '2026-11-07T10:00:02.000000Z',
      })
      const photoFor = async (token: string) => itemIn(await itemsOf(token, 'kettlebells'), item)
      expect(await photoFor(viewer.token)).toMatchObject({ photo_path: photos[0], photo_listing_id: first })
      await confirm(second, viewer.userId)
      expect(await photoFor(viewer.token)).toMatchObject({ photo_path: photos[1], photo_listing_id: second })
      await block(viewer.userId, c.userId)
      expect(await photoFor(viewer.token)).toMatchObject({ photo_path: photos[0] })
      expect(await photoFor(a.token)).toMatchObject({ photo_path: photos[1] })
      await setStatus('gym_equipment', second, 'flagged')
      expect(await photoFor(a.token)).toMatchObject({ photo_path: photos[0] })
      await setStatus('gym_equipment', first, 'removed')
      expect(await photoFor(a.token)).toMatchObject({ photo_path: null, photo_listing_id: null })
    })

  it("never take a private listing's photo, even for its owner", async () => {
    const a = await signUp()
    const generic = await genericItem('medicine-ball')
    const gym = await insertGym({ visibility: 'private', owner: a.userId })
    await insertListing({ gym, item: generic, visibility: 'private', owner: a.userId, photo: `${crypto.randomUUID()}.jpg` })
    expect(itemIn(await itemsOf(a.token, 'medicine-ball'), generic)).toMatchObject({ photo_path: null, gym_count: 0 })
  })

  it('leave the list once the only gym that lists one is removed, except for its creator', async () => {
    const a = await signUp()
    const b = await signUp()
    const item = await insertItem({ brand: 'Acme', model: 'K4', createdBy: a.userId, kind: 'kettlebells' })
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    await insertListing({ gym, item, visibility: 'public', addedBy: a.userId })
    expect(itemIn(await itemsOf(b.token, 'kettlebells'), item)).toMatchObject({ gym_count: 1 })
    await setStatus('gyms', gym, 'removed')
    expect(itemIn(await itemsOf(b.token, 'kettlebells'), item)).toBeUndefined()
    expect(itemIn(await itemsOf(a.token, 'kettlebells'), item)).toMatchObject({ is_mine: true, gym_count: 0 })
  })

  it('count the distinct gyms that list one', async () => {
    const a = await signUp()
    const item = await insertItem({ brand: 'Acme', model: 'K3', createdBy: a.userId, kind: 'kettlebells' })
    const one = await insertGym({ visibility: 'public', createdBy: a.userId })
    const two = await insertGym({ visibility: 'public', createdBy: a.userId })
    for (const gym of [one, one, two]) await insertListing({ gym, item, visibility: 'public', addedBy: a.userId })
    expect(itemIn(await itemsOf(a.token, 'kettlebells'), item)).toMatchObject({ gym_count: 2 })
  })

  it('refuse a kind that could not be one', async () => {
    const { token } = await signUp()
    const res = await request('GET', '/v1/items?kind=Not%20A%20Kind', { token })
    expect(res.status).toBe(400)
    expect(await res.json()).toEqual({ error: { code: 'bad_request', message: 'invalid kind' } })
  })
})
