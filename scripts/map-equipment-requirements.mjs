#!/usr/bin/env node
// Maps every library exercise to the equipment kinds it needs (docs/specs/2026-10-30-gym-equipment-design.md §4).
// Each exercise gets requirement groups that ALL have to be present, any one kind per group:
//   [["barbell"], ["flat-bench", "adjustable-bench", "bench-press-station"], ["power-rack", "bench-press-station"]]
// `[]` = no equipment. An exercise missing from the output is unmapped: the app still logs it but never picks it.
// Conservative on purpose (a wrong requirement suggests an exercise the gym can't do): unclear names stay unmapped
// and are listed in the review file.
//
// Usage: node scripts/map-equipment-requirements.mjs
//   Reads ios/GymRollins/Resources/exercises.json and equipment-kinds.json, writes
//   ios/GymRollins/Resources/equipment-requirements.json and docs/import/equipment-requirements-review.md.
// Tests: node --test scripts/map-equipment-requirements.test.mjs
import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

const ROOT = resolve(import.meta.dirname, '..')
const LIBRARY = resolve(ROOT, 'ios/GymRollins/Resources/exercises.json')
const KINDS = resolve(ROOT, 'ios/GymRollins/Resources/equipment-kinds.json')
const OUT_JSON = resolve(ROOT, 'ios/GymRollins/Resources/equipment-requirements.json')
const OUT_REVIEW = resolve(ROOT, 'docs/import/equipment-requirements-review.md')

export const FLAT_BENCH = ['flat-bench', 'adjustable-bench']
export const INCLINE_BENCH = ['adjustable-bench', 'incline-bench']
export const DECLINE_BENCH = ['adjustable-bench', 'decline-bench']
const BALL = /stability ball|exercise ball|swiss ball/

/** Free weights: the library's `eq` -> the kind that carries the load. */
const FREE_WEIGHTS = {
  dumbbell: 'dumbbells', kettlebell: 'kettlebells', barbell: 'barbell', 'olympic barbell': 'barbell',
  'ez barbell': 'ez-bar', 'trap bar': 'trap-bar', 'medicine ball': 'medicine-ball',
}
/** Equipment that maps one to one to a kind. */
const DIRECT = {
  band: 'resistance-bands', 'resistance band': 'resistance-bands', 'stability ball': 'stability-ball',
  'bosu ball': 'bosu-ball', 'wheel roller': 'ab-wheel', 'stationary bike': 'stationary-bike',
  'elliptical machine': 'elliptical', 'stepmill machine': 'stepmill', 'skierg machine': 'skierg',
  'upper body ergometer': 'upper-body-ergometer',
}
/** Equipment with no kind, or partner-assisted ("assisted"): always unmapped. */
const NO_KIND = new Set(['weighted', 'assisted', 'rope', 'roller', 'hammer', 'tire'])
/** Bodyweight exercises that need something the kinds list doesn't have. */
const NEEDS_OTHER = /\brings?\b|towel|rope|\bbox\b|stool|chair|\bstep\b|platform|sled/

/** Leverage and sled machines, first match wins; `null` = deliberately unmapped. */
export const MACHINE_RULES = [
  [/hack.*calf/, ['hack-squat']],
  [/on leg press|^sled .*calf/, ['leg-press']],
  [/calf/, ['calf-raise-machine']],
  [/hack squat/, ['hack-squat']],
  [/leg (wide )?press/, ['leg-press']],
  [/assisted/, ['assisted-pullup-dip']],
  [/leg extension/, ['leg-extension']],
  [/leg curl/, ['leg-curl']],
  [/hip (abduction|adduction)/, ['hip-abductor-adductor']],
  [/chest press/, ['chest-press-machine']],
  [/shoulder press|military press/, ['shoulder-press-machine']],
  [/lateral raise/, ['lateral-raise-machine']],
  [/seated (reverse )?fly/, ['pec-deck']],
  [/pulldown/, ['lat-pulldown']],
  [/\bt[- ]?bar\b/, ['t-bar-row']],
  [/bent-over/, null],
  [/\brow\b/, ['seated-row-machine']],
  [/preacher curl|bicep curl/, ['preacher-curl-machine']],
  [/triceps (extension|dip)|seated dip/, ['triceps-machine']],
  [/crunch|kneeling twist/, ['ab-crunch-machine']],
  [/reverse hyperextension/, null],
  [/back extension|hyperextension/, ['back-extension']],
  [/treadmill/, ['treadmill']],
  [/stationary bike/, ['stationary-bike']],
  [/cross trainer/, ['elliptical']],
]

