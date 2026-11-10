import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { DomainLimits } from '../src/shared/domain-limits.ts'
import {
  type CappedTable,
  countOf,
  type CountedTable,
  seedCount,
  seedProposals,
  seedRows,
} from './cap-fixtures.ts'
import { genericItem, insertGym, insertListing, insertUser } from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'
import { appUUID, SAMPLES, workoutSample } from './samples.ts'

// The counts in account_rows themselves (plan 31, migrations/0010_account_caps.sql): a deleted row lowers its count,
// the migration's backfill counts rows stored before it, and an account at every cap can still be deleted.

const T = '2026-11-07T10:00:00.000000Z'
const OWNER: Readonly<Partial<Record<CountedTable, string>>> = { gyms: 'owner_id', gym_equipment: 'owner_id' }
const CAPPED: readonly CappedTable[] = [
  'workouts', 'bodyweight', 'routines', 'custom_exercises', 'exercise_prefs', 'gyms', 'gym_equipment',
]
/** Every table account_rows counts, and the cap on each. */
const CAPS: Readonly<Record<CountedTable, number>> = {
  workouts: DomainLimits.workoutsMax,
  bodyweight: DomainLimits.bodyweightsMax,
  routines: DomainLimits.routinesMax,
  custom_exercises: DomainLimits.customExercisesMax,
  exercise_prefs: DomainLimits.exercisePrefsMax,
  gyms: DomainLimits.privateGymsTotalMax,
  gym_equipment: DomainLimits.privateListingsTotalMax,
  proposals: DomainLimits.proposalsMax,
  workout_entries: DomainLimits.accountEntriesMax,
  workout_sets: DomainLimits.accountSetsMax,
}
const COUNTED = Object.keys(CAPS) as CountedTable[]

/** Deletes one of the account's rows in `table` outright, as only a cascade does in the app today. */
async function deleteOne(table: CountedTable, userId: string): Promise<void> {
  const owner = OWNER[table] ?? 'user_id'
  await env.DB.prepare(
    `DELETE FROM ${table} WHERE rowid IN (SELECT rowid FROM ${table} WHERE ${owner} = ?1 LIMIT 1)`,
  ).bind(userId).run()
}

describe('a deleted row', () => {
  it.each([...CAPPED, 'proposals' as const])('lowers the count of %s by one', async (table) => {
    const userId = await insertUser()
    if (table === 'proposals') await seedProposals(userId, 3)
    else await seedRows(table, userId, 3)
    expect(await countOf(table, userId)).toBe(3)
    await deleteOne(table, userId)
    expect(await countOf(table, userId)).toBe(2)
  })

  it("lowers both counts when a private gym's deletion cascades to its listings", async () => {
    const userId = await insertUser()
    await seedRows('gym_equipment', userId, 3)
    expect([await countOf('gyms', userId), await countOf('gym_equipment', userId)]).toEqual([1, 3])
    await deleteOne('gyms', userId)
    expect([await countOf('gyms', userId), await countOf('gym_equipment', userId)]).toEqual([0, 0])
  })
})

/** The migration's own backfill statements, as the test D1 ran them. */
function backfill(): string[] {
  const migration = env.TEST_MIGRATIONS.find((m) => m.name === '0010_account_caps.sql')
  expect(migration, '0010_account_caps.sql').toBeDefined()
  return migration!.queries
    .map((q) => q.replace(/^(\s*--[^\n]*\n)*/, '').trim())
    .filter((q) => q.startsWith('INSERT INTO account_rows'))
}

