import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { PRIVATE_BUCKET } from '../src/photos/objects.ts'
import { uploadPhoto } from '../src/photos/store.ts'
import {
  agedRows, genericItem, insertGym, insertListing, JPEG, makeAdmin, photosToday, setStatus, uploadedPhoto,
} from './gym-fixtures.ts'
import { request, signUp, upload } from './helpers.ts'

type Json = Record<string, any>

const photo = () => `${crypto.randomUUID()}.jpg`
const privatePath = (name: string) => `/v1/photos/private/${name}`
const sharedPath = (name: string) => `/v1/photos/shared/${name}`

async function refusalOf(res: Response, status = 422) {
  expect(res.status).toBe(status)
  return (await res.json<{ error: { code: string; message: string } }>()).error
}

const rowsOf = async (name: string) =>
  (await env.DB.prepare('SELECT count(*) AS n FROM photo_objects WHERE name = ?1').bind(name).first<{ n: number }>())!.n
const mine = async (token: string) => (await (await request('GET', '/v1/photos/mine', { token })).json<Json>()).rows as Json[]

describe('private photos', () => {
  it('are stored for their owner, who alone can read, list and delete them', async () => {
    const a = await signUp()
    const b = await signUp()
    const name = photo()
    const stored = await upload(a.token, privatePath(name), JPEG)
    expect(stored.status).toBe(200)
    expect(await stored.json()).toEqual({ name })
    const read = await request('GET', privatePath(name), { token: a.token })
    expect(read.status).toBe(200)
    expect(read.headers.get('content-type')).toBe('image/jpeg')
    expect(read.headers.get('cache-control')).toBe('private, no-store')
    expect(read.headers.get('content-security-policy')).toBe("default-src 'none'; sandbox")
    expect(new Uint8Array(await read.arrayBuffer())).toEqual(JPEG)
    expect((await request('GET', privatePath(name), { token: b.token })).status).toBe(404)
    expect(await mine(a.token)).toEqual([{ bucket_id: PRIVATE_BUCKET, name }])
    expect(await mine(b.token)).toEqual([])
    expect(await refusalOf(await request('DELETE', privatePath(name), { token: b.token }), 403)).toEqual({
      code: 'not_allowed', message: 'Not allowed.',
    })
    expect(await env.GYM_PHOTOS_PRIVATE.head(name)).not.toBeNull()
    expect((await request('DELETE', privatePath(name), { token: a.token })).status).toBe(204)
    expect(await env.GYM_PHOTOS_PRIVATE.head(name)).toBeNull()
    expect(await rowsOf(name)).toBe(0)
    expect((await request('GET', privatePath(name), { token: a.token })).status).toBe(404)
    expect((await request('DELETE', privatePath(name), { token: a.token })).status).toBe(204)
  })
})

