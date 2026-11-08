import { ApiError } from '../http/errors.ts'
import { DomainLimits } from '../shared/domain-limits.ts'
import { WORKOUT_CAPS } from './caps.ts'
import { type Column, RowError, storedRow, wireRow } from './columns.ts'
import { entryListings, workoutGym } from './gym-links.ts'
import { columnNames as names, extracted } from './sql.ts'
import { afterSql, type PullQuery } from './table-sync.ts'
import { laterStamp, NOW_SQL } from './time.ts'

// Workouts sync as a whole: the row, its entries and their sets, as upsert_workout stored them
// (the Postgres migration 20261030000005_workout_gym_links.sql). The fallbacks are its coalesce(…) defaults.

const WORKOUT: readonly Column[] = [
  { name: 'id', kind: 'uuid' },
  { name: 'started_at', kind: 'ts' },
  { name: 'ended_at', kind: 'ts', nullable: true },
  { name: 'paused_sec', kind: 'real', fallback: 0 },
  { name: 'routine_id', kind: 'uuid', nullable: true },
  { name: 'name', kind: 'text' },
  { name: 'source', kind: 'text', fallback: 'app' },
  { name: 'note', kind: 'text', nullable: true },
  { name: 'vol_kg', kind: 'real', fallback: 0 },
  { name: 'records', kind: 'json', fallback: [] },
  { name: 'gym_id', kind: 'uuid', nullable: true },
  { name: 'client_updated_at', kind: 'ts' },
  { name: 'deleted_at', kind: 'ts', nullable: true },
]

const ENTRY: readonly Column[] = [
  { name: 'id', kind: 'uuid' },
  { name: 'exercise_id', kind: 'text' },
  { name: 'position', kind: 'int' },
  { name: 'note', kind: 'text', nullable: true },
  { name: 'superset_group', kind: 'text', nullable: true },
  { name: 'gym_equipment_id', kind: 'uuid', nullable: true },
]

const SET: readonly Column[] = [
  { name: 'id', kind: 'uuid' },
  { name: 'position', kind: 'int' },
  { name: 'w_kg', kind: 'real' },
  { name: 'r', kind: 'int' },
  { name: 'sec', kind: 'int', nullable: true },
  { name: 'min', kind: 'real', nullable: true },
  { name: 'dist_m', kind: 'real', nullable: true },
  { name: 'done', kind: 'bool', fallback: false },
  { name: 'warmup', kind: 'bool', fallback: false },
  { name: 'rir', kind: 'real', nullable: true },
  { name: 'rpe', kind: 'real', nullable: true },
  { name: 'multiplier', kind: 'real', fallback: 1 },
  { name: 'completed_at', kind: 'ts', nullable: true },
]

/** Push only: the server version this edit was made on, and Keep this iPhone's. */
const PUSH_ONLY: readonly Column[] = [
  { name: 'base_updated_at', kind: 'ts', nullable: true },
  { name: 'force', kind: 'bool', fallback: false },
]

/** Entries and sets are written only while the workout row is still this save's: ?1 the workout, ?2 the write id. */
const STILL_THIS_SAVE = 'EXISTS (SELECT 1 FROM workouts WHERE id = ?1 AND write_id = ?2)'

const UPSERT = `INSERT INTO workouts (${names(WORKOUT)}, user_id, write_id, updated_at)
VALUES (${WORKOUT.map((_, i) => `?${i + 1}`).join(', ')}, ?14, ?15, ${NOW_SQL})
ON CONFLICT (id) DO UPDATE SET ${WORKOUT.filter((c) => c.name !== 'id').map((c) => `${c.name} = excluded.${c.name}`).join(', ')},
  write_id = excluded.write_id, updated_at = ${laterStamp('workouts.updated_at', 'excluded.updated_at')}
WHERE workouts.user_id = excluded.user_id AND (?16 = 1 OR (workouts.client_updated_at <= excluded.client_updated_at
  AND (workouts.updated_at IS ?17 OR (?17 IS NULL AND workouts.client_updated_at = excluded.client_updated_at))))`

const DELETE_ENTRIES = `DELETE FROM workout_entries WHERE workout_id = ?1 AND ${STILL_THIS_SAVE}`
const INSERT_ENTRIES = `INSERT INTO workout_entries (workout_id, user_id, ${names(ENTRY)})
SELECT ?1, ?3, ${extracted(ENTRY)} FROM json_each(?4) WHERE ${STILL_THIS_SAVE}`
const INSERT_SETS = `INSERT INTO workout_sets (user_id, entry_id, ${names(SET)})
SELECT ?3, json_extract(value, '$.entry_id'), ${extracted(SET)} FROM json_each(?4) WHERE ${STILL_THIS_SAVE}`

