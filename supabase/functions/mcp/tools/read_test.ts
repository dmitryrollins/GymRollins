import { assert, assertEquals, assertRejects } from 'jsr:@std/assert@^1'
import type { WorkoutRow } from '../db.ts'
import { FakeDb, loadOwnerData } from './fake_db.ts'
import {
  getBodyweight,
  getExerciseHistory,
  getPlan,
  getProfile,
  getTrainingSummary,
  getWorkout,
  listWorkouts,
  searchExercises,
} from './read.ts'
import { ToolError, type ToolResult } from './result.ts'

const NOW = new Date('2026-09-26T12:00:00Z')

// deno-lint-ignore no-explicit-any
function json(r: ToolResult): any {
  assert(!r.isError, `unexpected error: ${r.content[0].text}`)
  return JSON.parse(r.content[0].text)
}

async function ctx(mutate?: (d: Awaited<ReturnType<typeof loadOwnerData>>) => void) {
  const data = await loadOwnerData()
  mutate?.(data)
  const db = new FakeDb(data)
  return { db, now: NOW }
}

Deno.test('get_profile: unit, goal with display, limits, permissions', async () => {
  const out = json(await getProfile(await ctx()))
  assertEquals(out.unit, 'lb')
  assertEquals(out.goal, { weight_kg: 85, weight_display: '187.4 lb (85 kg)', date: '2026-12-31' })
  assertEquals(out.limits, 'left knee: no deep knee flexion')
  assertEquals(out.training_days, 4)
  assertEquals(out.permissions, {
    read_plan: true,
    read_workouts: true,
    read_body: true,
    propose: true,
    auto_apply: false,
  })
})

Deno.test('get_profile: no profile yet → defaults, lb', async () => {
  const out = json(await getProfile(await ctx((d) => (d.profile = null))))
  assertEquals(out.unit, 'lb')
  assertEquals(out.profile_saved, false)
})

Deno.test('get_plan: routines with exercise names, weights in kg + display, week Mon…Sun', async () => {
  const out = json(await getPlan(await ctx()))
  assertEquals(out.routines.length, 2)
  const push = out.routines[0]
  assertEquals(push.name, 'Push + Arms')
  assertEquals(push.paused, false)
  assertEquals(push.exercises[0].id, '0025')
  assertEquals(push.exercises[0].name, 'barbell bench press')
  assertEquals(push.exercises[0].weight_kg, 58.97)
  assertEquals(push.exercises[0].weight_display, '130 lb (59 kg)')
  assertEquals(push.exercises[0].reps, 10)
  assertEquals(push.exercises[0].reps_min, 8)
  assertEquals(out.routines[1].paused, true)
  assertEquals(out.week.length, 7)
  assertEquals(out.week[0], { weekday: 1, day: 'Mon', routine_id: push.id, routine: 'Push + Arms' })
  assertEquals(out.week[1], { weekday: 2, day: 'Tue', routine_id: null, routine: null })
  assertEquals(out.week[5].routine, null)
})

Deno.test('list_workouts: clamps limit to 60 and defaults to a 12-week window', async () => {
  const c = await ctx()
  await listWorkouts(c, { limit: 500 })
  assertEquals(c.db.workoutQueries[0].limit, 60)
  assertEquals(c.db.workoutQueries[0].since, '2026-07-04T12:00:00.000Z')
  assertEquals(c.db.workoutQueries[0].until, undefined)
  await listWorkouts(c, {})
  assertEquals(c.db.workoutQueries[1].limit, 20)
})

Deno.test('list_workouts: summaries newest first with working sets, volume and top sets', async () => {
  const out = json(await listWorkouts(await ctx(), {}))
  assertEquals(out.workouts.map((w: { date: string }) => w.date), ['2026-09-19', '2026-09-15', '2026-09-12'])
  const pull = out.workouts[1]
  assertEquals(pull.working_sets, 3) // the undone 4th set doesn't count
  assertEquals(pull.volume_kg, 1440)
  assertEquals(pull.duration_min, 50)
  const first = out.workouts[2]
  assertEquals(first.working_sets, 3) // warm-up excluded
  assertEquals(first.duration_min, 60) // 65 min minus 5 paused
  assertEquals(first.top_sets[0].exercise, 'barbell bench press')
  assertEquals(first.top_sets[0].reps, 6)
  assertEquals(first.top_sets[0].weight_kg, 58.97)
})

