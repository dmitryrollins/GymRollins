# Sourced by the iOS test scripts: a throwaway local Worker for tests, on its own port with its own state folder, so the
# development data (server/.wrangler/state, the Worker on 8787) is never touched. Local only: every wrangler command
# has --local. The caller sets ROOT. TEST_API_STATE may name the state folder (the server-move check keeps it in its
# work folder), outside the repo; otherwise a temporary one is made. stop_test_server removes it either way, with the
# accounts and rows the tests made.
TEST_API_PORT="${TEST_API_PORT:-8788}"
TEST_API_URL="http://127.0.0.1:$TEST_API_PORT"
TEST_API_PID=""

start_test_server() {
  local server="$ROOT/server"
  [[ -f "$server/.dev.vars" ]] || {
    echo "Missing server/.dev.vars: copy server/.dev.vars.example and set BETTER_AUTH_SECRET." >&2; return 1; }
  grep -qx 'ALLOW_PASSWORD_AUTH=1' "$server/.dev.vars" || {
    echo "server/.dev.vars needs ALLOW_PASSWORD_AUTH=1: the tests make their accounts by email." >&2; return 1; }
  if curl -s -o /dev/null --max-time 2 "$TEST_API_URL/"; then
    echo "Something already answers on $TEST_API_URL; stop it or set TEST_API_PORT." >&2; return 1
  fi
  TEST_API_STATE="${TEST_API_STATE:-$(mktemp -d -t gymrollins-test-api)}"
  case "$TEST_API_STATE/" in
    "$ROOT"/*) echo "TEST_API_STATE ($TEST_API_STATE) must be outside the repo." >&2; return 1 ;;
  esac
  mkdir -p "$TEST_API_STATE"
  local log="$TEST_API_STATE.log"
  (cd "$server" && { [[ -d node_modules ]] || npm ci; } \
    && npx wrangler d1 migrations apply gymrollins --local --persist-to "$TEST_API_STATE" < /dev/null) > "$log" 2>&1 || {
    echo "Migrating the test D1 failed; see $log" >&2; return 1; }
  # PUBLIC_BASE_URL follows the port (wrangler.jsonc holds the deployed one): password sign-up is allowed only on a
  # local base URL. The origin the Worker sees stays local instead of the custom domain in routes.
  (cd "$server" && exec npx wrangler dev --local --persist-to "$TEST_API_STATE" --ip 127.0.0.1 \
    --port "$TEST_API_PORT" --var "PUBLIC_BASE_URL:$TEST_API_URL" --infer-origin-from-routes=false \
    --show-interactive-dev-session=false) >> "$log" 2>&1 &
  TEST_API_PID=$!
  for _ in $(seq 1 90); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "$TEST_API_URL/v1/sync/profile")" == "401" ]] && return 0
    kill -0 "$TEST_API_PID" 2>/dev/null || break
    sleep 1
  done
  echo "The test Worker didn't come up on $TEST_API_URL; see $log" >&2
  return 1
}

# Stops the Worker (killing npm's wrangler stops workerd too) and removes its state.
stop_test_server() {
  if [[ -n "$TEST_API_PID" ]]; then
    kill "$TEST_API_PID" 2>/dev/null || true
    wait "$TEST_API_PID" 2>/dev/null || true
    TEST_API_PID=""
  fi
  if [[ -n "${TEST_API_STATE:-}" ]]; then
    rm -rf "$TEST_API_STATE" "$TEST_API_STATE.log"
  fi
}

# One number from the test Worker's D1: the SQL selects one column named n.
test_d1_count() {
  (cd "$ROOT/server" && npx wrangler d1 execute gymrollins --local --persist-to "$TEST_API_STATE" --json \
    --command "$1" 2>/dev/null) | node -e '
      let text = ""
      process.stdin.on("data", (chunk) => { text += chunk })
      process.stdin.on("end", () => console.log(JSON.parse(text)[0].results[0].n))'
}
