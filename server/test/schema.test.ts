import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { signUp } from './helpers.ts'

const T = '2026-11-07T10:00:00.000000Z'

async function count(sql: string, ...bindings: unknown[]): Promise<number> {
  return (await env.DB.prepare(sql).bind(...bindings).first<{ n: number }>())!.n
}

describe('the D1 schema', () => {
  it('holds the exercise library and the equipment catalogue', async () => {
    expect(await count('SELECT count(*) AS n FROM exercises')).toBe(1324)
    expect(await count('SELECT count(*) AS n FROM equipment_kinds')).toBe(46)
    expect(await count('SELECT count(*) AS n FROM equipment_items WHERE brand IS NULL AND model IS NULL')).toBe(46)
    expect(await count('SELECT count(*) AS n FROM exercise_requirements')).toBe(1107)
  })

  it("keeps the library's lists as JSON arrays", async () => {
    const bad = await count("SELECT count(*) AS n FROM exercises WHERE json_type(sm) <> 'array' OR json_type(st) <> 'array'")
    expect(bad).toBe(0)
  })

  it('enforces foreign keys', async () => {
    expect(await env.DB.prepare('PRAGMA foreign_keys').first()).toEqual({ foreign_keys: 1 })
  })

  it('refuses a timestamp that is not in the stored form', async () => {
    const { userId } = await signUp()
    const insert = env.DB.prepare('INSERT INTO profiles (user_id, client_updated_at, updated_at) VALUES (?1, ?2, ?3)')
    await expect(insert.bind(userId, '2026-11-07T10:00:00Z', T).run()).rejects.toThrow(/CHECK constraint failed/)
    await expect(insert.bind(userId, T, T).run()).resolves.toBeTruthy()
  })

  it.each([
    '2026-11-07T10:00:00.000000',
    '2026-11-07T10:00:00.00000Z',
    '2026-11-07 10:00:00.000000Z',
  ])('refuses the malformed timestamp %s', async (bad) => {
    const { userId } = await signUp()
    const insert = env.DB.prepare('INSERT INTO profiles (user_id, client_updated_at, updated_at) VALUES (?1, ?2, ?3)')
    await expect(insert.bind(userId, bad, T).run()).rejects.toThrow(/CHECK constraint failed/)
  })

  it("keeps every GLOB and LIKE pattern within D1's 50-byte limit", () => {
    const tooLong: string[] = []
    for (const migration of env.TEST_MIGRATIONS) {
      for (const query of migration.queries) {
        for (const match of query.matchAll(/\b(?:GLOB|LIKE)\s+'((?:[^']|'')*)'/gi)) {
          const bytes = new TextEncoder().encode(match[1]!).length
          if (bytes > 50) tooLong.push(`${migration.name}: ${bytes} bytes: ${match[1]}`)
        }
      }
    }
    expect(tooLong).toEqual([])
  })

  it('checks a listing photo name', async () => {
    const gymId = crypto.randomUUID()
    await env.DB.prepare(`INSERT INTO gyms (id, visibility, name, maps_place_id, status, client_updated_at, created_at, updated_at)
      VALUES (?1, 'public', 'Test gym', ?2, 'active', ?3, ?3, ?3)`).bind(gymId, `place-${gymId}`, T).run()
    const item = await env.DB.prepare("SELECT id FROM equipment_items WHERE kind_id = 'dumbbells' AND brand IS NULL")
      .first<{ id: string }>()
    const insert = (photo: string) => env.DB.prepare(`INSERT INTO gym_equipment
      (id, gym_id, item_id, visibility, photo_path, client_updated_at, created_at, updated_at)
      VALUES (?1, ?2, ?3, 'public', ?4, ?5, ?5, ?5)`).bind(crypto.randomUUID(), gymId, item!.id, photo, T).run()
    const uuid = crypto.randomUUID()
    await expect(insert(`${uuid}.jpg`)).resolves.toBeTruthy()
    const moved = `${uuid.slice(0, 8)}${uuid[9]}-${uuid.slice(10)}.jpg`
    const rejected = [`${uuid.toUpperCase()}.jpg`, `${uuid.slice(1)}.jpg`, `${uuid}.png`, moved, uuid]
    for (const photo of rejected) {
      await expect(insert(photo), photo).rejects.toThrow(/CHECK constraint failed/)
    }
  })

  it("removes an account's rows with the account", async () => {
    const { userId } = await signUp()
    await env.DB.prepare('INSERT INTO profiles (user_id, client_updated_at, updated_at) VALUES (?1, ?2, ?2)')
      .bind(userId, T).run()
    await env.DB.prepare('DELETE FROM "user" WHERE id = ?1').bind(userId).run()
    expect(await count('SELECT count(*) AS n FROM profiles WHERE user_id = ?1', userId)).toBe(0)
    expect(await count('SELECT count(*) AS n FROM session WHERE userId = ?1', userId)).toBe(0)
  })

  it.each([
    ['gyms_private_cap', 'gyms_owner_live'],
    ['gyms_private_cap_revived', 'gyms_owner_live'],
    ['gym_equipment_private_cap', 'gym_equipment_owner_live'],
    ['gym_equipment_private_cap_revived', 'gym_equipment_owner_live'],
  ])("counts %s's live rows through %s, never an owner's tombstones", async (trigger, index) => {
    const { sql } = (await env.DB.prepare("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?1")
      .bind(trigger).first<{ sql: string }>())!
    const counted = /\(SELECT count\(\*\) FROM (\w+ WHERE [^)]*)\)/.exec(sql)
    expect(counted, sql).not.toBeNull()
    const query = `SELECT count(*) FROM ${counted![1]}`.replaceAll('NEW.owner_id', '?1').replaceAll('NEW.id', '?2')
    const plan = await env.DB.prepare(`EXPLAIN QUERY PLAN ${query}`).bind(crypto.randomUUID(), crypto.randomUUID())
      .all<{ detail: string }>()
    expect(plan.results.map((r) => r.detail).join('\n'), query).toMatch(new RegExp(`USING (COVERING )?INDEX ${index}\\b`))
  })

  it("indexes a workout's entries and an entry's sets", async () => {
    const { results } = await env.DB.prepare("SELECT name FROM sqlite_master WHERE type = 'index'").all<{ name: string }>()
    const names = results.map((r) => r.name)
    expect(names).toContain('workout_entries_workout')
    expect(names).toContain('workout_sets_entry')
    const plan = await env.DB.prepare("EXPLAIN QUERY PLAN DELETE FROM workout_entries WHERE workout_id = 'x'")
      .all<{ detail: string }>()
    expect(plan.results.map((r) => r.detail).join('\n')).toMatch(/USING (COVERING )?INDEX workout_entries_workout/)
  })
})
