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
case "$API_URL" in
  http://127.0.0.1:*|http://localhost:*) ;;
  *) echo "Refusing to run: API_URL ($API_URL) is not a local stack" >&2; exit 1 ;;
esac

psql_local() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -tA "$@"; }

# Leftovers from an interrupted earlier run (test accounts only).
psql_local -c "delete from auth.users where email like 'sync-%@test.local'" >/dev/null

DELETED_FILE="$(mktemp -t gymsync-deleted-users)"
trap 'rm -f "$DELETED_FILE"' EXIT

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
       + (select count(*) from public.proposals where user_id in ($ids))")
if [[ "$left" != "0" ]]; then
  echo "Account deletion left $left user/data rows behind" >&2
  exit 1
fi
remaining=$(psql_local -c "select count(*) from auth.users where email like 'sync-%@test.local'")
echo "Account deletion verified: $(echo "$ids" | tr ',' '\n' | wc -l | tr -d ' ') deleted users, 0 rows left; $remaining test users remain"
