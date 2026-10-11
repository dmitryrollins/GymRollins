#!/usr/bin/env bash
# Builds the Apple Watch app (plan 17, watchOS 10 for the owner's Series 5) for the watchOS simulator and for devices
# (unsigned), to prove it compiles. Uses SDK target builds: `-destination generic/platform=watchOS…` needs the watchOS
# platform installed in Xcode (Settings > Components), which this doesn't.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYM="$ROOT/ios/build/watch-sym"
cd "$ROOT/ios"
xcodegen generate --quiet
for sdk in watchsimulator watchos; do
  xcodebuild build -project GymRollins.xcodeproj -target GymRollinsWatch -configuration "${CONFIGURATION:-Debug}" \
    -sdk "$sdk" CODE_SIGNING_ALLOWED=NO SYMROOT="$SYM" -quiet "$@"
  echo "GymRollinsWatch: $sdk build OK"
done
