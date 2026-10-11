// Tests for scripts/consent-server.mjs: routing, CSP/security headers, directory-traversal protection, and that
// config injection never includes secrets. Run: node --test web/consent/server.test.mjs (no Docker/Supabase
// needed — the server under test is given a fixture config, not the real supabase/.env.local).

import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  createServer,
  configScript,
  loadGymConfig,
  parseEnvFile,
  resolveStaticPath,
  contentSecurityPolicy,
  CONSENT_ROOT,
} from '../../scripts/consent-server.mjs'

const FIXTURE_CONFIG = { apiUrl: 'http://127.0.0.1:55421', anonKey: 'fixture-anon-key' }

async function withServer(config, fn) {
  const server = createServer({ root: CONSENT_ROOT, config })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  const { port } = server.address()
  const base = `http://127.0.0.1:${port}`
  try {
    await fn(base)
  } finally {
    await new Promise((resolve) => server.close(resolve))
  }
}

test('GET /oauth/consent serves index.html with a strict CSP and no inline script', async () => {
  await withServer(FIXTURE_CONFIG, async (base) => {
    const res = await fetch(`${base}/oauth/consent?authorization_id=abc`)
    assert.equal(res.status, 200)
    assert.match(res.headers.get('content-type'), /text\/html/)
    assert.equal(res.headers.get('x-content-type-options'), 'nosniff')
    assert.equal(res.headers.get('x-frame-options'), 'DENY')
    const csp = res.headers.get('content-security-policy')
    assert.match(csp, /default-src 'self'/)
    assert.match(csp, /script-src 'self' https:\/\/esm\.sh(;|$)/)
    assert.doesNotMatch(csp, /unsafe-inline|unsafe-eval/)
    assert.match(csp, new RegExp(`connect-src ${FIXTURE_CONFIG.apiUrl.replace(/[.:]/g, '\\$&')}`))

    const body = await res.text()
    assert.doesNotMatch(body, /<script>/, 'no inline scripts: the CSP would block them')
    assert.doesNotMatch(body, /fixture-anon-key/, 'config comes from /config.js, not the HTML')
  })
})

test('the page references its assets root-relative, so they resolve from /oauth/consent', async () => {
  await withServer(FIXTURE_CONFIG, async (base) => {
    const body = await (await fetch(`${base}/oauth/consent`)).text()
    const refs = [...body.matchAll(/(?:src|href)="([^"]+)"/g)].map((m) => m[1])
    assert.deepEqual(refs.sort(), ['/config.js', '/consent.js', '/style.css'])
    for (const ref of refs) {
      const res = await fetch(new URL(ref, `${base}/oauth/consent?authorization_id=abc`))
      assert.equal(res.status, 200, ref)
    }
  })
})

test('GET /config.js serves the config (url + anon key only) as a no-store script', async () => {
  await withServer(FIXTURE_CONFIG, async (base) => {
    const res = await fetch(`${base}/config.js`)
    assert.equal(res.status, 200)
    assert.match(res.headers.get('content-type'), /javascript/)
    assert.equal(res.headers.get('cache-control'), 'no-store')
    const body = await res.text()
    assert.equal(
      body,
      'window.GYM_CONFIG = {"url":"http://127.0.0.1:55421","anonKey":"fixture-anon-key"};\n',
    )
  })
})

test('GET / also serves index.html', async () => {
  await withServer(FIXTURE_CONFIG, async (base) => {
    const res = await fetch(`${base}/`)
    assert.equal(res.status, 200)
    const body = await res.text()
    assert.match(body, /\/config\.js/)
  })
})

test('the consent markup shows the full redirect URI and the first-time warning', async () => {
  await withServer(FIXTURE_CONFIG, async (base) => {
    const body = await (await fetch(`${base}/oauth/consent`)).text()
    assert.match(body, /<code id="redirect-uri"/)
    assert.match(body, /First time connecting this app — only approve if you just added GymRollins in Claude\./)
  })
})

