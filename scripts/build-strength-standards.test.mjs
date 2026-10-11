// Unit tests for the strength-standards builder: node --test scripts/build-strength-standards.test.mjs
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  ageGroupOf,
  binOf,
  buildCurves,
  buildStandards,
  coalesce,
  CONFIG,
  indexHeader,
  isotonic,
  keepBest,
  OUT_APP,
  OUT_SERVER,
  percentile,
  readCsv,
  resolveAge,
  rowResults,
  smooth3,
} from './build-strength-standards.mjs'

const HEADER = 'Name,Sex,Event,Equipment,Age,AgeClass,BirthYearClass,Division,BodyweightKg,WeightClassKg,' +
  'Squat1Kg,Squat2Kg,Squat3Kg,Squat4Kg,Best3SquatKg,Bench1Kg,Bench2Kg,Bench3Kg,Bench4Kg,Best3BenchKg,' +
  'Deadlift1Kg,Deadlift2Kg,Deadlift3Kg,Deadlift4Kg,Best3DeadliftKg,TotalKg,Place,Dots,Wilks,Glossbrenner,' +
  'Goodlift,Tested,Country,State,Federation,ParentFederation,Date,MeetCountry,MeetState,MeetTown,MeetName,Sanctioned'
const IDX = indexHeader(HEADER)

/** One CSV line with sensible defaults (a raw 30-year-old man at 82 kg, full power, placed 1st in 2024). */
function row(o = {}) {
  const v = { Name: 'A B', Sex: 'M', Event: 'SBD', Equipment: 'Raw', Age: '30', AgeClass: '', BirthYearClass: '',
    BodyweightKg: '82', Best3SquatKg: '180', Best3BenchKg: '120', Best3DeadliftKg: '220', Place: '1', Tested: '',
    Date: '2024-05-01', ...o }
  return HEADER.split(',').map((c) => v[c] ?? '').join(',')
}

test('the synthetic header matches the real CSV header shape', () => {
  assert.equal(IDX.Name, 0)
  assert.equal(IDX.Best3DeadliftKg, 24)
  assert.throws(() => indexHeader('Name,Sex'), /missing Event/)
})

test('rowResults keeps a raw, placed, dated, aged row: one result per lift in the event', () => {
  const out = rowResults(row(), IDX)
  assert.deepEqual(out.map((r) => [r.lift, r.kg, r.bw, r.age]), [
    ['squat', 180, 82, 30], ['bench', 120, 82, 30], ['deadlift', 220, 82, 30],
  ])
  assert.equal(out[0].key, 'M|A B|squat')
  // A bench-only meet contributes only the bench; a failed lift (negative / empty best) is skipped.
  assert.deepEqual(rowResults(row({ Event: 'B' }), IDX).map((r) => r.lift), ['bench'])
  assert.deepEqual(rowResults(row({ Best3SquatKg: '-200' }), IDX).map((r) => r.lift), ['bench', 'deadlift'])
})

test('rowResults filters equipment, DQ/no-show/guest, sex, old meets, bodyweight and age, and counts why', () => {
  const counts = {}
  const dropped = [
    row({ Equipment: 'Wraps' }), row({ Equipment: 'Single-ply' }), row({ Place: 'DQ' }), row({ Place: 'DD' }),
    row({ Place: 'NS' }), row({ Place: 'G' }), row({ Sex: 'Mx' }), row({ Date: '2011-12-31' }),
    row({ BodyweightKg: '' }), row({ BodyweightKg: '25' }), row({ Age: '', AgeClass: '', BirthYearClass: '' }),
    row({ Age: '12' }), row({ Best3SquatKg: '', Best3BenchKg: '', Best3DeadliftKg: '' }),
  ]
  for (const line of dropped) assert.deepEqual(rowResults(line, IDX, CONFIG, counts), [], line)
  assert.deepEqual(counts, { equipment: 2, place: 4, sex: 1, date: 1, bodyweight: 2, age: 2, noLift: 1 })
})

test('resolveAge: exact, approximate, then the age-class or birth-year-class midpoint', () => {
  assert.equal(resolveAge('23', '', ''), 23)
  assert.equal(resolveAge('23.5', '24-34', ''), 23.5)
  assert.equal(resolveAge('', '40-44', '40-49'), 42)
  assert.equal(resolveAge('', '', '50-59'), 54.5)
  assert.equal(resolveAge('', '80-999', ''), 80)
  assert.equal(resolveAge('', '', ''), null)
})

