-- Plan 38: a set keeps the pound number it was entered or chosen as, next to its kilograms (w_kg stays the number
-- used for maths). Null when nobody gave a pound number: kg entries, imports and rows from before this. The range is
-- 1,000 kg in pounds, rounded up. Routine exercises and plan changes are JSON, so they need no column.
ALTER TABLE workout_sets ADD COLUMN w_lb REAL CHECK (w_lb IS NULL OR (w_lb >= 0 AND w_lb <= 2205));
