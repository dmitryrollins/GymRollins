import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import {
  agedRows, block, confirm, genericItem, gymsCreatedToday, insertGym, insertListing, listingsSharedToday, setStatus,
  uploadedPhoto,
} from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'

type Json = Record<string, any>

const place = () => `place-${crypto.randomUUID()}`

const findOrCreate = (token: string, body: Json) => request('POST', '/v1/gyms/find-or-create', { token, body })

async function gymFor(token: string, body: Json): Promise<string> {
  const res = await findOrCreate(token, body)
  expect(res.status).toBe(200)
  return (await res.json<{ id: string }>()).id
}

const shareBody = (gymId: string, overrides: Json = {}): Json => ({
  listing_id: crypto.randomUUID().toUpperCase(), gym_id: gymId, kind_id: 'dumbbells', brand: null, model: null,
  loads: { type: 'none' }, quantity: 1, notes: null, photo_path: null, force_new: false, ...overrides,
})

const share = (token: string, body: Json) => request('POST', '/v1/listings/share', { token, body })

async function answer(res: Response, status = 200): Promise<Json> {
  expect(res.status).toBe(status)
  return res.json<Json>()
}

const refusalOf = async (res: Response, status = 422) => (await answer(res, status)).error as { code: string; message: string }

const confirmOf = (token: string, listing: string) => request('POST', `/v1/listings/${listing}/confirm`, { token })

describe('find or create a gym', () => {
  it('creates a public gym on the first share of a place, trims its text, and answers the same gym after', async () => {
    const a = await signUp()
    const b = await signUp()
    const where = place()
    const id = await gymFor(a.token, { maps_place_id: where, name: ' Iron Works ', address: ' 1 Main St ', latitude: 52.1, longitude: 4.3 })
    const again = await gymFor(b.token, { maps_place_id: where, name: 'Other name', address: null, latitude: 0, longitude: 0 })
    expect(again).toBe(id)
    const stored = await env.DB.prepare('SELECT name, address, latitude, created_by, visibility FROM gyms WHERE id = ?1')
      .bind(id).first()
    expect(stored).toEqual({ name: 'Iron Works', address: '1 Main St', latitude: 52.1, created_by: a.userId, visibility: 'public' })
    const seen = await answer(await request('GET', `/v1/gyms/public?place=${where}`, { token: a.token }))
    expect(seen.gym).toMatchObject({ id, is_mine: true })
  })

  it('refuses a place id that could not be one, and a name of hidden characters', async () => {
    const { token } = await signUp()
    for (const maps_place_id of ['', 'a\nb', 'x'.repeat(201), 7]) {
      expect(await refusalOf(await findOrCreate(token, { maps_place_id, name: 'Gym' }), 400))
        .toEqual({ code: 'bad_request', message: 'invalid place' })
    }
    expect((await refusalOf(await findOrCreate(token, { maps_place_id: place(), name: '​' }))).code).toBe('row_rejected')
    expect((await refusalOf(await findOrCreate(token, { maps_place_id: place(), name: '   ' }))).code).toBe('row_rejected')
  })

  it('creates 10 gyms a day; the 11th is refused, a known place still answers, and older ones do not count', async () => {
    const { token, userId } = await signUp()
    await gymsCreatedToday(userId, 9)
    await gymFor(token, { maps_place_id: place(), name: 'Tenth' })
    expect(await refusalOf(await findOrCreate(token, { maps_place_id: place(), name: 'Eleventh' }))).toEqual({
      code: 'daily_limit', message: "You've shared a lot today. Try again tomorrow.",
    })
    const known = await insertGym({ visibility: 'public' })
    expect(await gymFor(token, { maps_place_id: `place-${known}`, name: 'Known' })).toBe(known)
    await agedRows('gyms', 'created_by', userId)
    await gymFor(token, { maps_place_id: place(), name: 'Tomorrow' })
  })

  it('gives a removed gym its place back', async () => {
    const { token } = await signUp()
    const where = place()
    const first = await gymFor(token, { maps_place_id: where, name: 'First' })
    await setStatus('gyms', first, 'removed')
    const second = await gymFor(token, { maps_place_id: where, name: 'Second' })
    expect(second).not.toBe(first)
  })
})

