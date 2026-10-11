import { assert, assertEquals, assertRejects } from 'jsr:@std/assert@^1'
import type { PlanChange, PlanProposal, PlanSnapshot } from '../../_shared/plan-validation.ts'
import type { RoutineRow } from '../db.ts'
import { FakeDb, loadOwnerData } from './fake_db.ts'
import { ToolError, type ToolResult } from './result.ts'
import { getProposal, logBodyweight, planSnapshot, proposePlanChanges } from './write.ts'

const NOW = new Date('2026-09-26T12:00:00Z')

interface Fixture {
  library: string[]
  plan: PlanSnapshot
  cases: { name: string; proposal: PlanProposal; violations: { changeId: string | null; field: string }[] }[]
}

const fixture = JSON.parse(
  await Deno.readTextFile(new URL('../../../../fixtures/plan-changes.json', import.meta.url)),
) as Fixture

// A FakeDb whose plan and library are the shared fixture's (routine ids 'push'/'pull'/'legs', library ids).
function fixtureDb(paused: string[] = [], weights: Record<string, number> = {}): FakeDb {
  const routines: RoutineRow[] = fixture.plan.routines.map((r, i) => ({
    id: r.id,
    name: r.name,
    policy: 'double',
    position: i,
    paused: paused.includes(r.id),
    exercises: r.exerciseIds.map((exerciseId, j) => ({
      id: `${r.id}-${j}`,
      exercise_id: exerciseId,
      position: j,
      sets: 3,
      reps: r.reps?.[exerciseId] ?? 10,
      reps_min: r.repsMin?.[exerciseId] ?? null,
      weight_kg: weights[exerciseId] ?? null,
      mode: 'reps',
    })),
  }))
  const library = fixture.library.map((id) => ({ id, n: id, bp: 'chest', eq: 'barbell', tg: 'pectorals' }))
  return new FakeDb({ profile: null, library, routines, schedule: [], workouts: [], bodyweight: [] })
}

// deno-lint-ignore no-explicit-any
function json(r: ToolResult): any {
  return JSON.parse(r.content[0].text)
}

Deno.test('planSnapshot: routine ids, library exercise ids and effective rep ranges', async () => {
  const data = await loadOwnerData()
  const snap = planSnapshot(data.routines)
  assertEquals(snap.routines[0], {
    id: '6f1c1e2a-4b1d-4c3e-9a51-2d7a1b0c0001',
    name: 'Push + Arms',
    exerciseIds: ['0025', '0047'],
    reps: { '0025': 10, '0047': 12 },
    repsMin: { '0025': 8, '0047': 8 },
    paused: false,
  })
  assertEquals(snap.routines[1].repsMin, {})
})

Deno.test("propose_plan_changes: the fixture's valid proposal is inserted once and returns its id", async () => {
  const db = fixtureDb()
  const valid = fixture.cases.find((c) => c.name === 'valid knee-break proposal')!
  const r = await proposePlanChanges({ db, now: NOW }, valid.proposal)
  assert(!r.isError, r.content[0].text)
  assertEquals(db.insertedProposals.length, 1)
  assertEquals(db.insertedProposals[0].summary, valid.proposal.summary)
  assertEquals(db.insertedProposals[0].changes, valid.proposal.changes)
  const out = json(r)
  assertEquals(out.proposal_id, 'prop-1')
  assertEquals(out.status, 'pending')
  assert(String(out.applies).includes('reviews it in the app'))
})

Deno.test('propose_plan_changes: every invalid fixture case → isError with violations, nothing inserted', async () => {
  for (const c of fixture.cases.filter((x) => x.violations.length > 0)) {
    const db = fixtureDb()
    const r = await proposePlanChanges({ db, now: NOW }, c.proposal)
    assertEquals(r.isError, true, c.name)
    assertEquals(db.insertedProposals.length, 0, c.name)
    const got = new Set(
      json(r).violations.map((v: { change_id: string | null; field: string }) =>
        `${v.change_id ?? '∅'}::${v.field}`
      ),
    )
    const want = new Set(c.violations.map((v) => `${v.changeId ?? '∅'}::${v.field}`))
    assertEquals(got, want, c.name)
  }
})

Deno.test('propose_plan_changes: a real-plan weight change on bench is valid', async () => {
  const db = new FakeDb(await loadOwnerData())
  const change: PlanChange = {
    id: 'c1',
    type: 'weight',
    routineId: '6f1c1e2a-4b1d-4c3e-9a51-2d7a1b0c0001',
    exerciseId: '0025',
    weightKg: 61.235,
    reason: 'Hit 3×10 last week',
  }
  const r = await proposePlanChanges({ db, now: NOW }, { summary: 'Bench +5 lb', changes: [change] })
  assert(!r.isError, r.content[0].text)
  assertEquals(db.insertedProposals.length, 1)
})

Deno.test('get_proposal: status and applied change ids; unknown id → not found', async () => {
  const data = await loadOwnerData()
  data.proposals = [{
    id: 'e0e0e0e0-0000-4000-8000-000000000001',
    created_at: '2026-09-25T10:00:00Z',
    status: 'partial',
    summary: 'Bench +5 lb',
    changes: [{ id: 'c1' }, { id: 'c2' }],
    applied_change_ids: ['c1'],
    resolved_at: '2026-09-25T11:00:00Z',
  }]
  const db = new FakeDb(data)
  const out = json(await getProposal({ db, now: NOW }, { id: 'e0e0e0e0-0000-4000-8000-000000000001' }))
  assertEquals(out.status, 'partial')
  assertEquals(out.applied_change_ids, ['c1'])
  assertEquals(out.change_count, 2)
  await assertRejects(
    () => getProposal({ db, now: NOW }, { id: 'e0e0e0e0-0000-4000-8000-00000000ffff' }),
    ToolError,
    'not found',
  )
})

