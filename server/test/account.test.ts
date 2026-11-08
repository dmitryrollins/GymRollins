import { env } from 'cloudflare:workers'
import { beforeAll, describe, expect, it } from 'vitest'
import {
  block, confirm, genericItem, insertGym, insertItem, insertListing, insertPhoto, insertReport, JPEG, makeAdmin,
} from './gym-fixtures.ts'
import { ApiError } from '../src/http/errors.ts'
import { deleteAccount } from '../src/account/delete.ts'
import { request, signUp, upload } from './helpers.ts'
import { SAMPLES, sampleNeeds, workoutSample } from './samples.ts'

beforeAll(sampleNeeds)

/** Every column that names an account. After the deletion, none may name it. */
const OWNED: readonly [string, string][] = [
  ['"user"', 'id'], ['session', 'userId'], ['account', 'userId'],
  ['profiles', 'user_id'], ['custom_exercises', 'user_id'], ['exercise_prefs', 'user_id'], ['routines', 'user_id'],
  ['week_schedule', 'user_id'], ['muscle_targets', 'user_id'], ['bodyweight', 'user_id'], ['workouts', 'user_id'],
  ['workout_entries', 'user_id'], ['workout_sets', 'user_id'], ['proposals', 'user_id'], ['mcp_audit', 'user_id'],
  ['mcp_calls', 'user_id'], ['photo_objects', 'owner_id'], ['gyms', 'owner_id'], ['gyms', 'created_by'],
  ['gym_equipment', 'owner_id'], ['gym_equipment', 'added_by'], ['equipment_items', 'created_by'],
  ['equipment_confirmations', 'user_id'], ['reports', 'reporter_id'], ['user_blocks', 'blocker_id'],
  ['user_blocks', 'blocked_id'], ['gym_unblocks', 'user_id'], ['app_admins', 'user_id'],
]

async function rowsNaming(table: string, column: string, userId: string): Promise<number> {
  return (await env.DB.prepare(`SELECT count(*) AS n FROM ${table} WHERE ${column} = ?1`).bind(userId)
    .first<{ n: number }>())!.n
}

const row = (sql: string, ...bindings: unknown[]) => env.DB.prepare(sql).bind(...bindings).first<Record<string, unknown>>()

