-- Plan 40 (docs/specs/2026-11-16-native-design-stage-1-design.md, section 6.1): what Apple Health measured during a
-- GymRollins workout, one row per workout, read on the phone and synced like the other tables (src/sync/entities.ts,
-- workout-measurements). A table of its own, not columns on workouts: builds 1–4 push whole workouts without these
-- fields and would wipe them with every edit. Heart-rate readings stay in Apple Health. The numbers are GymCore's
-- MeasurementLimits (ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift); test/domain-limits-drift.test.ts
-- checks each one here. Conventions as in 0002_app_schema.sql.
--
-- workouts is keyed by its id alone (0002), so workout_id references it as workout_entries does, and the push checks
-- that the workout is the caller's (ownWorkouts in src/sync/entities.ts). D1 enforces foreign keys: deleting a
-- workout's row (the account's deletion) deletes its numbers, through workout_measurements_workout. The sync only
-- marks a workout deleted; its numbers then stay unread. Its row count is bounded by workouts', so no cap.
CREATE TABLE workout_measurements (
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  workout_id TEXT NOT NULL REFERENCES workouts(id) ON DELETE CASCADE CHECK (length(workout_id) = 36),
  recorded_by TEXT CHECK (recorded_by IN ('watch','apple_workout')),
  duration_s REAL CHECK (duration_s BETWEEN 0 AND 86400),
  active_kcal REAL CHECK (active_kcal BETWEEN 0 AND 20000),
  total_kcal REAL CHECK (total_kcal BETWEEN 0 AND 20000),
  avg_hr INTEGER CHECK (avg_hr BETWEEN 20 AND 250),
  max_hr INTEGER CHECK (max_hr BETWEEN 20 AND 250),
  post_hr INTEGER CHECK (post_hr BETWEEN 20 AND 250),
  effort INTEGER CHECK (effort BETWEEN 1 AND 10),
  effort_estimated INTEGER NOT NULL CHECK (effort_estimated IN (0,1)),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  deleted_at TEXT CHECK (substr(deleted_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(deleted_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(deleted_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  PRIMARY KEY (user_id, workout_id)
);
-- The pull's keyset order.
CREATE INDEX workout_measurements_user_updated ON workout_measurements (user_id, updated_at, workout_id);
-- A workout's deletion finds its row (the foreign key's ON DELETE CASCADE), as workout_entries_workout does.
CREATE INDEX workout_measurements_workout ON workout_measurements (workout_id);
