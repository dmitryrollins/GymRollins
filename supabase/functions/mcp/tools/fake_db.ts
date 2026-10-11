// In-memory Db for unit tests, built from JSON fixtures (testdata/owner.json). Records writes and queries so tests
// can assert on them. Behaves like SupabaseDb for the owner's own data (RLS is out of scope here).
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
} from '../db.ts'

export interface FakeData {
  profile: Profile | null
  library: ExerciseRow[]
  custom?: ExerciseRow[]
  routines: RoutineRow[]
  schedule: ScheduleRow[]
  workouts: WorkoutRow[]
  bodyweight: BodyweightRow[]
  proposals?: ProposalRow[]
  prefs?: ExercisePrefRow[]
  targets?: MuscleTargetRow[]
}

const ownerUrl = new URL('../testdata/owner.json', import.meta.url)

export async function loadOwnerData(): Promise<FakeData> {
  return JSON.parse(await Deno.readTextFile(ownerUrl)) as FakeData
}

const time = (iso: string) => new Date(iso).getTime()

export class FakeDb implements Db {
  readonly insertedProposals: { summary: string; changes: unknown[] }[] = []
  readonly insertedBodyweight: { id: string; measured_at: string; w_kg: number; bf_pct?: number }[] = []
  readonly audits: { tool: string; ok: boolean; argsDigest: string }[] = []
  readonly workoutQueries: WorkoutQuery[] = []
  /** Call slots taken in the current minute (mcp_take_call); tests preset it to simulate earlier calls. */
  calls = 0
  callLimit = 60

  constructor(private readonly data: FakeData) {}

  private get allExercises(): ExerciseRow[] {
    return [...(this.data.custom ?? []).map((e) => ({ ...e, custom: true })), ...this.data.library]
  }

  profile(): Promise<Profile | null> {
    return Promise.resolve(this.data.profile)
  }

  routines(): Promise<RoutineRow[]> {
    return Promise.resolve([...this.data.routines].sort((a, b) => a.position - b.position))
  }

  weekSchedule(): Promise<ScheduleRow[]> {
    return Promise.resolve(this.data.schedule)
  }

  workouts(q: WorkoutQuery): Promise<WorkoutRow[]> {
    this.workoutQueries.push(q)
    const rows = this.data.workouts
      .filter((w) => (q.since ? time(w.started_at) >= time(q.since) : true))
      .filter((w) => (q.until ? time(w.started_at) < time(q.until) : true))
      .sort((a, b) => time(b.started_at) - time(a.started_at))
      .slice(0, q.limit)
    return Promise.resolve(rows)
  }

  workout(id: string): Promise<WorkoutRow | null> {
    return Promise.resolve(this.data.workouts.find((w) => w.id === id) ?? null)
  }

  exerciseSets(exerciseId: string, since?: string): Promise<ExerciseSession[]> {
    const sessions = this.data.workouts
      .filter((w) => (since ? time(w.started_at) >= time(since) : true))
      .filter((w) => w.workout_entries.some((e) => e.exercise_id === exerciseId))
      .sort((a, b) => time(b.started_at) - time(a.started_at))
      .map((w) => ({
        workout_id: w.id,
        started_at: w.started_at,
        sets: w.workout_entries.filter((e) => e.exercise_id === exerciseId).flatMap((e) => e.workout_sets),
      }))
    return Promise.resolve(sessions.slice(0, 60))
  }

  bodyweight(since?: string): Promise<BodyweightRow[]> {
    const rows = this.data.bodyweight
      .filter((b) => (since ? time(b.measured_at) >= time(since) : true))
      .sort((a, b) => time(a.measured_at) - time(b.measured_at))
    return Promise.resolve(rows.slice(0, 1000)) // SupabaseDb: oldest first, at most MAX_ROWS
  }

