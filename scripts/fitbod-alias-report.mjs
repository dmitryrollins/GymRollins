#!/usr/bin/env node
// Fitbod alias report: lists every distinct exercise name in a Fitbod CSV export with its set count and the
// best library match, using the same normalization + Jaccard scoring as GymCore `ExerciseMatcher`.
//
// Usage: node scripts/fitbod-alias-report.mjs <export.csv> [--out docs/import/fitbod-alias-review.md]
//
// PERSONAL DATA: the CSV is read locally only. Output contains exercise NAMES and set COUNTS — never dates,
// weights, reps or notes. Without --out it prints to stdout and writes nothing.
import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

const ROOT = resolve(import.meta.dirname, '..')
const LIBRARY = resolve(ROOT, 'ios/GymRollins/Resources/exercises.json')
const ALIASES = resolve(ROOT, 'ios/GymRollins/Resources/fitbod-aliases.json')
const MIN_SCORE = 0.6

// --- ExerciseMatcher port -------------------------------------------------------------------------------
export const normalize = s =>
  [...s.toLowerCase()].map(c => (/[\p{L}\p{N}]/u.test(c) ? c : ' ')).join('').split(' ').filter(Boolean).join(' ')

export const tokens = normalized =>
  new Set(normalized.split(' ').filter(Boolean).map(t => (t.length > 3 && t.endsWith('s') ? t.slice(0, -1) : t)))

export const jaccard = (a, b) => {
  const union = new Set([...a, ...b]).size
  if (union === 0) return 0
  let inter = 0
  for (const t of a) if (b.has(t)) inter++
  return inter / union
}

/** Ranked candidates plus the matcher's verdict (exact / fuzzy / ambiguous / none). */
export function rank(raw, entries) {
  const name = normalize(raw)
  const exact = entries.find(e => e.name === name)
  if (exact) return { verdict: 'exact', best: { ...exact, score: 1 }, runnerUp: null }
  const q = tokens(name)
  const scored = entries.map(e => ({ ...e, score: jaccard(q, e.tokens) })).sort((a, b) => b.score - a.score)
  const [best, runnerUp] = scored
  let verdict = 'none'
  if (best && best.score >= MIN_SCORE) verdict = runnerUp && runnerUp.score === best.score ? 'ambiguous' : 'fuzzy'
  return { verdict, best, runnerUp }
}

// --- CSV (RFC 4180-ish, quoted fields may contain commas, quotes, newlines) ----------------------------------
export function csvRecords(text) {
  const rows = []
  let row = []
  let field = ''
  let quoted = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') { field += '"'; i++ } else if (c === '"') quoted = false
      else field += c
    } else if (c === '"') quoted = true
    else if (c === ',') { row.push(field); field = '' } else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i++
      row.push(field); rows.push(row); row = []; field = ''
    } else field += c
  }
  if (field !== '' || row.length) { row.push(field); rows.push(row) }
  return rows.filter(r => !(r.length === 1 && r[0] === ''))
}

function distinctNames(csvPath) {
  const [header, ...rows] = csvRecords(readFileSync(csvPath, 'utf8'))
  const col = header.map(h => h.trim()).indexOf('Exercise')
  if (col < 0) throw new Error('No "Exercise" column in CSV header')
  const counts = new Map()
  for (const r of rows) {
    const name = (r[col] ?? '').trim()
    if (name) counts.set(name, (counts.get(name) ?? 0) + 1)
  }
  return [...counts].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
}

const cell = s => String(s).replaceAll('|', '\\|')

function report(csvPath) {
  const library = JSON.parse(readFileSync(LIBRARY, 'utf8'))
  const byId = new Map(library.map(e => [e.id, e]))
  const entries = library.map(e => ({ id: e.id, name: normalize(e.n), tokens: tokens(normalize(e.n)) }))
  let aliases = {}
  try { aliases = JSON.parse(readFileSync(ALIASES, 'utf8')) } catch { /* table not curated yet */ }
  const names = distinctNames(csvPath)
  const lines = [
    '| Fitbod name | Sets | Best match | Score | Runner-up | Matcher | Curated |',
    '|---|---:|---|---:|---|---|---|',
  ]
  for (const [name, count] of names) {
    const { verdict, best, runnerUp } = rank(name, entries)
    const fmt = e => (e ? `${e.id} ${byId.get(e.id).n}` : '—')
    const curated = !(name in aliases) ? 'MISSING'
      : aliases[name] === null ? 'custom' : `${aliases[name]} ${byId.get(aliases[name])?.n ?? '(unknown id!)'}`
    lines.push(`| ${cell(name)} | ${count} | ${cell(fmt(best))} | ${best.score.toFixed(2)} | ` +
      `${cell(fmt(runnerUp))}${runnerUp ? ` (${runnerUp.score.toFixed(2)})` : ''} | ${verdict} | ${cell(curated)} |`)
  }
  const total = names.reduce((s, [, c]) => s + c, 0)
  const summary = `${names.length} distinct names, ${total} sets.`
  return { summary, table: lines.join('\n') }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2)
  const outIdx = args.indexOf('--out')
  const out = outIdx >= 0 ? args[outIdx + 1] : null
  const csv = args.find((a, i) => !a.startsWith('--') && (outIdx < 0 || i !== outIdx + 1))
  if (!csv) { console.error('Usage: fitbod-alias-report.mjs <export.csv> [--out <file.md>]'); process.exit(2) }
  const { summary, table } = report(csv)
  if (out) {
    writeFileSync(resolve(out), `${summary}\n\n${table}\n`)
    console.log(`Wrote ${summary} to ${out}`)
  } else {
    console.log(`${summary}\n\n${table}`)
  }
}
