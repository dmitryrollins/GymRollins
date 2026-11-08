-- GymRollins app schema for Cloudflare D1 (SQLite), translated from supabase/migrations/*.sql (the final state of
-- every table). Plan 26; design in docs/specs/2026-11-07-cloudflare-backend-design.md.
--
-- Conventions: ids are TEXT (36-char uuid); timestamps are TEXT 'YYYY-MM-DDTHH:MM:SS.ffffffZ' (UTC); dates are TEXT
-- 'YYYY-MM-DD'; booleans are INTEGER 0/1; jsonb / text[] / numeric[] are TEXT holding JSON. No now()/auth.uid()/
-- gen_random_uuid() defaults: the server supplies ids, user ids and timestamps. Regex and function checks that SQLite
-- cannot express are checked in TypeScript instead. Triggers, views and functions became server code (server/src).
-- The Better Auth table "user" (id TEXT PRIMARY KEY) is owned by Better Auth's own migration (0001).

-- Profiles ------------------------------------------------------------------------------------------------------
CREATE TABLE profiles (
  user_id TEXT NOT NULL PRIMARY KEY REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  unit TEXT NOT NULL DEFAULT 'lb' CHECK (unit IN ('kg','lb')),
  rest_sec INTEGER NOT NULL DEFAULT 120 CHECK (rest_sec BETWEEN 0 AND 900),
  warmup_rest_sec INTEGER NOT NULL DEFAULT 60 CHECK (warmup_rest_sec BETWEEN 0 AND 900),
  height_cm REAL CHECK (height_cm BETWEEN 100 AND 250),
  goal_weight_kg REAL CHECK (goal_weight_kg BETWEEN 30 AND 300),
  goal_date TEXT CHECK (goal_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  training_days INTEGER NOT NULL DEFAULT 4 CHECK (training_days BETWEEN 1 AND 7),
  experience TEXT NOT NULL DEFAULT 'intermediate',
  limits TEXT NOT NULL DEFAULT '' CHECK (length(limits) <= 500),
  deload_pct REAL NOT NULL DEFAULT 0.05 CHECK (deload_pct BETWEEN 0 AND 0.5),
  bar_kg REAL NOT NULL DEFAULT 20.411656,
  plates_kg TEXT NOT NULL DEFAULT '[20.411656,15.87573,11.339809,4.535924,2.267962,1.133981]'
    CHECK (json_valid(plates_kg) AND json_type(plates_kg) = 'array'),
  dumbbell_step_kg REAL NOT NULL DEFAULT 1.133981,
  mcp_read_workouts INTEGER NOT NULL DEFAULT 1 CHECK (mcp_read_workouts IN (0,1)),
  mcp_read_body INTEGER NOT NULL DEFAULT 1 CHECK (mcp_read_body IN (0,1)),
  mcp_propose INTEGER NOT NULL DEFAULT 1 CHECK (mcp_propose IN (0,1)),
  mcp_auto_apply INTEGER NOT NULL DEFAULT 0 CHECK (mcp_auto_apply IN (0,1)),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  mcp_read_plan INTEGER NOT NULL DEFAULT 1 CHECK (mcp_read_plan IN (0,1)),
  sex TEXT CHECK (sex IN ('male','female')),
  birth_year INTEGER CHECK (birth_year BETWEEN 1900 AND 2100),
  mcp_read_gyms INTEGER NOT NULL DEFAULT 1 CHECK (mcp_read_gyms IN (0,1)),
  limits_until TEXT CHECK (limits_until GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]')
);

-- Exercise library (global, read-only for users) ------------------------------------------------------------------
CREATE TABLE exercises (
  id TEXT PRIMARY KEY,
  n TEXT NOT NULL, bp TEXT NOT NULL, eq TEXT NOT NULL, tg TEXT NOT NULL,
  mg TEXT,
  sm TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(sm) AND json_type(sm) = 'array'),
  st TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(st) AND json_type(st) = 'array')
);

CREATE TABLE custom_exercises (
  id TEXT PRIMARY KEY CHECK (id GLOB 'custom-*'),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  n TEXT NOT NULL CHECK (length(n) BETWEEN 1 AND 80),
  bp TEXT NOT NULL, eq TEXT NOT NULL, tg TEXT NOT NULL,
  mode TEXT NOT NULL DEFAULT 'reps' CHECK (mode IN ('reps','time','cardio')),
  bilateral INTEGER NOT NULL DEFAULT 0 CHECK (bilateral IN (0,1)),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  deleted_at TEXT CHECK (substr(deleted_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(deleted_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(deleted_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);

-- Plan ----------------------------------------------------------------------------------------------------------
CREATE TABLE routines (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 40),
  emoji TEXT,
  policy TEXT NOT NULL DEFAULT 'double' CHECK (policy IN ('off','linear','greyskull','double','time')),
  position INTEGER NOT NULL DEFAULT 0,
  paused INTEGER NOT NULL DEFAULT 0 CHECK (paused IN (0,1)),
  exercises TEXT NOT NULL DEFAULT '[]'
    CHECK (json_valid(exercises) AND json_type(exercises) = 'array' AND json_array_length(exercises) <= 20),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  deleted_at TEXT CHECK (substr(deleted_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(deleted_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(deleted_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);

CREATE TABLE week_schedule (
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  weekday INTEGER NOT NULL CHECK (weekday BETWEEN 1 AND 7),
  routine_id TEXT REFERENCES routines(id) ON DELETE SET NULL CHECK (length(routine_id) = 36),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  PRIMARY KEY (user_id, weekday)
);

CREATE TABLE muscle_targets (
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  muscle TEXT NOT NULL CHECK (muscle IN (
    'chest','shoulders','traps','upper_back','lats','lower_back','biceps','triceps','forearms','abs',
    'glutes','quads','hamstrings','calves','adductors','abductors')),
  min_sets INTEGER NOT NULL CHECK (min_sets BETWEEN 0 AND 50),
  max_sets INTEGER NOT NULL CHECK (max_sets BETWEEN 0 AND 50),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  PRIMARY KEY (user_id, muscle),
  CONSTRAINT muscle_targets_range CHECK (min_sets <= max_sets)
);

CREATE TABLE exercise_prefs (
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  -- pg: exercise_id ~ '^[A-Za-z0-9_-]{1,80}$' (translated exactly with GLOB)
  exercise_id TEXT NOT NULL CHECK (length(exercise_id) BETWEEN 1 AND 80 AND exercise_id NOT GLOB '*[^A-Za-z0-9_-]*'),
  pref TEXT NOT NULL CHECK (pref IN ('more','normal','less','never')),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  PRIMARY KEY (user_id, exercise_id)
);
-- Pull cursor: rows changed since the last pull, keyset-ordered by (updated_at, exercise_id).
CREATE INDEX exercise_prefs_user_updated ON exercise_prefs (user_id, updated_at, exercise_id);

-- Curated catalogue + gyms (created before workouts, which link to gyms and listings) ------------------------------
CREATE TABLE equipment_kinds (
  -- pg: id ~ '^[a-z0-9-]{1,40}$' (translated exactly with GLOB)
  id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 1 AND 40 AND id NOT GLOB '*[^a-z0-9-]*'),
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 60),
  category TEXT NOT NULL CHECK (category IN ('machine','cable','free-weight','bench','rack','cardio','accessory')),
  load_type TEXT NOT NULL CHECK (load_type IN ('stack','plate-loaded','fixed-set','bodyweight','none')),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);

CREATE TABLE exercise_requirements (
  exercise_id TEXT PRIMARY KEY REFERENCES exercises(id) ON DELETE CASCADE,
  -- All groups are needed, any one kind per group; [] means no equipment.
  groups TEXT NOT NULL CHECK (json_valid(groups) AND json_type(groups) = 'array'),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);

CREATE TABLE app_admins (
  user_id TEXT NOT NULL PRIMARY KEY REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);

CREATE TABLE user_blocks (
  blocker_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(blocker_id) = 36),
  blocked_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(blocked_id) = 36),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  PRIMARY KEY (blocker_id, blocked_id)
);

CREATE TABLE gyms (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  visibility TEXT NOT NULL CHECK (visibility IN ('public','private')),
  owner_id TEXT REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(owner_id) = 36),
  -- clean_text(...): control characters are refused below; the invisible-character rules are checked in TypeScript
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 120 AND name NOT GLOB ('*[' || char(1) || '-' || char(31) || ']*')),
  address TEXT CHECK (address IS NULL OR (length(address) <= 300 AND address NOT GLOB ('*[' || char(1) || '-' || char(31) || ']*'))),
  latitude REAL CHECK (latitude IS NULL OR latitude BETWEEN -90 AND 90),
  longitude REAL CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180),
  -- pg: maps_place_id ~ '^[A-Za-z0-9._:+/=-]{1,200}$' (translated exactly with GLOB)
  maps_place_id TEXT CHECK (maps_place_id IS NULL
    OR (length(maps_place_id) BETWEEN 1 AND 200 AND maps_place_id NOT GLOB '*[^A-Za-z0-9._:+/=-]*')),
  created_by TEXT REFERENCES "user"(id) ON DELETE SET NULL CHECK (length(created_by) = 36),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','flagged','removed')),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  deleted_at TEXT CHECK (substr(deleted_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(deleted_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(deleted_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  CONSTRAINT gyms_private_has_owner CHECK ((visibility = 'private') = (owner_id IS NOT NULL)),
  CONSTRAINT gyms_public_is_a_place CHECK ((visibility = 'public') = (maps_place_id IS NOT NULL))
);
-- A removed gym gives its place back, so one bad gym can't block a real place forever.
CREATE UNIQUE INDEX gyms_maps_place ON gyms (maps_place_id) WHERE visibility = 'public' AND status <> 'removed';
CREATE INDEX gyms_owner_updated ON gyms (owner_id, updated_at, id) WHERE owner_id IS NOT NULL;
CREATE INDEX gyms_created_by ON gyms (created_by, created_at) WHERE created_by IS NOT NULL;

CREATE TABLE equipment_items (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  kind_id TEXT NOT NULL REFERENCES equipment_kinds(id),
  brand TEXT CHECK (brand IS NULL OR (length(brand) BETWEEN 1 AND 60 AND brand NOT GLOB ('*[' || char(1) || '-' || char(31) || ']*'))),
  model TEXT CHECK (model IS NULL OR (length(model) BETWEEN 1 AND 80 AND model NOT GLOB ('*[' || char(1) || '-' || char(31) || ']*'))),
  created_by TEXT REFERENCES "user"(id) ON DELETE SET NULL CHECK (length(created_by) = 36),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','flagged','removed')),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);
CREATE UNIQUE INDEX equipment_items_identity
  ON equipment_items (kind_id, lower(coalesce(brand, '')), lower(coalesce(model, '')));
CREATE INDEX equipment_items_created_by ON equipment_items (created_by) WHERE created_by IS NOT NULL;

CREATE TABLE gym_equipment (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  gym_id TEXT NOT NULL REFERENCES gyms(id) ON DELETE CASCADE CHECK (length(gym_id) = 36),
  item_id TEXT NOT NULL REFERENCES equipment_items(id) CHECK (length(item_id) = 36),
  visibility TEXT NOT NULL CHECK (visibility IN ('public','private')),
  owner_id TEXT REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(owner_id) = 36),
  -- A bare random name: a folder per user would give every reader the uploader's id.
  -- pg: photo_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$' (exact, as GLOB)
  photo_path TEXT CHECK (photo_path IS NULL OR length(photo_path) = 36+4 AND substr(photo_path,1,8) GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]' AND substr(photo_path,10,4) GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f]' AND substr(photo_path,15,4) GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f]' AND substr(photo_path,20,4) GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f]' AND substr(photo_path,25,6) GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]' AND substr(photo_path,31,6) GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]' AND substr(photo_path,9,1)||substr(photo_path,14,1)||substr(photo_path,19,1)||substr(photo_path,24,1)||substr(photo_path,37) = '----.jpg'),
  -- pg: gym_private.valid_loads(loads). Only the structural part is kept: an object, a known type, compact JSON.
  -- Keys, number ranges and the 24-char number form are validated in TypeScript.
  loads TEXT NOT NULL DEFAULT '{"type":"none"}'
    CHECK (json_valid(loads) AND json_type(loads) = 'object' AND length(loads) <= 2048
           AND json_extract(loads, '$.type') IN ('none','plates','stack','fixed')),
  quantity INTEGER NOT NULL DEFAULT 1 CHECK (quantity BETWEEN 1 AND 50),
  notes TEXT CHECK (notes IS NULL OR (length(notes) <= 280 AND notes NOT GLOB ('*[' || char(1) || '-' || char(9) || char(11) || char(12) || char(14) || '-' || char(31) || ']*'))),
  -- A private listing points at its kind's generic item and keeps any brand and model here, so private text never
  -- enters the shared catalogue.
  private_brand TEXT CHECK (private_brand IS NULL OR (length(private_brand) BETWEEN 1 AND 60 AND private_brand NOT GLOB ('*[' || char(1) || '-' || char(31) || ']*'))),
  private_model TEXT CHECK (private_model IS NULL OR (length(private_model) BETWEEN 1 AND 80 AND private_model NOT GLOB ('*[' || char(1) || '-' || char(31) || ']*'))),
  added_by TEXT REFERENCES "user"(id) ON DELETE SET NULL CHECK (length(added_by) = 36),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','flagged','removed')),
  confirm_count INTEGER NOT NULL DEFAULT 0,
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  deleted_at TEXT CHECK (substr(deleted_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(deleted_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(deleted_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  CONSTRAINT gym_equipment_private_has_owner CHECK ((visibility = 'private') = (owner_id IS NOT NULL)),
  CONSTRAINT gym_equipment_private_text
    CHECK (visibility = 'private' OR (private_brand IS NULL AND private_model IS NULL))
);
CREATE INDEX gym_equipment_gym ON gym_equipment (gym_id, status);
-- One photo backs one listing, so a name can't be shared by two.
CREATE UNIQUE INDEX gym_equipment_photo ON gym_equipment (photo_path) WHERE photo_path IS NOT NULL;
CREATE INDEX gym_equipment_item ON gym_equipment (item_id);
CREATE INDEX gym_equipment_owner_updated ON gym_equipment (owner_id, updated_at, id) WHERE owner_id IS NOT NULL;
CREATE INDEX gym_equipment_added_by ON gym_equipment (added_by, created_at) WHERE added_by IS NOT NULL;

CREATE TABLE equipment_confirmations (
  listing_id TEXT NOT NULL REFERENCES gym_equipment(id) ON DELETE CASCADE CHECK (length(listing_id) = 36),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  PRIMARY KEY (listing_id, user_id)
);
CREATE INDEX equipment_confirmations_user ON equipment_confirmations (user_id, created_at);

CREATE TABLE reports (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  target_type TEXT NOT NULL CHECK (target_type IN ('gym','item','listing')),
  target_id TEXT NOT NULL CHECK (length(target_id) = 36),
  -- A report outlives its reporter, so deleting three throwaway accounts can't clear a flag's history.
  reporter_id TEXT REFERENCES "user"(id) ON DELETE SET NULL CHECK (length(reporter_id) = 36),
  reason TEXT NOT NULL CHECK (reason IN ('wrong-info','not-here-anymore','duplicate','inappropriate-photo',
                                         'person-in-photo','spam','other')),
  note TEXT CHECK (note IS NULL OR (length(note) <= 280 AND note NOT GLOB ('*[' || char(1) || '-' || char(9) || char(11) || char(12) || char(14) || '-' || char(31) || ']*'))),
  resolved_at TEXT CHECK (substr(resolved_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(resolved_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(resolved_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  UNIQUE (target_type, target_id, reporter_id)
);

-- gym_private.unblocks in Postgres. Logs each "unblock all" so it can be rate limited (3 a day).
CREATE TABLE gym_unblocks (
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);
CREATE INDEX gym_unblocks_user ON gym_unblocks (user_id, created_at);

-- Workouts (relational children for SQL history queries) ---------------------------------------------------------
CREATE TABLE workouts (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  started_at TEXT NOT NULL CHECK (substr(started_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(started_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(started_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  ended_at TEXT CHECK (substr(ended_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(ended_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(ended_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  paused_sec REAL NOT NULL DEFAULT 0 CHECK (paused_sec >= 0),
  routine_id TEXT CHECK (length(routine_id) = 36),
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
  source TEXT NOT NULL DEFAULT 'app' CHECK (source IN ('app','import')),
  note TEXT,
  vol_kg REAL NOT NULL DEFAULT 0,
  records TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(records)),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  deleted_at TEXT CHECK (substr(deleted_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(deleted_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(deleted_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  gym_id TEXT REFERENCES gyms(id) ON DELETE SET NULL CHECK (length(gym_id) = 36),
  -- Set by each save (server/src/sync/workouts.ts): the save writes its entries and sets only while the row is still
  -- its own, so two phones saving at once can't mix their entries. Never sent to the app.
  write_id TEXT,
  CONSTRAINT workouts_vol_kg_nonnegative CHECK (vol_kg >= 0)
);
CREATE INDEX workouts_user_started ON workouts (user_id, started_at DESC);
CREATE INDEX workouts_gym ON workouts (gym_id) WHERE gym_id IS NOT NULL;

CREATE TABLE workout_entries (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  workout_id TEXT NOT NULL REFERENCES workouts(id) ON DELETE CASCADE CHECK (length(workout_id) = 36),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  exercise_id TEXT NOT NULL,
  position INTEGER NOT NULL,
  note TEXT,
  superset_group TEXT,
  gym_equipment_id TEXT REFERENCES gym_equipment(id) ON DELETE SET NULL CHECK (length(gym_equipment_id) = 36)
);
CREATE INDEX workout_entries_user_exercise ON workout_entries (user_id, exercise_id);

CREATE TABLE workout_sets (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  entry_id TEXT NOT NULL REFERENCES workout_entries(id) ON DELETE CASCADE CHECK (length(entry_id) = 36),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  position INTEGER NOT NULL,
  w_kg REAL NOT NULL CHECK (w_kg BETWEEN 0 AND 1000),
  r INTEGER NOT NULL CHECK (r BETWEEN 0 AND 1000),
  sec INTEGER CHECK (sec BETWEEN 0 AND 86400),
  min REAL, dist_m REAL,
  done INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0,1)),
  warmup INTEGER NOT NULL DEFAULT 0 CHECK (warmup IN (0,1)),
  rir REAL, rpe REAL,
  multiplier REAL NOT NULL DEFAULT 1 CHECK (multiplier BETWEEN 0 AND 10),
  completed_at TEXT CHECK (substr(completed_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(completed_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(completed_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  CONSTRAINT workout_sets_min_range CHECK (min BETWEEN 0 AND 1440),
  CONSTRAINT workout_sets_dist_m_range CHECK (dist_m BETWEEN 0 AND 1000000)
);

-- Body ----------------------------------------------------------------------------------------------------------
CREATE TABLE bodyweight (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  measured_at TEXT NOT NULL CHECK (substr(measured_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(measured_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(measured_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  w_kg REAL NOT NULL CHECK (w_kg BETWEEN 30 AND 300),
  bf_pct REAL CHECK (bf_pct BETWEEN 3 AND 60),
  t TEXT,
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  deleted_at TEXT CHECK (substr(deleted_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(deleted_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(deleted_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  source TEXT CHECK (source IS NULL OR source IN ('apple_health')),
  health_sample_id TEXT CHECK (length(health_sample_id) = 36),
  health_fat_sample_id TEXT CHECK (length(health_fat_sample_id) = 36)
);

-- Proposals from Claude -------------------------------------------------------------------------------------------
CREATE TABLE proposals (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  source TEXT NOT NULL DEFAULT 'claude',
  summary TEXT NOT NULL CHECK (length(summary) BETWEEN 1 AND 500),
  changes TEXT NOT NULL
    CHECK (json_valid(changes) AND json_type(changes) = 'array' AND json_array_length(changes) BETWEEN 1 AND 25),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','applied','dismissed','partial')),
  applied_change_ids TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(applied_change_ids)),
  resolved_at TEXT CHECK (substr(resolved_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(resolved_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(resolved_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);

-- MCP audit + rate limit ------------------------------------------------------------------------------------------
CREATE TABLE mcp_audit (
  id INTEGER PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  client_id TEXT,
  tool TEXT NOT NULL,
  ok INTEGER NOT NULL CHECK (ok IN (0,1)),
  args_digest TEXT,
  at TEXT NOT NULL CHECK (substr(at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);
CREATE INDEX mcp_audit_user_at ON mcp_audit (user_id, at DESC);

CREATE TABLE mcp_calls (
  id INTEGER PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  at TEXT NOT NULL CHECK (substr(at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z')
);
CREATE INDEX mcp_calls_user_at ON mcp_calls (user_id, at DESC);

-- R2 object ownership (replaces storage.objects.owner_id for the gym photo buckets) ---------------------------------
CREATE TABLE photo_objects (
  bucket TEXT NOT NULL CHECK (bucket IN ('gym-photos','gym-photos-private')),
  name TEXT NOT NULL,
  owner_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(owner_id) = 36),
  created_at TEXT NOT NULL CHECK (substr(created_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(created_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(created_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  PRIMARY KEY (bucket, name)
);
CREATE INDEX photo_objects_owner_created ON photo_objects (owner_id, created_at);
