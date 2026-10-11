#!/usr/bin/env bash
# Prints GymCore line coverage. Fails if below the threshold (default 90%).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THRESHOLD="${1:-90}"
cd "$ROOT/ios/Packages/GymCore"
mkdir -p .build
if ! swift test --enable-code-coverage 2>&1 | tee .build/coverage-test.log >/dev/null; then
    echo "swift test failed; see .build/coverage-test.log" >&2
    cat .build/coverage-test.log
    exit 1
fi
PROF="$(swift test --show-codecov-path)"
BIN="$(find -L .build/debug -maxdepth 1 -name 'GymCorePackageTests.xctest')/Contents/MacOS/GymCorePackageTests"
REPORT="$(xcrun llvm-cov report "$BIN" -instr-profile "$(dirname "$PROF")/default.profdata" -ignore-filename-regex='Tests|\.build')"
echo "$REPORT"
PCT="$(echo "$REPORT" | awk '/^TOTAL/ {gsub("%","",$10); print $10}')"
echo "Line coverage: ${PCT}% (threshold ${THRESHOLD}%)"
awk -v p="$PCT" -v t="$THRESHOLD" 'BEGIN { exit (p+0 >= t+0) ? 0 : 1 }'
