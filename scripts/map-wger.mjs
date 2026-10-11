#!/usr/bin/env node
// Maps the bundled exercise library to wger.de exercises (data only, via the public REST API; wger's AGPL code is
// never used) for two things:
//   - photos for exercises that have no own / free-exercise-db photo (ios/GymRollins/Resources/wger-photos.json),
//     loaded on demand from wger's media server, each with its own Creative Commons credit;
//   - names in other languages for search and import matching (ios/GymRollins/Resources/exercise-names-i18n.json).
// Every wger image and translation has its own license and author. Only CC-BY-SA 3/4, CC-BY 4 and CC0 items with a
// named author are used; ODbL items and images wger flags as AI-generated are skipped. See
// docs/plans/2026-09-30-plan-16-wger.md and the generated review docs/import/wger-review.md.
//
// Conservative like scripts/map-exercise-photos.mjs (a wrong photo is worse than none): a library exercise maps to
// wger entries only via a curated alias in scripts/wger-aliases.json (`null` vetoes), or when the normalized English
// names are equal AND the equipment agrees AND the muscles agree.
//
// Usage:
//   node scripts/map-wger.mjs --fetch                 # download a snapshot into media/wger/ (gitignored)
//   node scripts/map-wger.mjs [--snapshot <file>]     # build the JSON resources + review doc from a snapshot
// Tests: node --test scripts/map-wger.test.mjs
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { matchKey, nameTokens, ourEquipment } from './map-exercise-photos.mjs'

export const API = 'https://wger.de/api/v2/'
const WGER_HOST = 'wger.de'
/** wger license ids whose items may be used: CC-BY-SA 3, CC-BY-SA 4, CC0, CC-BY 4 (5 = ODbL is not). */
export const PERMITTED_LICENSES = new Set([1, 2, 3, 4])
/** The app's photo store rejects files above 5 MB; bigger originals use wger's 400 px thumbnail. */
export const MAX_ORIGINAL_BYTES = 4 * 1024 * 1024
export const MAX_PHOTOS = 2

const ROOT = resolve(import.meta.dirname, '..')
const LIBRARY = resolve(ROOT, 'ios/GymRollins/Resources/exercises.json')
const FEDB_PHOTOS = resolve(ROOT, 'ios/GymRollins/Resources/exercise-photos.json')
const OWN_PHOTOS = resolve(ROOT, 'ios/GymRollins/Resources/OwnPhotos')
const OWNER_SEED = resolve(ROOT, 'ios/Packages/GymData/Sources/GymData/Seed/OwnerSeed.swift')
const ALIASES = resolve(ROOT, 'scripts/wger-aliases.json')
const IMAGE_POLICY = resolve(ROOT, 'scripts/wger-image-policy.json')
const NAME_VETOES = resolve(ROOT, 'scripts/wger-name-vetoes.json')
const SNAPSHOT_DIR = resolve(ROOT, 'media/wger')
const OUT_PHOTOS = resolve(ROOT, 'ios/GymRollins/Resources/wger-photos.json')
const OUT_NAMES = resolve(ROOT, 'ios/GymRollins/Resources/exercise-names-i18n.json')
const OUT_REVIEW = resolve(ROOT, 'docs/import/wger-review.md')

// --- Item filters -------------------------------------------------------------------------------------------
const hasAuthor = a => typeof a === 'string' && a.trim().length > 0

export function isWgerMediaURL(value) {
  if (typeof value !== 'string') return false
  try {
    const url = new URL(value)
    return url.protocol === 'https:' && url.hostname === WGER_HOST && url.pathname.startsWith('/media/')
  } catch { return false }
}

/** An image we may show: permitted license, a named author, not AI-generated, https on wger.de — and, with a
 *  provenance `policy` ({trustedAuthors: {name: why}, allowedImages: {imageId: why}}), a trusted author or an
 *  individually reviewed image. The policy exists because a visual review of the license-clean uploads found
 *  commercial images re-uploaded under CC licenses (a HOIST © notice, weighttraining.guide watermarks, StrengthLog
 *  branding, unflagged AI art); see docs/import/wger-review.md. */
