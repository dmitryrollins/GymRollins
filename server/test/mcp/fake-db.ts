// In-memory Db for unit tests, built from JSON fixtures (testdata/owner.json). Records writes and queries so tests
// can assert on them. Behaves like D1Db for the owner's own data (RLS is out of scope here).
import ownerText from './testdata/owner.json?raw'
import { normalizeTimestamp } from '../../src/sync/time.ts'
import type {
  BodyweightRow,
  Db,
  ExercisePrefRow,
  ExerciseRequirementRow,
  ExerciseRow,
  ExerciseSearch,
  ExerciseSession,
  GymListingRow,
  GymRow,
  LoggedWorkout,
  MuscleTargetRow,
  Profile,
  ProposalRow,
  RoutineRow,
  ScheduleRow,
  WorkoutAdded,
  WorkoutQuery,
  WorkoutRow,
} from '../../src/mcp/db.ts'

/**
 * Rows as the tables hold them: author columns and notes included, so a tool that spread a row instead of picking
 * keys would leak them in the tests.
 */
export type FakeGym = GymRow & {
  status?: string
  owner_id?: string | null
  created_by?: string | null
  /** Public gyms: the owner has a workout there (readable only while mcp_read_workouts is on). */
  trained?: boolean
  /** Public gyms: the owner shared a listing there. */
  shared?: boolean
}
export type FakeListing = GymListingRow & {
  gym_id: string
  status?: string
  notes?: string | null
  added_by?: string | null
  owner_id?: string | null
  /** The author is blocked by the owner: RLS hides the row. */
  blocked?: boolean
}

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
  gyms?: FakeGym[]
  listings?: FakeListing[]
  requirements?: ExerciseRequirementRow[]
}


export async function loadOwnerData(): Promise<FakeData> {
  return JSON.parse(ownerText) as FakeData
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
    return Promise.resolve(rows.slice(0, 1000)) // D1Db: oldest first, at most MAX_ROWS
  }

  latestBodyweight(until: string): Promise<BodyweightRow | null> {
    const rows = this.data.bodyweight.filter((b) => time(b.measured_at) <= time(until))
      .sort((a, b) => time(b.measured_at) - time(a.measured_at))
    return Promise.resolve(rows[0] ?? null)
  }

  /** Like D1Db: the stored flag, off when no profile was saved. */
  autoApply(): Promise<boolean> {
    return Promise.resolve(this.data.profile?.mcp_auto_apply ?? false)
  }

  /** Like public.mcp_flag: the stored flag, true when no profile was saved. */
  readPermissions(): Promise<{ plan: boolean; workouts: boolean; body: boolean; gyms: boolean }> {
    const p = this.data.profile
    return Promise.resolve({
      plan: p?.mcp_read_plan ?? true,
      workouts: p?.mcp_read_workouts ?? true,
      body: p?.mcp_read_body ?? true,
      gyms: p?.mcp_read_gyms ?? true,
    })
  }

  privateGyms(limit: number): Promise<GymRow[]> {
    if (this.data.profile?.mcp_read_gyms === false) return Promise.resolve([])
    const rows = (this.data.gyms ?? []).filter((g) => g.visibility === 'private' && g.status !== 'removed')
    return Promise.resolve(rows.sort((a, b) => a.name.localeCompare(b.name)).slice(0, limit))
  }

  myPublicGyms(limit: number): Promise<GymRow[]> {
    const p = this.data.profile
    const workoutsOn = p?.mcp_read_workouts ?? true
    const gymsOn = p?.mcp_read_gyms ?? true
    const rows = (this.data.gyms ?? []).filter((g) =>
      g.visibility === 'public' && (g.status ?? 'active') === 'active' &&
      ((g.trained && workoutsOn) || (g.shared && gymsOn))
    )
    return Promise.resolve(rows.sort((a, b) => a.name.localeCompare(b.name)).slice(0, limit))
  }

  readonly listingQueries: string[] = []

  gymListings(gymId: string, limit: number): Promise<GymListingRow[]> {
    this.listingQueries.push(gymId)
    const gymsOn = this.data.profile?.mcp_read_gyms ?? true
    const rows = (this.data.listings ?? []).filter((l) =>
      l.gym_id === gymId && (l.status ?? 'active') === 'active' && !l.blocked &&
      (gymsOn || l.visibility === 'public')
    )
    return Promise.resolve(rows.slice(0, limit))
  }

  exerciseRequirements(): Promise<ExerciseRequirementRow[]> {
    return Promise.resolve(this.data.requirements ?? [])
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

  /** The Add workouts switch; off unless a test turns it on. */
  logWorkouts = false
  readonly insertedWorkouts: { workout: LoggedWorkout; addedBy: string }[] = []
  /** The calling client's name (D1Db reads oauthClient). */
  agent: string | null = 'Claude'

  mayLogWorkouts(): Promise<boolean> {
    return Promise.resolve(this.logWorkouts)
  }

  loggableExerciseIds(ids: string[]): Promise<Set<string>> {
    const known = new Set(this.allExercises.map((e) => e.id))
    return Promise.resolve(new Set(ids.filter((id) => known.has(id))))
  }

  agentName(): Promise<string | null> {
    return Promise.resolve(this.agent)
  }

  workoutTimes(since: string, until: string): Promise<{ started_at: string; ended_at: string | null }[]> {
    const rows = this.data.workouts.filter((w) => time(w.started_at) >= time(since) && time(w.started_at) < time(until))
    return Promise.resolve(rows.map((w) => ({
      started_at: normalizeTimestamp(w.started_at)!,
      ended_at: w.ended_at === null ? null : normalizeTimestamp(w.ended_at),
    })))
  }

  insertWorkout(workout: LoggedWorkout, addedBy: string): Promise<WorkoutAdded> {
    this.insertedWorkouts.push({ workout, addedBy })
    return Promise.resolve({ added: true, id: `workout-${this.insertedWorkouts.length}` })
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
