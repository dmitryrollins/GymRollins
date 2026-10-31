import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { test } from 'node:test'
import { seedSql, stableUUID } from './gen-equipment-seed.mjs'

const root = resolve(import.meta.dirname, '..')
const read = (name) => JSON.parse(readFileSync(resolve(root, 'ios/GymRollins/Resources', name), 'utf8'))

test('the migration matches the bundled JSON', () => {
  const sql = seedSql(read('equipment-kinds.json').kinds, read('equipment-requirements.json').requirements)
  assert.equal(readFileSync(resolve(root, 'supabase/migrations/20261030000004_equipment_seed.sql'), 'utf8'), sql)
})

test('generic item ids match the phone', () => {
  // Pinned on the Swift side too: GymRepositoryTests.genericItemIdMatchesTheServerSeed.
  assert.equal(stableUUID('6b1f3c2e-8d4a-5e17-9a60-2f4c7d9b1e35', 'dumbbells'), 'cdd9d434-9eca-5d33-8406-2bdea6b4c561')
})

test('quotes survive', () => {
  const sql = seedSql([{ id: 'a', name: "O'Brien", category: 'rack', load: 'none' }], { x: [] })
  assert.match(sql, /'O''Brien'/)
  assert.match(sql, /\('x','\[\]'::jsonb\)/)
})
