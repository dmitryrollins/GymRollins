import { describe, expect, it } from 'vitest'
import { constraintMessage } from '../src/http/errors.ts'

describe('constraintMessage', () => {
  it('reads a D1 constraint failure as the row being refused', () => {
    const check = new Error('D1_ERROR: CHECK constraint failed: rest_sec BETWEEN 0 AND 900: SQLITE_CONSTRAINT')
    expect(constraintMessage(check)).toBe('CHECK constraint failed: rest_sec BETWEEN 0 AND 900')
    expect(constraintMessage(new Error('D1_ERROR: FOREIGN KEY constraint failed'))).toBe('FOREIGN KEY constraint failed')
    expect(constraintMessage(new Error('UNIQUE constraint failed: workout_sets.id'))).toBe(
      'UNIQUE constraint failed: workout_sets.id',
    )
  })

  it('leaves other errors alone', () => {
    expect(constraintMessage(new Error('D1_ERROR: no such table: nope'))).toBeNull()
  })
})
