-- Plan 32 (docs/specs/2026-11-09-ai-agents-design.md, section 3.5): the connector serves any agent, not only Claude.
-- Each column is added with its default, so the rows already stored are valid as they are.

-- The "Add workouts" switch (log_workout), off until the owner turns it on. Synced with the profile like the other
-- mcp_* switches (src/sync/entities.ts).
ALTER TABLE profiles ADD COLUMN mcp_log_workouts INTEGER NOT NULL DEFAULT 0 CHECK (mcp_log_workouts IN (0,1));

-- The agent that added a workout with log_workout: its registered name, or 'Agent'. Null for every other workout.
-- The server sets it when the workout is added; a save from the app never changes it (src/sync/workouts.ts).
ALTER TABLE workouts ADD COLUMN added_by TEXT CHECK (added_by IS NULL OR length(added_by) BETWEEN 1 AND 64);

-- The agent that sent a proposal (its registered name, when it gave one). Null for proposals from before this.
ALTER TABLE proposals ADD COLUMN from_agent TEXT CHECK (from_agent IS NULL OR length(from_agent) BETWEEN 1 AND 64);