/**
 * Moves the account's count of logged entries or sets (account_rows, migrations/0010_account_caps.sql) by what this
 * save changes: the rows it writes (?4) minus the rows it replaces. Once a save, before the delete, and nothing when
 * the count stays. account_rows_entries_cap and account_rows_sets_cap refuse a move past a cap, and with it the batch.
 * The count is exact while this save is the only writer of entries and sets (plan 31, Task 3, Step 1).
 */
const moveCount = (tbl: 'workout_entries' | 'workout_sets', stored: string) =>
  `INSERT INTO account_rows (user_id, tbl, n)
SELECT ?3, '${tbl}', d FROM (SELECT ?4 - (${stored}) AS d) WHERE d <> 0 AND ${STILL_THIS_SAVE}
ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + excluded.n`
const MOVE_ENTRIES = moveCount('workout_entries', 'SELECT count(*) FROM workout_entries WHERE workout_id = ?1')
const MOVE_SETS = moveCount(
  'workout_sets',
  'SELECT count(*) FROM workout_sets WHERE entry_id IN (SELECT id FROM workout_entries WHERE workout_id = ?1)',
)

export interface WorkoutPushResult {
  readonly status: 'ok' | 'stale'
  readonly updated_at: string
}

interface Parsed {
  readonly workout: Record<string, unknown>
  readonly base: string | null
  readonly force: boolean
  readonly entries: readonly { row: Record<string, unknown>; sets: Record<string, unknown>[] }[]
}

function listOf(raw: unknown, label: string): unknown[] {
  if (raw === undefined || raw === null) return []
  if (!Array.isArray(raw)) throw new RowError(`${label} is not a list`)
  return raw
}

/** A save past one of the per-workout caps: refused whole, before anything is read or written. */
const tooBig = (code: keyof typeof WORKOUT_CAPS) => new ApiError(422, code, WORKOUT_CAPS[code])

/**
 * The save's rows. A save replaces the workout's entries and sets with the ones it carries, so the caps count the
 * body: at most DomainLimits.workoutEntriesMax exercises, each with at most entrySetsMax sets.
 */
function parseWorkout(body: unknown): Parsed {
  const workout = storedRow(WORKOUT, body, 'workout')
  const pushOnly = storedRow(PUSH_ONLY, body, 'workout')
  const rawEntries = listOf((body as Record<string, unknown>).entries, 'workout.entries')
  if (rawEntries.length > DomainLimits.workoutEntriesMax) throw tooBig('too_many_workout_exercises')
  const entries = rawEntries.map((raw, i) => {
    const label = `workout.entries[${i}]`
    const row = storedRow(ENTRY, raw, label)
    const rawSets = listOf((raw as Record<string, unknown>).sets, `${label}.sets`)
    if (rawSets.length > DomainLimits.entrySetsMax) throw tooBig('too_many_exercise_sets')
    return { row, sets: rawSets.map((set, j) => storedRow(SET, set, `${label}.sets[${j}]`)) }
  })
  return { workout, base: pushOnly.base_updated_at as string | null, force: pushOnly.force === 1, entries }
}

/**
 * Saves a workout as upsert_workout did.
 * - `stale`: another device changed it since this edit's version (base_updated_at), unless this is the retry of a save
 *   whose answer was lost; or the server holds a newer edit.
 * - `force` (Keep this iPhone's) overwrites, keeping the later of the two edit times.
 * The row, its entries and its sets change in one batch, and the entries and sets only while the row is still this
 * save's (write_id), so a save that loses a race to another changes nothing and answers `stale`.
 */
