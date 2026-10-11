#!/usr/bin/env node
// Builds the strength-level percentile tables (squat, bench press, deadlift) from OpenPowerlifting's bulk CSV
// (public domain, see docs/licenses/openpowerlifting.md) into ios/GymRollins/Resources/strength-standards.json,
// and a byte-identical copy for the MCP server (supabase/functions/_shared/strength-standards.json).
// Build time only: the app and the server ship the compact percentile curves, never raw rows. Only the DATA is
// used — no OpenPowerlifting code (AGPLv3) is copied or linked.
//
// Pipeline (streamed, one pass over the ~800 MB CSV):
//   1. Row filter: Equipment == Raw, Event contains the lift, a numeric Place (not DQ/DD/NS/G), Sex M or F,
//      BodyweightKg in [BW_MIN, BW_MAX], an age (Age, else the AgeClass/BirthYearClass midpoint) of AGE_MIN+,
//      meet Date on/after SINCE, Best3<Lift>Kg > 0.
//   2. Dedupe: one result per lifter per lift (Sex + Name; OpenPowerlifting disambiguates namesakes with "#n"):
//      the heaviest, ties -> the most recent meet. Its bodyweight and age place the lifter in a bin.
//   3. Bin: sex x age group x 5 kg bodyweight bin. A bin under MIN_N lifters pools its bodyweight neighbours
//      (+-1..3 bins, same age group); still short -> the open (23-39) age group's pooled rows for that bodyweight.
//   4. Percentiles of lift/bodyweight in each bin (linear interpolation), times the bin's median bodyweight.
//   5. Smooth across bodyweight: weighted isotonic regression (lifts never fall as bodyweight rises) per
//      percentile, then a 3-bin weighted moving average, then percentiles forced non-decreasing within each bin.
//
// Usage: node scripts/build-strength-standards.mjs --csv <openpowerlifting-YYYY-MM-DD-*.csv> [--out <json>]
// Tests: node --test scripts/build-strength-standards.test.mjs
import { createReadStream, readFileSync, writeFileSync } from 'node:fs'
import { basename, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { createHash } from 'node:crypto'

const ROOT = resolve(import.meta.dirname, '..')
export const OUT_APP = resolve(ROOT, 'ios/GymRollins/Resources/strength-standards.json')
export const OUT_SERVER = resolve(ROOT, 'supabase/functions/_shared/strength-standards.json')

export const LIFTS = ['squat', 'bench', 'deadlift']
const LIFT_COLUMN = { squat: 'Best3SquatKg', bench: 'Best3BenchKg', deadlift: 'Best3DeadliftKg' }
const LIFT_EVENT_LETTER = { squat: 'S', bench: 'B', deadlift: 'D' }

export const CONFIG = Object.freeze({
  equipment: ['Raw'],
  since: '2012-01-01',
  ageMin: 14,
  bwMin: 30,
  bwMax: 250,
  minN: 60,
  maxPoolRadius: 3,
  percentiles: [1, 2, 5, 10, 15, 20, 25, 30, 40, 50, 60, 70, 75, 80, 85, 90, 95, 98, 99],
  ageGroups: [
    { id: 'u23', label: 'Under 23', min: 14, max: 22 },
    { id: 'open', label: '23–39', min: 23, max: 39 },
    { id: 'm40', label: '40–49', min: 40, max: 49 },
    { id: 'm50', label: '50–59', min: 50, max: 59 },
    { id: 'm60', label: '60+', min: 60, max: 200 },
  ],
  /** First bin [start, start + width), last bin open-ended; lighter lifters fall in the first bin. */
  bins: { M: { start: 50, width: 5, count: 23 }, F: { start: 40, width: 5, count: 19 } },
  /**
   * Level thresholds, anchored on the raw-competitor curve at the lifter's sex, age group and bodyweight:
   * `fraction x (the competitors' p<percentile> lift)`. Competitors out-lift the general gym population — their
   * p1 is already a solid intermediate gym lifter — so the two lower thresholds sit BELOW the competitor
   * distribution, as fractions of its median. At 81 kg, 23-39, male this gives ~0.73/1.05/1.38/1.87 x bodyweight
   * on the bench (see docs/plans/2026-09-29-plan-14-strength-levels.md, "Level mapping").
   */
  levels: [
    { id: 'beginner', name: 'Beginner', percentile: 50, fraction: 0 },
    { id: 'novice', name: 'Novice', percentile: 50, fraction: 0.45 },
    { id: 'intermediate', name: 'Intermediate', percentile: 50, fraction: 0.65 },
    { id: 'advanced', name: 'Advanced', percentile: 20, fraction: 1 },
    { id: 'elite', name: 'Elite', percentile: 80, fraction: 1 },
  ],
})

const PLACE_OK = /^\d+$/

/** `Age` if present ("23" or "23.5"), else the midpoint of AgeClass ("40-44" -> 42) or BirthYearClass. */
export function resolveAge(age, ageClass, birthYearClass) {
  const exact = Number.parseFloat(age)
  if (age !== '' && Number.isFinite(exact)) return exact
  for (const cls of [ageClass, birthYearClass]) {
    const m = /^(\d+)-(\d+)$/.exec(cls ?? '')
    if (!m) continue
    const lo = Number(m[1])
    const hi = Number(m[2])
    return hi >= 999 ? lo : (lo + hi) / 2
  }
  return null
}

export function ageGroupOf(age, groups = CONFIG.ageGroups) {
  // Ages in the CSV can be n.5 (n or n+1): the floor keeps 22.5 in u23 and 39.5 in open.
  const a = Math.floor(age)
  return groups.find((g) => a >= g.min && a <= g.max)?.id ?? null
}

export function binOf(bw, bins) {
  const i = Math.floor((bw - bins.start) / bins.width)
  return Math.min(bins.count - 1, Math.max(0, i))
}

export function indexHeader(line) {
  const cols = line.split(',')
  const idx = {}
  cols.forEach((c, i) => {
    idx[c] = i
  })
  for (const need of ['Name', 'Sex', 'Event', 'Equipment', 'Age', 'AgeClass', 'BirthYearClass', 'BodyweightKg',
    'Best3SquatKg', 'Best3BenchKg', 'Best3DeadliftKg', 'Place', 'Tested', 'Date']) {
    if (!(need in idx)) throw new Error(`CSV header is missing ${need}`)
  }
  return idx
}

/**
 * The lift results one CSV line contributes, after the row filter; [] when the row is filtered out.
 * `counts` (optional) tallies why rows were dropped.
 */
export function rowResults(line, idx, cfg = CONFIG, counts = null) {
  const f = line.split(',')
  const drop = (why) => {
    if (counts) counts[why] = (counts[why] ?? 0) + 1
    return []
  }
  if (!cfg.equipment.includes(f[idx.Equipment])) return drop('equipment')
  if (!PLACE_OK.test(f[idx.Place])) return drop('place')
  const sex = f[idx.Sex]
  if (sex !== 'M' && sex !== 'F') return drop('sex')
  if (f[idx.Date] < cfg.since) return drop('date')
  const bw = Number.parseFloat(f[idx.BodyweightKg])
  if (!Number.isFinite(bw) || bw < cfg.bwMin || bw > cfg.bwMax) return drop('bodyweight')
  const age = resolveAge(f[idx.Age], f[idx.AgeClass], f[idx.BirthYearClass])
  if (age === null || age < cfg.ageMin) return drop('age')
  const event = f[idx.Event]
  const out = []
  for (const lift of LIFTS) {
    if (!event.includes(LIFT_EVENT_LETTER[lift])) continue
    const kg = Number.parseFloat(f[idx[LIFT_COLUMN[lift]]])
    if (!Number.isFinite(kg) || kg <= 0) continue
    out.push({ key: `${sex}|${f[idx.Name]}|${lift}`, sex, lift, kg, bw, age, date: f[idx.Date] })
  }
  return out.length ? out : drop('noLift')
}

/** Keeps the heaviest result per lifter per lift (ties: the most recent meet). Mutates and returns `best`. */
export function keepBest(best, r) {
  const prev = best.get(r.key)
  if (!prev || r.kg > prev.kg || (r.kg === prev.kg && r.date > prev.date)) best.set(r.key, r)
  return best
}

/** Linear-interpolation percentile (p in 0..100) of an ascending array. */
export function percentile(sorted, p) {
  if (sorted.length === 0) return null
  const pos = (p / 100) * (sorted.length - 1)
  const lo = Math.floor(pos)
  const hi = Math.ceil(pos)
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo)
}

