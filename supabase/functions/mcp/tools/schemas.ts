// Zod (v4, Standard Schema) input schemas for the MCP tools. Types mirror the Swift `PlanChange` Codable model
// (Int fields are integers), so anything accepted here decodes in the app; value ranges and plan references are
// checked by the shared validator, not here.
import { z } from 'npm:zod@4.6.5'
import type { PlanChangeType } from '../../_shared/plan-validation.ts'

const ref = z.string().min(1).max(64)
const isoDate = z.string().min(10).max(40).describe('YYYY-MM-DD or an ISO 8601 timestamp')
const uuid = z.guid()

/** Required fields per change type — the validator's rules, written for Claude. */
export const CHANGE_FIELDS: Record<PlanChangeType, string> = {
  'add-exercise':
    'routineId, exerciseId (library id), sets 1–10, reps 1–100; optional repsMin, weightKg 0–500',
  'remove-exercise': 'routineId, exerciseId',
  'swap-exercise':
    'routineId, exerciseId (in the routine), toExerciseId (library id, not already in the routine); optional ' +
    "sets, reps, repsMin, sec, weightKg 0–500. The old exercise's weight is NOT carried over: give weightKg for " +
    'the new one, or it starts at 0',
  'sets': 'routineId, exerciseId, sets 1–10',
  'reps': 'routineId, exerciseId, reps 1–100 (top of the range); optional repsMin ≤ reps',
  'repsMin': 'routineId, exerciseId, repsMin 1–reps (bottom of the range)',
  'sec': 'routineId, exerciseId, sec 5–3600 (timed exercises)',
  'weight': 'routineId, exerciseId, weightKg 0–500 (the next planned working weight, in kg)',
  'cardio': 'routineId, exerciseId, minutes 1–300; optional speed 0–50',
  'reorder': 'routineId, exerciseId, position 0–19',
  'superset': 'routineId, exerciseId, withExerciseId (both in the routine)',
  'routine-prog': 'routineId, policy (off | linear | greyskull | double | time)',
  'exercise-prog': 'routineId, exerciseId, policy',
  'inc': 'routineId, exerciseId, incKg 0.1–20 (progression increment)',
  'add-routine': 'routineId (a new id you choose, usable by later changes), name 1–40; at most 7 routines',
  'remove-routine': 'routineId',
  'rename-routine': 'routineId, name 1–40',
  'pause-routine': 'routineId, paused (true/false)',
  'week':
    'weekday 1–7 (1 = Monday); routineId, or omit it for a rest day. Permanent: every such weekday from now on',
  'today':
    "routineId (existing and not paused, or added earlier in this proposal), date (YYYY-MM-DD, the owner's local " +
    'date, today up to 7 days ahead): the owner trains that routine on that date only, instead of the scheduled ' +
    'one; the weekly schedule is unchanged and the next day is back to normal',
}

const changeTypes = Object.keys(CHANGE_FIELDS) as [PlanChangeType, ...PlanChangeType[]]

export const planChangeSchema = z.object({
  id: ref.describe('Unique within this proposal, e.g. "c1"'),
  type: z.enum(changeTypes),
  routineId: ref.optional(),
  exerciseId: ref.optional(),
  toExerciseId: ref.optional(),
  withExerciseId: ref.optional(),
  sets: z.number().int().optional(),
  reps: z.number().int().optional(),
  repsMin: z.number().int().optional(),
  sec: z.number().int().optional(),
  weightKg: z.number().optional(),
  minutes: z.number().optional(),
  speed: z.number().optional(),
  incKg: z.number().optional(),
  policy: z.enum(['off', 'linear', 'greyskull', 'double', 'time']).optional(),
  position: z.number().int().optional(),
  name: z.string().max(100).optional(),
  weekday: z.number().int().optional(),
  paused: z.boolean().optional(),
  date: z.string().min(10).max(10).optional().describe("today only: YYYY-MM-DD, the owner's local date"),
  reason: z.string().max(300).optional().describe('Why — shown to the owner next to the change'),
})

export const schemas = {
  empty: z.object({}),
  listWorkouts: z.object({
    since: isoDate.optional().describe('Start date (inclusive). Default: 12 weeks ago'),
    until: isoDate.optional().describe('End date (inclusive for a plain date)'),
    limit: z.number().int().min(1).optional().describe('1–60, default 20'),
  }),
  byId: z.object({ id: uuid }),
  exerciseHistory: z.object({
    exercise: z.string().min(1).max(100).describe(
      'Exercise id (e.g. "0025") or name (e.g. "barbell bench press")',
    ),
    since: isoDate.optional(),
  }),
  trainingSummary: z.object({ weeks: z.number().int().min(1).optional().describe('1–12, default 4') }),
  bodyweight: z.object({ since: isoDate.optional().describe('Default: 12 weeks ago') }),
  insights: z.object({
    time_zone: z.string().min(1).max(64).optional().describe(
      'IANA time zone for the Monday–Sunday week, e.g. Europe/Warsaw. Default: UTC',
    ),
  }),
  strengthLevels: z.object({}),
  searchExercises: z.object({
    query: z.string().max(100).optional().describe('Words that must all appear in the name'),
    body_part: z.string().max(40).optional().describe(
      'e.g. chest, back, shoulders, upper legs, upper arms, waist',
    ),
    equipment: z.string().max(40).optional().describe(
      'e.g. barbell, dumbbell, cable, body weight, leverage machine',
    ),
    limit: z.number().int().min(1).optional().describe('1–25, default 10'),
  }),
  propose: z.object({
    summary: z.string().min(1).max(500).describe('One or two sentences the owner sees first'),
    changes: z.array(planChangeSchema).min(1).max(25),
  }),
  logBodyweight: z.object({
    weight_kg: z.number().min(30).max(300),
    date: isoDate.optional().describe('Default: now'),
    body_fat_pct: z.number().min(3).max(60).optional(),
  }),
}
