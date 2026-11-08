// Small lookups shared by several tools.
import type { Db, ExercisePreference, ExerciseRow, WeightUnit } from '../db.ts'

/** The owner's display unit; lb when no profile has been saved (the app's default). */
export async function ownerUnit(db: Db): Promise<WeightUnit> {
  return (await db.profile())?.unit ?? 'lb'
}

/** id → exercise row, for library and custom exercises. */
export async function exerciseMap(db: Db, ids: Iterable<string>): Promise<Map<string, ExerciseRow>> {
  const unique = [...new Set(ids)]
  if (unique.length === 0) return new Map()
  const rows = await db.exercises(unique)
  return new Map(rows.map((r) => [r.id, r]))
}

/** exercise id → the owner's preference, 'normal' ones left out. */
export async function preferenceMap(db: Db, ids?: string[]): Promise<Map<string, ExercisePreference>> {
  return new Map((await db.exercisePreferences(ids)).map((p) => [p.exercise_id, p.pref]))
}

export const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'] as const
