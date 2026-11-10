-- Plan 31: storage caps per account (docs/plans/2026-11-08-plan-31-account-caps.md). The numbers are DomainLimits'
-- (ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift); test/domain-limits-drift.test.ts checks each one here.

-- How many rows each account holds in the capped tables, deleted rows included. A deletion keeps its row as a
-- tombstone (deleted_at), so it still counts, and deleting frees nothing. The triggers below and the workout save
-- (src/sync/workouts.ts, for entries and sets) keep the counts, so a cap reads one row. A count(*) would read every row
-- the account ever had, for every pushed row: no live-rows index can serve it, and most of these tables have no index
-- on user_id (a count reads the whole table). gyms and gym_equipment count the account's private rows (owner_id).
CREATE TABLE account_rows (
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  tbl TEXT NOT NULL CHECK (tbl IN ('workouts','bodyweight','routines','custom_exercises','exercise_prefs','proposals',
    'gyms','gym_equipment','workout_entries','workout_sets')),
  n INTEGER NOT NULL,
  PRIMARY KEY (user_id, tbl)
);
INSERT INTO account_rows (user_id, tbl, n) SELECT user_id, 'workouts', count(*) FROM workouts GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n) SELECT user_id, 'bodyweight', count(*) FROM bodyweight GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n) SELECT user_id, 'routines', count(*) FROM routines GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n)
  SELECT user_id, 'custom_exercises', count(*) FROM custom_exercises GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n)
  SELECT user_id, 'exercise_prefs', count(*) FROM exercise_prefs GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n) SELECT user_id, 'proposals', count(*) FROM proposals GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n)
  SELECT owner_id, 'gyms', count(*) FROM gyms WHERE owner_id IS NOT NULL GROUP BY owner_id;
INSERT INTO account_rows (user_id, tbl, n)
  SELECT owner_id, 'gym_equipment', count(*) FROM gym_equipment WHERE owner_id IS NOT NULL GROUP BY owner_id;
INSERT INTO account_rows (user_id, tbl, n)
  SELECT user_id, 'workout_entries', count(*) FROM workout_entries GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n)
  SELECT user_id, 'workout_sets', count(*) FROM workout_sets GROUP BY user_id;

-- Per table: <table>_cap (gyms_total_cap, gym_equipment_total_cap) refuses a new row once the account holds the cap;
-- <table>_counted and <table>_uncounted keep the count.
-- - A row is new when its key isn't stored yet. SQLite runs BEFORE INSERT for an upsert's row that turns into an
--   update too, so the key check is what lets an edit, a deletion or a revival through at the cap. Proposals are only
--   ever inserted, so theirs has none.
-- - AFTER INSERT runs only for a row actually inserted, never for an upsert's update.
-- - RAISE fails the whole statement, and the whole batch around it (a workout save). The server answers 422 with the
--   message as the code (src/http/errors.ts); under Claude's writes it becomes words for Claude (src/mcp/d1-db.ts).
-- - Only an account's deletion removes these rows today, and the counts go with the account (ON DELETE CASCADE).
CREATE TRIGGER workouts_cap BEFORE INSERT ON workouts
  WHEN NOT EXISTS (SELECT 1 FROM workouts WHERE id = NEW.id)
    AND coalesce((SELECT n FROM account_rows WHERE user_id = NEW.user_id AND tbl = 'workouts'), 0) >= 10000
BEGIN
  SELECT RAISE(ABORT, 'too_many_workouts');
