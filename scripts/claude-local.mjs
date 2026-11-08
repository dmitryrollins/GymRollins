#!/usr/bin/env node
// Claude's connection against the local Worker (scripts/server-up.sh), plan 29. Local only: it talks to
// API_BASE (default http://127.0.0.1:8787) and to nothing else.
//   node scripts/claude-local.mjs smoke          the whole flow as Claude would run it, step by step
//   node scripts/claude-local.mjs approve CODE   approve a code that /connect shows (Claude Code's sign-in)
//   node scripts/claude-local.mjs deny CODE      deny it
//   node scripts/claude-local.mjs last-use       when Claude last called a tool for the dev account
//   node scripts/claude-local.mjs revoke         Disconnect Claude for the dev account
// The approver is a local dev account (email and password; server/.dev.vars needs ALLOW_PASSWORD_AUTH=1),
// created on first use: GYM_DEV_EMAIL (default claude-dev@test.local), GYM_DEV_PASSWORD.
import { createHash, randomBytes } from 'node:crypto'

const BASE = (process.env.API_BASE ?? 'http://127.0.0.1:8787').replace(/\/+$/, '')
const EMAIL = process.env.GYM_DEV_EMAIL ?? 'claude-dev@test.local'
const PASSWORD = process.env.GYM_DEV_PASSWORD ?? 'correct-horse-battery'
const CALLBACK = 'http://127.0.0.1:53682/callback'

const fail = (message) => {
  console.error(`FAIL ${message}`)
  process.exit(1)
}
const ok = (message) => console.log(`ok   ${message}`)
const base64url = (bytes) => Buffer.from(bytes).toString('base64url')

async function json(res, what) {
  const text = await res.text()
  try {
    return JSON.parse(text)
  } catch {
    return fail(`${what}: ${res.status} ${text.slice(0, 200)}`)
  }
}

/** The dev account's app session: sign in, or sign up the first time. */
async function appSession() {
  const body = JSON.stringify({ email: EMAIL, password: PASSWORD, name: 'Claude dev' })
  // Node's fetch marks requests `sec-fetch-mode: cors`, so Better Auth wants an Origin it trusts: its own.
  const headers = { 'content-type': 'application/json', origin: BASE }
  let res = await fetch(`${BASE}/api/auth/sign-in/email`, { method: 'POST', headers, body })
  if (res.status === 401) {
    res = await fetch(`${BASE}/api/auth/sign-up/email`, { method: 'POST', headers, body })
  }
  const session = await json(res, 'sign-in')
  if (res.status !== 200 || !session.token) fail(`sign-in: ${res.status} ${JSON.stringify(session)}`)
  return session.token
}

