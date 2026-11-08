// Claude's OAuth up to the sign-in page: discovery, registration, and the authorize step sending the browser
// to /connect (spec section 4, "Claude's connection", steps 1–3).
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { REGISTRATIONS_PER_HOUR } from '../src/auth/routes.ts'
import app from '../src/index.ts'
import { call, CLAUDE_AI, LOOPBACK, register, registerClient, RESOURCE, startFlow } from './claude.ts'
import { ORIGIN } from './helpers.ts'

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
