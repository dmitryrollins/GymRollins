import { env } from 'cloudflare:workers'
import { beforeAll, describe, expect, it } from 'vitest'
import { DomainLimits } from '../src/shared/domain-limits.ts'
import { ACCOUNT_CAPS } from '../src/sync/caps.ts'
import { type CappedTable, countOf, kept, type LoggedTable, seedCount, seedRows } from './cap-fixtures.ts'
import { insertUser } from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'
import { appUUID, KEY, type Row, SAMPLES, sampleNeeds, T1, T2, type WorkoutJSON, workoutSample } from './samples.ts'

// Each account cap at its exact number (plan 31): N-1 and N are stored, N+1 is refused with its code and the app's
// words, and nothing of the refused push is stored. A stored row can still be edited, deleted and brought back at the
// cap. A deletion frees nothing, because its tombstone counts. Another account's rows don't count.

beforeAll(sampleNeeds)

const T3 = '2026-11-07T12:00:00.000000Z'
const T4 = '2026-11-07T13:00:00.000000Z'

interface Saved {
  status: 'ok' | 'stale'
  updated_at: string
}

const push = (token: string, entity: string, rows: Row[]) =>
  request('POST', `/v1/sync/${entity}`, { token, body: { rows } })
const save = (token: string, workout: Row) => request('POST', '/v1/sync/workouts', { token, body: workout })

async function refusedWith(res: Response, code: string): Promise<void> {
  expect(res.status).toBe(422)
  expect(await res.json()).toEqual({ error: { code, message: ACCOUNT_CAPS[code] } })
}

describe('the words', () => {
  it('say what the cap is, that deleted rows count, and that the row stays on the phone', () => {
    expect(ACCOUNT_CAPS.too_many_body_weights).toBe(
      "You've reached the limit of 20,000 weigh-ins on one account, deleted ones included. " +
        'This one stays on this iPhone.',
    )
    expect(ACCOUNT_CAPS.too_many_logged_sets).toBe(
      "You've reached the limit of 250,000 sets logged on one account, deleted workouts included. " +
        'This workout stays on this iPhone.',
    )
    expect(Object.keys(ACCOUNT_CAPS).sort()).toEqual([
      'too_many_body_weights', 'too_many_custom_exercises', 'too_many_exercise_prefs', 'too_many_gyms_total',
      'too_many_listings_total', 'too_many_logged_exercises', 'too_many_logged_sets', 'too_many_pending_proposals',
      'too_many_proposals', 'too_many_routines', 'too_many_workouts',
    ])
  })
})

interface Synced {
  readonly entity: string
  readonly table: CappedTable
  readonly max: number
  readonly code: string
}

const SYNCED: Synced[] = [
  { entity: 'bodyweight', table: 'bodyweight', max: DomainLimits.bodyweightsMax, code: 'too_many_body_weights' },
  { entity: 'routines', table: 'routines', max: DomainLimits.routinesMax, code: 'too_many_routines' },
  {
    entity: 'custom-exercises', table: 'custom_exercises', max: DomainLimits.customExercisesMax,
    code: 'too_many_custom_exercises',
  },
]

