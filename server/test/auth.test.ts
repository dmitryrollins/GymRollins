import { env } from 'cloudflare:workers'
import { getMigrations } from 'better-auth/db/migration'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createAuth, SESSION_EXPIRES_IN } from '../src/auth/auth.ts'
import { appleIdToken, appleKeyPair, mockAppleKeys, sha256Hex } from './apple.ts'
import { request, signUp } from './helpers.ts'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

afterEach(() => vi.restoreAllMocks())

async function sessionUser(token: string): Promise<string | null> {
  const body = await (await request('GET', '/api/auth/get-session', { token })).json<{ user: { id: string } } | null>()
  return body?.user.id ?? null
}

/** The app's Sign in with Apple call: Apple's id token and the raw nonce whose SHA-256 the token carries. */
async function signInWithApple(token: string, nonce: string): Promise<Response> {
  return request('POST', '/api/auth/sign-in/social', { body: { provider: 'apple', idToken: { token, nonce } } })
}

describe('the schema', () => {
  it('has every table, column and index Better Auth expects', async () => {
    const { toBeCreated, toBeAdded, toBeAddedIndexes } = await getMigrations(createAuth(env).options)
    expect(toBeCreated).toEqual([])
    expect(toBeAdded).toEqual([])
    expect(toBeAddedIndexes).toEqual([])
  })
})

describe('email and password (debug builds and tests)', () => {
  it('signs up with a UUID user id and a bearer session token', async () => {
    const { token, userId } = await signUp()
    expect(userId).toMatch(UUID)
    expect(await sessionUser(token)).toBe(userId)
  })

  it('is off unless ALLOW_PASSWORD_AUTH is 1', async () => {
    const res = await createAuth({ ...env, ALLOW_PASSWORD_AUTH: '0' }).handler(
      new Request('http://localhost/api/auth/sign-up/email', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ email: 'off@test.local', password: 'correct-horse-battery', name: 'Off' }),
      }),
    )
    expect(res.status).toBe(400)
  })
})

describe('sessions', () => {
  it('last 60 days', async () => {
    const { token } = await signUp()
    const row = await env.DB.prepare('SELECT expiresAt FROM session WHERE token = ?1').bind(token)
      .first<{ expiresAt: string }>()
    const left = new Date(row!.expiresAt).getTime() - Date.now()
    expect(Math.abs(left - SESSION_EXPIRES_IN * 1000)).toBeLessThan(60_000)
  })

  it('end on sign-out', async () => {
    const { token } = await signUp()
    expect((await request('POST', '/api/auth/sign-out', { token })).status).toBe(200)
    expect(await sessionUser(token)).toBeNull()
  })
})

describe('Sign in with Apple, with the id token the app gets', () => {
  it('signs in with the raw nonce, without an Origin header, and gives a session token', async () => {
    const keys = await mockAppleKeys()
    const idToken = await appleIdToken(keys, {
      aud: env.APPLE_BUNDLE_ID,
      sub: 'apple-1',
      nonce: await sha256Hex('raw-nonce'),
    })
    const res = await signInWithApple(idToken, 'raw-nonce')
    expect(res.status).toBe(200)
    const session = res.headers.get('set-auth-token')
    expect(session).toBeTruthy()
    expect(await sessionUser(session!)).toMatch(UUID)
  })

  it('finds the same account on the next sign-in', async () => {
    const keys = await mockAppleKeys()
    const once = async () => {
      const idToken = await appleIdToken(keys, { aud: env.APPLE_BUNDLE_ID, sub: 'apple-2', nonce: await sha256Hex('n') })
      return sessionUser((await signInWithApple(idToken, 'n')).headers.get('set-auth-token')!)
    }
    expect(await once()).toBe(await once())
  })

  it("refuses another app's token, a wrong nonce and a key Apple never published", async () => {
    const keys = await mockAppleKeys()
    const claims = { sub: 'apple-3', nonce: await sha256Hex('n') }
    const status = async (idToken: string, nonce: string) => (await signInWithApple(idToken, nonce)).status
    expect(await status(await appleIdToken(keys, { ...claims, aud: 'com.other.app' }), 'n')).toBe(401)
    expect(await status(await appleIdToken(keys, { ...claims, aud: env.APPLE_BUNDLE_ID }), 'other')).toBe(401)
    const stranger = await appleKeyPair()
    expect(await status(await appleIdToken(stranger, { ...claims, aud: env.APPLE_BUNDLE_ID }), 'n')).toBe(401)
  })

  it('refuses a sign-in that leaves the nonce out', async () => {
    const keys = await mockAppleKeys()
    const idToken = await appleIdToken(keys, {
      aud: env.APPLE_BUNDLE_ID,
      sub: 'apple-4',
      nonce: await sha256Hex('n'),
    })
    const res = await request('POST', '/api/auth/sign-in/social', { body: { provider: 'apple', idToken: { token: idToken } } })
    expect(res.status).toBe(400)
    expect(await res.json()).toMatchObject({ error: { code: 'bad_request' } })
    expect(res.headers.get('set-auth-token')).toBeNull()
  })

  it('refuses a sign-in body over 16 KB', async () => {
    const res = await signInWithApple('x'.repeat(17 * 1024), 'n')
    expect(res.status).toBe(413)
    expect(await res.json()).toMatchObject({ error: { code: 'too_large' } })
  })

  it("answers Better Auth's errors in the API's error shape", async () => {
    const keys = await mockAppleKeys()
    const wrongAudience = await appleIdToken(keys, {
      aud: 'com.other.app',
      sub: 'apple-5',
      nonce: await sha256Hex('n'),
    })
    const shape = { error: { code: expect.stringMatching(/^[a-z_]+$/), message: expect.any(String) } }
    const refused = await signInWithApple(wrongAudience, 'n')
    expect(refused.status).toBe(401)
    const refusedBody = await refused.json()
    expect(refusedBody).toMatchObject(shape)
    const email = `dup-${crypto.randomUUID()}@test.local`
    const body = { email, password: 'correct-horse-battery', name: 'Dup' }
    expect((await request('POST', '/api/auth/sign-up/email', { body })).status).toBe(200)
    const again = await request('POST', '/api/auth/sign-up/email', { body })
    expect(again.status).toBeGreaterThanOrEqual(400)
    const againBody = await again.json()
    expect(againBody).toMatchObject(shape)
  })

  it('refuses a social sign-in without an id token', async () => {
    const res = await request('POST', '/api/auth/sign-in/social', { body: { provider: 'apple' } })
    expect(res.status).toBe(400)
  })

  it("answers Better Auth routes the app doesn't use with 404", async () => {
    const { token } = await signUp()
    expect((await request('GET', '/api/auth/callback/apple')).status).toBe(404)
    expect((await request('POST', '/api/auth/link-social', { token, body: { provider: 'apple' } })).status).toBe(404)
    expect((await request('POST', '/api/auth/update-user', { token, body: { name: 'x' } })).status).toBe(404)
  })
})
