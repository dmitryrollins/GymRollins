import { assert, assertEquals } from 'jsr:@std/assert@^1'
import {
  authenticate,
  bearerToken,
  jwtClaims,
  metadataDocument,
  metadataResponse,
  resourceMetadataUrl,
  unauthorized,
} from './auth.ts'

const BASE = 'http://127.0.0.1:55421'
const USER = '11111111-2222-4333-8444-555555555555'

function b64url(obj: unknown): string {
  return btoa(JSON.stringify(obj)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function fakeJwt(claims: Record<string, unknown>): string {
  return `${b64url({ alg: 'ES256', typ: 'JWT' })}.${b64url(claims)}.signature`
}

const verifyAs = (id: string | null) => (_token: string) => Promise.resolve(id ? { id } : null)
const req = (auth?: string) =>
  new Request(`${BASE}/functions/v1/mcp`, { method: 'POST', headers: auth ? { authorization: auth } : {} })

Deno.test('bearerToken: only a well-formed Bearer header yields a token', () => {
  assertEquals(bearerToken(req('Bearer abc.def.ghi')), 'abc.def.ghi')
  assertEquals(bearerToken(req('bearer abc')), 'abc')
  assertEquals(bearerToken(req()), null)
  assertEquals(bearerToken(req('Basic abc')), null)
  assertEquals(bearerToken(req('Bearer ')), null)
  assertEquals(bearerToken(req(`Bearer ${'x'.repeat(10_000)}`)), null)
})

Deno.test('jwtClaims: decodes the base64url payload; garbage → null', () => {
  assertEquals(jwtClaims(fakeJwt({ sub: USER, client_id: 'c1' })), { sub: USER, client_id: 'c1' })
  assertEquals(jwtClaims('not-a-jwt'), null)
  assertEquals(jwtClaims('a.!!!.c'), null)
})

Deno.test('authenticate: missing or invalid token → null', async () => {
  assertEquals(await authenticate(req(), verifyAs(USER)), null)
  assertEquals(await authenticate(req('Bearer nope'), verifyAs(null)), null)
})

Deno.test('authenticate: a token whose sub differs from the verified user → null', async () => {
  const token = fakeJwt({ sub: 'someone-else' })
  assertEquals(await authenticate(req(`Bearer ${token}`), verifyAs(USER)), null)
})

Deno.test('authenticate: an app session token (no client_id) is rejected — only OAuth client tokens pass', async () => {
  for (
    const claims of [
      { sub: USER, role: 'authenticated' },
      { sub: USER, role: 'authenticated', client_id: '' },
      { sub: USER, role: 'authenticated', client_id: 42 },
    ]
  ) {
    const token = fakeJwt(claims)
    assertEquals(await authenticate(req(`Bearer ${token}`), verifyAs(USER)), null, JSON.stringify(claims))
  }
  const oauth = fakeJwt({ sub: USER, role: 'authenticated', client_id: 'claude-dcr-123' })
  assertEquals(await authenticate(req(`Bearer ${oauth}`), verifyAs(USER)), {
    userId: USER,
    clientId: 'claude-dcr-123',
    token: oauth,
  })
})

Deno.test('unauthorized: 401 with the exact WWW-Authenticate metadata pointer and a JSON body', async () => {
  const res = unauthorized(BASE)
  assertEquals(res.status, 401)
  assertEquals(
    res.headers.get('www-authenticate'),
    'Bearer resource_metadata="http://127.0.0.1:55421/functions/v1/mcp/oauth-protected-resource"',
  )
  assert(res.headers.get('access-control-expose-headers')?.toLowerCase().includes('www-authenticate'))
  const body = await res.json()
  assertEquals(body.error, 'invalid_token')
})

Deno.test('metadata document: RFC 9728 fields for the MCP resource', async () => {
  const doc = {
    resource: 'http://127.0.0.1:55421/functions/v1/mcp',
    authorization_servers: ['http://127.0.0.1:55421/auth/v1'],
    scopes_supported: ['email', 'profile'],
    bearer_methods_supported: ['header'],
    resource_name: 'GymRollins',
  }
  assertEquals(metadataDocument(`${BASE}/`), doc)
  assertEquals(resourceMetadataUrl(BASE), `${BASE}/functions/v1/mcp/oauth-protected-resource`)
  const res = metadataResponse(BASE)
  assertEquals(res.status, 200)
  assertEquals(res.headers.get('content-type'), 'application/json')
  assertEquals(res.headers.get('access-control-allow-origin'), '*')
  assertEquals(await res.json(), doc)
})