export async function pushWorkout(db: D1Database, userId: string, body: unknown): Promise<WorkoutPushResult> {
  const { workout, base, force, entries } = parseWorkout(body)
  const id = workout.id as string
  const incoming = workout.client_updated_at as string
  const existing = await db.prepare('SELECT user_id, client_updated_at, updated_at, gym_id FROM workouts WHERE id = ?1')
    .bind(id).first<{ user_id: string; client_updated_at: string; updated_at: string; gym_id: string | null }>()
  if (existing && existing.user_id !== userId) {
    throw new ApiError(403, 'not_allowed', 'That workout belongs to another account.')
  }
  if (existing && !force) {
    const lostAnswer = base === null && existing.client_updated_at === incoming
    const stale = (existing.updated_at !== base && !lostAnswer) || existing.client_updated_at > incoming
    if (stale) return { status: 'stale', updated_at: existing.updated_at }
  }
  const storedEdit = existing && force && existing.client_updated_at > incoming ? existing.client_updated_at : incoming
  const gymId = await workoutGym(db, userId, existing?.gym_id ?? null, workout.gym_id as string | null)
  const previous = existing ? await previousListings(db, id) : new Map<string, string>()
  const listings = await entryListings(
    db,
    userId,
    entries.map(({ row }) => ({ id: row.id as string, gymEquipmentId: row.gym_equipment_id as string | null })),
    previous,
  )
  const entryRows = entries.map(({ row }) => ({ ...row, gym_equipment_id: listings.get(row.id as string) ?? null }))
  const setRows = entries.flatMap(({ row, sets }) => sets.map((set) => ({ ...set, entry_id: row.id })))
  const writeId = crypto.randomUUID()
  const values = WORKOUT.map((c) => {
    if (c.name === 'client_updated_at') return storedEdit
    if (c.name === 'gym_id') return gymId
    return workout[c.name]
  })
  const results = await db.batch([
    db.prepare(UPSERT).bind(...values, userId, writeId, force ? 1 : 0, base),
    db.prepare(MOVE_ENTRIES).bind(id, writeId, userId, entryRows.length),
    db.prepare(MOVE_SETS).bind(id, writeId, userId, setRows.length),
    db.prepare(DELETE_ENTRIES).bind(id, writeId),
    db.prepare(INSERT_ENTRIES).bind(id, writeId, userId, JSON.stringify(entryRows)),
    db.prepare(INSERT_SETS).bind(id, writeId, userId, JSON.stringify(setRows)),
    db.prepare('SELECT updated_at, write_id FROM workouts WHERE id = ?1').bind(id),
  ])
  const after = results[6].results[0] as { updated_at: string; write_id: string }
  return { status: after.write_id === writeId ? 'ok' : 'stale', updated_at: after.updated_at }
}

async function previousListings(db: D1Database, workoutId: string): Promise<Map<string, string>> {
  const { results } = await db.prepare(
    'SELECT id, gym_equipment_id FROM workout_entries WHERE workout_id = ?1 AND gym_equipment_id IS NOT NULL',
  ).bind(workoutId).all<{ id: string; gym_equipment_id: string }>()
  return new Map(results.map((r) => [r.id, r.gym_equipment_id]))
}

const WORKOUT_SELECT = `${names(WORKOUT)}, updated_at`

/** One page of the caller's workouts, oldest change first, deleted ones included. `limit` counts workouts. */
export async function pullWorkouts(db: D1Database, userId: string, query: PullQuery) {
  const { results } = await db.prepare(
    `SELECT ${WORKOUT_SELECT} FROM workouts WHERE user_id = ?1 AND ${afterSql('id')} ORDER BY updated_at, id LIMIT ?4`,
  ).bind(userId, query.since, query.after, query.limit).all<Record<string, unknown>>()
  return withEntries(db, results)
}

/** One of the caller's workouts, deleted or not; 404 for a workout that is missing or isn't theirs. */
export async function fetchWorkout(db: D1Database, userId: string, rawId: string) {
  const row = await db.prepare(`SELECT ${WORKOUT_SELECT} FROM workouts WHERE id = ?1 AND user_id = ?2`)
    .bind(rawId.toLowerCase(), userId).first<Record<string, unknown>>()
  if (!row) throw new ApiError(404, 'not_found', 'No such workout.')
  const [workout] = await withEntries(db, [row])
  return workout
}

/** Workouts as the app decodes them, entries[] with sets[] in position order: one query for all entries, one for sets. */
async function withEntries(db: D1Database, workouts: Record<string, unknown>[]) {
  if (workouts.length === 0) return []
  const ids = JSON.stringify(workouts.map((w) => w.id))
  const [entries, sets] = await db.batch<Record<string, unknown>>([
    db.prepare(
      `SELECT workout_id, ${names(ENTRY)} FROM workout_entries WHERE workout_id IN (SELECT value FROM json_each(?1)) ` +
        'ORDER BY position, id',
    ).bind(ids),
    db.prepare(
      `SELECT s.entry_id, ${SET.map((c) => `s.${c.name}`).join(', ')} FROM workout_sets s ` +
        'JOIN workout_entries e ON e.id = s.entry_id WHERE e.workout_id IN (SELECT value FROM json_each(?1)) ' +
        'ORDER BY s.position, s.id',
    ).bind(ids),
  ])
  const setsByEntry = new Map<unknown, Record<string, unknown>[]>()
  for (const { entry_id, ...set } of sets.results) {
    setsByEntry.set(entry_id, [...(setsByEntry.get(entry_id) ?? []), wireRow(SET, set)])
  }
  const entriesByWorkout = new Map<unknown, Record<string, unknown>[]>()
  for (const { workout_id, ...entry } of entries.results) {
    const wired = { ...wireRow(ENTRY, entry), sets: setsByEntry.get(entry.id) ?? [] }
    entriesByWorkout.set(workout_id, [...(entriesByWorkout.get(workout_id) ?? []), wired])
  }
  return workouts.map((w) => ({ ...wireRow(WORKOUT, w), entries: entriesByWorkout.get(w.id) ?? [] }))
}
