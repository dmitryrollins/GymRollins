import { describe, expect, it } from 'vitest'
import { WORKOUT_CAPS } from '../src/sync/caps.ts'
import { countOf } from './cap-fixtures.ts'
import { genericItem, insertGym, insertListing } from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'
import { appUUID, T0, T1, T2, type WorkoutJSON, workoutSample } from './samples.ts'

interface Saved {
  status: 'ok' | 'stale'
  updated_at: string
}

const T3 = '2026-11-07T12:00:00.000000Z'

async function save(token: string, workout: unknown): Promise<Saved> {
  const res = await request('POST', '/v1/sync/workouts', { token, body: workout })
  expect(res.status).toBe(200)
  return res.json<Saved>()
}

async function fetchOne(token: string, id: string): Promise<WorkoutJSON> {
  const res = await request('GET', `/v1/sync/workouts/${id}`, { token })
  expect(res.status).toBe(200)
  return res.json<WorkoutJSON>()
}

async function pullPage(token: string, query: string): Promise<WorkoutJSON[]> {
  const res = await request('GET', `/v1/sync/workouts${query}`, { token })
  expect(res.status).toBe(200)
  return (await res.json<{ rows: WorkoutJSON[] }>()).rows
}

describe('saving a workout', () => {
  it('stores it with its entries and sets, and answers it as the app decodes it', async () => {
    const { token } = await signUp()
    const w = workoutSample()
    const saved = await save(token, w)
    expect(saved.status).toBe('ok')
    const [entry] = w.entries
    expect(await fetchOne(token, w.id)).toEqual({
      id: w.id.toLowerCase(), started_at: w.started_at, ended_at: w.ended_at, paused_sec: 0, routine_id: null,
      name: 'Push', source: 'app', note: null, vol_kg: 960, records: w.records, gym_id: null, client_updated_at: T1,
      deleted_at: null, added_by: null, updated_at: saved.updated_at,
      entries: [{
        id: entry.id.toLowerCase(), exercise_id: 'bench_press', position: 0, note: null, superset_group: null,
        gym_equipment_id: null,
        sets: entry.sets.map((s: Record<string, unknown>) => ({
          sec: null, min: null, dist_m: null, rir: null, rpe: null, completed_at: null, w_lb: null, ...s,
          id: String(s.id).toLowerCase(),
        })),
      }],
    })
  })

  it('fills in what upsert_workout defaulted', async () => {
    const { token } = await signUp()
    const id = appUUID()
    await save(token, {
      id, started_at: T0, name: 'Bare', client_updated_at: T1, base_updated_at: null, force: false,
      entries: [{ id: appUUID(), exercise_id: 'squat', position: 0, sets: [{ id: appUUID(), position: 0, w_kg: 100, r: 5 }] }],
    })
    const stored = await fetchOne(token, id)
    expect(stored).toMatchObject({ paused_sec: 0, source: 'app', vol_kg: 0, records: [], ended_at: null, deleted_at: null })
    expect(stored.entries[0].sets[0]).toMatchObject({ done: false, warmup: false, multiplier: 1 })
  })

  it('replaces the entries and sets with each save on the latest version', async () => {
    const { token } = await signUp()
    const w = workoutSample()
    const first = await save(token, w)
    const entry = { id: appUUID(), exercise_id: 'row', position: 0, note: 'new', superset_group: null, sets: [] }
    const second = await save(token, {
      ...w, name: 'Pull', entries: [entry], client_updated_at: T2, base_updated_at: first.updated_at,
    })
    expect(second.status).toBe('ok')
    expect(second.updated_at > first.updated_at).toBe(true)
    const stored = await fetchOne(token, w.id)
    expect(stored.name).toBe('Pull')
    expect(stored.entries.map((e) => e.id)).toEqual([entry.id.toLowerCase()])
    expect(stored.updated_at).toBe(second.updated_at)
  })

  it("answers stale when another phone saved since this edit's version, and changes nothing", async () => {
    const { token } = await signUp()
    const w = workoutSample()
    const first = await save(token, w)
    const other = await save(token, {
      ...w, name: 'From the other phone', client_updated_at: T2, base_updated_at: first.updated_at,
    })
    expect(other.status).toBe('ok')
    const late = await save(token, {
      ...w, name: 'From this phone', client_updated_at: T3, base_updated_at: first.updated_at,
    })
    expect(late).toEqual({ status: 'stale', updated_at: other.updated_at })
    expect((await fetchOne(token, w.id)).name).toBe('From the other phone')
  })

  it('answers stale for an edit older than the stored one', async () => {
    const { token } = await signUp()
    const w = workoutSample({ client_updated_at: T2 })
    const first = await save(token, w)
    expect(await save(token, { ...w, client_updated_at: T1, base_updated_at: first.updated_at }))
      .toEqual({ status: 'stale', updated_at: first.updated_at })
  })

  it('takes the retry of a save whose answer was lost, but no other edit without a version', async () => {
    const { token } = await signUp()
    const w = workoutSample()
    await save(token, w)
    expect((await save(token, w)).status).toBe('ok')
    expect((await save(token, { ...w, client_updated_at: T2 })).status).toBe('stale')
  })

  it("lets Keep this iPhone's overwrite, keeping the later edit time", async () => {
    const { token } = await signUp()
    const w = workoutSample({ client_updated_at: T2 })
    await save(token, w)
    const forced = await save(token, { ...w, name: 'Mine', client_updated_at: T1, force: true })
    expect(forced.status).toBe('ok')
    expect(await fetchOne(token, w.id)).toMatchObject({ name: 'Mine', client_updated_at: T2 })
  })

  it("refuses another account's workout id", async () => {
    const a = await signUp()
    const b = await signUp()
    const w = workoutSample()
    await save(a.token, w)
    const res = await request('POST', '/v1/sync/workouts', { token: b.token, body: { ...w, name: 'Taken', force: true } })
    expect(res.status).toBe(403)
    expect(await res.json()).toMatchObject({ error: { code: 'not_allowed' } })
    expect((await fetchOne(a.token, w.id)).name).toBe('Push')
  })

  it('refuses a set that breaks a rule, and keeps the stored workout whole', async () => {
    const { token } = await signUp()
    const w = workoutSample()
    const first = await save(token, w)
    const bad = structuredClone(w)
    bad.entries[0].sets[0].w_kg = 2000
    const res = await request('POST', '/v1/sync/workouts', {
      token, body: { ...bad, client_updated_at: T2, base_updated_at: first.updated_at },
    })
    expect(res.status).toBe(422)
    expect(await res.json()).toMatchObject({ error: { code: 'row_rejected' } })
    const stored = await fetchOne(token, w.id)
    expect(stored.updated_at).toBe(first.updated_at)
    expect(stored.entries[0].sets).toHaveLength(2)
  })

  it('refuses a value of the wrong type, saying where it is', async () => {
    const { token } = await signUp()
    const bad = workoutSample()
    bad.entries[0].sets[0].r = 'eight'
    const res = await request('POST', '/v1/sync/workouts', { token, body: bad })
    expect(res.status).toBe(422)
    expect(await res.json()).toEqual({
      error: { code: 'row_rejected', message: 'workout.entries[0].sets[0].r is not a valid int' },
    })
  })
})

