// What a tool says when the owner turned a switch off (owner, 2026-11-09): an agent is told which switch is off and
// that this isn't an empty result, instead of getting no rows and taking the history for empty.
import { describe, expect, it } from 'vitest'
import { getTrainingInsights } from '../../../src/mcp/tools/insights.ts'
import { listGyms } from '../../../src/mcp/tools/gyms.ts'
import {
  getBodyweight,
  getExerciseHistory,
  getPlan,
  getProfile,
  getTrainingSummary,
  getWorkout,
  listWorkouts,
  searchExercises,
} from '../../../src/mcp/tools/read.ts'
import { notAllowed, withheld } from '../../../src/mcp/tools/permissions.ts'
import type { ToolResult } from '../../../src/mcp/tools/result.ts'
import { getStrengthLevels } from '../../../src/mcp/tools/strength.ts'
import { FakeDb, loadOwnerData } from '../fake-db.ts'

const NOW = new Date('2026-09-26T12:00:00Z')
type Switch = 'mcp_read_workouts' | 'mcp_read_body' | 'mcp_read_plan' | 'mcp_read_gyms'

async function ctx(...off: Switch[]) {
  const data = await loadOwnerData()
  data.profile = { ...data.profile!, ...Object.fromEntries(off.map((s) => [s, false])) }
  return { db: new FakeDb(data), now: NOW }
}

const json = (r: ToolResult) => {
  expect(r.isError).toBeFalsy()
  return JSON.parse(r.content[0]!.text)
}

describe('the words', () => {
  it('name each switch as the app does, and say this is not an empty result', () => {
    expect(notAllowed(['workouts'])).toBe(
      'Not allowed: the owner has turned off “Read workouts and sets” for agents in the GymRollins app ' +
        '(Settings › AI agents), so nothing was read. This is not an empty result: tell the owner, who can turn ' +
        'it on.',
    )
    expect(notAllowed(['workouts', 'plan'])).toContain(
      '“Read workouts and sets” and “Read your plan and profile”',
    )
    expect(notAllowed(['workouts', 'body', 'plan'])).toContain(
      '“Read workouts and sets”, “Read bodyweight” and “Read your plan and profile”',
    )
    expect(withheld(['body'], 'Bodyweight')).toBe(
      'Bodyweight withheld: the owner has turned off “Read bodyweight” for agents in the GymRollins app ' +
        '(Settings › AI agents).',
    )
  })
})

describe('a tool whose switch is off', () => {
  it('refuses instead of answering with nothing', async () => {
    const workoutsOff = await ctx('mcp_read_workouts')
    await expect(listWorkouts(workoutsOff, {})).rejects.toThrow(notAllowed(['workouts']))
    await expect(getWorkout(workoutsOff, { id: '00000000-0000-4000-8000-000000000000' })).rejects.toThrow(
      notAllowed(['workouts']),
    )
    await expect(getExerciseHistory(workoutsOff, { exercise: 'bench press' })).rejects.toThrow(
      notAllowed(['workouts']),
    )
    await expect(getTrainingSummary(workoutsOff, {})).rejects.toThrow(notAllowed(['workouts']))
    await expect(getBodyweight(await ctx('mcp_read_body'), {})).rejects.toThrow(notAllowed(['body']))
    await expect(getPlan(await ctx('mcp_read_plan'))).rejects.toThrow(notAllowed(['plan']))
    await expect(listGyms(await ctx('mcp_read_gyms'))).rejects.toThrow(notAllowed(['gyms']))
  })

  it('names every switch a combined tool needs that is off', async () => {
    await expect(getTrainingInsights(await ctx('mcp_read_workouts', 'mcp_read_plan'), {})).rejects.toThrow(
      notAllowed(['workouts', 'plan']),
    )
    await expect(getStrengthLevels(await ctx('mcp_read_body'), {})).rejects.toThrow(notAllowed(['body']))
  })
})

describe('a tool that still answers in part', () => {
  it("get_profile gives the permissions and says the profile is withheld, not that it isn't saved", async () => {
    const out = json(await getProfile(await ctx('mcp_read_plan', 'mcp_read_body')))
    expect(out).toEqual({
      profile: withheld(['plan'], 'The profile'),
      permissions: { read_plan: false, read_workouts: true, read_body: false, read_gyms: true, auto_apply: false },
    })
  })

  it('get_profile with the profile withheld still says whether changes apply without a review', async () => {
    const data = await loadOwnerData()
    data.profile = { ...data.profile!, mcp_read_plan: false, mcp_auto_apply: true }
    expect(json(await getProfile({ db: new FakeDb(data), now: NOW })).permissions.auto_apply).toBe(true)
  })

  it('get_training_summary gives the workouts and says the bodyweight is withheld', async () => {
    const out = json(await getTrainingSummary(await ctx('mcp_read_body'), {}))
    expect(out.weekly.length).toBeGreaterThan(0)
    expect(out.bodyweight).toBeNull()
    expect(out.withheld).toEqual([withheld(['body'], 'Bodyweight')])
  })

  it("search_exercises gives the library and says the owner's custom exercises are withheld", async () => {
    const out = json(await searchExercises(await ctx('mcp_read_plan'), { query: 'bench' }))
    expect(out.results.length).toBeGreaterThan(0)
    expect(out.withheld).toEqual([withheld(['plan'], "The owner's custom exercises")])
    expect(json(await searchExercises(await ctx(), { query: 'bench' })).withheld).toBeUndefined()
  })
})