export function usableImage(i, policy = null) {
  if (!PERMITTED_LICENSES.has(i.license) || !hasAuthor(i.author) || i.ai === true || !isWgerMediaURL(i.url)) return false
  if (!policy) return true
  return Object.hasOwn(policy.trustedAuthors ?? {}, i.author.trim()) || Object.hasOwn(policy.allowedImages ?? {}, String(i.id))
}

/** A translation (name) we may use: permitted license, a named author, a non-empty name. */
export const usableTranslation = t => PERMITTED_LICENSES.has(t.license) && hasAuthor(t.author)
  && typeof t.name === 'string' && t.name.trim().length > 0

// --- Snapshot -----------------------------------------------------------------------------------------------
/** Reduces raw API payloads to what the mapper needs (no descriptions), sorted by exercise id. */
export function trimSnapshot({ exercises, licenses, languages, version, fetchedAt, sizes = {} }) {
  return {
    fetchedAt,
    apiVersion: version,
    licenses: Object.fromEntries(licenses.map(l => [l.id, { short: l.short_name, url: l.url }])),
    languages: Object.fromEntries(languages.map(l => [l.id, l.short_name])),
    exercises: [...exercises].sort((a, b) => a.id - b.id).map(e => ({
      id: e.id,
      equipment: (e.equipment ?? []).map(q => q.name),
      muscles: (e.muscles ?? []).map(m => m.id),
      musclesSecondary: (e.muscles_secondary ?? []).map(m => m.id),
      translations: (e.translations ?? []).map(t => ({
        lang: t.language, name: t.name, aliases: (t.aliases ?? []).map(a => a.alias ?? a).filter(a => typeof a === 'string'),
        license: t.license, author: t.license_author,
      })),
      images: (e.images ?? []).map(i => ({
        id: i.id, url: i.image, thumb: i.thumbnails?.medium ?? null, isMain: i.is_main === true, style: i.style,
        license: i.license, author: i.license_author, ai: i.is_ai_generated === true, bytes: sizes[i.image] ?? null,
      })),
    })),
  }
}

const englishId = snapshot => Number(Object.entries(snapshot.languages).find(([, code]) => code === 'en')?.[0] ?? 2)
const englishName = (e, snapshot) => e.translations.find(t => t.lang === englishId(snapshot))?.name ?? null

// --- Equipment and muscles ----------------------------------------------------------------------------------
const LISTED_EQUIPMENT = {
  Barbell: 'barbell', 'SZ-Bar': 'ez', Dumbbell: 'dumbbell', Kettlebell: 'kettlebell', 'Cable machine': 'cable',
  'Resistance band': 'band', 'Swiss Ball': 'exercise ball', 'none (bodyweight exercise)': 'body',
}
const NAME_EQUIPMENT = {
  barbell: 'barbell', dumbbell: 'dumbbell', cable: 'cable', kettlebell: 'kettlebell', band: 'band', smith: 'smith',
  ez: 'ez', machine: 'machine', leverage: 'machine',
}

/** Canonical equipment of a wger exercise (listed kit + equipment words in its English name): one kind, 'unknown'
 *  (only neutral kit such as a bench, mat or pull-up bar), or null (two kinds: ambiguous, never auto-matched). */
export function wgerEquipment(e, snapshot = { languages: { 2: 'en' } }) {
  const kinds = new Set(e.equipment.map(q => LISTED_EQUIPMENT[q]).filter(Boolean))
  for (const t of nameTokens(englishName(e, snapshot) ?? '')) if (NAME_EQUIPMENT[t]) kinds.add(NAME_EQUIPMENT[t])
  if (kinds.has('smith')) { kinds.delete('machine'); kinds.delete('barbell') }
  if (kinds.has('ez')) kinds.delete('barbell')
  if (kinds.has('cable')) kinds.delete('machine')
  if (kinds.size === 0) return 'unknown'
  return kinds.size === 1 ? [...kinds][0] : null
}

/** Our muscle words -> wger muscle ids (2 delts, 1 biceps, 11 hamstrings, 13 brachialis, 7 calves, 8 glutes,
 *  12 lats, 14 obliques, 4 chest, 10 quads, 6 abs, 3 serratus, 15 soleus, 9 trapezius, 5 triceps). */
