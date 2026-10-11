#!/usr/bin/env node
// Strong / Hevy / FitNotes alias review: for every curated name in `<app>-aliases.json` shows the curated library
// id next to what the app's matcher (GymCore `ExerciseMatcher`, ported in fitbod-alias-report.mjs) would pick on
// its own, with the reason for every non-obvious decision.
//
// Usage: node scripts/other-apps-alias-report.mjs [--out docs/import/other-apps-alias-review.md]
//
// Reads only the bundled alias tables and the exercise library: no personal data involved.
import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { normalize, tokens, rank } from './fitbod-alias-report.mjs'

const ROOT = resolve(import.meta.dirname, '..')
const RESOURCES = resolve(ROOT, 'ios/GymRollins/Resources')
const LIBRARY = resolve(RESOURCES, 'exercises.json')

export const APPS = [
  { key: 'strong', title: 'Strong', file: 'strong-aliases.json' },
  { key: 'hevy', title: 'Hevy', file: 'hevy-aliases.json' },
  { key: 'fitnotes', title: 'FitNotes', file: 'fitnotes-aliases.json' },
]

// --- Reasons ----------------------------------------------------------------------------------------------
// COMMON applies to a name in any app; REASONS[app] wins over it. Trivial agreements get a generated reason.
const HIP_THRUST = 'Shoulders-on-bench barbell hip thrust; the library glute bridges are floor-based, loads not ' +
  'comparable (same call as Fitbod "Barbell Hip Thrust").'
const ROWER = 'No rowing ergometer in the library (only a SkiErg); becomes a custom cardio exercise.'
const OHP = 'Standing barbell overhead press at shoulder width = standing close-grip military press (no plain ' +
  'standing OHP entry); the matcher\'s seated press is a different, lighter lift.'
const RUN = 'Run (cardio), same id as Fitbod "Running". Treadmill and outdoor runs share it; "run (equipment)" ' +
  '(0684) is a duplicate with identical instructions.'
const TRICEPS_DIP = 'Upright parallel-bar dip. Library "triceps dip" (0814) is the bench dip (Fitbod decision), so ' +
  'the exact-name hit is overridden; imported with the logged added load (0 when bodyweight).'
const SEATED_CALF = 'Seated calf raise machine (knee pad, plate loaded); the matcher offered barbell versions.'
const STANDING_CALF = 'Standing calf raise machine (shoulder pads); matcher tied barbell vs bodyweight.'

const COMMON = {
  'Bicep Curl (Barbell)': 'Straight-bar two-arm curl; the matcher preferred the alternating variant.',
  'Bicep Curl (Cable)': 'Standing cable curl with a bar; matcher tied lying vs pulldown curls.',
  'Bulgarian Split Squat': 'Rear-foot-elevated split squat with dumbbells (the library entry puts the back foot on a ' +
    'bench); the matcher suggested the bodyweight floor split squat.',
  'Cable Crossover': 'Standing cable fly between two pulleys (Fitbod "Cable Crossover Fly").',
  'Cable Crunch': 'Kneeling rope crunch at the high pulley; matcher tied kneeling vs reverse crunch.',
  'Chest Press (Machine)': 'Selectorized seated chest press = lever chest press (0576 is a duplicate entry); ' +
    '"machine inner chest press" is a squeeze variant.',
  'Crunch': 'Floor crunch.',
  'Hip Thrust (Barbell)': HIP_THRUST,
  'Lat Pulldown (Machine)': 'Plate-loaded pulldown machine = lever front pulldown; kept apart from the cable ' +
    'pulldown (0198) because loads differ.',
  'Leg Extension (Machine)': 'Machine leg extension (Fitbod decision).',
  'Overhead Press (Barbell)': OHP,
  'Plank': 'Front forearm plank; imported with zero added weight and its duration (Fitbod decision).',
  'Skullcrusher (Barbell)': 'Barbell skull crusher (lying extension to the forehead), not the reverse-grip version.',
  'Squat (Barbell)': 'Barbell back squat = barbell full squat (Fitbod "Back Squat").',
  'Standing Calf Raise (Machine)': STANDING_CALF,
  'Triceps Dip': TRICEPS_DIP,
  'Walking': 'The library\'s only plain walking cardio entry (Fitbod decision).',
  'Running': RUN,
  'Running (Treadmill)': RUN,
  'Rowing (Machine)': ROWER,
  'Rowing Machine': ROWER,
  'Leg Press': 'The 45° plate-loaded sled (Fitbod decision), not the Smith leg press the fuzzy match suggested.',
  'Dumbbell Row': 'Single-arm dumbbell row (Fitbod decision); matcher tied incline vs upright row.',
}