Deno.test('log_bodyweight: inserts with a new id; a date-only value is noon UTC; defaults to now', async () => {
  const db = new FakeDb(await loadOwnerData())
  const out = json(
    await logBodyweight({ db, now: NOW }, { weight_kg: 81.9, date: '2026-09-25', body_fat_pct: 14.5 }),
  )
  assertEquals(db.insertedBodyweight.length, 1)
  const row = db.insertedBodyweight[0]
  assertEquals(row.measured_at, '2026-09-25T12:00:00.000Z')
  assertEquals(row.w_kg, 81.9)
  assertEquals(row.bf_pct, 14.5)
  assertEquals(out.id, row.id)
  assertEquals(out.weight_display, '180.6 lb (81.9 kg)')
  await logBodyweight({ db, now: NOW }, { weight_kg: 82 })
  assertEquals(db.insertedBodyweight[1].measured_at, NOW.toISOString())
  assertEquals(db.insertedBodyweight[1].bf_pct, undefined)
})

Deno.test('propose_plan_changes: a today date is checked against the UTC date ±1 day (owner time zone unknown)', async () => {
  // NOW is 2026-09-26 12:00 UTC: the owner may already be on the 27th, or still on the 25th.
  for (const date of ['2026-09-25', '2026-09-26', '2026-10-03', '2026-10-04']) {
    const db = fixtureDb()
    const changes: PlanChange[] = [{ id: 'c1', type: 'today', routineId: 'pull', date }]
    const r = await proposePlanChanges({ db, now: NOW }, { summary: 'One-off', changes })
    assert(!r.isError, `${date}: ${r.content[0].text}`)
    assertEquals(db.insertedProposals[0].changes, changes)
  }
  for (const [date, message] of [['2026-09-24', 'Date passed'], ['2026-10-05', 'At most 7 days ahead']]) {
    const db = fixtureDb()
    const changes: PlanChange[] = [{ id: 'c1', type: 'today', routineId: 'pull', date }]
    const r = await proposePlanChanges({ db, now: NOW }, { summary: 'One-off', changes })
    assertEquals(r.isError, true, date)
    assertEquals(json(r).violations, [{ change_id: 'c1', field: 'date', message }])
    assertEquals(db.insertedProposals.length, 0)
  }
})

Deno.test('propose_plan_changes: add-routine + today for a one-off session (the "Home · KB Upper" case)', async () => {
  const db = fixtureDb()
  const r = await proposePlanChanges({ db, now: NOW }, {
    summary: 'Home session today',
    changes: [
      { id: 'c1', type: 'add-routine', routineId: 'home-kb', name: 'Home · KB Upper' },
      { id: 'c2', type: 'add-exercise', routineId: 'home-kb', exerciseId: 'dips', sets: 3, reps: 10 },
      { id: 'c3', type: 'today', routineId: 'home-kb', date: '2026-09-26', reason: 'Training at home' },
    ],
  })
  assert(!r.isError, r.content[0].text)
  assertEquals(json(r).changes, 3)
})

Deno.test('propose_plan_changes: today on a paused routine is refused', async () => {
  const db = fixtureDb(['legs'])
  const r = await proposePlanChanges({ db, now: NOW }, {
    summary: 'Legs today',
    changes: [{ id: 'c1', type: 'today', routineId: 'legs', date: '2026-09-26' }],
  })
  assertEquals(r.isError, true)
  assertEquals(json(r).violations.map((v: { field: string }) => v.field), ['routineId'])
  assertEquals(db.insertedProposals.length, 0)
})

Deno.test('log_bodyweight: a date in the future is rejected', async () => {
  const db = new FakeDb(await loadOwnerData())
  await assertRejects(
    () => logBodyweight({ db, now: NOW }, { weight_kg: 82, date: '2026-10-05' }),
    ToolError,
    'future',
  )
  assertEquals(db.insertedBodyweight.length, 0)
})

Deno.test('propose_plan_changes: a swap without weightKg away from a weighted exercise is saved with a warning', async () => {
  const db = fixtureDb([], { 'machine-shoulder-press': 40 })
  const r = await proposePlanChanges({ db, now: NOW }, {
    summary: 'Swap the press',
    changes: [SWAP],
  })
  assert(!r.isError, r.content[0].text)
  assertEquals(json(r).warnings, [{
    change_id: 'c1',
    message:
      "No weightKg: machine-shoulder-press's 40 kg isn't carried over, so db-shoulder-press starts with no " +
      'planned weight (0 until the owner types one). Propose a weight change for it.',
  }])
  assertEquals(db.insertedProposals.length, 1)
})

Deno.test('propose_plan_changes: a swap with weightKg, or away from an unweighted exercise, has no warnings', async () => {
  const unweighted = await proposePlanChanges({ db: fixtureDb(), now: NOW }, {
    summary: 'Swap',
    changes: [SWAP],
  })
  assertEquals(json(unweighted).warnings, undefined)
  const withWeight = await proposePlanChanges({
    db: fixtureDb([], { 'machine-shoulder-press': 40 }),
    now: NOW,
  }, {
    summary: 'Swap with weight',
    changes: [{ ...SWAP, weightKg: 24 }],
  })
  assertEquals(json(withWeight).warnings, undefined)
})

const SWAP: PlanChange = {
  id: 'c1',
  type: 'swap-exercise',
  routineId: 'pull',
  exerciseId: 'machine-shoulder-press',
  toExerciseId: 'db-shoulder-press',
}
