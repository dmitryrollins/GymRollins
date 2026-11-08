#!/usr/bin/env bash
# Runs every test suite in the repo. The opt-in end-to-end suites each start a throwaway local Worker on port 8788
# (scripts/test-server.sh) with a state folder of its own; none needs a Cloudflare account. Set DEST to pick the
# simulator the iOS suites use.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> GymCore (swift test)"
(cd "$ROOT/ios/Packages/GymCore" && swift test)

echo "==> GymData (swift test)"
(cd "$ROOT/ios/Packages/GymData" && swift test)

echo "==> GymSync (swift test, fake transport; integration tests: scripts/test-sync-integration.sh, on a throwaway local Worker)"
(cd "$ROOT/ios/Packages/GymSync" && swift test --filter GymSyncTests)

echo "==> GymHealth (swift test, fake Health store)"
(cd "$ROOT/ios/Packages/GymHealth" && swift test)

echo "==> GymWatchLink (swift test) + Apple Watch app build (watchOS simulator + device, unsigned)"
(cd "$ROOT/ios/Packages/GymWatchLink" && swift test)
"$ROOT/scripts/watch-build.sh"

echo "==> iOS app unit + UI tests"
"$ROOT/scripts/ios-test.sh"

echo "==> API server (Cloudflare Worker: vitest in workerd, in-memory D1 and R2; the MCP tools, Claude's OAuth, the limits drift test)"
(cd "$ROOT/server" && { [[ -d node_modules ]] || npm ci; } && npx vitest run && npx tsc --noEmit)

echo "==> Workout link page (node test)"
node --test "$ROOT/web/share/share.test.mjs"

echo "==> Exercise photo matcher (node test)"
node --test "$ROOT/scripts/map-exercise-photos.test.mjs"

echo "==> wger photos + other-language names mapper (node test)"
node --test "$ROOT/scripts/map-wger.test.mjs"

echo "==> Strong / Hevy / FitNotes alias tables (node --test)"
node --test "$ROOT/scripts/other-apps-alias-report.test.mjs"

echo "==> Photo prompts + Gemini photo generator (node test, mocked fetch)"
node --test "$ROOT/scripts/build-photo-prompts.test.mjs" "$ROOT/scripts/generate-photos.test.mjs"

echo "==> Strength-standards tables: the app's and the Worker's copies match (node test)"
node --test "$ROOT/scripts/build-strength-standards.test.mjs"

echo "==> Exercise photo uploader (node test, fake Worker and wrangler)"
node --test "$ROOT/scripts/upload-photos.test.mjs"

echo "==> Seed generators (node test; drift against the D1 migrations)"
node --test "$ROOT/scripts/gen-equipment-seed.test.mjs"
node "$ROOT/scripts/gen-equipment-seed.mjs" --check
node "$ROOT/scripts/gen-exercise-seed.mjs" --check

echo "==> Store comparison for the server-move check (node test)"
node --test "$ROOT/scripts/compare-stores.test.mjs"

# Sync on a throwaway local Worker (needs server/.dev.vars): opt in with SYNC_E2E=1.
if [[ "${SYNC_E2E:-0}" == "1" ]]; then
  echo "==> GymSync integration and iOS sync E2E (throwaway local Worker on :8788)"
  "$ROOT/scripts/test-sync-integration.sh"
  "$ROOT/scripts/ios-test-sync.sh"
fi

# Exercise photo hosting end to end on a throwaway local Worker: opt in with PHOTO_E2E=1.
if [[ "${PHOTO_E2E:-0}" == "1" ]]; then
  echo "==> Photo hosting E2E (throwaway local Worker: upload script -> R2 -> manifest -> app provider)"
  "$ROOT/scripts/test-photo-hosting.sh"
fi

# Claude's connection over HTTP on a throwaway local Worker: opt in with MCP_E2E=1.
if [[ "${MCP_E2E:-0}" == "1" ]]; then
  echo "==> Claude's connection E2E (throwaway local Worker: discovery, /connect, approval, tokens, MCP, revoke)"
  "$ROOT/scripts/test-mcp.sh"
fi

# Gyms shared between two users, on a throwaway local Worker: opt in with GYM_E2E=1.
if [[ "${GYM_E2E:-0}" == "1" ]]; then
  echo "==> Shared gym catalogue E2E (throwaway local Worker on :8788)"
  "$ROOT/scripts/test-gym-e2e.sh"
fi
