import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { countOf, seedRows } from './cap-fixtures.ts'
import { genericItem, insertGym, insertListing, insertUser, listingsSharedToday } from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'
import { appUUID, SAMPLES, T1 } from './samples.ts'

// Requests that arrive together: each limit holds at its exact number, because every count sits in the statement that
// writes and D1 runs writes one at a time (spec section 2, "Locks and limits"). share.test.ts and photos.test.ts do
// the same for shares (35 → 30) and photo uploads (70 → 60).

const together = (count: number, call: (i: number) => Promise<Response>) =>
  Promise.all(Array.from({ length: count }, (_, i) => call(i)))
const tally = (answers: Response[]) =>
  answers.reduce<Record<number, number>>((counts, res) => ({ ...counts, [res.status]: (counts[res.status] ?? 0) + 1 }), {})

describe('limits, with requests that arrive together', () => {
  it('create exactly 10 new gyms out of 15', async () => {
    const { token } = await signUp()
    const answers = await together(15, () => request('POST', '/v1/gyms/find-or-create', {
      token, body: { maps_place_id: `place-${crypto.randomUUID()}`, name: 'Gym' },
    }))
    expect(tally(answers)).toEqual({ 200: 10, 422: 5 })
  })

  it('file exactly 20 reports out of 25', async () => {
    const { token } = await signUp()
    const author = await insertUser()
    const listings = await listingsSharedToday(await insertGym({ visibility: 'public', createdBy: author }), author, 25)
    const answers = await together(25, (i) => request('POST', '/v1/reports', {
      token, body: { target_type: 'listing', target_id: listings[i], reason: 'spam', note: null },
    }))
    expect(tally(answers)).toEqual({ 200: 20, 422: 5 })
  })

  it('make exactly 20 new blocks out of 25', async () => {
    const { token } = await signUp()
    const authors = await Promise.all(Array.from({ length: 25 }, () => insertUser()))
    const gym = await insertGym({ visibility: 'public', createdBy: authors[0] })
    const item = await genericItem()
    const listings = await Promise.all(authors.map((author) => insertListing({ gym, item, visibility: 'public', addedBy: author })))
    const answers = await together(25, (i) => request('POST', '/v1/blocks', {
      token, body: { target_type: 'listing', target_id: listings[i] },
    }))
    expect(tally(answers)).toEqual({ 204: 20, 422: 5 })
  })

  it('confirm exactly 100 listings out of 105', async () => {
    const { token } = await signUp()
    const author = await insertUser()
    const listings = await listingsSharedToday(await insertGym({ visibility: 'public', createdBy: author }), author, 105)
    const answers = await together(105, (i) => request('POST', `/v1/listings/${listings[i]}/confirm`, { token }))
    expect(tally(answers)).toEqual({ 200: 100, 422: 5 })
  })

  it('keep 100 live private gyms', async () => {
    const { token, userId } = await signUp()
    const gym = () => ({
      id: appUUID(), visibility: 'private', name: 'Home', address: null, latitude: null, longitude: null,
      client_updated_at: T1, deleted_at: null,
    })
    expect((await request('POST', '/v1/sync/gyms', { token, body: { rows: Array.from({ length: 96 }, gym) } })).status)
      .toBe(200)
    const answers = await together(6, () => request('POST', '/v1/sync/gyms', { token, body: { rows: [gym()] } }))
    expect(tally(answers)).toEqual({ 200: 4, 422: 2 })
    const live = await env.DB.prepare('SELECT count(*) AS n FROM gyms WHERE owner_id = ?1 AND deleted_at IS NULL')
      .bind(userId).first<{ n: number }>()
    expect(live!.n).toBe(100)
  })

  it('keep 200 routines, deleted ones included', async () => {
    const { token, userId } = await signUp()
    await seedRows('routines', userId, 196)
    const answers = await together(6, () => request('POST', '/v1/sync/routines', {
      token, body: { rows: [SAMPLES.routines()] },
    }))
    expect(tally(answers)).toEqual({ 200: 4, 422: 2 })
    expect(await countOf('routines', userId)).toBe(200)
  })
})
