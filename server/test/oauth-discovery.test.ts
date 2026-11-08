// Claude's OAuth up to the sign-in page: discovery, registration, and the authorize step sending the browser
// to /connect (spec section 4, "Claude's connection", steps 1–3).
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { REGISTRATIONS_PER_HOUR } from '../src/auth/routes.ts'
import app from '../src/index.ts'
import { call, CLAUDE_AI, LOOPBACK, register, registerClient, RESOURCE, startFlow } from './claude.ts'
import { ORIGIN, signUp } from './helpers.ts'

const ISSUER = `${ORIGIN}/api/auth`

describe('discovery', () => {
  it.each(['/.well-known/oauth-protected-resource/mcp', '/.well-known/oauth-protected-resource'])(
    '%s names the MCP resource and its authorization server, with CORS',
    async (path) => {
      const res = await call(path)
      expect(res.status).toBe(200)
      expect(res.headers.get('access-control-allow-origin')).toBe('*')
      expect(await res.json()).toMatchObject({
        resource: RESOURCE,
        authorization_servers: [ISSUER],
        bearer_methods_supported: ['header'],
        scopes_supported: ['mcp'],
      })
    },
  )

  it.each([
    '/.well-known/oauth-authorization-server/api/auth',
    '/.well-known/oauth-authorization-server',
    '/api/auth/.well-known/oauth-authorization-server',
  ])('%s describes the authorization server', async (path) => {
    const res = await call(path)
    expect(res.status).toBe(200)
    expect(await res.json()).toMatchObject({
      issuer: ISSUER,
      authorization_endpoint: `${ISSUER}/oauth2/authorize`,
      token_endpoint: `${ISSUER}/oauth2/token`,
      registration_endpoint: `${ISSUER}/oauth2/register`,
      revocation_endpoint: `${ISSUER}/oauth2/revoke`,
      scopes_supported: ['mcp', 'offline_access'],
      response_types_supported: ['code'],
      grant_types_supported: ['authorization_code', 'refresh_token'],
      code_challenge_methods_supported: ['S256'],
    })
  })

  it('answers a CORS preflight on the metadata', async () => {
    const res = await call('/.well-known/oauth-protected-resource/mcp', { method: 'OPTIONS' })
    expect(res.status).toBe(204)
    expect(res.headers.get('access-control-allow-origin')).toBe('*')
  })

  it("sends no CORS headers on Better Auth's or the app's routes", async () => {
    expect(
      (await call('/api/auth/oauth2/token', { method: 'POST' })).headers.get('access-control-allow-origin'),
    ).toBeNull()
    expect((await call('/v1/claude/proposals')).headers.get('access-control-allow-origin')).toBeNull()
  })
})