const MUSCLES = {
  pectorals: [4], chest: [4], 'upper chest': [4], biceps: [1, 13], brachialis: [13], glutes: [8],
  delts: [2], shoulders: [2], deltoids: [2], 'rear deltoids': [2], triceps: [5], 'upper back': [12, 9], back: [12, 9],
  rhomboids: [9], lats: [12], 'latissimus dorsi': [12], calves: [7, 15], soleus: [15], quads: [10], quadriceps: [10],
  hamstrings: [11], abs: [6, 14], abdominals: [6, 14], core: [6, 14], 'lower abs': [6], obliques: [14],
  traps: [9], trapezius: [9], 'serratus anterior': [3],
}

/** True when any of our target/secondary muscles is among wger's primary/secondary muscles. */
export function musclesAgree(ours, e) {
  const mine = new Set([ours.tg, ...(ours.sm ?? [])].flatMap(m => MUSCLES[m] ?? []))
  return [...e.muscles, ...e.musclesSecondary].some(m => mine.has(m))
}

// --- Mapping ------------------------------------------------------------------------------------------------
function validateAliases(library, snapshot, aliases) {
  const libraryIds = new Set(library.map(e => e.id))
  const wgerIds = new Set(snapshot.exercises.map(e => e.id))
  for (const [ourId, alias] of Object.entries(aliases)) {
    if (!libraryIds.has(ourId)) throw new Error(`Alias for ${ourId}: not in the library`)
    if (alias.wger !== null && (!Array.isArray(alias.wger) || alias.wger.length === 0
      || alias.wger.some(id => !wgerIds.has(id)))) throw new Error(`Alias for ${ourId}: unknown wger id in ${JSON.stringify(alias.wger)}`)
    if (typeof alias.why !== 'string' || !alias.why.trim()) throw new Error(`Alias for ${ourId}: missing why`)
  }
}

/**
 * @returns {{matches: Map<string,{how:'auto'|'alias'|'veto', wger:number[], why?:string}>,
 *            dropped: {wger:number, ours:string[]}[], rejected: {ours:string, wger:number}[]}}
 */
export function buildWgerMapping(library, snapshot, aliases) {
  validateAliases(library, snapshot, aliases)
  const byKey = new Map()
  for (const e of snapshot.exercises) {
    const name = englishName(e, snapshot)
    const eq = name && wgerEquipment(e, snapshot)
    if (!eq) continue
    for (const canon of eq === 'unknown' ? ['body', 'machine'] : [eq]) {
      const key = matchKey(name, canon)
      if (key) byKey.set(key, [...(byKey.get(key) ?? []), e])
    }
  }
  const matches = new Map()
  const rejected = []
  const autoEquipment = new Map() // wger id -> Map(canonical equipment -> our ids)
  for (const ex of library) {
    const alias = aliases[ex.id]
    if (alias) {
      matches.set(ex.id, alias.wger === null ? { how: 'veto', wger: [], why: alias.why }
        : { how: 'alias', wger: [...alias.wger], why: alias.why })
      continue
    }
    const eq = ourEquipment(ex.eq)
    const key = eq && matchKey(ex.n, eq)
    const hits = key ? byKey.get(key) ?? [] : []
    const agreeing = hits.filter(e => musclesAgree(ex, e))
    for (const e of hits) if (!agreeing.includes(e)) rejected.push({ ours: ex.id, wger: e.id })
    if (!agreeing.length) continue
    matches.set(ex.id, { how: 'auto', wger: agreeing.map(e => e.id) })
    for (const e of agreeing) {
      const perEq = autoEquipment.get(e.id) ?? new Map()
      perEq.set(eq, [...(perEq.get(eq) ?? []), ex.id])
      autoEquipment.set(e.id, perEq)
    }
  }
  // A wger entry with unknown equipment can't picture both our body-weight and our machine version.
  const dropped = []
  for (const [wgerId, perEq] of autoEquipment) {
    if (perEq.size < 2) continue
    const ours = [...perEq.values()].flat()
    dropped.push({ wger: wgerId, ours })
    for (const id of ours) {
      const rest = matches.get(id).wger.filter(w => w !== wgerId)
      if (rest.length) matches.set(id, { how: 'auto', wger: rest }); else matches.delete(id)
    }
  }
  return { matches, dropped, rejected }
}

