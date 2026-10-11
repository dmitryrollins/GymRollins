#!/usr/bin/env bash
# Starts Docker (colima) and local Supabase; writes connection env to supabase/.env.local (gitignored).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
colima status >/dev/null 2>&1 || colima start --cpu 4 --memory 6
cd "$ROOT"
npx --yes supabase@2.118.0 start >/dev/null
npx --yes supabase@2.118.0 status -o env > supabase/.env.local
echo "Supabase running. Env written to supabase/.env.local"
