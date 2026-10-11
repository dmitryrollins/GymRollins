#!/usr/bin/env bash
# MCP Edge Function tests against the local Supabase stack (needs Docker): unit tests plus the HTTP end-to-end
# test (supabase/functions/mcp/http_test.ts), then the OAuth consent page in headless Chromium
# (web/consent/e2e.test.mjs). Starts `supabase functions serve mcp` and scripts/consent-server.mjs in the background
# unless they are already answering, runs the tests, and stops only what it started on exit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPABASE=(npx --yes supabase@2.118.0)
API_URL="http://127.0.0.1:55421"
MCP_URL="$API_URL/functions/v1/mcp"
METADATA_URL="$MCP_URL/oauth-protected-resource"
ENV_FILE="$ROOT/supabase/functions/.env.local"   # gitignored; public base URL the function advertises
LOG="$(mktemp -t gymrollins-mcp-serve.XXXXXX)"

"$ROOT/scripts/supabase-up.sh"
[[ -f "$ENV_FILE" ]] || echo "MCP_PUBLIC_BASE_URL=$API_URL" > "$ENV_FILE"

# Up AND advertising the public base URL (the edge runtime `supabase start` launches has no env file, so its
# function advertises the internal http://kong:8000 — then we start our own serve, which replaces it).
metadata_up() { curl -sf -m 5 "$METADATA_URL" 2>/dev/null | grep -q "\"resource\":\"$MCP_URL\""; }

CONSENT_URL="http://127.0.0.1:55430/oauth/consent"
consent_up() { curl -sf -m 3 "$CONSENT_URL" -o /dev/null 2>&1; }

STARTED=0
STARTED_CONSENT=0
stop_serve() {
  if [[ "$STARTED" == "1" ]]; then
    # Only this repo's serve (matched by its absolute env-file path), never another project's.
    pkill -INT -f -- "functions serve mcp --no-verify-jwt --env-file $ENV_FILE" 2>/dev/null || true
  fi
  if [[ "$STARTED_CONSENT" == "1" ]]; then
    pkill -INT -f -- "node $ROOT/scripts/consent-server.mjs" 2>/dev/null || true
  fi
  wait 2>/dev/null || true
}
trap stop_serve EXIT

if metadata_up; then
  echo "Using the functions server already running on $API_URL"
else
  echo "Starting supabase functions serve mcp (log: $LOG)"
  (cd "$ROOT" && "${SUPABASE[@]}" functions serve mcp --no-verify-jwt --env-file "$ENV_FILE") >"$LOG" 2>&1 &
  STARTED=1
  for _ in $(seq 1 90); do
    metadata_up && break
    sleep 2
  done
  metadata_up || { echo "functions serve did not come up; log:"; tail -40 "$LOG"; exit 1; }
fi

(cd "$ROOT/supabase/functions" && MCP_E2E_URL="$MCP_URL" deno test -A _shared/ mcp/)

echo "==> OAuth consent page in headless Chromium (web/consent/e2e.test.mjs)"
if ! consent_up; then
  node "$ROOT/scripts/consent-server.mjs" >"$LOG.consent" 2>&1 &
  STARTED_CONSENT=1
  for _ in $(seq 1 30); do consent_up && break; sleep 0.5; done
  consent_up || { echo "consent-server.mjs did not come up; log:"; cat "$LOG.consent"; exit 1; }
fi
(cd "$ROOT/web/consent" && { [[ -d node_modules/playwright ]] || npm ci --no-audit --no-fund --silent; } \
  && npx --no-install playwright install chromium >/dev/null)
node --test "$ROOT/web/consent/server.test.mjs" "$ROOT/web/consent/e2e.test.mjs"
