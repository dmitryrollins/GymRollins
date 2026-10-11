// Db over a user-scoped Supabase client: every query runs as the caller, so RLS (including the MCP-client
// restrictions from the schema migration) decides what is visible and writable. Never construct this with the
// service-role key.
import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2.117.2'
import type {
  BodyweightRow,
  Db,
  ExercisePrefRow,
  ExerciseRow,
  ExerciseSearch,
  ExerciseSession,
  MuscleTargetRow,
  Profile,
  ProposalRow,
  RoutineRow,
  ScheduleRow,
  WorkoutQuery,
  WorkoutRow,
} from './db.ts'
import { ToolError } from './tools/result.ts'

const PROFILE_COLS =
  'unit, height_cm, goal_weight_kg, goal_date, training_days, experience, limits, deload_pct, ' +
  'rest_sec, mcp_read_plan, mcp_read_workouts, mcp_read_body, mcp_propose, mcp_auto_apply, sex, birth_year'
const SET_COLS = 'position, w_kg, r, sec, min, dist_m, done, warmup, rir, rpe, multiplier'
const WORKOUT_COLS = `id, started_at, ended_at, paused_sec, routine_id, name, note, ` +
  `workout_entries(exercise_id, position, note, superset_group, workout_sets(${SET_COLS}))`
const EXERCISE_COLS = 'id, n, bp, eq, tg'
const LIBRARY_COLS = `${EXERCISE_COLS}, sm`
const CUSTOM_COLS = `${EXERCISE_COLS}, mode`
const MAX_SESSIONS = 60
const MAX_ROWS = 1000
const MAX_QUERY_WORDS = 6
const PREF_PAGE = 500
/** Upper bound on workout dates read for streaks (~40 years of daily training). */
const MAX_DATE_ROWS = 15_000

/**
 * Reads `fetch(from, to)` pages (inclusive row ranges) of `pageSize` until a short page or `max` rows. Exported for
 * tests.
 */
export async function collectPages<T>(
  pageSize: number,
  max: number,
  fetch: (from: number, to: number) => Promise<T[]>,
): Promise<T[]> {
  const out: T[] = []
  while (out.length < max) {
    const page = await fetch(out.length, Math.min(out.length + pageSize, max) - 1)
    out.push(...page)
    if (page.length < pageSize) break
  }
  return out
}

interface PgError {
  code?: string
  message: string
}

/** RLS/permission denials become a user-facing ToolError; anything else is an internal error (logged, not shown). */
function dbError(error: PgError): Error {
  if (error.code === '42501') {
    return new ToolError("Not allowed: the owner's Claude permissions in the app don't allow this.")
  }
  return new Error(`db ${error.code ?? '?'}: ${error.message}`)
}

function unwrap<T>(res: { data: T | null; error: PgError | null }): T {
  if (res.error) throw dbError(res.error)
  return res.data as T
}

/** Escapes LIKE wildcards and PostgREST's `*`, so user words match literally. */
function likeWord(word: string): string {
  return `%${word.replace(/[\\%_*]/g, (c) => `\\${c}`)}%`
}

export class SupabaseDb implements Db {
  constructor(private readonly client: SupabaseClient, private readonly clientId: string) {}

  async profile(): Promise<Profile | null> {
    return unwrap(await this.client.from('profiles').select(PROFILE_COLS).maybeSingle()) as Profile | null
  }

  async routines(): Promise<RoutineRow[]> {
    const q = this.client.from('routines').select('id, name, emoji, policy, position, paused, exercises')
      .is('deleted_at', null).order('position')
    return unwrap(await q) as RoutineRow[]
  }

  async weekSchedule(): Promise<ScheduleRow[]> {
    return unwrap(
      await this.client.from('week_schedule').select('weekday, routine_id').order('weekday'),
    ) as ScheduleRow[]
  }

  async workouts(q: WorkoutQuery): Promise<WorkoutRow[]> {
    let query = this.client.from('workouts').select(WORKOUT_COLS).is('deleted_at', null)
    if (q.since) query = query.gte('started_at', q.since)
    if (q.until) query = query.lt('started_at', q.until)
    return unwrap(
      await query.order('started_at', { ascending: false }).limit(q.limit),
    ) as unknown as WorkoutRow[]
  }

  async workout(id: string): Promise<WorkoutRow | null> {
    const q = this.client.from('workouts').select(WORKOUT_COLS).eq('id', id).is('deleted_at', null)
      .maybeSingle()
    return unwrap(await q) as unknown as WorkoutRow | null
  }

  async exerciseSets(exerciseId: string, since?: string): Promise<ExerciseSession[]> {
    let q = this.client.from('workouts')
      .select(`id, started_at, workout_entries!inner(exercise_id, workout_sets(${SET_COLS}))`)
      .eq('workout_entries.exercise_id', exerciseId)
      .is('deleted_at', null)
    if (since) q = q.gte('started_at', since)
    const rows = unwrap(await q.order('started_at', { ascending: false }).limit(MAX_SESSIONS)) as unknown as {
      id: string
      started_at: string
      workout_entries: { workout_sets: ExerciseSession['sets'] }[]
    }[]
    return rows.map((w) => ({
      workout_id: w.id,
      started_at: w.started_at,
      sets: w.workout_entries.flatMap((e) => e.workout_sets),
    }))
  }

  async bodyweight(since?: string): Promise<BodyweightRow[]> {
    let q = this.client.from('bodyweight').select('id, measured_at, w_kg, bf_pct').is('deleted_at', null)
    if (since) q = q.gte('measured_at', since)
    return unwrap(await q.order('measured_at').limit(MAX_ROWS)) as BodyweightRow[]
  }