Deno.test('list_workouts: a date-only `until` includes that whole day', async () => {
  const c = await ctx()
  const out = json(await listWorkouts(c, { since: '2026-09-12', until: '2026-09-15' }))
  assertEquals(c.db.workoutQueries[0].since, '2026-09-12T00:00:00.000Z')
  assertEquals(c.db.workoutQueries[0].until, '2026-09-16T00:00:00.000Z')
  assertEquals(out.workouts.length, 2)
})

Deno.test('list_workouts: an unparseable date is a tool error', async () => {
  const c = await ctx()
  await assertRejects(() => listWorkouts(c, { since: 'last week' }), ToolError, 'since')
})

Deno.test('get_workout: entries with sets, warm-ups flagged', async () => {
  const out = json(await getWorkout(await ctx(), { id: 'b0b0b0b0-0000-4000-8000-000000000001' }))
  assertEquals(out.name, 'Push + Arms')
  assertEquals(out.entries[0].exercise, 'barbell bench press')
  assertEquals(out.entries[0].sets.length, 4)
  assertEquals(out.entries[0].sets[0].warmup, true)
  assertEquals(out.entries[0].sets[1].warmup, undefined)
  assertEquals(out.entries[0].sets[1].weight_display, '130 lb (59 kg)')
})

Deno.test('get_workout: logged effort (rir / rpe) is on the set; absent effort is omitted', async () => {
  const c = await ctx((d) => {
    const sets = d.workouts[0].workout_entries[0].workout_sets
    sets[1] = { ...sets[1], rir: 2 }
    sets[2] = { ...sets[2], rpe: 8.5 }
  })
  const out = json(await getWorkout(c, { id: 'b0b0b0b0-0000-4000-8000-000000000001' }))
  const sets = out.entries[0].sets
  assertEquals(sets[1].rir, 2)
  assertEquals(sets[2].rpe, 8.5)
  assertEquals('rir' in sets[3] || 'rpe' in sets[3], false)
})

Deno.test('get_workout: unknown id → not found', async () => {
  await assertRejects(
    () => getWorkout(ctx0(), { id: 'b0b0b0b0-0000-4000-8000-00000000ffff' }),
    ToolError,
    'not found',
  )
})

function ctx0() {
  return {
    db: new FakeDb({ profile: null, library: [], routines: [], schedule: [], workouts: [], bodyweight: [] }),
    now: NOW,
  }
}

Deno.test('get_exercise_history by name "bench": the 2 bench sessions newest first, e1RM 78.6 then 70.8', async () => {
  const out = json(await getExerciseHistory(await ctx(), { exercise: 'bench' }))
  assertEquals(out.exercise, { id: '0025', name: 'barbell bench press' })
  assertEquals(out.sessions.length, 2)
  assertEquals(out.sessions.map((s: { e1rm_kg: number }) => s.e1rm_kg), [78.6, 70.8])
  assertEquals(out.sessions.map((s: { date: string }) => s.date), ['2026-09-19', '2026-09-12'])
  assertEquals(out.sessions[1].working_sets.length, 3) // warm-up excluded
  assertEquals(out.sessions[0].top_set.weight_display, '130 lb (59 kg)')
})

Deno.test('get_exercise_history: working sets carry logged rir / rpe, and nothing when not logged', async () => {
  const c = await ctx((d) => {
    const sets = d.workouts[0].workout_entries[0].workout_sets
    sets[1] = { ...sets[1], rir: 3 }
    sets[3] = { ...sets[3], rir: 0, rpe: 10 }
  })
  const out = json(await getExerciseHistory(c, { exercise: '0025' }))
  const older = out.sessions[1].working_sets
  assertEquals(older[0].rir, 3)
  assertEquals('rir' in older[1] || 'rpe' in older[1], false)
  assertEquals([older[2].rir, older[2].rpe], [0, 10])
  assertEquals('rir' in out.sessions[0].working_sets[0], false)
})

Deno.test('get_exercise_history by id and by exact name', async () => {
  const byId = json(await getExerciseHistory(await ctx(), { exercise: '0027' }))
  assertEquals(byId.sessions.length, 1)
  const exact = json(await getExerciseHistory(await ctx(), { exercise: 'Barbell Bench Press' }))
  assertEquals(exact.exercise.id, '0025')
})

