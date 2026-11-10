#!/usr/bin/env bash
# Shared gym catalogue end to end: two users with the real transports, against a throwaway LOCAL Worker
# (scripts/test-server.sh: port 8788, a state folder of its own, removed afterwards; never the development data).
# Afterwards, D1 is searched for every marker the Swift suite recorded: "This phone only" text must never have reached
# a gym, a listing or an item, and the control must have.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/test-server.sh
source "$ROOT/scripts/test-server.sh"

MARKERS_FILE="$(mktemp -t gym-e2e-markers)"
cleanup() {
  local status=$?
  rm -f "$MARKERS_FILE"
  stop_test_server
  exit "$status"
}
trap cleanup EXIT
start_test_server

export API_URL="$TEST_API_URL" GYM_E2E_MARKERS_FILE="$MARKERS_FILE"
(cd "$ROOT/ios/Packages/GymSync" && swift test --filter GymCatalogE2ETests)

# Criterion 6: each marker in every text column that could hold it. instr(), because D1 refuses LIKE patterns over
# 50 bytes, and a marker is longer. The photo rules over HTTP are server/test/photos.test.ts's now.
count_rows() {
  test_d1_count "select
      (select count(*) from gyms
        where instr(name || '|' || coalesce(address, '') || '|' || coalesce(maps_place_id, ''), '$1') > 0)
    + (select count(*) from gym_equipment
        where instr(coalesce(notes, '') || '|' || coalesce(private_brand, '') || '|' || coalesce(private_model, ''), '$1') > 0)
    + (select count(*) from equipment_items
        where instr(coalesce(brand, '') || '|' || coalesce(model, ''), '$1') > 0) as n"
}
absent=0; present=0
while read -r role marker; do
  [[ "$marker" =~ ^e2e-[a-z-]+-[0-9a-f-]{36}$ ]] || { echo "Unexpected marker: $marker" >&2; exit 1; }
  found=$(count_rows "$marker")
  case "$role" in
    absent) [[ "$found" == "0" ]] || { echo "FAIL: '$marker' is in $found shared row(s)" >&2; exit 1; }; absent=$((absent + 1)) ;;
    present) [[ "$found" != "0" ]] || { echo "FAIL: control '$marker' never reached the server" >&2; exit 1; }; present=$((present + 1)) ;;
  esac
done < "$MARKERS_FILE"
[[ "$absent" -gt 0 && "$present" -gt 0 ]] || { echo "FAIL: no markers were recorded ($absent absent, $present present)" >&2; exit 1; }
echo "Stays on the phone verified: $absent markers absent from gyms, gym_equipment, equipment_items; $present control present"
