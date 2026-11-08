// Claude's Db on D1 (spec section 4, "Permissions and Claude"). Postgres's RLS for an OAuth client becomes
// code here: every query filters by the token's user, each read checks its Settings › Claude toggle first (as
// mcp_flag did) and answers as if the rows were hidden, and the only writes are a pending proposal, a body
// weight, the audit row and the rate-limit slot. The old Deno server's data layer and the Postgres
// policies were the reference.
import { claudeReadsPrivateListing, claudeReadsPublicListing } from '../gyms/visibility.ts'
import { inJson } from '../sync/sql.ts'
import { normalizeTimestamp, NOW_SQL } from '../sync/time.ts'
import type {
  BodyweightRow,
  Db,
  EntryRow,
  ExercisePrefRow,
  ExerciseRequirementRow,
  ExerciseRow,
  ExerciseSearch,
  ExerciseSession,
  GymListingRow,
  GymRow,
  MuscleTargetRow,
  Profile,
  ProposalRow,
  RoutineRow,
  ScheduleRow,
  SetRow,
  WorkoutQuery,
  WorkoutRow,
} from './db.ts'
import { ToolError } from './tools/result.ts'

/** Calls per user per rolling minute (spec section 4). */
export const CALLS_PER_MINUTE = 60
const MAX_SESSIONS = 60
const MAX_ROWS = 1000
const MAX_QUERY_WORDS = 6
const MAX_GYM_IDS = 200
const MAX_REQUIREMENT_ROWS = 5000
const MAX_DATE_ROWS = 15_000
const NOT_ALLOWED = "Not allowed: the owner's Claude permissions in the app don't allow this."
/** Audit rows are kept this long; the app's "last use" only reads the newest one. */
const AUDIT_DAYS = 90
const AUDIT_CUTOFF_SQL = `(strftime('%Y-%m-%dT%H:%M:%f', 'now', '-${AUDIT_DAYS} days') || '000Z')`
const MINUTE_AGO_SQL = `(strftime('%Y-%m-%dT%H:%M:%f', 'now', '-60 seconds') || '000Z')`

export interface Permissions {
  plan: boolean
  workouts: boolean
  body: boolean
  gyms: boolean
  propose: boolean
}

type Raw = Record<string, unknown>

const bool = (v: unknown) => v === 1 || v === true
const json = <T>(v: unknown): T => (typeof v === 'string' ? JSON.parse(v) : v) as T
const ids = (list: Iterable<string>) => JSON.stringify([...new Set(list)])

/** An ISO time from a tool in the stored form, so text comparison is time comparison. */
function stamp(iso: string): string {
  const normalized = normalizeTimestamp(iso)
  if (normalized === null) throw new Error(`not a timestamp: ${iso}`)
  return normalized
}

const SET_COLS =
  's.position, s.w_kg, s.r, s.sec, s.min, s.dist_m, s.done, s.warmup, s.rir, s.rpe, s.multiplier'

function setRow(r: Raw): SetRow {
  return {
    position: r.position as number,
    w_kg: r.w_kg as number,
    r: r.r as number,
    sec: r.sec as number | null,
    min: r.min as number | null,
    dist_m: r.dist_m as number | null,
    done: bool(r.done),
    warmup: bool(r.warmup),
    rir: r.rir as number | null,
    rpe: r.rpe as number | null,
    multiplier: r.multiplier as number,
  }
}

export class D1Db implements Db {
  private permissions: Promise<Permissions> | null = null

  constructor(
    private readonly db: D1Database,
    private readonly userId: string,
    private readonly clientId: string,
  ) {}

  private async all<T = Raw>(sql: string, ...binds: unknown[]): Promise<T[]> {
    return (await this.db.prepare(sql).bind(...binds).all<T>()).results
  }

  /** The toggles, read once per request; a missing profile allows everything, as mcp_flag's coalesce did. */
  allowed(): Promise<Permissions> {
    this.permissions ??= this.db.prepare(
      'SELECT mcp_read_plan, mcp_read_workouts, mcp_read_body, mcp_read_gyms, mcp_propose FROM profiles ' +
        'WHERE user_id = ?1',
    ).bind(this.userId).first<Raw>().then((p) => ({
      plan: p ? bool(p.mcp_read_plan) : true,
      workouts: p ? bool(p.mcp_read_workouts) : true,
      body: p ? bool(p.mcp_read_body) : true,
      gyms: p ? bool(p.mcp_read_gyms) : true,
      propose: p ? bool(p.mcp_propose) : true,
    }))
    return this.permissions
  }