test('ageGroupOf: boundaries (n.5 ages floor) and binOf clamps to the first/last bin', () => {
  assert.equal(ageGroupOf(14), 'u23')
  assert.equal(ageGroupOf(22.5), 'u23')
  assert.equal(ageGroupOf(23), 'open')
  assert.equal(ageGroupOf(39.5), 'open')
  assert.equal(ageGroupOf(40), 'm40')
  assert.equal(ageGroupOf(59), 'm50')
  assert.equal(ageGroupOf(75), 'm60')
  assert.equal(ageGroupOf(13), null)
  const bins = { start: 50, width: 5, count: 4 }
  assert.equal(binOf(40, bins), 0)
  assert.equal(binOf(54.99, bins), 0)
  assert.equal(binOf(55, bins), 1)
  assert.equal(binOf(300, bins), 3)
})

test('keepBest: one result per lifter per lift, the heaviest, ties -> the latest meet', () => {
  const best = new Map()
  const r = (kg, date, name = 'A B') => ({ key: `M|${name}|bench`, kg, date })
  for (const x of [r(100, '2020-01-01'), r(110, '2019-01-01'), r(110, '2023-01-01'), r(90, '2024-01-01'),
    r(50, '2024-01-01', 'A B #2')]) keepBest(best, x)
  assert.equal(best.size, 2)
  assert.deepEqual(best.get('M|A B|bench'), r(110, '2023-01-01'))
})

test('percentile interpolates linearly; isotonic pools violators; smooth3 averages neighbours', () => {
  assert.equal(percentile([1, 2, 3, 4, 5], 50), 3)
  assert.equal(percentile([10, 20], 25), 12.5)
  assert.equal(percentile([7], 99), 7)
  assert.equal(percentile([], 50), null)
  assert.deepEqual(isotonic([1, 3, 2, 4], [1, 1, 1, 1]), [1, 2.5, 2.5, 4])
  assert.deepEqual(isotonic([5, 1], [3, 1]), [4, 4])
  assert.deepEqual(smooth3([0, 3, 0], [1, 1, 1]), [1, 1.5, 1])
})

/** `n` lifters in one cell with lifts spread evenly from lo to hi (ratio to bodyweight). */
function cell(n, { sex = 'M', lift = 'bench', age = 30, bw = 82, lo = 1, hi = 2 } = {}) {
  return Array.from({ length: n }, (_, i) => ({ sex, lift, age, bw, kg: bw * (lo + ((hi - lo) * i) / (n - 1)) }))
}

const SMALL = { ...CONFIG, minN: 10, maxPoolRadius: 1, percentiles: [5, 50, 95],
  ageGroups: CONFIG.ageGroups.slice(0, 3) }

test('buildCurves: percentiles of lift/bodyweight x the bin median bodyweight, own bins', () => {
  const bins = { start: 70, width: 10, count: 2 }
  const curves = buildCurves([...cell(11, { bw: 75 }), ...cell(11, { bw: 85, lo: 1.5, hi: 2.5 })], bins, SMALL)
  assert.deepEqual(curves.open.map((b) => [b.bin, b.bw, b.n, b.source]), [[0, 75, 11, 'own'], [1, 85, 11, 'own']])
  assert.deepEqual(curves.open[0].kg.length, 3)
  // Percentiles stay ordered and lifts never fall as bodyweight rises.
  for (const b of curves.open) assert.ok(b.kg[0] <= b.kg[1] && b.kg[1] <= b.kg[2])
  for (let p = 0; p < 3; p++) assert.ok(curves.open[0].kg[p] <= curves.open[1].kg[p])
  // u23 has no lifters of its own: it borrows the open group's pooled rows.
  // Both bins borrow the same 22 rows, so they share one bodyweight anchor and merge into one curve.
  assert.deepEqual(curves.u23.map((b) => [b.n, b.source, b.bw]), [[0, 'open+open', 80]])
})

test('buildCurves: a thin bin pools its bodyweight neighbours, then the open group; empty bins are dropped', () => {
  const bins = { start: 70, width: 10, count: 3 }
  const results = [
    ...cell(10, { bw: 75 }), ...cell(3, { bw: 85 }), ...cell(10, { bw: 95 }), // open: bin 1 is thin -> pools ±1
    ...cell(4, { bw: 85, age: 45 }), // m40: only 4 lifters anywhere -> falls back to the open group's pool
  ]
  const curves = buildCurves(results, bins, SMALL)
  assert.deepEqual(curves.open.map((b) => [b.bin, b.n, b.pooled, b.source]),
    [[0, 10, 10, 'own'], [1, 3, 23, 'bw±1'], [2, 10, 10, 'own']])
  assert.deepEqual(curves.m40.map((b) => [b.bin, b.n, b.source]), [[0, 0, 'open'], [1, 4, 'open'], [2, 0, 'open']])
})

