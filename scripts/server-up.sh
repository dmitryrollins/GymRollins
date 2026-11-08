#!/usr/bin/env bash
# The GymRollins API on http://127.0.0.1:8787: the local D1 (server/.wrangler/state) with every migration applied,
# then wrangler dev. Local only: no Cloudflare account is used. Ctrl-C stops it; the local data stays until
# server/.wrangler is removed. The tests never touch it (they use an in-memory D1).
set -euo pipefail
cd "$(dirname "$0")/../server"
if [[ ! -f .dev.vars ]]; then
  echo "Missing server/.dev.vars: copy server/.dev.vars.example and set BETTER_AUTH_SECRET." >&2
  exit 1
fi
[[ -d node_modules ]] || npm ci
npx wrangler d1 migrations apply gymrollins --local < /dev/null
exec npx wrangler dev --local
