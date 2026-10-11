import { assert, assertEquals } from 'jsr:@std/assert@^1'
import type { PlanChange } from '../../_shared/plan-validation.ts'
import { FakeDb, loadOwnerData } from './fake_db.ts'
import { getPlan, searchExercises } from './read.ts'
import { TOOL_SPECS } from './register.ts'
import type { ToolResult } from './result.ts'
import { proposePlanChanges } from './write.ts'

const NOW = new Date('2026-09-26T12:00:00Z')
const PUSH = '6f1c1e2a-4b1d-4c3e-9a51-2d7a1b0c0001'

// deno-lint-ignore no-explicit-any
function json(r: ToolResult): any {
  return JSON.parse(r.content[0].text)
}

async function db(): Promise<FakeDb> {
  const data = await loadOwnerData()
  data.prefs = [
    { exercise_id: '0025', pref: 'more' },
    { exercise_id: '0289', pref: 'never' },
    { exercise_id: '0405', pref: 'less' },
    { exercise_id: '0043', pref: 'normal' },
  ]
  return new FakeDb(data)
}

Deno.test('get_plan: exercise_preferences lists more / less / never with names, not normal', async () => {
  const out = json(await getPlan({ db: await db(), now: NOW }))
  assertEquals(out.exercise_preferences, {
    more: [{ id: '0025', name: 'barbell bench press' }],
    less: [{ id: '0405', name: 'dumbbell seated shoulder press' }],
    never: [{ id: '0289', name: 'dumbbell bench press' }],
  })
})

Deno.test('get_plan: no preferences → empty lists', async () => {
  const out = json(await getPlan({ db: new FakeDb(await loadOwnerData()), now: NOW }))
  assertEquals(out.exercise_preferences, { more: [], less: [], never: [] })
})

Deno.test('search_exercises: results carry the owner preference, never ones marked', async () => {
  const out = json(await searchExercises({ db: await db(), now: NOW }, { query: 'bench press' }))
  const byId = Object.fromEntries(out.results.map((r: { id: string }) => [r.id, r]))
  assertEquals(byId['0025'].preference, 'more')
  assertEquals(byId['0289'].preference, 'never')
  assertEquals(byId['0047'].preference, undefined, 'normal is omitted')
})

Deno.test('propose_plan_changes: adding or swapping to a "never" exercise is refused, nothing saved', async () => {
  const d = await db()
  const add: PlanChange = {
    id: 'c1',
    type: 'add-exercise',
    routineId: PUSH,
    exerciseId: '0289',
    sets: 3,
    reps: 10,
  }
  const swap: PlanChange = {
    id: 'c2',
    type: 'swap-exercise',
    routineId: PUSH,
    exerciseId: '0047',
    toExerciseId: '0289',
  }
  for (const [change, field] of [[add, 'exerciseId'], [swap, 'toExerciseId']] as const) {
    const r = await proposePlanChanges({ db: d, now: NOW }, { summary: 'DB bench', changes: [change] })
    assertEquals(r.isError, true, change.id)
    const violations = json(r).violations as { change_id: string; field: string; message: string }[]
    assertEquals(violations.map((v) => `${v.change_id}::${v.field}`), [`${change.id}::${field}`])
    assert(violations[0].message.includes("Don't recommend again"), violations[0].message)
  }
  assertEquals(d.insertedProposals.length, 0)
})

Deno.test('propose_plan_changes refuses a "never" exercise even when the plan is hidden from Claude', async () => {
  const d = await db()
  d.prefsHidden = true // mcp_read_plan off: RLS hides exercise_prefs
  const add: PlanChange = {
    id: 'c1',
    type: 'add-exercise',
    routineId: PUSH,
    exerciseId: '0289',
    sets: 3,
    reps: 10,
  }
  const r = await proposePlanChanges({ db: d, now: NOW }, { summary: 'DB bench', changes: [add] })
  assertEquals(r.isError, true)
  assertEquals(d.insertedProposals.length, 0)
})

Deno.test('search_exercises reads preferences only for the results', async () => {
  const d = await db()
  await searchExercises({ db: d, now: NOW }, { query: 'bench press' })
  const asked = d.prefQueries.at(-1) ?? []
  assert(asked.includes('0025') && asked.includes('0289'), JSON.stringify(asked))
})

Deno.test('propose_plan_changes: removing a "never" exercise and adding a "less" one are fine', async () => {
  const data = await loadOwnerData()
  data.prefs = [{ exercise_id: '0047', pref: 'never' }, { exercise_id: '0405', pref: 'less' }]
  const d = new FakeDb(data)
  const changes: PlanChange[] = [
    { id: 'c1', type: 'remove-exercise', routineId: PUSH, exerciseId: '0047' },
    { id: 'c2', type: 'add-exercise', routineId: PUSH, exerciseId: '0405', sets: 3, reps: 10 },
  ]
  const r = await proposePlanChanges({ db: d, now: NOW }, { summary: 'Tidy', changes })
  assert(!r.isError, r.content[0].text)
  assertEquals(d.insertedProposals.length, 1)
})

Deno.test('tool descriptions tell Claude never to propose "never" exercises', () => {
  const byName = Object.fromEntries(TOOL_SPECS.map((s) => [s.name, s.description]))
  for (const name of ['get_plan', 'search_exercises', 'propose_plan_changes']) {
    assert(/never/.test(byName[name]) && /Don't recommend again/.test(byName[name]), name)
  }
})
