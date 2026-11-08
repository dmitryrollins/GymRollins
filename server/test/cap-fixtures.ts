import { env } from 'cloudflare:workers'
import { expect } from 'vitest'

// Accounts near a storage cap (plan 31): rows written straight to D1, so a test can start a row or two short of
// 20,000. They go through the same triggers as a push, so the account's count (account_rows) includes them.

export type CappedTable =
  | 'workouts'
  | 'bodyweight'
  | 'routines'
  | 'custom_exercises'
  | 'exercise_prefs'
  | 'gyms'
  | 'gym_equipment'
/** The two counts a workout save moves itself (src/sync/workouts.ts). */
export type LoggedTable = 'workout_entries' | 'workout_sets'
/** Every table account_rows counts. Proposals have a seed of their own (seedProposals). */
export type CountedTable = CappedTable | LoggedTable | 'proposals'

const T = '2026-11-07T10:00:00.000000Z'
/** Every other seeded row is deleted: deleted rows count toward the caps too. */
const HALF_DELETED = 'CASE WHEN key % 2 = 1 THEN ?3 END'
const GENERIC_DUMBBELLS =
  "(SELECT id FROM equipment_items WHERE kind_id = 'dumbbells' AND brand IS NULL AND model IS NULL)"

/** Each table's columns, and their values over json_each: `value` a new key, ?1 the account, ?3 T, ?4 a gym. */
const FILL: Readonly<Record<CappedTable, { readonly columns: string; readonly values: string }>> = {
  workouts: {
    columns: 'id, user_id, started_at, name, client_updated_at, updated_at, deleted_at',
    values: `value, ?1, ?3, 'Seeded', ?3, ?3, ${HALF_DELETED}`,
  },
  bodyweight: {
    columns: 'id, user_id, measured_at, w_kg, client_updated_at, updated_at, deleted_at',
    values: `value, ?1, ?3, 80, ?3, ?3, ${HALF_DELETED}`,
  },
  routines: {
    columns: 'id, user_id, name, client_updated_at, updated_at, deleted_at',
    values: `value, ?1, 'Seeded', ?3, ?3, ${HALF_DELETED}`,
  },
  custom_exercises: {
    columns: 'id, user_id, n, bp, eq, tg, client_updated_at, updated_at, deleted_at',
    values: `value, ?1, 'Seeded', 'legs', 'machine', 'quads', ?3, ?3, ${HALF_DELETED}`,
  },
  // No deleted_at: a preference is only ever set.
  exercise_prefs: {
    columns: 'user_id, exercise_id, pref, client_updated_at, updated_at',
    values: "?1, value, 'more', ?3, ?3",
  },
  // All deleted, so the live caps (100 gyms, 1,000 listings) stay out of the way.
  gyms: {
    columns: 'id, visibility, owner_id, created_by, name, client_updated_at, created_at, updated_at, deleted_at',
    values: "value, 'private', ?1, ?1, 'Seeded', ?3, ?3, ?3, ?3",
  },
  gym_equipment: {
    columns:
      'id, gym_id, item_id, visibility, owner_id, added_by, client_updated_at, created_at, updated_at, deleted_at',
    values: `value, ?4, ${GENERIC_DUMBBELLS}, 'private', ?1, ?1, ?3, ?3, ?3, ?3`,
  },
}

const newKey = (table: CappedTable) => {
  if (table === 'custom_exercises') return `custom-${crypto.randomUUID()}`
  if (table === 'exercise_prefs') return `ex_${crypto.randomUUID()}`
  return crypto.randomUUID()
}

/** `count` rows of `table` for the account (listings at one private gym of their own, which counts as a gym). */
export async function seedRows(table: CappedTable, userId: string, count: number): Promise<void> {
  const { columns, values } = FILL[table]
  const keys = JSON.stringify(Array.from({ length: count }, () => newKey(table)))
  const insert = env.DB.prepare(`INSERT INTO ${table} (${columns}) SELECT ${values} FROM json_each(?2)`)
  if (table !== 'gym_equipment') {
    await insert.bind(userId, keys, T).run()
    return
  }
  const gym = crypto.randomUUID()
  await env.DB.prepare(
    `INSERT INTO gyms (${FILL.gyms.columns}) VALUES (?2, 'private', ?1, ?1, 'Seeded', ?3, ?3, ?3, ?3)`,
  ).bind(userId, gym, T).run()
  await insert.bind(userId, keys, T, gym).run()
}

/** `count` proposals for the account with `status`, written straight to D1; answers their ids. */
export async function seedProposals(userId: string, count: number, status = 'pending'): Promise<string[]> {
  const ids = Array.from({ length: count }, () => crypto.randomUUID())
  await env.DB.prepare(
    'INSERT INTO proposals (id, user_id, created_at, summary, changes, status, applied_change_ids, ' +
      'client_updated_at, updated_at) ' +
      `SELECT value, ?1, ?3, 'Seeded', '[{"id":"c1","type":"weight"}]', ?4, '[]', ?3, ?3 FROM json_each(?2)`,
  ).bind(userId, JSON.stringify(ids), T, status).run()
  return ids
}

const OWNER: Readonly<Record<string, string>> = { gyms: 'owner_id', gym_equipment: 'owner_id' }

/** The account's rows in `table`, deleted ones included; fails when the count kept in account_rows disagrees. */
export async function countOf(table: CountedTable, userId: string): Promise<number> {
  const owner = OWNER[table] ?? 'user_id'
  const row = (await env.DB.prepare(
    `SELECT (SELECT count(*) FROM ${table} WHERE ${owner} = ?1) AS stored, ` +
      '(SELECT n FROM account_rows WHERE user_id = ?1 AND tbl = ?2) AS kept',
  ).bind(userId, table).first<{ stored: number; kept: number | null }>())!
  expect(row.kept ?? 0, `account_rows for ${table}`).toBe(row.stored)
  return row.stored
}

/** The count account_rows keeps for the account. */
export async function kept(table: LoggedTable, userId: string): Promise<number> {
  const row = await env.DB.prepare('SELECT n FROM account_rows WHERE user_id = ?1 AND tbl = ?2').bind(userId, table)
    .first<{ n: number }>()
  return row?.n ?? 0
}

/** Sets the account's count of logged entries or sets without writing the rows: the caps read only the count. */
export async function seedCount(table: LoggedTable, userId: string, n: number): Promise<void> {
  await env.DB.prepare(
    'INSERT INTO account_rows (user_id, tbl, n) VALUES (?1, ?2, ?3) ' +
      'ON CONFLICT (user_id, tbl) DO UPDATE SET n = excluded.n',
  ).bind(userId, table, n).run()
}
