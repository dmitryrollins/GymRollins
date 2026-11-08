import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { insertGym, makeAdmin, setStatus, uploadedPhoto } from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'

type Json = Record<string, any>
type Account = { token: string; userId: string }

async function answer(res: Response, status = 200): Promise<Json> {
  expect(res.status).toBe(status)
  return res.json<Json>()
}

const refusalOf = async (res: Response, status = 422) =>
  (await answer(res, status)).error as { code: string; message: string }

async function admin(): Promise<Account> {
  const account = await signUp()
  await makeAdmin(account.userId)
  return account
}

const queueFor = async (token: string, ids: string[]) =>
  ((await answer(await request('GET', '/v1/admin/queue', { token }))).rows as Json[]).filter((r) => ids.includes(r.target_id))
const moderate = (token: string, target_type: string, target_id: string, action: string) =>
  request('POST', '/v1/admin/moderate', { token, body: { target_type, target_id, action } })
const report = (token: string, target_type: string, target_id: string, reason = 'spam', note: string | null = null) =>
  request('POST', '/v1/reports', { token, body: { target_type, target_id, reason, note } })
const photoDeleted = (token: string, path: string) => request('POST', '/v1/admin/photo-deleted', { token, body: { path } })
const photoOf = async (listing: string) =>
  env.DB.prepare('SELECT photo_path FROM gym_equipment WHERE id = ?1').bind(listing).first()

/** "Review Gym, 1 Main St", made through the app's routes, with one shared listing. */
async function reviewGym(author: Account, listing: Json = {}) {
  const place = `place-${crypto.randomUUID()}`
  const created = await request('POST', '/v1/gyms/find-or-create', {
    token: author.token, body: { maps_place_id: place, name: 'Review Gym', address: '1 Main St' },
  })
  const gym = (await answer(created)).id as string
  const body = {
    listing_id: crypto.randomUUID(), gym_id: gym, kind_id: 'dumbbells', loads: { type: 'none' }, force_new: true,
    ...listing,
  }
  const shared = await answer(await request('POST', '/v1/listings/share', { token: author.token, body }))
  return { gym, place, listing: shared.listing_id as string }
}

describe('admins', () => {
  it('are told so, and nobody else is', async () => {
    const a = await signUp()
    expect(await answer(await request('GET', '/v1/admin/me', { token: a.token }))).toEqual({ admin: false })
    await makeAdmin(a.userId)
    expect(await answer(await request('GET', '/v1/admin/me', { token: a.token }))).toEqual({ admin: true })
  })

  it('alone read the queue, moderate and confirm a deleted photo', async () => {
    const a = await signUp()
    const { listing } = await reviewGym(a)
    const answers = [
      await request('GET', '/v1/admin/queue', { token: a.token }),
      await moderate(a.token, 'listing', listing, 'remove'),
      await moderate(a.token, 'item', listing, 'nuke'),
      await photoDeleted(a.token, `${crypto.randomUUID()}.jpg`),
    ]
    for (const res of answers) expect(await refusalOf(res, 403)).toEqual({ code: 'not_allowed', message: 'Not allowed.' })
  })
})

describe('the moderation queue', () => {
  it('lists open reports flagged first, then the most reported, a single report included', async () => {
    const author = await signUp()
    const boss = await admin()
    const { gym, listing: listed } = await reviewGym(author, { notes: 'text me 555' })
    const { listing: branded } = await reviewGym(author, { brand: 'Acme', model: 'X1' })
    for (let i = 0; i < 3; i++) await answer(await report((await signUp()).token, 'listing', listed))
    for (let i = 0; i < 2; i++) await answer(await report((await signUp()).token, 'gym', gym, 'wrong-info'))
    await answer(await report((await signUp()).token, 'listing', branded, 'person-in-photo', 'a face'))
    expect(await queueFor(boss.token, [gym, listed, branded])).toEqual([
      {
        target_type: 'listing', target_id: listed, title: 'Dumbbells', photo_path: null, report_count: 3,
        reasons: { spam: 3 }, notes: [], status: 'flagged', address: 'Review Gym, 1 Main St', listing_notes: 'text me 555',
      },
      {
        target_type: 'gym', target_id: gym, title: 'Review Gym', photo_path: null, report_count: 2,
        reasons: { 'wrong-info': 2 }, notes: [], status: 'active', address: '1 Main St', listing_notes: null,
      },
      {
        target_type: 'listing', target_id: branded, title: 'Acme X1', photo_path: null, report_count: 1,
        reasons: { 'person-in-photo': 1 }, notes: ['a face'], status: 'active', address: 'Review Gym, 1 Main St',
        listing_notes: null,
      },
    ])
  })

  it('counts each reason, keeps the notes in the order they were filed, and never says who reported', async () => {
    const author = await signUp()
    const boss = await admin()
    const { listing } = await reviewGym(author)
    await answer(await report((await signUp()).token, 'listing', listing, 'person-in-photo', 'a face'))
    await answer(await report((await signUp()).token, 'listing', listing, 'spam'))
    await answer(await report((await signUp()).token, 'listing', listing, 'other', 'wrong gym'))
    const [row] = await queueFor(boss.token, [listing])
    expect(row).toMatchObject({
      report_count: 3, reasons: { 'person-in-photo': 1, spam: 1, other: 1 }, notes: ['a face', 'wrong gym'],
      status: 'flagged',
    })
    for (const column of ['reporter_id', 'reporters', 'created_by', 'added_by']) expect(row).not.toHaveProperty(column)
  })

  it('keeps a flagged gym with no open reports, with nothing counted', async () => {
    const boss = await admin()
    const gym = await insertGym({ visibility: 'public', status: 'flagged' })
    expect(await queueFor(boss.token, [gym])).toMatchObject([
      { target_type: 'gym', report_count: 0, reasons: {}, notes: [], status: 'flagged' },
    ])
  })

  it("counts the reports of accounts that closed since, which can't flag", async () => {
    const author = await signUp()
    const boss = await admin()
    const { listing } = await reviewGym(author)
    for (let i = 0; i < 3; i++) {
      const reporter = await signUp()
      await answer(await report(reporter.token, 'listing', listing))
      expect((await request('DELETE', '/v1/account', { token: reporter.token })).status).toBe(204)
    }
    expect(await queueFor(boss.token, [listing])).toMatchObject([{ report_count: 3, status: 'active' }])
  })
})

