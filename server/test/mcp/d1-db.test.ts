// Claude's D1 Db against real D1 (replaces the pgTAP files on MCP access): each toggle hides exactly its
// data, the only writes are pending proposals and body weight, and 70 concurrent calls take exactly 60 slots.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { D1Db } from '../../src/mcp/d1-db.ts'
import { ToolError } from '../../src/mcp/tools/result.ts'
import { block, genericItem, insertGym, insertItem, insertListing } from '../gym-fixtures.ts'
import { signUp } from '../helpers.ts'

const T = '2026-11-07T10:00:00.000000Z'
const DB = env.DB

type Toggle = 'mcp_read_plan' | 'mcp_read_workouts' | 'mcp_read_body' | 'mcp_read_gyms' | 'mcp_propose'

interface Owner {
  userId: string
  workoutId: string
  privateGym: string
  publicGym: string
  trainedGym: string
}

const run = (sql: string, ...binds: unknown[]) => DB.prepare(sql).bind(...binds).run()

/** One account with a row in every table Claude reads, and every toggle on. */
async function seedOwner(): Promise<Owner> {
  const { userId } = await signUp()
  await run(
    'INSERT INTO profiles (user_id, unit, limits, client_updated_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?4)',
    userId,
    'kg',
    'left knee',
    T,
  )
  const routineId = crypto.randomUUID()
  const exercises = JSON.stringify([{
    id: crypto.randomUUID(),
    exercise_id: '0025',
    position: 0,
    sets: 3,
    reps: 8,
    mode: 'reps',
  }])
  await run(
    'INSERT INTO routines (id, user_id, name, policy, position, paused, exercises, client_updated_at, ' +
      'updated_at) ' +
      "VALUES (?1, ?2, 'Push', 'double', 0, 0, ?3, ?4, ?4)",
    routineId,
    userId,
    exercises,
    T,
  )
  await run(
    'INSERT INTO week_schedule (user_id, weekday, routine_id, client_updated_at, updated_at) VALUES (?1, ' +
      '1, ?2, ?3, ?3)',
    userId,
    routineId,
    T,
  )
  await run(
    'INSERT INTO muscle_targets (user_id, muscle, min_sets, max_sets, client_updated_at, updated_at) ' +
      "VALUES (?1, 'chest', 10, 16, ?2, ?2)",
    userId,
    T,
  )
  await run(
    'INSERT INTO exercise_prefs (user_id, exercise_id, pref, client_updated_at, updated_at) VALUES (?1, ' +
      "'0001', 'never', ?2, ?2)",
    userId,
    T,
  )
  await run(
    'INSERT INTO custom_exercises (id, user_id, n, bp, eq, tg, mode, client_updated_at, updated_at) ' +
      "VALUES (?1, ?2, 'Sled push 100%_x', 'upper legs', 'sled machine', 'quads', 'reps', ?3, ?3)",
    `custom-${crypto.randomUUID()}`,
    userId,
    T,
  )
  const trainedGym = await insertGym({ visibility: 'public' })
  const workoutId = crypto.randomUUID()
  await run(
    'INSERT INTO workouts (id, user_id, started_at, name, gym_id, client_updated_at, updated_at) ' +
      "VALUES (?1, ?2, '2026-11-06T09:00:00.000000Z', 'Push', ?3, ?4, ?4)",
    workoutId,
    userId,
    trainedGym,
    T,
  )
  const entryId = crypto.randomUUID()
  await run(
    'INSERT INTO workout_entries (id, workout_id, user_id, exercise_id, position) VALUES (?1, ?2, ?3, ' +
      "'0025', 0)",
    entryId,
    workoutId,
    userId,
  )
  await run(
    'INSERT INTO workout_sets (id, entry_id, user_id, position, w_kg, r, done) VALUES (?1, ?2, ?3, 0, 60, ' +
      '8, 1)',
    crypto.randomUUID(),
    entryId,
    userId,
  )
  await run(
    'INSERT INTO bodyweight (id, user_id, measured_at, w_kg, client_updated_at, updated_at) VALUES (?1, ' +
      "?2, '2026-11-05T07:00:00.000000Z', 81, ?3, ?3)",
    crypto.randomUUID(),
    userId,
    T,
  )
  const privateGym = await insertGym({ visibility: 'private', owner: userId })
  await insertListing({ gym: privateGym, item: await genericItem(), visibility: 'private', owner: userId })
  const publicGym = await insertGym({ visibility: 'public', createdBy: userId })
  await insertListing({
    gym: publicGym,
    item: await genericItem('barbell'),
    visibility: 'public',
    addedBy: userId,
  })
  return { userId, workoutId, privateGym, publicGym, trainedGym }
}