  async latestBodyweight(until: string): Promise<BodyweightRow | null> {
    const q = this.client.from('bodyweight').select('id, measured_at, w_kg, bf_pct').is('deleted_at', null)
      .lte('measured_at', until).order('measured_at', { ascending: false }).limit(1)
    return (unwrap(await q) as BodyweightRow[])[0] ?? null
  }

  async readPermissions(): Promise<{ plan: boolean; workouts: boolean; body: boolean }> {
    const [plan, workouts, body] = await Promise.all([
      this.client.rpc('mcp_flag', { flag: 'plan' }),
      this.client.rpc('mcp_flag', { flag: 'workouts' }),
      this.client.rpc('mcp_flag', { flag: 'body' }),
    ])
    return { plan: unwrap(plan) === true, workouts: unwrap(workouts) === true, body: unwrap(body) === true }
  }

  async workoutDates(): Promise<string[]> {
    return await collectPages(MAX_ROWS, MAX_DATE_ROWS, async (from, to) => {
      const q = this.client.from('workouts').select('started_at').is('deleted_at', null)
        .order('started_at', { ascending: false }).order('id').range(from, to)
      return (unwrap(await q) as { started_at: string }[]).map((r) => r.started_at)
    })
  }

  async muscleTargets(): Promise<MuscleTargetRow[]> {
    return unwrap(
      await this.client.from('muscle_targets').select('muscle, min_sets, max_sets').order('muscle'),
    ) as MuscleTargetRow[]
  }

  async searchExercises(s: ExerciseSearch): Promise<ExerciseRow[]> {
    const words = (s.query ?? '').toLowerCase().split(/\s+/).filter(Boolean).slice(0, MAX_QUERY_WORDS)
    // deno-lint-ignore no-explicit-any
    const filter = (q: any) => {
      let out = q
      for (const w of words) out = out.ilike('n', likeWord(w))
      if (s.bodyPart) out = out.eq('bp', s.bodyPart)
      if (s.equipment) out = out.eq('eq', s.equipment)
      return out.order('n').limit(s.limit)
    }
    const [custom, library] = await Promise.all([
      filter(this.client.from('custom_exercises').select(EXERCISE_COLS).is('deleted_at', null)),
      filter(this.client.from('exercises').select(EXERCISE_COLS)),
    ])
    const own = (unwrap(custom) as ExerciseRow[]).map((e) => ({ ...e, custom: true }))
    return [...own, ...(unwrap(library) as ExerciseRow[])].slice(0, s.limit)
  }

  async exercises(ids: string[]): Promise<ExerciseRow[]> {
    if (ids.length === 0) return []
    const [custom, library] = await Promise.all([
      this.client.from('custom_exercises').select(CUSTOM_COLS).in('id', ids).is('deleted_at', null),
      this.client.from('exercises').select(LIBRARY_COLS).in('id', ids),
    ])
    const own = (unwrap(custom) as ExerciseRow[]).map((e) => ({ ...e, custom: true }))
    return [...own, ...(unwrap(library) as ExerciseRow[])]
  }

  async exerciseExists(ids: string[]): Promise<Set<string>> {
    return new Set((await this.exercises(ids)).map((e) => e.id))
  }

  async exercisePreferences(ids?: string[]): Promise<ExercisePrefRow[]> {
    if (ids && ids.length === 0) return []
    const rows: ExercisePrefRow[] = []
    // Keyset pages by exercise_id (PostgREST caps a response), until a short page.
    for (let after: string | null = null;;) {
      let q = this.client.from('exercise_prefs').select('exercise_id, pref').neq('pref', 'normal')
      if (ids) q = q.in('exercise_id', ids)
      if (after !== null) q = q.gt('exercise_id', after)
      const page = unwrap(await q.order('exercise_id').limit(PREF_PAGE)) as ExercisePrefRow[]
      rows.push(...page)
      if (page.length < PREF_PAGE) return rows
      after = page[page.length - 1].exercise_id
    }
  }

  async neverExerciseIds(ids: string[]): Promise<Set<string>> {
    if (ids.length === 0) return new Set()
    return new Set((unwrap(await this.client.rpc('never_exercise_ids', { ids })) as string[] | null) ?? [])
  }

  async performedExerciseIds(ids: string[]): Promise<Set<string>> {
    if (ids.length === 0) return new Set()
    const q = this.client.from('workout_entries').select('exercise_id').in('exercise_id', ids).limit(MAX_ROWS)
    return new Set((unwrap(await q) as { exercise_id: string }[]).map((r) => r.exercise_id))
  }

  async insertProposal(
    p: { summary: string; changes: unknown[] },
  ): Promise<{ id: string; created_at: string }> {
    const q = this.client.from('proposals').insert({ summary: p.summary, changes: p.changes }).select(
      'id, created_at',
    )
      .single()
    return unwrap(await q) as { id: string; created_at: string }
  }

  async proposal(id: string): Promise<ProposalRow | null> {
    const q = this.client.from('proposals')
      .select('id, created_at, status, summary, changes, applied_change_ids, resolved_at').eq('id', id)
      .maybeSingle()
    return unwrap(await q) as ProposalRow | null
  }

  async insertBodyweight(
    r: { id: string; measured_at: string; w_kg: number; bf_pct?: number },
  ): Promise<void> {
    const res = await this.client.from('bodyweight').insert(r)
    if (res.error) throw dbError(res.error)
  }

  async audit(tool: string, ok: boolean, argsDigest: string): Promise<void> {
    const res = await this.client.from('mcp_audit').insert({
      tool,
      ok,
      args_digest: argsDigest,
      client_id: this.clientId,
    })
    if (res.error) throw dbError(res.error)
  }

  async takeCall(): Promise<boolean> {
    return unwrap(await this.client.rpc('mcp_take_call')) === true
  }
}
