// Runs fixtures/strength-levels.json — the same cases GymCore's StrengthFixtureTests.swift runs — through the TS
// port, plus edge cases on a tiny synthetic table (the Swift StrengthLevelCalculatorTests use the same one).
import { assert, assertAlmostEquals, assertEquals } from 'jsr:@std/assert@^1'
import {
  assess,
  best,
  curve,
  LIFTS,
  percentileText,
  report,
  type Sex,
  type Standards,
  type StrengthWorkout,
} from './strength-levels.ts'

interface Expected {
  e1rm_kg: number | null
  exercise_id: string | null
  level: string | null
  percentile: number | null
  next: string | null
  next_target_kg: number | null
  paused: boolean
}

interface Fixture {
  cases: {
    name: string
    sex: Sex | null
    birth_year: number | null
    bodyweight_kg: number | null
    limits: string
    now: string
    workouts: StrengthWorkout[]
    expected: { missing: string[]; age: number | null; lifts: Record<string, Expected> }
  }[]
}

const standards = JSON.parse(
  await Deno.readTextFile(new URL('./strength-standards.json', import.meta.url)),
) as Standards
const fixture = JSON.parse(
  await Deno.readTextFile(new URL('../../../fixtures/strength-levels.json', import.meta.url)),
) as Fixture

const near = (actual: number | null | undefined, expected: number | null, msg: string) => {
  if (expected === null) return assertEquals(actual ?? null, null, msg)
  assert(actual !== null && actual !== undefined, msg)
  assertAlmostEquals(actual, expected, 0.01, msg)
}

for (const c of fixture.cases) {
  Deno.test(`fixture: ${c.name}`, () => {
    const r = report(standards, {
      workouts: c.workouts,
      sex: c.sex,
      birthYear: c.birth_year,
      bodyweightKg: c.bodyweight_kg,
      limits: c.limits,
      now: new Date(c.now),
    })
    assertEquals(r.missing, c.expected.missing)
    assertEquals(r.age, c.expected.age)
    for (const row of r.rows) {
      const e = c.expected.lifts[row.lift]
      const msg = `${c.name} / ${row.lift}`
      near(row.estimate?.e1rm_kg, e.e1rm_kg, msg)
      assertEquals(row.estimate?.exercise_id ?? null, e.exercise_id, msg)
      assertEquals(row.assessment?.level ?? null, e.level, msg)
      near(row.assessment?.percentile, e.percentile, msg)
      assertEquals(row.assessment?.next ?? null, e.next, msg)
      near(row.assessment?.next_target_kg, e.next_target_kg, msg)
      assertEquals(row.paused, e.paused, msg)
    }
  })
}

/** StrengthFixture.synthetic() in the Swift tests: 60 kg bin 50/80/100/130/160, 100 kg bin 70/100/120/150/200. */
const synthetic: Standards = {
  formatVersion: 1,
  source: { name: 'Test', url: '', license: '', version: 't' },
  percentiles: [1, 20, 50, 80, 99],
  ageGroups: [{ id: 'open', label: '23–39', min: 23, max: 39 }],
  levels: [
    { id: 'beginner', name: 'Beginner', percentile: 50, fraction: 0 },
    { id: 'novice', name: 'Novice', percentile: 50, fraction: 0.45 },
    { id: 'intermediate', name: 'Intermediate', percentile: 50, fraction: 0.65 },
    { id: 'advanced', name: 'Advanced', percentile: 20, fraction: 1 },
    { id: 'elite', name: 'Elite', percentile: 80, fraction: 1 },
  ],
  tables: {
    M: {
      bench: {
        open: [{ bw: 60, n: 100, kg: [50, 80, 100, 130, 160] }, {
          bw: 100,
          n: 50,
          kg: [70, 100, 120, 150, 200],
        }],
      },
    },
  },
}
const level = (kg: number, bw = 60) => assess(synthetic, 'bench', kg, bw, 'male', 30)

Deno.test('thresholds: exactly on a threshold reaches the level', () => {
  assertEquals(level(70)?.thresholds, { beginner: 0, novice: 45, intermediate: 65, advanced: 80, elite: 130 })
  assertEquals(level(44.99)?.level, 'beginner')
  assertEquals(level(45)?.level, 'novice')
  assertEquals(level(65)?.level, 'intermediate')
  assertEquals(level(80)?.level, 'advanced')
  assertEquals(level(130)?.level, 'elite')
  assertEquals(level(45 / 0.45359237 * 0.45359237)?.level, 'novice')
})

Deno.test('next target, gap, progress, percentile and its text', () => {
  const a = level(70)!
  assertEquals([a.next, a.next_target_kg, a.gap_kg], ['advanced', 80, 10])
  assertAlmostEquals(a.progress, 5 / 15)
  assertEquals(level(140)!.next, null)
  assertEquals(level(140)!.progress, 1)
  assertEquals(level(100)!.percentile, 50)
  assertEquals(level(115)!.percentile, 65)
  assertEquals(level(25)!.percentile_text, 'under 1%')
  assertEquals(level(160)!.percentile_text, 'over 99%')
  assertEquals(level(159)!.percentile_text, '98%')
  assertEquals(percentileText(1, [1, 99]), '1%')
})

Deno.test('curve interpolates between bins and clamps; unknown sex/age/lift gives null', () => {
  assertEquals(curve(synthetic, 'male', 'bench', 30, 80), [60, 90, 110, 140, 180])
  assertEquals(curve(synthetic, 'male', 'bench', 30, 40), [50, 80, 100, 130, 160])
  assertEquals(curve(synthetic, 'female', 'bench', 30, 60), null)
  assertEquals(curve(synthetic, 'male', 'squat', 30, 60), null)
  assertEquals(curve(synthetic, 'male', 'bench', 45, 60), null)
  assertEquals(level(90, 80)!.level, 'advanced')
  assertEquals(assess(synthetic, 'bench', 0, 60, 'male', 30), null)
  assertEquals(assess(synthetic, 'bench', 50, 0, 'male', 30), null)
})

Deno.test('best: window, future, warm-ups, undone, >12 reps and unmapped exercises are ignored', () => {
  const now = new Date('2026-09-29T12:00:00Z')
  const w = (at: string, id: string, w_kg: number, r: number, o = {}) => ({
    started_at: at,
    workout_entries: [{ exercise_id: id, workout_sets: [{ w_kg, r, done: true, warmup: false, ...o }] }],
  })
  const workouts = [
    w('2025-09-28T10:00:00Z', '0032', 250, 1),
    w('2026-10-05T10:00:00Z', '0032', 240, 1),
    w('2026-09-01T10:00:00Z', '0032', 300, 1, { warmup: true }),
    w('2026-09-02T10:00:00Z', '0032', 290, 1, { done: false }),
    w('2026-09-03T10:00:00Z', '0085', 200, 1),
    w('2026-09-04T10:00:00Z', '0032', 100, 20),
    w('2026-08-01T10:00:00Z', '0032', 150, 1),
    w('2026-09-10T10:00:00Z', '0117', 160, 1),
  ]
  assertEquals(best(workouts, 'deadlift', now), {
    e1rm_kg: 160,
    date: '2026-09-10T10:00:00Z',
    exercise_id: '0117',
  })
  const tie = [w('2026-09-01T10:00:00Z', '0043', 100, 1), w('2026-09-05T10:00:00Z', '1435', 100, 1)]
  assertEquals(best(tie, 'squat', now)?.exercise_id, '1435')
  assertEquals(LIFTS, ['squat', 'bench', 'deadlift'])
})
