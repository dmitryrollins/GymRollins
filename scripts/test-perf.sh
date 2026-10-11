#!/usr/bin/env bash
# Performance baselines (timing-based, so not in test-all.sh). Numbers and targets: docs/testing/performance.md.
#   1. GymData repository timings (recent/history/bests, 150 workouts, release build, < 50 ms each).
#   2. iOS launch + Library/Log scroll metrics (PerformanceUITests) on the iOS 26 simulator.
# Usage: scripts/test-perf.sh [data|ui]   (default: both)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHAT="${1:-all}"
DEST="${DEST:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2}"

if [[ "$WHAT" == "all" || "$WHAT" == "data" ]]; then
  echo "==> GymData repository performance (release, GYM_PERF=1)"
  (cd "$ROOT/ios/Packages/GymData" && GYM_PERF=1 swift test -c release -Xswiftc -enable-testing \
    --filter WorkoutRepositoryPerformanceTests 2>&1 | grep -E "PERF|passed|failed|error")
fi

if [[ "$WHAT" == "all" || "$WHAT" == "ui" ]]; then
  echo "==> iOS launch and scroll metrics (PerformanceUITests)"
  cd "$ROOT/ios"
  xcodegen generate --quiet
  RESULT="$ROOT/ios/build/Perf-$(date +%s).xcresult"
  xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins -destination "$DEST" \
    -only-testing:GymRollinsUITests/PerformanceUITests -resultBundlePath "$RESULT" 2>&1 \
    | grep -E "measured \[|Test Case .*(passed|failed)|error:" || true
  echo "Result bundle: $RESULT"
fi
