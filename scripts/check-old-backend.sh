#!/usr/bin/env bash
# Acceptance criterion 1 of docs/specs/2026-11-07-cloudflare-backend-design.md: the old backend is gone. Fails when
#   - tracked files still sit in its folder,
#   - a tracked file outside the history docs names it,
#   - a tracked script runs Docker (or colima).
# Only tracked files are scanned: untracked leftovers on the owner's disk (the old folder, web/consent) don't count.
# The history docs keep their mentions, because they record what was built and decided: docs/plans/, docs/specs/ and
# docs/research/. Nothing else may name it: the old sign-in SDK's Keychain cleanup went once the owner's phone had
# moved (2026-11-09). The patterns are spelled with brackets, so this file does not match itself. They are
# case-insensitive: a test name that spells Postgres followed by a capital T (a timestamps test) matches the second
# one, so name tests differently.
set -euo pipefail
cd "$(dirname "$0")/.."

NAMES='supa[b]ase|postg[r]est'
failed=0

# `git grep`, where no match (exit 1) is an empty answer and a scan that failed (exit 2 or more) stops the guard, so
# a broken repository never reads as a clean one.
scan() {
  local out rc=0
  out="$(git grep "$@")" || rc=$?
  if (( rc > 1 )); then
    echo "FAIL: git grep could not scan the repository (exit $rc)." >&2
    exit 2
  fi
  printf '%s' "$out"
}

tracked="$(git ls-files -- 'supa[b]ase')"
if [[ -n "$tracked" ]]; then
  echo "FAIL: the old backend's folder still has tracked files." >&2
  failed=1
fi

hits="$(scan -n -I -i -E "$NAMES" -- . ':!docs/plans/' ':!docs/specs/' ':!docs/research/')"
if [[ -n "$hits" ]]; then
  echo "$hits" >&2
  echo "FAIL: the lines above name the old backend. The app, the tests and the docs name API_URL and the Worker only." >&2
  failed=1
fi

docker_hits="$(scan -n -I -E '(^|[^A-Za-z])(dock[e]r(-compos[e])?|colim[a])( [a-z]|[[:space:]]*\\?$)' -- scripts)"
if [[ -n "$docker_hits" ]]; then
  echo "$docker_hits" >&2
  echo "FAIL: a script above runs Docker; local development needs none." >&2
  failed=1
fi

if [[ "$failed" == "0" ]]; then
  echo "Old backend gone: no folder, no name outside docs/plans, docs/specs and docs/research, no script running Docker."
fi
exit "$failed"