describe('pulling workouts', () => {
  it('pages them with their entries, deleted ones included', async () => {
    const { token } = await signUp()
    const ids: string[] = []
    for (const deleted of [null, null, T1]) {
      const w = workoutSample({ deleted_at: deleted })
      await save(token, w)
      ids.push(w.id.toLowerCase())
    }
    const first = await pullPage(token, '?limit=2')
    expect(first).toHaveLength(2)
    const last = first[1]
    const rest = await pullPage(token, `?limit=2&since=${encodeURIComponent(last.updated_at)}&after=${last.id}`)
    const all = [...first, ...rest]
    expect(all.map((w) => w.id).sort()).toEqual(ids.sort())
    expect(all.every((w) => w.entries.length === 1 && w.entries[0].sets.length === 2)).toBe(true)
    expect(all.filter((w) => w.deleted_at !== null)).toHaveLength(1)
  })

  it("fetches one by id in either case, and answers 404 for one that isn't yours", async () => {
    const a = await signUp()
    const b = await signUp()
    const w = workoutSample()
    await save(a.token, w)
    expect((await fetchOne(a.token, w.id.toUpperCase())).id).toBe(w.id.toLowerCase())
    expect((await request('GET', `/v1/sync/workouts/${w.id}`, { token: b.token })).status).toBe(404)
    expect((await request('GET', `/v1/sync/workouts/${crypto.randomUUID()}`, { token: a.token })).status).toBe(404)
  })
})