test('GET /style.css and /consent.js serve with correct content types', async () => {
  await withServer(FIXTURE_CONFIG, async (base) => {
    const css = await fetch(`${base}/style.css`)
    assert.equal(css.status, 200)
    assert.match(css.headers.get('content-type'), /text\/css/)

    const js = await fetch(`${base}/consent.js`)
    assert.equal(js.status, 200)
    assert.match(js.headers.get('content-type'), /javascript/)
    const jsBody = await js.text()
    assert.match(jsBody, /esm\.sh\/@supabase\/supabase-js@2\.117\.2/)
  })
})

test('unknown path returns 404, not a directory listing', async () => {
  await withServer(FIXTURE_CONFIG, async (base) => {
    const res = await fetch(`${base}/does-not-exist.html`)
    assert.equal(res.status, 404)
  })
})

test('non-GET/HEAD methods are rejected', async () => {
  await withServer(FIXTURE_CONFIG, async (base) => {
    const res = await fetch(`${base}/oauth/consent`, { method: 'POST' })
    assert.equal(res.status, 405)
    assert.equal(res.headers.get('allow'), 'GET, HEAD')
  })
})

test('directory traversal is blocked (encoded and literal ../)', async () => {
  await withServer(FIXTURE_CONFIG, async (base) => {
    const attempts = [
      '/../../../../etc/passwd',
      '/%2e%2e/%2e%2e/%2e%2e/etc/passwd',
      '/..%2f..%2f..%2fetc%2fpasswd',
      '/consent.js/../../../etc/passwd',
    ]
    for (const attempt of attempts) {
      const res = await fetch(`${base}${attempt}`)
      assert.notEqual(res.status, 200, `expected traversal attempt to be blocked: ${attempt}`)
      if (res.status === 200) {
        const body = await res.text()
        assert.doesNotMatch(body, /root:.*:0:0:/, `leaked /etc/passwd via ${attempt}`)
      }
    }
  })
})

test('resolveStaticPath rejects paths that escape the root directly', async () => {
  const resolved = await resolveStaticPath(CONSENT_ROOT, '/../server.test.mjs')
  assert.equal(resolved, null)
})

test('resolveStaticPath resolves a legitimate file inside the root', async () => {
  const resolved = await resolveStaticPath(CONSENT_ROOT, '/style.css')
  assert.ok(resolved && resolved.endsWith('style.css'))
})

test('configScript embeds only url and anonKey as JSON', () => {
  const out = configScript({ apiUrl: 'http://x', anonKey: 'a";alert(1);"', extra: 'nope' })
  assert.equal(out, 'window.GYM_CONFIG = {"url":"http://x","anonKey":"a\\";alert(1);\\""};\n')
})

test('configScript refuses a service-role or other secret key', () => {
  for (const key of ['SERVICE_ROLE_KEY', 'SECRET_KEY', 'JWT_SECRET', 'DB_URL']) {
    assert.throws(() => configScript({ apiUrl: 'http://x', anonKey: 'a', [key]: 'leak' }))
  }
})

test('served consent page never contains the real service-role key when config only carries url/anonKey', async () => {
  // Mirrors what the real server does: config passed to createServer() is whatever loadGymConfig() returns,
  // which only has apiUrl/anonKey. Assert the served body can't contain a service-role-shaped secret.
  await withServer(FIXTURE_CONFIG, async (base) => {
    const res = await fetch(`${base}/config.js`)
    const body = await res.text()
    assert.doesNotMatch(body, /SERVICE_ROLE_KEY/)
    assert.doesNotMatch(body, /SECRET_KEY/)
    assert.doesNotMatch(body, /service_role/)
  })
})

test('parseEnvFile strips quotes and ignores comments/blank lines', () => {
  const parsed = parseEnvFile('# comment\n\nAPI_URL="http://127.0.0.1:55421"\nANON_KEY=unquoted-value\n')
  assert.deepEqual(parsed, { API_URL: 'http://127.0.0.1:55421', ANON_KEY: 'unquoted-value' })
})

test('loadGymConfig throws a clear error when the env file is missing', () => {
  assert.throws(() => loadGymConfig('/nonexistent/path/.env.local'), /not found/)
})

test('contentSecurityPolicy scopes connect-src to exactly the given API URL', () => {
  const csp = contentSecurityPolicy('http://127.0.0.1:55421')
  assert.match(csp, /connect-src http:\/\/127\.0\.0\.1:55421;/)
})