export function median(values) {
  return percentile([...values].sort((a, b) => a - b), 50)
}

/** Weighted isotonic regression (pool-adjacent-violators): the closest non-decreasing sequence. */
export function isotonic(values, weights) {
  const blocks = []
  values.forEach((v, i) => {
    blocks.push({ sum: v * weights[i], w: weights[i], len: 1 })
    while (blocks.length > 1) {
      const b = blocks[blocks.length - 1]
      const a = blocks[blocks.length - 2]
      if (a.sum / a.w <= b.sum / b.w) break
      blocks.splice(-2, 2, { sum: a.sum + b.sum, w: a.w + b.w, len: a.len + b.len })
    }
  })
  return blocks.flatMap((b) => Array(b.len).fill(b.sum / b.w))
}

/** 3-point weighted moving average (ends use the two available points). */
export function smooth3(values, weights) {
  return values.map((_, i) => {
    let s = 0
    let w = 0
    for (let j = Math.max(0, i - 1); j <= Math.min(values.length - 1, i + 1); j++) {
      const k = (j === i ? 2 : 1) * weights[j]
      s += values[j] * k
      w += k
    }
    return s / w
  })
}

const round1 = (x) => Math.round(x * 10) / 10

/**
 * Merges consecutive bins whose bodyweight anchors tie (pooled neighbours can share a median; isotonic ordering
 * then leaves equal anchors): one curve per bodyweight, the pooled-lifter-weighted mean, percentiles kept
 * non-decreasing. Two curves at one bodyweight would make levels jump at that weight.
 */