describe('share a listing', () => {
  it('creates a listing, answers a retry with the same id as created, and offers duplicates of the kind', async () => {
    const a = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    const body = shareBody(gym, { notes: 'by the door\nleft side' })
    const id = String(body.listing_id).toLowerCase()
    expect(await answer(await share(a.token, body))).toEqual({ status: 'created', listing_id: id })
    expect(await answer(await share(a.token, body))).toEqual({ status: 'created', listing_id: id })
    const offered = await answer(await share(a.token, shareBody(gym)))
    expect(offered).toEqual({
      status: 'duplicates',
      listings: [{ id, kind_id: 'dumbbells', brand: null, model: null, photo_path: null, loads: { type: 'none' }, quantity: 1, confirm_count: 0 }],
    })
    const forced = shareBody(gym, { brand: 'Hammer Strength', model: 'Pro', loads: { type: 'plates' }, quantity: 2, force_new: true })
    expect((await answer(await share(a.token, forced))).status).toBe('created')
    const count = await env.DB.prepare("SELECT count(*) AS n FROM gym_equipment WHERE gym_id = ?1 AND visibility = 'public'")
      .bind(gym).first<{ n: number }>()
    expect(count!.n).toBe(2)
  })

  it('finds a catalogue item by brand and model in any case, in every script', async () => {
    const a = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    for (const brand of ['Ärger Fitness', ' ärger FITNESS ']) {
      await answer(await share(a.token, shareBody(gym, { brand, model: 'Ü1', force_new: true })))
    }
    const items = await env.DB.prepare("SELECT brand FROM equipment_items WHERE brand_key = 'ärger fitness'").all()
    expect(items.results).toEqual([{ brand: 'Ärger Fitness' }])
  })

  it("leaves blocked authors' listings out of the duplicates", async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    await answer(await share(a.token, shareBody(gym)))
    await block(b.userId, a.userId)
    expect((await answer(await share(b.token, shareBody(gym)))).status).toBe('created')
  })

  it("takes the caller's own stored photo once, and refuses someone else's, a missing or a made-up one", async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    const mine = await uploadedPhoto(a.userId, 'gym-photos')
    expect((await answer(await share(a.token, shareBody(gym, { photo_path: mine })))).status).toBe('created')
    expect(await refusalOf(await share(a.token, shareBody(gym, { photo_path: mine, force_new: true })))).toEqual({
      code: 'photo_in_use', message: 'That photo already belongs to a listing.',
    })
    const theirs = await uploadedPhoto(b.userId, 'gym-photos')
    const unfinished = await uploadedPhoto(a.userId, 'gym-photos', { stored: false })
    const privateOne = await uploadedPhoto(a.userId, 'gym-photos-private')
    for (const photo_path of [theirs, unfinished, privateOne, '../evil.jpg']) {
      expect((await refusalOf(await share(a.token, shareBody(gym, { photo_path, force_new: true })))).code)
        .toBe('photo_missing')
    }
  })

  it('refuses loads the app could not read, an unknown kind, and text the CHECKs refuse', async () => {
    const a = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    const refused = async (overrides: Json, status: number) => refusalOf(await share(a.token, shareBody(gym, { force_new: true, ...overrides })), status)
    expect(await refused({ loads: { type: 'stack', maxKg: -1 } }, 400)).toEqual({ code: 'bad_request', message: 'invalid loads' })
    expect(await refused({ loads: { type: 'plates', html: '<script>' } }, 400)).toMatchObject({ message: 'invalid loads' })
    expect(await refused({ kind_id: 'no-such-kind' }, 400)).toEqual({ code: 'bad_request', message: 'unknown kind' })
    expect(await refused({ brand: 'Acme‮' }, 422)).toEqual({ code: 'row_rejected', message: 'brand has hidden or control characters' })
    expect((await refused({ brand: 'x'.repeat(61) }, 422)).code).toBe('row_rejected')
    expect((await refused({ quantity: 51 }, 422)).code).toBe('row_rejected')
    expect((await refused({ quantity: 1.5 }, 400)).code).toBe('bad_request')
  })

  it("refuses a gym that isn't public and active, and a listing id that isn't the caller's public listing", async () => {
    const a = await signUp()
    const b = await signUp()
    const flagged = await insertGym({ visibility: 'public', createdBy: a.userId, status: 'flagged' })
    const privateGym = await insertGym({ visibility: 'private', owner: a.userId })
    for (const gym of [flagged, privateGym, crypto.randomUUID()]) {
      expect((await refusalOf(await share(a.token, shareBody(gym)))).code).toBe('gym_not_shareable')
    }
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    const mine = shareBody(gym)
    await answer(await share(a.token, mine))
    expect((await refusalOf(await share(b.token, { ...mine }), 403)).code).toBe('not_allowed')
    const privateListing = await insertListing({ gym: privateGym, item: await genericItem(), visibility: 'private', owner: a.userId })
    expect((await refusalOf(await share(a.token, shareBody(gym, { listing_id: privateListing })), 403)).code).toBe('not_allowed')
  })

  it('shares 30 a day; the 31st is refused, and older shares do not count', async () => {
    const a = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    await listingsSharedToday(gym, a.userId, 29)
    expect((await answer(await share(a.token, shareBody(gym, { force_new: true })))).status).toBe('created')
    expect((await refusalOf(await share(a.token, shareBody(gym, { force_new: true })))).code).toBe('daily_limit')
    await agedRows('gym_equipment', 'added_by', a.userId)
    expect((await answer(await share(a.token, shareBody(gym, { force_new: true })))).status).toBe('created')
  })

  it('holds 300 active listings a gym; a retry still succeeds there, and a removed listing frees a place', async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    const mine = shareBody(gym)
    await answer(await share(a.token, mine))
    const others = await listingsSharedToday(gym, (await signUp()).userId, 299)
    expect(await refusalOf(await share(b.token, shareBody(gym, { force_new: true })))).toEqual({
      code: 'gym_full', message: 'This gym has as much shared equipment as it can hold.',
    })
    expect((await answer(await share(a.token, mine))).status).toBe('created')
    await setStatus('gym_equipment', others[0], 'removed')
    expect((await answer(await share(b.token, shareBody(gym, { force_new: true })))).status).toBe('created')
  })

  it('creates exactly 30 when 35 shares arrive together', async () => {
    const a = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    const answers = await Promise.all(Array.from({ length: 35 }, () => share(a.token, shareBody(gym, { force_new: true }))))
    expect(answers.filter((res) => res.status === 200)).toHaveLength(30)
    expect(answers.filter((res) => res.status === 422)).toHaveLength(5)
  })
})