/** The bench an exercise needs, as zero or one requirement group. A ball replaces the bench; only free weights
 *  read "fly", "pullover" and "skull" as lying on a bench (cable flies are standing). */
export function benchFor(name, { fly }) {
  if (BALL.test(name)) return [['stability-ball']]
  if (/preacher/.test(name)) return [['preacher-bench']]
  if (/\bincline\b/.test(name)) return [INCLINE_BENCH]
  if (/\bdecline\b/.test(name)) return [DECLINE_BENCH]
  if (/\bbench\b|\blying\b/.test(name) || (fly && /\bfly\b|pullover|skull/.test(name))) return [FLAT_BENCH]
  return []
}

/** Barbell presses from uprights: a bench plus a rack, or one station that is both. */
function barbellPress(name) {
  if (/\bincline\b/.test(name)) return [INCLINE_BENCH, ['power-rack', 'incline-bench']]
  if (/\bdecline\b/.test(name)) return [DECLINE_BENCH, ['power-rack', 'decline-bench']]
  return [[...FLAT_BENCH, 'bench-press-station'], ['power-rack', 'bench-press-station']]
}

function freeWeight(name, eq) {
  const load = [FREE_WEIGHTS[eq]]
  if (load[0] !== 'barbell') return { groups: [load, ...benchFor(name, { fly: true })] }
  if (/bench press|(incline|decline).*press/.test(name)) return { groups: [load, ...barbellPress(name)] }
  if (/squat|lunge|good morning/.test(name)) {
    return { groups: [load, ['power-rack'], ...benchFor(name, { fly: true })] }
  }
  return { groups: [load, ...benchFor(name, { fly: true })] }
}

function cable(name) {
  const base = /pulldown|pull-down|pull down/.test(name) ? ['lat-pulldown', 'cable-station']
    : /seated.*row|low row|floor seated/.test(name) ? ['seated-cable-row', 'cable-station']
      : ['cable-station']
  return { groups: [base, ...benchFor(name, { fly: false })] }
}

function machine(name) {
  const rule = MACHINE_RULES.find(([re]) => re.test(name))
  return rule?.[1] ? { groups: [rule[1]] } : { unmapped: 'machine not identified' }
}

/** Bodyweight exercises need a bar, dip station, bench, ball or back-extension bench only when the name says so. */
export function bodyweight(name) {
  if (NEEDS_OTHER.test(name)) return { unmapped: 'needs equipment that has no kind' }
  if (/\bdips?\b/.test(name)) {
    if (/floor/.test(name)) return { groups: [] }
    if (/\bbench(es)?\b/.test(name)) return { groups: [FLAT_BENCH] }
    return { groups: [['dip-station', 'assisted-pullup-dip']] }
  }
  if (/pull-?up|chin-?up|muscle[- ]?up|hanging|\bhang\b/.test(name)) return { groups: [['pull-up-bar', 'power-rack']] }
  if (/inverted row/.test(name)) return { groups: [['power-rack', 'smith-machine']] }
  if (BALL.test(name)) return { groups: [['stability-ball']] }
  if (/back extension|hyperextension/.test(name)) return { groups: [['back-extension']] }
  if (/\bbench\b|incline push|decline push/.test(name)) return { groups: [FLAT_BENCH] }
  return { groups: [] }
}

