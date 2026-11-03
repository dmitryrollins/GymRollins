-- Plan 24: the injury note's optional end date. On or after it, Today asks whether it's the right time to continue. A
-- calendar day like goal_date, synced like the rest of the profile (last write wins). Nullable and not tied to
-- `limits` by a check: the app ignores a date without a note, and older builds don't send the column. RLS is unchanged.
alter table public.profiles add column limits_until date;
