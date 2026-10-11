# Plan 06: Remote MCP server, OAuth consent, proposals in the app

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude can read training data and propose plan changes through a remote MCP server (a Supabase Edge
Function with OAuth via Supabase Auth). The app shows Claude's proposals, lets the owner apply them change by change,
with undo, or auto-apply them when that's enabled, and has a Claude connection screen with permissions.

**Architecture:**
- `supabase/functions/mcp/index.ts` is one Edge Function (`verify_jwt = false`) that routes on its path:
  `GET …/mcp/oauth-protected-resource` serves the RFC 9728 metadata, and every other method on `…/mcp` is the MCP
  Streamable HTTP endpoint, handled by `createMcpHandler` from `@modelcontextprotocol/server` v2 (stateless, one
  server per request). Unauthenticated requests get `401` with
  `WWW-Authenticate: Bearer resource_metadata="<base>/functions/v1/mcp/oauth-protected-resource"`.
- Auth: the bearer token is validated with `supabase.auth.getUser(token)`, and every tool runs on a
  **user-scoped client** (`createClient(url, anonKey, { global: { headers: { Authorization } } })`), so RLS applies,
  including the plan 05 MCP-client restrictions. The service role is never used in tool paths.
- Tool logic lives in plain modules (`tools/*.ts`) that take a small `Db` interface, so they're unit-testable with a
  fake. `index.ts` only wires the transport, auth, rate limiting and audit.
- The plan-change validator is ported to TypeScript (`_shared/plan-validation.ts`) and must pass the **same**
  `app/fixtures/plan-changes.json` as Swift.
- The consent page is a static site (`web/consent/`), because Supabase rewrites Edge Function HTML to text/plain.
  Locally it's served by `scripts/consent-server.mjs` on `http://127.0.0.1:55430`, with `site_url` pointing there.
- The app applies proposals on the device with a new pure `PlanChangeApplier` (GymCore) and syncs the routines.

**Tech Stack:** Deno (Supabase Edge Runtime), `npm:@modelcontextprotocol/server@2.1.0`, `npm:zod@^4`,
`jsr:@supabase/supabase-js@2`, Deno test; Swift 6.2 (GymCore, GymSync, app), XCUITest.

**Reference:** `docs/research/2026-09-26-mcp-on-supabase.md` (APIs, spec details, known issues).
**Depends on:** Plan 05 merged (schema, RLS, proposals table, GymSync). Local Supabase ports are 554xx.
**Known limitation:** the full "add custom connector in the Claude app" flow can't be tested against local Supabase:
Claude needs public HTTPS, and the local OAuth server emits `127.0.0.1` redirects. Everything else is tested
locally with real tokens. Task 9 documents the cloud checklist to run once the owner approves a cloud project.

**Conventions:** Branch `plan-06-mcp-proposals`. Commit per task with the trailer lines. Never `git add -A`. No
cloud commands.

---

## File structure

```
supabase/
  config.toml                                (modify) [functions.mcp] verify_jwt=false; site_url -> consent server
  functions/_shared/plan-validation.ts       TS port of PlanChangeValidator
  functions/_shared/plan-validation.test.ts  runs app/fixtures/plan-changes.json
  functions/mcp/index.ts                     routing, auth, transport, rate limit, audit
  functions/mcp/auth.ts                      bearer extraction, getUser, 401 builder, metadata doc
  functions/mcp/db.ts                        Db interface + Supabase implementation
  functions/mcp/tools/read.ts                get_profile, get_plan, list_workouts, get_workout, get_exercise_history,
                                             get_training_summary, get_bodyweight, search_exercises
  functions/mcp/tools/write.ts               propose_plan_changes, get_proposal, log_bodyweight
  functions/mcp/tools/register.ts            zod schemas, descriptions, annotations -> McpServer
  functions/mcp/*_test.ts                    unit tests with FakeDb
  functions/mcp/http_test.ts                 HTTP e2e against `supabase functions serve` (skips if not running)
  migrations/20260927000001_mcp_audit.sql    mcp_audit table + rate-limit helper
web/consent/index.html, consent.js, style.css
scripts/consent-server.mjs, scripts/test-mcp.sh
ios/Packages/GymCore/Sources/GymCore/Plan/PlanChangeApplier.swift (+ tests)
ios/Packages/GymData/Sources/GymData/Records/ProposalRecord.swift, Repositories/ProposalRepository.swift (+ tests)
ios/GymRollins/Features/Claude/ClaudeConnectionView.swift, ProposalReviewView.swift, ProposalModel.swift
ios/GymRollinsUITests/ProposalUITests.swift
```