describe.each(SYNCED)('$entity', ({ entity, table, max, code }) => {
  const fresh = () => SAMPLES[entity]()

  /** The stored row's edit time, or undefined when the row isn't stored. */
  async function storedEdit(row: Row, userId: string): Promise<string | undefined> {
    const stored = await env.DB.prepare(`SELECT client_updated_at FROM ${table} WHERE id = ?1`)
      .bind(KEY[entity](row, userId)).first<{ client_updated_at: string }>()
    return stored?.client_updated_at
  }

  it('holds the cap, deleted rows included: N-1 and N are stored, N+1 is refused', async () => {
    const { token, userId } = await signUp()
    await seedRows(table, userId, max - 2)
    expect((await push(token, entity, [fresh()])).status).toBe(200)
    expect(await countOf(table, userId)).toBe(max - 1)
    expect((await push(token, entity, [fresh()])).status).toBe(200)
    expect(await countOf(table, userId)).toBe(max)
    const last = fresh()
    await refusedWith(await push(token, entity, [last]), code)
    expect(await countOf(table, userId)).toBe(max)
    expect(await storedEdit(last, userId)).toBeUndefined()
  })

  it('refuses a push holding a new row past the cap whole, and takes an edit, a deletion and a revival at the cap',
    async () => {
      const { token, userId } = await signUp()
      await seedRows(table, userId, max - 1)
      const row = fresh()
      expect((await push(token, entity, [row])).status).toBe(200)
      const edit = { ...row, client_updated_at: T2 }
      await refusedWith(await push(token, entity, [edit, fresh()]), code)
      expect(await storedEdit(row, userId)).toBe(T1)
      expect((await push(token, entity, [edit])).status).toBe(200)
      expect((await push(token, entity, [{ ...edit, deleted_at: T2 }])).status).toBe(200)
      expect((await push(token, entity, [{ ...edit, client_updated_at: T3, deleted_at: null }])).status).toBe(200)
      expect(await storedEdit(row, userId)).toBe(T3)
      await refusedWith(await push(token, entity, [fresh()]), code)
      expect(await countOf(table, userId)).toBe(max)
    })

  it('counts a deletion the server never had as a new row', async () => {
    const { token, userId } = await signUp()
    await seedRows(table, userId, max)
    await refusedWith(await push(token, entity, [{ ...fresh(), deleted_at: T1 }]), code)
  })

  it("doesn't count another account's rows", async () => {
    await seedRows(table, await insertUser(), max)
    const { token, userId } = await signUp()
    expect((await push(token, entity, [fresh()])).status).toBe(200)
    expect(await countOf(table, userId)).toBe(1)
  })
})

describe('exercise preferences', () => {
  const max = DomainLimits.exercisePrefsMax

  it('hold 2,000 per account: N-1 and N are stored, N+1 is refused, and an edit at the cap goes through', async () => {
    const { token, userId } = await signUp()
    await seedRows('exercise_prefs', userId, max - 2)
    const pref = SAMPLES['exercise-prefs']()
    expect((await push(token, 'exercise-prefs', [pref])).status).toBe(200)
    expect(await countOf('exercise_prefs', userId)).toBe(max - 1)
    expect((await push(token, 'exercise-prefs', [SAMPLES['exercise-prefs']()])).status).toBe(200)
    await refusedWith(await push(token, 'exercise-prefs', [SAMPLES['exercise-prefs']()]), 'too_many_exercise_prefs')
    const edit = { ...pref, pref: 'never', client_updated_at: T2 }
    expect((await push(token, 'exercise-prefs', [edit])).status).toBe(200)
    expect(await countOf('exercise_prefs', userId)).toBe(max)
  })

  it("don't count another account's", async () => {
    await seedRows('exercise_prefs', await insertUser(), max)
    const { token } = await signUp()
    expect((await push(token, 'exercise-prefs', [SAMPLES['exercise-prefs']()])).status).toBe(200)
  })
})

const PRIVATE: Synced[] = [
  { entity: 'gyms', table: 'gyms', max: DomainLimits.privateGymsTotalMax, code: 'too_many_gyms_total' },
  {
    entity: 'gym-listings', table: 'gym_equipment', max: DomainLimits.privateListingsTotalMax,
    code: 'too_many_listings_total',
  },
]

describe('private gyms and listings, deleted ones included', () => {
  it.each(PRIVATE)('$entity: N-1 and N are stored, N+1 is refused under the live cap, and an edit goes through',
    async ({ entity, table, max, code }) => {
      const { token, userId } = await signUp()
      await seedRows(table, userId, max - 2)
      const first = SAMPLES[entity]()
      expect((await push(token, entity, [first])).status).toBe(200)
      expect(await countOf(table, userId)).toBe(max - 1)
      expect((await push(token, entity, [SAMPLES[entity]()])).status).toBe(200)
      await refusedWith(await push(token, entity, [SAMPLES[entity]()]), code)
      expect((await push(token, entity, [{ ...first, client_updated_at: T2 }])).status).toBe(200)
      expect(await countOf(table, userId)).toBe(max)
    })

  it.each(PRIVATE)("$entity: another account's don't count", async ({ entity, table, max }) => {
    await seedRows(table, await insertUser(), max)
    const { token } = await signUp()
    expect((await push(token, entity, [SAMPLES[entity]()])).status).toBe(200)
  })
})