  async readPermissions(): Promise<{ plan: boolean; workouts: boolean; body: boolean; gyms: boolean }> {
    const { plan, workouts, body, gyms } = await this.allowed()
    return { plan, workouts, body, gyms }
  }

  async profile(): Promise<Profile | null> {
    if (!(await this.allowed()).plan) return null
    const [p] = await this.all(
      'SELECT unit, height_cm, goal_weight_kg, goal_date, training_days, experience, limits, limits_until, ' +
        'deload_pct, rest_sec, mcp_read_plan, mcp_read_workouts, mcp_read_body, mcp_read_gyms, ' +
        'mcp_propose, ' +
        'mcp_auto_apply, sex, birth_year FROM profiles WHERE user_id = ?1',
      this.userId,
    )
    if (!p) return null
    return {
      ...p,
      mcp_read_plan: bool(p.mcp_read_plan),
      mcp_read_workouts: bool(p.mcp_read_workouts),
      mcp_read_body: bool(p.mcp_read_body),
      mcp_read_gyms: bool(p.mcp_read_gyms),
      mcp_propose: bool(p.mcp_propose),
      mcp_auto_apply: bool(p.mcp_auto_apply),
    } as Profile
  }

  async routines(): Promise<RoutineRow[]> {
    if (!(await this.allowed()).plan) return []
    const rows = await this.all(
      'SELECT id, name, emoji, policy, position, paused, exercises FROM routines ' +
        'WHERE user_id = ?1 AND deleted_at IS NULL ORDER BY position, id',
      this.userId,
    )
    return rows.map((r) => ({ ...r, paused: bool(r.paused), exercises: json(r.exercises) }) as RoutineRow)
  }

  async weekSchedule(): Promise<ScheduleRow[]> {
    if (!(await this.allowed()).plan) return []
    return await this.all<ScheduleRow>(
      'SELECT weekday, routine_id FROM week_schedule WHERE user_id = ?1 ORDER BY weekday',
      this.userId,
    )
  }

  async workouts(q: WorkoutQuery): Promise<WorkoutRow[]> {
    if (!(await this.allowed()).workouts) return []
    const binds: unknown[] = [this.userId, q.limit]
    let where = 'user_id = ?1 AND deleted_at IS NULL'
    if (q.since) where += ` AND started_at >= ?${binds.push(stamp(q.since))}`
    if (q.until) where += ` AND started_at < ?${binds.push(stamp(q.until))}`
    const rows = await this.all(
      `SELECT id, started_at, ended_at, paused_sec, routine_id, name, note FROM workouts WHERE ${where} ` +
        'ORDER BY started_at DESC, id LIMIT ?2',
      ...binds,
    )
    return await this.withEntries(rows)
  }

  async workout(id: string): Promise<WorkoutRow | null> {
    if (!(await this.allowed()).workouts) return null
    const rows = await this.all(
      'SELECT id, started_at, ended_at, paused_sec, routine_id, name, note FROM workouts ' +
        'WHERE user_id = ?1 AND id = ?2 AND deleted_at IS NULL',
      this.userId,
      id.toLowerCase(),
    )
    return (await this.withEntries(rows))[0] ?? null
  }

  /** The workouts' entries and sets, in position order (two reads, whatever the number of workouts). */
  private async withEntries(workouts: Raw[]): Promise<WorkoutRow[]> {
    if (workouts.length === 0) return []
    const workoutIds = ids(workouts.map((w) => w.id as string))
    const [entries, sets] = await Promise.all([
      this.all(
        'SELECT id, workout_id, exercise_id, position, note, superset_group FROM workout_entries ' +
          `WHERE user_id = ?1 AND ${inJson('workout_id', '?2')} ORDER BY position, id`,
        this.userId,
        workoutIds,
      ),
      this.all(
        `SELECT s.entry_id, ${SET_COLS} FROM workout_sets s JOIN workout_entries e ON e.id = s.entry_id ` +
          `WHERE s.user_id = ?1 AND ${inJson('e.workout_id', '?2')} ORDER BY s.position, s.id`,
        this.userId,
        workoutIds,
      ),
    ])
    const setsByEntry = new Map<string, SetRow[]>()
    for (const s of sets) {
      const list = setsByEntry.get(s.entry_id as string) ?? []
      setsByEntry.set(s.entry_id as string, [...list, setRow(s)])
    }
    const entriesByWorkout = new Map<string, EntryRow[]>()
    for (const e of entries) {
      const entry: EntryRow = {
        exercise_id: e.exercise_id as string,
        position: e.position as number,
        note: e.note as string | null,
        superset_group: e.superset_group as string | null,
        workout_sets: setsByEntry.get(e.id as string) ?? [],
      }
      entriesByWorkout.set(e.workout_id as string, [
        ...(entriesByWorkout.get(e.workout_id as string) ?? []),
        entry,
      ])
    }
    return workouts.map((w) =>
      ({ ...w, workout_entries: entriesByWorkout.get(w.id as string) ?? [] }) as WorkoutRow
    )
  }