// --- Outputs ------------------------------------------------------------------------------------------------
export const sourceURL = id => `https://wger.de/exercise/${id}/view-base`

function imageURL(i) {
  if (typeof i.bytes === 'number' && i.bytes > 0 && i.bytes <= MAX_ORIGINAL_BYTES) return i.url
  return isWgerMediaURL(i.thumb) ? i.thumb : null
}

/** Up to two credited photos from the first of `entries` that has usable images: its main image first, then
 *  another image by the same author under the same license (so one caption covers both). */
export function photoEntries(entries, snapshot, policy) {
  for (const e of entries) {
    const usable = e.images.filter(i => usableImage(i, policy) && imageURL(i))
      .sort((a, b) => Number(b.isMain) - Number(a.isMain) || a.id - b.id)
    if (!usable.length) continue
    const [first] = usable
    const picked = [first, ...usable.slice(1).filter(i => i.author.trim() === first.author.trim()
      && i.license === first.license)].slice(0, MAX_PHOTOS)
    const license = snapshot.licenses[first.license]
    return picked.map(i => ({
      url: imageURL(i), title: englishName(e, snapshot) ?? `wger exercise ${e.id}`, author: i.author.trim(),
      license: license.short, licenseUrl: license.url, sourceUrl: sourceURL(e.id), modified: true,
    }))
  }
  return []
}

const byIds = snapshot => new Map(snapshot.exercises.map(e => [e.id, e]))
const sortedObject = entries => Object.fromEntries([...entries].sort((a, b) => a[0].localeCompare(b[0])))

/** ourId -> credited photos, for every match with usable images. */
export function buildPhotos(matches, snapshot, policy) {
  const index = byIds(snapshot)
  const out = []
  for (const [ourId, m] of matches) {
    const photos = photoEntries(m.wger.map(id => index.get(id)), snapshot, policy)
    if (photos.length) out.push([ourId, photos])
  }
  return sortedObject(out)
}

const nameKey = s => s.trim().toLocaleLowerCase('en').replace(/\s+/g, ' ')
/** Same as the app's `ExerciseMatcher.normalize` (lowercase, non-letters/digits -> spaces, collapsed): the key
 *  imports are resolved by, so collisions are detected on exactly what the app compares. */
export const importKey = s => s.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim()

/** ourId -> {names: {lang: [{n, a, l, w, s?}]}, sources}: licensed non-English names and aliases (w = the wger entry
 *  the name comes from; s = search-only, because wger also uses the name for an exercise outside this match, so it
 *  must not resolve imports automatically), deduplicated per language, minus curated `vetoes` ({ourId: {name: why}}: mistranslations
 *  found in review). `sources` links every wger entry that contributed a name, for the credit. */
export function buildNames(matches, snapshot, vetoes = {}) {
  const index = byIds(snapshot)
  const en = englishId(snapshot)
  const out = []
  const vetoUsed = new Set()
  for (const [ourId, perName] of Object.entries(vetoes)) {
    for (const [name, why] of Object.entries(perName)) {
      if (typeof why !== 'string' || !why.trim()) throw new Error(`Name veto ${ourId} "${name}": missing why`)
    }
  }
  // Every name (any language, English included) -> the wger entries using it, across the whole snapshot.
  const users = new Map()
  for (const e of snapshot.exercises) {
    for (const t of e.translations) {
      for (const n of [t.name, ...t.aliases]) {
        if (typeof n !== 'string' || !n.trim()) continue
        users.set(importKey(n), new Set([...(users.get(importKey(n)) ?? []), e.id]))
      }
    }
  }
  for (const [ourId, m] of matches) {
    const names = {}
    const seen = new Set()
    const sources = []
    const own = new Set(m.wger)
    const vetoed = new Set(Object.keys(vetoes[ourId] ?? {}).map(nameKey))
    for (const e of m.wger.map(id => index.get(id))) {
      for (const t of e.translations) {
        const lang = snapshot.languages[t.lang]
        if (t.lang === en || !lang || !usableTranslation(t)) continue
        const license = snapshot.licenses[t.license]?.short
        for (const n of [t.name, ...t.aliases].map(s => s.trim()).filter(Boolean)) {
          const key = `${lang}|${nameKey(n)}`
          if (seen.has(key)) continue
          seen.add(key)
          if (vetoed.has(nameKey(n))) { vetoUsed.add(`${ourId}|${nameKey(n)}`); continue }
          const shared = [...(users.get(importKey(n)) ?? [])].some(id => !own.has(id))
          const entry = { n, a: t.author.trim(), l: license, w: e.id, ...(shared ? { s: true } : {}) }
          names[lang] = [...(names[lang] ?? []), entry]
          if (!sources.includes(e.id)) sources.push(e.id)
        }
      }
    }
    if (Object.keys(names).length) {
      out.push([ourId, { names: sortedObject(Object.entries(names)), sources: sources.map(sourceURL) }])
    }
  }
  for (const [ourId, perName] of Object.entries(vetoes)) {
    for (const name of Object.keys(perName)) {
      if (!vetoUsed.has(`${ourId}|${nameKey(name)}`)) throw new Error(`Name veto ${ourId} "${name}": not a generated name`)
    }
  }
  return sortedObject(out)
}

