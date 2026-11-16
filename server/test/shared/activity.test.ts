// Runs fixtures/activity.json, the cases GymCore's ActivityFixtureTests.swift runs too, through the TypeScript mirror.
import activityJson from '../../../fixtures/activity.json?raw'
import { test } from 'vitest'
import { assert, assertEquals } from '../assert.ts'
import { type ActivitySpan, counted, resolveActivities, type WorkoutSpan } from '../../src/shared/activity.ts'
import { streak } from '../../src/shared/insights.ts'

interface Fixture {
  cases: {
    name: string
    now: string
    time_zone: string
    goal: number
    workouts: WorkoutSpan[]
    activities: ActivitySpan[]
    expected: {
      shown: string[]
      attached: Record<string, string>
      counted: string[]
      streak: { current: number; longest: number; this_week_days: number; this_week_met: boolean }
    }
  }[]
}

const fixture = JSON.parse(activityJson) as Fixture

test('the fixture has its cases', () => {
  assert(fixture.cases.length >= 6, String(fixture.cases.length))
})

for (const c of fixture.cases) {
  test(`activity fixture: ${c.name}`, () => {
    const resolved = resolveActivities(c.activities, c.workouts)
    assertEquals(resolved.shown.map((a) => a.id), c.expected.shown, 'shown')
    assertEquals(Object.fromEntries(resolved.attached.map((x) => [x.activity.id, x.workout_id])), c.expected.attached,
      'attached')
    const kept = counted(resolved)
    assertEquals(kept.map((a) => a.id), c.expected.counted, 'counted')
    const s = streak([...c.workouts.map((w) => w.started_at), ...kept.map((a) => a.started_at)], c.goal,
      new Date(c.now), c.time_zone)
    assertEquals(
      { current: s.current, longest: s.longest, this_week_days: s.this_week_days, this_week_met: s.this_week_met },
      c.expected.streak,
      'streak',
    )
  })
}