  async exerciseSets(exerciseId: string, since?: string): Promise<ExerciseSession[]> {
    if (!(await this.allowed()).workouts) return []
    const binds: unknown[] = [this.userId, exerciseId, MAX_SESSIONS]
    const after = since ? ` AND started_at >= ?${binds.push(stamp(since))}` : ''
    const rows = await this.all(
      `SELECT w.id AS workout_id, w.started_at, s.entry_id, ${SET_COLS} FROM (` +
        `SELECT id, started_at FROM workouts WHERE user_id = ?1 AND deleted_at IS NULL${after} AND EXISTS ` +
        '(SELECT 1 FROM workout_entries x WHERE x.workout_id = workouts.id AND x.exercise_id = ?2 AND x.user_id = ?1) ' +
        'ORDER BY started_at DESC, id LIMIT ?3) w ' +
        'JOIN workout_entries e ON e.workout_id = w.id AND e.exercise_id = ?2 AND e.user_id = ?1 ' +
        'LEFT JOIN workout_sets s ON s.entry_id = e.id AND s.user_id = ?1 ' +
        'ORDER BY w.started_at DESC, w.id, e.position, s.position',
      ...binds,
    )
    const sessions: ExerciseSession[] = []
    for (const r of rows) {
      let session = sessions.at(-1)
      if (!session || session.workout_id !== r.workout_id) {
        session = { workout_id: r.workout_id as string, started_at: r.started_at as string, sets: [] }
        sessions.push(session)
      }
      if (r.entry_id !== null) session.sets.push(setRow(r))
    }
    return sessions
  }

  async bodyweight(since?: string): Promise<BodyweightRow[]> {
    if (!(await this.allowed()).body) return []
    const binds: unknown[] = [this.userId, MAX_ROWS]
    const after = since ? ` AND measured_at >= ?${binds.push(stamp(since))}` : ''
    return await this.all<BodyweightRow>(
      `SELECT id, measured_at, w_kg, bf_pct FROM bodyweight WHERE user_id = ?1 AND deleted_at IS ` +
        `NULL${after} ` +
        'ORDER BY measured_at, id LIMIT ?2',
      ...binds,
    )
  }

  async latestBodyweight(until: string): Promise<BodyweightRow | null> {
    if (!(await this.allowed()).body) return null
    const [row] = await this.all<BodyweightRow>(
      'SELECT id, measured_at, w_kg, bf_pct FROM bodyweight WHERE user_id = ?1 AND deleted_at IS NULL ' +
        'AND measured_at <= ?2 ORDER BY measured_at DESC, id LIMIT 1',
      this.userId,
      stamp(until),
    )
    return row ?? null
  }

  async workoutDates(): Promise<string[]> {
    if (!(await this.allowed()).workouts) return []
    const rows = await this.all<{ started_at: string }>(
      'SELECT started_at FROM workouts WHERE user_id = ?1 AND deleted_at IS NULL ORDER BY started_at DESC, ' +
        'id LIMIT ?2',
      this.userId,
      MAX_DATE_ROWS,
    )
    return rows.map((r) => r.started_at)
  }

  async muscleTargets(): Promise<MuscleTargetRow[]> {
    if (!(await this.allowed()).plan) return []
    return await this.all<MuscleTargetRow>(
      'SELECT muscle, min_sets, max_sets FROM muscle_targets WHERE user_id = ?1 ORDER BY muscle',
      this.userId,
    )
  }

