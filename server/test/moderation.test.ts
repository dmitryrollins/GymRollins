import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import {
  agedRows, blocksToday, DAYS_AGO, genericItem, insertGym, insertListing, reportsToday, setStatus, unblocksToday,
} from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'

type Json = Record<string, any>
type Target = { target_type: string; target_id: string }

const report = (token: string, target: Target, reason = 'spam', note: unknown = null) =>
  request('POST', '/v1/reports', { token, body: { ...target, reason, note } })
const blockOf = (token: string, target: Target) => request('POST', '/v1/blocks', { token, body: target })
const unblockAll = (token: string) => request('DELETE', '/v1/blocks', { token })

async function answer(res: Response, status = 200): Promise<Json> {
  expect(res.status).toBe(status)
  return res.json<Json>()
}

const refusalOf = async (res: Response, status = 422) =>
  (await answer(res, status)).error as { code: string; message: string }

/** A public gym with one active listing by `author`. */
async function shared(author: string) {
  const gym = await insertGym({ visibility: 'public', createdBy: author })
  const listing = await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: author })
  return { gym, listing, target: { target_type: 'listing', target_id: listing } }
}

const statusOf = async (table: 'gyms' | 'gym_equipment', id: string) =>
  (await env.DB.prepare(`SELECT status FROM ${table} WHERE id = ?1`).bind(id).first<{ status: string }>())!.status
const count = async (sql: string, ...bindings: unknown[]) =>
  (await env.DB.prepare(sql).bind(...bindings).first<{ n: number }>())!.n
const listingsSeenBy = async (token: string, gym: string) =>
  (await answer(await request('GET', `/v1/gyms/${gym}/listings`, { token }))).rows as Json[]

describe('reports', () => {
  it('store a report with its note trimmed, and answer already to the same account again, whatever it sends',
    async () => {
      const author = await signUp()
      const b = await signUp()
      const { listing, target } = await shared(author.userId)
      expect(await answer(await report(b.token, target, 'person-in-photo', '  a face  '))).toEqual({ status: 'reported' })
      const stored = await env.DB.prepare('SELECT reason, note, reporter_id FROM reports WHERE target_id = ?1')
        .bind(listing).first()
      expect(stored).toEqual({ reason: 'person-in-photo', note: 'a face', reporter_id: b.userId })
      expect(await answer(await report(b.token, target))).toEqual({ status: 'already' })
      expect(await answer(await report(b.token, target, 'not-a-reason'))).toEqual({ status: 'already' })
    })

  it('answer own to an author reporting their own content, and store nothing', async () => {
    const author = await signUp()
    const { listing, target } = await shared(author.userId)
    expect(await answer(await report(author.token, target))).toEqual({ status: 'own' })
    expect(await count('SELECT count(*) AS n FROM reports WHERE target_id = ?1', listing)).toBe(0)
  })

  it('refuse a target that is not a public gym or listing, or was removed', async () => {
    const author = await signUp()
    const b = await signUp()
    const { listing } = await shared(author.userId)
    const privateGym = await insertGym({ visibility: 'private', owner: author.userId })
    const removed = await shared(author.userId)
    await setStatus('gym_equipment', removed.listing, 'removed')
    const targets = [
      { target_type: 'item', target_id: await genericItem() }, { target_type: 'nonsense', target_id: listing },
      { target_type: 'listing', target_id: crypto.randomUUID() }, { target_type: 'gym', target_id: privateGym },
      removed.target,
    ]
    for (const target of targets) {
      expect(await refusalOf(await report(b.token, target))).toEqual({ code: 'unknown_target', message: 'unknown target' })
    }
    expect((await refusalOf(await report(b.token, { target_type: 'listing', target_id: 'nope' }), 400)).code)
      .toBe('bad_request')
  })

  it('refuse a reason that is not on the list, and a note that is too long or has hidden characters', async () => {
    const author = await signUp()
    const b = await signUp()
    const refused: [string, string | null][] = [['not-a-reason', null], ['other', 'x'.repeat(281)], ['other', 'look\u{E0041}']]
    for (const [reason, note] of refused) {
      const { target } = await shared(author.userId)
      expect((await refusalOf(await report(b.token, target, reason, note))).code).toBe('row_rejected')
    }
    const { target } = await shared(author.userId)
    expect(await answer(await report(b.token, target, 'other', 'two\nlines'))).toEqual({ status: 'reported' })
  })

  it('flag a target at three reports from three accounts, hiding it from everyone but its author', async () => {
    const author = await signUp()
    const viewer = await signUp()
    const { gym, listing, target } = await shared(author.userId)
    for (let i = 0; i < 2; i++) await answer(await report((await signUp()).token, target))
    expect(await statusOf('gym_equipment', listing)).toBe('active')
    expect(await listingsSeenBy(viewer.token, gym)).toHaveLength(1)
    await answer(await report((await signUp()).token, target))
    expect(await statusOf('gym_equipment', listing)).toBe('flagged')
    expect(await listingsSeenBy(viewer.token, gym)).toEqual([])
    expect((await listingsSeenBy(author.token, gym))[0]).toMatchObject({ id: listing, status: 'flagged' })
  })

  it("don't flag a target whose reporters closed their accounts in between", async () => {
    const author = await signUp()
    const { listing, target } = await shared(author.userId)
    for (let i = 0; i < 3; i++) {
      const reporter = await signUp()
      await answer(await report(reporter.token, target))
      expect((await request('DELETE', '/v1/account', { token: reporter.token })).status).toBe(204)
    }
    expect(await statusOf('gym_equipment', listing)).toBe('active')
    expect(await count('SELECT count(*) AS n FROM reports WHERE target_id = ?1 AND reporter_id IS NULL', listing)).toBe(3)
  })

  it('take 20 a day; the 21st is refused, and older reports do not count', async () => {
    const author = await signUp()
    const b = await signUp()
    await reportsToday(b.userId, 19)
    await answer(await report(b.token, (await shared(author.userId)).target))
    expect(await refusalOf(await report(b.token, (await shared(author.userId)).target))).toEqual({
      code: 'daily_limit', message: "You've shared a lot today. Try again tomorrow.",
    })
    await agedRows('reports', 'reporter_id', b.userId)
    await answer(await report(b.token, (await shared(author.userId)).target))
  })
})

