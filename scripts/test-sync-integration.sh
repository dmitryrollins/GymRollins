#!/usr/bin/env bash
# GymSync integration tests against the LOCAL Supabase stack (never a cloud project).
# Needs `scripts/supabase-up.sh` to have run (it writes supabase/.env.local, gitignored).
# Only the public anon key reaches the Swift tests; admin checks below run as postgres inside the local DB container.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/supabase/.env.local"
DB_CONTAINER="supabase_db_gymrollins"

[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE — run scripts/supabase-up.sh first" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
# A prefix match would accept http://127.0.0.1:1@evil.example/, whose host is evil.example.
[[ "$API_URL" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+/?$ ]] || {
  echo "Refusing to run: API_URL ($API_URL) is not a local stack" >&2; exit 1; }

psql_local() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -tA "$@"; }

# Leftovers from an interrupted earlier run (test accounts only).
psql_local -c "delete from auth.users where email like 'sync-%@test.local'" >/dev/null

DELETED_FILE="$(mktemp -t gymsync-deleted-users)"
# Set before the temporary trigger below exists, so an early exit can't leave it behind. A cleanup that fails fails the
# run: a leftover trigger would make every later sync-admin-* sign-up an admin.
cleanup() {
  local status=$?
  rm -f "$DELETED_FILE"
  if ! psql_local -c "drop trigger if exists it_make_admin on auth.users;
                      drop function if exists public.it_make_admin();
                      delete from auth.users where email like 'sync-admin-%@test.local'" >/dev/null; then
    echo "Cleanup failed: the it_make_admin trigger may still be installed on auth.users" >&2
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT

# The moderation test signs up an account named sync-admin-*@test.local; this makes it an admin the moment it exists
# (the app has no way to become one). The trigger and its function are dropped on exit, and the admin row goes with its
# account (on delete cascade), like every other sync-* test user.
psql_local -c "
  create or replace function public.it_make_admin() returns trigger language plpgsql security definer
    set search_path = public as \$\$
  begin insert into public.app_admins (user_id) values (new.id) on conflict do nothing; return new; end \$\$;
  drop trigger if exists it_make_admin on auth.users;
  create trigger it_make_admin after insert on auth.users for each row
    when (new.email like 'sync-admin-%@test.local') execute function public.it_make_admin()" >/dev/null

# Reports of accounts deleted earlier stay anonymised for good, so the check at the end compares with this count.
reports_before=$(psql_local -c "select count(*) from public.reports where reporter_id is null")

export SUPABASE_URL="$API_URL" SUPABASE_ANON_KEY="$ANON_KEY" SYNC_DELETED_USERS_FILE="$DELETED_FILE"
(cd "$ROOT/ios/Packages/GymSync" && swift test --filter GymSyncIntegrationTests)

# Every account the tests deleted must have left no user and no rows behind.
ids=$(sort -u "$DELETED_FILE" | grep -E '^[0-9a-f-]{36}$' | sed "s/.*/'&'/" | paste -sd, -)
[[ -n "$ids" ]] || { echo "No deleted accounts were recorded" >&2; exit 1; }
left=$(psql_local -c "
  select (select count(*) from auth.users where id in ($ids))
       + (select count(*) from public.profiles where user_id in ($ids))
       + (select count(*) from public.custom_exercises where user_id in ($ids))
       + (select count(*) from public.exercise_prefs where user_id in ($ids))
       + (select count(*) from public.routines where user_id in ($ids))
       + (select count(*) from public.week_schedule where user_id in ($ids))
       + (select count(*) from public.muscle_targets where user_id in ($ids))
       + (select count(*) from public.workouts where user_id in ($ids))
       + (select count(*) from public.workout_entries where user_id in ($ids))
       + (select count(*) from public.workout_sets where user_id in ($ids))
       + (select count(*) from public.bodyweight where user_id in ($ids))
       + (select count(*) from public.proposals where user_id in ($ids))
       + (select count(*) from public.gyms where owner_id in ($ids))
       + (select count(*) from public.gym_equipment where owner_id in ($ids))
       + (select count(*) from public.equipment_confirmations where user_id in ($ids))
       + (select count(*) from public.reports where reporter_id in ($ids))
       + (select count(*) from public.user_blocks where blocker_id in ($ids) or blocked_id in ($ids))
       + (select count(*) from storage.objects where owner_id in ($ids)
            and bucket_id in ('gym-photos', 'gym-photos-private'))")
if [[ "$left" != "0" ]]; then
  echo "Account deletion left $left user/data rows behind" >&2
  exit 1
fi
# A report outlives its reporter: the row stays and only the id goes (the query above counted none by id).
reports_after=$(psql_local -c "select count(*) from public.reports where reporter_id is null")
[[ "$reports_after" -gt "$reports_before" ]] || {
  echo "Account deletion removed the reports instead of anonymising them ($reports_before before, $reports_after after)" >&2
  exit 1; }
remaining=$(psql_local -c "select count(*) from auth.users where email like 'sync-%@test.local'")
echo "Account deletion verified: $(echo "$ids" | tr ',' '\n' | wc -l | tr -d ' ') deleted users, 0 rows left; $remaining test users remain"