describe("a workout's gym and listings", () => {
  it("keeps a gym and listing you can read, and drops ones you can't", async () => {
    const me = await signUp()
    const other = await signUp()
    const mine = await insertGym({ visibility: 'private', owner: me.userId })
    const listing = await insertListing({ gym: mine, item: await genericItem(), visibility: 'private', owner: me.userId })
    const w = workoutSample({ gym_id: mine.toUpperCase() })
    w.entries[0].gym_equipment_id = listing
    await save(me.token, w)
    const stored = await fetchOne(me.token, w.id)
    expect(stored.gym_id).toBe(mine)
    expect(stored.entries[0].gym_equipment_id).toBe(listing)
    const hidden = workoutSample({ gym_id: await insertGym({ visibility: 'private', owner: other.userId }) })
    await save(me.token, hidden)
    expect((await fetchOne(me.token, hidden.id)).gym_id).toBeNull()
  })

  it('keeps the stored links when the phone sends none', async () => {
    const me = await signUp()
    const gym = await insertGym({ visibility: 'public' })
    const listing = await insertListing({ gym, item: await genericItem(), visibility: 'public' })
    const w = workoutSample({ gym_id: gym })
    w.entries[0].gym_equipment_id = listing
    const first = await save(me.token, w)
    const { gym_id: _gym, ...unlinked } = w
    const entries = w.entries.map(({ gym_equipment_id: _listing, ...e }) => e)
    await save(me.token, { ...unlinked, entries, client_updated_at: T2, base_updated_at: first.updated_at })
    const stored = await fetchOne(me.token, w.id)
    expect(stored.gym_id).toBe(gym)
    expect(stored.entries[0].gym_equipment_id).toBe(listing)
  })
})

describe('workout saves under load and in shape', () => {
  const pad = (i: number) => String(i).padStart(2, '0')

  it('lets exactly one of two saves at once win, without mixing their entries or their counts', async () => {
    const { token, userId } = await signUp()
    const w = workoutSample()
    let base = (await save(token, w)).updated_at
    for (let i = 0; i < 10; i++) {
      const a = {
        ...w, name: `A${i}`, client_updated_at: `2026-11-07T11:00:${pad(i)}.000000Z`, base_updated_at: base,
        entries: [{ id: appUUID(), exercise_id: 'a', position: 0, sets: [] }],
      }
      const b = {
        ...w, name: `B${i}`, client_updated_at: `2026-11-07T11:00:${pad(i)}.500000Z`, base_updated_at: base,
        entries: [0, 1].map((position) => ({ id: appUUID(), exercise_id: 'b', position, sets: [] })),
      }
      const answers = await Promise.all([save(token, a), save(token, b)])
      expect(answers.map((r) => r.status).sort()).toEqual(['ok', 'stale'])
      const stored = await fetchOne(token, w.id)
      const winner = stored.name === `A${i}` ? { exercise: 'a', count: 1 } : { exercise: 'b', count: 2 }
      expect(stored.name).toBe(`${winner.exercise.toUpperCase()}${i}`)
      expect(stored.entries.map((e) => e.exercise_id)).toEqual(Array(winner.count).fill(winner.exercise))
      expect(answers.find((r) => r.status === 'stale')!.updated_at).toBe(stored.updated_at)
      // The losing save moved no count: account_rows still equals what is stored (countOf checks both).
      expect(await countOf('workout_entries', userId)).toBe(winner.count)
      expect(await countOf('workout_sets', userId)).toBe(0)
      base = stored.updated_at
    }
  })

  it("answers pulled workouts with only the app's keys", async () => {
    const { token } = await signUp()
    await save(token, workoutSample())
    const [w] = await pullPage(token, '')
    const keys = (o: Record<string, unknown>) => Object.keys(o).sort()
    expect(keys(w)).toEqual([
      'id', 'started_at', 'ended_at', 'paused_sec', 'routine_id', 'name', 'source', 'note', 'vol_kg', 'records',
      'gym_id', 'client_updated_at', 'deleted_at', 'added_by', 'updated_at', 'entries',
    ].sort())
    expect(keys(w.entries[0])).toEqual(
      ['id', 'exercise_id', 'position', 'note', 'superset_group', 'gym_equipment_id', 'sets'].sort(),
    )
    expect(keys(w.entries[0].sets[0])).toEqual([
      'id', 'position', 'w_kg', 'w_lb', 'r', 'sec', 'min', 'dist_m', 'done', 'warmup', 'rir', 'rpe', 'multiplier', 'completed_at',
    ].sort())
  })

  it('orders entries and sets by position', async () => {
    const { token } = await signUp()
    const set = (position: number) => ({ id: appUUID(), position, w_kg: 20, r: 5 })
    const entries = [2, 0, 1].map((position) => ({
      id: appUUID(), exercise_id: `x${position}`, position, sets: [set(2), set(0), set(1)],
    }))
    const w = workoutSample({ entries })
    await save(token, w)
    const stored = await fetchOne(token, w.id)
    expect(stored.entries.map((e) => e.position)).toEqual([0, 1, 2])
    expect(stored.entries.map((e) => e.exercise_id)).toEqual(['x0', 'x1', 'x2'])
    expect(stored.entries.every((e) => e.sets.map((s: Record<string, unknown>) => s.position).join() === '0,1,2')).toBe(true)
  })

  it('fetches a deleted workout', async () => {
    const { token } = await signUp()
    const w = workoutSample({ deleted_at: T1 })
    await save(token, w)
    expect((await fetchOne(token, w.id)).deleted_at).toBe(T1)
  })
})

