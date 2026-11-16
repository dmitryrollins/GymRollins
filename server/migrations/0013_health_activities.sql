
-- Plan 39 (docs/specs/2026-11-16-health-activities-design.md, section 5): Apple Health activities, read on the phone
-- and synced like the other tables (src/sync/entities.ts, health-activities and activity-days). The numbers are
-- DomainLimits' (ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift); test/domain-limits-drift.test.ts checks
-- each one here. Conventions as in 0002_app_schema.sql: text timestamps in the stored form, 0/1 booleans, no defaults
-- for ids or times.

-- Outside workouts: workouts other apps saved to Health. The id is the HealthKit workout's UUID, so two devices of one
-- account importing the same workout write the same row. The account is part of the key: one iPhone's Health can be
-- read into two accounts (signing out of one and into another), and neither may refuse the other's rows.
CREATE TABLE health_activities (
  id TEXT NOT NULL CHECK (length(id) = 36),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  kind TEXT NOT NULL CHECK (length(kind) BETWEEN 1 AND 100),
  started_at TEXT NOT NULL CHECK (substr(started_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(started_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(started_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  ended_at TEXT NOT NULL CHECK (substr(ended_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(ended_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(ended_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  duration_s REAL NOT NULL CHECK (duration_s BETWEEN 0 AND 86400),
  kcal REAL CHECK (kcal BETWEEN 0 AND 20000),
  distance_m REAL CHECK (distance_m BETWEEN 0 AND 1000000),
  avg_hr INTEGER CHECK (avg_hr BETWEEN 20 AND 250),
  max_hr INTEGER CHECK (max_hr BETWEEN 20 AND 250),
  avg_power_w INTEGER CHECK (avg_power_w BETWEEN 0 AND 2500),
  avg_cadence_rpm INTEGER CHECK (avg_cadence_rpm BETWEEN 0 AND 250),
  total_kcal REAL CHECK (total_kcal BETWEEN 0 AND 20000),
  source_name TEXT NOT NULL CHECK (length(source_name) BETWEEN 1 AND 100),
  from_watch INTEGER NOT NULL CHECK (from_watch IN (0,1)),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  deleted_at TEXT CHECK (substr(deleted_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(deleted_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(deleted_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  CHECK (ended_at >= started_at),
  PRIMARY KEY (user_id, id)
);
-- The pull's keyset order, and the MCP reads by start time (get_activity, get_training_insights).
CREATE INDEX health_activities_user_updated ON health_activities (user_id, updated_at, id);
CREATE INDEX health_activities_user_started ON health_activities (user_id, started_at);

-- Days of activity: one local calendar day's steps, move, exercise and stand (stand is null without an Apple Watch).
-- Never deleted: a day stays as it was last read.
CREATE TABLE activity_days (
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  day TEXT NOT NULL CHECK (day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  steps INTEGER NOT NULL CHECK (steps BETWEEN 0 AND 200000),
  move_kcal REAL NOT NULL CHECK (move_kcal BETWEEN 0 AND 20000),
  exercise_min INTEGER NOT NULL CHECK (exercise_min BETWEEN 0 AND 1440),
  stand_h INTEGER CHECK (stand_h BETWEEN 0 AND 24),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  PRIMARY KEY (user_id, day)
);
CREATE INDEX activity_days_user_updated ON activity_days (user_id, updated_at, day);

-- The storage caps, kept like plan 31's (0010_account_caps.sql) but in a table of their own: account_rows' tbl CHECK
-- lists the tables plan 31 capped, and SQLite can't change a CHECK without rebuilding that table and every trigger
-- that writes it. Deleted rows count; only an account's deletion removes these rows (ON DELETE CASCADE).
CREATE TABLE health_rows (
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  tbl TEXT NOT NULL CHECK (tbl IN ('health_activities','activity_days')),
  n INTEGER NOT NULL,
  PRIMARY KEY (user_id, tbl)
);
CREATE TRIGGER health_activities_cap BEFORE INSERT ON health_activities
  WHEN NOT EXISTS (SELECT 1 FROM health_activities WHERE user_id = NEW.user_id AND id = NEW.id)
    AND coalesce((SELECT n FROM health_rows WHERE user_id = NEW.user_id AND tbl = 'health_activities'), 0) >= 20000
BEGIN
  SELECT RAISE(ABORT, 'too_many_health_activities');
END;
CREATE TRIGGER health_activities_counted AFTER INSERT ON health_activities
BEGIN
  INSERT INTO health_rows (user_id, tbl, n) VALUES (NEW.user_id, 'health_activities', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER health_activities_uncounted AFTER DELETE ON health_activities
BEGIN
  UPDATE health_rows SET n = n - 1 WHERE user_id = OLD.user_id AND tbl = 'health_activities';
END;
CREATE TRIGGER activity_days_cap BEFORE INSERT ON activity_days
  WHEN NOT EXISTS (SELECT 1 FROM activity_days WHERE user_id = NEW.user_id AND day = NEW.day)
    AND coalesce((SELECT n FROM health_rows WHERE user_id = NEW.user_id AND tbl = 'activity_days'), 0) >= 5000
BEGIN
  SELECT RAISE(ABORT, 'too_many_activity_days');
END;
CREATE TRIGGER activity_days_counted AFTER INSERT ON activity_days
BEGIN
  INSERT INTO health_rows (user_id, tbl, n) VALUES (NEW.user_id, 'activity_days', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER activity_days_uncounted AFTER DELETE ON activity_days
BEGIN
  UPDATE health_rows SET n = n - 1 WHERE user_id = OLD.user_id AND tbl = 'activity_days';
END;

-- "Read activity from Apple Health" for agents (get_activity, the streak in get_training_insights): on by default,
-- synced with the profile like the other mcp_* switches. Rows already stored are valid as they are.
ALTER TABLE profiles ADD COLUMN mcp_read_activity INTEGER NOT NULL DEFAULT 1 CHECK (mcp_read_activity IN (0,1));