export function coalesce(bins) {
  const out = []
  for (const b of bins) {
    const prev = out[out.length - 1]
    if (!prev || b.bw > prev.bw) {
      out.push({ ...b, kg: [...b.kg] })
      continue
    }
    const w = prev.pooled + b.pooled
    let floor = 0
    const kg = prev.kg.map((v, i) => {
      floor = Math.max(floor, round1((v * prev.pooled + b.kg[i] * b.pooled) / w))
      return floor
    })
    out[out.length - 1] = { bin: prev.bin, bw: prev.bw, n: prev.n + b.n, pooled: w,
      source: `${prev.source}+${b.source}`, kg }
  }
  return out
}

/** The rows a bin draws on: its own, else pooled bodyweight neighbours, else the open group's pooled rows. */
export function poolFor(cells, age, bin, cfg) {
  const own = cells.get(`${age}|${bin}`) ?? []
  if (own.length >= cfg.minN) return { rows: own, source: 'own' }
  const pooled = (group) => {
    let rows = cells.get(`${group}|${bin}`) ?? []
    for (let r = 1; r <= cfg.maxPoolRadius; r++) {
      rows = rows.concat(cells.get(`${group}|${bin - r}`) ?? [], cells.get(`${group}|${bin + r}`) ?? [])
      if (rows.length >= cfg.minN) return { rows, radius: r }
    }
    return { rows, radius: cfg.maxPoolRadius }
  }
  const near = pooled(age)
  if (near.rows.length >= cfg.minN) return { rows: near.rows, source: `bw±${near.radius}` }
  if (age !== 'open') {
    const open = pooled('open')
    if (open.rows.length >= cfg.minN) return { rows: open.rows, source: 'open' }
  }
  return { rows: [], source: 'none' }
}

/** Percentile curves for one sex x lift from its deduped results. */
export function buildCurves(results, bins, cfg = CONFIG) {
  const cells = new Map()
  for (const r of results) {
    const age = ageGroupOf(r.age, cfg.ageGroups)
    if (!age) continue
    const k = `${age}|${binOf(r.bw, bins)}`
    if (!cells.has(k)) cells.set(k, [])
    cells.get(k).push(r)
  }
  const out = {}
  for (const g of cfg.ageGroups) {
    const raw = []
    for (let b = 0; b < bins.count; b++) {
      const own = cells.get(`${g.id}|${b}`) ?? []
      const { rows, source } = poolFor(cells, g.id, b, cfg)
      if (rows.length === 0) continue
      const bw = median(rows.map((r) => r.bw))
      const ratios = rows.map((r) => r.kg / r.bw).sort((a, b) => a - b)
      raw.push({ bin: b, n: own.length, pooledN: rows.length, source, bw,
        kg: cfg.percentiles.map((p) => percentile(ratios, p) * bw) })
    }
    // Bin bodyweights come from medians; pooled neighbours can make them non-increasing — keep them ordered.
    const bws = isotonic(raw.map((r) => r.bw), raw.map(() => 1))
    const weights = raw.map((r) => Math.sqrt(r.pooledN))
    const columns = cfg.percentiles.map((_, pi) =>
      smooth3(isotonic(raw.map((r) => r.kg[pi]), weights), weights))
    out[g.id] = coalesce(raw.map((r, i) => {
      let floor = 0
      const kg = columns.map((col) => {
        floor = Math.max(floor, col[i])
        return round1(floor)
      })
      return { bin: r.bin, bw: round1(bws[i]), n: r.n, pooled: r.pooledN, source: r.source, kg }
    }))
  }
  return out
}

