#!/usr/bin/env bash
# The server-move check (spec section 8, iOS; acceptance criterion 7). A COPY of the owner's phone store goes into a
# throwaway simulator, the app moves it to a throwaway local Worker, a new account signs in, and the first sync uploads
# it. Then D1's counts must equal the copy's, and the phone's records must be unchanged apart from sync state.
#
#   scripts/server-move-check.sh <phone-backup-dir> <work-dir>
#
# <phone-backup-dir> holds the app container's Library: Library/Application Support/default.store (with its -wal and
# -shm) and Library/Preferences/com.rollins.gymrollins.plist. It is only read. <work-dir> gets every copy, the build and
# the D1 state. Both must be outside the repo, because this is the owner's personal data. The simulator and the D1
# state are deleted at the end; delete <work-dir> once the numbers are noted. Local only: no Cloudflare account,
# nothing on a phone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP="$(cd "${1:?usage: server-move-check.sh <phone-backup-dir> <work-dir>}" && pwd)"
mkdir -p "${2:?usage: server-move-check.sh <phone-backup-dir> <work-dir>}"
WORK="$(cd "$2" && pwd)"
for dir in "$BACKUP" "$WORK"; do
  case "$dir/" in
    "$ROOT"/*) echo "Refusing: $dir is inside the repo, and the owner's data stays out of it." >&2; exit 1 ;;
  esac
done
STORE="$BACKUP/Library/Application Support/default.store"
PREFS="$BACKUP/Library/Preferences/com.rollins.gymrollins.plist"
[[ -f "$STORE" && -f "$PREFS" ]] || { echo "No store or settings under $BACKUP/Library" >&2; exit 1; }

# The copies: `before` is the reference the comparison reads, `count` is the one sqlite3 counts.
mkdir -p "$WORK/before" "$WORK/count" "$WORK/after"
for suffix in "" -wal -shm; do
  if [[ -f "$STORE$suffix" ]]; then
    cp "$STORE$suffix" "$WORK/before/default.store$suffix"
    cp "$STORE$suffix" "$WORK/count/default.store$suffix"
  fi
done
cp "$PREFS" "$WORK/before/com.rollins.gymrollins.plist"

export TEST_API_STATE="$WORK/d1"
# shellcheck source=scripts/test-server.sh
source "$ROOT/scripts/test-server.sh"
UDID="$(xcrun simctl create "GymRollins server move $(date +%s)" \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max com.apple.CoreSimulator.SimRuntime.iOS-26-2)"
cleanup() {
  local status=$?
  stop_test_server
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT
start_test_server
xcrun simctl bootstatus "$UDID" -b >/dev/null

# Build, install, then put the copies where a `-uiTesting -diskStore` launch reads them.
cd "$ROOT/ios"
xcodegen generate --quiet
xcodebuild build-for-testing -project GymRollins.xcodeproj -scheme GymRollins -destination "id=$UDID" \
  -derivedDataPath "$WORK/DerivedData" -quiet
# Right after a boot, an install can fail with IXErrorDomain code 2 ("Failed to create promise"); it works on retry.
for attempt in 1 2 3 4 5; do
  xcrun simctl install "$UDID" "$WORK/DerivedData/Build/Products/Debug-iphonesimulator/GymRollins.app" && break
  [[ "$attempt" == 5 ]] && { echo "Installing the app on the simulator failed." >&2; exit 1; }
  sleep 10
done
DATA="$(xcrun simctl get_app_container "$UDID" com.rollins.gymrollins data)"
mkdir -p "$DATA/tmp" "$DATA/Library/Preferences"
for suffix in "" -wal -shm; do
  if [[ -f "$WORK/before/default.store$suffix" ]]; then
    cp "$WORK/before/default.store$suffix" "$DATA/tmp/gymrollins-uitest.store$suffix"
  fi
done
cp "$WORK/before/com.rollins.gymrollins.plist" "$DATA/Library/Preferences/com.rollins.gymrollins.plist"

TEST_RUNNER_API_URL="$TEST_API_URL" TEST_RUNNER_SERVER_MOVE_CHECK=1 \
  xcodebuild test-without-building -project GymRollins.xcodeproj -scheme GymRollins -destination "id=$UDID" \
  -derivedDataPath "$WORK/DerivedData" \
  -only-testing:GymRollinsUITests/SyncUITests/testThePhonesDataMovesToTheWorker \
  -resultBundlePath "$WORK/TestResults-server-move.xcresult" -quiet

# Xcode's own install moves the app's data container to a new path (the data goes with it), so ask again.
DATA="$(xcrun simctl get_app_container "$UDID" com.rollins.gymrollins data)"
[[ -f "$DATA/tmp/gymrollins-uitest.store" ]] || {
  echo "The app's store isn't in its container after the test." >&2; exit 1; }
for suffix in "" -wal -shm; do
  if [[ -f "$DATA/tmp/gymrollins-uitest.store$suffix" ]]; then
    cp "$DATA/tmp/gymrollins-uitest.store$suffix" "$WORK/after/default.store$suffix"
  fi
done

# name | the copy's count (active workouts never sync) | D1's count (only the move's account is in this D1)
CHECKS=(
  "workouts|select count(*) from ZWORKOUTRECORD where ZISACTIVE = 0|select count(*) as n from workouts"
  "entries|select count(*) from ZWORKOUTENTRYRECORD e join ZWORKOUTRECORD w on e.ZWORKOUT = w.Z_PK where w.ZISACTIVE = 0|select count(*) as n from workout_entries"
  "sets|select count(*) from ZSETRECORD s join ZWORKOUTENTRYRECORD e on s.ZENTRY = e.Z_PK join ZWORKOUTRECORD w on e.ZWORKOUT = w.Z_PK where w.ZISACTIVE = 0|select count(*) as n from workout_sets"
  "routines|select count(*) from ZROUTINERECORD|select count(*) as n from routines"
  "body weights|select count(*) from ZBODYWEIGHTRECORD|select count(*) as n from bodyweight"
  "custom exercises|select count(*) from ZCUSTOMEXERCISERECORD|select count(*) as n from custom_exercises"
  "week days|select count(*) from ZWEEKDAYRECORD|select count(*) as n from week_schedule"
  "profile|select count(*) from ZPROFILERECORD|select count(*) as n from profiles"
  "exercise preferences|select count(*) from ZEXERCISEPREFERENCERECORD|select count(*) as n from exercise_prefs"
  "muscle targets|select count(*) from ZMUSCLETARGETRECORD|select count(*) as n from muscle_targets"
  "private gyms|select count(*) from ZGYMRECORD where ZVISIBILITYRAW = 'synced'|select count(*) as n from gyms where visibility = 'private'"
  "private listings|select count(*) from ZGYMLISTINGRECORD where ZVISIBILITYRAW = 'synced'|select count(*) as n from gym_equipment where visibility = 'private'"
  "workouts at a gym|select count(*) from ZWORKOUTRECORD w join ZGYMRECORD g on g.ZID = w.ZGYMID where w.ZISACTIVE = 0 and g.ZVISIBILITYRAW = 'synced'|select count(*) as n from workouts where gym_id is not null"
  "entries at a listing|select count(*) from ZWORKOUTENTRYRECORD e join ZGYMLISTINGRECORD l on l.ZID = e.ZGYMLISTINGID join ZWORKOUTRECORD w on e.ZWORKOUT = w.Z_PK where w.ZISACTIVE = 0 and l.ZVISIBILITYRAW = 'synced'|select count(*) as n from workout_entries where gym_equipment_id is not null"
)
failed=0
printf '%-22s %8s %8s\n' "" "phone" "D1"
for check in "${CHECKS[@]}"; do
  IFS='|' read -r name copy_sql d1_sql <<< "$check"
  mine="$(sqlite3 "$WORK/count/default.store" "$copy_sql")"
  theirs="$(test_d1_count "$d1_sql")"
  printf '%-22s %8s %8s\n' "$name" "$mine" "$theirs"
  [[ "$mine" == "$theirs" ]] || failed=1
done
echo "(Spec section 8 lists 148 workouts, 836 entries, 2,685 sets, 6 routines and 24 body weights; the copy is the reference.)"

unsynced="$(sqlite3 "$WORK/after/default.store" "select
    (select count(*) from ZWORKOUTRECORD where ZISACTIVE = 0 and (ZDIRTY = 1 or ZSERVERUPDATEDAT is null))
  + (select count(*) from ZBODYWEIGHTRECORD where ZDIRTY = 1)
  + (select count(*) from ZROUTINERECORD where ZDIRTY = 1)
  + (select count(*) from ZCUSTOMEXERCISERECORD where ZDIRTY = 1)
  + (select count(*) from ZWEEKDAYRECORD where ZDIRTY = 1)
  + (select count(*) from ZPROFILERECORD where ZDIRTY = 1)
  + (select count(*) from ZEXERCISEPREFERENCERECORD where ZDIRTY = 1)
  + (select count(*) from ZMUSCLETARGETRECORD where ZDIRTY = 1)
  + (select count(*) from ZGYMRECORD where ZVISIBILITYRAW = 'synced' and ZDIRTY = 1)
  + (select count(*) from ZGYMLISTINGRECORD where ZVISIBILITYRAW = 'synced' and ZDIRTY = 1)")"
echo "Records still unsynced on the phone: $unsynced"
[[ "$unsynced" == "0" ]] || failed=1

node "$ROOT/scripts/compare-stores.mjs" "$WORK/before/default.store" "$WORK/after/default.store" || failed=1
if [[ "$failed" != "0" ]]; then
  echo "Server move check FAILED" >&2
  exit 1
fi
echo "Server move verified."
