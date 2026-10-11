#!/usr/bin/env bash
# Storage photo hosting end-to-end against the LOCAL Supabase stack (never a cloud project):
# 1. uploads two generated test photos (own-9990-0.jpg 30x20, own-9990-1.jpg 20x30) with scripts/upload-photos.mjs,
# 2. checks a second upload is a no-op (idempotent),
# 3. runs GymRollinsTests/StoragePhotoIntegrationTests (manifest -> provider -> ExercisePhotoStore over local http),
# 4. deletes the test photos and rebuilds the bucket manifest without them.
# Only the local API URL reaches the app tests (as TEST_RUNNER_* env vars, passed on without the prefix).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/supabase/.env.local"
DEST="${DEST:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2}"
TEST_ID="9990"

"$ROOT/scripts/supabase-up.sh"
API_URL="$(grep -E '^API_URL=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')"
SERVICE_ROLE_KEY="$(grep -E '^SERVICE_ROLE_KEY=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')"
case "$API_URL" in
  http://127.0.0.1:*|http://localhost:*) ;;
  *) echo "Refusing to run: API_URL ($API_URL) is not a local stack" >&2; exit 1 ;;
esac

WORK="$(mktemp -d -t photo-hosting-e2e)"
cleanup() {
  curl -sf -X DELETE "$API_URL/storage/v1/object/exercise-photos" \
    -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H "apikey: $SERVICE_ROLE_KEY" -H "content-type: application/json" \
    -d "{\"prefixes\":[\"own-$TEST_ID-0.jpg\",\"own-$TEST_ID-1.jpg\"]}" >/dev/null \
    || echo "warning: couldn't delete the test photos" >&2
  mkdir -p "$WORK/empty"
  node "$ROOT/scripts/upload-photos.mjs" --dir "$WORK/empty" >/dev/null \
    || echo "warning: couldn't rebuild the manifest" >&2
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/photos"
python3 - "$WORK/photos" "$TEST_ID" <<'PY'
import sys
from PIL import Image
out, test_id = sys.argv[1], sys.argv[2]
Image.new("RGB", (30, 20), (230, 120, 40)).save(f"{out}/own-{test_id}-0.jpg", quality=80)
Image.new("RGB", (20, 30), (40, 120, 230)).save(f"{out}/own-{test_id}-1.jpg", quality=80)
PY

node "$ROOT/scripts/upload-photos.mjs" --dir "$WORK/photos"
second="$(node "$ROOT/scripts/upload-photos.mjs" --dir "$WORK/photos")"
echo "$second"
grep -q "done: 0 uploaded, 2 skipped, 0 failed; manifest unchanged" <<<"$second" \
  || { echo "second upload was not a no-op" >&2; exit 1; }

cd "$ROOT/ios"
xcodegen generate --quiet
LOG="$WORK/xcodebuild.log"
TEST_RUNNER_PHOTO_E2E=1 TEST_RUNNER_SUPABASE_URL="$API_URL" TEST_RUNNER_PHOTO_E2E_ID="$TEST_ID" \
  xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins -destination "$DEST" \
  -only-testing:GymRollinsTests/StoragePhotoIntegrationTests \
  -resultBundlePath "$ROOT/ios/build/TestResults-photos-$(date +%s).xcresult" "$@" >"$LOG" 2>&1 \
  || { tail -40 "$LOG" >&2; exit 1; }
# The suite skips itself without PHOTO_E2E=1, which xcodebuild reports as success: require that it really ran.
grep -E "Test uploadedPhotosLoadThroughTheManifestAndProvider\(\) passed" "$LOG" \
  || { tail -40 "$LOG" >&2; echo "the photo E2E test did not run" >&2; exit 1; }
