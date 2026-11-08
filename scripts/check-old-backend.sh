#!/usr/bin/env bash
# Acceptance criterion 1 of docs/specs/2026-11-07-cloudflare-backend-design.md: the old backend is gone. Fails when
#   - tracked files still sit in its folder,
#   - a tracked file outside the history docs names it,
#   - a tracked script runs Docker (or colima).
# Only tracked files are scanned: untracked leftovers on the owner's disk (the old folder, web/consent) don't count.
# The history docs keep their mentions, because they record what was built and decided: docs/plans/, docs/specs/ and
# docs/research/. One line is allowed elsewhere: the old sign-in SDK's Keychain service name, which the server move
# needs to delete that SDK's items from the phone (ios/Packages/GymSync/Sources/GymSync/OldServerKeychain.swift).
# The patterns are spelled with brackets, so this file does not match itself. They are case-insensitive: a test name
# that spells Postgres followed by a capital T (a timestamps test) matches the second one, so name tests differently.
set -euo pipefail
cd "$(dirname "$0")/.."

NAMES='supa[b]ase|postg[r]est'
KEYCHAIN_FILE='ios/Packages/GymSync/Sources/GymSync/OldServerKeychain.swift'
KEYCHAIN_LINE='    public static let service = "supa[b]ase\.gotrue\.swift"'
failed=0

if [[ -n "$(git ls-files -- 'supa[b]ase')" ]]; then
  echo "FAIL: the old backend's folder still has tracked files." >&2
  failed=1
fi

hits="$(git grep -n -I -i -E "$NAMES" -- . ':!docs/plans/' ':!docs/specs/' ':!docs/research/' \
  | grep -v -E "^${KEYCHAIN_FILE}:[0-9]+:${KEYCHAIN_LINE}\$" || true)"
if [[ -n "$hits" ]]; then
  echo "$hits" >&2
  echo "FAIL: the lines above name the old backend. The app, the tests and the docs name API_URL and the Worker only." >&2
  failed=1
fi

if [[ -f "$KEYCHAIN_FILE" ]] && [[ "$(grep -c -i -E "$NAMES" "$KEYCHAIN_FILE")" != "1" ]]; then
  echo "FAIL: $KEYCHAIN_FILE may name the old backend only in its service line." >&2
  failed=1
fi

docker_hits="$(git grep -n -I -E '(^|[^A-Za-z])(dock[e]r|colim[a]) [a-z]' -- scripts || true)"
if [[ -n "$docker_hits" ]]; then
  echo "$docker_hits" >&2
  echo "FAIL: a script above runs Docker; local development needs none." >&2
  failed=1
fi

if [[ "$failed" == "0" ]]; then
  echo "Old backend gone: no folder, no name outside docs/plans, docs/specs and docs/research, no script running Docker."
fi
exit "$failed"