const toggle = (userId: string, column: Toggle, on: boolean) =>
  run(`UPDATE profiles SET ${column} = ?2 WHERE user_id = ?1`, userId, on ? 1 : 0)

/** The profile without its mcp_* fields, which show the toggles themselves. */
const withoutToggles = (p: object | null) =>
  p && Object.fromEntries(Object.entries(p).filter(([k]) => !k.startsWith('mcp_')))

/** Every read Claude can make, by name. */
async function snapshot(o: Owner): Promise<Record<string, unknown>> {
  const db = new D1Db(DB, o.userId, 'claude')
  const custom = (await db.searchExercises({ query: 'sled', limit: 5 })).filter((e) => e.custom)
  return {
    profile: withoutToggles(await db.profile()),
    routines: await db.routines(),
    weekSchedule: await db.weekSchedule(),
    muscleTargets: await db.muscleTargets(),
    exercisePreferences: await db.exercisePreferences(),
    customExercises: custom,
    workouts: await db.workouts({ limit: 10 }),
    workout: await db.workout(o.workoutId),
    exerciseSets: await db.exerciseSets('0025'),
    workoutDates: await db.workoutDates(),
    performedExerciseIds: [...await db.performedExerciseIds(['0025'])],
    bodyweight: await db.bodyweight(),
    latestBodyweight: await db.latestBodyweight('2026-11-08T00:00:00.000Z'),
    privateGyms: await db.privateGyms(10),
    myPublicGyms: await db.myPublicGyms(10),
    privateListings: await db.gymListings(o.privateGym, 10),
    publicListings: await db.gymListings(o.publicGym, 10),
  }
}

const changed = (a: Record<string, unknown>, b: Record<string, unknown>) =>
  Object.keys(a).filter((k) => JSON.stringify(a[k]) !== JSON.stringify(b[k])).sort()