describe("the migration's backfill", () => {
  it("counts every account's stored rows, deleted ones included, and private gyms and listings by owner only",
    async () => {
      const { token, userId: a } = await signUp()
      for (const table of CAPPED) await seedRows(table, a, 3)
      await seedProposals(a, 2)
      const entry = (position: number, sets: number) => ({
        id: appUUID(), exercise_id: `ex_${position}`, position, note: null, superset_group: null,
        sets: Array.from({ length: sets }, (_, j) => ({ id: appUUID(), position: j, w_kg: 60, r: 8 })),
      })
      const saved = await request('POST', '/v1/sync/workouts', {
        token, body: workoutSample({ entries: [entry(0, 3), entry(1, 3)] }),
      })
      expect(saved.status).toBe(200)
      const b = await insertUser()
      await seedRows('bodyweight', b, 5)
      await seedRows('gym_equipment', b, 2)
      // Shared gyms and listings have no owner: the backfill skips them, though `a` created them.
      const shared = await insertGym({ visibility: 'public', createdBy: a })
      await insertListing({ gym: shared, item: await genericItem(), visibility: 'public', addedBy: a })

      const statements = backfill()
      expect(statements).toHaveLength(COUNTED.length)
      await env.DB.prepare('DELETE FROM account_rows').run()
      await env.DB.batch(statements.map((q) => env.DB.prepare(q)))

      const counts = async (userId: string, tables: readonly CountedTable[]) =>
        Object.fromEntries(await Promise.all(tables.map(async (t) => [t, await countOf(t, userId)] as const)))
      expect(await counts(a, COUNTED)).toEqual({
        workouts: 4, bodyweight: 3, routines: 3, custom_exercises: 3, exercise_prefs: 3, gyms: 4, gym_equipment: 3,
        proposals: 2, workout_entries: 2, workout_sets: 6,
      })
      expect(await counts(b, ['bodyweight', 'gyms', 'gym_equipment'])).toEqual({
        bodyweight: 5, gyms: 1, gym_equipment: 2,
      })
      const owned = await env.DB.prepare(
        "SELECT (SELECT sum(n) FROM account_rows WHERE tbl = 'gyms') AS gyms, " +
          "(SELECT sum(n) FROM account_rows WHERE tbl = 'gym_equipment') AS listings, " +
          '(SELECT count(*) FROM gyms WHERE owner_id IS NOT NULL) AS private_gyms, ' +
          '(SELECT count(*) FROM gym_equipment WHERE owner_id IS NOT NULL) AS private_listings, ' +
          '(SELECT count(*) FROM gyms WHERE owner_id IS NULL) AS shared_gyms',
      ).first<Record<string, number>>()
      expect(owned!.gyms).toBe(owned!.private_gyms)
      expect(owned!.listings).toBe(owned!.private_listings)
      expect(owned!.shared_gyms).toBeGreaterThan(0)
    })
})

/** `n` generated rows (k = 0…n-1) in one statement: ?1 the account, ?2 n, ?3 an id prefix, ?4 T. */
const SEQ = 'WITH RECURSIVE seq(k) AS (SELECT 0 UNION ALL SELECT k + 1 FROM seq WHERE k + 1 < ?2) '
/** A UUID-shaped id, unique per prefix, tag and k. */
const uuid = (tag: number, k = 'k') => `printf('%s-%04x-4000-8000-%012x', ?3, ${tag}, ${k})`
const GENERIC_DUMBBELLS =
  "(SELECT id FROM equipment_items WHERE kind_id = 'dumbbells' AND brand IS NULL AND model IS NULL)"