END;
CREATE TRIGGER workouts_counted AFTER INSERT ON workouts
BEGIN
  INSERT INTO account_rows (user_id, tbl, n) VALUES (NEW.user_id, 'workouts', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER workouts_uncounted AFTER DELETE ON workouts
BEGIN
  UPDATE account_rows SET n = n - 1 WHERE user_id = OLD.user_id AND tbl = 'workouts';
END;
CREATE TRIGGER bodyweight_cap BEFORE INSERT ON bodyweight
  WHEN NOT EXISTS (SELECT 1 FROM bodyweight WHERE id = NEW.id)
    AND coalesce((SELECT n FROM account_rows WHERE user_id = NEW.user_id AND tbl = 'bodyweight'), 0) >= 20000
BEGIN
  SELECT RAISE(ABORT, 'too_many_body_weights');
END;
CREATE TRIGGER bodyweight_counted AFTER INSERT ON bodyweight
BEGIN
  INSERT INTO account_rows (user_id, tbl, n) VALUES (NEW.user_id, 'bodyweight', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER bodyweight_uncounted AFTER DELETE ON bodyweight
BEGIN
  UPDATE account_rows SET n = n - 1 WHERE user_id = OLD.user_id AND tbl = 'bodyweight';
END;
CREATE TRIGGER routines_cap BEFORE INSERT ON routines
  WHEN NOT EXISTS (SELECT 1 FROM routines WHERE id = NEW.id)
    AND coalesce((SELECT n FROM account_rows WHERE user_id = NEW.user_id AND tbl = 'routines'), 0) >= 200
BEGIN
  SELECT RAISE(ABORT, 'too_many_routines');
END;
CREATE TRIGGER routines_counted AFTER INSERT ON routines
BEGIN
  INSERT INTO account_rows (user_id, tbl, n) VALUES (NEW.user_id, 'routines', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER routines_uncounted AFTER DELETE ON routines
BEGIN
  UPDATE account_rows SET n = n - 1 WHERE user_id = OLD.user_id AND tbl = 'routines';
END;
CREATE TRIGGER custom_exercises_cap BEFORE INSERT ON custom_exercises
  WHEN NOT EXISTS (SELECT 1 FROM custom_exercises WHERE id = NEW.id)
    AND coalesce((SELECT n FROM account_rows WHERE user_id = NEW.user_id AND tbl = 'custom_exercises'), 0) >= 1000
BEGIN
  SELECT RAISE(ABORT, 'too_many_custom_exercises');
END;
CREATE TRIGGER custom_exercises_counted AFTER INSERT ON custom_exercises
BEGIN
  INSERT INTO account_rows (user_id, tbl, n) VALUES (NEW.user_id, 'custom_exercises', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER custom_exercises_uncounted AFTER DELETE ON custom_exercises
BEGIN
  UPDATE account_rows SET n = n - 1 WHERE user_id = OLD.user_id AND tbl = 'custom_exercises';
END;
CREATE TRIGGER exercise_prefs_cap BEFORE INSERT ON exercise_prefs
  WHEN NOT EXISTS (SELECT 1 FROM exercise_prefs WHERE user_id = NEW.user_id AND exercise_id = NEW.exercise_id)
    AND coalesce((SELECT n FROM account_rows WHERE user_id = NEW.user_id AND tbl = 'exercise_prefs'), 0) >= 2000
BEGIN
  SELECT RAISE(ABORT, 'too_many_exercise_prefs');
END;
CREATE TRIGGER exercise_prefs_counted AFTER INSERT ON exercise_prefs
BEGIN
  INSERT INTO account_rows (user_id, tbl, n) VALUES (NEW.user_id, 'exercise_prefs', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER exercise_prefs_uncounted AFTER DELETE ON exercise_prefs
BEGIN
  UPDATE account_rows SET n = n - 1 WHERE user_id = OLD.user_id AND tbl = 'exercise_prefs';
END;
CREATE TRIGGER proposals_cap BEFORE INSERT ON proposals
  WHEN coalesce((SELECT n FROM account_rows WHERE user_id = NEW.user_id AND tbl = 'proposals'), 0) >= 5000
BEGIN
  SELECT RAISE(ABORT, 'too_many_proposals');
END;
CREATE TRIGGER proposals_counted AFTER INSERT ON proposals
BEGIN
  INSERT INTO account_rows (user_id, tbl, n) VALUES (NEW.user_id, 'proposals', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER proposals_uncounted AFTER DELETE ON proposals
BEGIN
  UPDATE account_rows SET n = n - 1 WHERE user_id = OLD.user_id AND tbl = 'proposals';
END;
CREATE TRIGGER gyms_total_cap BEFORE INSERT ON gyms
  WHEN NEW.owner_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM gyms WHERE id = NEW.id)
    AND coalesce((SELECT n FROM account_rows WHERE user_id = NEW.owner_id AND tbl = 'gyms'), 0) >= 500
BEGIN
  SELECT RAISE(ABORT, 'too_many_gyms_total');
END;
CREATE TRIGGER gyms_counted AFTER INSERT ON gyms
  WHEN NEW.owner_id IS NOT NULL
BEGIN
  INSERT INTO account_rows (user_id, tbl, n) VALUES (NEW.owner_id, 'gyms', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER gyms_uncounted AFTER DELETE ON gyms
  WHEN OLD.owner_id IS NOT NULL
BEGIN
  UPDATE account_rows SET n = n - 1 WHERE user_id = OLD.owner_id AND tbl = 'gyms';
END;
CREATE TRIGGER gym_equipment_total_cap BEFORE INSERT ON gym_equipment
  WHEN NEW.owner_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM gym_equipment WHERE id = NEW.id)
    AND coalesce((SELECT n FROM account_rows WHERE user_id = NEW.owner_id AND tbl = 'gym_equipment'), 0) >= 5000
BEGIN
  SELECT RAISE(ABORT, 'too_many_listings_total');
END;
CREATE TRIGGER gym_equipment_counted AFTER INSERT ON gym_equipment
  WHEN NEW.owner_id IS NOT NULL
BEGIN
  INSERT INTO account_rows (user_id, tbl, n) VALUES (NEW.owner_id, 'gym_equipment', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER gym_equipment_uncounted AFTER DELETE ON gym_equipment
  WHEN OLD.owner_id IS NOT NULL
BEGIN
  UPDATE account_rows SET n = n - 1 WHERE user_id = OLD.owner_id AND tbl = 'gym_equipment';
END;

-- Exercises and sets logged, deleted workouts included. A workout save deletes the workout's entries and sets and
-- writes the ones it carries, so it moves these two counts itself, once a save, by what it changes
-- (src/sync/workouts.ts, MOVE_ENTRIES and MOVE_SETS): row triggers here would write the count once per row deleted and
-- once per row written, on every save. These refuse a save that would take a count past its cap; a save that keeps or
-- lowers it always passes. The first count row an account gets is at most one workout's size, far under either cap.
CREATE TRIGGER account_rows_entries_cap BEFORE UPDATE OF n ON account_rows
  WHEN NEW.tbl = 'workout_entries' AND NEW.n > OLD.n AND NEW.n > 50000
BEGIN
  SELECT RAISE(ABORT, 'too_many_logged_exercises');
END;
CREATE TRIGGER account_rows_sets_cap BEFORE UPDATE OF n ON account_rows
  WHEN NEW.tbl = 'workout_sets' AND NEW.n > OLD.n AND NEW.n > 250000
BEGIN
  SELECT RAISE(ABORT, 'too_many_logged_sets');
END;

-- At most 100 proposals waiting for the owner (pending) per account, besides proposals_cap's 5,000 in all. Claude's
-- insert is the only writer (src/mcp/d1-db.ts, insertProposal), one row at a time, and a resolved proposal never turns
-- pending again (src/claude/proposals.ts refuses it), so a live count is enough: at most 100 rows, read through this
-- index, which the app's pull of pending proposals uses too.
CREATE INDEX proposals_user_pending ON proposals (user_id, created_at, id) WHERE status = 'pending';
CREATE TRIGGER proposals_pending_cap BEFORE INSERT ON proposals
  WHEN NEW.status = 'pending'
    AND (SELECT count(*) FROM proposals WHERE user_id = NEW.user_id AND status = 'pending') >= 100
BEGIN
  SELECT RAISE(ABORT, 'too_many_pending_proposals');
END;
