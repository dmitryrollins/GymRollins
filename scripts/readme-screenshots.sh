#!/usr/bin/env bash
# Regenerates the README screenshots from the app's DEBUG mock-data seeds (nothing real is read):
# status bar override (9:41, full battery) -> ReadmeScreenshotsUITests writes full-size PNGs ->
# README-sized (600 px wide) copies in docs/readme/ -> status bar override cleared.
# Full-size PNGs go to $README_SCREENSHOTS_DIR (default ios/build/readme-shots/full, gitignored with ios/build).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
SIM_OS="${SIM_OS:-26.2}"
DEST="${DEST:-platform=iOS Simulator,name=$SIM_NAME,OS=$SIM_OS}"
FULL="${README_SCREENSHOTS_DIR:-$ROOT/ios/build/readme-shots/full}"
OUT="$ROOT/docs/readme"
WIDTH=600

# The simulator the tests run on (several can be booted at once); `booted` when DEST was overridden.
UDID="$(xcrun simctl list devices "iOS $SIM_OS" | sed -n "s/^ *$SIM_NAME (\([0-9A-Fa-f-]\{36\}\)).*/\1/p" | head -1)"
SIM="${UDID:-booted}"
if [ -n "$UDID" ]; then
  xcrun simctl boot "$UDID" 2>/dev/null || true # already booted is fine
  xcrun simctl bootstatus "$UDID" -b >/dev/null
fi
clear_status_bar() { xcrun simctl status_bar "$SIM" clear || true; }
trap clear_status_bar EXIT
xcrun simctl status_bar "$SIM" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3

mkdir -p "$FULL" "$OUT"
rm -f "$FULL"/*.png
cd "$ROOT/ios"
xcodegen generate --quiet
TEST_RUNNER_README_SCREENSHOTS_DIR="$FULL" \
  xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins -destination "$DEST" \
  -resultBundlePath "$ROOT/ios/build/ReadmeScreenshots-$(date +%s).xcresult" \
  -only-testing:GymRollinsUITests/ReadmeScreenshotsUITests -quiet "$@"

for shot in 01-today 02-workout 03-claude-proposal 04-body 05-log 06-claude-connect; do
  [ -f "$FULL/$shot.png" ] || { echo "missing screenshot: $FULL/$shot.png" >&2; exit 1; }
done
for png in "$FULL"/*.png; do
  sips --resampleWidth "$WIDTH" "$png" --out "$OUT/$(basename "$png")" >/dev/null
done
echo "README screenshots: $OUT"
