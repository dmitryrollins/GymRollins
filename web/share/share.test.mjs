// The landing page a workout link opens when the app doesn't take it. Run: node --test web/share/share.test.mjs
// It must never send anything: the workout sits after the #, which browsers keep from the host.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { appLink, appStoreLink } from './w/open.mjs'

const read = (path) => readFileSync(new URL(path, import.meta.url), 'utf8')

test('hands a workout to the app', () => {
  assert.equal(appLink('#1.0025_3_8-10.1512_3_10_g1'), 'gymrollins://w#1.0025_3_8-10.1512_3_10_g1')
})

for (const hash of ['', '#', '#javascript:alert(1)', '#1.0025 3', '#a/b', '#a?b', '#a&b', '#%41', `#${'1'.repeat(1025)}`]) {
  test(`offers no link for ${JSON.stringify(hash.slice(0, 24))}`, () => {
    assert.equal(appLink(hash), null)
  })
}

test('the App Store button stays hidden until there is an address', () => {
  assert.equal(appStoreLink(''), null)
  assert.equal(appStoreLink('http://apps.apple.com/app/id1'), null)
  assert.equal(appStoreLink('https://apps.apple.com/app/id1'), 'https://apps.apple.com/app/id1')
})

test('the page blocks every request but its own files', () => {
  const html = read('./w/index.html')
  const policy = /http-equiv="Content-Security-Policy" content="([^"]+)"/.exec(html)?.[1]
  assert.ok(policy, 'no content security policy')
  for (const part of ["default-src 'none'", "connect-src 'none'", "script-src 'self'", "style-src 'self'",
    "base-uri 'none'", "form-action 'none'"]) {
    assert.ok(policy.includes(part), `missing ${part}`)
  }
  assert.ok(!/<script(?![^>]*\bsrc=)/.test(html), 'inline script')
  assert.ok(!/https?:\/\//.test(html), 'an outside address in the page')
})

test('the script makes no requests', () => {
  const script = read('./w/open.mjs')
  for (const banned of ['fetch(', 'XMLHttpRequest', 'sendBeacon', 'WebSocket', 'localStorage', 'document.cookie', 'import(']) {
    assert.ok(!script.includes(banned), banned)
  }
})

test("Apple's domain file covers only the link's path and this app", () => {
  const file = JSON.parse(read('./apple-app-site-association.template'))
  const [details] = file.applinks.details
  assert.deepEqual(details.appIDs, ['TEAM_ID.com.rollins.gymrollins'])
  assert.deepEqual(details.components.map((c) => c['/']), ['/w', '/w/'])
})