describe('confirm a listing', () => {
  it("counts each account once, and adds nothing for the listing's author", async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await gymFor(a.token, { maps_place_id: place(), name: 'Gym' })
    const { listing_id } = await answer(await share(a.token, shareBody(gym)))
    expect(await answer(await confirmOf(b.token, listing_id))).toEqual({ confirm_count: 1 })
    expect(await answer(await confirmOf(b.token, listing_id))).toEqual({ confirm_count: 1 })
    expect(await answer(await confirmOf(a.token, listing_id))).toEqual({ confirm_count: 1 })
    const seen = await answer(await request('GET', `/v1/gyms/${gym}/listings`, { token: b.token }))
    expect(seen.rows[0]).toMatchObject({ confirm_count: 1, confirmed_by_me: true })
  })

  it("refuses a listing that is flagged, under a removed gym, by a blocked author, or isn't there", async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const item = await genericItem()
    const flagged = await insertListing({ gym, item, visibility: 'public', addedBy: a.userId, status: 'flagged' })
    const removedGym = await insertGym({ visibility: 'public', createdBy: a.userId, status: 'removed' })
    const underRemoved = await insertListing({ gym: removedGym, item, visibility: 'public', addedBy: a.userId })
    const byBlocked = await insertListing({ gym, item, visibility: 'public', addedBy: a.userId })
    await block(b.userId, a.userId)
    for (const listing of [flagged, underRemoved, byBlocked, crypto.randomUUID()]) {
      expect(await refusalOf(await confirmOf(b.token, listing))).toEqual({ code: 'unknown_listing', message: 'unknown listing' })
    }
  })

  it('confirms 100 a day; the 101st is refused, but an earlier confirmation still answers', async () => {
    const author = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: author.userId })
    const listings = await listingsSharedToday(gym, author.userId, 101)
    for (const listing of listings.slice(0, 99)) await confirm(listing, b.userId)
    await env.DB.prepare('UPDATE equipment_confirmations SET created_at = (strftime(\'%Y-%m-%dT%H:%M:%f\', \'now\') || \'000Z\') WHERE user_id = ?1')
      .bind(b.userId).run()
    expect(await answer(await confirmOf(b.token, listings[99]))).toEqual({ confirm_count: 1 })
    expect((await refusalOf(await confirmOf(b.token, listings[100]))).code).toBe('daily_limit')
    expect(await answer(await confirmOf(b.token, listings[0]))).toEqual({ confirm_count: 1 })
  })
})
