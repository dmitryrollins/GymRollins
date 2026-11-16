// get_activity (plan 39): outside workouts after rules 6 and 7, the per-day and per-week totals, the window and its time
// zone, and the switch.
import { describe, expect, it } from 'vitest'
import type { HealthActivityRow, WorkoutRow } from '../../../src/mcp/db.ts'
import { getActivity } from '../../../src/mcp/tools/activity.ts'
import { notAllowed } from '../../../src/mcp/tools/permissions.ts'
import { ToolError, type ToolResult } from '../../../src/mcp/tools/result.ts'
import { FakeDb, type FakeData, loadOwnerData } from '../fake-db.ts'

const NOW = new Date('2026-09-26T09:00:00Z') // Saturday

function outside(id: string, kind: string, start: string, minutes: number,
  extra: Partial<HealthActivityRow> = {}): HealthActivityRow {
  return {
    id, kind, started_at: start, ended_at: new Date(Date.parse(start) + minutes * 60_000).toISOString(),
    duration_s: minutes * 60, kcal: null, distance_m: null, avg_hr: null, max_hr: null, avg_power_w: null,
    avg_cadence_rpm: null, total_kcal: null, source_name: 'Strava', from_watch: false, ...extra,
  }
}

const workout = (id: string, start: string): WorkoutRow => ({
  id, started_at: start, ended_at: new Date(Date.parse(start) + 3_600_000).toISOString(), paused_sec: 0,
  routine_id: null, name: 'Push', workout_entries: [],
})

async function ctx(mutate?: (d: FakeData) => void) {
  const data = await loadOwnerData()
  data.workouts = [workout('w1', '2026-09-22T17:00:00Z')]
  data.activities = [
    outside('a1', 'walking', '2026-09-25T07:00:00.000000Z', 45,
      { kcal: 180, distance_m: 3400, avg_hr: 102, max_hr: 121, source_name: 'Apple Watch', from_watch: true }),
    outside('a2', 'traditional_strength', '2026-09-22T17:05:00.000000Z', 50,
      { kcal: 412, avg_hr: 128, max_hr: 162, source_name: 'Apple Watch', from_watch: true }), // during w1
    outside('a3', 'walking', '2026-09-25T07:01:00.000000Z', 44, { kcal: 175 }), // Strava's copy of a1
    outside('a4', 'running', '2026-09-20T08:00:00.000000Z', 30),
    outside('a5', 'running', '2026-08-01T08:00:00.000000Z', 30), // before the 28 days
  ]
  data.days = [
    { day: '2026-08-01', steps: 9000, move_kcal: 450, exercise_min: 40, stand_h: 12 },
    { day: '2026-09-20', steps: 6000, move_kcal: 300, exercise_min: 25, stand_h: 10 },
    { day: '2026-09-25', steps: 8532, move_kcal: 410, exercise_min: 34, stand_h: 11 },
    { day: '2026-09-26', steps: 4210, move_kcal: 210, exercise_min: 18, stand_h: null },
  ]
  mutate?.(data)
  return { db: new FakeDb(data), now: NOW }
}

const json = (r: ToolResult) => {
  expect(r.isError).toBeFalsy()
  return JSON.parse(r.content[0]!.text)
}