  /**
   * Every word must appear in the name. instr() instead of LIKE: no wildcards to escape, and no pattern for
   * D1's 50-byte LIKE limit to trip on. SQLite's lower() folds ASCII only, as the library's names are.
   */
  async searchExercises(s: ExerciseSearch): Promise<ExerciseRow[]> {
    const words = (s.query ?? '').toLowerCase().split(/\s+/).filter(Boolean).slice(0, MAX_QUERY_WORDS)
    const filter = (binds: unknown[]) => {
      let where = ''
      for (const w of words) where += ` AND instr(lower(n), ?${binds.push(w)}) > 0`
      if (s.bodyPart) where += ` AND bp = ?${binds.push(s.bodyPart)}`
      if (s.equipment) where += ` AND eq = ?${binds.push(s.equipment)}`
      return where
    }
    const libraryBinds: unknown[] = [s.limit]
    const library = this.all<ExerciseRow>(
      `SELECT id, n, bp, eq, tg FROM exercises WHERE 1 = 1${filter(libraryBinds)} ORDER BY n, id LIMIT ?1`,
      ...libraryBinds,
    )
    // SQLite's lower() folds ASCII only, so a user's own names (any script) are filtered here; a user has few.
    const custom = (await this.allowed()).plan
      ? (await this.all<ExerciseRow>(
        'SELECT id, n, bp, eq, tg FROM custom_exercises WHERE user_id = ?1 AND deleted_at IS NULL ORDER BY n, id',
        this.userId,
      )).filter((e) =>
        (!s.bodyPart || e.bp === s.bodyPart) && (!s.equipment || e.eq === s.equipment) &&
        words.every((w) => e.n.toLowerCase().includes(w))
      ).slice(0, s.limit)
      : []
    const own = custom.map((e) => ({ ...e, custom: true }))
    return [...own, ...(await library)].slice(0, s.limit)
  }

  async exercises(list: string[]): Promise<ExerciseRow[]> {
    if (list.length === 0) return []
    const library = this.all(
      `SELECT id, n, bp, eq, tg, sm FROM exercises WHERE ${inJson('id', '?1')}`,
      ids(list),
    )
    const custom = (await this.allowed()).plan
      ? this.all<ExerciseRow>(
        'SELECT id, n, bp, eq, tg, mode FROM custom_exercises ' +
          `WHERE user_id = ?1 AND deleted_at IS NULL AND ${inJson('id', '?2')}`,
        this.userId,
        ids(list),
      )
      : Promise.resolve([])
    const own = (await custom).map((e) => ({ ...e, custom: true }))
    return [...own, ...(await library).map((e) => ({ ...e, sm: json<string[]>(e.sm) }) as ExerciseRow)]
  }

  async exerciseExists(list: string[]): Promise<Set<string>> {
    return new Set((await this.exercises(list)).map((e) => e.id))
  }

  async exercisePreferences(list?: string[]): Promise<ExercisePrefRow[]> {
    if (list && list.length === 0) return []
    if (!(await this.allowed()).plan) return []
    const only = list ? ` AND ${inJson('exercise_id', '?2')}` : ''
    return await this.all<ExercisePrefRow>(
      `SELECT exercise_id, pref FROM exercise_prefs WHERE user_id = ?1 AND pref <> 'normal'${only} ORDER ` +
        `BY exercise_id`,
      this.userId,
      ...(list ? [ids(list)] : []),
    )
  }

  /** Answers while Claude may read the plan or propose changes (public.never_exercise_ids). */
  async neverExerciseIds(list: string[]): Promise<Set<string>> {
    if (list.length === 0) return new Set()
    const { plan, propose } = await this.allowed()
    if (!plan && !propose) return new Set()
    const rows = await this.all<{ exercise_id: string }>(
      "SELECT exercise_id FROM exercise_prefs WHERE user_id = ?1 AND pref = 'never' " +
        `AND ${inJson('exercise_id', '?2')}`,
      this.userId,
      ids(list),
    )
    return new Set(rows.map((r) => r.exercise_id))
  }

  async performedExerciseIds(list: string[]): Promise<Set<string>> {
    if (list.length === 0) return new Set()
    if (!(await this.allowed()).workouts) return new Set()
    const rows = await this.all<{ exercise_id: string }>(
      `SELECT DISTINCT exercise_id FROM workout_entries WHERE user_id = ?1 AND ${
        inJson('exercise_id', '?2')
      }`,
      this.userId,
      ids(list),
    )
    return new Set(rows.map((r) => r.exercise_id))
  }

