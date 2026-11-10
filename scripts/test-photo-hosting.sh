#!/usr/bin/env bash
# Exercise photo hosting end to end against a throwaway LOCAL Worker (scripts/test-server.sh: port 8788 and a state
# folder of its own, removed afterwards; never the development data or a deployed Worker):
# 1. uploads two generated test photos into that Worker's R2 with scripts/upload-photos.mjs --target worker,
# 2. checks a second upload is a no-op,
# 3. runs GymRollinsTests/StoragePhotoIntegrationTests (manifest -> provider -> ExercisePhotoStore over local http).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${DEST:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2}"
TEST_ID="9990"
# shellcheck source=scripts/test-server.sh
source "$ROOT/scripts/test-server.sh"

WORK="$(mktemp -d -t photo-hosting-e2e)"
cleanup() {
  local status=$?
  rm -rf "$WORK"
  stop_test_server
  exit "$status"
}
trap cleanup EXIT
start_test_server

mkdir -p "$WORK/photos"
python3 - "$WORK/photos" "$TEST_ID" <<'PY'
import sys
from PIL import Image
out, test_id = sys.argv[1], sys.argv[2]
Image.new("RGB", (30, 20), (230, 120, 40)).save(f"{out}/own-{test_id}-0.jpg", quality=80)
Image.new("RGB", (20, 30), (40, 120, 230)).save(f"{out}/own-{test_id}-1.jpg", quality=80)
PY

upload() {
  WORKER_URL="$TEST_API_URL" WORKER_STATE="$TEST_API_STATE" \
    node "$ROOT/scripts/upload-photos.mjs" --target worker --dir "$WORK/photos"
}
upload
second="$(upload)"
echo "$second"
grep -q "done: 0 uploaded, 2 skipped, 0 failed; manifest unchanged" <<<"$second" \
  || { echo "second upload was not a no-op" >&2; exit 1; }

cd "$ROOT/ios"
xcodegen generate --quiet
LOG="$WORK/xcodebuild.log"
TEST_RUNNER_PHOTO_E2E=1 TEST_RUNNER_API_URL="$TEST_API_URL" TEST_RUNNER_PHOTO_E2E_ID="$TEST_ID" \
  xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins -destination "$DEST" \
  -only-testing:GymRollinsTests/StoragePhotoIntegrationTests \
  -resultBundlePath "$ROOT/ios/build/TestResults-photos-$(date +%s).xcresult" "$@" >"$LOG" 2>&1 \
  || { tail -40 "$LOG" >&2; exit 1; }
# The suite skips itself without PHOTO_E2E=1, which xcodebuild reports as success: require that it really ran.
grep -E "Test uploadedPhotosLoadThroughTheManifestAndProvider\(\) passed" "$LOG" \
  || { tail -40 "$LOG" >&2; echo "the photo E2E test did not run" >&2; exit 1; }