describe("Claude's reads", () => {
  it("return the owner's rows with every toggle on, and nothing of anyone else's", async () => {
    const owner = await seedOwner()
    const all = await snapshot(owner)
    expect(await new D1Db(DB, owner.userId, 'claude').profile())
      .toMatchObject({ unit: 'kg', limits: 'left knee', mcp_read_plan: true, mcp_auto_apply: false })
    expect((all.routines as { paused: boolean; exercises: unknown[] }[])[0]).toMatchObject({ paused: false })
    expect(
      (all.workouts as { workout_entries: { workout_sets: unknown[] }[] }[])[0].workout_entries[0]
        .workout_sets,
    )
      .toEqual([{
        position: 0,
        w_kg: 60,
        r: 8,
        sec: null,
        min: null,
        dist_m: null,
        done: true,
        warmup: false,
        rir: null,
        rpe: null,
        multiplier: 1,
      }])
    expect(all.exerciseSets).toHaveLength(1)
    expect(all.customExercises).toHaveLength(1)
    expect((all.myPublicGyms as { id: string; is_mine: boolean }[]).map((g) => [g.id, g.is_mine]).sort())
      .toEqual([[owner.publicGym, true], [owner.trainedGym, false]].sort())
    expect(all.privateListings).toMatchObject([{
      visibility: 'private',
      kind_id: 'dumbbells',
      is_mine: true,
    }])
    expect(all.publicListings).toMatchObject([{
      visibility: 'public',
      kind_id: 'barbell',
      is_mine: true,
      item_is_mine: false,
    }])

    const stranger = await seedOwner()
    const theirs = await snapshot({ ...owner, userId: stranger.userId })
    expect(JSON.stringify(theirs)).not.toContain(owner.workoutId)
    expect(theirs.privateListings).toEqual([])
  })

  const HIDES: Record<Toggle, string[]> = {
    mcp_read_plan: [
      'customExercises',
      'exercisePreferences',
      'muscleTargets',
      'profile',
      'routines',
      'weekSchedule',
    ],
    mcp_read_workouts: [
      'exerciseSets',
      'myPublicGyms',
      'performedExerciseIds',
      'workout',
      'workoutDates',
      'workouts',
    ],
    mcp_read_body: ['bodyweight', 'latestBodyweight'],
    mcp_read_gyms: ['myPublicGyms', 'privateGyms', 'privateListings', 'publicListings'],
    mcp_propose: [],
  }

  it.each(Object.entries(HIDES))('%s off hides exactly its data', async (column, hidden) => {
    const owner = await seedOwner()
    const all = await snapshot(owner)
    await toggle(owner.userId, column as Toggle, false)
    expect(changed(all, await snapshot(owner))).toEqual(hidden)
  })

  it("gyms off keeps public listings but stops calling any of them the owner's", async () => {
    const owner = await seedOwner()
    await toggle(owner.userId, 'mcp_read_gyms', false)
    const db = new D1Db(DB, owner.userId, 'claude')
    expect(await db.gymListings(owner.publicGym, 10)).toMatchObject([{ kind_id: 'barbell', is_mine: false }])
    expect((await db.myPublicGyms(10)).map((g) => g.id)).toEqual([owner.trainedGym])
  })

  it("never shows a blocked author's listing, or a flagged or removed one", async () => {
    const owner = await seedOwner()
    const { userId: stranger } = await signUp()
    const item = await insertItem({ brand: 'Acme', model: 'X1', createdBy: stranger })
    await insertListing({ gym: owner.publicGym, item, visibility: 'public', addedBy: stranger })
    await insertListing({
      gym: owner.publicGym,
      item: await genericItem('kettlebells'),
      visibility: 'public',
      status: 'flagged',
      addedBy: owner.userId,
    })
    const db = () => new D1Db(DB, owner.userId, 'claude')
    expect((await db().gymListings(owner.publicGym, 10)).map((l) => l.brand).sort()).toEqual(['Acme', null])
    await block(owner.userId, stranger)
    expect((await db().gymListings(owner.publicGym, 10)).map((l) => l.kind_id)).toEqual(['barbell'])
  })

  it('answers never_exercise_ids while the plan or propose toggle is on', async () => {
    const owner = await seedOwner()
    const never =
      async () => [...await new D1Db(DB, owner.userId, 'claude').neverExerciseIds(['0001', '0025'])]
    expect(await never()).toEqual(['0001'])
    await toggle(owner.userId, 'mcp_read_plan', false)
    expect(await never()).toEqual(['0001'])
    await toggle(owner.userId, 'mcp_propose', false)
    expect(await never()).toEqual([])
  })

  it("finds exercises by every word, literally and past D1's 50-byte LIKE limit", async () => {
    const owner = await seedOwner()
    const db = new D1Db(DB, owner.userId, 'claude')
    expect((await db.searchExercises({ query: 'SLED 100%_x', limit: 5 })).map((e) => e.n)).toEqual([
      'Sled push 100%_x',
    ])
    expect(await db.searchExercises({ query: '%', limit: 5 })).toHaveLength(1)
    expect(await db.searchExercises({ query: 'x'.repeat(80), limit: 5 })).toEqual([])
    expect((await db.searchExercises({ query: 'bench press', limit: 3 })).length).toBeGreaterThan(0)
  })
})