describe('the size of one workout', () => {
  const sets = (n: number) => Array.from({ length: n }, (_, i) => ({ id: appUUID(), position: i, w_kg: 60, r: 8 }))
  const entries = (n: number, setsEach = 1) => Array.from({ length: n }, (_, i) => ({
    id: appUUID(), exercise_id: `ex_${i}`, position: i, note: null, superset_group: null, sets: sets(setsEach),
  }))
  /** Three exercises, the last with `n` sets. */
  const oneLong = (n: number) =>
    workoutSample({ entries: entries(3).map((e, i) => (i === 2 ? { ...e, sets: sets(n) } : e)) })
  const push = (token: string, workout: unknown) => request('POST', '/v1/sync/workouts', { token, body: workout })

  async function refusedWith(res: Response, code: keyof typeof WORKOUT_CAPS): Promise<void> {
    expect(res.status).toBe(422)
    expect(await res.json()).toEqual({ error: { code, message: WORKOUT_CAPS[code] } })
  }

  it('takes 49 and 50 exercises, and refuses 51 with the words the app shows', async () => {
    const { token } = await signUp()
    for (const n of [49, 50]) expect((await push(token, workoutSample({ entries: entries(n) }))).status).toBe(200)
    const refused = workoutSample({ entries: entries(51) })
    await refusedWith(await push(token, refused), 'too_many_workout_exercises')
    expect((await request('GET', `/v1/sync/workouts/${refused.id}`, { token })).status).toBe(404)
  })

  it('takes 49 and 50 sets in an exercise, and refuses 51 in any one of them', async () => {
    const { token } = await signUp()
    for (const n of [49, 50]) expect((await push(token, oneLong(n))).status).toBe(200)
    await refusedWith(await push(token, oneLong(51)), 'too_many_exercise_sets')
  })

  it('saves a workout at both caps, 50 exercises of 50 sets, within the body limit', async () => {
    const { token } = await signUp()
    const w = workoutSample({ entries: entries(50, 50) })
    expect(JSON.stringify(w).length).toBeLessThan(1024 * 1024)
    expect((await push(token, w)).status).toBe(200)
    const stored = await fetchOne(token, w.id)
    expect(stored.entries).toHaveLength(50)
    expect(stored.entries.every((e) => e.sets.length === 50)).toBe(true)
  })

  it('refuses before anything is written: a stored workout keeps its entries when an edit is too big', async () => {
    const { token } = await signUp()
    const w = workoutSample()
    const first = await save(token, w)
    const tooBig = { ...w, entries: entries(51), client_updated_at: T2, base_updated_at: first.updated_at }
    await refusedWith(await push(token, tooBig), 'too_many_workout_exercises')
    const stored = await fetchOne(token, w.id)
    expect(stored.entries.map((e) => e.id)).toEqual([w.entries[0].id.toLowerCase()])
    expect(stored.updated_at).toBe(first.updated_at)
  })
})

describe("a set's pound number", () => {
  const withSets = (sets: Record<string, unknown>[]) => {
    const w = workoutSample()
    w.entries[0].sets = sets.map((s, position) => ({ id: appUUID(), position, r: 5, ...s }))
    return w
  }

  it('is saved and pulled as w_lb; a set without it comes back null', async () => {
    const { token } = await signUp()
    const w = withSets([{ w_kg: 20.41165665, w_lb: 45 }, { w_kg: 20 }])
    await save(token, w)
    const sets = (await fetchOne(token, w.id)).entries[0].sets
    expect(sets.map((s: Record<string, unknown>) => [s.w_kg, s.w_lb])).toEqual([[20.41165665, 45], [20, null]])
  })

  it('is kept when the workout is saved again, and may be cleared', async () => {
    const { token } = await signUp()
    const w = withSets([{ w_kg: 20.41165665, w_lb: 45 }])
    const first = await save(token, w)
    const again = { ...w, client_updated_at: T2, base_updated_at: first.updated_at }
    again.entries = [{ ...w.entries[0], sets: [{ ...w.entries[0].sets[0], w_kg: 20, w_lb: null }] }]
    await save(token, again)
    expect((await fetchOne(token, w.id)).entries[0].sets[0]).toMatchObject({ w_kg: 20, w_lb: null })
  })

  it('is refused above 2205', async () => {
    const { token } = await signUp()
    const res = await request('POST', '/v1/sync/workouts', { token, body: withSets([{ w_kg: 1000, w_lb: 2206 }]) })
    expect(res.status).toBeGreaterThanOrEqual(400)
  })
})