---

### Task 1: TypeScript plan validator on the shared fixture

**Files:** `supabase/functions/_shared/plan-validation.ts`, `plan-validation.test.ts`.

- [ ] Port `PlanChangeValidator` + `PlanChangeValidator+Families.swift` from GymCore **exactly** (same types, ranges,
  limits, messages, effective reps/repsMin tracking, routine add/remove tracking). Export:
```ts
export type PlanChangeType = 'add-exercise'|'remove-exercise'|'swap-exercise'|'sets'|'reps'|'repsMin'|'sec'|'weight'|'cardio'|'reorder'|'superset'|'routine-prog'|'exercise-prog'|'inc'|'add-routine'|'remove-routine'|'rename-routine'|'pause-routine'|'week'
export interface PlanChange { id: string; type: PlanChangeType; routineId?: string; exerciseId?: string; toExerciseId?: string; withExerciseId?: string; sets?: number; reps?: number; repsMin?: number; sec?: number; weightKg?: number; minutes?: number; speed?: number; incKg?: number; policy?: 'off'|'linear'|'greyskull'|'double'|'time'; position?: number; name?: string; weekday?: number; paused?: boolean; reason?: string }
export interface PlanProposal { summary: string; changes: PlanChange[] }
export interface RoutineRef { id: string; name: string; exerciseIds: string[]; reps?: Record<string, number>; repsMin?: Record<string, number> }
export interface PlanSnapshot { routines: RoutineRef[] }
export interface PlanViolation { changeId: string | null; field: string; message: string }
export function validateProposal(p: PlanProposal, plan: PlanSnapshot, exerciseExists: (id: string) => boolean): PlanViolation[]
```
- [ ] Test: read `../../../fixtures/plan-changes.json` (from the test file's location, via `new URL(..., import.meta.url)`)
  and, for every case, assert that the set of `(changeId, field)` equals the expected set. Also test the 26-change
  limit and the 8th-routine limit, as in Swift.
- [ ] Run `cd supabase/functions && deno test _shared/` → PASS. **Commit:** `feat(mcp): TypeScript plan validator sharing the Swift fixture`

---

### Task 2: Audit table, rate limit, config

**Files:** `supabase/migrations/20260927000001_mcp_audit.sql`, `supabase/config.toml`, `supabase/tests/database/mcp_audit.test.sql`.

```sql
create table public.mcp_audit (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  client_id text,
  tool text not null,
  ok boolean not null,
  args_digest text,
  at timestamptz not null default now()
);
create index mcp_audit_user_at on public.mcp_audit (user_id, at desc);
alter table public.mcp_audit enable row level security;
create policy mcp_audit_select on public.mcp_audit for select to authenticated using (user_id = auth.uid());
create policy mcp_audit_insert on public.mcp_audit for insert to authenticated with check (user_id = auth.uid());

-- Calls in the last minute for the caller (rate limit = 60/min, enforced in the function).
create or replace function public.mcp_calls_last_minute() returns int
language sql stable security invoker set search_path = public as $$
  select count(*)::int from public.mcp_audit where user_id = auth.uid() and at > now() - interval '1 minute'
$$;
grant execute on function public.mcp_calls_last_minute() to authenticated;
```
`config.toml`: `[functions.mcp] verify_jwt = false`; `[auth] site_url = "http://127.0.0.1:55430"`;
`additional_redirect_urls = ["https://claude.ai/api/mcp/auth_callback", "https://claude.com/api/mcp/auth_callback"]`;
`[auth.oauth_server] enabled = true, authorization_url_path = "/oauth/consent", allow_dynamic_registration = true`.
pgTAP: a user sees only their own audit rows; an MCP client can insert audit rows; `mcp_calls_last_minute()` counts.
**Commit:** `feat(db): MCP audit log and rate-limit helper`

---

### Task 3: MCP tools (pure modules + FakeDb tests)

**Files:** `functions/mcp/db.ts`, `tools/read.ts`, `tools/write.ts`, `*_test.ts`.

`db.ts` defines the `Db` interface the tools use (and nothing else):
```ts
export interface Db {
  profile(): Promise<Profile | null>
  routines(): Promise<RoutineRow[]>                 // deleted_at is null
  weekSchedule(): Promise<{ weekday: number; routine_id: string | null }[]>
  workouts(opts: { since?: string; until?: string; limit: number }): Promise<WorkoutRow[]>  // with entries+sets, newest first
  workout(id: string): Promise<WorkoutRow | null>
  exerciseSets(exerciseId: string, since?: string): Promise<{ workout_id: string; started_at: string; sets: SetRow[] }[]>
  bodyweight(since?: string): Promise<BodyweightRow[]>
  searchExercises(q: { query?: string; bodyPart?: string; equipment?: string; limit: number }): Promise<ExerciseRow[]>
  exerciseExists(ids: string[]): Promise<Set<string>>
  insertProposal(p: { summary: string; changes: unknown[] }): Promise<{ id: string; created_at: string }>
  proposal(id: string): Promise<ProposalRow | null>
  insertBodyweight(r: { id: string; measured_at: string; w_kg: number; bf_pct?: number }): Promise<void>
  audit(tool: string, ok: boolean, argsDigest: string): Promise<void>
  callsLastMinute(): Promise<number>
}
```
`SupabaseDb` implements it with the user-scoped client. Workouts use
`select('*, workout_entries(*, workout_sets(*))')` ordered by `started_at desc`. Exercise search is `ilike` on `n`
with the words ANDed, limit ≤ 50.

Tools (each returns `{ content: [{ type: 'text', text }], structuredContent? }`; the text is compact JSON, and
weights are always kg **with a `display` string in the owner's unit**, e.g. `"140 lb (63.5 kg)"`):

| Tool | Input (zod) | Output | Notes |
|---|---|---|---|
| `get_profile` | {} | unit, goal, goal date, height, limits, training days, deload, mcp flags | readOnly |
| `get_plan` | {} | routines (id, name, paused, policy, exercises: id, name, sets, reps, repsMin, weight + display) + week schedule (Mon…Sun names) | readOnly; resolves exercise names via `searchExercises`/ids |
| `list_workouts` | since?, until? (ISO dates), limit 1–60 (default 20) | [{id, date, name, duration_min, sets, volume_kg, top sets per exercise}] | readOnly; the window is capped at 12 weeks when `since` is absent |
| `get_workout` | id (uuid) | full workout with entries/sets (warm-ups flagged) | readOnly |
| `get_exercise_history` | exercise (id **or** name), since? | [{date, working sets, top weight, e1RM}] newest first, ≤ 30 sessions | readOnly; name → id via search (ambiguous → error listing candidates) |
| `get_training_summary` | weeks 1–12 (default 4) | sessions/week, volume by body part per week, PRs, stalls (same top weight and reps ≤ previous for 3 sessions), last bodyweight trend | readOnly; e1RM = Epley ≤ 12 reps, the same as Swift |
| `get_bodyweight` | since? | entries + 4-week slope kg/week | readOnly |
| `search_exercises` | query, body_part?, equipment?, limit ≤ 25 | id, name, body part, equipment, target | readOnly |
| `propose_plan_changes` | summary (1–500), changes (1–25 of PlanChange) | {proposal_id, status:"pending", applies:"when the owner reviews it in the app (or automatically if auto-apply is on)"} | **not** readOnly; validates with `validateProposal` against the current `get_plan` snapshot plus `exerciseExists`. On violations: `isError: true` with the list; nothing is inserted |
| `get_proposal` | id | status, applied change ids | readOnly |
| `log_bodyweight` | weight_kg 30–300, date?, body_fat_pct 3–60? | {id} | not readOnly; RLS enforces `mcp_read_body` |

Tool descriptions are written for Claude, e.g. `get_plan`: "Get the owner's current routines and weekly schedule.
Weights are kg with a display string in the owner's preferred unit (they load lb plates). Use routine and exercise
ids from here in propose_plan_changes." `propose_plan_changes` documents every change type with its required fields
(generated from the validator's table), and says that proposals never change anything until the owner applies them.

Tests (`tools/read_test.ts`, `tools/write_test.ts`) with a `FakeDb` built from JSON fixtures of the owner's data
(bench 12 Sep 3×6 @58.97, 19 Sep 3×10 @58.97, a pull day, and two weigh-ins):
- `get_exercise_history` by name "bench" → the 2 sessions, newest first, e1RM 78.6 and 70.8.
- `get_training_summary` weeks 4 → sessions and volume per week correct; a synthetic 3-session stall is detected.
- `propose_plan_changes` with the fixture's valid case → `insertProposal` called once, and the result has the
  proposal id. With an invalid case → `isError`, violations listed, no insert.
- `list_workouts` clamps `limit` to 60 and defaults to 12 weeks.
- Ambiguous exercise names → an error that lists candidates.
Run `deno test functions/mcp/tools/` → PASS. **Commit:** `feat(mcp): tool logic for reading training data and proposing plan changes`

---

### Task 4: MCP HTTP function (auth, transport, rate limit, audit)

**Files:** `functions/mcp/index.ts`, `auth.ts`, `tools/register.ts`, `functions/mcp/auth_test.ts`.

```ts
// index.ts (shape; see docs/research §1-3 for the APIs)
import 'jsr:@supabase/functions-js/edge-runtime.d.ts'
import { createMcpHandler, McpServer } from 'npm:@modelcontextprotocol/server@2.1.0'
import { authenticate, metadataResponse, unauthorized } from './auth.ts'
import { SupabaseDb } from './db.ts'
import { registerTools } from './tools/register.ts'

const BASE = Deno.env.get('MCP_PUBLIC_BASE_URL') ?? Deno.env.get('SUPABASE_URL')!  // public origin clients see

Deno.serve(async (req) => {
  const path = new URL(req.url).pathname.replace(/\/+$/, '')
  if (path.endsWith('/mcp/oauth-protected-resource')) return metadataResponse(BASE)
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors })
  const auth = await authenticate(req)                   // { userId, clientId, token } | null
  if (!auth) return unauthorized(BASE)
  const db = new SupabaseDb(auth.token)
  if (await db.callsLastMinute() >= 60) return new Response('Too many requests', { status: 429, headers: { 'Retry-After': '60' } })
  const handler = createMcpHandler(() => {
    const server = new McpServer({ name: 'gymrollins', version: '0.1.0' })
    registerTools(server, db)                            // each tool wrapper audits ok/error with a SHA-256 args digest
    return server
  })
  return handler.fetch(req)
})
```
- `metadataResponse(base)` → JSON `{ resource: base + '/functions/v1/mcp', authorization_servers: [base + '/auth/v1'], scopes_supported: ['email', 'profile'], bearer_methods_supported: ['header'], resource_name: 'GymRollins' }`.
- `unauthorized(base)` → 401 with `WWW-Authenticate: Bearer resource_metadata="<base>/functions/v1/mcp/oauth-protected-resource"`
  and a JSON error body.
- `authenticate` extracts `Authorization: Bearer`, calls `createClient(url, anon).auth.getUser(token)`, and reads
  `client_id` from the JWT payload (base64url decode; the signature has already been verified by getUser).
- Errors inside tools are logged with `console.error(requestId, tool, err.message)` and returned as `isError` with a
  generic message. Stack traces and personal data never go to the client.
- `auth_test.ts`: a missing or invalid token → 401 with the exact header; the metadata document has the fields
  above; tokens with and without `client_id` both parse.
- Run locally: `npx supabase functions serve mcp --no-verify-jwt --env-file supabase/.env.local`.
  **Commit:** `feat(mcp): Streamable HTTP MCP endpoint with OAuth discovery, auth, rate limit and audit`

---

### Task 5: HTTP end-to-end tests for MCP

**Files:** `functions/mcp/http_test.ts`, `scripts/test-mcp.sh`.

`scripts/test-mcp.sh`: run `scripts/supabase-up.sh`, start `functions serve` in the background (wait until the
metadata URL responds), then `deno test -A functions/` (unit + HTTP), and stop the server on exit.

`http_test.ts` (skips when `MCP_E2E_URL` is unset):
1. Create two users with the admin API (the service key from `supabase/.env.local`, test-only) and get user tokens
   with `signInWithPassword`. Seed user A: profile, a routine "Push + Arms" with bench (`0025`), a workout with 3
   bench sets, and a weigh-in, all through the user-scoped client/RPC as the app would.
2. Without a token: POST initialize → 401 and the `WWW-Authenticate` metadata pointer. GET the metadata → 200 JSON.
3. With A's token: `initialize` (JSON-RPC over POST with `Accept: application/json, text/event-stream`), then
   `tools/list` contains the 11 tools with annotations; `get_plan` returns the routine; `get_exercise_history`
   ("barbell bench press") returns 1 session; `propose_plan_changes` (valid, `weight` change on bench) returns a
   proposal id, and the proposal row exists with status pending; an invalid proposal returns `isError`.
4. With B's token: `get_workout(A's id)` → not found (RLS).
5. MCP-client token simulation: a DB-level check that a JWT with a `client_id` can't write routines is covered by
   plan 05 pgTAP. Here, assert the audit rows exist for A's calls.
6. 61 rapid calls → the last returns 429.
Run `scripts/test-mcp.sh` → PASS. **Commit:** `test(mcp): HTTP end-to-end tests against local Supabase`

---

### Task 6: OAuth consent page (static)

**Files:** `web/consent/index.html`, `consent.js`, `style.css`, `scripts/consent-server.mjs`.

- The page implements Supabase's flow (research §5): read `authorization_id` from the query string. If there's no
  session, show a sign-in form (email/password locally; a "Sign in with Apple" button is rendered only when
  `window.GYM_APPLE_ENABLED`, which the cloud build sets). After sign-in, call
  `supabase.auth.oauth.getAuthorizationDetails(id)`. If the result is a redirect, go there. Otherwise show the
  client name, the redirect host and what access means ("Claude will be able to read your workouts and bodyweight and
  propose plan changes; nothing changes until you apply it in the app"), with Approve and Deny buttons →
  `approveAuthorization` / `denyAuthorization` → `location.href = redirect_url`.
- Style: the dark theme tokens from `docs/design/STYLE.md`.
- `supabase-js` is loaded from `https://esm.sh/@supabase/supabase-js@2.117.2` (pinned). The config (url, anon key)
  is injected by `consent-server.mjs` as `window.GYM_CONFIG` from `supabase/.env.local`.
- `consent-server.mjs`: a Node `http` server on 127.0.0.1:55430 serving `web/consent/*`, mapping `/oauth/consent`
  to `index.html`, with `Content-Security-Policy: default-src 'self' https://esm.sh; connect-src http://127.0.0.1:55421`.
- **Manual local check** (document it in README; the full Claude handshake is cloud-only): register a test OAuth
  client via DCR with curl (`POST /auth/v1/oauth/clients/register` with the redirect `http://127.0.0.1:8976/cb`), open
  `http://127.0.0.1:55421/auth/v1/oauth/authorize?...&code_challenge=...` in Safari, sign in on the consent page,
  approve, see the redirect with `code=`, exchange it at `/auth/v1/oauth/token`, and call the MCP `tools/list` with
  the resulting token. Script this as `scripts/oauth-local-smoke.sh`, which automates everything except the browser
  click (it prints the authorize URL, waits for the code on a tiny local listener, then exchanges and calls
  tools/list).
- **Commit:** `feat(auth): static OAuth consent page and local OAuth smoke script`

---

### Task 7: PlanChangeApplier (GymCore) and proposals in GymData/GymSync

**Files:** `GymCore/Plan/PlanChangeApplier.swift` (+ tests), `GymData/Records/ProposalRecord.swift`,
`GymData/Repositories/ProposalRepository.swift` (+ tests), GymSync proposal pull/resolve wiring (+ tests).

- `PlanChangeApplier.apply(_ changes: [PlanChange], to plan: PlanState, now: Date) throws -> PlanState` where
  `PlanState { routines: [Routine]; schedule: [Int: UUID] }`. Every change type from the validator is implemented
  purely. `weight` sets `weightSetAt = now` (so the progression engine treats it as planned). `add-routine` uses
  `UUID(uuidString: routineId)` or a new UUID mapped in a table for later changes in the same batch.
  `pause-routine`, `week` and the others are straightforward. Throws `PlanApplyError.invalid(changeId)` when a
  reference is missing (defense in depth; the validator runs first). Tests: one per change type, plus applying the
  fixture's "valid knee-break proposal" to a matching `PlanState` gives the expected routines/schedule, and
  applying a subset of changes (toggles) works.
- `ProposalRecord` (SwiftData): id, createdAt, summary, changesData (JSON `[PlanChange]`), statusRaw,
  appliedChangeIds, snapshotData (encoded `PlanState` before apply), resolvedAt, serverUpdatedAt, dirty.
  `ProposalRepository`: `upsertRemote`, `pending()`, `markApplied(id, changeIds, snapshot)`, `dismiss(id)`,
  `undo(id) -> PlanState?` (only within 7 days), `dirty()`/`markSynced`. Tests cover each.
- GymSync: the pull includes `proposals` (status pending or recently resolved). The push sends status/applied ids
  via `resolveProposal`. `SyncEngine` after pull: if `profile.mcpAutoApply`, then for each pending proposal validate
  with `PlanChangeValidator` against the current plan, apply all valid changes, record a snapshot, mark applied,
  and sync the routines. Tests with FakeTransport: a pulled proposal appears pending; auto-apply on → routines change
  and the status goes to applied on the next push.
- **Commit:** `feat(proposals): apply Claude proposals on device with snapshot undo and auto-apply`

---

### Task 8: Claude screens in the app

**Files:** `Features/Claude/ClaudeConnectionView.swift`, `ProposalReviewView.swift`, `ProposalModel.swift`
(+ `GymRollinsTests/ProposalModelTests.swift`), UI test `ProposalUITests.swift`. **Mockups:**
`Claude.dc.html`, `ConnectClaude.dc.html`, `Proposal.dc.html`.

- `ProposalModel` (pure): turns a `PlanChange` plus the current plan and library into a row: type label ("Swap",
  "Sets", "Weight", "Schedule"…), "before → after" text in the owner's unit (e.g. "Bench Press 3 × 10 @ 130 lb →
  3 × 8 @ 140 lb"), and the reason. Unit-test every change type's text.
- **ProposalReviewView** (`proposal.review`): header with the date, "From Claude", and the summary. A solid card per
  change with a glass toggle (`proposal.change.<id>`, all on by default). The floating glass bar has "Dismiss all"
  `proposal.dismiss` and a prominent "Apply N changes" `proposal.apply`. The note: "A snapshot is saved; you can
  undo for 7 days." After applying, a toast offers "Undo" `proposal.undo`. Invalid changes (validator violations
  against the current plan) are shown disabled with the reason.
- **Today**: a glass chip "Plan change from Claude" (`today.proposal`) when a proposal is pending → review.
- **ClaudeConnectionView** (reached from Log's gear/Account until plan 07's Settings; identifier `claude.view`):
  - connector URL (`<SUPABASE_URL>/functions/v1/mcp`) with Copy (`claude.copyURL`), and the 3 steps for Claude
    (Settings → Connectors → Add custom connector → paste → approve);
  - a status line ("Last used 26 Sep" from the newest `mcp_audit` row via a small transport call, or "Not connected
    yet");
  - permission toggles bound to the profile's `mcpReadWorkouts`, `mcpReadBody`, `mcpPropose` and `mcpAutoApply`
    (`claude.perm.*`), saved to the profile (which syncs);
  - pending proposals list → review;
  - "Disconnect Claude" `claude.disconnect`: turns every permission off and explains how to remove the connector in
    Claude.
- **UI tests** (`ProposalUITests`, hermetic, no backend): launch with `-uiTesting -seedProposal` (new DEBUG launch
  flag: inserts a pending `ProposalRecord` with the fixture's knee-break changes, mapped to the seeded routine ids).
  Then: `today.proposal` → review shows 4 change cards → toggle one off → Apply 3 → Today's bench shows the new
  weight → Undo → the old weight is back. Also: Dismiss all → the chip disappears. Also: auto-apply toggle →
  relaunch with the seed → the chip doesn't appear and the plan is already changed.
- **Commit:** `feat(app): Claude connection screen and proposal review with apply/undo`

---

### Task 9: Verify, review, cloud checklist, merge

- [ ] `scripts/test-all.sh`, `scripts/test-db.sh`, `scripts/test-mcp.sh` green; `swiftlint` has 0 errors;
  `deno lint supabase/functions` is clean.
- [ ] Security review (security-reviewer agent) of `supabase/functions/mcp`, the consent page and the migrations:
  token handling, RLS reliance, no service key in tool paths, input validation, rate limiting, audit, CSP on the
  consent page, no PII in logs. Fix CRITICAL/HIGH.
- [ ] `codex review --base main`; fix P0–P2.
- [ ] Write `docs/cloud-checklist.md`: create the Supabase project (owner approval required), set asymmetric JWT
  signing keys, enable the OAuth server + DCR, set `site_url` to the hosted consent page (static host), set the
  Apple provider (Services ID, key), deploy migrations and the `mcp` function, set `MCP_PUBLIC_BASE_URL`, add the
  connector in Claude (claude.ai → Settings → Connectors → Add custom connector →
  `https://<ref>.supabase.co/functions/v1/mcp`), approve, and ask Claude "What did I bench last week?" and "Propose
  a lighter upper day". Also: point the app's `Local.xcconfig` `SUPABASE_URL`/`SUPABASE_ANON_KEY` at the cloud
  project.
- [ ] Merge with `--no-ff`, then delete the branch.