// --- Fetch --------------------------------------------------------------------------------------------------
async function getJSON(url, fetchImpl) {
  const parsed = new URL(url)
  if (parsed.protocol !== 'https:' || parsed.hostname !== WGER_HOST) throw new Error(`Refusing to fetch ${url}`)
  const res = await fetchImpl(url, { headers: { accept: 'application/json' } })
  if (!res.ok) throw new Error(`GET ${url} -> ${res.status}`)
  return res.json()
}

async function getAll(url, fetchImpl) {
  const out = []
  for (let next = url; next;) {
    const page = await getJSON(next, fetchImpl)
    out.push(...page.results)
    next = page.next
  }
  return out
}

async function imageSizes(urls, fetchImpl, concurrency = 8) {
  const sizes = {}
  const queue = [...urls]
  await Promise.all(Array.from({ length: concurrency }, async () => {
    for (let url; (url = queue.shift());) {
      const res = await fetchImpl(url, { method: 'HEAD' })
      const length = Number(res.headers.get('content-length'))
      if (res.ok && Number.isFinite(length) && length > 0) sizes[url] = length
    }
  }))
  return sizes
}

export async function fetchSnapshot(fetchImpl = fetch, now = new Date()) {
  const version = await getJSON(`${API}version/`, fetchImpl)
  const licenses = await getAll(`${API}license/?limit=100`, fetchImpl)
  const languages = await getAll(`${API}language/?limit=100`, fetchImpl)
  const exercises = await getAll(`${API}exerciseinfo/?limit=200`, fetchImpl)
  const urls = exercises.flatMap(e => e.images ?? []).map(i => i.image).filter(isWgerMediaURL)
  const sizes = await imageSizes(urls, fetchImpl)
  return trimSnapshot({ exercises, licenses, languages, version, fetchedAt: now.toISOString().slice(0, 10), sizes })
}

// --- Review doc ---------------------------------------------------------------------------------------------
const cell = s => String(s).replaceAll('|', '\\|')

