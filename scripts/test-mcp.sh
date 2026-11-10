#!/usr/bin/env bash
# Claude's connection end to end over HTTP, against a throwaway LOCAL Worker (scripts/test-server.sh: port 8788 and a
# state folder of its own, removed afterwards; never server/.wrangler/state). scripts/claude-local.mjs smoke runs it as
# Claude would: discovery, registration, the authorize step and /connect, the app's approval, the tokens, MCP calls,
# refresh, then Disconnect Claude and the 401. Local only: nothing reaches claude.ai. Needs server/.dev.vars with
# ALLOW_PASSWORD_AUTH=1, because the approver is an email account made in that throwaway D1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/test-server.sh
source "$ROOT/scripts/test-server.sh"
trap stop_test_server EXIT
start_test_server

API_BASE="$TEST_API_URL" node "$ROOT/scripts/claude-local.mjs" smoke
