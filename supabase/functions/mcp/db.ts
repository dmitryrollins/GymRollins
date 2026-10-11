// The data access surface the MCP tools use — and nothing else. `SupabaseDb` (supabase_db.ts) implements it with
// a user-scoped client, so RLS applies to every call; tests use `FakeDb` (tools/fake_db.ts).
// Row shapes mirror the tables in supabase/migrations/*_schema.sql (weights in kg).

export type WeightUnit = 'kg' | 'lb'

export interface Profile {
  unit: WeightUnit
  height_cm: number | null
  goal_weight_kg: number | null
  goal_date: string | null
  training_days: number
  experience: string
  limits: string
  deload_pct: number
  rest_sec: number
  mcp_read_plan: boolean
  mcp_read_workouts: boolean
  mcp_read_body: boolean
  mcp_propose: boolean
  mcp_auto_apply: boolean
  /** Strength levels only; never returned by get_profile. */
  sex?: 'male' | 'female' | null
  birth_year?: number | null
}

/** One element of `routines.exercises` (jsonb). `exercise_id` is the library (or custom) exercise id. */
export interface RoutineExercise {
  id: string
  exercise_id: string
  position: number
  sets: number
  reps: number
  reps_min?: number | null
  sec?: number | null
  weight_kg?: number | null
  mode: string
  prog?: string | null
  inc_kg?: number | null
  sg?: string | null
  weight_set_at?: string | null
}

export interface RoutineRow {
  id: string
  name: string
  emoji?: string | null
  policy: string
  position: number
  paused: boolean
  exercises: RoutineExercise[]
}

export interface ScheduleRow {
  weekday: number
  routine_id: string | null
}

export interface SetRow {
  position: number
  w_kg: number
  r: number
  sec?: number | null
  min?: number | null
  dist_m?: number | null
  done: boolean
  warmup: boolean
  rir?: number | null
  rpe?: number | null
  multiplier: number
}

export interface EntryRow {
  exercise_id: string
  position: number
  note?: string | null
  superset_group?: string | null
  workout_sets: SetRow[]
}

export interface WorkoutRow {
  id: string
  started_at: string
  ended_at: string | null
  paused_sec: number
  routine_id: string | null
  name: string
  note?: string | null
  workout_entries: EntryRow[]
}

/** All sets of one exercise in one workout. */
export interface ExerciseSession {
  workout_id: string
  started_at: string
  sets: SetRow[]
}

export interface BodyweightRow {
  id: string
  measured_at: string
  w_kg: number
  bf_pct: number | null
}

export interface ExerciseRow {
  id: string
  n: string
  bp: string
  eq: string
  tg: string
  /** Secondary muscles (library only). */
  sm?: string[] | null
  /** reps | time | cardio (custom exercises only; the library derives it from bp). */
  mode?: string | null
  custom?: boolean
}

/** `public.exercise_prefs`: how often the owner wants an exercise recommended. */
export type ExercisePreference = 'more' | 'normal' | 'less' | 'never'

export interface ExercisePrefRow {
  exercise_id: string
  pref: ExercisePreference
}

/** `public.muscle_targets`: a weekly hard-set target the owner set for one muscle group. */
export interface MuscleTargetRow {
  muscle: string
  min_sets: number
  max_sets: number
}

export interface ProposalRow {
  id: string
  created_at: string
  status: string
  summary: string
  changes: unknown[]
  applied_change_ids: string[]
  resolved_at: string | null
}

export interface WorkoutQuery {
  /** Inclusive lower bound on started_at (ISO timestamp). */
  since?: string
  /** Exclusive upper bound on started_at (ISO timestamp). */
  until?: string
  limit: number
}

export interface ExerciseSearch {
  query?: string
  bodyPart?: string
  equipment?: string
  limit: number
}

export interface Db {
  profile(): Promise<Profile | null>
  /** Not deleted, ordered by position. */
  routines(): Promise<RoutineRow[]>
  weekSchedule(): Promise<ScheduleRow[]>
  /** Not deleted, with entries and sets, newest first. */
  workouts(q: WorkoutQuery): Promise<WorkoutRow[]>
  workout(id: string): Promise<WorkoutRow | null>
  /** Sessions containing the exercise, newest first (at most 60). */
  exerciseSets(exerciseId: string, since?: string): Promise<ExerciseSession[]>
  /** Not deleted, oldest first. */
  bodyweight(since?: string): Promise<BodyweightRow[]>
  /** The newest non-deleted weigh-in measured at or before `until`, or null. */
  latestBodyweight(until: string): Promise<BodyweightRow | null>
  /** The owner's MCP read flags (public.mcp_flag), readable even while RLS hides the profile. */
  readPermissions(): Promise<{ plan: boolean; workouts: boolean; body: boolean }>
  /** `started_at` of every non-deleted workout, newest first (all of them, paged). */
  workoutDates(): Promise<string[]>
  /** The owner's stored weekly targets (groups without a row use the defaults). */
  muscleTargets(): Promise<MuscleTargetRow[]>
  /** Library + the owner's custom exercises; every word of `query` must appear in the name. */
  searchExercises(q: ExerciseSearch): Promise<ExerciseRow[]>
  /** Library + custom exercises with these ids. */
  exercises(ids: string[]): Promise<ExerciseRow[]>
  exerciseExists(ids: string[]): Promise<Set<string>>
  /**
   * The owner's recommendation preferences other than 'normal' (read-only for Claude): all of them, or only those
   * for `ids`. Never truncated (checking a proposal against a partial list would let a 'never' exercise through).
   */
  exercisePreferences(ids?: string[]): Promise<ExercisePrefRow[]>
  /**
   * Which of `ids` the owner marked 'never' (public.never_exercise_ids, SECURITY DEFINER): answered even when the owner
   * hid the plan from Claude (mcp_read_plan off), so a proposal can never bring such an exercise in.
   */
  neverExerciseIds(ids: string[]): Promise<Set<string>>
  /** The subset of `ids` that appear in the owner's logged workouts. */
  performedExerciseIds(ids: string[]): Promise<Set<string>>
  insertProposal(p: { summary: string; changes: unknown[] }): Promise<{ id: string; created_at: string }>
  proposal(id: string): Promise<ProposalRow | null>
  insertBodyweight(r: { id: string; measured_at: string; w_kg: number; bf_pct?: number }): Promise<void>
  audit(tool: string, ok: boolean, argsDigest: string): Promise<void>
  /**
   * Atomically takes one rate-limit slot for the caller (public.mcp_take_call: 60 per trailing minute). False when
   * the budget is used up; concurrent requests can't overshoot it.
   */
  takeCall(): Promise<boolean>
}
