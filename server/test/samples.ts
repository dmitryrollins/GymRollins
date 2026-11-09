import { env } from 'cloudflare:workers'
import { ENTITIES } from '../src/sync/entities.ts'

// Rows as the app encodes them (SyncJSON): uppercase UUIDs, six-digit UTC times, explicit nulls. Made-up values only.

export type Row = Record<string, unknown>

export const T0 = '2026-11-07T09:00:00.000000Z'
export const T1 = '2026-11-07T10:00:00.000000Z'
export const T2 = '2026-11-07T11:00:00.000000Z'

export const appUUID = () => crypto.randomUUID().toUpperCase()

/** The public gym the gym-listings sample names: any account may list its own equipment at a public gym. */
export const SAMPLE_GYM_ID = '5a3b1e00-0000-4000-8000-000000000001'
/** The dumbbells' generic item, as migrations/0004_seed_equipment.sql seeds it. */
const GENERIC_DUMBBELLS = 'cdd9d434-9eca-5d33-8406-2bdea6b4c561'

export const SAMPLES: Readonly<Record<string, () => Row>> = {
  profile: () => ({
    unit: 'kg', rest_sec: 120, warmup_rest_sec: 60, height_cm: 180, goal_weight_kg: null, goal_date: '2027-06-30',
    training_days: 4, experience: 'intermediate', limits: '', limits_until: null, deload_pct: 0.05, bar_kg: 20,
    plates_kg: [20, 10, 5, 2.5, 1.25], dumbbell_step_kg: 2, mcp_read_workouts: true, mcp_read_body: false,
    mcp_read_plan: true, mcp_read_gyms: true, mcp_propose: true, mcp_auto_apply: false, mcp_log_workouts: true,
    sex: null, birth_year: null, client_updated_at: T1,
  }),
  'custom-exercises': () => ({
    id: `custom-${crypto.randomUUID()}`, n: 'Sled push', bp: 'legs', eq: 'machine', tg: 'quads', mode: 'reps',
    bilateral: true, client_updated_at: T1, deleted_at: null,
  }),
  'exercise-prefs': () => ({ exercise_id: `ex_${crypto.randomUUID().slice(0, 8)}`, pref: 'more', client_updated_at: T1 }),
  routines: () => ({
    id: appUUID(), name: 'Push', emoji: null, policy: 'double', position: 0, paused: false,
    exercises: [{
      id: appUUID(), exercise_id: 'bench_press', position: 0, sets: 3, reps: 8, mode: 'reps', weight_kg: 60,
      weight_set_at: '2026-11-01T09:00:00.000000Z',
    }],
    client_updated_at: T1, deleted_at: null,
  }),
  weekdays: () => ({ weekday: 3, routine_id: null, client_updated_at: T1 }),
  'muscle-targets': () => ({ muscle: 'chest', min_sets: 10, max_sets: 16, client_updated_at: T1 }),
  // a private gym as GymDTO encodes it
  gyms: () => ({
    id: appUUID(), visibility: 'private', name: 'Home gym', address: '1 Main St', latitude: 52.37, longitude: 4.89,
    client_updated_at: T1, deleted_at: null,
  }),
  bodyweight: () => ({
    id: appUUID(), measured_at: '2026-11-07T07:00:00.000000Z', w_kg: 75.5, bf_pct: null, t: '07:00', source: null,
    health_sample_id: null, health_fat_sample_id: null, client_updated_at: T1, deleted_at: null,
  }),
  // a private listing as GymListingDTO encodes it: the kind's generic item, at the public gym sampleNeeds stores
  'gym-listings': () => ({
    id: appUUID(), gym_id: SAMPLE_GYM_ID.toUpperCase(), item_id: GENERIC_DUMBBELLS.toUpperCase(), visibility: 'private',
    photo_path: null, loads: { type: 'fixed', kg: [20, 24] }, quantity: 1, notes: null, private_brand: null,
    private_model: null, client_updated_at: T1, deleted_at: null,
  }),
}