describe('an upload', () => {
  it('answers 409 for a name already uploaded, by the caller or by anyone', async () => {
    const a = await signUp()
    const b = await signUp()
    const name = photo()
    expect((await upload(a.token, privatePath(name), JPEG)).status).toBe(200)
    expect(await refusalOf(await upload(a.token, privatePath(name), JPEG), 409)).toEqual({
      code: 'duplicate', message: 'A photo with that name is already uploaded.',
    })
    expect((await refusalOf(await upload(b.token, privatePath(name), JPEG), 409)).code).toBe('duplicate')
  })

  it('refuses a bad name, a type or bytes that are not JPEG, and more than 1 MB', async () => {
    const { token } = await signUp()
    for (const name of [photo().toUpperCase(), 'photo.jpg', '..%2Fx.jpg', `${crypto.randomUUID()}.png`]) {
      expect(await refusalOf(await upload(token, privatePath(name), JPEG))).toEqual({
        code: 'photo_bad_name', message: 'A photo name is a lowercase UUID and .jpg.',
      })
    }
    expect((await refusalOf(await upload(token, privatePath(photo()), JPEG, 'image/svg+xml'))).code).toBe('photo_not_jpeg')
    expect((await refusalOf(await upload(token, privatePath(photo()), JPEG, 'application/octet-stream'))).code)
      .toBe('photo_not_jpeg')
    expect((await refusalOf(await upload(token, privatePath(photo()), new TextEncoder().encode('GIF89a')))).code)
      .toBe('photo_not_jpeg')
    expect((await refusalOf(await upload(token, privatePath(photo()), new Uint8Array(0)))).code).toBe('photo_not_jpeg')
    const atLimit = new Uint8Array(1_000_000)
    atLimit.set(JPEG)
    expect((await upload(token, privatePath(photo()), atLimit)).status).toBe(200)
    const over = new Uint8Array(1_000_001)
    over.set(JPEG)
    expect((await refusalOf(await upload(token, privatePath(photo()), over), 413)).code).toBe('too_large')
  })

  it("refuses a name a listing uses, the caller's or anyone's, after its object was deleted", async () => {
    const a = await signUp()
    const b = await signUp()
    const name = photo()
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: a.userId, photo: name })
    for (const account of [a, b]) {
      expect(await refusalOf(await upload(account.token, sharedPath(name), JPEG))).toEqual({
        code: 'photo_name_in_use', message: 'A listing already uses that photo name.',
      })
    }
  })

  it('takes 60 a day across both buckets; the 61st is refused, a deletion frees a slot, older ones do not count',
    async () => {
      const a = await signUp()
      await photosToday(a.userId, 30, 'gym-photos')
      await photosToday(a.userId, 29, 'gym-photos-private')
      const sixtieth = photo()
      expect((await upload(a.token, privatePath(sixtieth), JPEG)).status).toBe(200)
      expect(await refusalOf(await upload(a.token, sharedPath(photo()), JPEG))).toEqual({
        code: 'photo_daily_limit', message: "You've uploaded a lot of photos today. Try again tomorrow.",
      })
      expect((await request('DELETE', privatePath(sixtieth), { token: a.token })).status).toBe(204)
      expect((await upload(a.token, sharedPath(photo()), JPEG)).status).toBe(200)
      expect((await refusalOf(await upload(a.token, sharedPath(photo()), JPEG))).code).toBe('photo_daily_limit')
      await agedRows('photo_objects', 'owner_id', a.userId)
      expect((await upload(a.token, sharedPath(photo()), JPEG)).status).toBe(200)
    })

  it('answers a retry of a finished upload with 409 even at the daily limit', async () => {
    const a = await signUp()
    await photosToday(a.userId, 59, 'gym-photos-private')
    const name = photo()
    expect((await upload(a.token, privatePath(name), JPEG)).status).toBe(200)
    expect((await refusalOf(await upload(a.token, privatePath(name), JPEG), 409)).code).toBe('duplicate')
  })

  it('finishes an upload whose object was never written when its owner sends it again, and nobody else', async () => {
    const a = await signUp()
    const b = await signUp()
    const name = await uploadedPhoto(a.userId, 'gym-photos-private', { stored: false })
    expect((await refusalOf(await upload(b.token, privatePath(name), JPEG), 409)).code).toBe('duplicate')
    expect(await env.GYM_PHOTOS_PRIVATE.head(name)).toBeNull()
    expect((await upload(a.token, privatePath(name), JPEG)).status).toBe(200)
    expect((await request('GET', privatePath(name), { token: a.token })).status).toBe(200)
    expect(await rowsOf(name)).toBe(1)
  })

  it('gives its row back when the object cannot be written', async () => {
    const { userId } = await signUp()
    const name = photo()
    const down = {
      put: async () => {
        throw new Error('R2 is down')
      },
      head: async () => null,
    } as unknown as R2Bucket
    await expect(uploadPhoto({ ...env, GYM_PHOTOS_PRIVATE: down }, userId, PRIVATE_BUCKET, name, 'image/jpeg', JPEG))
      .rejects.toThrow('R2 is down')
    expect(await rowsOf(name)).toBe(0)
  })

  it.each([
    ['a new upload', false],
    ['finishing an unfinished upload', true],
  ])('refuses %s with photo_missing, and keeps no object, when a delete takes its row while the object is written',
    async (_, unfinished) => {
      const { userId } = await signUp()
      const name = unfinished ? await uploadedPhoto(userId, 'gym-photos-private', { stored: false }) : photo()
      const real = env.GYM_PHOTOS_PRIVATE
      // The app's delete-all (account deletion) lands while the put is in flight: the object isn't there yet, so the
      // delete only takes the row.
      const racing = new Proxy(real, {
        get(target, key) {
          if (key === 'put') {
            return async (...args: Parameters<R2Bucket['put']>) => {
              await env.DB.prepare('DELETE FROM photo_objects WHERE name = ?1').bind(name).run()
              return target.put(...args)
            }
          }
          const value: unknown = Reflect.get(target, key, target)
          return typeof value === 'function' ? value.bind(target) : value
        },
      })
      const racingEnv = { ...env, GYM_PHOTOS_PRIVATE: racing }
      const attempt = uploadPhoto(racingEnv, userId, PRIVATE_BUCKET, name, 'image/jpeg', JPEG)
      await expect(attempt).rejects.toMatchObject({ status: 422, code: 'photo_missing' })
      expect(await real.head(name)).toBeNull()
      expect(await rowsOf(name)).toBe(0)
    })

  it("refuses to finish an unfinished upload whose name a listing uses, and writes nothing", async () => {
    const a = await signUp()
    const name = await uploadedPhoto(a.userId, 'gym-photos-private', { stored: false })
    const gym = await insertGym({ visibility: 'private', owner: a.userId })
    await insertListing({ gym, item: await genericItem(), visibility: 'private', owner: a.userId, photo: name })
    expect((await refusalOf(await upload(a.token, privatePath(name), JPEG))).code).toBe('photo_name_in_use')
    expect(await env.GYM_PHOTOS_PRIVATE.head(name)).toBeNull()
  })

  it('refuses an owner whose account is gone', async () => {
    const attempt = uploadPhoto(env, crypto.randomUUID(), PRIVATE_BUCKET, photo(), 'image/jpeg', JPEG)
    await expect(attempt).rejects.toMatchObject({ code: 'photo_owner_missing' })
  })

  it('takes exactly 60 when 70 arrive together', async () => {
    const a = await signUp()
    const answers = await Promise.all(Array.from({ length: 70 }, () => upload(a.token, privatePath(photo()), JPEG)))
    expect(answers.filter((res) => res.status === 200)).toHaveLength(60)
    expect(answers.filter((res) => res.status === 422)).toHaveLength(10)
    expect(await mine(a.token)).toHaveLength(60)
  })
})

