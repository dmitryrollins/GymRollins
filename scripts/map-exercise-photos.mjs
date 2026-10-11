#!/usr/bin/env node
// Maps the bundled exercise library to public-domain photos from yuhonas/free-exercise-db (Unlicense, see
// docs/licenses/free-exercise-db.md). Build time only: the app bundles the resulting id -> photo-path JSON and
// loads the JPEGs on demand from a CDN URL pinned to FEDB_SHA.
//
// Conservative on purpose (a wrong photo is worse than none): a library exercise gets photos only when
//   1. a curated alias in scripts/exercise-photo-aliases.json names the upstream entry, or
//   2. its normalized name (word order, plurals, punctuation, "DB"/"BB"/"tricep"… synonyms and equipment words
//      ignored) equals exactly ONE upstream entry's, AND both sides' equipment agrees.
// A `null` alias vetoes an automatic match.
//
// Usage: node scripts/map-exercise-photos.mjs [--fedb <local exercises.json>]
//   Without --fedb it downloads dist/exercises.json at FEDB_SHA. Writes
//   ios/GymRollins/Resources/exercise-photos.json and docs/import/exercise-photo-review.md.
// Tests: node --test scripts/map-exercise-photos.test.mjs
import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

export const FEDB_SHA = 'f00c92c7dcf1216a928a52c3706c7ce8e2f71ed5'
export const FEDB_BASE_URL = `https://cdn.jsdelivr.net/gh/yuhonas/free-exercise-db@${FEDB_SHA}/exercises/`
const FEDB_JSON_URL = `https://raw.githubusercontent.com/yuhonas/free-exercise-db/${FEDB_SHA}/dist/exercises.json`

const ROOT = resolve(import.meta.dirname, '..')
const LIBRARY = resolve(ROOT, 'ios/GymRollins/Resources/exercises.json')
const FITBOD_ALIASES = resolve(ROOT, 'ios/GymRollins/Resources/fitbod-aliases.json')
const OWNER_SEED = resolve(ROOT, 'ios/Packages/GymData/Sources/GymData/Seed/OwnerSeed.swift')
const ALIASES = resolve(ROOT, 'scripts/exercise-photo-aliases.json')
const OUT_JSON = resolve(ROOT, 'ios/GymRollins/Resources/exercise-photos.json')
const OUT_REVIEW = resolve(ROOT, 'docs/import/exercise-photo-review.md')

// --- Normalization ------------------------------------------------------------------------------------------
/** Multi-word phrases joined before tokenizing ("pull down" == "pulldown"). */
const PHRASES = [
  ['pull down', 'pulldown'], ['push down', 'pushdown'], ['push up', 'pushup'], ['pull up', 'pullup'],
  ['chin up', 'chinup'], ['sit up', 'situp'], ['cross over', 'crossover'], ['e z', 'ez'], ['body weight', 'bodyweight'],
]
/** Token synonyms, applied after singularizing. */
const SYNONYMS = {
  db: 'dumbbell', bb: 'barbell', kb: 'kettlebell', flye: 'fly', fly: 'fly', flie: 'fly',
  bicep: 'biceps', tricep: 'triceps', lever: 'leverage', skullcrusher: 'skull crusher',
}
/** Words that only name the equipment: dropped from the name key (equipment is compared separately). */
const EQUIPMENT_WORDS = new Set(['barbell', 'dumbbell', 'cable', 'leverage', 'machine', 'kettlebell', 'band',
  'smith', 'ez', 'bar', 'bodyweight'])

const singular = t => (t.length > 3 && t.endsWith('s') && !t.endsWith('ss') ? t.slice(0, -1) : t)

/** Sorted, de-duplicated, synonym-normalized tokens of a name. */
export function nameTokens(name) {
  let s = ` ${[...name.toLowerCase()].map(c => (/[\p{L}\p{N}]/u.test(c) ? c : ' ')).join('')} `
  s = s.replace(/\s+/g, ' ')
  for (const [from, to] of PHRASES) s = s.replaceAll(` ${from} `, ` ${to} `).replaceAll(` ${from}s `, ` ${to} `)
  const out = s.split(' ').filter(Boolean).map(singular).flatMap(t => (SYNONYMS[t] ?? t).split(' '))
    .map(t => (t === 'bicep' ? 'biceps' : t === 'tricep' ? 'triceps' : t))
  return [...new Set(out)].sort()
}