export const REASONS = {
  strong: {
    'Ab Wheel': 'Kneeling ab-wheel rollout.',
    'Bench Dip': 'Library "triceps dip" is the bench dip (Fitbod decision); fuzzy tie offered three-bench / weighted.',
    'Box Squat (Barbell)': 'Squat to a box/bench = barbell bench squat; not merged into full squat (lighter, paused).',
    'Cycling (Indoor)': 'Stationary bike (Fitbod "Cycling - Stationary").',
    'Elliptical Machine': 'Elliptical cross trainer (equipment match).',
    'Face Pull (Cable)': 'Face pull = cable rear delt row with rope (Fitbod decision).',
    'Hack Squat': 'Strong\'s Hack Squat is the plate-loaded hack machine (sled), not the behind-the-legs barbell lift.',
    'Hip Abductor (Machine)': 'Seated hip abduction machine (Fitbod decision).',
    'Hip Adductor (Machine)': 'Seated hip adduction machine (Fitbod decision).',
    'Seated Calf Raise (Plate Loaded)': SEATED_CALF,
    'Seated Overhead Press (Dumbbell)': 'Seated two-arm dumbbell press (same id as Fitbod "Dumbbell Shoulder Press").',
    'Sit Up': 'Plain floor sit-up; the tie offered assisted / decline variants.',
    'Triceps Extension (Cable)': 'Strong\'s cable triceps extension is overhead with a rope; matcher tied ' +
      'alternate vs incline versions.',
    'Triceps Extension (Dumbbell)': 'Two-hand overhead dumbbell extension (Fitbod decision).',
    'Triceps Pushdown (Cable - Straight Bar)': 'Straight-bar cable pushdown; the matcher picked the V-bar version.',
  },
  hevy: {
    'Back Extension (Hyperextension)': '45° back extension bench = hyperextension (Fitbod decision); the lever ' +
      'entry is a seated machine.',
    'Cable Fly Crossovers': 'Standing cable fly between two pulleys (Fitbod "Cable Crossover Fly").',
    'Calf Press (Machine)': 'Calf press on a machine = lever calf press (not the seated calf press).',
    'Chest Fly (Machine)': 'Pec deck = lever seated fly.',
    'Cycling': 'The library\'s only cycling cardio entry (stationary bike); imported as cardio duration/distance.',
    'Elliptical Trainer': 'Elliptical cross trainer (equipment match).',
    'EZ Bar Biceps Curl': 'EZ-bar curl; the arm-blaster version is a different setup.',
    'Face Pull': 'Hevy\'s Face Pull is cable with rope = cable rear delt row (with rope) (Fitbod decision).',
    'Front Squat': 'Hevy\'s Front Squat is barbell; matcher tied barbell vs kettlebell.',
    'Goblet Squat': 'Hevy logs Goblet Squat with a dumbbell (Fitbod decision); matcher tied dumbbell vs kettlebell.',
    'Hack Squat (Machine)': 'Plate-loaded hack squat machine (sled), not the barbell hack squat.',
    'Hip Abduction (Machine)': 'Seated hip abduction machine (Fitbod decision).',
    'Hip Adduction (Machine)': 'Seated hip adduction machine (Fitbod decision).',
    'Leg Press (Machine)': 'Hevy\'s Leg Press (Machine) is the 45° sled (it has a separate "Leg Press Horizontal").',
    'Lying Leg Raise': 'Lying leg raise on a flat bench/floor; not the leg-hip raise variant.',
    'Overhead Triceps Extension (Cable)': 'Overhead cable extension with rope (Fitbod "Cable Rope Overhead Triceps ' +
      'Extension"); matcher tied high-pulley vs rope.',
    'Rear Delt Reverse Fly (Dumbbell)': 'Bent-over dumbbell reverse fly (Fitbod decision).',
    'Seated Cable Row - V Grip (Cable)': 'Seated cable row with the V handle (Fitbod "Cable Row"), not wide grip.',
    'Seated Calf Raise': SEATED_CALF,
    'Seated Row (Machine)': 'Plate/selectorized seated row machine = lever seated row; kept apart from cable row.',
    'Treadmill': 'Hevy "Treadmill" is a treadmill run; shares the run id. Treadmill walks log under "Walking".',
    'Triceps Extension (Cable)': 'Ambiguous: Hevy lists a separate overhead variant and a pushdown, so this one ' +
      'stays custom rather than merging its loads into either history.',
    'Triceps Pushdown': 'Hevy\'s default pushdown uses a straight bar = cable pushdown (Fitbod decision).',
    'Triceps Rope Pushdown': 'Rope pushdown (Fitbod "Cable Rope Tricep Extension").',
  },
  fitnotes: {
    'Ab-Wheel Rollout': 'Kneeling ab-wheel rollout.',
    'Barbell Row': 'FitNotes Barbell Row is the bent-over row; matcher tied incline vs Pendlay row.',
    'Barbell Squat': 'Barbell back squat = barbell full squat (Fitbod "Back Squat").',
    'Cycling': 'FitNotes default cardio "Cycling"; the library\'s only cycling entry is the stationary bike.',
    'Deadlift': 'FitNotes Deadlift is barbell (Fitbod decision).',
    'Dumbbell Curl': 'Two-arm standing dumbbell biceps curl; matcher tied with concentration curl.',
    'EZ-Bar Curl': 'EZ-bar curl.',
    'Lat Pulldown': 'Standard cable lat pulldown (Fitbod decision).',
    'Leg Extension Machine': 'Machine leg extension (Fitbod decision).',
    'Lying Triceps Extension': 'FitNotes files it under barbell/EZ-bar; mapped to the barbell lying extension.',
    'Overhead Press': OHP,
    'Parallel Bar Triceps Dip': TRICEPS_DIP,
    'Push Press': 'FitNotes Push Press is barbell; the library only has dumbbell/kettlebell push presses, loads not ' +
      'comparable.',
    'Romanian Deadlift': 'FitNotes RDL is barbell (Fitbod decision); matcher tied barbell vs dumbbell.',
    'Rope Push Down': 'Rope pushdown (Fitbod "Cable Rope Tricep Extension").',
    'Seated Calf Raise Machine': SEATED_CALF,
    'Seated Dumbbell Press': 'Seated two-arm dumbbell shoulder press (Fitbod "Dumbbell Shoulder Press").',
    'Seated Machine Fly': 'Pec deck = lever seated fly.',
    'Standing Calf Raise Machine': STANDING_CALF,
    'V-Bar Push Down': 'Cable pushdown with a V-bar.',
  },
}