/** What the samples need in D1 before they are pushed: the public gym. Run it in a test file's beforeAll. */
export async function sampleNeeds(): Promise<void> {
  await env.DB.prepare(
    "INSERT OR IGNORE INTO gyms (id, visibility, name, maps_place_id, status, client_updated_at, created_at, updated_at) " +
      "VALUES (?1, 'public', 'Sample gym', ?2, 'active', ?3, ?3, ?3)",
  ).bind(SAMPLE_GYM_ID, `place-${SAMPLE_GYM_ID}`, T0).run()
}

/** A change that breaks one of the table's CHECK constraints. */
export const BAD: Readonly<Record<string, Row>> = {
  profile: { rest_sec: 901 },
  'custom-exercises': { mode: 'swim' },
  'exercise-prefs': { pref: 'maybe' },
  routines: { name: '' },
  weekdays: { weekday: 8 },
  'muscle-targets': { min_sets: 20, max_sets: 10 },
  bodyweight: { w_kg: 500 },
  gyms: { latitude: 91 },
  'gym-listings': { quantity: 51 },
}

/** The ack id the app matches for a row. */
export const KEY: Readonly<Record<string, (row: Row, userId: string) => string>> = {
  profile: (_, userId) => userId,
  'custom-exercises': (row) => String(row.id),
  'exercise-prefs': (row) => String(row.exercise_id),
  routines: (row) => String(row.id).toLowerCase(),
  weekdays: (row) => String(row.weekday),
  'muscle-targets': (row) => String(row.muscle),
  bodyweight: (row) => String(row.id).toLowerCase(),
  gyms: (row) => String(row.id).toLowerCase(),
  'gym-listings': (row) => String(row.id).toLowerCase(),
}

/** What a pull adds to a pushed row beyond its columns: a listing's item kind, embedded as the old REST API did. */
const PULL_ADDS: Readonly<Record<string, Row>> = {
  'gym-listings': { equipment_items: { kind_id: 'dumbbells' } },
}

/** What a pull answers for a pushed row: its UUID columns lowercased, plus updated_at (and user_id on the profile). */
export function pulled(entity: string, row: Row, updatedAt: string, userId: string): Row {
  const out: Row = { ...row, ...PULL_ADDS[entity], updated_at: updatedAt }
  for (const column of ENTITIES[entity].columns) {
    if (column.kind === 'uuid' && typeof out[column.name] === 'string') out[column.name] = String(out[column.name]).toLowerCase()
  }
  if (ENTITIES[entity].pullsUserId) out.user_id = userId
  return out
}

/** A workout as the tests build and read it: loosely typed, like the JSON. */
export type WorkoutJSON = Record<string, any> & { id: string; entries: Array<Record<string, any>> }

/** A workout push as the app encodes it (WorkoutDTO): nested entries and sets, the set's nil optionals left out. */
export function workoutSample(overrides: Record<string, unknown> = {}): WorkoutJSON {
  return {
    id: appUUID(),
    started_at: '2026-11-07T09:00:00.000000Z',
    ended_at: '2026-11-07T10:00:00.000000Z',
    paused_sec: 0,
    routine_id: null,
    name: 'Push',
    source: 'app',
    note: null,
    vol_kg: 960,
    records: [{ exerciseId: 'bench_press', kind: 'e1RM', valueKg: 75 }],
    entries: [{
      id: appUUID(),
      exercise_id: 'bench_press',
      position: 0,
      note: null,
      superset_group: null,
      sets: [
        { id: appUUID(), position: 0, w_kg: 60, r: 8, done: true, warmup: false, multiplier: 1 },
        { id: appUUID(), position: 1, w_kg: 60, r: 8, done: true, warmup: false, multiplier: 1, rir: 2 },
      ],
    }],
    client_updated_at: T1,
    deleted_at: null,
    base_updated_at: null,
    force: false,
    ...overrides,
  }
}