describe('get_activity', () => {
  it('lists outside workouts newest first: an attached one says during which workout, copies once', async () => {
    const out = json(await getActivity(await ctx(), {}))
    expect(out.days).toBe(28)
    expect(out.first_day).toBe('2026-08-30')
    expect(out.outside_workouts).toEqual([
      {
        kind: 'walking', started_at: '2026-09-25T07:00:00.000000Z', duration_min: 45, distance_km: 3.4, kcal: 180,
        avg_hr: 102, max_hr: 121, source: 'Apple Watch',
      },
      {
        kind: 'traditional_strength', started_at: '2026-09-22T17:05:00.000000Z', duration_min: 50, kcal: 412,
        avg_hr: 128, max_hr: 162, source: 'Apple Watch', during_workout_id: 'w1',
      },
      { kind: 'running', started_at: '2026-09-20T08:00:00.000000Z', duration_min: 30, source: 'Strava' },
    ])
    expect(out.outside_workouts_total).toBe(3)
    expect(out.method).toContain('never add the two')
  })

  it("gives a ride's average power, average cadence and total kcal, only when the workout has them", async () => {
    const ride = await ctx((d) => {
      d.activities = [
        outside('r1', 'cycling', '2026-09-25T17:00:00.000000Z', 13.5,
          { kcal: 40.4, avg_power_w: 138, avg_cadence_rpm: 62, total_kcal: 47.6, source_name: 'Apple Watch' }),
        outside('r2', 'running', '2026-09-24T07:00:00.000000Z', 30, { avg_power_w: 241 }),
      ]
    })
    expect(json(await getActivity(ride, {})).outside_workouts).toEqual([
      {
        kind: 'cycling', started_at: '2026-09-25T17:00:00.000000Z', duration_min: 14, kcal: 40, total_kcal: 48,
        avg_power_w: 138, avg_cadence_rpm: 62, source: 'Apple Watch',
      },
      { kind: 'running', started_at: '2026-09-24T07:00:00.000000Z', duration_min: 30, avg_power_w: 241, source: 'Strava' },
    ])
  })

  it('totals each day and each Monday–Sunday week, leaving attached workouts out', async () => {
    const out = json(await getActivity(await ctx(), {}))
    expect(out.days_of_activity).toEqual([
      { day: '2026-09-26', steps: 4210, move_kcal: 210, exercise_min: 18, outside_workouts: 0, outside_minutes: 0 },
      {
        day: '2026-09-25', steps: 8532, move_kcal: 410, exercise_min: 34, stand_h: 11, outside_workouts: 1,
        outside_minutes: 45,
      },
      {
        day: '2026-09-20', steps: 6000, move_kcal: 300, exercise_min: 25, stand_h: 10, outside_workouts: 1,
        outside_minutes: 30,
      },
    ])
    expect(out.weeks).toEqual([
      {
        week_start: '2026-09-21', days_with_data: 2, steps: 12742, move_kcal: 620, exercise_min: 52,
        outside_workouts: 1, outside_minutes: 45,
      },
      {
        week_start: '2026-09-14', days_with_data: 1, steps: 6000, move_kcal: 300, exercise_min: 25,
        outside_workouts: 1, outside_minutes: 30,
      },
    ])
  })

  it('takes the last `days` days, in the time zone it is given', async () => {
    const today = json(await getActivity(await ctx(), { days: 1 }))
    expect(today.outside_workouts).toEqual([])
    expect(today.days_of_activity.map((d: { day: string }) => d.day)).toEqual(['2026-09-26'])

    const lateEvening = await ctx((d) => {
      d.activities = [outside('a6', 'walking', '2026-09-26T06:00:00.000000Z', 30)] // 23:00 on the 25th in Los Angeles
    })
    expect(json(await getActivity(lateEvening, { days: 1 })).outside_workouts).toHaveLength(1)
    expect(json(await getActivity(lateEvening, { days: 1, time_zone: 'America/Los_Angeles' })).outside_workouts)
      .toEqual([])
  })

  it('lists at most 60 and says how many there were', async () => {
    const many = await ctx((d) => {
      d.activities = Array.from({ length: 70 }, (_, i) =>
        outside(`m${i}`, 'walking', new Date(Date.UTC(2026, 8, 1) + i * 3 * 3_600_000).toISOString(), 60))
    })
    const out = json(await getActivity(many, {}))
    expect(out.outside_workouts).toHaveLength(60)
    expect(out.outside_workouts_total).toBe(70)
  })

  it('refuses while the owner keeps activity from agents, and for an unknown time zone', async () => {
    const off = await ctx((d) => {
      d.profile = { ...d.profile!, mcp_read_activity: false }
    })
    await expect(getActivity(off, {})).rejects.toThrow(notAllowed(['activity']))
    await expect(getActivity(await ctx(), { time_zone: 'Mars/Olympus' })).rejects.toThrow(ToolError)
  })
})