function app(token, method, path, body) {
  return fetch(`${BASE}${path}`, {
    method,
    headers: { authorization: `Bearer ${token}`, ...(body ? { 'content-type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  })
}

/**
 * Where a response sends the browser. Better Auth answers a request that Node's fetch marks `sec-fetch-mode:
 * cors` with `{"redirect": true, "url"}` instead of a 302 (a browser's navigation gets the 302).
 */
async function location(res) {
  if (res.status === 302) return new URL(res.headers.get('location'), BASE)
  const body = (res.headers.get('content-type') ?? '').includes('json') ? await res.json() : null
  return body?.redirect === true ? new URL(body.url, BASE) : null
}

/** A browser that keeps cookies and never follows redirects. */
class Browser {
  cookies = new Map()

  async get(path) {
    const cookie = [...this.cookies].map(([k, v]) => `${k}=${v}`).join('; ')
    const url = path.startsWith('http') ? path : `${BASE}${path}`
    const res = await fetch(url, {
      redirect: 'manual',
      headers: { accept: 'text/html', ...(cookie ? { cookie } : {}) },
    })
    for (const set of res.headers.getSetCookie()) {
      const [pair, ...attributes] = set.split(';')
      const name = pair.slice(0, pair.indexOf('='))
      const value = pair.slice(pair.indexOf('=') + 1)
      if (value === '' || attributes.some((a) => a.trim().toLowerCase() === 'max-age=0')) {
        this.cookies.delete(name)
      } else this.cookies.set(name, value)
    }
    return res
  }
}

function mcp(token, method, params, id = 1) {
  return fetch(`${BASE}/mcp`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      accept: 'application/json, text/event-stream',
      'mcp-protocol-version': '2025-06-18',
    },
    body: JSON.stringify({ jsonrpc: '2.0', id, method, ...(params ? { params } : {}) }),
  })
}

/** The JSON-RPC answer in a JSON or an SSE body. */
async function rpc(res) {
  const text = await res.text()
  if (!(res.headers.get('content-type') ?? '').includes('text/event-stream')) return JSON.parse(text)
  const data = text.split('\n').filter((l) => l.startsWith('data:')).map((l) => JSON.parse(l.slice(5)))
  return data.at(-1)
}

function tokenRequest(params) {
  return fetch(`${BASE}/api/auth/oauth2/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(params),
  })
}

async function smoke() {
  const prm = await json(await fetch(`${BASE}/.well-known/oauth-protected-resource/mcp`), 'resource metadata')
  if (prm.resource !== `${BASE}/mcp`) fail(`resource metadata names ${prm.resource}`)
  const unauthorized = await fetch(`${BASE}/mcp`, { method: 'POST' })
  if (
    unauthorized.status !== 401 ||
    !unauthorized.headers.get('www-authenticate')?.includes('resource_metadata')
  ) {
    fail(`/mcp without a token answered ${unauthorized.status}`)
  }
  ok('discovery: 401 on /mcp points at the resource metadata')

  const registration = await fetch(`${BASE}/api/auth/oauth2/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      client_name: 'claude-local smoke',
      redirect_uris: [CALLBACK],
      token_endpoint_auth_method: 'none',
    }),
  })
  const client = await json(registration, 'registration')
  if (registration.status !== 201) fail(`registration: ${registration.status} ${JSON.stringify(client)}`)
  ok(`registered client ${client.client_id}`)

  const verifier = base64url(randomBytes(32))
  const challenge = base64url(createHash('sha256').update(verifier).digest())
  const state = base64url(randomBytes(12))
  const query = new URLSearchParams({
    response_type: 'code',
    client_id: client.client_id,
    redirect_uri: CALLBACK,
    state,
    code_challenge: challenge,
    code_challenge_method: 'S256',
    scope: 'mcp',
    resource: `${BASE}/mcp`,
  })
  const browser = new Browser()
  const authorize = await browser.get(`/api/auth/oauth2/authorize?${query}`)
  const signIn = await location(authorize)
  if (signIn?.pathname !== '/connect') {
    fail(`authorize did not send the browser to /connect: ${authorize.status}`)
  }
  const connectUrl = `${signIn.pathname}${signIn.search}`
  const page = await browser.get(connectUrl)
  const csp = page.headers.get('content-security-policy') ?? ''
  const code = /class="code">([0-9A-Z]{4}-[0-9A-Z]{4})</.exec(await page.text())?.[1]
  if (!code || !csp.startsWith("default-src 'none'")) fail(`/connect showed no code (${page.status})`)
  ok(`/connect shows ${code} under a strict CSP`)

  const session = await appSession()
  const decided = await app(session, 'POST', `/v1/claude/connect/${code}`, { decision: 'approve' })
  if (decided.status !== 200) fail(`approve: ${decided.status} ${await decided.text()}`)
  ok(`approved ${code} as ${EMAIL}`)

  const approved = await browser.get(connectUrl)
  const refresh = /http-equiv="refresh" content="0;url=([^"]+)"/.exec(await approved.text())?.[1]
  if (!refresh) fail('/connect did not continue after the approval')
  const back = await browser.get(refresh.replace(/&amp;/g, '&'))
  const callback = await location(back)
  if (
    `${callback?.origin}${callback?.pathname}` !== CALLBACK || callback.searchParams.get('state') !== state
  ) {
    fail(`authorize did not return to the callback: ${back.status} ${callback}`)
  }
  ok('the browser went back to the callback with a code')

  const exchanged = await tokenRequest({
    grant_type: 'authorization_code',
    code: callback.searchParams.get('code'),
    redirect_uri: CALLBACK,
    client_id: client.client_id,
    code_verifier: verifier,
    resource: `${BASE}/mcp`,
  })
  const tokens = await json(exchanged, 'token')
  if (exchanged.status !== 200 || !tokens.refresh_token) {
    fail(`token: ${exchanged.status} ${JSON.stringify(tokens)}`)
  }
  ok(`tokens: scope "${tokens.scope}", access token valid ${tokens.expires_in} s`)

  const init = await rpc(
    await mcp(tokens.access_token, 'initialize', {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: { name: 'claude-local', version: '0' },
    }),
  )
  const tools = (await rpc(await mcp(tokens.access_token, 'tools/list', undefined, 2))).result?.tools ?? []
  if (init.result?.serverInfo?.name !== 'gymrollins' || tools.length !== 15) {
    fail(`MCP: ${tools.length} tools`)
  }
  const profile = await rpc(
    await mcp(tokens.access_token, 'tools/call', { name: 'get_profile', arguments: {} }, 3),
  )
  if (profile.result?.isError) fail(`get_profile: ${JSON.stringify(profile.result)}`)
  ok('MCP: initialize, 15 tools, get_profile')

  const lastUse = await json(await app(session, 'GET', '/v1/claude/last-use'), 'last-use')
  if (!lastUse.at) fail('last-use is empty after a tool call')
  ok(`last use ${lastUse.at}`)

  const refreshed = await tokenRequest({
    grant_type: 'refresh_token',
    refresh_token: tokens.refresh_token,
    client_id: client.client_id,
    resource: `${BASE}/mcp`,
  })
  const rotated = await json(refreshed, 'refresh')
  if (refreshed.status !== 200 || rotated.refresh_token === tokens.refresh_token) {
    fail('refresh did not rotate')
  }
  ok('refresh rotated the tokens')

  const revoked = await json(await app(session, 'POST', '/v1/claude/revoke'), 'revoke')
  const after = await mcp(rotated.access_token, 'tools/list')
  if (after.status !== 401) fail(`after Disconnect Claude /mcp answered ${after.status}`)
  ok(`Disconnect Claude removed ${revoked.revoked} connection(s); the next call got 401`)
}

async function decideCode(code, decision) {
  if (!code) fail('usage: node scripts/claude-local.mjs approve|deny CODE')
  const res = await app(await appSession(), 'POST', `/v1/claude/connect/${encodeURIComponent(code)}`, {
    decision,
  })
  const body = await json(res, decision)
  if (res.status !== 200) fail(`${decision}: ${res.status} ${JSON.stringify(body)}`)
  ok(`${body.status} ${code} as ${EMAIL}`)
}

const [command, argument] = process.argv.slice(2)
if (command === 'smoke') await smoke()
else if (command === 'approve' || command === 'deny') await decideCode(argument, command)
else if (command === 'last-use') {
  console.log(await json(await app(await appSession(), 'GET', '/v1/claude/last-use')))
} else if (command === 'revoke') {
  console.log(await json(await app(await appSession(), 'POST', '/v1/claude/revoke')))
} else fail('usage: node scripts/claude-local.mjs smoke | approve CODE | deny CODE | last-use | revoke')
