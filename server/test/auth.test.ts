import { env } from 'cloudflare:workers'
import { getMigrations } from 'better-auth/db/migration'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createAuth, passwordAuthAllowed, SESSION_EXPIRES_IN } from '../src/auth/auth.ts'
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

  /** A sign-up straight to Better Auth, built for `baseURL` with ALLOW_PASSWORD_AUTH=1. */
  const signUpAt = (baseURL: string) => createAuth({ ...env, ALLOW_PASSWORD_AUTH: '1', PUBLIC_BASE_URL: baseURL }).handler(
    new Request(`${baseURL}/api/auth/sign-up/email`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email: `base-${crypto.randomUUID()}@test.local`, password: 'correct-horse-battery', name: 'B' }),
    }),
  )

  it('is on only where the base URL is this machine, whatever ALLOW_PASSWORD_AUTH says', async () => {
    expect(passwordAuthAllowed({ ...env, ALLOW_PASSWORD_AUTH: '1', PUBLIC_BASE_URL: 'http://127.0.0.1:8787' })).toBe(true)
    expect(passwordAuthAllowed({ ...env, ALLOW_PASSWORD_AUTH: '1', PUBLIC_BASE_URL: 'http://localhost' })).toBe(true)
    expect(passwordAuthAllowed({ ...env, ALLOW_PASSWORD_AUTH: '0', PUBLIC_BASE_URL: 'http://localhost' })).toBe(false)
    for (const base of ['https://api.gymrollins.app', 'http://localhost.example.com', 'http://127.0.0.1.nip.io',
      'https://user@localhost.example.com', 'not a url', '']) {
      expect(passwordAuthAllowed({ ...env, ALLOW_PASSWORD_AUTH: '1', PUBLIC_BASE_URL: base }), base).toBe(false)
    }
  })

  it('refuses a sign-up when the base URL is not this machine, even with ALLOW_PASSWORD_AUTH=1', async () => {
    expect((await signUpAt('http://127.0.0.1:8787')).status).toBe(200)
    const remote = await signUpAt('https://api.gymrollins.app')
    expect(remote.status).toBe(400)
    expect(await remote.json()).toMatchObject({ code: 'EMAIL_PASSWORD_SIGN_UP_DISABLED' })
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
    expect(await status(await appleIdToken(keys, { ...claims, aud: env.APPLE_BUNDLE_ID }), 'other')).toBe(400)
    const stranger = await appleKeyPair()
    expect(await status(await appleIdToken(stranger, { ...claims, aud: env.APPLE_BUNDLE_ID }), 'n')).toBe(401)
  })

  it("refuses the token's own nonce claim sent back as the nonce: anyone with the token could replay it", async () => {
    const keys = await mockAppleKeys()
    const hashed = await sha256Hex('raw-nonce')
    const tokens = [
      [await appleIdToken(keys, { aud: env.APPLE_BUNDLE_ID, sub: 'apple-6', nonce: hashed }), hashed],
      // Apple was given the raw nonce: the claim is the raw value, which Better Auth alone would also take.
      [await appleIdToken(keys, { aud: env.APPLE_BUNDLE_ID, sub: 'apple-6', nonce: 'raw-nonce' }), 'raw-nonce'],
      [await appleIdToken(keys, { aud: env.APPLE_BUNDLE_ID, sub: 'apple-6' }), 'raw-nonce'],
      ['not-a-jwt', 'raw-nonce'],
      [`x.${btoa('{"nonce":').replace(/=+$/, '')}.y`, 'raw-nonce'],
    ]
    for (const [token, nonce] of tokens) {
      const res = await signInWithApple(token, nonce)
      expect(res.status, token).toBe(400)
      expect(await res.json()).toMatchObject({ error: { code: 'bad_request' } })
      expect(res.headers.get('set-auth-token')).toBeNull()
    }
    const accounts = await env.DB.prepare("SELECT count(*) AS n FROM account WHERE accountId = 'apple-6'")
      .first<{ n: number }>()
    expect(accounts!.n).toBe(0)
  })

  it("stores none of Apple's tokens, on the first sign-in or the next", async () => {
    const keys = await mockAppleKeys()
    const sub = `apple-${crypto.randomUUID()}`
    for (let attempt = 0; attempt < 2; attempt++) {
      const idToken = await appleIdToken(keys, { aud: env.APPLE_BUNDLE_ID, sub, nonce: await sha256Hex(`n${attempt}`) })
      expect((await signInWithApple(idToken, `n${attempt}`)).status).toBe(200)
      const { results } = await env.DB.prepare(
        "SELECT idToken, accessToken, refreshToken FROM account WHERE providerId = 'apple' AND accountId = ?1",
      ).bind(sub).all()
      expect(results).toEqual([{ idToken: null, accessToken: null, refreshToken: null }])
    }
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
