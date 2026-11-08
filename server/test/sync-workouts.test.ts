import { describe, expect, it } from 'vitest'
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
      deleted_at: null, updated_at: saved.updated_at,
      entries: [{
        id: entry.id.toLowerCase(), exercise_id: 'bench_press', position: 0, note: null, superset_group: null,
        gym_equipment_id: null,
        sets: entry.sets.map((s: Record<string, unknown>) => ({
          sec: null, min: null, dist_m: null, rir: null, rpe: null, completed_at: null, ...s,
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