describe("Claude's writes", () => {
  it('inserts a pending proposal, and refuses one while propose is off', async () => {
    const owner = await seedOwner()
    const db = new D1Db(DB, owner.userId, 'claude')
    const { id, created_at } = await db.insertProposal({
      summary: 'More bench',
      changes: [{ id: 'c1', type: 'sets' }],
    })
    expect(created_at).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/)
    expect(await db.proposal(id)).toMatchObject({
      status: 'pending',
      changes: [{ id: 'c1' }],
      applied_change_ids: [],
    })
    expect(await new D1Db(DB, (await signUp()).userId, 'claude').proposal(id)).toBeNull()
    await toggle(owner.userId, 'mcp_propose', false)
    await expect(new D1Db(DB, owner.userId, 'claude').insertProposal({ summary: 'x', changes: [{}] }))
      .rejects.toThrow(ToolError)
  })

  it('inserts a body weight, never over an existing one, and refuses one while body is off', async () => {
    const owner = await seedOwner()
    const db = new D1Db(DB, owner.userId, 'claude')
    const row = { id: crypto.randomUUID(), measured_at: '2026-11-07T12:00:00.000Z', w_kg: 82 }
    await db.insertBodyweight(row)
    expect(await db.latestBodyweight('2026-11-08T00:00:00.000Z'))
      .toMatchObject({ id: row.id, measured_at: '2026-11-07T12:00:00.000000Z', w_kg: 82 })
    await expect(db.insertBodyweight({ ...row, w_kg: 90 })).rejects.toThrow(/UNIQUE/)
    await toggle(owner.userId, 'mcp_read_body', false)
    await expect(new D1Db(DB, owner.userId, 'claude').insertBodyweight({ ...row, id: crypto.randomUUID() }))
      .rejects.toThrow(ToolError)
  })

  it('has no other way to change data than proposals, body weight, the audit and the call slots', () => {
    const methods = Object.getOwnPropertyNames(D1Db.prototype).filter((m) =>
      /^(insert|update|delete|upsert|save|set)/i.test(m)
    )
    expect(methods.sort()).toEqual(['insertBodyweight', 'insertProposal'])
  })

  it('audits a call with the client id', async () => {
    const owner = await seedOwner()
    await new D1Db(DB, owner.userId, 'client-1').audit('get_plan', true, 'a'.repeat(64))
    const row = await DB.prepare('SELECT client_id, tool, ok FROM mcp_audit WHERE user_id = ?1').bind(
      owner.userId,
    ).first()
    expect(row).toEqual({ client_id: 'client-1', tool: 'get_plan', ok: 1 })
  })
})

describe('the rate limit', () => {
  it('gives exactly 60 of 70 concurrent calls a slot, per user', async () => {
    const { userId } = await signUp()
    const results = await Promise.all(Array.from({ length: 70 }, () => new D1Db(DB, userId, 'c').takeCall()))
    expect(results.filter(Boolean)).toHaveLength(60)
    expect(await new D1Db(DB, (await signUp()).userId, 'c').takeCall()).toBe(true)
  })

  it('stops counting a call after a minute', async () => {
    const { userId } = await signUp()
    const old = '2026-01-01T00:00:00.000000Z'
    await DB.batch(
      Array.from(
        { length: 60 },
        () => DB.prepare('INSERT INTO mcp_calls (user_id, at) VALUES (?1, ?2)').bind(userId, old),
      ),
    )
    expect(await new D1Db(DB, userId, 'c').takeCall()).toBe(true)
    const left = await DB.prepare('SELECT count(*) AS n FROM mcp_calls WHERE user_id = ?1').bind(userId)
      .first<{ n: number }>()
    expect(left!.n).toBe(1)
  })
})
