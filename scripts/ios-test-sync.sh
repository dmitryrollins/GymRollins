#!/usr/bin/env bash
# E2E sync UI tests (GymRollinsUITests/SyncUITests, ProposalSyncUITests) against the LOCAL Supabase stack — never a cloud project.
# Only the local API URL and the public anon key reach the tests (as TEST_RUNNER_* env vars, which Xcode hands to
# the UI test runner without the prefix; the tests pass them to the app via launchEnvironment). Test accounts
# (ui-*@test.local) are deleted afterwards as postgres inside the local DB container.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/supabase/.env.local"
DB_CONTAINER="supabase_db_gymrollins"
DEST="${DEST:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2}"

"$ROOT/scripts/supabase-up.sh"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 1; }
API_URL="$(grep -E '^API_URL=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')"
ANON_KEY="$(grep -E '^ANON_KEY=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')"
case "$API_URL" in
  http://127.0.0.1:*|http://localhost:*) ;;
  *) echo "Refusing to run: API_URL ($API_URL) is not a local stack" >&2; exit 1 ;;
esac
[[ -n "$ANON_KEY" ]] || { echo "ANON_KEY missing from $ENV_FILE" >&2; exit 1; }

cleanup() {
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -tA \
    -c "delete from auth.users where email like 'ui-%@test.local'" >/dev/null \
    || echo "warning: couldn't delete ui-*@test.local users" >&2
}
cleanup # leftovers from an interrupted run
trap cleanup EXIT

cd "$ROOT/ios"
xcodegen generate --quiet
TEST_RUNNER_SUPABASE_URL="$API_URL" TEST_RUNNER_SUPABASE_ANON_KEY="$ANON_KEY" \
  xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins -destination "$DEST" \
  -only-testing:GymRollinsUITests/SyncUITests -only-testing:GymRollinsUITests/ProposalSyncUITests \
  -resultBundlePath "$ROOT/ios/build/TestResults-sync-$(date +%s).xcresult" -quiet "$@"