/** Each table at its cap. Workouts hold 5 entries of 5 sets, so entries and sets end at their caps too. */
const AT_CAP: readonly { readonly table: CountedTable; readonly sql: string }[] = [
  {
    table: 'workouts',
    sql: `INSERT INTO workouts (id, user_id, started_at, name, client_updated_at, updated_at)
      SELECT ${uuid(1)}, ?1, ?4, 'Seeded', ?4, ?4 FROM seq`,
  },
  {
    table: 'workout_entries',
    sql: `INSERT INTO workout_entries (id, workout_id, user_id, exercise_id, position)
      SELECT ${uuid(2)}, ${uuid(1, 'k / 5')}, ?1, 'bench_press', k % 5 FROM seq`,
  },
  {
    table: 'workout_sets',
    sql: `INSERT INTO workout_sets (id, entry_id, user_id, position, w_kg, r)
      SELECT ${uuid(3)}, ${uuid(2, 'k / 5')}, ?1, k % 5, 60, 8 FROM seq`,
  },
  {
    table: 'bodyweight',
    sql: `INSERT INTO bodyweight (id, user_id, measured_at, w_kg, client_updated_at, updated_at)
      SELECT ${uuid(4)}, ?1, ?4, 80, ?4, ?4 FROM seq`,
  },
  {
    table: 'routines',
    sql: `INSERT INTO routines (id, user_id, name, client_updated_at, updated_at)
      SELECT ${uuid(5)}, ?1, 'Seeded', ?4, ?4 FROM seq`,
  },
  {
    table: 'custom_exercises',
    sql: `INSERT INTO custom_exercises (id, user_id, n, bp, eq, tg, client_updated_at, updated_at)
      SELECT 'custom-' || ${uuid(6)}, ?1, 'Seeded', 'legs', 'machine', 'quads', ?4, ?4 FROM seq`,
  },
  {
    table: 'exercise_prefs',
    sql: `INSERT INTO exercise_prefs (user_id, exercise_id, pref, client_updated_at, updated_at)
      SELECT ?1, 'ex_' || ?3 || '_' || k, 'more', ?4, ?4 FROM seq`,
  },
  // 100 live (the live cap), the rest deleted.
  {
    table: 'gyms',
    sql: `INSERT INTO gyms (id, visibility, owner_id, created_by, name, client_updated_at, created_at, updated_at,
        deleted_at)
      SELECT ${uuid(7)}, 'private', ?1, ?1, 'Seeded', ?4, ?4, ?4, CASE WHEN k >= 100 THEN ?4 END FROM seq`,
  },
  // 1,000 live (the live cap), the rest deleted, all at the live gyms.
  {
    table: 'gym_equipment',
    sql: `INSERT INTO gym_equipment (id, gym_id, item_id, visibility, owner_id, added_by, client_updated_at, created_at,
        updated_at, deleted_at)
      SELECT ${uuid(8)}, ${uuid(7, 'k % 100')}, ${GENERIC_DUMBBELLS}, 'private', ?1, ?1, ?4, ?4, ?4,
        CASE WHEN k >= 1000 THEN ?4 END FROM seq`,
  },
  // 100 waiting (the pending cap), the rest dismissed.
  {
    table: 'proposals',
    sql: `INSERT INTO proposals (id, user_id, created_at, summary, changes, status, applied_change_ids,
        client_updated_at, updated_at)
      SELECT ${uuid(9)}, ?1, ?4, 'Seeded', '[{"id":"c1","type":"weight"}]',
        CASE WHEN k < 100 THEN 'pending' ELSE 'dismissed' END, '[]', ?4, ?4 FROM seq`,
  },
]

/** Fills the account to every cap, generating the rows in SQL; the logged counts are set to the rows written. */
async function fillToEveryCap(userId: string): Promise<void> {
  const prefix = crypto.randomUUID().slice(0, 8)
  for (const { table, sql } of AT_CAP) {
    const statement = SEQ + sql
    // D1 wants exactly as many values as the statement's highest ?N.
    const used = Math.max(...[...statement.matchAll(/\?(\d)/g)].map((m) => Number(m[1])))
    await env.DB.prepare(statement).bind(...[userId, CAPS[table], prefix, T].slice(0, used)).run()
  }
  await seedCount('workout_entries', userId, DomainLimits.accountEntriesMax)
  await seedCount('workout_sets', userId, DomainLimits.accountSetsMax)
}

describe('an account at every cap', () => {
  it('is deleted whole, and leaves no row and no count behind', async () => {
    const { token, userId } = await signUp()
    await fillToEveryCap(userId)
    for (const table of COUNTED) expect(await countOf(table, userId), table).toBe(CAPS[table])
    const oneMore = await request('POST', '/v1/sync/bodyweight', { token, body: { rows: [SAMPLES.bodyweight()] } })
    expect(oneMore.status).toBe(422)

    expect((await request('DELETE', '/v1/account', { token })).status).toBe(204)
    for (const table of COUNTED) expect(await countOf(table, userId), table).toBe(0)
    const left = await env.DB.prepare('SELECT count(*) AS n FROM account_rows WHERE user_id = ?1').bind(userId)
      .first<{ n: number }>()
    expect(left!.n).toBe(0)
  }, 120_000)
})
