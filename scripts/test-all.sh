#!/usr/bin/env bash
# Runs every test suite that exists in the repo. Later plans append suites here.
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

echo "==> MCP validator, tools and endpoint (deno test, FakeDb; HTTP e2e: MCP_E2E=1)"
(cd "$ROOT/supabase/functions" && deno test --allow-read _shared/ mcp/)

echo "==> API server (Cloudflare Worker: vitest in workerd, in-memory D1)"
(cd "$ROOT/server" && { [[ -d node_modules ]] || npm ci; } && npx vitest run && npx tsc --noEmit)

echo "==> OAuth consent server (node test)"
node --test "$ROOT/web/consent/server.test.mjs"

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

echo "==> Exercise photo uploader (node test, mocked Storage API)"
node --test "$ROOT/scripts/upload-photos.test.mjs"

echo "==> Seed generators (node test; drift against the Postgres and D1 migrations)"
node --test "$ROOT/scripts/gen-equipment-seed.test.mjs"
node "$ROOT/scripts/gen-equipment-seed.mjs" --check
node "$ROOT/scripts/gen-exercise-seed.mjs" --check

# Sync against a throwaway local Worker (no Docker; needs server/.dev.vars): opt in with SYNC_E2E=1.
if [[ "${SYNC_E2E:-0}" == "1" ]]; then
  echo "==> GymSync integration and iOS sync E2E (throwaway local Worker on :8788)"
  "$ROOT/scripts/test-sync-integration.sh"
  "$ROOT/scripts/ios-test-sync.sh"
fi

# Storage photo hosting end-to-end against the local Supabase stack (needs Docker): opt in with PHOTO_E2E=1.
if [[ "${PHOTO_E2E:-0}" == "1" ]]; then
  echo "==> Photo hosting E2E (local Supabase Storage: upload script -> manifest -> app provider)"
  "$ROOT/scripts/test-photo-hosting.sh"
fi

# MCP HTTP end-to-end against the local Supabase stack (needs Docker): opt in with MCP_E2E=1.
if [[ "${MCP_E2E:-0}" == "1" ]]; then
  echo "==> MCP HTTP E2E (local Supabase, functions serve)"
  "$ROOT/scripts/test-mcp.sh"
fi

# Gyms shared between two users: its Swift suite is parked until plan 28 moves the catalogue to the Worker.
if [[ "${GYM_E2E:-0}" == "1" ]]; then
  echo "==> Shared gym catalogue E2E: parked until plan 28"
fi