  async privateGyms(limit: number): Promise<GymRow[]> {
    if (!(await this.allowed()).gyms) return []
    const rows = await this.all<Omit<GymRow, 'is_mine'>>(
      "SELECT id, visibility, name, address FROM gyms WHERE visibility = 'private' AND owner_id = ?1 " +
        "AND deleted_at IS NULL AND status = 'active' ORDER BY name, id LIMIT ?2",
      this.userId,
      limit,
    )
    return rows.map((g) => ({ ...g, is_mine: false }))
  }

  async myPublicGyms(limit: number): Promise<GymRow[]> {
    const { gyms, workouts } = await this.allowed()
    const shared = gyms
      ? this.all<{ gym_id: string }>(
        'SELECT DISTINCT e.gym_id FROM gym_equipment e JOIN gyms g ON g.id = e.gym_id ' +
          "WHERE e.added_by = ?1 AND e.visibility = 'public' AND e.status = 'active' " +
          "AND g.visibility = 'public' AND g.status = 'active' LIMIT ?2",
        this.userId,
        MAX_GYM_IDS,
      )
      : Promise.resolve([])
    // Newest first, so the cap keeps the gyms trained at lately. Only the gym id leaves the workouts table.
    const trained = workouts
      ? this.all<{ gym_id: string }>(
        'SELECT gym_id FROM workouts WHERE user_id = ?1 AND gym_id IS NOT NULL AND deleted_at IS NULL ' +
          'GROUP BY gym_id ORDER BY max(started_at) DESC LIMIT ?2',
        this.userId,
        MAX_GYM_IDS,
      )
      : Promise.resolve([])
    const gymIds = [...new Set([...(await shared), ...(await trained)].map((r) => r.gym_id))].slice(
      0,
      MAX_GYM_IDS,
    )
    if (gymIds.length === 0) return []
    const rows = await this.all(
      'SELECT id, name, address, created_by FROM gyms ' +
        `WHERE ${
          inJson('id', '?1')
        } AND visibility = 'public' AND status = 'active' ORDER BY name, id LIMIT ?2`,
      JSON.stringify(gymIds),
      limit,
    )
    return rows.map((g) => ({
      id: g.id as string,
      visibility: 'public' as const,
      name: g.name as string,
      address: g.address as string | null,
      is_mine: gyms && g.created_by === this.userId,
    }))
  }

  /**
   * Active listings at one gym: the public ones Claude may see (src/gyms/visibility.ts), then the owner's
   * private ones while gyms is on.
   */
  async gymListings(gymId: string, limit: number): Promise<GymListingRow[]> {
    const { gyms } = await this.allowed()
    const publicRows = await this.all(
      'SELECT i.kind_id, i.brand, i.model, e.loads, e.quantity, e.confirm_count, e.added_by, i.created_by ' +
        'FROM gym_equipment e JOIN equipment_items i ON i.id = e.item_id ' +
        `WHERE e.gym_id = ?2 AND ${claudeReadsPublicListing('e', 'i', '?1')} ` +
        'ORDER BY e.confirm_count DESC, e.id LIMIT ?3',
      this.userId,
      gymId.toLowerCase(),
      limit,
    )
    const privateRows = gyms
      ? await this.all(
        'SELECT i.kind_id, e.private_brand, e.private_model, e.loads, e.quantity, e.confirm_count ' +
          'FROM gym_equipment e JOIN equipment_items i ON i.id = e.item_id ' +
          `WHERE e.gym_id = ?2 AND ${claudeReadsPrivateListing('e', 'i', '?1')} ORDER BY e.id LIMIT ?3`,
        this.userId,
        gymId.toLowerCase(),
        limit,
      )
      : []
    const mine = privateRows.map((r): GymListingRow => ({
      visibility: 'private',
      kind_id: r.kind_id as string,
      loads: json(r.loads),
      quantity: r.quantity as number,
      confirm_count: r.confirm_count as number,
      is_mine: true,
      item_is_mine: true,
      brand: r.private_brand as string | null,
      model: r.private_model as string | null,
    }))
    const shared = publicRows.map((r): GymListingRow => ({
      visibility: 'public',
      kind_id: r.kind_id as string,
      loads: json(r.loads),
      quantity: r.quantity as number,
      confirm_count: r.confirm_count as number,
      is_mine: gyms && r.added_by === this.userId,
      item_is_mine: gyms && r.created_by === this.userId,
      brand: r.brand as string | null,
      model: r.model as string | null,
    }))
    return [...mine, ...shared].slice(0, limit)
  }

