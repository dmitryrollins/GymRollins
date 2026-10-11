// Runs the shared fixture (app/fixtures/plan-changes.json) — the same file the Swift tests use
// (ios/Packages/GymCore/Tests/GymCoreTests/PlanChangeValidatorTests.swift) — against the TypeScript port, plus
// the 26-change and 8th-routine limit checks that aren't in the fixture (mirrors PlanChangeValidatorTests).
import { assertEquals } from 'jsr:@std/assert@^1'
import { type PlanChange, type PlanProposal, type PlanSnapshot, validateProposal } from './plan-validation.ts'

interface FixtureViolation {
  changeId: string | null
  field: string
}

interface FixtureCase {
  name: string
  proposal: PlanProposal
  violations: FixtureViolation[]
}

interface Fixture {
  /** The owner's date the fixture's `today` changes are checked against. */
  today: string
  library: string[]
  plan: PlanSnapshot
  cases: FixtureCase[]
}

const fixtureUrl = new URL('../../../fixtures/plan-changes.json', import.meta.url)

async function loadFixture(): Promise<Fixture> {
  const text = await Deno.readTextFile(fixtureUrl)
  return JSON.parse(text) as Fixture
}

function violationKey(v: FixtureViolation): string {
  return `${v.changeId ?? '∅'}::${v.field}`
}

const fixture = await loadFixture()

for (const testCase of fixture.cases) {
  Deno.test({
    name: `plan-changes fixture: ${testCase.name}`,
    permissions: { read: true },
    fn: () => {
      const library = new Set(fixture.library)
      const got = validateProposal(testCase.proposal, fixture.plan, (id) => library.has(id), {
        today: fixture.today,
      })
      const gotKeys = new Set(got.map(violationKey))
      const wantKeys = new Set(testCase.violations.map(violationKey))
      assertEquals(
        gotKeys,
        wantKeys,
        `${testCase.name}: got [${[...gotKeys].join(', ')}] want [${[...wantKeys].join(', ')}]`,
      )
    },
  })
}

Deno.test({
  name: '26 changes exceeds the max-changes limit',
  permissions: { read: true },
  fn: () => {
    const changes: PlanChange[] = Array.from({ length: 26 }, (_, i) => ({
      id: `c${i}`,
      type: 'sets',
      routineId: 'push',
      exerciseId: 'bench',
      sets: 3,
    }))
    const got = validateProposal({ summary: 'Many', changes }, fixture.plan, () => true)
    assertEquals(got.some((v) => v.field === 'changes'), true)
  },
})

Deno.test({
  name: 'adding an 8th routine hits the routine limit',
  permissions: { read: true },
  fn: () => {
    // The fixture plan already has 3 routines (push, pull, legs); 4 more brings it to 7 (the max), and the
    // 5th add (index 4) must be rejected.
    const changes: PlanChange[] = Array.from({ length: 5 }, (_, i) => ({
      id: `a${i}`,
      type: 'add-routine',
      routineId: `r${i}`,
      name: `R${i}`,
    }))
    const got = validateProposal({ summary: 'Lots', changes }, fixture.plan, () => true)
    assertEquals(got.some((v) => v.changeId === 'a4' && v.field === 'routineId'), true)
  },
})

// ---- today (one-off routine for a date) ---------------------------------------------------------------------

function todayViolations(date: string, options: { today?: string; slackDays?: number }): string[] {
  const change: PlanChange = { id: 't1', type: 'today', routineId: 'push', date }
  return validateProposal({ summary: 'Today', changes: [change] }, fixture.plan, () => true, options)
    .map((v) => `${v.field}: ${v.message}`)
}

Deno.test("today: the owner's date up to 7 days ahead is valid; earlier or later is not", () => {
  assertEquals(todayViolations('2026-09-26', { today: '2026-09-26' }), [])
  assertEquals(todayViolations('2026-10-03', { today: '2026-09-26' }), [])
  assertEquals(todayViolations('2026-09-25', { today: '2026-09-26' }), ['date: Date passed'])
  assertEquals(todayViolations('2026-10-04', { today: '2026-09-26' }), ['date: At most 7 days ahead'])
})

Deno.test("today: slackDays widens the window both ways (the server doesn't know the owner's time zone)", () => {
  const opts = { today: '2026-09-26', slackDays: 1 }
  assertEquals(todayViolations('2026-09-25', opts), [])
  assertEquals(todayViolations('2026-10-04', opts), [])
  assertEquals(todayViolations('2026-09-24', opts), ['date: Date passed'])
  assertEquals(todayViolations('2026-10-05', opts), ['date: At most 7 days ahead'])
})

Deno.test('today: without a reference date only the format is checked; month/year boundaries count days', () => {
  assertEquals(todayViolations('2020-01-01', {}), [])
  assertEquals(todayViolations('2026-13-01', {}), ['date: Must be a date like 2026-10-03'])
  assertEquals(todayViolations('2028-02-29', {}), [])
  assertEquals(todayViolations('2027-02-29', {}), ['date: Must be a date like 2026-10-03'])
  assertEquals(todayViolations('2027-01-02', { today: '2026-12-31' }), [])
  assertEquals(todayViolations('2027-01-08', { today: '2026-12-31' }), ['date: At most 7 days ahead'])
})

Deno.test('today: a routine paused in the snapshot is refused; one resumed earlier in the proposal is fine', () => {
  const plan: PlanSnapshot = {
    routines: [{ id: 'legs', name: 'Legs', exerciseIds: ['leg-extension'], paused: true }],
  }
  const today: PlanChange = { id: 't1', type: 'today', routineId: 'legs', date: '2026-09-26' }
  const paused = validateProposal({ summary: 'x', changes: [today] }, plan, () => true, {
    today: '2026-09-26',
  })
  assertEquals(paused.map((v) => `${v.changeId}::${v.field}`), ['t1::routineId'])
  const resume: PlanChange = { id: 'r1', type: 'pause-routine', routineId: 'legs', paused: false }
  const resumed = validateProposal({ summary: 'x', changes: [resume, today] }, plan, () => true, {
    today: '2026-09-26',
  })
  assertEquals(resumed, [])
})