test('buildCurves: non-monotone raw medians are smoothed so heavier bins never lift less', () => {
  const bins = { start: 60, width: 10, count: 3 }
  const results = [...cell(20, { bw: 65, lo: 1.8, hi: 2.2 }), ...cell(20, { bw: 75, lo: 1.0, hi: 1.2 }),
    ...cell(20, { bw: 85, lo: 1.5, hi: 1.7 })]
  const med = buildCurves(results, bins, SMALL).open.map((b) => b.kg[1])
  assert.ok(med[0] <= med[1] && med[1] <= med[2], `${med}`)
})

test('coalesce merges bins whose bodyweight anchors tie, weighting curves by pooled lifters', () => {
  const bins = [
    { bin: 3, bw: 130, n: 50, pooled: 100, source: 'own', kg: [100, 150] },
    { bin: 4, bw: 140, n: 10, pooled: 60, source: 'bw\u00B11', kg: [120, 160] },
    { bin: 5, bw: 140, n: 5, pooled: 20, source: 'bw\u00B12', kg: [100, 140] },
    { bin: 6, bw: 150, n: 30, pooled: 60, source: 'own', kg: [130, 170] },
  ]
  assertEqualBins(coalesce(bins), [
    { bin: 3, bw: 130, n: 50, pooled: 100, source: 'own', kg: [100, 150] },
    { bin: 4, bw: 140, n: 15, pooled: 80, source: 'bw\u00B11+bw\u00B12', kg: [115, 155] },
    { bin: 6, bw: 150, n: 30, pooled: 60, source: 'own', kg: [130, 170] },
  ])
  assert.deepEqual(coalesce([]), [])
})

function assertEqualBins(actual, expected) {
  assert.deepEqual(actual, expected)
}

test('buildStandards: every sex x lift x age group, metadata, levels and percentiles', () => {
  const results = [...cell(80, { bw: 82 }), ...cell(80, { sex: 'F', lift: 'squat', bw: 63 })]
  const s = buildStandards(results, { name: 'OpenPowerlifting', version: 'test' })
  assert.equal(s.formatVersion, 1)
  assert.equal(s.source.version, 'test')
  assert.deepEqual(Object.keys(s.tables), ['M', 'F'])
  assert.deepEqual(Object.keys(s.tables.M), ['squat', 'bench', 'deadlift'])
  // Bin 6 (80-85 kg) is the lifters' own; bins up to 3 away borrow it and share its 82 kg anchor: one curve.
  assert.deepEqual(s.tables.M.bench.open.map((b) => [b.bin, b.n, b.bw]), [[3, 80, 82]])
  assert.deepEqual(s.tables.M.squat.open, [])
  assert.ok(s.tables.F.squat.open.every((b) => b.bw === 63))
  assert.deepEqual(s.levels.map((l) => l.id), ['beginner', 'novice', 'intermediate', 'advanced', 'elite'])
  assert.equal(s.percentiles.length, s.tables.M.bench.open[0].kg.length)
  assert.equal(s.method.equipment[0], 'Raw')
})

test('readCsv streams a file: filters, dedupes and counts rows', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'opl-'))
  const path = join(dir, 'openpowerlifting-2026-01-01-abc.csv')
  writeFileSync(path, [HEADER, row(), row({ Best3BenchKg: '130', Date: '2025-01-01' }), row({ Place: 'DQ' }),
    row({ Name: 'C D', Sex: 'F', Event: 'B', BodyweightKg: '60', Best3BenchKg: '70' }), ''].join('\n'))
  const { results, counts } = await readCsv(path)
  assert.equal(counts.rows, 4)
  assert.equal(counts.place, 1)
  assert.deepEqual(results.map((r) => `${r.key}=${r.kg}`).sort(),
    ['F|C D|bench=70', 'M|A B|bench=130', 'M|A B|deadlift=220', 'M|A B|squat=180'])
})

test('the committed tables: app and server copies are identical, small, and well-formed', () => {
  const app = readFileSync(OUT_APP, 'utf8')
  assert.equal(readFileSync(OUT_SERVER, 'utf8'), app)
  assert.ok(app.length < 400 * 1024, `${app.length} bytes`)
  const s = JSON.parse(app)
  assert.equal(s.source.name, 'OpenPowerlifting')
  for (const sex of ['M', 'F']) {
    for (const lift of ['squat', 'bench', 'deadlift']) {
      for (const g of s.ageGroups) {
        const rows = s.tables[sex][lift][g.id]
        assert.ok(rows.length > 5, `${sex} ${lift} ${g.id}`)
        for (let i = 1; i < rows.length; i++) {
          assert.ok(rows[i].bw > rows[i - 1].bw, `${sex} ${lift} ${g.id}: bodyweight anchors must increase`)
        }
        for (const b of rows) assert.equal(b.kg.length, s.percentiles.length)
      }
    }
  }
})
