#!/usr/bin/env bash
# Local OAuth smoke test for the GymRollins MCP connector (plan 06 task 6). Automates everything in Supabase's
# OAuth 2.1 authorization-code + PKCE flow except the human's "Approve" click on the consent page:
#
#   1. Dynamic Client Registration (DCR) of a throwaway OAuth client, redirect http://127.0.0.1:8976/cb.
#   2. PKCE code_verifier/code_challenge (S256) + a random `state`.
#   3. Hits the authorize endpoint and inspects the redirect it returns.
#   4. Prints the consent URL to open, and starts a tiny local listener on 8976 to capture `code`/`state`.
#   5. Exchanges the code at /auth/v1/oauth/token.
#   6. Calls the MCP endpoint's `tools/list` with the resulting access token.
#
# It also verifies, without a human, everything that doesn't require clicking Approve: DCR works, the authorize
# endpoint's redirect, and that the consent page (scripts/consent-server.mjs) is reachable and its HTML has the
# expected structure. (The same flow runs fully automated in headless Chromium in web/consent/e2e.test.mjs, via
# scripts/test-mcp.sh; this script is for trying it by hand.)
#
# Requires: local Supabase running (scripts/supabase-up.sh), consent-server.mjs running for the interactive part
# (this script starts it if it isn't), and `mcp` served for the last step (this script starts
# `supabase functions serve mcp` if it isn't already, mirroring scripts/test-mcp.sh, and stops what it started).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/supabase/.env.local"
FUNCTIONS_ENV_FILE="$ROOT/supabase/functions/.env.local"
CALLBACK_PORT=8976
CALLBACK_URI="http://127.0.0.1:${CALLBACK_PORT}/cb"
CONSENT_HOST="127.0.0.1"
CONSENT_PORT=55430
TIMEOUT="${SMOKE_TIMEOUT:-300}" # seconds to wait for the human to approve
# SMOKE_TOKEN_FILE=<path>: also save the token response (access + refresh token) there, mode 600, so a local MCP
# client (e.g. a Claude Code agent using curl) can call the server as the approving user.
TOKEN_FILE="${SMOKE_TOKEN_FILE:-}"

