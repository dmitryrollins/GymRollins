-- Drift guard (item 16), DB leg: the Swift/TS domain limits (DomainLimits.swift <-> _shared/domain-limits.ts,
-- checked for drift by supabase/functions/_shared/domain-limits-drift.test.ts) are only meaningful if the
-- database CHECK constraints actually enforce the same numbers — nothing else proves that. This reads each
-- constraint's real definition back out of pg_constraint (via pg_get_constraintdef), so a migration that
-- silently loosens/tightens a range is caught here even though it wouldn't touch either Swift or TS file.
--
-- Bounds render as `(col >= 1)` for ints and `(col >= (30)::numeric)` for numerics; the patterns accept both.
begin;
create extension if not exists pgtap with schema extensions;
select plan(35);

-- Text of every CHECK constraint on `rel` that references `col` (there is at most one per column in this
-- schema's tables). Matching on pg_constraint/pg_attribute rather than a hard-coded constraint name, since most
-- of these are unnamed (Postgres auto-names them `<table>_<column>_check`) and one pair is explicitly named.
create or replace function pg_temp.check_def(rel regclass, col text) returns text
language sql stable as $$
  select string_agg(pg_get_constraintdef(c.oid), ' ; ' order by c.oid)
  from pg_constraint c
  join pg_attribute a on a.attrelid = c.conrelid and a.attname = col
  where c.conrelid = rel and c.contype = 'c' and a.attnum = any(c.conkey)
$$;

-- profiles.rest_sec / warmup_rest_sec — DomainLimits.restSec (0...900) --------------------------------------------
select matches(pg_temp.check_def('public.profiles', 'rest_sec'), '>=\s*\(?0\)?(::numeric)?\)',
  'profiles.rest_sec lower bound is 0 (DomainLimits.restSec.min)');
select matches(pg_temp.check_def('public.profiles', 'rest_sec'), '<=\s*\(?900\)?(::numeric)?\)',
  'profiles.rest_sec upper bound is 900 (DomainLimits.restSec.max)');
select matches(pg_temp.check_def('public.profiles', 'warmup_rest_sec'), '>=\s*\(?0\)?(::numeric)?\)',
  'profiles.warmup_rest_sec lower bound is 0 (DomainLimits.restSec.min)');
select matches(pg_temp.check_def('public.profiles', 'warmup_rest_sec'), '<=\s*\(?900\)?(::numeric)?\)',
  'profiles.warmup_rest_sec upper bound is 900 (DomainLimits.restSec.max)');

-- profiles.training_days — DomainLimits.trainingDays (1...7) -------------------------------------------------------
select matches(pg_temp.check_def('public.profiles', 'training_days'), '>=\s*\(?1\)?(::numeric)?\)',
  'profiles.training_days lower bound is 1 (DomainLimits.trainingDays.min)');
select matches(pg_temp.check_def('public.profiles', 'training_days'), '<=\s*\(?7\)?(::numeric)?\)',
  'profiles.training_days upper bound is 7 (DomainLimits.trainingDays.max)');

-- profiles.height_cm — DomainLimits.heightCm (100...250) -----------------------------------------------------------
select matches(pg_temp.check_def('public.profiles', 'height_cm'), '>=\s*\(?100\)?(::numeric)?\)',
  'profiles.height_cm lower bound is 100 (DomainLimits.heightCm.min)');
select matches(pg_temp.check_def('public.profiles', 'height_cm'), '<=\s*\(?250\)?(::numeric)?\)',
  'profiles.height_cm upper bound is 250 (DomainLimits.heightCm.max)');

-- profiles.goal_weight_kg — DomainLimits.goalWeightKg (30...300) ---------------------------------------------------
select matches(pg_temp.check_def('public.profiles', 'goal_weight_kg'), '>=\s*\(?30\)?(::numeric)?\)',
  'profiles.goal_weight_kg lower bound is 30 (DomainLimits.goalWeightKg.min)');
select matches(pg_temp.check_def('public.profiles', 'goal_weight_kg'), '<=\s*\(?300\)?(::numeric)?\)',
  'profiles.goal_weight_kg upper bound is 300 (DomainLimits.goalWeightKg.max)');

-- profiles.deload_pct — DomainLimits.deloadPct (0...0.5) -----------------------------------------------------------
select matches(pg_temp.check_def('public.profiles', 'deload_pct'), '>=\s*\(?0\)?(::numeric)?\)',
  'profiles.deload_pct lower bound is 0 (DomainLimits.deloadPct.min)');
select matches(pg_temp.check_def('public.profiles', 'deload_pct'), '<=\s*\(?0\.5\)?(::numeric)?\)',
  'profiles.deload_pct upper bound is 0.5 (DomainLimits.deloadPct.max)');

-- profiles.limits — DomainLimits.limitsTextMax (500) ---------------------------------------------------------------
select matches(pg_temp.check_def('public.profiles', 'limits'), '<=\s*\(?500\)?(::numeric)?\)',
  'profiles.limits upper bound is 500 characters (DomainLimits.limitsTextMax)');

-- routines.name — DomainLimits.routineNameMax (40) -------------------------------------------------------------
select matches(pg_temp.check_def('public.routines', 'name'), '<=\s*\(?40\)?(::numeric)?\)',
  'routines.name upper bound is 40 characters (DomainLimits.routineNameMax)');

-- routines.exercises — DomainLimits.routineExercisesMax (20) --------------------------------------------------------
select matches(pg_temp.check_def('public.routines', 'exercises'), '<=\s*\(?20\)?(::numeric)?\)',
  'routines.exercises upper bound is 20 entries (DomainLimits.routineExercisesMax)');

-- custom_exercises.n — DomainLimits.customExerciseNameMax (80) ------------------------------------------------------
select matches(pg_temp.check_def('public.custom_exercises', 'n'), '<=\s*\(?80\)?(::numeric)?\)',
  'custom_exercises.n upper bound is 80 characters (DomainLimits.customExerciseNameMax)');

-- workouts.name — DomainLimits.workoutNameMax (80) -------------------------------------------------------------
select matches(pg_temp.check_def('public.workouts', 'name'), '<=\s*\(?80\)?(::numeric)?\)',
  'workouts.name upper bound is 80 characters (DomainLimits.workoutNameMax)');

-- workout_sets.w_kg — DomainLimits.setWeightKg (0...1000) -----------------------------------------------------------
select matches(pg_temp.check_def('public.workout_sets', 'w_kg'), '>=\s*\(?0\)?(::numeric)?\)',
  'workout_sets.w_kg lower bound is 0 (DomainLimits.setWeightKg.min)');
select matches(pg_temp.check_def('public.workout_sets', 'w_kg'), '<=\s*\(?1000\)?(::numeric)?\)',
  'workout_sets.w_kg upper bound is 1000 (DomainLimits.setWeightKg.max)');

-- workout_sets.r — DomainLimits.setReps (0...1000) -------------------------------------------------------------
select matches(pg_temp.check_def('public.workout_sets', 'r'), '>=\s*\(?0\)?(::numeric)?\)',
  'workout_sets.r lower bound is 0 (DomainLimits.setReps.min)');
select matches(pg_temp.check_def('public.workout_sets', 'r'), '<=\s*\(?1000\)?(::numeric)?\)',
  'workout_sets.r upper bound is 1000 (DomainLimits.setReps.max)');

-- workout_sets.sec — DomainLimits.setSeconds (0...86400) -------------------------------------------------------
select matches(pg_temp.check_def('public.workout_sets', 'sec'), '>=\s*\(?0\)?(::numeric)?\)',
  'workout_sets.sec lower bound is 0 (DomainLimits.setSeconds.min)');
select matches(pg_temp.check_def('public.workout_sets', 'sec'), '<=\s*\(?86400\)?(::numeric)?\)',
  'workout_sets.sec upper bound is 86400 (DomainLimits.setSeconds.max)');

-- workout_sets.min — DomainLimits.setMinutes (0...1440) -----------------------------------------------------------
select matches(pg_temp.check_def('public.workout_sets', 'min'), '>=\s*\(?0\)?(::numeric)?\)',
  'workout_sets.min lower bound is 0 (DomainLimits.setMinutes.min)');
select matches(pg_temp.check_def('public.workout_sets', 'min'), '<=\s*\(?1440\)?(::numeric)?\)',
  'workout_sets.min upper bound is 1440 (DomainLimits.setMinutes.max)');

-- workout_sets.dist_m — DomainLimits.setDistanceM (0...1000000) -----------------------------------------------------
select matches(pg_temp.check_def('public.workout_sets', 'dist_m'), '>=\s*\(?0\)?(::numeric)?\)',
  'workout_sets.dist_m lower bound is 0 (DomainLimits.setDistanceM.min)');
select matches(pg_temp.check_def('public.workout_sets', 'dist_m'), '<=\s*\(?1000000\)?(::numeric)?\)',
  'workout_sets.dist_m upper bound is 1000000 (DomainLimits.setDistanceM.max)');

-- bodyweight.w_kg — DomainLimits.bodyweightKg (30...300) -----------------------------------------------------------
select matches(pg_temp.check_def('public.bodyweight', 'w_kg'), '>=\s*\(?30\)?(::numeric)?\)',
  'bodyweight.w_kg lower bound is 30 (DomainLimits.bodyweightKg.min)');
select matches(pg_temp.check_def('public.bodyweight', 'w_kg'), '<=\s*\(?300\)?(::numeric)?\)',
  'bodyweight.w_kg upper bound is 300 (DomainLimits.bodyweightKg.max)');

-- bodyweight.bf_pct — DomainLimits.bodyFatPct (3...60) -------------------------------------------------------------
select matches(pg_temp.check_def('public.bodyweight', 'bf_pct'), '>=\s*\(?3\)?(::numeric)?\)',
  'bodyweight.bf_pct lower bound is 3 (DomainLimits.bodyFatPct.min)');
select matches(pg_temp.check_def('public.bodyweight', 'bf_pct'), '<=\s*\(?60\)?(::numeric)?\)',
  'bodyweight.bf_pct upper bound is 60 (DomainLimits.bodyFatPct.max)');

-- profiles.birth_year — DomainLimits.birthYear (1900...2100) ---------------------------------------------------------
select matches(pg_temp.check_def('public.profiles', 'birth_year'), '>=\s*\(?1900\)?(::numeric)?\)',
  'profiles.birth_year lower bound is 1900 (DomainLimits.birthYear.min)');
select matches(pg_temp.check_def('public.profiles', 'birth_year'), '<=\s*\(?2100\)?(::numeric)?\)',
  'profiles.birth_year upper bound is 2100 (DomainLimits.birthYear.max)');
select matches(pg_temp.check_def('public.profiles', 'sex'), 'male.*female',
  'profiles.sex allows male and female only');
select col_is_null('public', 'profiles', 'sex', 'profiles.sex is optional');

select * from finish();
rollback;
