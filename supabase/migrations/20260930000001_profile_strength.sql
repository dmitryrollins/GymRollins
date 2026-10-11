-- Plan 14: optional sex and birth year on the profile, used only to pick the strength-level comparison table
-- (raw powerlifting competitors of the same sex and age group). Both nullable: the app asks for them in the
-- Strength level section and never requires them. Synced like the rest of the profile (last write wins); RLS is
-- unchanged (profiles_select already hides the row from MCP clients without the plan permission).
-- birth_year: DomainLimits.birthYear (1900…2100, drift-guarded in _shared/domain-limits.ts).
alter table public.profiles
  add column sex text check (sex in ('male', 'female')),
  add column birth_year int check (birth_year between 1900 and 2100);
