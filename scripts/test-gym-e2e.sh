#!/usr/bin/env bash
# Shared gym catalogue end to end: two users and an anonymous client with the real transports, against the LOCAL
# Supabase stack (never a cloud project). Needs `scripts/supabase-up.sh` to have run (it writes supabase/.env.local).
# Afterwards, admin SQL as postgres checks that "This phone only" text never reached a table and that every test
# account and the gyms it created are gone.
set -euo pipefail
# Parked until plan 28: its Swift suite (GymCatalogE2ETests) signs in with the Supabase client, which the app no longer
# has since plan 27 (ios/Packages/GymSync/Tests/GymSyncIntegrationTests/SupabaseParked).
echo "Parked until plan 28 moves the shared gym catalogue to the Worker." >&2
exit 1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/supabase/.env.local"
DB_CONTAINER="supabase_db_gymrollins"

[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE — run scripts/supabase-up.sh first" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
# A prefix match would accept http://127.0.0.1:1@evil.example/, whose host is evil.example.
[[ "$API_URL" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+/?$ ]] || {
  echo "Refusing to run: API_URL ($API_URL) is not a local stack" >&2; exit 1; }

psql_local() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -tA "$@"; }

# Test accounts, and the gyms they shared (deleting an account leaves shared gyms behind by design).
cleanup() {
  psql_local -c "
    delete from public.gym_equipment where gym_id in (select id from public.gyms where maps_place_id like 'e2e-%');
    delete from public.gyms where maps_place_id like 'e2e-%';
    delete from auth.users where email like 'gym-%@test.local'" >/dev/null
}
cleanup

MARKERS_FILE="$(mktemp -t gym-e2e-markers)"
trap 'rm -f "$MARKERS_FILE"; cleanup || true' EXIT

export SUPABASE_URL="$API_URL" SUPABASE_ANON_KEY="$ANON_KEY" GYM_E2E_MARKERS_FILE="$MARKERS_FILE"
(cd "$ROOT/ios/Packages/GymSync" && swift test --filter GymCatalogE2ETests)

# The photo upload rules, over real HTTP (a trigger on storage.objects, which the Swift tests don't reach).
"$ROOT/scripts/test-gym-storage-rules.sh"

# Criterion 6: look for each marker in every column of every table that could hold it.
count_rows() {
  psql_local -c "
    select (select count(*) from public.gyms t where t::text like '%$1%')
         + (select count(*) from public.gym_equipment t where t::text like '%$1%')
         + (select count(*) from public.equipment_items t where t::text like '%$1%')" </dev/null
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

cleanup
left=$(psql_local -c "
  select (select count(*) from auth.users where email like 'gym-%@test.local')
       + (select count(*) from public.gyms where maps_place_id like 'e2e-%')")
[[ "$left" == "0" ]] || { echo "Cleanup left $left rows behind" >&2; exit 1; }
echo "Cleanup verified: no gym-*@test.local users and no e2e gyms remain"