/** Requirement groups for one library exercise (`{ groups }`), or `{ unmapped: reason }`. */
export function requirementsFor({ n, eq }) {
  const name = n.toLowerCase()
  if (/stretch/.test(name)) return { unmapped: 'stretch' }
  if (NO_KIND.has(eq)) return { unmapped: `no kind for "${eq}"` }
  if (eq === 'leverage machine' || eq === 'sled machine') return machine(name)
  if (eq === 'cable') return cable(name)
  if (eq === 'smith machine') return { groups: [['smith-machine'], ...benchFor(name, { fly: false })] }
  if (eq === 'body weight') return bodyweight(name)
  if (FREE_WEIGHTS[eq]) return freeWeight(name, eq)
  if (DIRECT[eq]) return { groups: [[DIRECT[eq]]] }
  return { unmapped: `unknown equipment "${eq}"` }
}

/** Maps the whole library. Throws when a rule names a kind that isn't in equipment-kinds.json. */
export function buildRequirements(library, kindIds) {
  const known = new Set(kindIds)
  const requirements = {}
  const unmapped = []
  for (const ex of library) {
    const result = requirementsFor(ex)
    if (result.unmapped) {
      unmapped.push({ id: ex.id, n: ex.n, eq: ex.eq, reason: result.unmapped })
      continue
    }
    const unknown = result.groups.flat().find(kind => !known.has(kind))
    if (unknown) throw new Error(`${ex.id} ${ex.n}: unknown kind "${unknown}"`)
    requirements[ex.id] = result.groups
  }
  return { requirements, unmapped }
}

/** The owner's review file: counts, every machine mapping, every unmapped exercise. */
export function review(library, { requirements, unmapped }) {
  const cell = s => String(s).replaceAll('|', '\\|')
  const needs = groups => groups.map(g => g.join(' or ')).join(' + ')
  const none = Object.values(requirements).filter(g => g.length === 0).length
  const machines = library.filter(e => (e.eq === 'leverage machine' || e.eq === 'sled machine') && requirements[e.id])
  const sortedUnmapped = [...unmapped].sort((a, b) => a.reason.localeCompare(b.reason) || a.id.localeCompare(b.id))
  return [
    '# Equipment requirements review',
    '',
    'Generated by `node scripts/map-equipment-requirements.mjs`; do not edit by hand. Check the machine table and the',
    'unmapped list. To fix a row, change the rules in the script and run it again.',
    '',
    `- Library exercises: ${library.length}`,
    `- Mapped: ${Object.keys(requirements).length} (no equipment: ${none})`,
    `- Unmapped: ${unmapped.length}`,
    '',
    '## Machines (check these)',
    '',
    '| Id | Library name | Needs |',
    '|---|---|---|',
    ...machines.map(e => `| ${e.id} | ${cell(e.n)} | ${needs(requirements[e.id])} |`),
    '',
    '## Unmapped',
    '',
    '| Reason | Id | Library name | Equipment |',
    '|---|---|---|---|',
    ...sortedUnmapped.map(u => `| ${cell(u.reason)} | ${u.id} | ${cell(u.n)} | ${u.eq} |`),
    '',
  ].join('\n')
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const library = JSON.parse(readFileSync(LIBRARY, 'utf8'))
  const kinds = JSON.parse(readFileSync(KINDS, 'utf8')).kinds
  const result = buildRequirements(library, kinds.map(k => k.id))
  const sorted = Object.fromEntries(Object.entries(result.requirements).sort((a, b) => a[0].localeCompare(b[0])))
  writeFileSync(OUT_JSON, `${JSON.stringify({ version: 1, requirements: sorted })}\n`)
  writeFileSync(OUT_REVIEW, review(library, result))
  console.log(`Mapped ${Object.keys(sorted).length} / ${library.length} exercises -> ${OUT_JSON}`)
}
