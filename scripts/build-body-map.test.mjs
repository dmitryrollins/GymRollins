// Unit tests for the body-map extractor: node --test scripts/build-body-map.test.mjs
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { test } from 'node:test'
import {
  approxArea, arcToCubics, BODY_HIGHLIGHTER_SHA, bounds, buildBodyMap, NEUTRAL, normalizePath, parseBodyParts,
  parseOutlines, partNames, regionsOf, serialize, tokenize, viewBoxes,
} from './build-body-map.mjs'

const square = (x, y, s) => `M${x} ${y}h${s}v${s}h${-s}z`
const part = (slug, left = [], right = [], common = []) => {
  const list = (k, v) => (v.length ? `${k}: [${v.map((p) => `"${p}"`).join(', ')}],` : '')
  return `  {\n    slug: "${slug}",\n    color: "#3f3f3f",\n    path: {\n      ${list('left', left)}\n      ${list('right', right)}\n      ${list('common', common)}\n    },\n  },\n`
}
const assetFile = (...parts) => `import { BodyPart } from "..";\n\nexport const bodyFront: BodyPart[] = [\n${parts.join('')}];\n`
const wrapper = (front, back) =>
  `{side === "front" && (<Path stroke={border} d="${front}" />)}\n{side === "back" && (<Path d="${back}" />)}`

test('parseBodyParts reads slug and the left/right/common path lists', () => {
  const parts = parseBodyParts(assetFile(part('chest', ['M1 1L2 2Z'], ['M3 3L4 4Z']), part('head', [], [], ['M5 5L6 6Z'])))
  assert.deepEqual(parts, [
    { slug: 'chest', left: ['M1 1L2 2Z'], right: ['M3 3L4 4Z'], common: [] },
    { slug: 'head', left: [], right: [], common: ['M5 5L6 6Z'] },
  ])
})

test('tokenize splits compact numbers and packed arc flags', () => {
  assert.deepEqual(tokenize('M10-2.5.5a1 1 0 01 3 4'), [
    { letter: 'M', args: [10, -2.5, 0.5] },
    { letter: 'a', args: [1, 1, 0, 0, 1, 3, 4] },
  ])
  assert.throws(() => tokenize('M1 1 X 2 2'), /unsupported path data/)
})

test('normalizePath makes every command absolute M/L/C/Z', () => {
  const cmds = normalizePath('m1 1 2 0h3v2H1V1zM0 0q5 10 10 0t10 0s5 5 10 0')
  assert.ok(cmds.every(([c]) => 'MLCZ'.includes(c)))
  assert.deepEqual(cmds.slice(0, 5), [['M', 1, 1], ['L', 3, 1], ['L', 6, 1], ['L', 6, 3], ['L', 1, 3]])
  const end = cmds.at(-1)
  assert.deepEqual(end.slice(-2), [30, 0])
  assert.throws(() => normalizePath('M1'), /1 numbers/)
})

test('arcToCubics: a half circle ends exactly at the target and bulges by the radius', () => {
  const cubics = arcToCubics(0, 0, 5, 5, 0, 0, 1, 10, 0)
  assert.equal(cubics.length, 2)
  assert.deepEqual(cubics.at(-1).slice(-2), [10, 0])
  const mid = cubics[0].slice(-2)
  assert.ok(Math.abs(mid[0] - 5) < 1e-9 && Math.abs(Math.abs(mid[1]) - 5) < 1e-9)
  assert.deepEqual(arcToCubics(1, 1, 5, 5, 0, 0, 1, 1, 1), []) // zero-length arc is dropped
})

test('serialize rounds to 2 decimals; bounds and approxArea measure a square', () => {
  const cmds = normalizePath(square(0, 0, 10))
  assert.equal(serialize([['M', 1.234, 5], ['Z']]), 'M1.23 5Z')
  assert.deepEqual(bounds(cmds), { minX: 0, minY: 0, maxX: 10, maxY: 10 })
  assert.equal(approxArea(cmds), 100)
})

test('partNames splits upper-back (largest = lats) and gluteal (smaller = gluteus-medius)', () => {
  const small = square(0, 0, 2), big = square(0, 0, 20)
  assert.deepEqual(partNames('upper-back', [small, big, small]), ['upper-back', 'lats', 'upper-back'])
  assert.deepEqual(partNames('gluteal', [small, big]), ['gluteus-medius', 'gluteal'])
  assert.deepEqual(partNames('chest', [small, big]), ['chest', 'chest'])
})

test('regionsOf merges pieces per part and side and names common parts without a side', () => {
  const regions = regionsOf(parseBodyParts(assetFile(
    part('abs', [square(0, 0, 1), square(2, 0, 1)], [square(5, 0, 1)]),
    part('head', [], [], [square(9, 9, 1)]),
  )), 'front')
  assert.deepEqual(regions.map((r) => r.id), ['abs-left', 'abs-right', 'head'])
  assert.equal(regions[0].path.match(/M/g).length, 2)
  assert.throws(() => regionsOf([], 'back'), /no back regions/)
})

test('buildBodyMap: pinned source, outlines sorted by side, equal-size padded view boxes', () => {
  const map = buildBodyMap(assetFile(part('chest', [square(10, 10, 5)])), assetFile(part('lats', [square(810, 10, 5)])),
    wrapper(square(800, 0, 100), square(0, 0, 50)))
  assert.equal(map.commit, BODY_HIGHLIGHTER_SHA)
  assert.equal(map.license, 'MIT')
  assert.ok(map.outlines.front.startsWith('M0 0'))
  assert.ok(map.outlines.back.startsWith('M800 0'))
  assert.deepEqual(map.viewBoxes.front.slice(2), [124, 124])
  assert.deepEqual(viewBoxes({ front: [square(0, 0, 50), square(0, -30, 5)], back: [square(0, 0, 50)] }).front,
    [-12, -42, 74, 104]) // a region above the outline (the head) widens the box

  assert.deepEqual(map.regions.map((r) => [r.id, r.view]), [['chest-left', 'front'], ['lats-left', 'back']])
  assert.throws(() => parseOutlines('d="M0 0z"'), /expected 2 outline paths/)
})

test('the bundled body-map.json is what the pinned source produces (regenerate with the script)', () => {
  const json = JSON.parse(readFileSync(resolve(import.meta.dirname, '../ios/GymRollins/Resources/body-map.json'), 'utf8'))
  assert.equal(json.commit, BODY_HIGHLIGHTER_SHA)
  assert.equal(json.regions.length, 71)
  assert.equal(json.regions.filter((r) => r.view === 'front').length, 37)
  for (const r of [...json.regions, { path: json.outlines.front }, { path: json.outlines.back }]) {
    assert.match(r.path, /^M[-\d. MLCZ]+$/)
  }
  const bases = new Set(json.regions.map((r) => r.id.replace(/-(left|right)$/, '')))
  for (const n of NEUTRAL) assert.ok(bases.has(n), `neutral part ${n} missing`)
  for (const split of ['lats', 'upper-back', 'gluteal', 'gluteus-medius']) assert.ok(bases.has(split), split)
})