function ownerIds() {
  return [...new Set([...readFileSync(OWNER_SEED, 'utf8').matchAll(/ex\("(\d{4})"/g)].map(m => m[1]))]
}

function existingPhotoIds() {
  const fedb = new Set(Object.keys(JSON.parse(readFileSync(FEDB_PHOTOS, 'utf8')).photos))
  const own = new Set(existsSync(OWN_PHOTOS) ? readdirSync(OWN_PHOTOS)
    .map(f => /^own-(\d+)-\d+\.jpg$/.exec(f)?.[1]).filter(Boolean) : [])
  return { fedb, own }
}

/** Throws unless every trusted author / reviewed image has a reason and every reviewed image id exists. */
export function validatePolicy(policy, snapshot) {
  const imageIds = new Set(snapshot.exercises.flatMap(e => e.images.map(i => String(i.id))))
  for (const [key, why] of [...Object.entries(policy.trustedAuthors ?? {}), ...Object.entries(policy.allowedImages ?? {})]) {
    if (typeof why !== 'string' || !why.trim()) throw new Error(`Image policy entry ${key}: missing why`)
  }
  for (const id of Object.keys(policy.allowedImages ?? {})) {
    if (!imageIds.has(id)) throw new Error(`Image policy: unknown wger image ${id}`)
  }
}

export function review({ library, snapshot, mapping, photos, names, snapshotSha, owner, existing, policy, nameVetoes = {} }) {
  const byId = new Map(library.map(e => [e.id, e]))
  const index = byIds(snapshot)
  const { matches, dropped, rejected } = mapping
  const count = how => [...matches.values()].filter(m => m.how === how).length
  const hasOther = id => existing.own.has(id) || existing.fedb.has(id)
  const gained = Object.keys(photos).filter(id => !hasOther(id))
  const usedImages = Object.values(photos).flat()
  const tally = list => Object.entries(list.reduce((acc, k) => ({ ...acc, [k]: (acc[k] ?? 0) + 1 }), {}))
    .sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k} ${v}`).join(', ')
  const nameList = Object.values(names).flatMap(x => Object.entries(x.names).flatMap(([lang, l]) => l.map(n => ({ lang, ...n }))))
  const allImages = snapshot.exercises.flatMap(e => e.images)
  const reasons = {
    'ODbL / unknown license': allImages.filter(i => !PERMITTED_LICENSES.has(i.license)).length,
    'no author': allImages.filter(i => PERMITTED_LICENSES.has(i.license) && !hasAuthor(i.author)).length,
    'AI-generated upstream': allImages.filter(i => PERMITTED_LICENSES.has(i.license) && hasAuthor(i.author) && i.ai).length,
    'unreviewed uploader (provenance)': allImages.filter(i => usableImage(i) && !usableImage(i, policy)).length,
  }
  const mappedWger = new Set([...matches.values()].flatMap(m => m.wger))
  const unmatchedWithImages = snapshot.exercises.filter(e => !mappedWger.has(e.id) && e.images.some(i => usableImage(i, policy)))
  const ownerRow = id => {
    const e = byId.get(id)
    const src = existing.own.has(id) ? 'own' : existing.fedb.has(id) ? 'free-exercise-db' : photos[id] ? '**wger**' : 'illustration'
    const langs = names[id] ? Object.keys(names[id].names).length : 0
    const m = matches.get(id)
    return `| ${id} | ${cell(e.n)} | ${src} | ${photos[id] ? 'yes' : '—'} | ${langs || '—'} | ${m ? `${m.how} ${m.wger.join(', ')}` : '—'} |`
  }
  const ownerGain = owner.filter(id => photos[id] || names[id]).length
  return [
    '# wger mapping review',
    '',
    `Generated by \`node scripts/map-wger.mjs\` from a wger.de API snapshot of **${snapshot.fetchedAt}** (server/API`,
    `version \`${snapshot.apiVersion}\`, snapshot sha256 \`${snapshotSha}\`). Data only; wger's AGPL code is not used.`,
    'Do not edit by hand: change `scripts/wger-aliases.json` and re-run. Plan: `docs/plans/2026-09-30-plan-16-wger.md`.',
    '',
    '## Counts',
    '',
    `- wger exercises in the snapshot: ${snapshot.exercises.length}; with at least one usable image: ${snapshot.exercises.filter(e => e.images.some(i => usableImage(i, policy))).length}`,
    `- Library exercises matched: **${count('auto') + count('alias')} / ${library.length}** (automatic ${count('auto')}, curated alias ${count('alias')}; vetoed ${count('veto')})`,
    `- Library exercises with wger photos: **${Object.keys(photos).length}**; of those, **${gained.length}** had no own or free-exercise-db photo (new photos)`,
    `- Images used: ${usedImages.length} (by license: ${tally(usedImages.map(p => p.license))}); 400 px thumbnails for oversized originals: ${usedImages.filter(p => p.url.includes('.400x400_')).length}`,
    `- Images skipped upstream: ${Object.entries(reasons).map(([k, v]) => `${k} ${v}`).join(', ')}`,
    `- Library exercises with other-language names: **${Object.keys(names).length}**; ${nameList.length} names in ${new Set(nameList.map(n => n.lang)).size} languages`,
    `  - by language: ${tally(nameList.map(n => n.lang))}`,
    `  - by license: ${tally(nameList.map(n => n.l))}`,
    `- Owner routine exercises (\`OwnerSeed\`) that gain a wger photo or names: **${ownerGain} / ${owner.length}**`,
    '',
    '## Rules',
    '',
    '1. Licenses: CC-BY-SA 3, CC-BY-SA 4, CC-BY 4 and CC0 items with a named author only. ODbL items, items without an',
    '   author and images wger flags as AI-generated are skipped. Every photo carries title, author, license, links and',
    '   "modified" (the app resizes/crops it for display).',
    '2. Automatic match: equal normalized English name key (as in `scripts/map-exercise-photos.mjs`) + agreeing',
    '   equipment (wger kit list + equipment words in the name; bench/mat/pull-up bar only = unknown = body weight or',
    '   machine) + agreeing muscles (our target/secondary vs wger primary/secondary). Several wger entries with the same',
    '   key are duplicates and are merged; a wger entry hit by our exercises with different equipment is dropped.',
    '3. Curated aliases cover the same movement under a different name; grip/angle/stance variants that change the',
    '   picture are not aliased.',
    '4. Photos: at most two per exercise — the main image, then another by the same author and license.',
    '   Photos have a white backing in the app (the Everkinetic drawings are dark lines on transparency).',
    '5. Provider order in the app: own → free-exercise-db → **wger** → illustration (wger only fills gaps).',
    '',
    '## Image provenance',
    '',
    'wger accepts uploads from anyone, and the uploader picks the license. A visual review of every license-clean image',
    'the name matcher selected (2026-09-30) found re-uploaded commercial material: a "© HOIST Fitness Systems" notice,',
    'weighttraining.guide watermarks, StrengthLog branding, Fitness-Programmer-style 3D renders from many different',
    'uploaders, and AI art not flagged as AI. A CC license granted by someone who does not own the image is void, so',
    'only images from trusted authors, or individually reviewed images, are used (`scripts/wger-image-policy.json`):',
    '',
    ...Object.entries(policy.trustedAuthors ?? {}).map(([a, why]) => `- author **${cell(a)}**: ${cell(why)}`),
    ...Object.entries(policy.allowedImages ?? {}).map(([id, why]) => `- image ${id}: ${cell(why)}`),
    '',
    '## Owner routine exercises',
    '',
    '| Id | Library name | Shown photo | wger photo | Name languages | Match |',
    '|---|---|---|---|---|---|',
    ...owner.map(ownerRow),
    '',
    '## New photos (no own or free-exercise-db photo before)',
    '',
    '| Id | Library name | wger exercise | Author · License |',
    '|---|---|---|---|',
    ...gained.map(id => `| ${id} | ${cell(byId.get(id).n)} | ${cell(photos[id][0].title)} (${photos[id][0].sourceUrl}) | ${cell(photos[id][0].author)} · ${photos[id][0].license} |`),
    '',
    '## Curated decisions',
    '',
    '| Id | Library name | wger | Why |',
    '|---|---|---|---|',
    ...[...matches].filter(([, m]) => m.how !== 'auto').sort((a, b) => a[0].localeCompare(b[0]))
      .map(([id, m]) => `| ${id} | ${cell(byId.get(id).n)} | ${m.wger.length ? m.wger.map(w => `${w} ${cell(englishName(index.get(w), snapshot))}`).join('; ') : '**none** (veto)'} | ${cell(m.why)} |`),
    '',
    '## Names left out (mistranslations and over-generic names, `scripts/wger-name-vetoes.json`)',
    '',
    'Other-language names resolve imported exercises automatically, so a wrong or generic translation would file',
    'workout history under the wrong exercise. Every generated name was read through (2026-09-30); these are vetoed:',
    '',
    '| Id | Library name | Name | Why |',
    '|---|---|---|---|',
    ...Object.entries(nameVetoes).flatMap(([id, per]) => Object.entries(per)
      .map(([n, why]) => `| ${id} | ${cell(byId.get(id).n)} | ${cell(n)} | ${cell(why)} |`)),
    '',
    '## Automatic matches',
    '',
    '| Id | Library name | wger |',
    '|---|---|---|',
    ...[...matches].filter(([, m]) => m.how === 'auto').sort((a, b) => a[0].localeCompare(b[0]))
      .map(([id, m]) => `| ${id} | ${cell(byId.get(id).n)} | ${m.wger.map(w => `${w} ${cell(englishName(index.get(w), snapshot))}`).join('; ')} |`),
    '',
    '## Left out automatically',
    '',
    ...(dropped.length ? dropped.map(d => `- wger ${d.wger} ${cell(englishName(index.get(d.wger), snapshot))}: unknown equipment, matched by ${d.ours.join(', ')} (different equipment)`) : ['- none (equipment conflicts)']),
    ...(rejected.length ? rejected.map(r => `- ${r.ours} ${cell(byId.get(r.ours).n)} ≠ wger ${r.wger} ${cell(englishName(index.get(r.wger), snapshot))}: muscles disagree`) : ['- none (muscle conflicts)']),
    '',
    '## Unmatched wger exercises with usable images (sample)',
    '',
    '| wger | English name | Equipment |',
    '|---|---|---|',
    ...unmatchedWithImages.slice(0, 60).map(e => `| ${e.id} | ${cell(englishName(e, snapshot) ?? '?')} | ${cell(e.equipment.join(', ') || '—')} |`),
    '',
  ].join('\n')
}