describe('workouts', () => {
  const max = DomainLimits.workoutsMax
  const entriesOf = async (userId: string) => (await env.DB.prepare(
    'SELECT count(*) AS n FROM workout_entries WHERE user_id = ?1',
  ).bind(userId).first<{ n: number }>())!.n

  it('holds 10,000, deleted ones included: N-1 and N are saved, N+1 is refused and none of its entries stored',
    async () => {
      const { token, userId } = await signUp()
      await seedRows('workouts', userId, max - 2)
      expect((await save(token, workoutSample())).status).toBe(200)
      expect(await countOf('workouts', userId)).toBe(max - 1)
      expect((await save(token, workoutSample())).status).toBe(200)
      expect(await countOf('workouts', userId)).toBe(max)
      await refusedWith(await save(token, workoutSample()), 'too_many_workouts')
      expect(await countOf('workouts', userId)).toBe(max)
      expect(await entriesOf(userId)).toBe(2)
    })

  it('saves an edit and a deletion of a stored workout at the cap, and the deletion frees nothing', async () => {
    const { token, userId } = await signUp()
    await seedRows('workouts', userId, max - 1)
    const w = workoutSample()
    const first = await (await save(token, w)).json<Saved>()
    const second = await (await save(token, {
      ...w, name: 'Pull', client_updated_at: T2, base_updated_at: first.updated_at,
    })).json<Saved>()
    expect(second.status).toBe('ok')
    const deleted = await save(token, {
      ...w, deleted_at: T3, client_updated_at: T3, base_updated_at: second.updated_at,
    })
    expect(await deleted.json()).toMatchObject({ status: 'ok' })
    await refusedWith(await save(token, workoutSample()), 'too_many_workouts')
    expect(await countOf('workouts', userId)).toBe(max)
  })

  it("doesn't count another account's workouts", async () => {
    await seedRows('workouts', await insertUser(), max)
    const { token, userId } = await signUp()
    expect((await save(token, workoutSample())).status).toBe(200)
    expect(await countOf('workouts', userId)).toBe(1)
  })
})

