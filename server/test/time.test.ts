import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { laterStamp, normalizeTimestamp, NOW_SQL } from '../src/sync/time.ts'

describe('normalizeTimestamp', () => {
  it.each([
    ['2026-11-07T10:00:00.123456Z', '2026-11-07T10:00:00.123456Z'],
    ['2026-11-07T10:00:00Z', '2026-11-07T10:00:00.000000Z'],
    ['2026-11-07T10:00:00', '2026-11-07T10:00:00.000000Z'],
    ['2026-11-07 10:00:00.5z', '2026-11-07T10:00:00.500000Z'],
    ['2026-11-07T10:00:00.123456789+00:00', '2026-11-07T10:00:00.123456Z'],
    ['2026-11-07T10:00:00+0200', '2026-11-07T08:00:00.000000Z'],
    ['2026-11-07T00:30:00-01', '2026-11-07T01:30:00.000000Z'],
    ['2026-01-01T00:00:00.000001-00:30', '2026-01-01T00:30:00.000001Z'],
    ['1969-12-31T23:59:59.999999Z', '1969-12-31T23:59:59.999999Z'],
  ])('reads %s as %s', (raw, stored) => {
    expect(normalizeTimestamp(raw)).toBe(stored)
  })

  it.each(['2026-11-07', 'yesterday', '2026-13-01T00:00:00Z', '2026-11-07T24:00:00Z', '2026-11-07T10:60:00Z', ''])(
    'refuses %j',
    (raw) => {
      expect(normalizeTimestamp(raw)).toBeNull()
    },
  )
})

describe('NOW_SQL', () => {
  it("is the database's clock, in the stored form", async () => {
    const { now } = (await env.DB.prepare(`SELECT ${NOW_SQL} AS now`).first<{ now: string }>())!
    expect(now).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}000Z$/)
    expect(Math.abs(Date.parse(now) - Date.now())).toBeLessThan(5_000)
  })
})

describe('laterStamp', () => {
  const later = async (stored: string, now: string) =>
    (await env.DB.prepare(`SELECT ${laterStamp('?1', '?2')} AS s`).bind(stored, now).first<{ s: string }>())!.s

  it('takes the clock when it has moved past the stored stamp', async () => {
    expect(await later('2026-11-07T10:00:00.123000Z', '2026-11-07T10:00:00.124000Z')).toBe('2026-11-07T10:00:00.124000Z')
  })

  it('goes a microsecond past the stored stamp when the clock has not, so every write changes it', async () => {
    expect(await later('2026-11-07T10:00:00.123000Z', '2026-11-07T10:00:00.123000Z')).toBe('2026-11-07T10:00:00.123001Z')
    expect(await later('2026-11-07T10:00:00.123999Z', '2026-11-07T10:00:00.123000Z')).toBe('2026-11-07T10:00:00.124000Z')
  })
})