Deno.test('get_exercise_history: ambiguous name → error listing candidates', async () => {
  const c = await ctx((d) => {
    // The owner has also done dumbbell bench press, so "bench" no longer narrows to one exercise.
    const w = structuredClone(d.workouts[0]) as WorkoutRow
    d.workouts.push({
      ...w,
      id: 'b0b0b0b0-0000-4000-8000-000000000009',
      workout_entries: [{ ...w.workout_entries[0], exercise_id: '0289' }],
    })
  })
  const err = await assertRejects(() => getExerciseHistory(c, { exercise: 'bench' }), ToolError)
  assert(err.message.includes('Ambiguous'), err.message)
  const ids = (err.details?.candidates as { id: string }[]).map((x) => x.id).sort()
  assertEquals(ids, ['0025', '0289'])
})

Deno.test('get_exercise_history: no match → error pointing to search_exercises', async () => {
  await assertRejects(() => getExerciseHistory(ctx0(), { exercise: 'zzz' }), ToolError, 'search_exercises')
})

Deno.test('get_training_summary weeks 4: sessions and volume per calendar week', async () => {
  const out = json(await getTrainingSummary(await ctx(), { weeks: 4 }))
  assertEquals(out.weekly.map((w: { week_start: string }) => w.week_start), [
    '2026-08-31',
    '2026-09-07',
    '2026-09-14',
    '2026-09-21',
  ])
  assertEquals(out.weekly.map((w: { sessions: number }) => w.sessions), [0, 1, 2, 0])
  assertEquals(out.weekly[1].volume_kg, 1061.5)
  assertEquals(out.weekly[2].volume_kg, 3209.1)
  assertEquals(out.weekly[2].sets_by_body_part, { chest: 3, back: 3 })
  assertEquals(out.prs.length, 1)
  assertEquals(out.prs[0].exercise_id, '0025')
  assertEquals(out.prs[0].e1rm_kg, 78.6)
  assertEquals(out.stalls, [])
  assertEquals(out.bodyweight.latest.weight_kg, 81.6)
  assertEquals(out.bodyweight.slope_kg_per_week, 0.3)
})

Deno.test('get_training_summary: a 3-session stall (same top weight, reps not rising) is detected', async () => {
  const set = (r: number) => ({ position: 0, w_kg: 100, r, done: true, warmup: false, multiplier: 1 })
  const squat = (id: string, day: string, reps: number[]): WorkoutRow => ({
    id,
    started_at: `${day}T17:00:00+00:00`,
    ended_at: null,
    paused_sec: 0,
    routine_id: null,
    name: 'Legs',
    workout_entries: [{ exercise_id: '0043', position: 0, workout_sets: reps.map(set) }],
  })
  const c = await ctx((d) => {
    d.workouts.push(
      squat('d0000000-0000-4000-8000-000000000001', '2026-09-08', [5, 5, 5]),
      squat('d0000000-0000-4000-8000-000000000002', '2026-09-16', [5, 5, 4]),
      squat('d0000000-0000-4000-8000-000000000003', '2026-09-23', [5, 4, 4]),
    )
  })
  const out = json(await getTrainingSummary(c, { weeks: 4 }))
  assertEquals(out.stalls.length, 1)
  assertEquals(out.stalls[0].exercise_id, '0043')
  assertEquals(out.stalls[0].reps, [5, 5, 5])
  assertEquals(out.stalls[0].weight_kg, 100)
})

Deno.test('get_training_summary: weeks is clamped to 1..12', async () => {
  const out = json(await getTrainingSummary(await ctx(), { weeks: 40 }))
  assertEquals(out.weekly.length, 12)
})

Deno.test('get_bodyweight: entries and slope', async () => {
  const out = json(await getBodyweight(await ctx(), {}))
  assertEquals(out.entries.length, 2)
  assertEquals(out.entries[1], {
    date: '2026-09-24',
    weight_kg: 81.6,
    weight_display: '179.9 lb (81.6 kg)',
    body_fat_pct: 15,
  })
  assertEquals(out.slope_kg_per_week_4w, 0.3)
})

Deno.test('search_exercises: words ANDed, custom exercises included, limit clamped to 25', async () => {
  const c = await ctx()
  const out = json(await searchExercises(c, { query: 'bench barbell' }))
  assertEquals(out.results.map((r: { id: string }) => r.id).sort(), ['0025', '0047'])
  const chest = json(await searchExercises(c, { body_part: 'Chest', limit: 99 }))
  assertEquals(chest.results.length, 4)
  assertEquals(chest.results[0], {
    id: 'custom-cable-fly',
    name: 'cable fly (low)',
    body_part: 'chest',
    equipment: 'cable',
    target: 'pectorals',
    custom: true,
  })
})

Deno.test('search_exercises: needs at least one criterion', async () => {
  await assertRejects(() => searchExercises(ctx0(), {}), ToolError)
})