  latestBodyweight(until: string): Promise<BodyweightRow | null> {
    const rows = this.data.bodyweight.filter((b) => time(b.measured_at) <= time(until))
      .sort((a, b) => time(b.measured_at) - time(a.measured_at))
    return Promise.resolve(rows[0] ?? null)
  }

  /** Like public.mcp_flag: the stored flag, true when no profile was saved. */
  readPermissions(): Promise<{ plan: boolean; workouts: boolean; body: boolean }> {
    const p = this.data.profile
    return Promise.resolve({
      plan: p?.mcp_read_plan ?? true,
      workouts: p?.mcp_read_workouts ?? true,
      body: p?.mcp_read_body ?? true,
    })
  }

  workoutDates(): Promise<string[]> {
    return Promise.resolve(
      this.data.workouts.map((w) => w.started_at).sort((a, b) => time(b) - time(a)).slice(0, 1000),
    )
  }

  muscleTargets(): Promise<MuscleTargetRow[]> {
    return Promise.resolve(this.data.targets ?? [])
  }

  searchExercises(q: ExerciseSearch): Promise<ExerciseRow[]> {
    const words = (q.query ?? '').toLowerCase().split(/\s+/).filter(Boolean)
    const rows = this.allExercises
      .filter((e) => words.every((w) => e.n.toLowerCase().includes(w)))
      .filter((e) => (q.bodyPart ? e.bp === q.bodyPart : true))
      .filter((e) => (q.equipment ? e.eq === q.equipment : true))
    return Promise.resolve(rows.slice(0, q.limit))
  }

  exercises(ids: string[]): Promise<ExerciseRow[]> {
    return Promise.resolve(this.allExercises.filter((e) => ids.includes(e.id)))
  }

  async exerciseExists(ids: string[]): Promise<Set<string>> {
    return new Set((await this.exercises(ids)).map((e) => e.id))
  }

  /** Simulates mcp_read_plan off: RLS hides exercise_prefs rows (never_exercise_ids still answers). */
  prefsHidden = false

  neverExerciseIds(ids: string[]): Promise<Set<string>> {
    const never = (this.data.prefs ?? []).filter((p) => p.pref === 'never').map((p) => p.exercise_id)
    return Promise.resolve(new Set(ids.filter((id) => never.includes(id))))
  }

  /** The `ids` each exercisePreferences call asked for (undefined = all). */
  readonly prefQueries: (string[] | undefined)[] = []

  exercisePreferences(ids?: string[]): Promise<ExercisePrefRow[]> {
    this.prefQueries.push(ids)
    if (this.prefsHidden) return Promise.resolve([])
    return Promise.resolve(
      (this.data.prefs ?? []).filter((p) => p.pref !== 'normal' && (!ids || ids.includes(p.exercise_id))),
    )
  }

  performedExerciseIds(ids: string[]): Promise<Set<string>> {
    const done = new Set(this.data.workouts.flatMap((w) => w.workout_entries.map((e) => e.exercise_id)))
    return Promise.resolve(new Set(ids.filter((id) => done.has(id))))
  }

  insertProposal(p: { summary: string; changes: unknown[] }): Promise<{ id: string; created_at: string }> {
    this.insertedProposals.push(p)
    return Promise.resolve({
      id: `prop-${this.insertedProposals.length}`,
      created_at: '2026-09-26T12:00:00Z',
    })
  }

  proposal(id: string): Promise<ProposalRow | null> {
    return Promise.resolve((this.data.proposals ?? []).find((p) => p.id === id) ?? null)
  }

  insertBodyweight(r: { id: string; measured_at: string; w_kg: number; bf_pct?: number }): Promise<void> {
    this.insertedBodyweight.push(r)
    return Promise.resolve()
  }

  audit(tool: string, ok: boolean, argsDigest: string): Promise<void> {
    this.audits.push({ tool, ok, argsDigest })
    return Promise.resolve()
  }

  takeCall(): Promise<boolean> {
    if (this.calls >= this.callLimit) return Promise.resolve(false)
    this.calls++
    return Promise.resolve(true)
  }
}
