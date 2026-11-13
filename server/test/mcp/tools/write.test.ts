import planChangesJson from '../../../../fixtures/plan-changes.json?raw'
import { test } from 'vitest'
import { assert, assertEquals, assertRejects } from '../../assert.ts'
import type { PlanChange, PlanProposal, PlanSnapshot } from '../../../src/shared/plan-validation.ts'
import type { RoutineRow } from '../../../src/mcp/db.ts'
import { FakeDb, loadOwnerData } from '../fake-db.ts'
import { ToolError, type ToolResult } from '../../../src/mcp/tools/result.ts'
import {
  APPLIES_AFTER_REVIEW,
  APPLIES_AUTOMATICALLY,
  DISMISSED_NOTE,
  PARTIAL_NOTE,
  SOME_WONT_APPLY_NOTE,
  WONT_APPLY_NOTE,
  getProposal,
  logBodyweight,
  planSnapshot,
  proposePlanChanges,
} from '../../../src/mcp/tools/write.ts'

const NOW = new Date('2026-09-26T12:00:00Z')

interface Fixture {
  library: string[]
  plan: PlanSnapshot
  cases: { name: string; proposal: PlanProposal; violations: { changeId: string | null; field: string }[] }[]
}

const fixture = JSON.parse(
  planChangesJson,
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
function json(r: ToolResult): any {
  return JSON.parse(r.content[0].text)
}

test('planSnapshot: routine ids, library exercise ids and effective rep ranges', async () => {
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

test("change_plan: the fixture's valid proposal is inserted once and returns its id", async () => {
  const db = fixtureDb()
  const valid = fixture.cases.find((c) => c.name === 'valid knee-break proposal')!
  const r = await proposePlanChanges({ db, now: NOW }, valid.proposal)
  assert(!r.isError, r.content[0].text)
  assertEquals(db.insertedProposals.length, 1)
  assertEquals(db.insertedProposals[0].summary, valid.proposal.summary)
  assertEquals(db.insertedProposals[0].changes, valid.proposal.changes)
  const out = json(r)
  assertEquals(out.id, 'prop-1')
  assertEquals(out.proposal_id, undefined)
  assertEquals(out.status, 'waiting_for_review')
  assertEquals(out.auto_apply, false)
  assert(String(out.applies).includes('Tell them to review it there'), String(out.applies))
})

test('change_plan: with "Apply changes without asking" on, the agent is told the change is made', async () => {
  const data = await loadOwnerData()
  data.profile = { ...data.profile!, mcp_auto_apply: true }
  const db = new FakeDb(data)
  const change: PlanChange = {
    id: 'c1',
    type: 'weight',
    routineId: '6f1c1e2a-4b1d-4c3e-9a51-2d7a1b0c0001',
    exerciseId: '0025',
    weightKg: 61.235,
    reason: 'Hit 3×10 last week',
  }
  const out = json(await proposePlanChanges({ db, now: NOW }, { summary: 'Bench +5 lb', changes: [change] }))
  assertEquals(out.auto_apply, true)
  assertEquals(out.status, 'applies_when_app_opens')
  assertEquals(out.applies, APPLIES_AUTOMATICALLY)
  assert(String(out.applies).includes("Tell the owner it's done"), String(out.applies))
  assert(String(out.applies).includes("Don't call it a proposal"), String(out.applies))
  assert(String(out.applies).includes('the app skips'), 'says what happens to a part that no longer fits')
})

test('change_plan: every invalid fixture case → isError with violations, nothing inserted', async () => {
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

test('change_plan: a real-plan weight change on bench is valid', async () => {
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

test('get_plan_change: status and applied change ids; unknown id → not found', async () => {
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
  assertEquals(out.note, PARTIAL_NOTE)
  data.proposals = [{ ...data.proposals[0]!, status: 'dismissed', applied_change_ids: [] }]
  const dismissed = json(await getProposal({ db, now: NOW }, { id: 'e0e0e0e0-0000-4000-8000-000000000001' }))
  assertEquals(dismissed.note, DISMISSED_NOTE)
  await assertRejects(
    () => getProposal({ db, now: NOW }, { id: 'e0e0e0e0-0000-4000-8000-00000000ffff' }),
    ToolError,
    'not found',
  )
})

const PUSH = '6f1c1e2a-4b1d-4c3e-9a51-2d7a1b0c0001'
const BENCH_UP: PlanChange = { id: 'c1', type: 'weight', routineId: PUSH, exerciseId: '0025', weightKg: 61.235 }

test('get_plan_change: a pending change says how it will land, a resolved one does not', async () => {
  const id = 'e0e0e0e0-0000-4000-8000-000000000002'
  const row = {
    id,
    created_at: '2026-09-25T10:00:00Z',
    status: 'pending',
    summary: 'Bench +5 lb',
    changes: [BENCH_UP],
    applied_change_ids: [],
    resolved_at: null,
  }
  const cases = [
    [false, APPLIES_AFTER_REVIEW, 'waiting_for_review'],
    [true, APPLIES_AUTOMATICALLY, 'applies_when_app_opens'],
  ] as const
  for (const [autoApply, applies, status] of cases) {
    const data = await loadOwnerData()
    data.profile = { ...data.profile!, mcp_auto_apply: autoApply }
    data.proposals = [row]
    const out = json(await getProposal({ db: new FakeDb(data), now: NOW }, { id }))
    assertEquals(out.status, status)
    assertEquals(out.applies, applies)
  }
  const data = await loadOwnerData()
  data.profile = { ...data.profile!, mcp_auto_apply: true }
  data.proposals = [{ ...row, status: 'applied', applied_change_ids: ['c1'], resolved_at: '2026-09-25T11:00:00Z' }]
  const out = json(await getProposal({ db: new FakeDb(data), now: NOW }, { id }))
  assertEquals(out.status, 'applied')
  assertEquals(out.applies, undefined)
})

/** A pending row the app hasn't applied yet, checked again against today's plan (NOW is 2026-09-26). */
async function pendingRow(changes: PlanChange[], profile: { mcp_auto_apply?: boolean; mcp_read_plan?: boolean } = {}) {
  const data = await loadOwnerData()
  data.profile = { ...data.profile!, mcp_auto_apply: true, ...profile }
  const id = 'e0e0e0e0-0000-4000-8000-000000000003'
  data.proposals = [{
    id,
    created_at: '2026-09-19T10:00:00Z',
    status: 'pending',
    summary: 'Push on Sunday',
    changes,
    applied_change_ids: [],
    resolved_at: null,
  }]
  return { data, id }
}

test("get_plan_change: a waiting change that no longer fits the plan says the app won't apply it", async () => {
  const { data, id } = await pendingRow([{ id: 'c2', type: 'today', routineId: PUSH, date: '2026-09-20' }])
  const out = json(await getProposal({ db: new FakeDb(data), now: NOW }, { id }))
  assertEquals(out.status, 'wont_apply')
  assertEquals(out.wont_apply.map((w: { change_id: string }) => w.change_id), ['c2'])
  assert(String(out.wont_apply[0].message).includes('Date passed'), out.wont_apply[0].message)
  assertEquals(out.note, WONT_APPLY_NOTE)
  assertEquals(out.applies, undefined)
})

test('get_plan_change: a partly stale change names the part the app will skip and still applies the rest', async () => {
  const stale: PlanChange = { id: 'c2', type: 'today', routineId: PUSH, date: '2026-09-20' }
  const { data, id } = await pendingRow([BENCH_UP, stale])
  const out = json(await getProposal({ db: new FakeDb(data), now: NOW }, { id }))
  assertEquals(out.status, 'applies_when_app_opens')
  assertEquals(out.wont_apply.map((w: { change_id: string }) => w.change_id), ['c2'])
  assertEquals(out.note, SOME_WONT_APPLY_NOTE)
  assertEquals(out.applies, APPLIES_AUTOMATICALLY)
})

test('get_plan_change: a change that needed a skipped one is skipped too, as the app re-checks what is left', async () => {
  // The new routine's name is too long, so the app drops it and the day planned on it has no routine. The validator
  // never applies an invalid change, so one check finds both, as the app's repeated check does.
  const { data, id } = await pendingRow([
    { id: 'c1', type: 'add-routine', routineId: 'home', name: 'H'.repeat(41) },
    { id: 'c2', type: 'today', routineId: 'home', date: '2026-09-27' },
  ])
  const out = json(await getProposal({ db: new FakeDb(data), now: NOW }, { id }))
  assertEquals(out.wont_apply.map((w: { change_id: string }) => w.change_id), ['c1', 'c2'])
  assertEquals(out.status, 'wont_apply')
})

test("get_plan_change: with plan reads off the plan can't be checked, so nothing is called stale", async () => {
  const { data, id } = await pendingRow([BENCH_UP], { mcp_read_plan: false })
  data.routines = [] // what D1 answers with plan reads off
  const out = json(await getProposal({ db: new FakeDb(data), now: NOW }, { id }))
  assertEquals(out.status, 'applies_when_app_opens')
  assertEquals(out.wont_apply, undefined)
  assertEquals(out.note, undefined)
})

test('log_bodyweight: inserts with a new id; a date-only value is noon UTC; defaults to now', async () => {
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

test('change_plan: a today date is checked against the UTC date ±1 day (owner time zone unknown)', async () => {
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

test('change_plan: add-routine + today for a one-off session (the "Home · KB Upper" case)', async () => {
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

test('change_plan: today on a paused routine is refused', async () => {
  const db = fixtureDb(['legs'])
  const r = await proposePlanChanges({ db, now: NOW }, {
    summary: 'Legs today',
    changes: [{ id: 'c1', type: 'today', routineId: 'legs', date: '2026-09-26' }],
  })
  assertEquals(r.isError, true)
  assertEquals(json(r).violations.map((v: { field: string }) => v.field), ['routineId'])
  assertEquals(db.insertedProposals.length, 0)
})

test('log_bodyweight: a date in the future is rejected', async () => {
  const db = new FakeDb(await loadOwnerData())
  await assertRejects(
    () => logBodyweight({ db, now: NOW }, { weight_kg: 82, date: '2026-10-05' }),
    ToolError,
    'future',
  )
  assertEquals(db.insertedBodyweight.length, 0)
})

test('change_plan: a swap without weightKg away from a weighted exercise is saved with a warning', async () => {
  const db = fixtureDb([], { 'machine-shoulder-press': 40 })
  const r = await proposePlanChanges({ db, now: NOW }, {
    summary: 'Swap the press',
    changes: [SWAP],
  })
  assert(!r.isError, r.content[0].text)
  assertEquals(json(r).warnings, [{
    change_id: 'c1',
    message:
      "No weight: machine-shoulder-press's 40 kg isn't carried over, so db-shoulder-press starts with no " +
      'planned weight (0 until the owner types one). Add a weight change for it.',
  }])
  assertEquals(db.insertedProposals.length, 1)
})

test('change_plan: a swap with weightKg, or away from an unweighted exercise, has no warnings', async () => {
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

test('change_plan: weightLb alone stores the exact kg and the pound number', async () => {
  const db = new FakeDb(await loadOwnerData())
  const change: PlanChange = { id: 'c1', type: 'weight', routineId: PUSH, exerciseId: '0025', weightLb: 45 }
  const r = await proposePlanChanges({ db, now: NOW }, { summary: 'Bench to 45 lb', changes: [change] })
  assert(!r.isError, r.content[0].text)
  assertEquals(db.insertedProposals[0]!.changes, [{ ...change, weightKg: 45 * 0.45359237, weightLb: 45 }])
})

test('change_plan: weightKg and weightLb that agree are both kept; weightKg alone gets no weightLb', async () => {
  const db = new FakeDb(await loadOwnerData())
  const both: PlanChange = { id: 'c1', type: 'weight', routineId: PUSH, exerciseId: '0025', weightKg: 20.41, weightLb: 45 }
  const kgOnly: PlanChange = { id: 'c2', type: 'weight', routineId: PUSH, exerciseId: '0025', weightKg: 20.3 }
  const r = await proposePlanChanges({ db, now: NOW }, { summary: 'Two', changes: [both, kgOnly] })
  assert(!r.isError, r.content[0].text)
  assertEquals(db.insertedProposals[0]!.changes, [both, kgOnly])
})

test('change_plan: weightKg and weightLb that disagree by more than 0.01 kg are refused', async () => {
  const db = new FakeDb(await loadOwnerData())
  const change: PlanChange = { id: 'c1', type: 'weight', routineId: PUSH, exerciseId: '0025', weightKg: 20.3, weightLb: 45 }
  const r = await proposePlanChanges({ db, now: NOW }, { summary: 'Bench', changes: [change] })
  assert(r.isError === true)
  assertEquals(db.insertedProposals.length, 0)
  const v = JSON.parse(r.content[0].text).violations
  assertEquals(v[0].field, 'weightLb')
  assert(String(v[0].message).includes('different weights'), v[0].message)
})

test('change_plan: weightLb is 0–1100, and a weight change needs weightKg or weightLb', async () => {
  const db = new FakeDb(await loadOwnerData())
  const high: PlanChange = { id: 'c1', type: 'weight', routineId: PUSH, exerciseId: '0025', weightLb: 1101 }
  const none: PlanChange = { id: 'c2', type: 'weight', routineId: PUSH, exerciseId: '0025' }
  const r = await proposePlanChanges({ db, now: NOW }, { summary: 'Bench', changes: [high, none] })
  assert(r.isError === true)
  const v = JSON.parse(r.content[0].text).violations
  assertEquals(v.map((x: any) => [x.change_id, x.field]), [['c1', 'weightLb'], ['c2', 'weightKg']])
})

test('change_plan: a swap with weightLb has no weight warning', async () => {
  const r = await proposePlanChanges({ db: fixtureDb([], { 'machine-shoulder-press': 40 }), now: NOW }, {
    summary: 'Swap',
    changes: [{ ...SWAP, weightLb: 50 }],
  })
  assertEquals(json(r).warnings, undefined)
})