const OUR_EQUIPMENT = {
  'body weight': 'body', barbell: 'barbell', 'olympic barbell': 'barbell', dumbbell: 'dumbbell', cable: 'cable',
  'leverage machine': 'machine', 'sled machine': 'machine', 'smith machine': 'smith', 'ez barbell': 'ez',
  kettlebell: 'kettlebell', band: 'band', 'resistance band': 'band', 'medicine ball': 'medicine ball',
  'stability ball': 'exercise ball', roller: 'foam roll',
}
const FEDB_EQUIPMENT = {
  'body only': 'body', barbell: 'barbell', dumbbell: 'dumbbell', cable: 'cable', machine: 'machine',
  'e-z curl bar': 'ez', kettlebells: 'kettlebell', bands: 'band', 'medicine ball': 'medicine ball',
  'exercise ball': 'exercise ball', 'foam roll': 'foam roll',
}

/** Our library's equipment, canonical; null = never auto-matched (rare or ambiguous kit). */
export const ourEquipment = eq => OUR_EQUIPMENT[eq] ?? null

/** Upstream equipment, canonical. The name wins for Smith machine and EZ-bar entries (upstream files both under
 *  "machine"/"barbell"); no listed equipment means bodyweight; "other" never auto-matches. */
export function canonicalEquipment(name, equipment) {
  const t = nameTokens(name)
  if (t.includes('smith')) return 'smith'
  if (t.includes('ez')) return 'ez'
  if (equipment === null || equipment === undefined) return 'body'
  return FEDB_EQUIPMENT[equipment] ?? null
}

/** Canonical equipment each equipment word in a name is compatible with ("bar" and "bodyweight" are neutral). */
const WORD_EQUIPMENT = {
  barbell: ['barbell', 'ez'], dumbbell: ['dumbbell'], cable: ['cable'], leverage: ['machine'], machine: ['machine', 'smith'],
  kettlebell: ['kettlebell'], band: ['band'], smith: ['smith'], ez: ['ez'],
}

/** `<equipment>|<sorted name tokens without equipment words>`, or null when a word in the name names other
 *  equipment than `canonEq` (e.g. "lever bent over row" filed under barbell): such entries never auto-match. */
export function matchKey(name, canonEq) {
  const t = nameTokens(name)
  if (t.some(w => WORD_EQUIPMENT[w] && !WORD_EQUIPMENT[w].includes(canonEq))) return null
  return `${canonEq}|${t.filter(w => !EQUIPMENT_WORDS.has(w)).join(' ')}`
}