// --- CLI ----------------------------------------------------------------------------------------------------
function latestSnapshot() {
  const files = existsSync(SNAPSHOT_DIR) ? readdirSync(SNAPSHOT_DIR).filter(f => /^snapshot-.*\.json$/.test(f)).sort() : []
  if (!files.length) throw new Error(`No snapshot in ${SNAPSHOT_DIR}; run with --fetch first`)
  return resolve(SNAPSHOT_DIR, files.at(-1))
}

async function main(args) {
  if (args.includes('--fetch')) {
    const snapshot = await fetchSnapshot()
    const file = resolve(SNAPSHOT_DIR, `snapshot-${snapshot.fetchedAt}.json`)
    mkdirSync(dirname(file), { recursive: true })
    const text = `${JSON.stringify(snapshot)}\n`
    writeFileSync(file, text)
    console.log(`Snapshot: ${file} (${snapshot.exercises.length} exercises, sha256 ${createHash('sha256').update(text).digest('hex')})`)
    return
  }
  const i = args.indexOf('--snapshot')
  const file = i >= 0 ? resolve(args[i + 1]) : latestSnapshot()
  const text = readFileSync(file, 'utf8')
  const snapshot = JSON.parse(text)
  const snapshotSha = createHash('sha256').update(text).digest('hex')
  const library = JSON.parse(readFileSync(LIBRARY, 'utf8'))
  const aliases = JSON.parse(readFileSync(ALIASES, 'utf8'))
  delete aliases.$comment
  const policy = JSON.parse(readFileSync(IMAGE_POLICY, 'utf8'))
  validatePolicy(policy, snapshot)
  const mapping = buildWgerMapping(library, snapshot, aliases)
  const photos = buildPhotos(mapping.matches, snapshot, policy)
  const nameVetoes = JSON.parse(readFileSync(NAME_VETOES, 'utf8'))
  delete nameVetoes.$comment
  const names = buildNames(mapping.matches, snapshot, nameVetoes)
  const meta = { source: 'wger.de', snapshot: snapshot.fetchedAt, apiVersion: snapshot.apiVersion }
  writeFileSync(OUT_PHOTOS, `${JSON.stringify({ ...meta, photos })}\n`)
  writeFileSync(OUT_NAMES, `${JSON.stringify({ ...meta, exercises: names })}\n`)
  writeFileSync(OUT_REVIEW, review({ library, snapshot, mapping, photos, names, snapshotSha, owner: ownerIds(),
    existing: existingPhotoIds(), policy, nameVetoes }))
  console.log(`wger: ${Object.keys(photos).length} exercises with photos, ${Object.keys(names).length} with other names`)
}

if (import.meta.url === `file://${process.argv[1]}`) await main(process.argv.slice(2))
