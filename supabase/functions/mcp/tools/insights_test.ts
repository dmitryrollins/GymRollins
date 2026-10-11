import { assert, assertEquals, assertRejects } from 'jsr:@std/assert@^1'
import type { WorkoutRow } from '../db.ts'
import { FakeDb, loadOwnerData } from './fake_db.ts'
import { getTrainingInsights } from './insights.ts'
import { ToolError, type ToolResult } from './result.ts'

const NOW = new Date('2026-09-26T09:00:00Z')

// deno-lint-ignore no-explicit-any
function json(r: ToolResult): any {
  assert(!r.isError, `unexpected error: ${r.content[0].text}`)
  return JSON.parse(r.content[0].text)
}

function bench(id: string, start: string, sets: number): WorkoutRow {
  const end = new Date(new Date(start).getTime() + 3_600_000).toISOString()
  return {
    id,
    started_at: start,
    ended_at: end,
    paused_sec: 0,
    routine_id: null,
    name: 'Push',
    workout_entries: [{
      exercise_id: '0025',
      position: 0,
      workout_sets: [
        { position: 0, w_kg: 20, r: 10, done: true, warmup: true, multiplier: 1 },
        ...Array.from({ length: sets }, (_, i) => ({
          position: i + 1,
          w_kg: 60,
          r: 8,
          done: true,
          warmup: false,
          multiplier: 1,
        })),
      ],
    }],
  }
}

async function ctx(mutate?: (d: Awaited<ReturnType<typeof loadOwnerData>>) => void) {
  const data = await loadOwnerData()
  data.library = data.library.map((e) => e.id === '0025' ? { ...e, sm: ['triceps', 'shoulders'] } : e)
  data.workouts = [
    bench('w1', '2026-09-21T17:00:00Z', 3), // Mon
    bench('w2', '2026-09-25T20:00:00Z', 3), // Fri, 12 h before NOW
    bench('w3', '2026-09-15T17:00:00Z', 3),
    bench('w4', '2026-09-16T17:00:00Z', 3),
    bench('w5', '2026-09-17T17:00:00Z', 3),
    bench('w6', '2026-09-18T17:00:00Z', 3),
  ]
  mutate?.(data)
  const db = new FakeDb(data)
  return { db, now: NOW }
}

Deno.test('get_training_insights: recovery, fresh, limited legs from the limits note', async () => {
  const out = json(await getTrainingInsights(await ctx(), {}))
  const byMuscle = Object.fromEntries(out.recovery.map((r: { muscle: string }) => [r.muscle, r]))
  assertEquals(out.recovery.length, 16)
  assertEquals(byMuscle.chest.recovered_pct, 64) // 3 sets 12 h ago: 1 − 0.5 × 30/42
  assertEquals(byMuscle.chest.status, 'recovering')
  assertEquals(byMuscle.chest.last_trained, '2026-09-25T21:00:00.000Z')
  assertEquals(byMuscle.triceps.recovered_pct, 84)
  assertEquals(byMuscle.lats.recovered_pct, 100)
  assertEquals(byMuscle.lats.last_trained, null)
  assertEquals(byMuscle.quads.limited_by_injury_note, true) // "left knee: no deep knee flexion"
  assertEquals(byMuscle.chest.limited_by_injury_note, undefined)
  assertEquals(out.fresh, [])
  assertEquals(out.limits_note, 'left knee: no deep knee flexion')
})

Deno.test('get_training_insights: weekly sets vs default and stored targets (UTC week)', async () => {
  const out = json(
    await getTrainingInsights(
      await ctx((d) => (d.targets = [{ muscle: 'chest', min_sets: 4, max_sets: 5 }])),
      {},
    ),
  )
  assertEquals(out.weekly_sets.week_start, '2026-09-21')
  assertEquals(out.weekly_sets.week_end, '2026-09-27')
  const chest = out.weekly_sets.muscles.find((m: { muscle: string }) => m.muscle === 'chest')
  assertEquals(chest, {
    muscle: 'chest',
    hard_sets: 6,
    target_min: 4,
    target_max: 5,
    custom_target: true,
    status: 'above',
  })
  const triceps = out.weekly_sets.muscles.find((m: { muscle: string }) => m.muscle === 'triceps')
  assertEquals(triceps, {
    muscle: 'triceps',
    hard_sets: 3,
    target_min: 6,
    target_max: 12,
    custom_target: false,
    status: 'below',
  })
})

Deno.test('get_training_insights: streak with the profile goal (4 days/week)', async () => {
  const out = json(await getTrainingInsights(await ctx(), {}))
  assertEquals(out.streak, {
    current_weeks: 1, // week of 14 Sep met 4 days; this week (2 days) is still in progress
    longest_weeks: 1,
    goal_days_per_week: 4,
    this_week_days: 2,
    this_week_met: false,
  })
})

Deno.test('get_training_insights: time zone moves the week boundary; bad zone is a user error', async () => {
  const late = await ctx((d) => d.workouts.push(bench('w7', '2026-09-20T22:30:00Z', 2))) // Mon 00:30 in Warsaw
  const utc = json(await getTrainingInsights(late, {}))
  const warsaw = json(await getTrainingInsights(late, { time_zone: 'Europe/Warsaw' }))
  const chest = (o: { weekly_sets: { muscles: { muscle: string; hard_sets: number }[] } }) =>
    o.weekly_sets.muscles.find((m) => m.muscle === 'chest')!.hard_sets
  assertEquals(chest(utc), 6)
  assertEquals(chest(warsaw), 8)
  await assertRejects(
    () => getTrainingInsights(late, { time_zone: 'Mars/Olympus' }),
    ToolError,
    'Unknown time zone',
  )
})

Deno.test('get_training_insights: refused when the owner turned off reading workouts', async () => {
  const c = await ctx((d) => (d.profile = { ...d.profile!, mcp_read_workouts: false }))
  await assertRejects(() => getTrainingInsights(c, {}), ToolError, 'Not allowed')
})

Deno.test('get_training_insights: refused when the plan is hidden (goal, targets, limits would be guesses)', async () => {
  // With mcp_read_plan off, RLS hides the profile and targets while workouts stay readable.
  const c = await ctx((d) => {
    d.profile = { ...d.profile!, mcp_read_plan: false }
  })
  await assertRejects(() => getTrainingInsights(c, {}), ToolError, 'read the plan')
})

Deno.test('get_training_insights: no profile and no history → defaults, all fresh', async () => {
  const out = json(
    await getTrainingInsights(
      await ctx((d) => {
        d.profile = null
        d.workouts = []
      }),
      {},
    ),
  )
  assert(out.recovery.every((r: { recovered_pct: number }) => r.recovered_pct === 100))
  assertEquals(out.streak.goal_days_per_week, 4)
  assertEquals(out.streak.current_weeks, 0)
  assertEquals(out.limits_note, '')
})
