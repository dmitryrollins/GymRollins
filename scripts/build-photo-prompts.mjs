#!/usr/bin/env node
// Builds docs/media/photo-prompts.csv: one image-generation prompt per missing photo (start + end position for every
// library exercise that has neither an own photo nor a free-exercise-db photo), in the catalog style of the first own
// photos (own-0453-*). Generate the images (scripts/generate-photos.mjs saves them as the row's file_name into the
// gitignored media/photos/; photos bundled in ios/GymRollins/Resources/OwnPhotos/ count as done too), then re-run this
// script: done rows drop out.
// Usage: node scripts/build-photo-prompts.mjs   (the CSV is not committed: *.csv is gitignored; re-run to rebuild)
import { existsSync, readdirSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(import.meta.dirname, '..')
const LIBRARY = resolve(ROOT, 'ios/GymRollins/Resources/exercises.json')
const STOCK = resolve(ROOT, 'ios/GymRollins/Resources/exercise-photos.json')
const OWN_DIRS = [resolve(ROOT, 'ios/GymRollins/Resources/OwnPhotos'), resolve(ROOT, 'media/photos')]
const FITBOD_ALIASES = resolve(ROOT, 'ios/GymRollins/Resources/fitbod-aliases.json')
const OWNER_SEED = resolve(ROOT, 'ios/Packages/GymData/Sources/GymData/Seed/OwnerSeed.swift')
const OUT = resolve(ROOT, 'docs/media/photo-prompts.csv')

const STUDIO = 'Professional fitness demonstration photo in a clean catalog style, landscape 3:2 format ' +
  '(1536x1024). Minimal studio set: a plain light-grey concrete wall and a smooth grey concrete floor, soft bright ' +
  'diffused studio lighting from the front and above, gentle soft shadows under the person and equipment, no ' +
  'clutter, no windows, no other equipment than described. The person and the equipment are centered and fully in ' +
  'frame from head to feet, with plain studio space on the left and right, so that a square crop of the center ' +
  'still shows the whole exercise. Camera angle: the side or three-quarter view that shows the movement most ' +
  'clearly. Photorealistic, high detail, sharp focus.'

const MAN = 'The man: athletic, fit build, early 30s, short dark hair, clean-shaven, calm focused expression. He ' +
  'wears a fitted muted-blue athletic t-shirt, dark-grey training joggers, and white training shoes with a red ' +
  'sole accent. If a reference photo of him is attached, match his face, hair, build and clothes exactly.'

const COACH = 'A second person, a coach (a woman in her 30s wearing a plain black t-shirt and black leggings), ' +
  'assists exactly as the steps describe, positioned so she does not hide the exercise.'

const FINISH = 'Correct, safe exercise form. No text, no logos, no brand names, no watermark, no mirrors'

const EQUIPMENT = {
  barbell: 'a chrome Olympic barbell with black rubber bumper plates (and a black steel rack or bench with ' +
    'cognac-brown upholstery only if the exercise needs one)',
  'olympic barbell': 'a chrome Olympic barbell with black rubber bumper plates',
  'ez barbell': 'a chrome EZ curl bar (the zig-zag shaped bar) with a small black weight plate on each end',
  'trap bar': 'a black hexagonal trap bar with black bumper plates',
  dumbbell: 'black hexagonal rubber dumbbells with chrome handles (and a bench with a matte black frame and ' +
    'cognac-brown upholstery only if the exercise needs one)',
  kettlebell: 'a matte black kettlebell',
  cable: 'a cable station with a matte black steel frame, a black weight stack, adjustable pulleys set at the ' +
    'height the exercise needs, black cables and the handle or attachment the exercise needs',
  'leverage machine': 'a strength machine built for this exercise, with a matte black steel frame, a black weight ' +
    'stack or plate horns, and cognac-brown upholstery',
  'sled machine': 'a plate-loaded sled or leg-press machine with a matte black steel frame, black plates and ' +
    'cognac-brown upholstery',
  'smith machine': 'a Smith machine with a matte black steel frame, a chrome guided bar and black plates',
  'body weight': 'no equipment except what the steps mention (a black exercise mat for floor work, or a black ' +
    'steel bar, bench or box with cognac-brown upholstery if the exercise needs one)',
  weighted: 'the extra weight the exercise uses (a black weight plate, a weighted vest or a dip belt), plus a bar, ' +
    'bench or dip station in matte black steel if the exercise needs one',
  band: 'a solid dark-blue resistance band (anchored to a matte black post if the exercise needs an anchor)',
  'resistance band': 'a solid dark-blue loop resistance band',
  'stability ball': 'a matte grey stability ball',
  'bosu ball': 'a grey-and-black half-ball balance trainer',
  'medicine ball': 'a black rubber medicine ball',
  roller: 'a black foam roller',
  'wheel roller': 'a black ab wheel roller',
  rope: 'the rope or strap the exercise uses (a thick black battle rope, a jump rope, a climbing rope, or a black ' +
    'stretching strap)',
  assisted: 'a black exercise mat or bench as the steps need',
  hammer: 'a sledgehammer with a black head',
  tire: 'a large black tractor tire',
}

export function equipmentPhrase(eq) {
  return EQUIPMENT[eq] ?? `a ${eq} with a matte black frame and cognac-brown upholstery where it has any`
}

const FILLER = /^(repeat|continue|switch (legs|sides|arms)|alternate (between|sides|arms|legs)|perform|do this)\b/i

/** The instruction steps worth showing: repetition/alternation filler is dropped. */
export function movementSteps(steps) {
  return steps.map(s => s.trim()).filter(s => s && !FILLER.test(s))
}

const UPPER = new Set(['ez', 'v', 'ab'])
export function displayName(name) {
  return name.split(' ').map(w => (UPPER.has(w.toLowerCase()) ? w.toUpperCase() : w.charAt(0).toUpperCase() + w.slice(1)))
    .join(' ')
}

export const fileName = (id, frame) => `own-${id}-${frame}.jpg`

function exerciseBlock(e) {
  const steps = movementSteps(e.st ?? []).map((s, i) => `${i + 1}) ${s}`).join(' ')
  const partner = e.eq === 'assisted' ? ` ${COACH}` : ''
  return `Equipment: ${equipmentPhrase(e.eq)}.${partner} Exercise: ${displayName(e.n)} (targets the ${e.tg}). ` +
    `How it is performed: ${steps}`
}

function finish(e) {
  return e.eq === 'assisted' ? `${FINISH}, no other people besides the coach.` : `${FINISH}, no other people.`
}

function startPrompt(e) {
  return `${STUDIO} ${MAN} ${exerciseBlock(e)} Show the STARTING position: the setup described in the first ` +
    `step(s), right before the movement begins. ${finish(e)}`
}

function endPrompt(e) {
  return `${STUDIO} Use the attached image (${fileName(e.id, 0)}) as the exact reference: keep the same person, ` +
    `face, hair, clothes, the same equipment in the same place, the same background, lighting, camera position and ` +
    `framing. ${MAN} ${exerciseBlock(e)} Show the END position: the peak of the movement described in the steps ` +
    `(full contraction, full extension or the deepest point of the stretch), before returning to the start. Change ` +
    `only what that position requires. ${finish(e)}`
}

/** Rows for every exercise with no own and no stock photo: start then end, owner-used exercises first. */
export function buildRows(library, { stockPhotoIds, ownPhotoIds, ownerUsedIds }) {
  const missing = library.filter(e => !stockPhotoIds.has(e.id) && !ownPhotoIds.has(e.id))
  const priority = e => (ownerUsedIds.has(e.id) ? 1 : 2)
  missing.sort((a, b) => priority(a) - priority(b) || a.bp.localeCompare(b.bp) || a.n.localeCompare(b.n))
  return missing.flatMap(e => [0, 1].map(frame => ({
    priority: priority(e),
    id: e.id,
    exercise: displayName(e.n),
    body_part: e.bp,
    equipment: e.eq,
    frame,
    position: frame === 0 ? 'start' : 'end',
    file_name: fileName(e.id, frame),
    reference_image: frame === 0 ? '' : fileName(e.id, 0),
    prompt: frame === 0 ? startPrompt(e) : endPrompt(e),
  })))
}

export function csvLine(values) {
  return values.map(v => `"${String(v).replace(/\r?\n/g, ' ').replaceAll('"', '""')}"`).join(',')
}

export function toCSV(rows) {
  if (!rows.length) return ''
  const headers = Object.keys(rows[0])
  return [csvLine(headers), ...rows.map(r => csvLine(headers.map(h => r[h])))].map(l => `${l}\r\n`).join('')
}

function ownPhotoIds() {
  const ids = new Set()
  for (const dir of OWN_DIRS.filter(d => existsSync(d))) {
    for (const name of readdirSync(dir)) {
      const m = /^own-(\d+)-\d+\.jpg$/.exec(name)
      if (m) ids.add(m[1])
    }
  }
  return ids
}

function ownerUsedIds() {
  const aliases = JSON.parse(readFileSync(FITBOD_ALIASES, 'utf8'))
  const seed = readFileSync(OWNER_SEED, 'utf8').match(/"\d{4}"/g) ?? []
  return new Set([...Object.values(aliases).filter(Boolean), ...seed.map(s => s.slice(1, -1))])
}

function main() {
  const library = JSON.parse(readFileSync(LIBRARY, 'utf8'))
  const stock = JSON.parse(readFileSync(STOCK, 'utf8')).photos
  const rows = buildRows(library, {
    stockPhotoIds: new Set(Object.keys(stock)), ownPhotoIds: ownPhotoIds(), ownerUsedIds: ownerUsedIds(),
  })
  mkdirSync(dirname(OUT), { recursive: true })
  writeFileSync(OUT, toCSV(rows))
  const exercises = rows.length / 2
  const first = rows.filter(r => r.priority === 1).length / 2
  console.log(`Wrote ${rows.length} prompts (${exercises} exercises, ${first} you've trained first) to ${OUT}`)
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main()