describe('blocks', () => {
  it('hide everything by a blocked author, and unblocking all brings it back', async () => {
    const author = await signUp()
    const b = await signUp()
    const first = await shared(author.userId)
    const second = await shared(author.userId)
    expect((await blockOf(b.token, first.target)).status).toBe(204)
    expect(await listingsSeenBy(b.token, second.gym)).toEqual([])
    expect(await answer(await unblockAll(b.token))).toEqual({ cleared: 1 })
    expect(await listingsSeenBy(b.token, second.gym)).toHaveLength(1)
  })

  it('do nothing for your own content, a gym with no author, or an author already blocked', async () => {
    const author = await signUp()
    const { target } = await shared(author.userId)
    expect((await blockOf(author.token, target)).status).toBe(204)
    expect(await count('SELECT count(*) AS n FROM user_blocks WHERE blocker_id = ?1', author.userId)).toBe(0)
    const b = await signUp()
    const orphan = await insertGym({ visibility: 'public' })
    expect((await blockOf(b.token, { target_type: 'gym', target_id: orphan })).status).toBe(204)
    expect((await blockOf(b.token, target)).status).toBe(204)
    expect((await blockOf(b.token, target)).status).toBe(204)
    expect(await count('SELECT count(*) AS n FROM user_blocks WHERE blocker_id = ?1', b.userId)).toBe(1)
    const unknown = await blockOf(b.token, { target_type: 'listing', target_id: crypto.randomUUID() })
    expect((await refusalOf(unknown)).code).toBe('unknown_target')
  })

  it('take 20 new blocks a day; the 21st is refused, a repeat still succeeds, and an older block frees a slot',
    async () => {
      const b = await signUp()
      const earlier = await blocksToday(b.userId, 19)
      const twentieth = await shared((await signUp()).userId)
      expect((await blockOf(b.token, twentieth.target)).status).toBe(204)
      const next = await shared((await signUp()).userId)
      expect((await refusalOf(await blockOf(b.token, next.target))).code).toBe('daily_limit')
      expect((await blockOf(b.token, twentieth.target)).status).toBe(204)
      expect(await count('SELECT count(*) AS n FROM user_blocks WHERE blocker_id = ?1', b.userId)).toBe(20)
      await env.DB.prepare('UPDATE user_blocks SET created_at = ?3 WHERE blocker_id = ?1 AND blocked_id = ?2')
        .bind(b.userId, earlier[0], DAYS_AGO).run()
      expect((await blockOf(b.token, next.target)).status).toBe(204)
    })
})

describe('unblocking all', () => {
  it('clears 3 times a day; the 4th is refused even with nothing to clear, and the blocks stay', async () => {
    const b = await signUp()
    for (let i = 0; i < 3; i++) {
      await blocksToday(b.userId, 1)
      expect(await answer(await unblockAll(b.token))).toEqual({ cleared: 1 })
    }
    await blocksToday(b.userId, 1)
    expect((await refusalOf(await unblockAll(b.token))).code).toBe('daily_limit')
    expect(await count('SELECT count(*) AS n FROM user_blocks WHERE blocker_id = ?1', b.userId)).toBe(1)
    await env.DB.prepare('DELETE FROM user_blocks WHERE blocker_id = ?1').bind(b.userId).run()
    expect((await refusalOf(await unblockAll(b.token))).code).toBe('daily_limit')
  })

  it("logs only clears that cleared something, and counts only the last day's", async () => {
    const b = await signUp()
    expect(await answer(await unblockAll(b.token))).toEqual({ cleared: 0 })
    expect(await count('SELECT count(*) AS n FROM gym_unblocks WHERE user_id = ?1', b.userId)).toBe(0)
    await unblocksToday(b.userId, 3)
    await blocksToday(b.userId, 2)
    expect((await refusalOf(await unblockAll(b.token))).code).toBe('daily_limit')
    await agedRows('gym_unblocks', 'user_id', b.userId)
    expect(await answer(await unblockAll(b.token))).toEqual({ cleared: 2 })
  })
})
