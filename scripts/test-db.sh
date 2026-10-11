#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" && npx --yes supabase@2.118.0 db reset >/dev/null && npx --yes supabase@2.118.0 test db
