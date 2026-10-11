#!/usr/bin/env node
// Builds the bundled exercise library from hasaneyldrm/exercises-dataset (MIT: names, instructions, structure;
// pinned to DATASET_SHA). Its media (images/, videos/) is © Gym visual with no reuse rights and is NEVER emitted.
// Exercise photos come from public-domain yuhonas/free-exercise-db instead (scripts/map-exercise-photos.mjs,
// which must be re-run after rebuilding this library); `Exercise.image`/`gif` stay reserved for own media.
//
// Usage: node scripts/build-exercise-library.mjs [<local data/exercises.json>] [<output>]
//   Without a path it downloads data/exercises.json at DATASET_SHA.
import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

const DATASET_SHA = '7455efae41b330c265e7cd4b78dfa848e7ce5ebd'
const RAW = `https://raw.githubusercontent.com/hasaneyldrm/exercises-dataset/${DATASET_SHA}/data/exercises.json`
const src = process.argv[2]
const out = process.argv[3] ?? resolve(import.meta.dirname, '../ios/GymRollins/Resources/exercises.json')

async function load() {
  if (src) return JSON.parse(readFileSync(src, 'utf8'))
  const res = await fetch(RAW)
  if (!res.ok) throw new Error(`GET ${RAW}: ${res.status}`)
  return res.json()
}

const fix = s => s.replaceAll('в°', '°').trim()
const rows = (await load()).map(e => ({
  id: e.id, n: fix(e.name), bp: e.body_part, eq: e.equipment, tg: e.target,
  ...(e.muscle_group ? { mg: e.muscle_group } : {}),
  sm: e.secondary_muscles ?? [], st: (e.instruction_steps?.en ?? []).map(fix),
}))
if (rows.length < 1300) throw new Error(`Expected ~1324 exercises, got ${rows.length}`)
writeFileSync(out, JSON.stringify(rows))
console.log(`Wrote ${rows.length} exercises to ${out}`)