// --- Report -----------------------------------------------------------------------------------------------
export function loadLibrary() {
  const library = JSON.parse(readFileSync(LIBRARY, 'utf8'))
  const byId = new Map(library.map(e => [e.id, e]))
  const entries = library.map(e => ({ id: e.id, name: normalize(e.n), tokens: tokens(normalize(e.n)) }))
  return { byId, entries }
}

export const loadAliases = app => JSON.parse(readFileSync(resolve(RESOURCES, app.file), 'utf8'))

const cell = s => String(s).replaceAll('|', '\\|')

function matcherText({ verdict, best }) {
  if (verdict === 'exact') return `${best.id} (exact 1.00)`
  if (verdict === 'fuzzy') return `${best.id} (fuzzy ${best.score.toFixed(2)})`
  if (verdict === 'ambiguous') return `tie at ${best.score.toFixed(2)}`
  return 'none'
}

function reasonFor(appKey, name, id, match) {
  const explicit = REASONS[appKey]?.[name] ?? COMMON[name]
  if (explicit) return explicit
  const agrees = (match.verdict === 'exact' || match.verdict === 'fuzzy') && match.best.id === id
  if (!agrees) return null
  if (match.verdict === 'exact') return normalize(name) === name.toLowerCase() ? 'Exact name match.' : 'Exact after punctuation.'
  if (match.best.score === 1) return 'Same words, different order (or plural only).'
  return `Matcher agrees (fuzzy ${match.best.score.toFixed(2)}); movement and equipment match.`
}

