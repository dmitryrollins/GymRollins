import { test } from 'node:test'
import assert from 'node:assert/strict'
import { normalize } from './fitbod-alias-report.mjs'
import { APPS, analyze, buildReport, loadAliases, loadLibrary } from './other-apps-alias-report.mjs'

const lib = loadLibrary()

for (const app of APPS) {
  const aliases = loadAliases(app)

  test(`${app.title}: every curated id exists in the library`, () => {
    const { unknownIds } = analyze(app, aliases, lib)
    assert.deepEqual(unknownIds, [])
  })

  test(`${app.title}: no two keys collide after normalization`, () => {
    const seen = new Map()
    for (const key of Object.keys(aliases)) {
      const n = normalize(key)
      assert.ok(!seen.has(n), `"${key}" collides with "${seen.get(n)}"`)
      seen.set(n, key)
    }
  })

  test(`${app.title}: every non-trivial decision has a reason`, () => {
    const { missingReasons } = analyze(app, aliases, lib)
    assert.deepEqual(missingReasons, [])
  })

  test(`${app.title}: test-fixture names stay unmatched`, () => {
    assert.ok(!('Zorblax Carry (Dumbbell)' in aliases))
    assert.ok(!('Zorblax Carry' in aliases))
  })
}

test('report contains a section per app', () => {
  const md = buildReport()
  for (const app of APPS) assert.match(md, new RegExp(`^## ${app.title}$`, 'm'))
  assert.doesNotMatch(md, /unknown id!/)
})