describe('exercises and sets logged, deleted workouts included', () => {
  /** A workout of `entries` exercises with `sets` sets each. */
  const sized = (entries: number, sets: number): WorkoutJSON => workoutSample({
    entries: Array.from({ length: entries }, (_, i) => ({
      id: appUUID(), exercise_id: `ex_${i}`, position: i, note: null, superset_group: null,
      sets: Array.from({ length: sets }, (_, j) => ({ id: appUUID(), position: j, w_kg: 60, r: 8 })),
    })),
  })
  const counts = async (userId: string) =>
    [await countOf('workout_entries', userId), await countOf('workout_sets', userId)]

  it('stay exact: a re-save moves nothing, a smaller one lowers them, a stale one and a deletion keep them',
    async () => {
      const { token, userId } = await signUp()
      const w = sized(3, 4)
      const first = await (await save(token, w)).json<Saved>()
      expect(await counts(userId)).toEqual([3, 12])
      const again = await (await save(token, {
        ...w, client_updated_at: T2, base_updated_at: first.updated_at,
      })).json<Saved>()
      expect(again.status).toBe('ok')
      expect(await counts(userId)).toEqual([3, 12])
      const stale = await (await save(token, {
        ...sized(5, 5), id: w.id, client_updated_at: T3, base_updated_at: first.updated_at,
      })).json<Saved>()
      expect(stale.status).toBe('stale')
      expect(await counts(userId)).toEqual([3, 12])
      const smaller = { ...w, entries: w.entries.slice(0, 2), client_updated_at: T3, base_updated_at: again.updated_at }
      const third = await (await save(token, smaller)).json<Saved>()
      expect(await counts(userId)).toEqual([2, 8])
      await save(token, { ...smaller, deleted_at: T4, client_updated_at: T4, base_updated_at: third.updated_at })
      expect(await counts(userId)).toEqual([2, 8])
    })

  interface Logged {
    readonly table: LoggedTable
    readonly max: number
    readonly code: string
    /** A new workout that adds exactly 1 to the count. */
    readonly one: () => WorkoutJSON
  }
  const LOGGED: Logged[] = [
    {
      table: 'workout_entries', max: DomainLimits.accountEntriesMax, code: 'too_many_logged_exercises',
      one: () => sized(1, 0),
    },
    { table: 'workout_sets', max: DomainLimits.accountSetsMax, code: 'too_many_logged_sets', one: () => sized(1, 1) },
  ]

  it.each(LOGGED)('$table: N-1 and N are saved, N+1 is refused whole and writes nothing', async (c) => {
    const { token, userId } = await signUp()
    await seedCount(c.table, userId, c.max - 2)
    expect((await save(token, c.one())).status).toBe(200)
    expect(await kept(c.table, userId)).toBe(c.max - 1)
    expect((await save(token, c.one())).status).toBe(200)
    expect(await kept(c.table, userId)).toBe(c.max)
    const refused = c.one()
    await refusedWith(await save(token, refused), c.code)
    expect(await kept(c.table, userId)).toBe(c.max)
    expect((await request('GET', `/v1/sync/workouts/${refused.id}`, { token })).status).toBe(404)
  })

  it('at the cap: a re-save passes, a bigger one is refused and changes nothing, a smaller one makes room',
    async () => {
      const { token, userId } = await signUp()
      await seedCount('workout_sets', userId, DomainLimits.accountSetsMax - 2)
      const w = sized(1, 2)
      const first = await (await save(token, w)).json<Saved>()
      expect(await kept('workout_sets', userId)).toBe(DomainLimits.accountSetsMax)
      const same = await (await save(token, {
        ...w, name: 'Pull', client_updated_at: T2, base_updated_at: first.updated_at,
      })).json<Saved>()
      expect(same.status).toBe('ok')
      const [entry] = w.entries
      const extra = { id: appUUID(), position: 2, w_kg: 60, r: 8 }
      const bigger = {
        ...w, entries: [{ ...entry, sets: [...entry.sets, extra] }], client_updated_at: T3,
        base_updated_at: same.updated_at,
      }
      await refusedWith(await save(token, bigger), 'too_many_logged_sets')
      const stored = await (await request('GET', `/v1/sync/workouts/${w.id}`, { token })).json<WorkoutJSON>()
      expect(stored.name).toBe('Pull')
      expect(stored.entries[0].sets).toHaveLength(2)
      const smaller = {
        ...w, entries: [{ ...entry, sets: entry.sets.slice(0, 1) }], client_updated_at: T3,
        base_updated_at: same.updated_at,
      }
      expect((await (await save(token, smaller)).json<Saved>()).status).toBe('ok')
      expect(await kept('workout_sets', userId)).toBe(DomainLimits.accountSetsMax - 1)
    })

  it("don't count another account's", async () => {
    const other = await insertUser()
    await seedCount('workout_entries', other, DomainLimits.accountEntriesMax)
    await seedCount('workout_sets', other, DomainLimits.accountSetsMax)
    const { token, userId } = await signUp()
    expect((await save(token, sized(1, 1))).status).toBe(200)
    expect(await counts(userId)).toEqual([1, 1])
  })
})

describe('the counts', () => {
  it('go with the account when it is deleted', async () => {
    const { token, userId } = await signUp()
    for (const table of ['workouts', 'bodyweight', 'routines', 'custom_exercises', 'exercise_prefs', 'gyms',
      'gym_equipment'] as const) {
      await seedRows(table, userId, 3)
    }
    expect((await save(token, workoutSample())).status).toBe(200)
    expect((await request('DELETE', '/v1/account', { token })).status).toBe(204)
    const left = await env.DB.prepare('SELECT count(*) AS n FROM account_rows WHERE user_id = ?1').bind(userId)
      .first<{ n: number }>()
    expect(left!.n).toBe(0)
  })
})