/** Per-app rows plus summary counts; `missingReasons` lists names whose decision is unexplained. */
export function analyze(app, aliases, { byId, entries }) {
  const rows = Object.entries(aliases).map(([name, id]) => {
    const match = rank(name, entries)
    const confident = match.verdict === 'exact' || match.verdict === 'fuzzy'
    return { name, id, match, confident, agrees: confident && match.best.id === id, reason: reasonFor(app.key, name, id, match) }
  })
  const counts = {
    names: rows.length,
    mapped: rows.filter(r => r.id !== null).length,
    custom: rows.filter(r => r.id === null).length,
    matcherAgrees: rows.filter(r => r.agrees).length,
    overrides: rows.filter(r => r.confident && !r.agrees).length,
    unmatchedOrAmbiguous: rows.filter(r => !r.confident).length,
  }
  const missingReasons = rows.filter(r => !r.reason).map(r => r.name)
  const unknownIds = rows.filter(r => r.id !== null && !byId.has(r.id)).map(r => r.name)
  return { rows, counts, missingReasons, unknownIds }
}

function section(app, { rows, counts }, byId) {
  const curated = r => (r.id === null ? '**custom**' : `\`${r.id}\` ${byId.get(r.id)?.n ?? '(unknown id!)'}`)
  const lines = [
    `## ${app.title}`,
    '',
    `- Names in \`${app.file}\`: **${counts.names}**; mapped to a library exercise: **${counts.mapped}**; ` +
      `custom on import (\`null\`): **${counts.custom}**`,
    `- The matcher alone (exact, or unambiguous fuzzy >= 0.6) already agrees with the curated id for ` +
      `${counts.matcherAgrees} names; the table overrides ${counts.overrides} confident-but-wrong matcher results; ` +
      `${counts.unmatchedOrAmbiguous} names would be unmatched or tied without the table.`,
    '',
    '| Exported name | Curated | Matcher alone | Why |',
    '|---|---|---|---|',
    ...rows.map(r => `| ${cell(r.name)} | ${cell(curated(r))} | ${matcherText(r.match)} | ${cell(r.reason ?? '(no reason recorded)')} |`),
    '',
    '### Common names left unmatched',
    '',
    ...rows.filter(r => r.id === null).map(r => `- **${r.name}**: ${r.reason ?? '(no reason recorded)'}`),
    '',
    '### Rules',
    '',
    `Same curation policy as Fitbod ([fitbod-alias-review.md](fitbod-alias-review.md), "Rules applied"): equipment ` +
      `and grip must match the ${app.title} name; non-comparable loads are never merged (the odd one out is \`null\`); ` +
      'two names may share one id; timed/cardio moves may map to library cardio entries and keep their duration and ' +
      'distance. Where the same movement exists in the Fitbod table, the same library id is reused.',
    '',
  ]
  return lines.join('\n')
}

export function buildReport() {
  const lib = loadLibrary()
  const parts = [
    '# Strong, Hevy and FitNotes alias review',
    '',
    'Curated decisions behind `ios/GymRollins/Resources/{strong,hevy,fitnotes}-aliases.json`, built from each app\'s ' +
      'default exercise names (not from personal exports). Every common name is listed so the importer never has to ' +
      'fall back to fuzzy suggestions for it.',
    '',
    'Regenerate: `node scripts/other-apps-alias-report.mjs --out docs/import/other-apps-alias-review.md`',
    '',
  ]
  for (const app of APPS) parts.push(section(app, analyze(app, loadAliases(app), lib), lib.byId))
  return parts.join('\n')
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2)
  const outIdx = args.indexOf('--out')
  const out = outIdx >= 0 ? args[outIdx + 1] : null
  if (outIdx >= 0 && !out) { console.error('Usage: other-apps-alias-report.mjs [--out <file.md>]'); process.exit(2) }
  const md = buildReport()
  if (out) {
    writeFileSync(resolve(out), md)
    console.log(`Wrote ${out}`)
  } else {
    console.log(md)
  }
}
