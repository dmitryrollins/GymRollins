import { assert, assertEquals, assertRejects } from 'jsr:@std/assert@^1'
import type { WorkoutRow } from '../db.ts'
import { FakeDb, loadOwnerData } from './fake_db.ts'
import { getStrengthLevels } from './strength.ts'
import { ToolError, type ToolResult } from './result.ts'

const NOW = new Date('2026-09-26T09:00:00Z')
const LB = 0.45359237

// deno-lint-ignore no-explicit-any
function json(r: ToolResult): any {
  assert(!r.isError, `unexpected error: ${r.content[0].text}`)
  return JSON.parse(r.content[0].text)
}

function session(id: string, start: string, exerciseId: string, wKg: number, reps: number): WorkoutRow {
  return {
    id,
    started_at: start,
    ended_at: start,
    paused_sec: 0,
    routine_id: null,
    name: 'W',
    workout_entries: [{
      exercise_id: exerciseId,
      position: 0,
      workout_sets: [
        { position: 0, w_kg: 20, r: 10, done: true, warmup: true, multiplier: 1 },
        { position: 1, w_kg: wKg, r: reps, done: true, warmup: false, multiplier: 1 },
      ],
    }],
  }
}

type Data = Awaited<ReturnType<typeof loadOwnerData>>

async function ctx(mutate?: (d: Data) => void) {
  const data = await loadOwnerData()
  data.profile = { ...data.profile!, sex: 'male', birth_year: 1991 }
  data.workouts = [
    session('b1', '2026-09-19T17:00:00Z', '0025', 130 * LB, 10), // e1RM 78.6 kg
    session('s1', '2026-07-01T17:00:00Z', '0043', 225 * LB, 5),
    session('old', '2025-09-01T17:00:00Z', '0032', 250, 1), // > 365 days: ignored
  ]
  data.bodyweight = [
    { id: 'bw1', measured_at: '2026-09-01T07:00:00Z', w_kg: 82, bf_pct: null },
    { id: 'bw2', measured_at: '2026-09-25T07:00:00Z', w_kg: 81, bf_pct: null },
    { id: 'future', measured_at: '2026-10-01T07:00:00Z', w_kg: 90, bf_pct: null },
  ]
  mutate?.(data)
  return { db: new FakeDb(data), now: NOW }
}

Deno.test('get_strength_levels: owner bench is Novice with the gap to Intermediate; knee note pauses leg lifts', async () => {
  const out = json(await getStrengthLevels(await ctx(), {}))
  assertEquals(out.missing, [])
  assertEquals(out.bodyweight.weight_kg, 81) // latest past weigh-in, not the future one
  const byLift = Object.fromEntries(out.lifts.map((l: { lift: string }) => [l.lift, l]))
  const bench = byLift.bench
  assertEquals(bench.level, 'novice')
  assertEquals(bench.e1rm.weight_kg, 78.62)
  assertEquals(bench.e1rm.date, '2026-09-19')
  assertEquals(bench.next_level, 'intermediate')
  assertEquals(bench.to_next_level, '+15 lb')
  assertEquals(bench.percentile_text, '1%')
  assertEquals(bench.paused_by_injury_note, false)
  assertEquals(Object.keys(bench.thresholds), ['novice', 'intermediate', 'advanced', 'elite'])
  assert(bench.next_level_target.weight_display.endsWith('kg)'), bench.next_level_target.weight_display)
  assertEquals(byLift.squat.paused_by_injury_note, true) // owner.json limits: knee
  assertEquals(byLift.squat.level !== null, true)
  assertEquals(byLift.deadlift.e1rm, null)
  assertEquals(byLift.deadlift.level, null)
  assertEquals(out.source.name, 'OpenPowerlifting')
})

Deno.test('get_strength_levels: never returns the owner sex or birth year', async () => {
  const r = await getStrengthLevels(await ctx(), {})
  const text = r.content[0].text
  assert(!text.includes('1991'), text)
  assert(!/"sex"|"birth_year"|"age"/.test(text), text)
})

Deno.test('get_strength_levels: missing sex/birth year and weigh-in are listed, e1RMs still shown', async () => {
  const out = json(
    await getStrengthLevels(
      await ctx((d) => {
        d.profile = { ...d.profile!, sex: null, birth_year: null }
        d.bodyweight = []
      }),
      {},
    ),
  )
  assertEquals(out.missing.length, 2)
  assert(out.missing[0].startsWith('sex_and_birth_year'))
  assert(out.missing[1].startsWith('bodyweight'))
  assertEquals(out.bodyweight, null)
  const bench = out.lifts.find((l: { lift: string }) => l.lift === 'bench')
  assertEquals(bench.e1rm.weight_kg, 78.62)
  assertEquals(bench.level, null)
})

Deno.test('get_strength_levels: kg unit, and no profile at all means missing inputs in lb', async () => {
  const kg = json(await getStrengthLevels(await ctx((d) => (d.profile = { ...d.profile!, unit: 'kg' })), {}))
  assertEquals(kg.lifts[1].to_next_level, '+7 kg')
  const none = json(await getStrengthLevels(await ctx((d) => (d.profile = null)), {}))
  assert(none.missing[0].startsWith('sex_and_birth_year'))
  assert(none.bodyweight.weight_display.startsWith('178.6 lb'))
})

Deno.test('get_strength_levels: a date-only weigh-in logged today (stored at 12:00 UTC) counts at once', async () => {
  const out = json(
    await getStrengthLevels(
      await ctx((d) =>
        d.bodyweight.push({ id: 'today', measured_at: '2026-09-26T12:00:00Z', w_kg: 83, bf_pct: null })
      ),
      {},
    ),
  )
  assertEquals(out.bodyweight.weight_kg, 83) // NOW is 09:00 UTC; log_bodyweight accepts up to a day ahead
})

Deno.test('get_strength_levels: the latest past weigh-in wins even behind 1,000+ older rows and a year gap', async () => {
  const out = json(
    await getStrengthLevels(
      await ctx((d) => {
        const old = Array.from({ length: 1200 }, (_, i) => ({
          id: `old${i}`,
          measured_at: new Date(Date.UTC(2020, 0, 1) + i * 86_400_000).toISOString(),
          w_kg: 70,
          bf_pct: null,
        }))
        d.bodyweight = [...old, { id: 'last', measured_at: '2024-06-01T07:00:00Z', w_kg: 84, bf_pct: null }]
      }),
      {},
    ),
  )
  assertEquals(out.bodyweight.weight_kg, 84)
})

for (
  const [flag, label] of [['mcp_read_workouts', 'workouts'], ['mcp_read_body', 'body'], [
    'mcp_read_plan',
    'plan',
  ]]
) {
  Deno.test(`get_strength_levels: refused when the owner turned off reading ${label}`, async () => {
    const c = await ctx((d) => (d.profile = { ...d.profile!, [flag]: false }))
    await assertRejects(() => getStrengthLevels(c, {}), ToolError, 'Not allowed')
  })
}
