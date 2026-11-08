#!/usr/bin/env bash
# E2E sync UI tests (GymRollinsUITests/SyncUITests) against a throwaway LOCAL Worker (scripts/test-server.sh): port
# 8788 and a state folder of its own, removed afterwards. Only the Worker's local URL reaches the tests, as
# TEST_RUNNER_API_URL (Xcode hands it to the UI test runner without the prefix; the tests pass it to the app via
# launchEnvironment). Each test signs up fresh ui-<uuid>@test.local accounts by email (DEBUG builds only).
# ProposalSyncUITests plays Claude with ClaudeTestClient; the server-move test runs only from server-move-check.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${DEST:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2}"
# shellcheck source=scripts/test-server.sh
source "$ROOT/scripts/test-server.sh"
trap stop_test_server EXIT
start_test_server

cd "$ROOT/ios"
xcodegen generate --quiet
TEST_RUNNER_API_URL="$TEST_API_URL" \
  xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins -destination "$DEST" \
  -only-testing:GymRollinsUITests/SyncUITests \
  -only-testing:GymRollinsUITests/ProposalSyncUITests \
  -resultBundlePath "$ROOT/ios/build/TestResults-sync-$(date +%s).xcresult" -quiet "$@"
