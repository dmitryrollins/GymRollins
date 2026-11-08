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

  it("removes an account's rows with the account", async () => {
    const { userId } = await signUp()
    await env.DB.prepare('INSERT INTO profiles (user_id, client_updated_at, updated_at) VALUES (?1, ?2, ?2)')
      .bind(userId, T).run()
    await env.DB.prepare('DELETE FROM "user" WHERE id = ?1').bind(userId).run()
    expect(await count('SELECT count(*) AS n FROM profiles WHERE user_id = ?1', userId)).toBe(0)
    expect(await count('SELECT count(*) AS n FROM session WHERE userId = ?1', userId)).toBe(0)
  })
})
