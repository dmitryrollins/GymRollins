// Browser end-to-end test of the OAuth consent page in headless Chromium (Playwright), against the LOCAL Supabase
// stack and the consent server (scripts/consent-server.mjs on 127.0.0.1:55430). Run by scripts/test-mcp.sh, which
// starts both; skipped (not failed) when either is not reachable or playwright is not installed
// (`cd web/consent && npm ci && npx playwright install chromium`).
//
// Flow, as Claude + a person would do it: register an OAuth client (DCR) → GET /auth/v1/oauth/authorize follows
// to the consent page Auth's site_url points at → the browser signs in → client name, full redirect URI and the
// first-time warning render → Approve → the browser lands on the client's redirect with `code` → the code is
// exchanged with the PKCE verifier. Test users are created/deleted with the service-role key from
// supabase/.env.local (test setup only; the page itself only ever gets the anon key).

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createHash, randomBytes, randomUUID } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseEnvFile } from '../../scripts/consent-server.mjs'

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const ENV_FILE = path.join(ROOT, 'supabase', '.env.local')
const CONSENT_ORIGIN = 'http://127.0.0.1:55430'
const REDIRECT_URI = 'http://127.0.0.1:8976/cb'
const CLIENT_NAME = 'Claude (consent e2e)'

async function reachable(url) {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(3000) })
    await res.body?.cancel()
    return res.status < 500
  } catch {
    return false
  }
}

async function loadPlaywright() {
  try {
    return await import('playwright')
  } catch {
    return null
  }
}

async function prerequisites() {
  if (!existsSync(ENV_FILE)) return { skip: 'supabase/.env.local missing (run scripts/supabase-up.sh)' }
  const env = parseEnvFile(readFileSync(ENV_FILE, 'utf8'))
  if (!(await reachable(`${env.API_URL}/auth/v1/health`))) return { skip: 'local Supabase is not running' }
  if (!(await reachable(`${CONSENT_ORIGIN}/oauth/consent`))) return { skip: 'consent server is not running' }
  const playwright = await loadPlaywright()
  if (!playwright) return { skip: 'playwright not installed (cd web/consent && npm ci)' }
  return { env, playwright }
}

const b64url = (buf) => buf.toString('base64url')

async function json(res, what) {
  const text = await res.text()
  if (!res.ok) throw new Error(`${what}: HTTP ${res.status} ${text}`)
  return text ? JSON.parse(text) : null
}

async function createUser(env) {
  const email = `consent-e2e-${randomUUID()}@example.test`
  const password = `pw-${randomUUID()}`
  const user = await json(
    await fetch(`${env.API_URL}/auth/v1/admin/users`, {
      method: 'POST',
      headers: {
        apikey: env.SERVICE_ROLE_KEY,
        authorization: `Bearer ${env.SERVICE_ROLE_KEY}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ email, password, email_confirm: true }),
    }),
    'create user',
  )
  return { id: user.id, email, password }
}

async function deleteUser(env, id) {
  await fetch(`${env.API_URL}/auth/v1/admin/users/${id}`, {
    method: 'DELETE',
    headers: { apikey: env.SERVICE_ROLE_KEY, authorization: `Bearer ${env.SERVICE_ROLE_KEY}` },
  })
}

/** DCR + authorize; returns the consent URL Auth redirects to, plus what the token exchange needs. */
async function startAuthorization(env) {
  const client = await json(
    await fetch(`${env.API_URL}/auth/v1/oauth/clients/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        client_name: CLIENT_NAME,
        redirect_uris: [REDIRECT_URI],
        grant_types: ['authorization_code', 'refresh_token'],
        response_types: ['code'],
        token_endpoint_auth_method: 'none',
      }),
    }),
    'client registration',
  )
  const verifier = b64url(randomBytes(48))
  const challenge = b64url(createHash('sha256').update(verifier).digest())
  const state = randomUUID()
  const url = new URL(`${env.API_URL}/auth/v1/oauth/authorize`)
  url.search = new URLSearchParams({
    response_type: 'code',
    client_id: client.client_id,
    redirect_uri: REDIRECT_URI,
    code_challenge: challenge,
    code_challenge_method: 'S256',
    scope: 'email profile',
    state,
    resource: `${env.API_URL}/functions/v1/mcp`,
  }).toString()
  const res = await fetch(url, { redirect: 'manual' })
  await res.body?.cancel()
  const consentUrl = res.headers.get('location')
  assert.ok(res.status >= 300 && res.status < 400 && consentUrl, `authorize should redirect (${res.status})`)
  return { clientId: client.client_id, verifier, state, consentUrl }
}

test('consent page in a real browser: sign in → details → Approve → redirect with a usable code', async (t) => {
  const pre = await prerequisites()
  if (pre.skip) {
    t.skip(pre.skip)
    return
  }
  const { env, playwright } = pre
  const user = await createUser(env)
  const browser = await playwright.chromium.launch()
  try {
    const flow = await startAuthorization(env)
    // Auth's site_url is the consent server: the redirect is used as-is, no rewriting.
    assert.match(flow.consentUrl, /^http:\/\/127\.0\.0\.1:55430\/oauth\/consent\?authorization_id=[\w-]+$/)

    const page = await browser.newPage()
    const problems = []
    page.on('console', (msg) => msg.type() === 'error' && problems.push(msg.text()))
    page.on('pageerror', (err) => problems.push(err.message))
    page.on('response', (res) => res.status() >= 400 && problems.push(`${res.status()} ${res.url()}`))
    // Nothing listens on the client's redirect URI: answer it in the browser and capture where it went.
    let landed = null
    await page.route(`${REDIRECT_URI}**`, (route) => {
      landed = route.request().url()
      return route.fulfill({ status: 200, contentType: 'text/plain', body: 'callback received' })
    })

    await page.goto(flow.consentUrl)
    await page.locator('#sign-in').waitFor({ state: 'visible', timeout: 20_000 })
    await page.fill('#email', user.email)
    await page.fill('#password', user.password)
    await page.click('#sign-in button[type="submit"]')

    await page.locator('#consent').waitFor({ state: 'visible', timeout: 20_000 })
    assert.equal(await page.textContent('#client-name'), CLIENT_NAME)
    assert.equal(await page.textContent('#redirect-uri'), REDIRECT_URI)
    assert.equal(await page.textContent('#signed-in-email'), user.email)
    assert.ok(await page.getByText('First time connecting this app').isVisible())

    await Promise.all([page.waitForURL(`${REDIRECT_URI}**`, { timeout: 20_000 }), page.click('#approve')])
    assert.ok(landed, 'the browser navigated to the redirect URI')
    const params = new URL(landed).searchParams
    assert.equal(params.get('state'), flow.state)
    const code = params.get('code')
    assert.ok(code, `redirect carries a code: ${landed}`)
    assert.deepEqual(problems, [], 'no console errors, CSP violations or failed requests')

    const tokens = await json(
      await fetch(`${env.API_URL}/auth/v1/oauth/token`, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          grant_type: 'authorization_code',
          code,
          redirect_uri: REDIRECT_URI,
          client_id: flow.clientId,
          code_verifier: flow.verifier,
        }),
      }),
      'token exchange',
    )
    const claims = JSON.parse(Buffer.from(tokens.access_token.split('.')[1], 'base64url').toString())
    assert.equal(claims.sub, user.id)
    assert.equal(claims.client_id, flow.clientId)
  } finally {
    await browser.close()
    await deleteUser(env, user.id)
  }
})
