import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { DomainLimits } from '../src/shared/domain-limits.ts'
import { countOf, type HealthTable, seedRows } from './cap-fixtures.ts'
import { insertUser } from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'
import { SAMPLES } from './samples.ts'

// The counts in health_rows (plan 39, migrations/0013_health_activities.sql), kept like account_rows' (plan 31): a
// deleted row lowers its count, and an account at both caps is deleted whole, its counts with it.

describe('health_rows', () => {
  const TABLES: HealthTable[] = ['health_activities', 'activity_days']

  it.each(TABLES)('a deleted row lowers the count of %s', async (table) => {
    const userId = await insertUser()
    await seedRows(table, userId, 3)
    expect(await countOf(table, userId)).toBe(3)
    await env.DB.prepare(
      `DELETE FROM ${table} WHERE rowid IN (SELECT rowid FROM ${table} WHERE user_id = ?1 LIMIT 1)`,
    ).bind(userId).run()
    expect(await countOf(table, userId)).toBe(2)
  })

  it('an account at both caps refuses one more and is deleted whole, with no count left', async () => {
    const { token, userId } = await signUp()
    await seedRows('health_activities', userId, DomainLimits.healthActivitiesMax)
    await seedRows('activity_days', userId, DomainLimits.activityDaysMax)
    const oneMore = await request('POST', '/v1/sync/activity-days', {
      token, body: { rows: [SAMPLES['activity-days']()] },
    })
    expect(oneMore.status).toBe(422)

    expect((await request('DELETE', '/v1/account', { token })).status).toBe(204)
    expect(await countOf('health_activities', userId)).toBe(0)
    expect(await countOf('activity_days', userId)).toBe(0)
    const left = await env.DB.prepare('SELECT count(*) AS n FROM health_rows WHERE user_id = ?1').bind(userId)
      .first<{ n: number }>()
    expect(left!.n).toBe(0)
  }, 120_000)
})