[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE. Run scripts/supabase-up.sh first."; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
: "${API_URL:?API_URL missing from $ENV_FILE}"
: "${ANON_KEY:?ANON_KEY missing from $ENV_FILE}"

WORKDIR="$(mktemp -d -t gymrollins-oauth-smoke.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

log() { printf '\n== %s ==\n' "$1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------------------------
# 0. Bring up the consent server and the MCP function if they aren't already running, and remember what we started
#    so we only stop what we started (never another agent's / another run's process).
# ---------------------------------------------------------------------------------------------------------------
consent_up() { curl -sf -m 3 "http://${CONSENT_HOST}:${CONSENT_PORT}/oauth/consent" -o /dev/null 2>&1; }
mcp_up() { curl -sf -m 3 "$API_URL/functions/v1/mcp/oauth-protected-resource" -o /dev/null 2>&1; }

STARTED_CONSENT=0
if consent_up; then
  log "Consent server already running on port $CONSENT_PORT"
else
  log "Starting scripts/consent-server.mjs"
  node "$ROOT/scripts/consent-server.mjs" >"$WORKDIR/consent-server.log" 2>&1 &
  STARTED_CONSENT=1
  for _ in $(seq 1 30); do consent_up && break; sleep 0.5; done
  consent_up || { cat "$WORKDIR/consent-server.log"; fail "consent-server.mjs did not come up on $CONSENT_PORT"; }
fi

STARTED_MCP=0
if mcp_up; then
  log "MCP function already being served"
else
  log "Starting supabase functions serve mcp (this can take a while on first run)"
  [[ -f "$FUNCTIONS_ENV_FILE" ]] || echo "MCP_PUBLIC_BASE_URL=$API_URL" > "$FUNCTIONS_ENV_FILE"
  (cd "$ROOT" && npx --yes supabase@2.118.0 functions serve mcp --no-verify-jwt --env-file "$FUNCTIONS_ENV_FILE") \
    >"$WORKDIR/mcp-serve.log" 2>&1 &
  STARTED_MCP=1
  for _ in $(seq 1 90); do mcp_up && break; sleep 2; done
  mcp_up || { tail -40 "$WORKDIR/mcp-serve.log"; fail "functions serve mcp did not come up"; }
fi

cleanup() {
  if [[ "$STARTED_MCP" == "1" ]]; then
    pkill -INT -f -- "functions serve mcp --no-verify-jwt --env-file $FUNCTIONS_ENV_FILE" 2>/dev/null || true
  fi
  if [[ "$STARTED_CONSENT" == "1" ]]; then
    pkill -INT -f -- "node $ROOT/scripts/consent-server.mjs" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------------------------
# 1. Dynamic Client Registration
# ---------------------------------------------------------------------------------------------------------------
log "1. Dynamic Client Registration"
CLIENT_NAME="gymrollins-oauth-smoke-$(date +%s)"
REGISTER_BODY=$(node -e '
const [name, redirect] = process.argv.slice(1)
process.stdout.write(JSON.stringify({
  client_name: name,
  redirect_uris: [redirect],
  grant_types: ["authorization_code", "refresh_token"],
  response_types: ["code"],
  token_endpoint_auth_method: "none",
}))
' "$CLIENT_NAME" "$CALLBACK_URI")

REGISTER_RESPONSE=$(curl -sf -m 10 -X POST "$API_URL/auth/v1/oauth/clients/register" \
  -H "Content-Type: application/json" -d "$REGISTER_BODY") || fail "DCR request failed"
CLIENT_ID=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).client_id ?? "")' "$REGISTER_RESPONSE")
[[ -n "$CLIENT_ID" ]] || fail "DCR did not return a client_id: $REGISTER_RESPONSE"
echo "OK: client_id=$CLIENT_ID"

# ---------------------------------------------------------------------------------------------------------------
# 2. PKCE + state
# ---------------------------------------------------------------------------------------------------------------
log "2. PKCE challenge"
CODE_VERIFIER=$(openssl rand -base64 96 | tr -d '=+/\n' | cut -c1-64)
CODE_CHALLENGE=$(printf '%s' "$CODE_VERIFIER" | openssl dgst -sha256 -binary | openssl base64 | tr '+/' '-_' | tr -d '=')
STATE=$(openssl rand -hex 16)
echo "OK: code_challenge=$CODE_CHALLENGE"

# ---------------------------------------------------------------------------------------------------------------
# 3. Authorize endpoint
# ---------------------------------------------------------------------------------------------------------------
log "3. GET /auth/v1/oauth/authorize (not following the redirect)"
RESOURCE="$API_URL/functions/v1/mcp"
AUTHORIZE_URL="$API_URL/auth/v1/oauth/authorize?response_type=code&client_id=${CLIENT_ID}&redirect_uri=$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$CALLBACK_URI")&code_challenge=${CODE_CHALLENGE}&code_challenge_method=S256&scope=$(node -e 'process.stdout.write(encodeURIComponent("email profile"))')&state=${STATE}&resource=$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$RESOURCE")"

AUTHORIZE_HEADERS="$WORKDIR/authorize-headers.txt"
curl -s -D "$AUTHORIZE_HEADERS" -o /dev/null -m 10 "$AUTHORIZE_URL"
STATUS_LINE=$(head -1 "$AUTHORIZE_HEADERS")
LOCATION=$(grep -i '^location:' "$AUTHORIZE_HEADERS" | tr -d '\r' | sed 's/^[Ll]ocation: //')
echo "Status: $STATUS_LINE"
[[ -n "$LOCATION" ]] || fail "authorize did not return a Location header. Headers:\n$(cat "$AUTHORIZE_HEADERS")"
AUTHORIZATION_ID=$(node -e 'process.stdout.write(new URL(process.argv[1]).searchParams.get("authorization_id") ?? "")' "$LOCATION")
[[ -n "$AUTHORIZATION_ID" ]] || fail "Location has no authorization_id: $LOCATION"
echo "Raw Location from Supabase: $LOCATION"
echo "authorization_id: $AUTHORIZATION_ID"

# Auth builds the Location from `[auth] site_url` (config.toml: the consent server) + the oauth_server
# authorization_url_path, so it IS the consent page URL. If it points elsewhere, the running auth container has a
# stale config: restart the stack after config.toml changes (supabase stop, then scripts/supabase-up.sh).
CONSENT_URL="$LOCATION"
EXPECTED_PREFIX="http://${CONSENT_HOST}:${CONSENT_PORT}/oauth/consent?"
[[ "$CONSENT_URL" == "$EXPECTED_PREFIX"* ]] || fail "authorize redirected to $CONSENT_URL, expected ${EXPECTED_PREFIX}... — \
restart the local stack after config.toml changes (supabase stop, then scripts/supabase-up.sh)"

# ---------------------------------------------------------------------------------------------------------------
# 4. Non-interactive consent-page checks (loads, has the expected structure) before asking for a human click.
# ---------------------------------------------------------------------------------------------------------------
log "4. Consent page reachability + structure (headless, no browser)"
CONSENT_PAGE_BODY="$WORKDIR/consent-page.html"
CONSENT_STATUS=$(curl -s -o "$CONSENT_PAGE_BODY" -w '%{http_code}' -m 10 "$CONSENT_URL")
[[ "$CONSENT_STATUS" == "200" ]] || fail "consent page returned HTTP $CONSENT_STATUS"
node -e '
const fs = require("fs")
const html = fs.readFileSync(process.argv[1], "utf8")
const required = ["src=\"/config.js\"", "id=\"consent\"", "id=\"approve\"", "id=\"deny\"", "id=\"client-name\"", "id=\"sign-in\""]
const missing = required.filter((needle) => !html.includes(needle))
if (missing.length > 0) {
  console.error("Consent page is missing expected markup: " + missing.join(", "))
  process.exit(1)
}
console.log("OK: consent page served (" + html.length + " bytes) with expected structure")
' "$CONSENT_PAGE_BODY"

# ---------------------------------------------------------------------------------------------------------------
# 5. Tiny local listener on 8976 to capture the callback, then the human step.
# ---------------------------------------------------------------------------------------------------------------
log "5. Waiting for a human to open the consent page and click Approve"
CALLBACK_RESULT="$WORKDIR/callback.json"
LISTENER_SCRIPT="$WORKDIR/listener.mjs"
cat > "$LISTENER_SCRIPT" <<'EOF'
import { createServer } from 'node:http'
import { writeFileSync } from 'node:fs'

const port = Number(process.argv[2])
const outFile = process.argv[3]

const server = createServer((req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${port}`)
  if (url.pathname !== '/cb') {
    res.writeHead(404).end('Not found')
    return
  }
  const code = url.searchParams.get('code')
  const state = url.searchParams.get('state')
  const error = url.searchParams.get('error')
  writeFileSync(outFile, JSON.stringify({ code, state, error }))
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
  res.end('<!doctype html><html><body>GymRollins OAuth smoke test: you can close this tab.</body></html>')
  server.close(() => process.exit(0))
})
server.listen(port, '127.0.0.1')
EOF

node "$LISTENER_SCRIPT" "$CALLBACK_PORT" "$CALLBACK_RESULT" &
LISTENER_PID=$!

echo
echo "Open this URL in a browser, sign in, and click Approve:"
echo
echo "  $CONSENT_URL"
echo
echo "Waiting up to ${TIMEOUT}s on http://127.0.0.1:${CALLBACK_PORT}/cb for the redirect..."

WAITED=0
while [[ ! -s "$CALLBACK_RESULT" ]]; do
  if ! kill -0 "$LISTENER_PID" 2>/dev/null; then
    fail "the callback listener exited before receiving a callback"
  fi
  if (( WAITED >= TIMEOUT )); then
    kill "$LISTENER_PID" 2>/dev/null || true
    fail "timed out after ${TIMEOUT}s waiting for the Approve callback (set SMOKE_TIMEOUT to change)"
  fi
  sleep 1
  WAITED=$((WAITED + 1))
done
wait "$LISTENER_PID" 2>/dev/null || true

CODE=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).code ?? "")' "$CALLBACK_RESULT")
RECEIVED_STATE=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).state ?? "")' "$CALLBACK_RESULT")
CALLBACK_ERROR=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).error ?? "")' "$CALLBACK_RESULT")
[[ -z "$CALLBACK_ERROR" ]] || fail "OAuth callback returned an error: $CALLBACK_ERROR (denied, or the request expired)"
[[ "$RECEIVED_STATE" == "$STATE" ]] || fail "state mismatch: sent $STATE, received $RECEIVED_STATE (possible CSRF)"
[[ -n "$CODE" ]] || fail "callback had no code"
echo "OK: received authorization code, state matched"

# ---------------------------------------------------------------------------------------------------------------
# 6. Token exchange
# ---------------------------------------------------------------------------------------------------------------
log "6. Exchanging the code at /auth/v1/oauth/token"
TOKEN_RESPONSE=$(curl -sf -m 10 -X POST "$API_URL/auth/v1/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=$CODE" \
  --data-urlencode "redirect_uri=$CALLBACK_URI" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "code_verifier=$CODE_VERIFIER") || fail "token exchange failed"
ACCESS_TOKEN=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).access_token ?? "")' "$TOKEN_RESPONSE")
[[ -n "$ACCESS_TOKEN" ]] || fail "token exchange did not return an access_token: $TOKEN_RESPONSE"
echo "OK: got an access token (${#ACCESS_TOKEN} chars)"
if [[ -n "$TOKEN_FILE" ]]; then
  (umask 077 && printf '%s\n' "$TOKEN_RESPONSE" > "$TOKEN_FILE")
  echo "OK: token response saved to $TOKEN_FILE"
fi

# ---------------------------------------------------------------------------------------------------------------
# 7. MCP tools/list with the new token
# ---------------------------------------------------------------------------------------------------------------
log "7. MCP tools/list with the OAuth access token"
RPC_RESPONSE=$(curl -sf -m 15 -X POST "$API_URL/functions/v1/mcp" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "mcp-protocol-version: 2025-06-18" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}') || fail "tools/list request failed"

node -e '
const raw = process.argv[1]
let msg
if (raw.trim().startsWith("{")) {
  msg = JSON.parse(raw)
} else {
  const line = raw.split("\n").find((l) => l.startsWith("data:"))
  if (!line) { console.error("no JSON-RPC message in SSE body:", raw.slice(0, 300)); process.exit(1) }
  msg = JSON.parse(line.slice(5).trim())
}
if (msg.error) { console.error("tools/list returned an error:", msg.error); process.exit(1) }
const tools = msg.result?.tools ?? []
console.log(`OK: tools/list returned ${tools.length} tools: ${tools.map((t) => t.name).join(", ")}`)
' "$RPC_RESPONSE"

log "Done"
echo "The OAuth client registered for this run (client_id=$CLIENT_ID) is left in the local database; it is"
echo "throwaway local-dev data and is cleared by \`supabase db reset\`."
