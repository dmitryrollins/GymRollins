// get_workout's and list_workouts' measured parts (plan 40): the spec's words, each part only when it is known.
import { describe, expect, it } from 'vitest'
import type { WorkoutMeasurementRow } from '../../../src/mcp/db.ts'
import { effortWord, listedMeasurement, measuredText } from '../../../src/mcp/tools/measured.ts'

/** What the Apple Watch recorded during `-seedHistory`'s Saturday session (58 min 20 s). */
const WATCH: WorkoutMeasurementRow = {
  workout_id: 'b0b0b0b0-0000-4000-8000-000000000003', recorded_by: 'watch', duration_s: 3500, active_kcal: 412.4,
  total_kcal: 488.6, avg_hr: 128, max_hr: 162, post_hr: 124, effort: 6, effort_estimated: false,
}
const NOTHING: WorkoutMeasurementRow = {
  ...WATCH, recorded_by: null, duration_s: null, active_kcal: null, total_kcal: null, avg_hr: null, max_hr: null,
  post_hr: null, effort: null,
}

describe('the measured part', () => {
  it("reads the Apple Watch's numbers as the spec words them", () => {
    expect(measuredText(WATCH)).toBe(
      'Apple Watch: 58 min, 412 active kcal (489 total), heart rate avg 128 / max 162, 124 BPM 2 min after, ' +
        'effort 6/10 Moderate',
    )
  })

  it('names an attached recording, and leaves out what it lacks', () => {
    const attached = {
      ...WATCH, recorded_by: 'apple_workout' as const, duration_s: 3000, total_kcal: null, post_hr: null, effort: null,
    }
    expect(measuredText(attached)).toBe('Apple Workout: 50 min, 412 active kcal, heart rate avg 128 / max 162')
  })

  it("says an effort alone, the Watch's estimate as estimated, and heart rate alone", () => {
    expect(measuredText({ ...NOTHING, effort: 6 })).toBe('Effort 6/10 Moderate')
    expect(measuredText({ ...NOTHING, effort: 5, effort_estimated: true })).toBe('Effort 5/10 Moderate (estimated)')
    expect(measuredText({ ...NOTHING, avg_hr: 131, post_hr: 118 })).toBe('Heart rate avg 131, 118 BPM 2 min after')
  })

  it('is nothing when nothing is known', () => {
    expect(measuredText(NOTHING)).toBeNull()
  })

  it.each([[1, 'Easy'], [3, 'Easy'], [4, 'Moderate'], [6, 'Moderate'], [7, 'Hard'], [8, 'Hard'], [9, 'All Out'],
    [10, 'All Out']])('calls effort %i %s', (score, word) => {
    expect(effortWord(score)).toBe(word)
  })

  it("gives a list_workouts line its active kcal, average heart rate and effort, when known", () => {
    expect(listedMeasurement(WATCH)).toEqual({ active_kcal: 412, avg_hr: 128, effort: '6/10 Moderate' })
    expect(listedMeasurement({ ...NOTHING, effort: 5, effort_estimated: true }))
      .toEqual({ effort: '5/10 Moderate (estimated)' })
    expect(listedMeasurement(undefined)).toEqual({})
  })
})
