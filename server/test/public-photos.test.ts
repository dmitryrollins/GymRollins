import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import app from '../src/index.ts'
import { JPEG } from './gym-fixtures.ts'
import { ORIGIN } from './helpers.ts'

/** A request as a phone's image loader or the uploader makes it: no session. */
const fetchPublic = (path: string, init: RequestInit = {}) =>
  Promise.resolve(app.fetch(new Request(`${ORIGIN}${path}`, init), env))

describe('public photos', () => {
  it('serve a shared photo to anyone, with its ETag, and 304 while it is unchanged', async () => {
    const name = `${crypto.randomUUID()}.jpg`
    const stored = (await env.GYM_PHOTOS.put(name, JPEG))!
    const res = await fetchPublic(`/photos/shared/${name}`)
    expect(res.status).toBe(200)
    expect(Object.fromEntries(res.headers)).toMatchObject({
      'content-type': 'image/jpeg', 'cache-control': 'public, max-age=3600', etag: stored.httpEtag,
      'content-length': String(JPEG.length), 'x-content-type-options': 'nosniff',
    })
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(JPEG)
    const unchanged = await fetchPublic(`/photos/shared/${name}`, { headers: { 'if-none-match': stored.httpEtag } })
    expect(unchanged.status).toBe(304)
    expect(await unchanged.text()).toBe('')
    const head = await fetchPublic(`/photos/shared/${name}`, { method: 'HEAD' })
    expect(head.status).toBe(200)
    expect(head.headers.get('etag')).toBe(stored.httpEtag)
    expect(head.headers.get('content-length')).toBe(String(JPEG.length))
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
    for (const name of ['own-0453-0.jpg', 'kind-leg-press.jpg']) {
      const res = await fetchPublic(`/photos/exercises/${name}?v=ab12cd34ef56`)
      expect(res.status).toBe(200)
      expect(res.headers.get('content-type')).toBe('image/jpeg')
      expect(res.headers.get('cache-control')).toBe('public, max-age=31536000')
    }
    const res = await fetchPublic('/photos/exercises/manifest.json')
    expect(res.headers.get('content-type')).toBe('application/json')
    expect(res.headers.get('cache-control')).toBe('public, max-age=60')
    expect(await res.json()).toEqual(manifest)
  })

  it('serve nothing else from the exercise bucket', async () => {
    await env.EXERCISE_PHOTOS.put('notes.txt', 'private notes')
    for (const name of ['notes.txt', 'own-abc-0.jpg', 'kind-Bad.jpg', '..%2Fmanifest.json']) {
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
