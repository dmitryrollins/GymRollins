import { describe, expect, it } from 'vitest'
import { type Column, RowError, storedRow, storedValue, wireRow, wireValue } from '../src/sync/columns.ts'

const col = (kind: Column['kind'], extra: Partial<Column> = {}): Column => ({ name: 'x', kind, ...extra })
const stored = (column: Column, raw: unknown) => storedValue(column, raw, 'rows[0]')

describe('storedValue', () => {
  it('lowercases UUIDs and refuses anything else', () => {
    expect(stored(col('uuid'), 'A1B2C3D4-0000-4000-8000-00000000000F')).toBe('a1b2c3d4-0000-4000-8000-00000000000f')
    expect(() => stored(col('uuid'), 'not-a-uuid')).toThrow(RowError)
  })

  it('stores booleans as 1 and 0', () => {
    expect(stored(col('bool'), true)).toBe(1)
    expect(stored(col('bool'), false)).toBe(0)
    expect(() => stored(col('bool'), 1)).toThrow('rows[0].x is not a valid bool')
  })

  it('keeps integers whole and reals finite', () => {
    expect(stored(col('int'), 3)).toBe(3)
    expect(() => stored(col('int'), 2.5)).toThrow(RowError)
    expect(() => stored(col('int'), '3')).toThrow(RowError)
    expect(stored(col('real'), 2.5)).toBe(2.5)
    expect(() => stored(col('real'), '2.5')).toThrow(RowError)
  })

  it('stores JSON as text', () => {
    expect(stored(col('json'), [1, { a: 2 }])).toBe('[1,{"a":2}]')
    expect(() => stored(col('json'), 'text')).toThrow(RowError)
  })

  it('normalises timestamps, and takes dates as real YYYY-MM-DD days only', () => {
    expect(stored(col('ts'), '2026-11-07T10:00:00Z')).toBe('2026-11-07T10:00:00.000000Z')
    expect(() => stored(col('ts'), '2026-11-07')).toThrow('rows[0].x is not a valid ts')
    expect(stored(col('date'), '2026-12-31')).toBe('2026-12-31')
    expect(() => stored(col('date'), '2026-12-31T00:00:00Z')).toThrow(RowError)
    expect(() => stored(col('date'), '2026-13-45')).toThrow(RowError)
    expect(() => stored(col('date'), '2026-02-30')).toThrow(RowError)
  })

  it('treats a missing or null value by the column', () => {
    expect(stored(col('real', { nullable: true }), null)).toBeNull()
    expect(stored(col('real', { nullable: true }), undefined)).toBeNull()
    expect(stored(col('real', { fallback: 0 }), undefined)).toBe(0)
    expect(stored(col('json', { fallback: [] }), null)).toBe('[]')
    expect(stored(col('bool', { fallback: false }), null)).toBe(0)
    expect(() => stored(col('real'), null)).toThrow('rows[0].x is required')
  })
})

describe('storedRow', () => {
  it('names the row and the column that failed', () => {
    expect(() => storedRow([col('int')], { x: 'no' }, 'rows[3]')).toThrow('rows[3].x is not a valid int')
    expect(() => storedRow([col('int')], 'no', 'rows[3]')).toThrow('rows[3] is not an object')
    expect(() => storedRow([col('int')], [1], 'rows[3]')).toThrow('rows[3] is not an object')
  })

  it("ignores keys it doesn't know, such as a user_id the app never sends", () => {
    expect(storedRow([col('int')], { x: 1, updated_at: 'z', user_id: 'someone' }, 'rows[0]')).toEqual({ x: 1 })
  })
})

describe('wireValue and wireRow', () => {
  it('answer booleans and JSON as the app decodes them', () => {
    expect(wireValue(col('bool'), 1)).toBe(true)
    expect(wireValue(col('bool'), 0)).toBe(false)
    expect(wireValue(col('json'), '[1,2]')).toEqual([1, 2])
    expect(wireValue(col('real'), null)).toBeNull()
    expect(wireValue(col('ts'), '2026-11-07T10:00:00.000000Z')).toBe('2026-11-07T10:00:00.000000Z')
  })

  it('pass other keys through', () => {
    expect(wireRow([col('bool')], { x: 1, updated_at: 't' })).toEqual({ x: true, updated_at: 't' })
  })
})