/** Upstream image paths look like `<Folder_Name>/<n>.jpg`; anything else is dropped. */
export const validPhotoPath = p => typeof p === 'string' && /^[A-Za-z0-9_\-(),'.]+\/[0-9]\.jpg$/.test(p)
  && !p.startsWith('.') && !p.includes('..')

// --- Mapping ------------------------------------------------------------------------------------------------
/**
 * @param library our exercises ({id, n, eq})
 * @param upstream free-exercise-db entries ({id, name, equipment, images})
 * @param aliases {ourId: {fedb: upstreamId|null, why}}
 * @returns {{photos: Record<string,string[]>, decisions: Map<string,{how,fedb,why?}>, ambiguous: object[]}}
 */
export function buildMapping(library, upstream, aliases) {
  const byUpstreamId = new Map(upstream.map(e => [e.id, e]))
  const libraryIds = new Set(library.map(e => e.id))
  for (const [ourId, alias] of Object.entries(aliases)) {
    if (!libraryIds.has(ourId)) throw new Error(`Alias for ${ourId}: not in the library`)
    if (alias.fedb !== null && !byUpstreamId.has(alias.fedb)) throw new Error(`Alias for ${ourId}: unknown upstream ${alias.fedb}`)
  }
  const byKey = new Map()
  for (const e of upstream) {
    const eq = canonicalEquipment(e.name, e.equipment)
    if (!eq) continue
    const key = matchKey(e.name, eq)
    if (!key) continue
    byKey.set(key, [...(byKey.get(key) ?? []), e])
  }
  const photos = {}
  const decisions = new Map()
  const ambiguous = []
  const images = e => {
    const list = (e.images ?? []).filter(validPhotoPath)
    return list.length === (e.images ?? []).length && list.length > 0 ? list : null
  }
  for (const ex of library) {
    const alias = aliases[ex.id]
    if (alias) {
      if (alias.fedb === null) { decisions.set(ex.id, { how: 'veto', fedb: null, why: alias.why }); continue }
      const list = images(byUpstreamId.get(alias.fedb))
      if (list) { photos[ex.id] = list; decisions.set(ex.id, { how: 'alias', fedb: alias.fedb, why: alias.why }) }
      continue
    }
    const eq = ourEquipment(ex.eq)
    if (!eq) continue
    const key = matchKey(ex.n, eq)
    const hits = key ? byKey.get(key) ?? [] : []
    if (hits.length > 1) { ambiguous.push({ ours: ex, hits }); continue }
    if (hits.length === 1) {
      const list = images(hits[0])
      if (list) { photos[ex.id] = list; decisions.set(ex.id, { how: 'auto', fedb: hits[0].id }) }
    }
  }
  return { photos, decisions, ambiguous }
}

// --- Review doc ---------------------------------------------------------------------------------------------
const cell = s => String(s).replaceAll('|', '\\|')
const STAPLE_EQUIPMENT = ['barbell', 'dumbbell', 'cable', 'leverage machine', 'ez barbell', 'smith machine',
  'body weight', 'kettlebell', 'sled machine']
const PER_BODY_PART = 10

function commonIds() {
  const owner = [...readFileSync(OWNER_SEED, 'utf8').matchAll(/ex\("(\d{4})"/g)].map(m => m[1])
  const fitbod = Object.values(JSON.parse(readFileSync(FITBOD_ALIASES, 'utf8'))).filter(Boolean)
  return { owner: [...new Set(owner)], fitbod: [...new Set(fitbod)] }
}

/** "Most common" proxy for unmatched exercises: staple gym equipment, no gendered/versioned/stretch variants,
 *  shortest (most generic) names first, up to PER_BODY_PART per body part. */
function unmatchedSample(library, photos) {
  const pool = library.filter(e => !photos[e.id] && STAPLE_EQUIPMENT.includes(e.eq)
    && !/\((male|female)\)|\bv\. ?\d|stretch/i.test(e.n))
  const byPart = new Map()
  for (const e of pool) byPart.set(e.bp, [...(byPart.get(e.bp) ?? []), e])
  return [...byPart].sort((a, b) => a[0].localeCompare(b[0])).map(([bp, list]) => [bp,
    list.sort((a, b) => a.n.length - b.n.length || a.n.localeCompare(b.n)).slice(0, PER_BODY_PART)])
}

function review(library, upstream, mapping) {
  const { photos, decisions, ambiguous } = mapping
  const byId = new Map(library.map(e => [e.id, e]))
  const upName = new Map(upstream.map(e => [e.id, e.name]))
  const matched = Object.keys(photos).length
  const count = how => [...decisions.values()].filter(d => d.how === how).length
  const { owner, fitbod } = commonIds()
  const line = id => {
    const e = byId.get(id); const d = decisions.get(id)
    const hit = photos[id] ? `\`${d.fedb}\` ${cell(upName.get(d.fedb))}` : '—'
    return `| ${id} | ${cell(e?.n ?? '?')} | ${e?.eq ?? '?'} | ${hit} | ${d?.how ?? 'none'} |`
  }
  const covered = ids => ids.filter(id => photos[id]).length
  const out = [
    '# Exercise photo review',
    '',
    `Generated by \`node scripts/map-exercise-photos.mjs\` from yuhonas/free-exercise-db at \`${FEDB_SHA}\``,
    '(public domain, see `docs/licenses/free-exercise-db.md`). Do not edit by hand: change',
    '`scripts/exercise-photo-aliases.json` and re-run.',
    '',
    `- Library exercises with photos: **${matched} / ${library.length}** (${(100 * matched / library.length).toFixed(1)}%)`,
    `  - automatic (exact normalized name + agreeing equipment): ${count('auto')}`,
    `  - curated alias: ${count('alias')}; vetoed by a \`null\` alias: ${count('veto')}`,
    `- Upstream entries used: ${new Set([...decisions.values()].filter(d => d.fedb).map(d => d.fedb)).size} / ${upstream.length}`,
    `- Owner routine exercises (\`OwnerSeed\`): **${covered(owner)} / ${owner.length}**`,
    `- Fitbod-import exercises (\`fitbod-aliases.json\`): **${covered(fitbod)} / ${fitbod.length}**`,
    `- Ambiguous automatic keys left unmatched: ${ambiguous.length}`,
    '',
    '## Rules',
    '',
    '1. A wrong photo is worse than none. Anything not confidently the same movement stays on the body-part',
    '   illustration.',
    '2. Automatic: word order, plurals, punctuation, "DB/BB/KB", "tricep/bicep", "flye", "pull down" etc. are',
    '   normalized; equipment words are dropped from the name and compared separately — both sides must agree',
    '   (upstream "other" never auto-matches, no listed equipment counts as bodyweight; Smith and EZ-bar are told',
    '   apart by name; an equipment word in a name that contradicts the equipment blocks the match).',
    '   Our library\'s instruction text is not compared: it is less reliable than the names, which identify the',
    '   movement (a manual posture cross-check of the automatic matches found only wording noise).',
    '3. Automatic matches must be unique: if two upstream entries share the key, neither is used.',
    '4. Curated aliases cover near-misses where the movement, equipment and grip are the same and the upstream',
    '   name only adds a default detail (e.g. "- Medium Grip"). Grip/angle/stance variants that change the picture',
    '   (wide vs close grip, incline vs flat, single vs two arm) are not aliased.',
    '',
    '## Owner routine exercises',
    '',
    '| Id | Library name | Equipment | Photo source | How |',
    '|---|---|---|---|---|',
    ...owner.map(line),
    '',
    '## Curated decisions',
    '',
    '| Id | Library name | Upstream | Why |',
    '|---|---|---|---|',
    ...[...decisions].filter(([, d]) => d.how !== 'auto').sort((a, b) => a[0].localeCompare(b[0]))
      .map(([id, d]) => `| ${id} | ${cell(byId.get(id).n)} | ${d.fedb ? `\`${d.fedb}\`` : '**none** (veto)'} | ${cell(d.why)} |`),
    '',
    '## Ambiguous automatic keys (left unmatched)',
    '',
    '| Id | Library name | Upstream candidates |',
    '|---|---|---|',
    ...ambiguous.map(a => `| ${a.ours.id} | ${cell(a.ours.n)} | ${a.hits.map(h => `\`${h.id}\``).join(', ')} |`),
    '',
    '## Unmatched, most common first (by body part)',
    '',
    `Proxy for "common": staple gym equipment (${STAPLE_EQUIPMENT.join(', ')}), no gendered/versioned/stretch`,
    `variants, shortest (most generic) names first, up to ${PER_BODY_PART} per body part. Fitbod-import exercises`,
    'without photos are listed first.',
    '',
    '| Body part | Id | Library name | Equipment |',
    '|---|---|---|---|',
    ...fitbod.filter(id => !photos[id]).map(id => byId.get(id))
      .map(e => `| (Fitbod) ${e.bp} | ${e.id} | ${cell(e.n)} | ${e.eq} |`),
    ...unmatchedSample(library, photos).flatMap(([bp, list]) => list.map(e => `| ${bp} | ${e.id} | ${cell(e.n)} | ${e.eq} |`)),
    '',
  ]
  return out.join('\n')
}

async function loadUpstream(args) {
  const i = args.indexOf('--fedb')
  if (i >= 0) return JSON.parse(readFileSync(resolve(args[i + 1]), 'utf8'))
  const res = await fetch(FEDB_JSON_URL)
  if (!res.ok) throw new Error(`GET ${FEDB_JSON_URL} -> ${res.status}`)
  return res.json()
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const upstream = await loadUpstream(process.argv.slice(2))
  const library = JSON.parse(readFileSync(LIBRARY, 'utf8'))
  const aliases = JSON.parse(readFileSync(ALIASES, 'utf8'))
  delete aliases.$comment
  const mapping = buildMapping(library, upstream, aliases)
  const sorted = Object.fromEntries(Object.entries(mapping.photos).sort((a, b) => a[0].localeCompare(b[0])))
  writeFileSync(OUT_JSON, `${JSON.stringify({ source: 'yuhonas/free-exercise-db', license: 'Unlicense',
    commit: FEDB_SHA, baseURL: FEDB_BASE_URL, photos: sorted })}\n`)
  writeFileSync(OUT_REVIEW, review(library, upstream, mapping))
  console.log(`Mapped ${Object.keys(sorted).length} / ${library.length} exercises -> ${OUT_JSON}`)
}
