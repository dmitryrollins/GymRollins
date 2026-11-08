import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { test } from 'node:test'
import { seedD1, stableUUID } from './gen-equipment-seed.mjs'

const root = resolve(import.meta.dirname, '..')
const read = (name) => JSON.parse(readFileSync(resolve(root, 'ios/GymRollins/Resources', name), 'utf8'))

test('generic item ids match the phone', () => {
  // Pinned on the Swift side too: GymRepositoryTests.genericItemIdMatchesTheServerSeed.
  assert.equal(stableUUID('6b1f3c2e-8d4a-5e17-9a60-2f4c7d9b1e35', 'dumbbells'), 'cdd9d434-9eca-5d33-8406-2bdea6b4c561')
})

test('the D1 seed matches the bundled JSON', () => {
  const sql = seedD1(read('equipment-kinds.json').kinds, read('equipment-requirements.json').requirements)
  assert.equal(readFileSync(resolve(root, 'server/migrations/0004_seed_equipment.sql'), 'utf8'), sql)
})

test('D1 statements hold at most 100 rows, and quotes survive', () => {
  const kinds = Array.from({ length: 101 }, (_, i) => ({
    id: `k${i}`, name: i === 0 ? "O'Brien" : `Kind ${i}`, category: 'rack', load: 'none',
  }))
  const sql = seedD1(kinds, { x: [] })
  assert.equal(sql.match(/INSERT INTO equipment_kinds/g).length, 2)
  assert.match(sql, /'O''Brien'/)
  assert.match(sql, /\('x','\[\]','2026-10-30T00:00:00\.000000Z'\)/)
})