describe('deleting an account', () => {
  it('refuses while any of its gym photos are left, and keeps the account', async () => {
    const { token, userId } = await signUp()
    await insertPhoto(userId)
    const res = await request('DELETE', '/v1/account', { token })
    expect(res.status).toBe(422)
    expect(await res.json()).toEqual({ error: { code: 'photos_remain', message: 'Delete your gym photos first.' } })
    expect((await request('GET', '/v1/sync/profile', { token })).status).toBe(200)
  })

  it("deletes every row of the account and ends its session, and nobody else's", async () => {
    const me = await signUp()
    const other = await signUp()
    for (const [entity, make] of Object.entries(SAMPLES)) {
      const res = await request('POST', `/v1/sync/${entity}`, { token: me.token, body: { rows: [make()] } })
      expect(res.status).toBe(200)
    }
    expect((await request('POST', '/v1/sync/workouts', { token: me.token, body: workoutSample() })).status).toBe(200)
    const gym = await insertGym({ visibility: 'private', owner: me.userId })
    await insertListing({ gym, item: await genericItem(), visibility: 'private', owner: me.userId })
    await makeAdmin(me.userId)
    await block(me.userId, other.userId)
    await block(other.userId, me.userId)
    expect((await request('DELETE', '/v1/account', { token: me.token })).status).toBe(204)
    for (const [table, column] of OWNED) {
      expect(await rowsNaming(table, column, me.userId), `${table}.${column}`).toBe(0)
    }
    expect((await request('GET', '/v1/sync/profile', { token: me.token })).status).toBe(401)
    expect((await request('GET', '/v1/sync/profile', { token: other.token })).status).toBe(200)
  })

  it("keeps shared gyms and listings, without the author or the author's own words", async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const onlyMine = await insertItem({ brand: 'Acme', model: 'X1', createdBy: a.userId })
    const shared = await insertItem({ brand: 'Common', model: 'C1', createdBy: a.userId })
    const photo = `${crypto.randomUUID()}.jpg`
    const myListing = await insertListing({
      gym, item: onlyMine, visibility: 'public', addedBy: a.userId, notes: 'By the window', photo,
    })
    const mySharedListing = await insertListing({ gym, item: shared, visibility: 'public', addedBy: a.userId })
    await insertListing({ gym, item: shared, visibility: 'public', addedBy: b.userId })
    const theirListing = await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: b.userId })
    await confirm(theirListing, a.userId)
    const report = await insertReport({ reporter: a.userId, targetType: 'listing', targetId: theirListing, note: 'Broken' })

    expect((await request('DELETE', '/v1/account', { token: a.token })).status).toBe(204)

    expect(await row('SELECT created_by FROM gyms WHERE id = ?1', gym)).toEqual({ created_by: null })
    expect(await row('SELECT item_id, notes, photo_path, added_by FROM gym_equipment WHERE id = ?1', myListing))
      .toEqual({ item_id: await genericItem(), notes: null, photo_path: null, added_by: null })
    expect(await row('SELECT id FROM equipment_items WHERE id = ?1', onlyMine)).toBeNull()
    expect(await row('SELECT created_by FROM equipment_items WHERE id = ?1', shared)).toEqual({ created_by: null })
    expect(await row('SELECT item_id FROM gym_equipment WHERE id = ?1', mySharedListing)).toEqual({ item_id: shared })
    expect(await row('SELECT confirm_count FROM gym_equipment WHERE id = ?1', theirListing)).toEqual({ confirm_count: 0 })
    expect(await row('SELECT reporter_id, note FROM reports WHERE id = ?1', report))
      .toEqual({ reporter_id: null, note: null })
  })

  it('stops everything when a photo appears after the first check', async () => {
    const a = await signUp()
    const b = await signUp()
    const c = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const mine = await insertItem({ brand: 'Acme', model: 'X1', createdBy: a.userId })
    const myListing = await insertListing({ gym, item: mine, visibility: 'public', addedBy: a.userId, notes: 'By the window' })
    const theirs = await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: b.userId })
    await confirm(theirs, a.userId)
    await confirm(theirs, c.userId)
    await insertPhoto(a.userId)

    // The first check, and only it, misses the photo.
    const blind = new Proxy(env.DB, {
      get: (target, prop) => {
        if (prop !== 'prepare') return (target as never)[prop]
        return (sql: string) => sql.startsWith('SELECT 1 FROM photo_objects')
          ? { bind: () => ({ first: async () => null }) }
          : target.prepare(sql)
      },
    })

    const error = await deleteAccount(blind, a.userId).catch((e: unknown) => e)
    expect(error).toBeInstanceOf(ApiError)
    expect((error as ApiError).code).toBe('photos_remain')
    expect(await row('SELECT id FROM "user" WHERE id = ?1', a.userId)).toEqual({ id: a.userId })
    expect(await row('SELECT notes, item_id FROM gym_equipment WHERE id = ?1', myListing))
      .toEqual({ notes: 'By the window', item_id: mine })
    expect(await row('SELECT id FROM equipment_items WHERE id = ?1', mine)).toEqual({ id: mine })
    expect(await row('SELECT confirm_count FROM gym_equipment WHERE id = ?1', theirs)).toEqual({ confirm_count: 2 })
  })

  it('recounts a listing two people confirmed down to the one who stays', async () => {
    const a = await signUp()
    const b = await signUp()
    const c = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: b.userId })
    const listing = await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: b.userId })
    await confirm(listing, a.userId)
    await confirm(listing, c.userId)
    expect(await row('SELECT confirm_count FROM gym_equipment WHERE id = ?1', listing)).toEqual({ confirm_count: 2 })
    expect((await request('DELETE', '/v1/account', { token: a.token })).status).toBe(204)
    expect(await row('SELECT confirm_count FROM gym_equipment WHERE id = ?1', listing)).toEqual({ confirm_count: 1 })
  })

  it("leaves other people's listings and words alone", async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const item = await insertItem({ brand: 'Bravo', model: 'B1', createdBy: b.userId })
    const photo = `${crypto.randomUUID()}.jpg`
    const listing = await insertListing({
      gym, item, visibility: 'public', addedBy: b.userId, notes: 'Back corner', photo,
    })
    expect((await request('DELETE', '/v1/account', { token: a.token })).status).toBe(204)
    expect(await row('SELECT item_id, notes, photo_path, added_by FROM gym_equipment WHERE id = ?1', listing))
      .toEqual({ item_id: item, notes: 'Back corner', photo_path: photo, added_by: b.userId })
    expect(await row('SELECT created_by FROM equipment_items WHERE id = ?1', item)).toEqual({ created_by: b.userId })
  })

  it('refuses while photos uploaded through the routes are left, then goes once they are deleted', async () => {
    const { token, userId } = await signUp()
    const names = [`${crypto.randomUUID()}.jpg`, `${crypto.randomUUID()}.jpg`]
    expect((await upload(token, `/v1/photos/private/${names[0]}`, JPEG)).status).toBe(200)
    expect((await upload(token, `/v1/photos/shared/${names[1]}`, JPEG)).status).toBe(200)
    const refused = await request('DELETE', '/v1/account', { token })
    expect(refused.status).toBe(422)
    expect(await refused.json()).toMatchObject({ error: { code: 'photos_remain' } })
    const listed = await request('GET', '/v1/photos/mine', { token })
    const { rows } = await listed.json<{ rows: { bucket_id: string; name: string }[] }>()
    expect(rows).toHaveLength(2)
    for (const { bucket_id, name } of rows) {
      const bucket = bucket_id === 'gym-photos' ? 'shared' : 'private'
      expect((await request('DELETE', `/v1/photos/${bucket}/${name}`, { token })).status).toBe(204)
    }
    expect((await request('DELETE', '/v1/account', { token })).status).toBe(204)
    expect(await env.GYM_PHOTOS_PRIVATE.head(names[0])).toBeNull()
    expect(await env.GYM_PHOTOS.head(names[1])).toBeNull()
    for (const [table, column] of OWNED) expect(await rowsNaming(table, column, userId), `${table}.${column}`).toBe(0)
  })
})