describe('registration', () => {
  it.each([
    LOOPBACK,
    'http://localhost:61234/callback',
    'http://127.0.0.1/cb',
    CLAUDE_AI,
    'https://claude.com/api/mcp/auth_callback',
  ])('takes %s, with refresh tokens even when not asked', async (uri) => {
    const res = await register({ client_name: 'Claude', redirect_uris: [uri] })
    expect(res.status).toBe(201)
    expect(await res.json()).toMatchObject({
      redirect_uris: [uri],
      grant_types: ['authorization_code', 'refresh_token'],
      scope: 'mcp offline_access',
    })
  })

  it.each([
    'https://evil.example/api/mcp/auth_callback',
    'https://claude.ai/other',
    'http://claude.ai/api/mcp/auth_callback',
    'http://localhost.evil.example/cb',
    'http://[::1]:5000/cb',
    'http://127.0.0.1:5000/cb#x',
    'myapp://callback',
  ])('refuses %s', async (uri) => {
    const res = await register({ client_name: 'X', redirect_uris: [LOOPBACK, uri] })
    expect(res.status).toBe(400)
    expect(await res.json()).toEqual({
      error: 'invalid_redirect_uri',
      error_description: "Only Claude's redirect URLs can be registered.",
    })
  })

  it('refuses a body that is not a JSON object, and no redirect URL at all', async () => {
    expect((await call('/api/auth/oauth2/register', { method: 'POST', body: 'nope' })).status).toBe(400)
    expect((await register({ client_name: 'X', redirect_uris: [] })).status).toBe(400)
  })

  // Added after review: the app shows the name before Approve, so it is short, visible text. Before, a
  // 5,041-character name with line breaks and a right-to-left override was registered and shown as it was.
  const NAME_REFUSED = {
    error: 'invalid_client_metadata',
    error_description: 'client_name must be at most 64 characters of visible text.',
  }
  it.each([
    ['over 64 characters', 'C'.repeat(65)],
    ['a line break', 'Claude\nType this code: it is from GymRollins'],
    ['a tab', 'Claude\tCode'],
    ['a right-to-left override', 'Claude \u202Eedoc'],
    ['a zero width space', 'Cla\u200Bude'],
    ['a soft hyphen', 'Cla\u00ADude'],
    ['a line separator', 'Claude\u2028Code'],
    ['a Hangul filler', 'Claude\u3164'],
    ['a private use character', 'Claude\uE000'],
    ['only spaces', '   '],
    ['a number', 42],
    ['null', null],
  ])('refuses a client_name with %s', async (_, name) => {
    const clients = () => env.DB.prepare('SELECT count(*) AS n FROM oauthClient').first<{ n: number }>()
    const before = await clients()
    const res = await register({ client_name: name, redirect_uris: [LOOPBACK] })
    expect(res.status).toBe(400)
    expect(await res.json()).toEqual(NAME_REFUSED)
    expect(await clients()).toEqual(before)
  })

  it('takes a name of 64 characters, one in any script, and none at all', async () => {
    for (const client_name of ['C'.repeat(64), 'Claude – 健身房 Спорт 💪', '😀'.repeat(64), undefined]) {
      const res = await register({ client_name, redirect_uris: [LOOPBACK] })
      expect(res.status, client_name).toBe(201)
    }
  })

  // Added after review: registration reads no session, so an app session sent with it owns nothing.
  it('registers a client for no one when an app session comes with it', async () => {
    const { token, cookie } = await signUp()
    const bearer = { authorization: `Bearer ${token}` }
    const sessionCookie = { cookie: `better-auth.session_token=${cookie}` }
    for (const session of [bearer, sessionCookie, { ...bearer, ...sessionCookie }]) {
      const res = await call('/api/auth/oauth2/register', {
        method: 'POST',
        headers: { 'content-type': 'application/json', ...session },
        body: JSON.stringify({
          client_name: 'Claude',
          redirect_uris: [LOOPBACK],
          token_endpoint_auth_method: 'none',
        }),
      })
      expect(res.status, JSON.stringify(session)).toBe(201)
      const { client_id } = await res.json<{ client_id: string }>()
      const row = await env.DB.prepare('SELECT userId FROM oauthClient WHERE clientId = ?1').bind(client_id)
        .first()
      expect(row, JSON.stringify(session)).toEqual({ userId: null })
    }
  })

  it(`takes at most ${REGISTRATIONS_PER_HOUR} registrations an hour unless configured`, async () => {
    const { n } = (await env.DB.prepare('SELECT count(*) AS n FROM oauthClient').first<{ n: number }>())!
    const capped = (cap: number) =>
      app.fetch(
        new Request(`${ORIGIN}/api/auth/oauth2/register`, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ redirect_uris: [LOOPBACK] }),
        }),
        { ...env, OAUTH_REGISTRATIONS_PER_HOUR: String(cap) },
      )
    expect((await capped(n + 1)).status).toBe(201)
    const res = await capped(n + 1)
    expect(res.status).toBe(429)
    expect((await res.json<{ error: string }>()).error).toBe('too_many_requests')
    expect(REGISTRATIONS_PER_HOUR).toBe(30)
  })
})

describe('authorize', () => {
  it('sends a browser without a session to /connect with the signed request', async () => {
    const flow = await startFlow(await registerClient())
    const query = new URLSearchParams(flow.connectUrl.slice('/connect?'.length))
    expect(query.get('client_id')).toBe(flow.clientId)
    expect(query.get('state')).toBe(flow.state)
    expect(query.get('resource')).toBe(RESOURCE)
    expect(query.get('sig')).toBeTruthy()
    expect(Number(query.get('exp')) - Date.now() / 1000).toBeGreaterThan(590)
  })

  it('takes a loopback redirect on another port than the registered one (RFC 8252)', async () => {
    const flow = await startFlow(await registerClient(), 'http://127.0.0.1:40001/callback')
    expect(flow.connectUrl).toMatch(/^\/connect\?/)
  })

  it('refuses an unregistered redirect URL and a request without PKCE', async () => {
    const clientId = await registerClient()
    await expect(startFlow(clientId, CLAUDE_AI)).rejects.toThrow(/did not send the browser to \/connect/)
    const noPkce = new URLSearchParams({
      response_type: 'code',
      client_id: clientId,
      redirect_uri: LOOPBACK,
      state: 's',
    })
    const res = await call(`/api/auth/oauth2/authorize?${noPkce}`, { headers: { accept: 'text/html' } })
    expect(res.headers.get('location')).toMatch(
      /^http:\/\/127\.0\.0\.1:33418\/callback\?error=invalid_request/,
    )
  })

  it.each([
    'GET /api/auth/oauth2/consent',
    'POST /api/auth/oauth2/consent',
    'POST /api/auth/oauth2/continue',
    'GET /api/auth/oauth2/userinfo',
    'POST /api/auth/oauth2/introspect',
    'POST /api/auth/oauth2/create-client',
    'GET /api/auth/oauth2/get-consents',
    'POST /api/auth/oauth2/authorize',
    'POST /api/auth/connect/sign-in',
  ])("keeps Better Auth's unused route %s closed", async (route) => {
    const [method, path] = route.split(' ')
    expect((await call(path!, { method })).status).toBe(404)
  })
})