  async exerciseRequirements(): Promise<ExerciseRequirementRow[]> {
    const rows = await this.all(
      'SELECT exercise_id, groups FROM exercise_requirements ORDER BY exercise_id LIMIT ?1',
      MAX_REQUIREMENT_ROWS,
    )
    return rows.map((r) => ({ exercise_id: r.exercise_id as string, groups: json(r.groups) }))
  }

  /** A pending proposal, while Claude may propose (proposals_insert). */
  async insertProposal(
    p: { summary: string; changes: unknown[] },
  ): Promise<{ id: string; created_at: string }> {
    if (!(await this.allowed()).propose) throw new ToolError(NOT_ALLOWED)
    const row = await this.db.prepare(
      'INSERT INTO proposals (id, user_id, created_at, summary, changes, status, applied_change_ids, ' +
        `client_updated_at, updated_at) VALUES (?1, ?2, ${NOW_SQL}, ?3, ?4, 'pending', '[]', ${NOW_SQL}, ` +
        `${NOW_SQL}) ` +
        'RETURNING id, created_at',
    ).bind(crypto.randomUUID(), this.userId, p.summary, JSON.stringify(p.changes)).first<
      { id: string; created_at: string }
    >()
    return row!
  }

  async proposal(id: string): Promise<ProposalRow | null> {
    const [row] = await this.all(
      'SELECT id, created_at, status, summary, changes, applied_change_ids, resolved_at FROM proposals ' +
        'WHERE user_id = ?1 AND id = ?2',
      this.userId,
      id.toLowerCase(),
    )
    if (!row) return null
    return {
      ...row,
      changes: json(row.changes),
      applied_change_ids: json(row.applied_change_ids),
    } as ProposalRow
  }

  /** A new weigh-in, while Claude may read body weight (bodyweight_insert). Never an update. */
  async insertBodyweight(
    r: { id: string; measured_at: string; w_kg: number; bf_pct?: number },
  ): Promise<void> {
    if (!(await this.allowed()).body) throw new ToolError(NOT_ALLOWED)
    await this.db.prepare(
      'INSERT INTO bodyweight (id, user_id, measured_at, w_kg, bf_pct, client_updated_at, updated_at) ' +
        `VALUES (?1, ?2, ?3, ?4, ?5, ${NOW_SQL}, ${NOW_SQL})`,
    ).bind(r.id.toLowerCase(), this.userId, stamp(r.measured_at), r.w_kg, r.bf_pct ?? null).run()
  }

  async audit(tool: string, ok: boolean, argsDigest: string): Promise<void> {
    await this.db.prepare(
      `INSERT INTO mcp_audit (user_id, client_id, tool, ok, args_digest, at) VALUES (?1, ?2, ?3, ?4, ?5, ` +
        `${NOW_SQL})`,
    ).bind(this.userId, this.clientId, tool, ok ? 1 : 0, argsDigest).run()
  }

  /**
   * One rate-limit slot: a single statement inserts the call only while the last minute holds fewer than 60,
   * and D1 runs statements one at a time, so concurrent calls can't overshoot (public.mcp_take_call took a
   * lock instead).
   */
  async takeCall(): Promise<boolean> {
    const [, , taken] = await this.db.batch([
      // The audit is written once per call and read only for its newest row: keep 90 days of it, per user.
      this.db.prepare(`DELETE FROM mcp_audit WHERE user_id = ?1 AND at < ${AUDIT_CUTOFF_SQL}`).bind(this.userId),
      this.db.prepare(`DELETE FROM mcp_calls WHERE user_id = ?1 AND at <= ${MINUTE_AGO_SQL}`).bind(
        this.userId,
      ),
      this.db.prepare(
        `INSERT INTO mcp_calls (user_id, at) SELECT ?1, ${NOW_SQL} WHERE (SELECT count(*) FROM mcp_calls ` +
          `WHERE user_id = ?1 AND at > ${MINUTE_AGO_SQL}) < ?2 RETURNING id`,
      ).bind(this.userId, CALLS_PER_MINUTE),
    ])
    return taken!.results.length === 1
  }
}
