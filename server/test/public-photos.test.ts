import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import app from '../src/index.ts'
import { genericItem, insertGym, insertItem, insertListing, JPEG } from './gym-fixtures.ts'
import { ORIGIN, request, signUp } from './helpers.ts'

/** A request as a phone's image loader or the uploader makes it: no session. */
const fetchPublic = (path: string, init: RequestInit = {}) =>
  Promise.resolve(app.fetch(new Request(`${ORIGIN}${path}`, init), env))

const CSP = "default-src 'none'; sandbox"
type Status = 'active' | 'flagged' | 'removed'

/** A shared photo in R2 and, unless `status` is null, a public listing in that status naming it. */
async function sharedPhoto(status: Status | null = 'active'): Promise<{ name: string; etag: string }> {
  const name = `${crypto.randomUUID()}.jpg`
  const etag = (await env.GYM_PHOTOS.put(name, JPEG))!.httpEtag
  if (status === null) return { name, etag }
  const gym = await insertGym({ visibility: 'public' })
  await insertListing({ gym, item: await genericItem(), visibility: 'public', photo: name, status })
  return { name, etag }
}

describe('public photos', () => {
  it('serve a shared photo to anyone, with its ETag, and 304 while it is unchanged', async () => {
    const { name, etag } = await sharedPhoto()
    const res = await fetchPublic(`/photos/shared/${name}`)
    expect(res.status).toBe(200)
    expect(Object.fromEntries(res.headers)).toMatchObject({
      'content-type': 'image/jpeg', 'cache-control': 'public, max-age=3600', etag,
      'content-length': String(JPEG.length), 'x-content-type-options': 'nosniff', 'content-security-policy': CSP,
    })
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(JPEG)
    const unchanged = await fetchPublic(`/photos/shared/${name}`, { headers: { 'if-none-match': etag } })
    expect(unchanged.status).toBe(304)
    expect(unchanged.headers.get('content-security-policy')).toBe(CSP)
    expect(await unchanged.text()).toBe('')
    const head = await fetchPublic(`/photos/shared/${name}`, { method: 'HEAD' })
    expect(head.status).toBe(200)
    expect(head.headers.get('etag')).toBe(etag)
    expect(head.headers.get('content-length')).toBe(String(JPEG.length))
  })

  it('serve a shared photo only while a public listing that is not removed names it', async () => {
    for (const status of ['active', 'flagged'] as const) {
      const { name } = await sharedPhoto(status)
      expect((await fetchPublic(`/photos/shared/${name}`)).status, status).toBe(200)
    }
    const unused = await sharedPhoto(null)
    const removed = await sharedPhoto('removed')
    const owner = await signUp()
    const privateOnly = await sharedPhoto(null)
    await insertListing({
      gym: await insertGym({ visibility: 'private', owner: owner.userId }), item: await genericItem(),
      visibility: 'private', owner: owner.userId, photo: privateOnly.name,
    })
    for (const [why, { name, etag }] of [['unused', unused], ['removed', removed], ['private', privateOnly]] as const) {
      for (const init of [{}, { method: 'HEAD' }, { headers: { 'if-none-match': etag } }]) {
        expect((await fetchPublic(`/photos/shared/${name}`, init)).status, `${why} ${JSON.stringify(init)}`).toBe(404)
      }
    }
  })

  it('serve the photo an item takes from its best listing, which is what the app shows for the item', async () => {
    const { token, userId } = await signUp()
    const item = await insertItem({ brand: 'Probe', model: crypto.randomUUID(), createdBy: userId })
    const name = `${crypto.randomUUID()}.jpg`
    await env.GYM_PHOTOS.put(name, JPEG)
    await insertListing({ gym: await insertGym({ visibility: 'public' }), item, visibility: 'public', photo: name })
    const items = await (await request('GET', '/v1/items?kind=dumbbells', { token }))
      .json<{ rows: { id: string; photo_path: string | null }[] }>()
    expect(items.rows.find((row) => row.id === item)?.photo_path).toBe(name)
    for (const { photo_path: path } of items.rows) {
      if (path !== null) expect((await fetchPublic(`/photos/shared/${path}`)).status, path).toBe(200)
    }
  })

  it('read the photo afresh for an If-None-Match R2 could not parse, and match the forms it can', async () => {
    const { name, etag } = await sharedPhoto()
    for (const seen of ['garbage', '"x', etag.replaceAll('"', ''), '"a b"', `${etag},`]) {
      const res = await fetchPublic(`/photos/shared/${name}`, { headers: { 'if-none-match': seen } })
      expect(res.status, seen).toBe(200)
      expect(new Uint8Array(await res.arrayBuffer())).toEqual(JPEG)
    }
    for (const seen of [etag, `W/${etag}`, `"other", ${etag}`, `"other" ,W/${etag}`, '*', ` ${etag} `]) {
      const res = await fetchPublic(`/photos/shared/${name}`, { headers: { 'if-none-match': seen } })
      expect(res.status, seen).toBe(304)
    }
    expect((await fetchPublic(`/photos/shared/${name}`, { headers: { 'if-none-match': '"other"' } })).status).toBe(200)
  })

  it('answer 404 for a missing photo, a name that could not be one, and a private photo', async () => {
    const privateName = `${crypto.randomUUID()}.jpg`
    await env.GYM_PHOTOS_PRIVATE.put(privateName, JPEG)
    const paths = [
      `/photos/shared/${privateName}`, `/photos/shared/${crypto.randomUUID()}.jpg`, '/photos/shared/..%2Fsecret.jpg',
      '/photos/shared/NOT-A-UUID.jpg', `/photos/private/${privateName}`,
    ]
    for (const path of paths) {
      const res = await fetchPublic(path)
      expect(res.status, path).toBe(404)
      expect(await res.json()).toMatchObject({ error: { code: 'not_found' } })
    }
  })

  it("serve GymRollins' own photos and the manifest, each with its cache time", async () => {
    const manifest = {
      version: 1, updatedAt: '2026-11-08T00:00:00.000Z', photos: { '0453': 1 }, rev: { '0453': 'ab12cd34ef56' }, kinds: {},
    }
    await env.EXERCISE_PHOTOS.put('own-0453-0.jpg', JPEG)
    await env.EXERCISE_PHOTOS.put('kind-leg-press.jpg', JPEG)
    await env.EXERCISE_PHOTOS.put('manifest.json', JSON.stringify(manifest))
    await env.EXERCISE_PHOTOS.put('own-123456-123456.jpg', JPEG)
    for (const name of ['own-0453-0.jpg', 'kind-leg-press.jpg', 'own-123456-123456.jpg']) {
      const res = await fetchPublic(`/photos/exercises/${name}?v=ab12cd34ef56`)
      expect(res.status).toBe(200)
      expect(res.headers.get('content-type')).toBe('image/jpeg')
      expect(res.headers.get('cache-control')).toBe('public, max-age=31536000')
      expect(res.headers.get('content-security-policy')).toBe(CSP)
    }
    const res = await fetchPublic('/photos/exercises/manifest.json')
    expect(res.headers.get('content-type')).toBe('application/json')
    expect(res.headers.get('content-security-policy')).toBe(CSP)
    expect(res.headers.get('cache-control')).toBe('public, max-age=60')
    expect(await res.json()).toEqual(manifest)
  })

  it('serve nothing else from the exercise bucket', async () => {
    await env.EXERCISE_PHOTOS.put('notes.txt', 'private notes')
    await env.EXERCISE_PHOTOS.put('own-1234567-0.jpg', JPEG)
    await env.EXERCISE_PHOTOS.put('own-0-1234567.jpg', JPEG)
    const long = ['own-1234567-0.jpg', 'own-0-1234567.jpg', `own-${'9'.repeat(5000)}-0.jpg`]
    for (const name of ['notes.txt', 'own-abc-0.jpg', 'kind-Bad.jpg', '..%2Fmanifest.json', ...long]) {
      expect((await fetchPublic(`/photos/exercises/${name}`)).status, name).toBe(404)
    }
  })

  it('take no writes: gym photos go through /v1, exercise photos through the uploader', async () => {
    const writes: [string, string][] = [
      ['PUT', `/photos/shared/${crypto.randomUUID()}.jpg`], ['DELETE', '/photos/exercises/manifest.json'],
      ['POST', '/photos/exercises/own-1-0.jpg'],
    ]
    for (const [method, path] of writes) {
      const res = await fetchPublic(path, { method, body: method === 'DELETE' ? undefined : JPEG })
      expect(res.status, `${method} ${path}`).toBe(404)
    }
  })
})