describe('shared photos', () => {
  it('are deleted by their owner, and by an admin only while a removed listing names them', async () => {
    const author = await signUp()
    const other = await signUp()
    const boss = await signUp()
    await makeAdmin(boss.userId)
    const name = photo()
    expect((await upload(author.token, sharedPath(name), JPEG)).status).toBe(200)
    const gym = await insertGym({ visibility: 'public', createdBy: author.userId })
    const listing = await insertListing({ gym, item: await genericItem(), visibility: 'public', addedBy: author.userId, photo: name })
    for (const account of [other, boss]) {
      expect((await refusalOf(await request('DELETE', sharedPath(name), { token: account.token }), 403)).code)
        .toBe('not_allowed')
      expect(await env.GYM_PHOTOS.head(name)).not.toBeNull()
    }
    await setStatus('gym_equipment', listing, 'removed')
    expect((await request('DELETE', sharedPath(name), { token: boss.token })).status).toBe(204)
    expect(await env.GYM_PHOTOS.head(name)).toBeNull()
    expect(await rowsOf(name)).toBe(0)
    const own = await uploadedPhoto(author.userId, 'gym-photos')
    expect((await request('DELETE', sharedPath(own), { token: author.token })).status).toBe(204)
    expect(await env.GYM_PHOTOS.head(own)).toBeNull()
  })
})

describe('a delete', () => {
  it('answers 204 when nothing is there, in either bucket, and for a name that could not be one', async () => {
    const { token } = await signUp()
    for (const path of [privatePath(photo()), sharedPath(photo()), privatePath('photo.jpg')]) {
      expect((await request('DELETE', path, { token })).status, path).toBe(204)
    }
  })
})

describe('detaching photos', () => {
  it("clears the caller's own listing photos, private and shared, and moves them for sync", async () => {
    const a = await signUp()
    const b = await signUp()
    const item = await genericItem()
    const publicGym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const ownPrivate = await insertListing({
      gym: await insertGym({ visibility: 'private', owner: a.userId }), item, visibility: 'private', owner: a.userId,
      photo: photo(),
    })
    const ownPublic = await insertListing({ gym: publicGym, item, visibility: 'public', addedBy: a.userId, photo: photo() })
    const theirPublic = await insertListing({ gym: publicGym, item, visibility: 'public', addedBy: b.userId, photo: photo() })
    const theirPrivate = await insertListing({
      gym: await insertGym({ visibility: 'private', owner: b.userId }), item, visibility: 'private', owner: b.userId,
      photo: photo(),
    })
    expect((await request('POST', '/v1/photos/detach', { token: a.token })).status).toBe(204)
    const row = (id: string) => env.DB.prepare('SELECT photo_path, client_updated_at, updated_at FROM gym_equipment WHERE id = ?1')
      .bind(id).first<{ photo_path: string | null; client_updated_at: string; updated_at: string }>()
    for (const id of [ownPrivate, ownPublic]) {
      const after = (await row(id))!
      expect(after.photo_path).toBeNull()
      expect(after.client_updated_at > '2026-11-07T10:00:00.000000Z').toBe(true)
      expect(after.updated_at > '2026-11-07T10:00:00.000000Z').toBe(true)
    }
    for (const id of [theirPublic, theirPrivate]) expect((await row(id))!.photo_path).not.toBeNull()
    expect((await request('GET', `/v1/gyms/${publicGym}/listings`, { token: b.token })).status).toBe(200)
  })

  it("leaves a removed listing's photo named, so the admin can still delete it", async () => {
    const author = await signUp()
    const boss = await signUp()
    await makeAdmin(boss.userId)
    const name = await uploadedPhoto(author.userId, 'gym-photos')
    const gym = await insertGym({ visibility: 'public', createdBy: author.userId })
    const listing = await insertListing({
      gym, item: await genericItem(), visibility: 'public', addedBy: author.userId, photo: name, status: 'removed',
    })
    expect((await request('POST', '/v1/photos/detach', { token: author.token })).status).toBe(204)
    const after = await env.DB.prepare('SELECT photo_path FROM gym_equipment WHERE id = ?1').bind(listing)
      .first<{ photo_path: string | null }>()
    expect(after!.photo_path).toBe(name)
    expect((await request('DELETE', sharedPath(name), { token: boss.token })).status).toBe(204)
    expect(await env.GYM_PHOTOS.head(name)).toBeNull()
    expect(await rowsOf(name)).toBe(0)
  })
})