describe('moderating', () => {
  it('restores a target and resolves its reports: it leaves the queue, and a reporter hears already', async () => {
    const author = await signUp()
    const viewer = await signUp()
    const boss = await admin()
    const { gym, listing } = await reviewGym(author)
    const reporters = [await signUp(), await signUp(), await signUp()]
    for (const reporter of reporters) await answer(await report(reporter.token, 'listing', listing))
    expect(await answer(await moderate(boss.token, 'listing', listing, 'restore'))).toEqual({ status: 'active', photo_path: null })
    expect(await queueFor(boss.token, [listing])).toEqual([])
    expect((await answer(await request('GET', `/v1/gyms/${gym}/listings`, { token: viewer.token }))).rows).toHaveLength(1)
    expect(await answer(await report(reporters[0].token, 'listing', listing))).toEqual({ status: 'already' })
  })

  it('removes a listing and answers its photo; the name stays until the photo is deleted, and a retry answers it',
    async () => {
      const author = await signUp()
      const boss = await admin()
      const photo = await uploadedPhoto(author.userId, 'gym-photos')
      const { gym, listing } = await reviewGym(author, { photo_path: photo })
      const removed = { status: 'removed', photo_path: photo }
      expect(await answer(await moderate(boss.token, 'listing', listing, 'remove'))).toEqual(removed)
      expect(await answer(await moderate(boss.token, 'listing', listing, 'remove'))).toEqual(removed)
      expect(await queueFor(boss.token, [listing])).toMatchObject([{ status: 'removed', photo_path: photo }])
      const reuse = {
        listing_id: crypto.randomUUID(), gym_id: gym, kind_id: 'dumbbells', loads: { type: 'none' }, photo_path: photo,
        force_new: true,
      }
      const again = await request('POST', '/v1/listings/share', { token: author.token, body: reuse })
      expect((await refusalOf(again)).code).toBe('photo_in_use')
      expect((await photoDeleted(boss.token, photo)).status).toBe(204)
      expect(await photoOf(listing)).toEqual({ photo_path: null })
      expect(await queueFor(boss.token, [listing])).toEqual([])
      expect(await answer(await moderate(boss.token, 'listing', listing, 'restore'))).toEqual({ status: 'active', photo_path: null })
    })

  it('photo-deleted leaves a name that is unknown, or on a listing that was not removed', async () => {
    const author = await signUp()
    const boss = await admin()
    const photo = await uploadedPhoto(author.userId, 'gym-photos')
    const { listing } = await reviewGym(author, { photo_path: photo })
    for (const path of [`${crypto.randomUUID()}.jpg`, photo]) expect((await photoDeleted(boss.token, path)).status).toBe(204)
    expect(await photoOf(listing)).toEqual({ photo_path: photo })
  })

  it('refuses an unknown action, and restoring a gym whose place another gym has taken', async () => {
    const author = await signUp()
    const boss = await admin()
    const { gym, place } = await reviewGym(author)
    expect(await refusalOf(await moderate(boss.token, 'gym', gym, 'nuke'), 400))
      .toEqual({ code: 'bad_request', message: 'invalid action' })
    expect(await answer(await moderate(boss.token, 'gym', gym, 'remove'))).toEqual({ status: 'removed', photo_path: null })
    const created = await request('POST', '/v1/gyms/find-or-create', {
      token: author.token, body: { maps_place_id: place, name: 'New Gym' },
    })
    const newer = (await answer(created)).id as string
    expect(newer).not.toBe(gym)
    expect(await refusalOf(await moderate(boss.token, 'gym', gym, 'restore'))).toEqual({
      code: 'place_taken', message: 'Another gym now has this place.',
    })
    await setStatus('gyms', newer, 'removed')
    expect(await answer(await moderate(boss.token, 'gym', gym, 'restore'))).toEqual({ status: 'active', photo_path: null })
  })
})
