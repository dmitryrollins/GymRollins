#!/usr/bin/env bash
# Generates the Xcode project and runs app unit + UI tests on the iOS 26 simulator.
# PerformanceUITests (timing baselines) are skipped here; run them with scripts/test-perf.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${DEST:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2}"
cd "$ROOT/ios"
xcodegen generate --quiet
xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins -destination "$DEST" \
  -resultBundlePath "$ROOT/ios/build/TestResults-$(date +%s).xcresult" \
  -skip-testing:GymRollinsUITests/PerformanceUITests -quiet "$@"
