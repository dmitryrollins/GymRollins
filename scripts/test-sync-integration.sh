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

DELETED_FILE="$(mktemp -t gymsync-deleted-users)"
cleanup() {
  rm -f "$DELETED_FILE"
  psql_local -c "drop trigger if exists it_make_admin on auth.users;
                 drop function if exists public.it_make_admin();
                 delete from auth.users where email like 'sync-admin-%@test.local'" >/dev/null || true
}
trap cleanup EXIT

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
       + (select count(*) from public.gym_equipment where owner_id in ($ids))")
if [[ "$left" != "0" ]]; then
  echo "Account deletion left $left user/data rows behind" >&2
  exit 1
fi
remaining=$(psql_local -c "select count(*) from auth.users where email like 'sync-%@test.local'")
echo "Account deletion verified: $(echo "$ids" | tr ',' '\n' | wc -l | tr -d ' ') deleted users, 0 rows left; $remaining test users remain"
