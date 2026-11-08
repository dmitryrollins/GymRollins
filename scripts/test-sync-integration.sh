#!/usr/bin/env bash
# GymSync integration tests against a throwaway LOCAL Worker (scripts/test-server.sh): port 8788 and a state folder of
# its own, removed afterwards, so server/.wrangler/state (the development data) is never touched. Every test makes its
# accounts fresh, as sync-<uuid>@test.local by email and password (ALLOW_PASSWORD_AUTH=1 in server/.dev.vars). The
# Supabase-only suites left (proposals, Claude's grants) are parked until plan 29.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/test-server.sh
source "$ROOT/scripts/test-server.sh"

DELETED_FILE="$(mktemp -t gymsync-deleted-users)"
cleanup() {
  local status=$?
  rm -f "$DELETED_FILE"
  stop_test_server
  exit "$status"
}
trap cleanup EXIT
start_test_server

# GymModerationIntegrationTests: accounts named sync-admin-*@test.local become admins when they sign up, in this
# throwaway D1 only (never a migration).
(cd "$ROOT/server" && npx wrangler d1 execute gymrollins --local --persist-to "$TEST_API_STATE" --command \
  "CREATE TRIGGER test_admins AFTER INSERT ON \"user\" WHEN NEW.email LIKE 'sync-admin-%@test.local' BEGIN INSERT INTO app_admins (user_id, created_at) VALUES (NEW.id, strftime('%Y-%m-%dT%H:%M:%f', 'now') || '000Z'); END") \
  > /dev/null

export API_URL="$TEST_API_URL" SYNC_DELETED_USERS_FILE="$DELETED_FILE"
(cd "$ROOT/ios/Packages/GymSync" && swift test --filter GymSyncIntegrationTests)

# Every account the tests deleted must have left no user, no session and no rows behind.
ids=$(sort -u "$DELETED_FILE" | grep -E '^[0-9a-f-]{36}$' | sed "s/.*/'&'/" | paste -sd, -)
[[ -n "$ids" ]] || { echo "No deleted accounts were recorded" >&2; exit 1; }
left=$(test_d1_count "select
    (select count(*) from \"user\" where id in ($ids))
  + (select count(*) from session where userId in ($ids))
  + (select count(*) from account where userId in ($ids))
  + (select count(*) from profiles where user_id in ($ids))
  + (select count(*) from custom_exercises where user_id in ($ids))
  + (select count(*) from exercise_prefs where user_id in ($ids))
  + (select count(*) from routines where user_id in ($ids))
  + (select count(*) from week_schedule where user_id in ($ids))
  + (select count(*) from muscle_targets where user_id in ($ids))
  + (select count(*) from workouts where user_id in ($ids))
  + (select count(*) from workout_entries where user_id in ($ids))
  + (select count(*) from workout_sets where user_id in ($ids))
  + (select count(*) from bodyweight where user_id in ($ids))
  + (select count(*) from gyms where owner_id in ($ids) or created_by in ($ids))
  + (select count(*) from gym_equipment where owner_id in ($ids) or added_by in ($ids))
  + (select count(*) from equipment_items where created_by in ($ids))
  + (select count(*) from photo_objects where owner_id in ($ids))
  + (select count(*) from equipment_confirmations where user_id in ($ids))
  + (select count(*) from reports where reporter_id in ($ids))
  + (select count(*) from user_blocks where blocker_id in ($ids) or blocked_id in ($ids))
  + (select count(*) from gym_unblocks where user_id in ($ids))
  + (select count(*) from app_admins where user_id in ($ids)) as n")
if [[ "$left" != "0" ]]; then
  echo "Account deletion left $left user/data rows behind" >&2
  exit 1
fi
echo "Account deletion verified: $(echo "$ids" | tr ',' '\n' | wc -l | tr -d ' ') deleted users, 0 rows left"
