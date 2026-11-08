import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'

// The three buckets of wrangler.jsonc, as local R2 in workerd (the same simulator `wrangler dev --local` uses).
describe('R2 buckets', () => {
  it('are three separate buckets', async () => {
    const name = `${crypto.randomUUID()}.jpg`
    await env.GYM_PHOTOS.put(name, new Uint8Array([0xff, 0xd8, 0xff]))
    expect(await env.GYM_PHOTOS.head(name)).not.toBeNull()
    expect(await env.GYM_PHOTOS_PRIVATE.head(name)).toBeNull()
    expect(await env.EXERCISE_PHOTOS.head(name)).toBeNull()
    await env.GYM_PHOTOS.delete(name)
    expect(await env.GYM_PHOTOS.head(name)).toBeNull()
  })

  it('give the MD5 as the ETag, and a conditional get without a body', async () => {
    const name = `${crypto.randomUUID()}.jpg`
    const stored = await env.GYM_PHOTOS.put(name, new TextEncoder().encode('hello'))
    expect(stored!.etag).toBe('5d41402abc4b2a76b9719d911017c592')
    const unchanged = await env.GYM_PHOTOS.get(name, { onlyIf: new Headers({ 'if-none-match': stored!.httpEtag }) })
    expect(unchanged).not.toBeNull()
    expect('body' in unchanged!).toBe(false)
  })
})