export function buildStandards(bestResults, meta, cfg = CONFIG) {
  const tables = {}
  for (const sex of ['M', 'F']) {
    tables[sex] = {}
    for (const lift of LIFTS) {
      const rows = bestResults.filter((r) => r.sex === sex && r.lift === lift)
      tables[sex][lift] = buildCurves(rows, cfg.bins[sex], cfg)
    }
  }
  return {
    formatVersion: 1,
    source: meta,
    method: {
      equipment: cfg.equipment,
      tested: 'all (drug-tested and untested)',
      since: cfg.since,
      minAge: cfg.ageMin,
      bodyweightKg: [cfg.bwMin, cfg.bwMax],
      dedupe: 'one result per lifter per lift: the heaviest (ties: most recent)',
      events: 'any meet event containing the lift (full power, push-pull, single lift)',
      place: 'numeric places only (no DQ, doping DQ, no-show or guest)',
      binning: 'sex x age group x 5 kg bodyweight bin; lift/bodyweight percentiles x the bin median bodyweight',
      fallback: `bins under ${cfg.minN} lifters pool bodyweight neighbours (up to ±${cfg.maxPoolRadius} bins), ` +
        'then the 23–39 group',
      smoothing: 'weighted isotonic regression across bodyweight, 3-bin moving average, percentiles non-decreasing; ' +
        'bins sharing a bodyweight anchor merged',
      minN: cfg.minN,
    },
    percentiles: cfg.percentiles,
    ageGroups: cfg.ageGroups,
    levels: cfg.levels,
    tables,
  }
}

export async function readCsv(path, cfg = CONFIG) {
  const best = new Map()
  const counts = { rows: 0 }
  const rl = createInterface({ input: createReadStream(path), crlfDelay: Infinity })
  let idx = null
  for await (const line of rl) {
    if (!idx) {
      idx = indexHeader(line)
      continue
    }
    if (line === '') continue
    counts.rows++
    for (const r of rowResults(line, idx, cfg, counts)) keepBest(best, r)
  }
  return { results: [...best.values()], counts }
}

function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex')
}

async function main() {
  const args = process.argv.slice(2)
  const csv = args[args.indexOf('--csv') + 1]
  if (!args.includes('--csv') || !csv) throw new Error('usage: --csv <openpowerlifting-*.csv> [--out <json>]')
  const out = args.includes('--out') ? resolve(args[args.indexOf('--out') + 1]) : null
  const { results, counts } = await readCsv(csv)
  const version = /openpowerlifting-(\d{4}-\d{2}-\d{2})/.exec(basename(csv))?.[1] ?? 'unknown'
  const meta = {
    name: 'OpenPowerlifting',
    url: 'https://www.openpowerlifting.org',
    data: 'https://openpowerlifting.gitlab.io/opl-csv/files/openpowerlifting-latest.zip',
    license: 'Public domain (OpenPowerlifting data is contributed to the public domain)',
    version,
    file: basename(csv),
    sha256: sha256(csv),
    rowsRead: counts.rows,
    lifterResults: results.length,
  }
  const json = JSON.stringify(buildStandards(results, meta)) + '\n'
  for (const path of out ? [out] : [OUT_APP, OUT_SERVER]) writeFileSync(path, json)
  process.stderr.write(`rows ${counts.rows}, dropped ${JSON.stringify(counts)}, lifter results ${results.length}, ` +
    `${(json.length / 1024).toFixed(0)} KB\n`)
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => {
    process.stderr.write(`${e.stack ?? e}\n`)
    process.exit(1)
  })
}
