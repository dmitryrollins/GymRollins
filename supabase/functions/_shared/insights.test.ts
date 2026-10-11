// Runs fixtures/insights.json — the same cases GymCore's InsightsFixtureTests.swift runs — through the TS port.
import { assertEquals, assertThrows } from 'jsr:@std/assert@^1'
import {
  assertTimeZone,
  contributions,
  effort,
  freshest,
  type InsightExercise,
  type InsightWorkout,
  limitedMuscles,
  MUSCLE_GROUPS,
  recovery,
  recoveryHours,
  streak,
  weekKey,
  weeklySets,
} from './insights.ts'

interface Fixture {
  exercises: InsightExercise[]
  cases: {
    name: string
    now: string
    time_zone: string
    goal: number
    limits: string
    workouts: InsightWorkout[]
    expected: {
      recovery: Record<string, number>
      weekly_sets: Record<string, number>
      streak: { current: number; longest: number; this_week_days: number; this_week_met: boolean }
      fresh: string[]
      limited: string[]
    }
  }[]
}

const fixture = JSON.parse(
  await Deno.readTextFile(new URL('../../../fixtures/insights.json', import.meta.url)),
) as Fixture
const byId = new Map(fixture.exercises.map((e) => [e.id, e]))
const lookup = (id: string) => byId.get(id)

for (const c of fixture.cases) {
  Deno.test(`insights fixture: ${c.name}`, () => {
    const now = new Date(c.now)
    const rec = recovery(c.workouts, lookup, now)
    assertEquals(
      Object.fromEntries(rec.map((r) => [r.group, r.percent])),
      Object.fromEntries(MUSCLE_GROUPS.map((g) => [g, c.expected.recovery[g] ?? 100])),
      'recovery',
    )
    assertEquals(
      Object.fromEntries(weeklySets(c.workouts, lookup, now, c.time_zone)),
      c.expected.weekly_sets,
      'sets',
    )
    const s = streak(c.workouts.map((w) => w.started_at), c.goal, now, c.time_zone)
    assertEquals(
      {
        current: s.current,
        longest: s.longest,
        this_week_days: s.this_week_days,
        this_week_met: s.this_week_met,
      },
      c.expected.streak,
      'streak',
    )
    const limited = limitedMuscles(c.limits)
    assertEquals([...limited].sort(), [...c.expected.limited].sort(), 'limited')
    assertEquals(freshest(rec, limited, now), c.expected.fresh, 'fresh')
  })
}

Deno.test('taxonomy: bench is chest + half triceps/shoulders; cardio works nothing; custom falls back to body part', () => {
  assertEquals(contributions({ id: 'b', bp: 'chest', tg: 'pectorals', sm: ['triceps', 'shoulders'] }), [
    { group: 'chest', weight: 1, primary: true },
    { group: 'triceps', weight: 0.5, primary: false },
    { group: 'shoulders', weight: 0.5, primary: false },
  ])
  assertEquals(contributions({ id: 'r', bp: 'cardio', tg: 'cardiovascular system' }), [])
  assertEquals(
    contributions({ id: 'c', bp: 'upper legs', tg: 'upper legs', mode: 'reps' }).map((c) => c.group),
    [
      'quads',
      'hamstrings',
      'glutes',
    ],
  )
  assertEquals(contributions({ id: 'x', bp: 'chest', tg: 'chest', mode: 'cardio' }), [])
})

Deno.test('effort bands and recovery hours match GymCore', () => {
  const set = (rir?: number, rpe?: number) => ({ r: 8, done: true, warmup: false, rir, rpe })
  assertEquals([undefined, 0, 1, 2, 2.5, 3, 4, 6].map((r) => effort(set(r))), [
    1,
    1,
    1,
    0.9,
    0.9,
    0.75,
    0.6,
    0.5,
  ])
  assertEquals(effort(set(undefined, 8)), 0.9)
  assertEquals([0.5, 4, 8, 20].map(recoveryHours), [27, 48, 72, 96])
})

Deno.test('weeks: Monday start in the zone, across DST', () => {
  const day = (iso: string) => new Date(iso).getTime()
  assertEquals(new Date(weekKey(day('2026-09-27T23:30:00Z'), 'UTC')).toISOString().slice(0, 10), '2026-09-21')
  assertEquals(
    new Date(weekKey(day('2026-09-27T23:30:00Z'), 'Europe/Warsaw')).toISOString().slice(0, 10),
    '2026-09-28',
  )
  assertEquals(
    new Date(weekKey(day('2026-10-25T22:30:00Z'), 'Europe/Warsaw')).toISOString().slice(0, 10),
    '2026-10-19',
  )
  assertThrows(() => assertTimeZone('Mars/Olympus'))
})
