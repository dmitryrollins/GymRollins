import { vi } from 'vitest'

export interface AppleKeys {
  privateKey: CryptoKey
  jwk: JsonWebKey & { kid: string }
}

const base64url = (bytes: ArrayBuffer | string) =>
  btoa(typeof bytes === 'string' ? bytes : String.fromCharCode(...new Uint8Array(bytes)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

export async function appleKeyPair(): Promise<AppleKeys> {
  const pair = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  ) as CryptoKeyPair
  const exported = await crypto.subtle.exportKey('jwk', pair.publicKey) as JsonWebKey
  return { privateKey: pair.privateKey, jwk: { ...exported, kid: crypto.randomUUID(), alg: 'RS256', use: 'sig' } }
}

/** A key pair whose public half Apple's key URL serves, through a spy on fetch: Better Auth's real check runs. */
export async function mockAppleKeys(): Promise<AppleKeys> {
  const keys = await appleKeyPair()
  const realFetch = globalThis.fetch
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const url = input instanceof Request ? input.url : String(input)
    if (url === 'https://appleid.apple.com/auth/keys') return Response.json({ keys: [keys.jwk] })
    return realFetch(input, init)
  })
  return keys
}

/** An id token as Apple signs one for the app: RS256, Apple's issuer, ten minutes. */
export async function appleIdToken(keys: AppleKeys, claims: Record<string, unknown>): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  const header = base64url(JSON.stringify({ alg: 'RS256', kid: keys.jwk.kid, typ: 'JWT' }))
  const payload = base64url(JSON.stringify({
    iss: 'https://appleid.apple.com',
    iat: now,
    exp: now + 600,
    email: `${String(claims.sub)}@privaterelay.appleid.com`,
    email_verified: 'true',
    ...claims,
  }))
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', keys.privateKey, new TextEncoder().encode(
    `${header}.${payload}`,
  ))
  return `${header}.${payload}.${base64url(signature)}`
}
