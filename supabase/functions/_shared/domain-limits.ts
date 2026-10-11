// TypeScript port of ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift.
//
// Value limits shared with the Swift app and the database CHECK constraints
// (supabase/migrations/*_schema.sql, *_security_fixes.sql). Anything saved must fit these, or the row would be
// rejected when it syncs. Keep in sync with the Swift source by hand — nothing here is generated.
export const DomainLimits = {
  // Routines
  routineNameMax: 40,
  routineExercisesMax: 20,
  // Custom exercises and workouts
  customExerciseNameMax: 80,
  workoutNameMax: 80,
  // Workout sets
  setWeightKg: { min: 0, max: 1_000 },
  setReps: { min: 0, max: 1_000 },
  setSeconds: { min: 0, max: 86_400 },
  setMinutes: { min: 0, max: 1_440 },
  setDistanceM: { min: 0, max: 1_000_000 },
  // Body
  bodyweightKg: { min: 30, max: 300 },
  bodyFatPct: { min: 3, max: 60 },
  // Profile
  restSec: { min: 0, max: 900 },
  heightCm: { min: 100, max: 250 },
  goalWeightKg: { min: 30, max: 300 },
  trainingDays: { min: 1, max: 7 },
  limitsTextMax: 500,
  deloadPct: { min: 0, max: 0.5 },
  // Optional, for strength levels only (profiles.birth_year)
  birthYear: { min: 1900, max: 2100 },
  // Weekly hard-set targets per muscle group (muscle_targets.min_sets / max_sets)
  weeklySetTarget: { min: 0, max: 50 },
} as const
