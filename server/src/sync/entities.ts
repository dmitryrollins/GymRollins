import { ApiError } from '../http/errors.ts'
import { type Column, type Kind, RowError } from './columns.ts'

/** One synced table, which the app's SyncTransport pushes and pulls at /v1/sync/<name> (the names below). */
export interface Entity {
  readonly table: string
  /** The ON CONFLICT target: user_id plus the row's key, or a row id alone (then other accounts' ids are refused). */
  readonly conflict: readonly string[]
  /** The column whose value is the ack id. The app matches acks lowercased. */
  readonly ackKey: string
  /** KeysetPager's tiebreak after updated_at, and how `after` is read. */
  readonly tiebreak: { readonly column: string; readonly kind: 'text' | 'int' }
  /** What the app sends and gets back, besides updated_at (and user_id, on the profile). */
  readonly columns: readonly Column[]
  /** When an update applies, besides the owner check. Default: last write wins by the device's edit time. */
  readonly applies?: string
  /** Update expressions in place of `excluded.<column>`. */
  readonly onUpdate?: Readonly<Record<string, string>>
  /** Pulled rows carry user_id: the profile's tiebreak. */
  readonly pullsUserId?: boolean
  /** Checks that span rows or tables, before anything is written. */
  readonly check?: (db: D1Database, userId: string, rows: readonly Record<string, unknown>[]) => Promise<void>
}

const col = (name: string, kind: Kind): Column => ({ name, kind })
const opt = (name: string, kind: Kind): Column => ({ name, kind, nullable: true })
const edited = col('client_updated_at', 'ts')
const deleted = opt('deleted_at', 'ts')

/** A day's routine must be the caller's (Postgres: the foreign key plus RLS's with check). Tombstones count. */
async function ownRoutines(db: D1Database, userId: string, rows: readonly Record<string, unknown>[]) {
  const ids = [...new Set(rows.flatMap((r) => (typeof r.routine_id === 'string' ? [r.routine_id] : [])))]
  if (ids.length === 0) return
  const { results } = await db.prepare('SELECT id FROM routines WHERE user_id = ?1 AND id IN (SELECT value FROM json_each(?2))')
    .bind(userId, JSON.stringify(ids)).all<{ id: string }>()
  const mine = new Set(results.map((r) => r.id))
  const missing = ids.find((id) => !mine.has(id))
  if (missing !== undefined) throw new RowError(`routine_id ${missing} is not one of your routines`)
}

export const ENTITIES: Readonly<Record<string, Entity>> = {
  profile: {
    table: 'profiles',
    conflict: ['user_id'],
    ackKey: 'user_id',
    tiebreak: { column: 'user_id', kind: 'text' },
    pullsUserId: true,
    columns: [
      col('unit', 'text'), col('rest_sec', 'int'), col('warmup_rest_sec', 'int'), opt('height_cm', 'real'),
      opt('goal_weight_kg', 'real'), opt('goal_date', 'date'), col('training_days', 'int'), col('experience', 'text'),
      col('limits', 'text'), opt('limits_until', 'date'), col('deload_pct', 'real'), col('bar_kg', 'real'),
      col('plates_kg', 'json'), col('dumbbell_step_kg', 'real'), col('mcp_read_workouts', 'bool'),
      col('mcp_read_body', 'bool'), col('mcp_read_plan', 'bool'), col('mcp_read_gyms', 'bool'),
      col('mcp_propose', 'bool'), col('mcp_auto_apply', 'bool'), opt('sex', 'text'), opt('birth_year', 'int'), edited,
    ],
  },
  'custom-exercises': {
    table: 'custom_exercises',
    conflict: ['id'],
    ackKey: 'id',
    tiebreak: { column: 'id', kind: 'text' },
    columns: [
      col('id', 'text'), col('n', 'text'), col('bp', 'text'), col('eq', 'text'), col('tg', 'text'), col('mode', 'text'),
      col('bilateral', 'bool'), edited, deleted,
    ],
  },
  'exercise-prefs': {
    table: 'exercise_prefs',
    conflict: ['user_id', 'exercise_id'],
    ackKey: 'exercise_id',
    tiebreak: { column: 'exercise_id', kind: 'text' },
    columns: [col('exercise_id', 'text'), col('pref', 'text'), edited],
  },
  routines: {
    table: 'routines',
    conflict: ['id'],
    ackKey: 'id',
    tiebreak: { column: 'id', kind: 'text' },
    columns: [
      col('id', 'uuid'), col('name', 'text'), opt('emoji', 'text'), col('policy', 'text'), col('position', 'int'),
      col('paused', 'bool'), col('exercises', 'json'), edited, deleted,
    ],
  },
  weekdays: {
    table: 'week_schedule',
    conflict: ['user_id', 'weekday'],
    ackKey: 'weekday',
    tiebreak: { column: 'weekday', kind: 'int' },
    columns: [col('weekday', 'int'), opt('routine_id', 'uuid'), edited],
    check: ownRoutines,
  },
  'muscle-targets': {
    table: 'muscle_targets',
    conflict: ['user_id', 'muscle'],
    ackKey: 'muscle',
    tiebreak: { column: 'muscle', kind: 'text' },
    columns: [col('muscle', 'text'), col('min_sets', 'int'), col('max_sets', 'int'), edited],
  },
  bodyweight: {
    table: 'bodyweight',
    conflict: ['id'],
    ackKey: 'id',
    tiebreak: { column: 'id', kind: 'text' },
    columns: [
      col('id', 'uuid'), col('measured_at', 'ts'), col('w_kg', 'real'), opt('bf_pct', 'real'), opt('t', 'text'),
      opt('source', 'text'), opt('health_sample_id', 'uuid'), opt('health_fat_sample_id', 'uuid'), edited, deleted,
    ],
  },
}

export function entityNamed(name: string): Entity {
  if (!Object.hasOwn(ENTITIES, name)) throw new ApiError(404, 'not_found', `No synced table ${name}.`)
  return ENTITIES[name]
}
