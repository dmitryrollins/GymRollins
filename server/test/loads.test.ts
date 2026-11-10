import { describe, expect, it } from 'vitest'
import { parseLoads } from '../src/gyms/loads.ts'

describe('listing loads', () => {
  it('takes the four shapes and rebuilds them in one key order', () => {
    expect(parseLoads({ type: 'none' })).toEqual({ type: 'none' })
    expect(parseLoads({ type: 'plates' })).toEqual({ type: 'plates' })
    expect(JSON.stringify(parseLoads({ stepKg: 5, type: 'stack', maxKg: 100 })))
      .toBe('{"type":"stack","maxKg":100,"stepKg":5}')
    expect(parseLoads({ type: 'stack', maxKg: 113.4 })).toEqual({ type: 'stack', maxKg: 113.4 })
    expect(parseLoads({ type: 'stack', maxKg: 113.4, stepKg: null })).toEqual({ type: 'stack', maxKg: 113.4 })
    // The same double as the app sent, written in JavaScript's shortest form.
    expect(JSON.stringify(parseLoads({ kg: [24.040395609999998, 20], type: 'fixed' })))
      .toBe('{"type":"fixed","kg":[24.040395609999997,20]}')
  })

  it('refuses numbers outside the limits or unreadable, as valid_kg did', () => {
    expect(parseLoads({ type: 'stack', maxKg: -1 })).toBeNull()
    expect(parseLoads({ type: 'stack', maxKg: JSON.parse('1e-400') })).toBeNull()
    expect(parseLoads({ type: 'stack', maxKg: 1000.5 })).toBeNull()
    expect(parseLoads({ type: 'stack', maxKg: 1000, stepKg: 1000 })).toBeNull()
    expect(parseLoads({ type: 'stack', maxKg: 10, stepKg: 20 })).toBeNull()
    expect(parseLoads({ type: 'fixed', kg: ['x'] })).toBeNull()
    expect(parseLoads({ type: 'fixed', kg: [JSON.parse('1e-400')] })).toBeNull()
    expect(parseLoads({ type: 'fixed', kg: [] })).toBeNull()
    expect(parseLoads({ type: 'fixed', kg: [500.5] })).toBeNull()
    expect(parseLoads({ type: 'fixed', kg: Array.from({ length: 61 }, () => 20) })).toBeNull()
    expect(parseLoads({ type: 'fixed', kg: Array.from({ length: 60 }, () => 20) })).not.toBeNull()
  })

  it('refuses any other key, type or shape', () => {
    expect(parseLoads({ type: 'plates', html: '<script>' })).toBeNull()
    expect(parseLoads({ type: 'none', ['x'.repeat(3000)]: 1 })).toBeNull()
    expect(parseLoads({ type: 'stack', 'maxKg,type': 1 })).toBeNull()
    expect(parseLoads({ type: 'barbell' })).toBeNull()
    expect(parseLoads({ type: 1 })).toBeNull()
    expect(parseLoads([{ type: 'none' }])).toBeNull()
    expect(parseLoads(null)).toBeNull()
    expect(parseLoads('none')).toBeNull()
  })
})
