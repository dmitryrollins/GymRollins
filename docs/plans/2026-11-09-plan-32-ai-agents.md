# Plan 32: AI agents — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Any connected agent (Claude, Meta's Muse, …) shows up in the app with its own Disconnect, proposals say which agent sent them, and agents can add past workouts straight into history behind an "Add workouts" switch.

**Architecture:** Server first (Tasks S1–S11): migration 0011 adds `profiles.mcp_log_workouts`, `workouts.added_by` and `proposals.from_agent`; `GET /v1/agents` and `POST /v1/agents/:clientId/disconnect` sit beside `/v1/claude/*`; the MCP tool `log_workout` writes through the same SQL as the workout sync. Then the app (Tasks A1–A16): GymData and GymSync learn the three fields and the two calls, and Settings › Claude becomes Settings › AI agents with the per-agent list.

**Tech Stack:** Cloudflare Workers + Hono + D1 + Better Auth 1.7.18 (server/, vitest with @cloudflare/vitest-plugin); SwiftUI + SwiftData, xcodegen, Swift Testing and XCTest UI tests (ios/).

**Spec:** `docs/specs/2026-11-09-ai-agents-design.md` (owner-approved 2026-11-09). **Branch:** `feat-ai-agents`, from `main`.

---

## How to run this plan

- **Order:** S1 → S11, then A1 → A16. The app half relies on the server half's wire names (both halves list theirs in
  "Server facts" and "App facts" below; the integrator checked they match). A15 needs the server half done.
- **Server checks** after each server task: `cd server && npx vitest run && npx tsc --noEmit`.
- **App checks:** each app task names its command; A16 runs everything.
- **Commits:** one or more per task, with the messages given. No Co-Authored-By, "Generated with" or session trailers.
- **Local only.** No `wrangler deploy`, no `--remote` command, no install on the owner's phone inside this plan. The
  rollout (spec section 6) is done afterwards with the owner's approval for each step: a Time Travel bookmark, `npx
  wrangler d1 migrations apply gymrollins --remote`, the deploy, a phone backup, then the install.
- **Never** open or print `ios/Config/Local.xcconfig` or `server/.dev.vars`.

## Integrator's changes to the drafts (2026-11-09)

1. `log_workout` takes **at most 5 workouts per call** (the drafts said 20). The Free plan allows about 50 D1 queries per
   Worker invocation; a 5-workout call makes about 12 even if every statement of a batch counted on its own.
2. Task S10 gains Step 4b: the server's own text names **Settings › AI agents** (the `/connect` page, `SERVER_INSTRUCTIONS`
   and two comments), because Task A10 renames the screen.
3. Left for later, not in this plan: Claude-worded lines on Today's chip and in the approve sheet's result lines (the
   app half's open questions), and computing personal records for agent-added workouts (they arrive with `records: []`).

---

# Plan 32, server half: AI agents (per-agent list and disconnect, proposals by agent, log_workout)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the Worker treats the MCP connector as any agent's, not only Claude's. The app can list the connected agents
and disconnect one; a proposal says which agent sent it; and an agent can add past workouts straight to the history
with a new tool, `log_workout`, behind a new "Add workouts" switch that is off by default.

**Spec:** `docs/specs/2026-11-09-ai-agents-design.md`, sections 3 (server), 5 (testing, server part) and 6 (rollout).
Section 4 (the app) is the other half of this plan.

**Tech stack:** as plans 26–31. The Worker (Hono 4.13.17, Better Auth 1.7.18 with `@better-auth/oauth-provider` 1.7.18,
D1 through wrangler 4.158.0, zod 4.6.7, `@modelcontextprotocol/server` 2.4.0, Vitest 4.1.12 with
`@cloudflare/vitest-plugin` 1.6.0 in workerd).

**Branch:** `feat-ai-agents`.
- No push. Local only: never run `wrangler login`, `wrangler deploy`, or any `wrangler` command without `--local`.
  Task S11 only writes the deploy steps down; the owner runs them.
- Commit messages have no `Co-Authored-By`, `Generated with` or `Claude-Session` trailers; the owner forbids them.

**Not in this plan:** per-agent switches; approve-before-adding for agent workouts; agents editing or deleting past
workouts; renaming the `/v1/claude/*` routes; the 5 unused test registrations (spec section 7).

---

## Server facts

The names the app half relies on, each read in the code (paths are `server/…`):

- **Migration:** `migrations/0011_ai_agents.sql` (the latest before it is `0010_account_caps.sql`). Three `ALTER TABLE
  … ADD COLUMN`s: `profiles.mcp_log_workouts`, `workouts.added_by`, `proposals.from_agent`, exactly as the contract has
  them.
- **The switch on the wire:** `mcp_log_workouts`, a JSON boolean, both ways, encoded like `mcp_read_body`
  (`src/sync/entities.ts`, kind `bool`: the app sends `true`/`false`, D1 stores 1/0, a pull answers `true`/`false`,
  `src/sync/columns.ts` `wireValue`). One difference: a push may leave it out (or send null) and it is stored as
  `false`, where the other switches are required. See decision 1.
- **Workout pulls:** `GET /v1/sync/workouts` and `GET /v1/sync/workouts/:id` carry `added_by` on every workout (a
  string, or `null`), beside `updated_at`. A push (`POST /v1/sync/workouts`) never sets it: a key `added_by` in the
  body is ignored (`storedRow` reads only its columns), and the upsert never updates it, so an edit from the app keeps
  an agent's name.
- **Proposals:** `GET /v1/claude/proposals` rows carry `from_agent` (a string, or `null`). There is no other proposal
  pull or sync: `pendingProposals` (`src/claude/proposals.ts`) is the only reader the app has
  (`src/claude/routes.ts`, `GET /proposals`).
- **`GET /v1/agents`** (behind `requireUser`, like `/v1/claude/*`; 401 `signed_out` without the app's session):
  `{"agents": [{"client_id", "name", "host", "known_host", "connected_at", "last_used_at"}]}`, newest `connected_at`
  first, ties by `client_id`.
  - `name`: `oauthClient.name` (Better Auth stores `client_name` there), else `host`.
  - `host`: `new URL(first redirect URI).host`, the same as the approve sheet's `redirect_host`
    (`src/claude/connect-page.ts`), so a loopback client's host keeps its port (`127.0.0.1:33418`).
  - `known_host`: `CLAUDE_HOSTS.has(host)`, the one set now in `src/claude/hosts.ts` (moved out of
    `src/claude/routes.ts`).
  - `connected_at`: the consent's `createdAt`, else the earliest refresh token's, in the server's stored form
    `YYYY-MM-DDTHH:MM:SS.ffffffZ` (Better Auth stores `toISOString()` text; `normalizeTimestamp` makes it six digits).
  - `last_used_at`: `max(mcp_audit.at)` for (user, client), already in the stored form, or `null`.
- **`POST /v1/agents/:clientId/disconnect`:** 200 `{"disconnected": true}`; 404
  `{"error": {"code": "unknown_agent", "message": "No agent with this id is connected to your account."}}`.
- **The verification JSON key that names the client:** `$.query.client_id`. Better Auth 1.7.18 writes a code's row as
  `{type: 'authorization_code', query: <the authorize query, with client_id>, userId, sessionId, …}`
  (`node_modules/@better-auth/oauth-provider/dist/authorize-BzDrbYtI.mjs`, `redirectWithAuthorizationCode`, about
  line 8474) and checks `verificationValue.query.client_id` on redemption (same file, `checkVerificationValue`, about
  line 2097). Task S6's test counts a code by that key before the disconnect, so a wrong key fails it.
- **Other stored forms:** `oauthClient.redirectUris` is JSON array text (`@better-auth/core`
  `dist/db/adapter/factory.mjs`, `string[]` without array support → `JSON.stringify`); every Better Auth date is
  `toISOString()` text (same file; `@better-auth/kysely-adapter` sets `supportsDates: false` for SQLite). Client ids
  are 32 letters (`authorize-BzDrbYtI.mjs`, `generateRandomString(32, "a-z", "A-Z")`).
- **`log_workout`:** input `{ workouts: [1..5] }`, each `{ started_at, ended_at, name?, note?, exercises: [ {
  exercise_id, sets: [ { reps, weight_kg, sec?, dist_m?, warmup? } ] } ] }`. Result
  `{ "results": [ { index, status: "added", workout_id } | { index, status: "refused", reason, message } ] }`,
  `isError: true` when nothing was added. Reasons: `not_allowed`, `invalid`, `unknown_exercise`, `overlaps`,
  `too_many_workout_exercises`, `too_many_exercise_sets`, `too_many_workouts`, `too_many_logged_exercises`,
  `too_many_logged_sets`.
- **What an added workout looks like in a pull:** `source: "import"`, `added_by:` the client's name or `"Agent"`,
  `routine_id`, `gym_id` null, `paused_sec` 0, `vol_kg` the working sets' weight × reps, `records: []`, every set
  `done: true`, `multiplier: 1`, `completed_at: null`; server `updated_at`, so the next pull brings it.
- **`get_profile`'s `permissions`** gains `log_workouts` (boolean). `tools/list` has 16 tools.
- **Code names used below:** `pushWorkout`, `pullWorkouts`, `fetchWorkout`, `parseWorkout`, new `addWorkout` and
  `writeSave` (`src/sync/workouts.ts`); `D1Db` (`src/mcp/d1-db.ts`) with `allowed()`, `insertProposal`, and new
  `mayLogWorkouts`, `loggableExerciseIds`, `agentName`, `workoutTimes`, `insertWorkout`; `revokeClaude`
  (`src/claude/revoke.ts`, unchanged: Disconnect all); `ApiError`, `raisedCode`, `constraintMessage`
  (`src/http/errors.ts`); `CLAUDE_CAPS`, `grouped`, new `AGENT_WORKOUT_CAPS` (`src/sync/caps.ts`). Test helpers:
  `connectClaude`, `registerClient`, `register`, `startFlow`, `Browser`, `openConnect`, `decideCode`,
  `finishInBrowser`, `exchangeCode`, `refresh`, `mcp`, `LOOPBACK`, `CLAUDE_AI` and new `connectAgent`,
  `AGENT_CALLBACK` (`test/claude.ts`); `request`, `signUp` (`test/helpers.ts`); `seedRows`, `countOf`, `kept`,
  `seedCount` (`test/cap-fixtures.ts`); `readRpc`, `toolJson` (`test/mcp/rpc.ts`); `SAMPLES`, `workoutSample`, `T2`
  (`test/samples.ts`).

## Decisions this plan makes

1. **`mcp_log_workouts` may be missing from a profile push, and is then stored off.** Every other profile column is
   required (`col(…)` in `src/sync/entities.ts`; `storedValue` throws `… is required`). The Worker deploys before the
   app (`docs/cloudflare-checklist.md`, section 4, "Order"), and the phone's build sends no such key, so a required
   column would refuse every profile push with 422 until the new build is installed. The column gets
   `fallback: false`, the column's own default. An old build's push stores off; it can't show the switch anyway.
2. **Set field names: `reps`, `weight_kg`, `sec`, `dist_m`, `warmup`.** The sync stores a set as `r`, `w_kg`, `sec`,
   `dist_m`, `warmup` (`src/sync/workouts.ts`, `SET`), and `get_workout` answers sets as `reps`, `weight_kg`, `sec`,
   `dist_m`, `warmup` (`src/mcp/tools/read.ts`, `setDetail`). The spec's `duration_s` and `distance_m` are neither:
   the tool takes the sync's own `sec` and `dist_m`, and keeps the spec's `reps` and `weight_kg`, which are also
   `get_workout`'s, so an agent writes sets the way it reads them. Mapping: `reps → r`, `weight_kg → w_kg`,
   `sec → sec`, `dist_m → dist_m`, `warmup → warmup`; the server adds `done: true`, `multiplier: 1`. Ranges are
   `DomainLimits`' (`setReps` 0–1,000 whole, `setWeightKg` 0–1,000, `setSeconds` 0–86,400 whole, `setDistanceM`
   0–1,000,000), the same as the D1 CHECKs the sync relies on.
3. **`log_workout` writes through the app's own save, minus its reads.** `addWorkout` (new, `src/sync/workouts.ts`)
   runs `parseWorkout` (column checks and the per-workout caps) and the same batch as `pushWorkout`, now one function
   `writeSave`, so the account caps' triggers, the logged-exercise and set counts (`MOVE_ENTRIES`, `MOVE_SETS`) and the
   entries and sets SQL are shared, not copied. It skips `pushWorkout`'s read of the stored row, its gym and its
   listings: the id is new and an agent's workout has neither. That keeps one D1 query per workout; a 5-workout call
   makes about 12 (token, rate slot, switch, exercises, history, name, 5 batches, audit), under the Free plan's 50
   queries per invocation, if a batch counts as one (Uncertain, see the end).
4. **`added_by` is written on insert only.** The upsert binds it as `?18` in `VALUES` and leaves it out of
   `DO UPDATE SET`, so the app's saves (`?18` null) never change it, and an agent's save can't rename an app workout.
5. **Overlaps.** A new workout is `[started_at, ended_at)`. A stored workout with no end, or one ending at or before
   its start (Fitbod and FitNotes imports have no end), is the moment it started: it blocks a new workout that
   contains that moment. Workouts that only touch (one ends as the other starts) don't overlap. The history is read
   once a call: workouts that aren't deleted and start from 24 hours before the earliest new start up to the latest
   new end (`workouts_user_started`). An agent's workout may last at most 24 hours (`invalid` otherwise), so that
   window holds every stored workout that can overlap, except an app workout over 24 hours long that started earlier.
   Two calls at the same moment could both add a copy; the check is not a lock.
6. **The checks run in this order for each workout:** `invalid` (times, name, note, set values, an empty workout or
   exercise) and the per-workout caps, then `unknown_exercise`, then `overlaps`, then the write (the account caps).
   `not_allowed` refuses every workout after reading only the switch.
7. **What the checks read regardless of the read switches.** `unknown_exercise` checks the owner's custom exercises
   even with "Read plan" off, and `overlaps` reads workout times even with "Read workouts" off. The agent learns only
   that its own ids exist and that a time is taken; refusals name no stored workout.
8. **A call that adds nothing is an error.** The result keeps its `results` shape, with `isError: true`, so the audit
   row records `ok = 0` (as a refused `log_bodyweight` does) and the client sees a failed call.
9. **A workout may end at most 5 minutes past the server's clock** (`END_SLACK_MS`): the agent's clock may run ahead.
10. **The disconnect's 404 comes from its own batch:** it answers 404 when the deletes of access tokens, refresh
    tokens and the consent changed nothing. The batch still clears that client's leftover codes, `connect_requests`
    rows and `/connect` sessions for the account, which are dead without a consent anyway. `/connect` sessions are
    found through `connect_requests.session_id` and through the codes' `$.sessionId`, and only marked ones
    (`claudeConnect = 1`) are deleted.
11. **The agent's name** is `oauthClient.name` when it holds 1 to 64 characters (registration takes at most 64,
    `CLIENT_NAME_MAX` in `src/auth/routes.ts`), else null; `from_agent` stores null then, `added_by` stores `Agent`.
12. **Wording (spec 3.6).** Tool descriptions and refusals say "agents". `src/mcp/tools/gyms.ts`'s "under Claude in the
    GymRollins app" names the screen, so it becomes "under AI agents". `SERVER_INSTRUCTIONS` stays as it is, as the
    contract says, though its last-but-one line names "Settings › Claude" (resolved: Task S10, Step 4b renames it).

## File map

| File | Change | Task |
|---|---|---|
| `server/migrations/0011_ai_agents.sql` | Create: the three columns | S1 |
| `server/test/ai-agents-schema.test.ts` | Create: the columns' defaults and CHECKs | S1 |
| `server/src/sync/entities.ts`, `server/test/samples.ts` | The profile switch | S2 |
| `server/test/agents-sync.test.ts` | Create: the switch (S2); `added_by` in pulls (S3) | S2, S3 |
| `server/src/sync/workouts.ts` | `added_by` pulled (S3); `addWorkout`, `writeSave`, `?18` (S7) | S3, S7 |
| `server/test/sync-workouts.test.ts` | `added_by` in the pulled shape | S3 |
| `server/src/mcp/d1-db.ts` | `from_agent` (S4); the log_workout data (S7); `get_profile`'s switch (S8); `workoutTimes` (S9); wording (S10) | S4, S7–S10 |
| `server/src/claude/proposals.ts`, `server/test/claude-proposals.test.ts` | `from_agent` served | S4 |
| `server/test/claude.ts` | `connectAgent`, `AGENT_CALLBACK` | S4 |
| `server/test/proposals-from-agent.test.ts` | Create | S4 |
| `server/src/claude/hosts.ts`, `server/src/claude/agents.ts`, `server/src/claude/agent-routes.ts` | Create: the list (S5), the disconnect (S6) | S5, S6 |
| `server/src/claude/routes.ts`, `server/src/index.ts` | The shared hosts; the route | S5 |
| `server/test/agents.test.ts` | Create: the list (S5); the disconnect (S6) | S5, S6 |
| `server/src/sync/caps.ts` | `AGENT_WORKOUT_CAPS` | S7 |
| `server/src/mcp/db.ts`, `server/test/mcp/fake-db.ts` | The Db's new methods and types | S7–S9 |
| `server/test/mcp/d1-workouts.test.ts` | Create | S7 |
| `server/test/mcp/d1-db.test.ts` | The write surface | S7 |
| `server/src/mcp/tools/log-workout.ts`, `server/src/mcp/tools/schemas.ts`, `server/src/mcp/tools/register.ts` | The tool | S8, S9 |
| `server/src/mcp/tools/read.ts`, `server/test/mcp/tools/read.test.ts` | `get_profile` shows the switch | S8 |
| `server/test/mcp/tools/log-workout.test.ts`, `server/test/log-workout.test.ts` | Create | S8, S9 |
| `server/test/mcp/app.test.ts`, `server/test/claude-connection.test.ts` | 16 tools | S8 |
| `server/src/mcp/tools/insights.ts`, `strength.ts`, `gyms.ts`, `server/test/mcp/agent-wording.test.ts` | Wording | S10 |
| `server/README.md`, `docs/cloudflare-checklist.md` | Docs | S11 |

## How to run things

```bash
cd server && npx vitest run test/<file>.test.ts    # one file; ignore the punycode DEP0040 warning
cd server && npx vitest run && npx tsc --noEmit    # everything
```

- The base (`de2bda6` on `feat-ai-agents`) is `Test Files  47 passed (47)`, `Tests  688 passed (688)`. Each task names
  the totals it ends at. If the base differs, add this plan's new tests to the base you find, and say so in the
  Outcome.
- The tests that connect agents print many `Called .text() on an HTTP body which does not appear to be text` console
  warnings (Better Auth reading the token request). They are harmless; `claude-connection.test.ts` prints them today.
- The code and tests below were built and run task by task, in this order, on a copy of `server/` at the base. The
  failures quoted are what those runs printed (S7's Step 2 and S8's Step 3 were written from the code, not run), and
  the suite ended at `Test Files  55 passed (55)`, `Tests  742 passed (742)`, with `tsc` clean.
- Reviews, as plan 31: after each task a fresh **code-reviewer** (spec and plan) and **typescript-reviewer**;
  **security-reviewer** after S6 and S9.

---

### Task S1: The three columns (migration 0011)

**Files:**
- Create: `server/migrations/0011_ai_agents.sql`
- Test: `server/test/ai-agents-schema.test.ts`

- [ ] **Step 1: Write the failing test**

`server/test/ai-agents-schema.test.ts`:

```ts
// Plan 32's columns (migrations/0011_ai_agents.sql): the Add workouts switch is off unless the owner turns it on, and
// the names of the agent that added a workout or sent a proposal hold 1 to 64 characters, or nothing.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { signUp } from './helpers.ts'

const T = '2026-11-09T10:00:00.000000Z'
const CHECK = /CHECK constraint failed/

async function newWorkout(userId: string, addedBy: string | null) {
  await env.DB.prepare(
    'INSERT INTO workouts (id, user_id, started_at, name, client_updated_at, updated_at, added_by) ' +
      "VALUES (?1, ?2, ?3, 'Upper', ?3, ?3, ?4)",
  ).bind(crypto.randomUUID(), userId, T, addedBy).run()
}

async function newProposal(userId: string, fromAgent: string | null) {
  await env.DB.prepare(
    'INSERT INTO proposals (id, user_id, created_at, summary, changes, client_updated_at, updated_at, from_agent) ' +
      `VALUES (?1, ?2, ?3, 'Bench', '[{"id":"c1"}]', ?3, ?3, ?4)`,
  ).bind(crypto.randomUUID(), userId, T, fromAgent).run()
}

describe('migration 0011', () => {
  it('stores a profile with Add workouts off, and only 0 or 1', async () => {
    const { userId } = await signUp()
    await env.DB.prepare('INSERT INTO profiles (user_id, client_updated_at, updated_at) VALUES (?1, ?2, ?2)')
      .bind(userId, T).run()
    const row = await env.DB.prepare('SELECT mcp_log_workouts FROM profiles WHERE user_id = ?1').bind(userId).first()
    expect(row).toEqual({ mcp_log_workouts: 0 })
    const set = (value: unknown) =>
      env.DB.prepare('UPDATE profiles SET mcp_log_workouts = ?2 WHERE user_id = ?1').bind(userId, value).run()
    await expect(set(1)).resolves.toBeTruthy()
    await expect(set(2)).rejects.toThrow(CHECK)
    await expect(set(null)).rejects.toThrow(/NOT NULL constraint failed/)
  })

  it("takes a workout's added_by of 1 to 64 characters or none", async () => {
    const { userId } = await signUp()
    await expect(newWorkout(userId, null)).resolves.toBeUndefined()
    await expect(newWorkout(userId, 'M')).resolves.toBeUndefined()
    await expect(newWorkout(userId, 'é'.repeat(64))).resolves.toBeUndefined()
    await expect(newWorkout(userId, '')).rejects.toThrow(CHECK)
    await expect(newWorkout(userId, 'x'.repeat(65))).rejects.toThrow(CHECK)
  })

  it("takes a proposal's from_agent of 1 to 64 characters or none", async () => {
    const { userId } = await signUp()
    await expect(newProposal(userId, null)).resolves.toBeUndefined()
    await expect(newProposal(userId, 'Muse')).resolves.toBeUndefined()
    await expect(newProposal(userId, 'é'.repeat(64))).resolves.toBeUndefined()
    await expect(newProposal(userId, '')).rejects.toThrow(CHECK)
    await expect(newProposal(userId, 'x'.repeat(65))).rejects.toThrow(CHECK)
  })

  it('leaves added_by and from_agent empty when a row names neither', async () => {
    const { userId } = await signUp()
    await env.DB.prepare(
      "INSERT INTO workouts (id, user_id, started_at, name, client_updated_at, updated_at) VALUES (?1, ?2, ?3, 'A', ?3, ?3)",
    ).bind(crypto.randomUUID(), userId, T).run()
    await env.DB.prepare(
      'INSERT INTO proposals (id, user_id, created_at, summary, changes, client_updated_at, updated_at) ' +
        `VALUES (?1, ?2, ?3, 'Bench', '[{"id":"c1"}]', ?3, ?3)`,
    ).bind(crypto.randomUUID(), userId, T).run()
    const row = await env.DB.prepare(
      'SELECT (SELECT added_by FROM workouts WHERE user_id = ?1) AS added_by, ' +
        '(SELECT from_agent FROM proposals WHERE user_id = ?1) AS from_agent',
    ).bind(userId).first()
    expect(row).toEqual({ added_by: null, from_agent: null })
  })
})
```

`'é'.repeat(64)` is 64 characters and 128 bytes: SQLite's `length()` counts characters, as registration's
`CLIENT_NAME_MAX` does.

- [ ] **Step 2: Run it to see it fail**

Run: `cd server && npx vitest run test/ai-agents-schema.test.ts`
Expected: FAIL, 4 failed: `no such column: mcp_log_workouts`, `table workouts has no column named added_by`,
`table proposals has no column named from_agent`, `no such column: added_by`.

- [ ] **Step 3: Write the migration**

`server/migrations/0011_ai_agents.sql`:

```sql
-- Plan 32 (docs/specs/2026-11-09-ai-agents-design.md, section 3.5): the connector serves any agent, not only Claude.
-- Each column is added with its default, so the rows already stored are valid as they are.

-- The "Add workouts" switch (log_workout), off until the owner turns it on. Synced with the profile like the other
-- mcp_* switches (src/sync/entities.ts).
ALTER TABLE profiles ADD COLUMN mcp_log_workouts INTEGER NOT NULL DEFAULT 0 CHECK (mcp_log_workouts IN (0,1));

-- The agent that added a workout with log_workout: its registered name, or 'Agent'. Null for every other workout.
-- The server sets it when the workout is added; a save from the app never changes it (src/sync/workouts.ts).
ALTER TABLE workouts ADD COLUMN added_by TEXT CHECK (added_by IS NULL OR length(added_by) BETWEEN 1 AND 64);

-- The agent that sent a proposal (its registered name, when it gave one). Null for proposals from before this.
ALTER TABLE proposals ADD COLUMN from_agent TEXT CHECK (from_agent IS NULL OR length(from_agent) BETWEEN 1 AND 64);
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd server && npx vitest run test/ai-agents-schema.test.ts test/schema.test.ts`
Expected: PASS, `Tests  29 passed (29)` (the GLOB-length check in `schema.test.ts` reads the new migration too).

- [ ] **Step 5: Everything**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  48 passed (48)`, `Tests  692 passed (692)`; `tsc` prints nothing.

- [ ] **Step 6: Commit**

```bash
git add server/migrations/0011_ai_agents.sql server/test/ai-agents-schema.test.ts
git commit -m "feat(server): migration 0011 adds the Add workouts switch, added_by and from_agent"
```

---

### Task S2: The Add workouts switch syncs with the profile

**Files:**
- Modify: `server/src/sync/entities.ts`, `server/test/samples.ts`
- Test: `server/test/agents-sync.test.ts`

- [ ] **Step 1: Write the failing tests**

`server/test/agents-sync.test.ts`:

```ts
// What plan 32 adds to sync (docs/specs/2026-11-09-ai-agents-design.md, section 3.5): the Add workouts switch on the
// profile, and the agent a workout was added by.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { request, signUp } from './helpers.ts'
import { type Row, SAMPLES, T2 } from './samples.ts'

async function pushProfile(token: string, row: Row): Promise<Response> {
  return await request('POST', '/v1/sync/profile', { token, body: { rows: [row] } })
}

async function pulledProfile(token: string): Promise<Row> {
  const res = await request('GET', '/v1/sync/profile', { token })
  expect(res.status).toBe(200)
  const { rows } = await res.json<{ rows: Row[] }>()
  expect(rows).toHaveLength(1)
  return rows[0]!
}

describe('the Add workouts switch', () => {
  it('syncs as mcp_log_workouts, a boolean, like the other switches', async () => {
    const { token, userId } = await signUp()
    expect((await pushProfile(token, { ...SAMPLES.profile(), mcp_log_workouts: true })).status).toBe(200)
    expect(await pulledProfile(token)).toMatchObject({ mcp_log_workouts: true, mcp_read_body: false })
    const stored = await env.DB.prepare('SELECT mcp_log_workouts FROM profiles WHERE user_id = ?1').bind(userId).first()
    expect(stored).toEqual({ mcp_log_workouts: 1 })
    const off = { ...SAMPLES.profile(), mcp_log_workouts: false, client_updated_at: T2 }
    expect((await pushProfile(token, off)).status).toBe(200)
    expect((await pulledProfile(token)).mcp_log_workouts).toBe(false)
  })

  it("takes the profile of an app that doesn't know the switch, and keeps Add workouts off", async () => {
    const { token } = await signUp()
    const { mcp_log_workouts: _, ...older } = SAMPLES.profile()
    expect((await pushProfile(token, older)).status).toBe(200)
    expect((await pulledProfile(token)).mcp_log_workouts).toBe(false)
  })

  it('refuses a value that is not a boolean, naming the column', async () => {
    const { token } = await signUp()
    const res = await pushProfile(token, { ...SAMPLES.profile(), mcp_log_workouts: 1 })
    expect(res.status).toBe(422)
    expect(await res.json()).toEqual({
      error: { code: 'row_rejected', message: 'rows[0].mcp_log_workouts is not a valid bool' },
    })
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/agents-sync.test.ts`
Expected: FAIL, 3 failed: the pulled profile has no `mcp_log_workouts` (`expected { …(25) } to match object
{ mcp_log_workouts: true, …(1) }`), `expected undefined to be false`, and `expected 200 to be 422`.

- [ ] **Step 3: The column, in `server/src/sync/entities.ts`**

Replace

```ts
const edited = col('client_updated_at', 'ts')
```

with

```ts
const edited = col('client_updated_at', 'ts')
/**
 * Plan 32's Add workouts switch. An app from before it sends none, and the Worker is deployed first, so a missing value
 * is stored as off, the column's default, instead of refusing the profile.
 */
const logWorkouts: Column = { name: 'mcp_log_workouts', kind: 'bool', fallback: false }
```

and in the profile's `columns`, replace

```ts
      col('mcp_propose', 'bool'), col('mcp_auto_apply', 'bool'), opt('sex', 'text'), opt('birth_year', 'int'), edited,
```

with

```ts
      col('mcp_propose', 'bool'), col('mcp_auto_apply', 'bool'), logWorkouts, opt('sex', 'text'),
      opt('birth_year', 'int'), edited,
```

`Column` is already imported there (`import { type Column, type Kind, RowError } from './columns.ts'`).

- [ ] **Step 4: The sample the generic sync tests push, in `server/test/samples.ts`**

The app's new build always sends the switch, so the sample does, and `sync-rows.test.ts`'s round trip covers it.
Replace

```ts
    mcp_read_plan: true, mcp_read_gyms: true, mcp_propose: true, mcp_auto_apply: false, sex: null, birth_year: null,
    client_updated_at: T1,
  }),
```

with

```ts
    mcp_read_plan: true, mcp_read_gyms: true, mcp_propose: true, mcp_auto_apply: false, mcp_log_workouts: true,
    sex: null, birth_year: null, client_updated_at: T1,
  }),
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd server && npx vitest run test/agents-sync.test.ts test/sync-rows.test.ts`
Expected: PASS, `Tests  72 passed (72)`.

- [ ] **Step 6: Everything**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  49 passed (49)`, `Tests  695 passed (695)`; `tsc` prints nothing.

- [ ] **Step 7: Commit**

```bash
git add server/src/sync/entities.ts server/test/samples.ts server/test/agents-sync.test.ts
git commit -m "feat(server): the profile syncs mcp_log_workouts, off when an older app leaves it out"
```

---

### Task S3: Workout pulls carry added_by, and the app's saves keep it

**Files:**
- Modify: `server/src/sync/workouts.ts`, `server/test/sync-workouts.test.ts`
- Test: `server/test/agents-sync.test.ts`

- [ ] **Step 1: Write the failing tests**

In `server/test/agents-sync.test.ts`, replace the samples import

```ts
import { type Row, SAMPLES, T2 } from './samples.ts'
```

with

```ts
import { type Row, SAMPLES, T2, type WorkoutJSON, workoutSample } from './samples.ts'
```

and add at the end of the file:

```ts

async function saveWorkout(token: string, workout: Row): Promise<{ status: string; updated_at: string }> {
  const res = await request('POST', '/v1/sync/workouts', { token, body: workout })
  expect(res.status).toBe(200)
  return await res.json<{ status: string; updated_at: string }>()
}

async function pulledWorkouts(token: string): Promise<WorkoutJSON[]> {
  const res = await request('GET', '/v1/sync/workouts', { token })
  expect(res.status).toBe(200)
  return (await res.json<{ rows: WorkoutJSON[] }>()).rows
}

/** What log_workout leaves on a workout it added (src/sync/workouts.ts writes it only on insert). */
const markAdded = (id: string, name: string) =>
  env.DB.prepare('UPDATE workouts SET added_by = ?2 WHERE id = ?1').bind(id.toLowerCase(), name).run()

describe("a workout's added_by", () => {
  it("is null on the app's own workouts, in a pull and a fetch", async () => {
    const { token } = await signUp()
    const w = workoutSample()
    await saveWorkout(token, w)
    expect((await pulledWorkouts(token)).map((p) => p.added_by)).toEqual([null])
    const fetched = await request('GET', `/v1/sync/workouts/${w.id}`, { token })
    expect((await fetched.json<WorkoutJSON>()).added_by).toBeNull()
  })

  it("is pulled as the agent's name, and an edit from the app keeps it", async () => {
    const { token } = await signUp()
    const w = workoutSample()
    const first = await saveWorkout(token, w)
    await markAdded(w.id, 'Muse')
    const edit = { ...w, name: 'Upper', client_updated_at: T2, base_updated_at: first.updated_at, added_by: null }
    expect((await saveWorkout(token, edit)).status).toBe('ok')
    expect(await pulledWorkouts(token)).toMatchObject([{ name: 'Upper', added_by: 'Muse' }])
  })

  it('is never set by the app: a save that sends one leaves it as it was', async () => {
    const { token } = await signUp()
    const fresh = workoutSample({ added_by: 'Forged' })
    await saveWorkout(token, fresh)
    const marked = workoutSample()
    const first = await saveWorkout(token, marked)
    await markAdded(marked.id, 'Muse')
    await saveWorkout(token, { ...marked, client_updated_at: T2, base_updated_at: first.updated_at, added_by: 'Forged' })
    const byId = Object.fromEntries((await pulledWorkouts(token)).map((p) => [p.id, p.added_by]))
    expect(byId).toEqual({ [fresh.id.toLowerCase()]: null, [marked.id.toLowerCase()]: 'Muse' })
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/agents-sync.test.ts`
Expected: FAIL, 3 failed, 3 passed: `expected [ undefined ] to deeply equal [ null ]`, and the pulled workouts have
no `added_by`.

- [ ] **Step 3: Pull added_by, in `server/src/sync/workouts.ts`**

Replace

```ts
const WORKOUT_SELECT = `${names(WORKOUT)}, updated_at`
```

with

```ts
/**
 * What a pull answers: the columns, the server's updated_at, and added_by (plan 32), the agent that added the workout
 * with log_workout or null. added_by is the server's own: no save from the app sets or changes it (UPSERT leaves it
 * out), and only addWorkout writes it.
 */
const WORKOUT_SELECT = `${names(WORKOUT)}, added_by, updated_at`
```

`withEntries` passes keys that aren't in `WORKOUT` through `wireRow` as stored, so `added_by` arrives as a string or
`null`. It stays out of `WORKOUT`, so `storedRow` ignores it in a push and `UPSERT` never sets it.

- [ ] **Step 4: The pulled shape, in `server/test/sync-workouts.test.ts`**

In "stores it with its entries and sets, and answers it as the app decodes it", replace

```ts
      deleted_at: null, updated_at: saved.updated_at,
```

with

```ts
      deleted_at: null, added_by: null, updated_at: saved.updated_at,
```

and in "answers pulled workouts with only the app's keys", replace

```ts
      'gym_id', 'client_updated_at', 'deleted_at', 'updated_at', 'entries',
```

with

```ts
      'gym_id', 'client_updated_at', 'deleted_at', 'added_by', 'updated_at', 'entries',
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd server && npx vitest run test/agents-sync.test.ts test/sync-workouts.test.ts`
Expected: PASS, `Tests  28 passed (28)`.

- [ ] **Step 6: Everything**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  49 passed (49)`, `Tests  698 passed (698)`; `tsc` prints nothing.

- [ ] **Step 7: Commit**

```bash
git add server/src/sync/workouts.ts server/test/sync-workouts.test.ts server/test/agents-sync.test.ts
git commit -m "feat(server): workout pulls carry added_by, which the app's saves never change"
```

---

### Task S4: A proposal names the agent that sent it

**Files:**
- Modify: `server/src/mcp/d1-db.ts`, `server/src/claude/proposals.ts`, `server/test/claude-proposals.test.ts`,
  `server/test/claude.ts`
- Test: `server/test/proposals-from-agent.test.ts`

- [ ] **Step 1: A second agent on one account, in `server/test/claude.ts`**

Add at the end of the file:

```ts

/** Meta's agent's kind of callback: https on a host that isn't Claude's. */
export const AGENT_CALLBACK = 'https://agent.meta.ai/oauth/callback'

export interface AgentConnection {
  clientId: string
  tokens: Tokens
}

/**
 * Another agent connected to an account that exists already (plan 32): its own registration, with `name` as its
 * client_name (none when undefined), the owner's approval in the app, and its tokens.
 */
export async function connectAgent(
  appToken: string,
  agent: { name?: string; redirectUri?: string } = {},
): Promise<AgentConnection> {
  const redirectUri = agent.redirectUri ?? AGENT_CALLBACK
  const registered = await register({
    ...(agent.name === undefined ? {} : { client_name: agent.name }),
    redirect_uris: [redirectUri],
    token_endpoint_auth_method: 'none',
  })
  if (registered.status !== 201) throw new Error(`registration failed: ${registered.status} ${await registered.text()}`)
  const clientId = (await registered.json<{ client_id: string }>()).client_id
  const flow = await startFlow(clientId, redirectUri)
  const browser = new Browser()
  const { code } = await openConnect(browser, flow)
  const decided = await decideCode(appToken, code, 'approve')
  if (decided.status !== 200) throw new Error(`approve failed: ${decided.status} ${await decided.text()}`)
  const res = await exchangeCode(flow, await finishInBrowser(browser, flow))
  if (res.status !== 200) throw new Error(`token exchange failed: ${res.status} ${await res.text()}`)
  return { clientId, tokens: await res.json<Tokens>() }
}
```

- [ ] **Step 2: Write the failing tests**

`server/test/proposals-from-agent.test.ts`:

```ts
// Which agent sent a proposal (plan 32; docs/specs/2026-11-09-ai-agents-design.md, section 3.3): propose_plan_changes
// stores the calling client's registered name, and the app's pull of pending proposals serves it as from_agent.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { D1Db } from '../src/mcp/d1-db.ts'
import { connectAgent, connectClaude, mcp } from './claude.ts'
import { request } from './helpers.ts'
import { readRpc } from './mcp/rpc.ts'

const PROPOSAL = {
  summary: 'Add a Push day',
  changes: [{ id: 'c1', type: 'add-routine', routineId: 'new-push', name: 'Push' }],
}

async function propose(token: string): Promise<void> {
  const msg = await readRpc(await mcp(token, 'tools/call', { name: 'propose_plan_changes', arguments: PROPOSAL }, 2))
  expect(msg.result.isError).toBeFalsy()
}

async function pendingFromAgents(appToken: string): Promise<unknown[]> {
  const res = await request('GET', '/v1/claude/proposals', { token: appToken })
  expect(res.status).toBe(200)
  return (await res.json<{ rows: { from_agent: unknown }[] }>()).rows.map((r) => r.from_agent)
}

describe("a proposal's agent", () => {
  it("is the calling client's registered name, stored and served to the app", async () => {
    const c = await connectClaude()
    const muse = await connectAgent(c.appToken, { name: 'Muse' })
    await propose(c.tokens.access_token)
    await propose(muse.tokens.access_token)
    // Two proposals can share a millisecond, and then their order is their ids'.
    expect((await pendingFromAgents(c.appToken)).sort()).toEqual(['Claude Code', 'Muse'])
    const stored = await env.DB.prepare('SELECT from_agent FROM proposals WHERE user_id = ?1 ORDER BY from_agent')
      .bind(c.userId).all()
    expect(stored.results).toEqual([{ from_agent: 'Claude Code' }, { from_agent: 'Muse' }])
  })

  it('is null when the client registered no name', async () => {
    const c = await connectClaude()
    const unnamed = await connectAgent(c.appToken)
    await propose(unnamed.tokens.access_token)
    expect(await pendingFromAgents(c.appToken)).toEqual([null])
  })

  it('is null for a proposal whose client is gone', async () => {
    const c = await connectClaude()
    await new D1Db(env.DB, c.userId, 'no-such-client').insertProposal({ summary: 'Old', changes: [{ id: 'c1' }] })
    expect(await pendingFromAgents(c.appToken)).toEqual([null])
  })
})
```

`connectClaude` registers its client as "Claude Code" (`registerClient`'s default).

- [ ] **Step 3: Run them to see them fail**

Run: `cd server && npx vitest run test/proposals-from-agent.test.ts`
Expected: FAIL, 3 failed: `expected [ undefined, undefined ] to deeply equal [ 'Claude Code', 'Muse' ]`, and
`expected [ undefined ] to deeply equal [ null ]` twice.

- [ ] **Step 4: Store the agent's name, in `server/src/mcp/d1-db.ts`**

Replace

```ts
/** `write`, with the refusal of one of its caps (migrations/0010_account_caps.sql) as words for Claude. */
```

with

```ts
/**
 * The calling client's registered name (oauthClient.name), as an SQL expression on the client id in `param`; null when
 * it gave none, or one that proposals.from_agent and workouts.added_by can't hold (1 to 64 characters,
 * migrations/0011_ai_agents.sql). Registration takes at most 64 (src/auth/routes.ts, CLIENT_NAME_MAX).
 */
const agentNameSql = (param: string) =>
  `(SELECT name FROM oauthClient WHERE clientId = ${param} AND length(name) BETWEEN 1 AND 64)`

/** `write`, with the refusal of one of its caps (migrations/0010_account_caps.sql) as words for Claude. */
```

and replace `insertProposal`:

```ts
  /** A pending proposal, while Claude may propose (proposals_insert). */
  async insertProposal(
    p: { summary: string; changes: unknown[] },
  ): Promise<{ id: string; created_at: string }> {
    if (!(await this.allowed()).propose) throw new ToolError(NOT_ALLOWED)
    const row = await capped(this.db.prepare(
      'INSERT INTO proposals (id, user_id, created_at, summary, changes, status, applied_change_ids, ' +
        `client_updated_at, updated_at) VALUES (?1, ?2, ${NOW_SQL}, ?3, ?4, 'pending', '[]', ${NOW_SQL}, ` +
        `${NOW_SQL}) ` +
        'RETURNING id, created_at',
    ).bind(crypto.randomUUID(), this.userId, p.summary, JSON.stringify(p.changes)).first<
      { id: string; created_at: string }
    >(), 'too_many_pending_proposals', 'too_many_proposals')
    return row!
  }
```

with

```ts
  /** A pending proposal, while Claude may propose (proposals_insert), marked with the calling agent's name. */
  async insertProposal(
    p: { summary: string; changes: unknown[] },
  ): Promise<{ id: string; created_at: string }> {
    if (!(await this.allowed()).propose) throw new ToolError(NOT_ALLOWED)
    const row = await capped(this.db.prepare(
      'INSERT INTO proposals (id, user_id, created_at, summary, changes, status, applied_change_ids, ' +
        `client_updated_at, updated_at, from_agent) VALUES (?1, ?2, ${NOW_SQL}, ?3, ?4, 'pending', '[]', ` +
        `${NOW_SQL}, ${NOW_SQL}, ${agentNameSql('?5')}) RETURNING id, created_at`,
    ).bind(crypto.randomUUID(), this.userId, p.summary, JSON.stringify(p.changes), this.clientId).first<
      { id: string; created_at: string }
    >(), 'too_many_pending_proposals', 'too_many_proposals')
    return row!
  }
```

The name is read in the insert itself: no extra query, and no change to the `Db` interface.

- [ ] **Step 5: Serve it, in `server/src/claude/proposals.ts`**

Replace

```ts
/** Pending proposals, oldest first: `changes` and `applied_change_ids` as JSON, times in the stored form. */
export async function pendingProposals(db: D1Database, userId: string): Promise<Record<string, unknown>[]> {
  const { results } = await db.prepare(
    'SELECT id, created_at, source, summary, changes, status, applied_change_ids, resolved_at FROM ' +
      'proposals ' +
```

with

```ts
/**
 * Pending proposals, oldest first: `changes` and `applied_change_ids` as JSON, times in the stored form, and from_agent,
 * the name of the agent that sent each (plan 32; null when it gave none, and for older proposals).
 */
export async function pendingProposals(db: D1Database, userId: string): Promise<Record<string, unknown>[]> {
  const { results } = await db.prepare(
    'SELECT id, created_at, source, summary, changes, status, applied_change_ids, resolved_at, from_agent FROM ' +
      'proposals ' +
```

- [ ] **Step 6: The pulled shape, in `server/test/claude-proposals.test.ts`**

In "lists the account's pending proposals, oldest first, with their changes as JSON", replace

```ts
      applied_change_ids: [],
      resolved_at: null,
    })
```

with

```ts
      applied_change_ids: [],
      resolved_at: null,
      from_agent: null,
    })
```

(Its proposals come from `new D1Db(env.DB, userId, 'claude')`, and `claude` is no registered client.)

- [ ] **Step 7: Run the tests to see them pass**

Run: `cd server && npx vitest run test/proposals-from-agent.test.ts test/claude-proposals.test.ts test/claude-caps.test.ts test/mcp/d1-db.test.ts`
Expected: PASS, `Test Files  4 passed (4)`, `Tests  41 passed (41)`.

- [ ] **Step 8: Everything**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  50 passed (50)`, `Tests  701 passed (701)`; `tsc` prints nothing.

- [ ] **Step 9: Commit**

```bash
git add server/src/mcp/d1-db.ts server/src/claude/proposals.ts server/test/claude-proposals.test.ts \
  server/test/claude.ts server/test/proposals-from-agent.test.ts
git commit -m "feat(server): a proposal stores and serves the name of the agent that sent it"
```

---

### Task S5: GET /v1/agents lists the account's agents

**Files:**
- Create: `server/src/claude/hosts.ts`, `server/src/claude/agents.ts`, `server/src/claude/agent-routes.ts`
- Modify: `server/src/claude/routes.ts`, `server/src/index.ts`
- Test: `server/test/agents.test.ts`

- [ ] **Step 1: Write the failing tests**

`server/test/agents.test.ts`:

```ts
// The agents connected to the account (plan 32; docs/specs/2026-11-09-ai-agents-design.md, section 3.1): GET /v1/agents
// lists every OAuth client holding a consent or a live refresh token for it, newest connection first.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { AGENT_CALLBACK, CLAUDE_AI, connectAgent, connectClaude, mcp } from './claude.ts'
import { request, signUp } from './helpers.ts'
import { readRpc } from './mcp/rpc.ts'

interface Agent {
  client_id: string
  name: string
  host: string
  known_host: boolean
  connected_at: string
  last_used_at: string | null
}

async function agents(appToken: string): Promise<Agent[]> {
  const res = await request('GET', '/v1/agents', { token: appToken })
  expect(res.status).toBe(200)
  return (await res.json<{ agents: Agent[] }>()).agents
}

/** Sets when the owner approved the client, in Better Auth's form of a time (toISOString). */
const consentedAt = (clientId: string, userId: string, iso: string) =>
  env.DB.prepare('UPDATE oauthConsent SET createdAt = ?3 WHERE clientId = ?1 AND userId = ?2')
    .bind(clientId, userId, iso).run()

describe('GET /v1/agents', () => {
  it("lists each agent with its name, host and whether the host is Claude's, newest connection first", async () => {
    const c = await connectClaude()
    const muse = await connectAgent(c.appToken, { name: 'Muse' })
    const claude = await connectAgent(c.appToken, { name: 'Claude', redirectUri: CLAUDE_AI })
    await consentedAt(c.clientId, c.userId, '2026-11-01T08:00:00.000Z')
    await consentedAt(muse.clientId, c.userId, '2026-11-09T01:20:00.000Z')
    await consentedAt(claude.clientId, c.userId, '2026-11-05T12:30:15.250Z')
    expect(await agents(c.appToken)).toEqual([
      {
        client_id: muse.clientId, name: 'Muse', host: 'agent.meta.ai', known_host: false,
        connected_at: '2026-11-09T01:20:00.000000Z', last_used_at: null,
      },
      {
        client_id: claude.clientId, name: 'Claude', host: 'claude.ai', known_host: true,
        connected_at: '2026-11-05T12:30:15.250000Z', last_used_at: null,
      },
      {
        client_id: c.clientId, name: 'Claude Code', host: '127.0.0.1:33418', known_host: false,
        connected_at: '2026-11-01T08:00:00.000000Z', last_used_at: null,
      },
    ])
  })

  it('names an agent by its host when it registered no name', async () => {
    const { token } = await signUp()
    const unnamed = await connectAgent(token)
    expect(await agents(token)).toMatchObject([
      { client_id: unnamed.clientId, name: new URL(AGENT_CALLBACK).host, host: 'agent.meta.ai' },
    ])
  })

  it('gives each agent its own last use, the newest of its audited calls', async () => {
    const c = await connectClaude()
    const muse = await connectAgent(c.appToken, { name: 'Muse' })
    for (const id of [2, 3]) {
      // Read to the end: the audit row is written as the answer is.
      await readRpc(await mcp(muse.tokens.access_token, 'tools/call', { name: 'get_profile', arguments: {} }, id))
    }
    const newest = await env.DB.prepare(
      'SELECT max(at) AS at FROM mcp_audit WHERE user_id = ?1 AND client_id = ?2',
    ).bind(c.userId, muse.clientId).first<{ at: string }>()
    const byId = Object.fromEntries((await agents(c.appToken)).map((a) => [a.client_id, a.last_used_at]))
    expect(byId).toEqual({ [muse.clientId]: newest!.at, [c.clientId]: null })
    expect(newest!.at).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/)
  })

  it('lists a client that holds only a live refresh token, as connected when its first token was', async () => {
    const c = await connectClaude()
    await env.DB.prepare('DELETE FROM oauthConsent WHERE userId = ?1').bind(c.userId).run()
    const first = await env.DB.prepare(
      'SELECT min(createdAt) AS at FROM oauthRefreshToken WHERE userId = ?1 AND clientId = ?2',
    ).bind(c.userId, c.clientId).first<{ at: string }>()
    const [listed] = await agents(c.appToken)
    expect(listed).toMatchObject({ client_id: c.clientId, name: 'Claude Code' })
    expect(listed!.connected_at).toBe(first!.at.replace(/Z$/, '000Z'))
    await env.DB.prepare("UPDATE oauthRefreshToken SET expiresAt = '2026-01-01T00:00:00.000Z' WHERE userId = ?1")
      .bind(c.userId).run()
    expect(await agents(c.appToken)).toEqual([])
  })

  it("lists only the account's own agents", async () => {
    const mine = await connectClaude()
    const theirs = await connectClaude()
    await connectAgent(theirs.appToken, { name: 'Muse' })
    expect((await agents(mine.appToken)).map((a) => a.client_id)).toEqual([mine.clientId])
    expect(await agents((await signUp()).token)).toEqual([])
  })

  it("needs the app's session: no token, or an agent's, is 401", async () => {
    const c = await connectClaude()
    expect((await request('GET', '/v1/agents')).status).toBe(401)
    expect((await request('GET', '/v1/agents', { token: c.tokens.access_token })).status).toBe(401)
  })
})
```

- The consent times are set by hand: agents connected one after another can share a millisecond.
- A consent-less client with a live refresh token is the pair a refresh mints while Disconnect runs
  (`src/claude/tokens.ts`); `/mcp` refuses it, and listing it lets the owner clear it.

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/agents.test.ts`
Expected: FAIL, 5 failed, 1 passed: `expected 404 to be 200` (no route yet). The 401 test passes already:
`requireUser` runs before any route matches.

- [ ] **Step 3: One set of Claude's hosts, `server/src/claude/hosts.ts`**

```ts
// Claude's own hosts: the approve sheet shows a connection returning to one without a warning (routes.ts), and the
// agents list marks an agent whose callback is on one as known (agents.ts). One set, so the two can't drift.
export const CLAUDE_HOSTS: ReadonlySet<string> = new Set(['claude.ai', 'claude.com'])
```

In `server/src/claude/routes.ts`, replace

```ts
import { lastClaudeUse, parseResolution, pendingProposals, resolveProposal } from './proposals.ts'
import { revokeClaude } from './revoke.ts'

/** Hosts the app shows without a warning: Claude's own. */
const CLAUDE_HOSTS = new Set(['claude.ai', 'claude.com'])
```

with

```ts
import { CLAUDE_HOSTS } from './hosts.ts'
import { lastClaudeUse, parseResolution, pendingProposals, resolveProposal } from './proposals.ts'
import { revokeClaude } from './revoke.ts'
```

`connectView` keeps calling `CLAUDE_HOSTS.has(r.redirect_host)`.

- [ ] **Step 4: The list, `server/src/claude/agents.ts`**

```ts
// The agents connected to the account (plan 32; docs/specs/2026-11-09-ai-agents-design.md, section 3.1): every OAuth
// client that holds a consent or a live refresh token for it. Settings › AI agents lists them.
import { normalizeTimestamp } from '../sync/time.ts'
import { CLAUDE_HOSTS } from './hosts.ts'

export interface ConnectedAgent {
  client_id: string
  /** The registered client_name, or the host when it gave none. */
  name: string
  /** The host (and port, if any) of its first redirect URL, as the approve sheet shows it. */
  host: string
  /** True for Claude's own hosts (CLAUDE_HOSTS). */
  known_host: boolean
  /** When the owner approved it (the consent), in the stored form. */
  connected_at: string
  /** Its newest audited call for the account, or null. */
  last_used_at: string | null
}

/** Better Auth's clock in SQL: it stores dates as toISOString() text (YYYY-MM-DDTHH:MM:SS.sssZ), which this matches. */
const AUTH_NOW_SQL = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"

/** The clients the account (?1) granted: a consent, or a refresh token that is neither revoked nor expired. */
const GRANTED = 'SELECT clientId FROM oauthConsent WHERE userId = ?1 UNION ' +
  `SELECT clientId FROM oauthRefreshToken WHERE userId = ?1 AND revoked IS NULL AND expiresAt > ${AUTH_NOW_SQL}`

/**
 * connected_at is the consent's createdAt, or the first refresh token's for a client whose consent is gone (a refresh
 * that raced a Disconnect; /mcp refuses it, src/claude/tokens.ts). Listing it lets the owner disconnect it.
 */
const LIST = `SELECT c.clientId AS client_id, c.name AS client_name,
  CASE WHEN json_valid(c.redirectUris) THEN json_extract(c.redirectUris, '$[0]') END AS redirect_uri,
  coalesce(
    (SELECT min(k.createdAt) FROM oauthConsent k WHERE k.clientId = c.clientId AND k.userId = ?1),
    (SELECT min(r.createdAt) FROM oauthRefreshToken r WHERE r.clientId = c.clientId AND r.userId = ?1)
  ) AS connected_at,
  (SELECT max(a.at) FROM mcp_audit a WHERE a.user_id = ?1 AND a.client_id = c.clientId) AS last_used_at
FROM oauthClient c WHERE c.clientId IN (${GRANTED})
ORDER BY connected_at DESC, c.clientId`

interface ListRow {
  client_id: string
  client_name: string | null
  redirect_uri: string | null
  connected_at: string
  last_used_at: string | null
}

/** A redirect URL's host as the approve sheet has it (src/claude/connect-page.ts), or '' when it isn't a URL. */
function hostOf(uri: string | null): string {
  if (uri === null) return ''
  try {
    return new URL(uri).host
  } catch {
    return ''
  }
}

/** The account's agents, newest connection first. */
export async function connectedAgents(db: D1Database, userId: string): Promise<ConnectedAgent[]> {
  const { results } = await db.prepare(LIST).bind(userId).all<ListRow>()
  return results.map((r) => {
    const host = hostOf(r.redirect_uri)
    return {
      client_id: r.client_id,
      name: r.client_name ?? host,
      host,
      known_host: CLAUDE_HOSTS.has(host),
      connected_at: normalizeTimestamp(r.connected_at) ?? r.connected_at,
      last_used_at: r.last_used_at,
    }
  })
}
```

- Reads go through `oauthConsent_userId_idx`, `oauthRefreshToken_userId_idx` and `mcp_audit_user_at`.
- Disabled clients are listed too: the owner can still disconnect them.

- [ ] **Step 5: The route, `server/src/claude/agent-routes.ts`**

```ts
// /v1/agents: Settings › AI agents, behind the app's session like /v1/claude (plan 32; docs/specs/
// 2026-11-09-ai-agents-design.md, section 3). POST /v1/claude/revoke stays as Disconnect all.
import { Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { connectedAgents } from './agents.ts'

export const agentRoutes = new Hono<AppEnv>()

agentRoutes.get('/', async (c) => c.json({ agents: await connectedAgents(c.env.DB, c.var.userId) }))
```

In `server/src/index.ts`, replace

```ts
import { requireUser } from './auth/session.ts'
```

with

```ts
import { requireUser } from './auth/session.ts'
import { agentRoutes } from './claude/agent-routes.ts'
```

and replace

```ts
v1.route('/claude', claudeRoutes)
```

with

```ts
v1.route('/claude', claudeRoutes)
v1.route('/agents', agentRoutes)
```

- [ ] **Step 6: Run the tests to see them pass**

Run: `cd server && npx vitest run test/agents.test.ts test/connect-approve.test.ts`
Expected: PASS, `Tests  31 passed (31)` (6 here, 25 in `connect-approve.test.ts`, which reads `CLAUDE_HOSTS` through
the approve sheet).

- [ ] **Step 7: Everything**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  51 passed (51)`, `Tests  707 passed (707)`; `tsc` prints nothing.

- [ ] **Step 8: Commit**

```bash
git add server/src/claude/hosts.ts server/src/claude/agents.ts server/src/claude/agent-routes.ts \
  server/src/claude/routes.ts server/src/index.ts server/test/agents.test.ts
git commit -m "feat(server): GET /v1/agents lists the account's agents, newest connection first"
```

---

### Task S6: Disconnect one agent

**Files:**
- Modify: `server/src/claude/agents.ts`, `server/src/claude/agent-routes.ts`
- Test: `server/test/agents.test.ts`

- [ ] **Step 1: Write the failing tests**

In `server/test/agents.test.ts`, replace

```ts
import { AGENT_CALLBACK, CLAUDE_AI, connectAgent, connectClaude, mcp } from './claude.ts'
```

with

```ts
import {
  AGENT_CALLBACK,
  Browser,
  CLAUDE_AI,
  connectAgent,
  connectClaude,
  decideCode,
  exchangeCode,
  finishInBrowser,
  LOOPBACK,
  mcp,
  openConnect,
  refresh,
  startFlow,
} from './claude.ts'
```

and add at the end of the file:

```ts

const disconnect = (appToken: string | undefined, clientId: string) =>
  request('POST', `/v1/agents/${encodeURIComponent(clientId)}/disconnect`, appToken ? { token: appToken } : {})

/** An agent the owner approved again, whose browser holds its /connect session and whose code isn't swapped yet. */
async function approvedUnswapped(appToken: string, clientId: string, redirectUri: string) {
  const flow = await startFlow(clientId, redirectUri)
  const browser = new Browser()
  const { code } = await openConnect(browser, flow)
  expect((await decideCode(appToken, code, 'approve')).status).toBe(200)
  return { flow, code: await finishInBrowser(browser, flow) }
}

/** The account's rows for one client in each table a disconnect clears. */
async function grantsOf(userId: string, clientId: string) {
  return await env.DB.prepare(
    'SELECT (SELECT count(*) FROM oauthAccessToken WHERE userId = ?1 AND clientId = ?2) AS access, ' +
      '(SELECT count(*) FROM oauthRefreshToken WHERE userId = ?1 AND clientId = ?2) AS refresh, ' +
      '(SELECT count(*) FROM oauthConsent WHERE userId = ?1 AND clientId = ?2) AS consent, ' +
      '(SELECT count(*) FROM connect_requests WHERE user_id = ?1 AND client_id = ?2) AS requests, ' +
      "(SELECT count(*) FROM verification WHERE json_valid(value) AND json_extract(value, '$.userId') = ?1 " +
      "AND json_extract(value, '$.query.client_id') = ?2) AS codes",
  ).bind(userId, clientId).first()
}

const browserSessions = async (userId: string) =>
  (await env.DB.prepare('SELECT count(*) AS n FROM session WHERE userId = ?1 AND claudeConnect = 1').bind(userId)
    .first<{ n: number }>())!.n

describe('POST /v1/agents/:clientId/disconnect', () => {
  it('cuts that agent off, its tokens and its approval, and leaves another agent working', async () => {
    const c = await connectClaude()
    const muse = await connectAgent(c.appToken, { name: 'Muse' })
    const res = await disconnect(c.appToken, muse.clientId)
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ disconnected: true })
    expect((await mcp(muse.tokens.access_token, 'tools/list')).status).toBe(401)
    expect((await refresh(muse.clientId, muse.tokens.refresh_token)).status).toBe(400)
    expect(await grantsOf(c.userId, muse.clientId)).toEqual({ access: 0, refresh: 0, consent: 0, requests: 0, codes: 0 })
    expect((await mcp(c.tokens.access_token, 'tools/list')).status).toBe(200)
    expect(await grantsOf(c.userId, c.clientId)).toMatchObject({ consent: 1, requests: 1 })
    expect((await agents(c.appToken)).map((a) => a.client_id)).toEqual([c.clientId])
    const client = await env.DB.prepare('SELECT count(*) AS n FROM oauthClient WHERE clientId = ?1')
      .bind(muse.clientId).first()
    expect(client).toEqual({ n: 1 })
  })

  it("ends that agent's approved browser and its unredeemed code, and no other agent's", async () => {
    const c = await connectClaude()
    const muse = await connectAgent(c.appToken, { name: 'Muse' })
    const museAgain = await approvedUnswapped(c.appToken, muse.clientId, AGENT_CALLBACK)
    const claudeAgain = await approvedUnswapped(c.appToken, c.clientId, LOOPBACK)
    expect(await grantsOf(c.userId, muse.clientId)).toMatchObject({ codes: 1 })
    expect(await browserSessions(c.userId)).toBe(2)
    expect((await disconnect(c.appToken, muse.clientId)).status).toBe(200)
    expect(await grantsOf(c.userId, muse.clientId)).toMatchObject({ codes: 0, requests: 0 })
    expect(await browserSessions(c.userId)).toBe(1)
    expect((await exchangeCode(museAgain.flow, museAgain.code)).status).toBe(400)
    expect((await exchangeCode(claudeAgain.flow, claudeAgain.code)).status).toBe(200)
  })

  it("answers 404 unknown_agent for a client the account never connected, or another account's", async () => {
    const mine = await connectClaude()
    const theirs = await connectClaude()
    const unknown = {
      error: { code: 'unknown_agent', message: 'No agent with this id is connected to your account.' },
    }
    for (const clientId of ['no-such-client', theirs.clientId, 'x'.repeat(300)]) {
      const res = await disconnect(mine.appToken, clientId)
      expect(res.status, clientId).toBe(404)
      expect(await res.json()).toEqual(unknown)
    }
    expect((await mcp(theirs.tokens.access_token, 'tools/list')).status).toBe(200)
    expect((await disconnect(mine.appToken, mine.clientId)).status).toBe(200)
    expect((await disconnect(mine.appToken, mine.clientId)).status).toBe(404)
  })

  it('leaves Disconnect all cutting every agent at once', async () => {
    const c = await connectClaude()
    const muse = await connectAgent(c.appToken, { name: 'Muse' })
    expect(await (await request('POST', '/v1/claude/revoke', { token: c.appToken })).json()).toEqual({ revoked: 2 })
    for (const token of [c.tokens.access_token, muse.tokens.access_token]) {
      expect((await mcp(token, 'tools/list')).status).toBe(401)
    }
    expect(await agents(c.appToken)).toEqual([])
  })

  it("needs the app's session", async () => {
    const c = await connectClaude()
    expect((await disconnect(undefined, c.clientId)).status).toBe(401)
    expect((await disconnect(c.tokens.access_token, c.clientId)).status).toBe(401)
    expect((await mcp(c.tokens.access_token, 'tools/list')).status).toBe(200)
  })
})
```

The second test proves the verification key: before the disconnect it counts Muse's unredeemed code by
`$.query.client_id`, so a wrong key fails at `codes: 1`.

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/agents.test.ts`
Expected: FAIL, 3 failed, 8 passed: `expected 404 to be 200` twice (no route: Hono's 404 `not_found`), and
`expected { error: { code: 'not_found', …(1) } } to deeply equal { error: { …(2) } }`.

- [ ] **Step 3: The disconnect, in `server/src/claude/agents.ts`**

Add at the end of the file:

```ts

/**
 * An unredeemed authorization code of the account (?1) for the client (?2). Better Auth keeps each code as a
 * verification row whose value is JSON: {type: 'authorization_code', query: {client_id, …}, userId, sessionId, …}
 * (@better-auth/oauth-provider 1.7.18, redirectWithAuthorizationCode). A redeemed code's row is gone already.
 */
const UNREDEEMED_CODE = "json_valid(value) AND json_extract(value, '$.type') = 'authorization_code' " +
  "AND json_extract(value, '$.userId') = ?1 AND json_extract(value, '$.query.client_id') = ?2"

/**
 * The /connect browser sessions for this account and client: the ones its connect_requests recorded, and the ones
 * its unredeemed codes name. Only marked sessions (claudeConnect = 1) are ever deleted, never the app's.
 */
const CONNECT_SESSIONS =
  'SELECT session_id FROM connect_requests WHERE user_id = ?1 AND client_id = ?2 AND session_id IS NOT NULL ' +
  `UNION SELECT json_extract(value, '$.sessionId') FROM verification WHERE ${UNREDEEMED_CODE}`

/**
 * Disconnect one agent (section 3.2): in one batch, for this account and this client only, its access and refresh
 * tokens, its consent, its unredeemed codes, its connect_requests and the /connect sessions they made. Its client
 * registration stays (decision 6). Sessions go first, while the rows that name them are still there; access tokens
 * before refresh tokens, which they name. False when the account held no token and no consent for it: 404.
 */
export async function disconnectAgent(db: D1Database, userId: string, clientId: string): Promise<boolean> {
  const results = await db.batch([
    db.prepare(`DELETE FROM session WHERE userId = ?1 AND claudeConnect = 1 AND id IN (${CONNECT_SESSIONS})`)
      .bind(userId, clientId),
    db.prepare('DELETE FROM oauthAccessToken WHERE userId = ?1 AND clientId = ?2').bind(userId, clientId),
    db.prepare('DELETE FROM oauthRefreshToken WHERE userId = ?1 AND clientId = ?2').bind(userId, clientId),
    db.prepare('DELETE FROM oauthConsent WHERE userId = ?1 AND clientId = ?2').bind(userId, clientId),
    db.prepare(`DELETE FROM verification WHERE ${UNREDEEMED_CODE}`).bind(userId, clientId),
    db.prepare('DELETE FROM connect_requests WHERE user_id = ?1 AND client_id = ?2').bind(userId, clientId),
  ])
  return results.slice(1, 4).some((r) => r.meta.changes > 0)
}
```

- `connect_requests` rows still waiting have no `user_id` yet, so a sign-in another person is starting with the same
  client is untouched.
- A refresh racing the disconnect can still mint a pair; `/mcp` refuses it for want of a consent
  (`src/claude/tokens.ts`), and approving the client again deletes it (`src/auth/connect-plugin.ts`), as for
  Disconnect all.

- [ ] **Step 4: The route, in `server/src/claude/agent-routes.ts`**

Replace the whole file with:

```ts
// /v1/agents: Settings › AI agents, behind the app's session like /v1/claude (plan 32; docs/specs/
// 2026-11-09-ai-agents-design.md, section 3). POST /v1/claude/revoke stays as Disconnect all.
import { Hono } from 'hono'
import type { AppEnv } from '../env.ts'
import { ApiError } from '../http/errors.ts'
import { connectedAgents, disconnectAgent } from './agents.ts'

/** Better Auth's client ids are 32 letters; anything far longer is no client of the account. */
const MAX_CLIENT_ID_LENGTH = 255

export const agentRoutes = new Hono<AppEnv>()

agentRoutes.get('/', async (c) => c.json({ agents: await connectedAgents(c.env.DB, c.var.userId) }))

/** Disconnect one agent. Its own code, not `not_found`, so the app can tell it from a missing route. */
agentRoutes.post('/:clientId/disconnect', async (c) => {
  const clientId = c.req.param('clientId')
  const known = clientId.length <= MAX_CLIENT_ID_LENGTH && await disconnectAgent(c.env.DB, c.var.userId, clientId)
  if (!known) throw new ApiError(404, 'unknown_agent', 'No agent with this id is connected to your account.')
  return c.json({ disconnected: true })
})
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd server && npx vitest run test/agents.test.ts test/claude-connection.test.ts`
Expected: PASS; `agents.test.ts` has 11 tests, and Disconnect all's own tests in `claude-connection.test.ts` still pass.

- [ ] **Step 6: Everything**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  51 passed (51)`, `Tests  712 passed (712)`; `tsc` prints nothing.

- [ ] **Step 7: Commit**

```bash
git add server/src/claude/agents.ts server/src/claude/agent-routes.ts server/test/agents.test.ts
git commit -m "feat(server): POST /v1/agents/:clientId/disconnect cuts one agent off and keeps the others"
```

---

### Task S7: The data side of log_workout (the switch, the exercises, the agent's name, the write)

**Files:**
- Modify: `server/src/sync/caps.ts`, `server/src/sync/workouts.ts`, `server/src/mcp/db.ts`, `server/src/mcp/d1-db.ts`,
  `server/test/mcp/fake-db.ts`, `server/test/mcp/d1-db.test.ts`
- Test: `server/test/mcp/d1-workouts.test.ts`

- [ ] **Step 1: Write the failing tests**

`server/test/mcp/d1-workouts.test.ts`:

```ts
// The data side of log_workout (plan 32; docs/specs/2026-11-09-ai-agents-design.md, section 3.4) against real D1: the
// Add workouts switch, the exercises an agent may log, its name, and a workout written by the app's own save path, so
// the caps hold and the phone pulls it.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import type { LoggedWorkout } from '../../src/mcp/db.ts'
import { D1Db } from '../../src/mcp/d1-db.ts'
import { ToolError } from '../../src/mcp/tools/result.ts'
import { DomainLimits } from '../../src/shared/domain-limits.ts'
import { AGENT_WORKOUT_CAPS } from '../../src/sync/caps.ts'
import { countOf, kept, seedCount, seedRows } from '../cap-fixtures.ts'
import { request, signUp } from '../helpers.ts'

const T = '2026-11-07T10:00:00.000000Z'
const DB = env.DB

const LOGGED: LoggedWorkout = {
  started_at: '2026-10-08T17:02:00.000000Z',
  ended_at: '2026-10-08T18:05:00.000000Z',
  name: 'Upper',
  note: 'From Fitbod',
  exercises: [
    {
      exercise_id: '0025',
      sets: [
        { reps: 10, weight_kg: 20, sec: null, dist_m: null, warmup: true },
        { reps: 8, weight_kg: 63.5, sec: null, dist_m: null, warmup: false },
      ],
    },
    { exercise_id: '0001', sets: [{ reps: 0, weight_kg: 0, sec: 60, dist_m: 250, warmup: false }] },
  ],
}

/** A new account with a saved profile: Add workouts on unless `on` is false. */
async function owner(on = true): Promise<{ token: string; userId: string }> {
  const account = await signUp()
  await DB.prepare(
    'INSERT INTO profiles (user_id, mcp_log_workouts, client_updated_at, updated_at) VALUES (?1, ?2, ?3, ?3)',
  ).bind(account.userId, on ? 1 : 0, T).run()
  return account
}

const agentDb = (userId: string, clientId = 'agent-client') => new D1Db(DB, userId, clientId)

describe('the Add workouts switch', () => {
  it('is on only when the owner turned it on', async () => {
    expect(await agentDb((await owner(true)).userId).mayLogWorkouts()).toBe(true)
    expect(await agentDb((await owner(false)).userId).mayLogWorkouts()).toBe(false)
    expect(await agentDb((await signUp()).userId).mayLogWorkouts()).toBe(false)
  })

  it('refuses a workout while it is off, writing nothing', async () => {
    const { userId } = await owner(false)
    await expect(agentDb(userId).insertWorkout(LOGGED, 'Muse')).rejects.toThrow(ToolError)
    expect(await countOf('workouts', userId)).toBe(0)
  })
})

describe('a workout an agent adds', () => {
  it('is an import marked with the agent, with done sets and its volume, which the app pulls', async () => {
    const { token, userId } = await owner()
    const added = await agentDb(userId).insertWorkout(LOGGED, 'Muse')
    expect(added).toEqual({ added: true, id: expect.stringMatching(/^[0-9a-f-]{36}$/) })
    const res = await request('GET', '/v1/sync/workouts', { token })
    const [pulled] = (await res.json<{ rows: Record<string, any>[] }>()).rows
    expect(pulled).toMatchObject({
      id: (added as { id: string }).id,
      started_at: LOGGED.started_at,
      ended_at: LOGGED.ended_at,
      name: 'Upper',
      note: 'From Fitbod',
      source: 'import',
      added_by: 'Muse',
      routine_id: null,
      gym_id: null,
      paused_sec: 0,
      vol_kg: 508,
      records: [],
      deleted_at: null,
    })
    expect(pulled!.updated_at).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/)
    expect(pulled!.entries.map((e: Record<string, any>) => [e.exercise_id, e.position])).toEqual([['0025', 0], ['0001', 1]])
    expect(pulled!.entries[0].sets).toMatchObject([
      { position: 0, w_kg: 20, r: 10, sec: null, dist_m: null, done: true, warmup: true, multiplier: 1 },
      { position: 1, w_kg: 63.5, r: 8, done: true, warmup: false, multiplier: 1 },
    ])
    expect(pulled!.entries[1].sets).toMatchObject([{ w_kg: 0, r: 0, sec: 60, dist_m: 250, done: true }])
    expect([await countOf('workouts', userId), await kept('workout_entries', userId), await kept('workout_sets', userId)])
      .toEqual([1, 2, 3])
  })

  it("is refused at the account's workout cap with the agent's words, and nothing is written", async () => {
    const { userId } = await owner()
    await seedRows('workouts', userId, DomainLimits.workoutsMax)
    expect(await agentDb(userId).insertWorkout(LOGGED, 'Muse')).toEqual({
      added: false,
      reason: 'too_many_workouts',
      message: AGENT_WORKOUT_CAPS.too_many_workouts,
    })
    expect(await countOf('workouts', userId)).toBe(DomainLimits.workoutsMax)
  })

  it('is refused whole when its sets would pass the sets the account may log', async () => {
    const { userId } = await owner()
    await seedCount('workout_sets', userId, DomainLimits.accountSetsMax - 2)
    expect(await agentDb(userId).insertWorkout(LOGGED, 'Muse')).toMatchObject({
      added: false,
      reason: 'too_many_logged_sets',
    })
    expect([await countOf('workouts', userId), await kept('workout_sets', userId)])
      .toEqual([0, DomainLimits.accountSetsMax - 2])
  })

  it('is refused past the per-workout caps, before anything is written', async () => {
    const { userId } = await owner()
    const exercise = LOGGED.exercises[1]!
    const wide = { ...LOGGED, exercises: Array.from({ length: DomainLimits.workoutEntriesMax + 1 }, () => exercise) }
    expect(await agentDb(userId).insertWorkout(wide, 'Muse')).toEqual({
      added: false,
      reason: 'too_many_workout_exercises',
      message: AGENT_WORKOUT_CAPS.too_many_workout_exercises,
    })
    const sets = Array.from({ length: DomainLimits.entrySetsMax + 1 }, () => exercise.sets[0]!)
    const deep = { ...LOGGED, exercises: [{ exercise_id: '0001', sets }] }
    expect(await agentDb(userId).insertWorkout(deep, 'Muse')).toMatchObject({ reason: 'too_many_exercise_sets' })
    expect(await countOf('workouts', userId)).toBe(0)
  })
})

describe('what an agent may log', () => {
  it("takes library ids and the owner's live custom exercises, whatever the plan switch says", async () => {
    const { userId } = await owner()
    const other = await owner()
    const custom = (user: string, deleted: string | null) => {
      const id = `custom-${crypto.randomUUID()}`
      return DB.prepare(
        'INSERT INTO custom_exercises (id, user_id, n, bp, eq, tg, mode, client_updated_at, updated_at, deleted_at) ' +
          "VALUES (?1, ?2, 'Sled push', 'upper legs', 'sled machine', 'quads', 'reps', ?3, ?3, ?4)",
      ).bind(id, user, T, deleted).run().then(() => id)
    }
    const [mine, gone, theirs] = [await custom(userId, null), await custom(userId, T), await custom(other.userId, null)]
    await DB.prepare('UPDATE profiles SET mcp_read_plan = 0 WHERE user_id = ?1').bind(userId).run()
    const known = await agentDb(userId).loggableExerciseIds(['0025', mine, gone, theirs, 'nope'])
    expect([...known].sort()).toEqual(['0025', mine].sort())
    expect(await agentDb(userId).loggableExerciseIds([])).toEqual(new Set())
  })

  it('names the agent by its registered name, when the columns can hold it', async () => {
    const { userId } = await owner()
    const client = (name: string | null) => {
      const clientId = crypto.randomUUID()
      return DB.prepare('INSERT INTO oauthClient (id, clientId, name, redirectUris) VALUES (?1, ?2, ?3, ?4)')
        .bind(crypto.randomUUID(), clientId, name, '["https://agent.meta.ai/cb"]').run().then(() => clientId)
    }
    expect(await agentDb(userId, await client('Muse')).agentName()).toBe('Muse')
    expect(await agentDb(userId, await client(null)).agentName()).toBeNull()
    expect(await agentDb(userId, await client('x'.repeat(65))).agentName()).toBeNull()
    expect(await agentDb(userId, 'no-such-client').agentName()).toBeNull()
  })
})
```

- `vol_kg` is 508: the working set's 63.5 × 8, plus the timed set's 0 × 0; the warm-up doesn't count (the app's
  `WorkoutMetrics`, as `src/mcp/tools/format.ts` `setVolumeKg` mirrors it).
- `'0001'` and `'0025'` are library ids (`migrations/0003_seed_exercises.sql`).

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/mcp/d1-workouts.test.ts`
Expected: FAIL, 8 failed: `TypeError: … mayLogWorkouts is not a function`, and the same for `insertWorkout`,
`loggableExerciseIds` and `agentName`.

- [ ] **Step 3: An agent's words for a refused workout, in `server/src/sync/caps.ts`**

Add at the end of the file:

```ts

/**
 * An agent's words when a cap refuses a workout it adds with log_workout (src/mcp/d1-db.ts, plan 32): the workout's
 * refusal names the code and says this. Nothing of that workout was saved; the others in the call are checked on their
 * own.
 */
export const AGENT_WORKOUT_CAPS = {
  too_many_workouts:
    `The owner's account already holds ${grouped(DomainLimits.workoutsMax)} workouts, deleted ones included, the ` +
    'most it can. This workout was not added.',
  too_many_logged_exercises:
    `The owner's account already holds ${grouped(DomainLimits.accountEntriesMax)} logged exercises, deleted ` +
    'workouts included, the most it can. This workout was not added.',
  too_many_logged_sets:
    `The owner's account already holds ${grouped(DomainLimits.accountSetsMax)} logged sets, deleted workouts ` +
    'included, the most it can. This workout was not added.',
  too_many_workout_exercises:
    `A workout can have up to ${DomainLimits.workoutEntriesMax} exercises. This workout was not added: split it ` +
    'into several.',
  too_many_exercise_sets:
    `An exercise in a workout can have up to ${DomainLimits.entrySetsMax} sets. This workout was not added: split ` +
    'it into several.',
} as const
```

The app's own words (`ACCOUNT_CAPS`, `WORKOUT_CAPS`) say "This one stays on this iPhone", which is wrong for an agent.

- [ ] **Step 4: One save batch, and addWorkout, in `server/src/sync/workouts.ts`**

Replace

```ts
const UPSERT = `INSERT INTO workouts (${names(WORKOUT)}, user_id, write_id, updated_at)
VALUES (${WORKOUT.map((_, i) => `?${i + 1}`).join(', ')}, ?14, ?15, ${NOW_SQL})
```

with

```ts
/**
 * ?14 the caller, ?15 the write id, ?16 force, ?17 the base version, ?18 added_by. added_by is written when the row is
 * inserted and never updated, so a save from the app (?18 null) keeps an agent's name (plan 32).
 */
const UPSERT = `INSERT INTO workouts (${names(WORKOUT)}, user_id, write_id, added_by, updated_at)
VALUES (${WORKOUT.map((_, i) => `?${i + 1}`).join(', ')}, ?14, ?15, ?18, ${NOW_SQL})
```

(the `ON CONFLICT … DO UPDATE SET` lines below it stay as they are: they list `WORKOUT`'s columns, without
`added_by`).

Then replace the end of `pushWorkout`,

```ts
  const entryRows = entries.map(({ row }) => ({ ...row, gym_equipment_id: listings.get(row.id as string) ?? null }))
  const setRows = entries.flatMap(({ row, sets }) => sets.map((set) => ({ ...set, entry_id: row.id })))
  const writeId = crypto.randomUUID()
  const values = WORKOUT.map((c) => {
    if (c.name === 'client_updated_at') return storedEdit
    if (c.name === 'gym_id') return gymId
    return workout[c.name]
  })
  const results = await db.batch([
    db.prepare(UPSERT).bind(...values, userId, writeId, force ? 1 : 0, base),
    db.prepare(MOVE_ENTRIES).bind(id, writeId, userId, entryRows.length),
    db.prepare(MOVE_SETS).bind(id, writeId, userId, setRows.length),
    db.prepare(DELETE_ENTRIES).bind(id, writeId),
    db.prepare(INSERT_ENTRIES).bind(id, writeId, userId, JSON.stringify(entryRows)),
    db.prepare(INSERT_SETS).bind(id, writeId, userId, JSON.stringify(setRows)),
    db.prepare('SELECT updated_at, write_id FROM workouts WHERE id = ?1').bind(id),
  ])
  const after = results[6].results[0] as { updated_at: string; write_id: string }
  return { status: after.write_id === writeId ? 'ok' : 'stale', updated_at: after.updated_at }
}
```

with

```ts
  const entryRows = entries.map(({ row }) => ({ ...row, gym_equipment_id: listings.get(row.id as string) ?? null }))
  const values = WORKOUT.map((c) => {
    if (c.name === 'client_updated_at') return storedEdit
    if (c.name === 'gym_id') return gymId
    return workout[c.name]
  })
  return await writeSave(db, userId, { id, values, entryRows, setRows: setRowsOf(entries), force, base, addedBy: null })
}

/**
 * A past workout an agent adds with log_workout (plan 32, src/mcp/d1-db.ts): parsed and capped as a save from the app
 * is, and written by the same batch, so the per-workout caps, the account's caps and its logged counts all hold. Its
 * id is new (the caller makes it), so there is no stored row to read first; it has no gym and no listings. added_by
 * names the agent, and no later save changes it.
 */
export async function addWorkout(
  db: D1Database,
  userId: string,
  body: unknown,
  addedBy: string,
): Promise<WorkoutPushResult> {
  const { workout, entries } = parseWorkout(body)
  const entryRows = entries.map(({ row }) => ({ ...row, gym_equipment_id: null }))
  const values = WORKOUT.map((c) => (c.name === 'gym_id' ? null : workout[c.name]))
  return await writeSave(db, userId, {
    id: workout.id as string,
    values,
    entryRows,
    setRows: setRowsOf(entries),
    force: false,
    base: null,
    addedBy,
  })
}

/** Every set of the save, each naming its entry. */
const setRowsOf = (entries: Parsed['entries']) =>
  entries.flatMap(({ row, sets }) => sets.map((set) => ({ ...set, entry_id: row.id })))

/** One save's rows, ready for its batch. */
interface Save {
  readonly id: string
  /** The WORKOUT columns' values, in their order. */
  readonly values: readonly unknown[]
  readonly entryRows: readonly Record<string, unknown>[]
  readonly setRows: readonly Record<string, unknown>[]
  readonly force: boolean
  readonly base: string | null
  /** Written only when the save inserts the row. */
  readonly addedBy: string | null
}

/**
 * The save's batch: the row, the moves of the logged counts, the entries and sets (only while the row is still this
 * save's), then the stored stamp and whether this save won.
 */
async function writeSave(db: D1Database, userId: string, s: Save): Promise<WorkoutPushResult> {
  const writeId = crypto.randomUUID()
  const results = await db.batch([
    db.prepare(UPSERT).bind(...s.values, userId, writeId, s.force ? 1 : 0, s.base, s.addedBy),
    db.prepare(MOVE_ENTRIES).bind(s.id, writeId, userId, s.entryRows.length),
    db.prepare(MOVE_SETS).bind(s.id, writeId, userId, s.setRows.length),
    db.prepare(DELETE_ENTRIES).bind(s.id, writeId),
    db.prepare(INSERT_ENTRIES).bind(s.id, writeId, userId, JSON.stringify(s.entryRows)),
    db.prepare(INSERT_SETS).bind(s.id, writeId, userId, JSON.stringify(s.setRows)),
    db.prepare('SELECT updated_at, write_id FROM workouts WHERE id = ?1').bind(s.id),
  ])
  const after = results[6].results[0] as { updated_at: string; write_id: string }
  return { status: after.write_id === writeId ? 'ok' : 'stale', updated_at: after.updated_at }
}
```

`pushWorkout` does exactly what it did; plan 31's count statements (`MOVE_ENTRIES`, `MOVE_SETS`) stay the only writers of
the logged counts, and their comment ("exact while this save is the only writer of entries and sets") still holds:
`addWorkout` is this save.

- [ ] **Step 5: The Db's new surface, in `server/src/mcp/db.ts`**

Replace

```ts
export interface Db {
```

with

```ts
/** One set of a workout log_workout adds (plan 32): what the agent sent, checked, in kg. */
export interface LoggedSet {
  reps: number
  weight_kg: number
  sec: number | null
  dist_m: number | null
  warmup: boolean
}

/** A workout log_workout adds: times in the stored form, ended_at after started_at, exercises in order. */
export interface LoggedWorkout {
  started_at: string
  ended_at: string
  name: string
  note: string | null
  exercises: { exercise_id: string; sets: LoggedSet[] }[]
}

/** What became of one workout log_workout added: its new id, or the cap or rule that refused it. */
export type WorkoutAdded =
  | { added: true; id: string }
  | { added: false; reason: string; message: string }

export interface Db {
```

and replace

```ts
  insertBodyweight(r: { id: string; measured_at: string; w_kg: number; bf_pct?: number }): Promise<void>
```

with

```ts
  insertBodyweight(r: { id: string; measured_at: string; w_kg: number; bf_pct?: number }): Promise<void>
  /** The owner's Add workouts switch (profiles.mcp_log_workouts): false when no profile is saved, its default. */
  mayLogWorkouts(): Promise<boolean>
  /**
   * Which of `ids` a workout may log: library ids and the owner's custom exercises that aren't deleted, whatever
   * mcp_read_plan says.
   */
  loggableExerciseIds(ids: string[]): Promise<Set<string>>
  /** The calling client's registered name (1 to 64 characters), or null. */
  agentName(): Promise<string | null>
  /**
   * A new workout in the owner's history, marked as added by `addedBy`, while Add workouts is on (else ToolError).
   * A cap's refusal, or a value D1 refuses, is the answer, not an error.
   */
  insertWorkout(w: LoggedWorkout, addedBy: string): Promise<WorkoutAdded>
```

- [ ] **Step 6: D1Db, in `server/src/mcp/d1-db.ts`**

Replace the imports

```ts
import { raisedCode } from '../http/errors.ts'
import { CLAUDE_CAPS } from '../sync/caps.ts'
import { inJson } from '../sync/sql.ts'
import { normalizeTimestamp, NOW_SQL } from '../sync/time.ts'
```

with

```ts
import { ApiError, constraintMessage, raisedCode } from '../http/errors.ts'
import { AGENT_WORKOUT_CAPS, CLAUDE_CAPS } from '../sync/caps.ts'
import { RowError } from '../sync/columns.ts'
import { inJson } from '../sync/sql.ts'
import { normalizeTimestamp, NOW_SQL } from '../sync/time.ts'
import { addWorkout } from '../sync/workouts.ts'
```

In the type import from `./db.ts`, replace

```ts
  GymRow,
  MuscleTargetRow,
```

with

```ts
  GymRow,
  LoggedWorkout,
  MuscleTargetRow,
```

and

```ts
  WorkoutQuery,
  WorkoutRow,
} from './db.ts'
```

with

```ts
  WorkoutAdded,
  WorkoutQuery,
  WorkoutRow,
} from './db.ts'
```

Replace `Permissions`:

```ts
export interface Permissions {
  plan: boolean
  workouts: boolean
  body: boolean
  gyms: boolean
  propose: boolean
}
```

with

```ts
export interface Permissions {
  plan: boolean
  workouts: boolean
  body: boolean
  gyms: boolean
  propose: boolean
  /** Add workouts (plan 32): off by default, so off without a profile too. */
  logWorkouts: boolean
}
```

Replace the query in `allowed()`:

```ts
    this.permissions ??= this.db.prepare(
      'SELECT mcp_read_plan, mcp_read_workouts, mcp_read_body, mcp_read_gyms, mcp_propose FROM profiles ' +
        'WHERE user_id = ?1',
    ).bind(this.userId).first<Raw>().then((p) => ({
      plan: p ? bool(p.mcp_read_plan) : true,
      workouts: p ? bool(p.mcp_read_workouts) : true,
      body: p ? bool(p.mcp_read_body) : true,
      gyms: p ? bool(p.mcp_read_gyms) : true,
      propose: p ? bool(p.mcp_propose) : true,
    }))
```

with

```ts
    this.permissions ??= this.db.prepare(
      'SELECT mcp_read_plan, mcp_read_workouts, mcp_read_body, mcp_read_gyms, mcp_propose, mcp_log_workouts ' +
        'FROM profiles WHERE user_id = ?1',
    ).bind(this.userId).first<Raw>().then((p) => ({
      plan: p ? bool(p.mcp_read_plan) : true,
      workouts: p ? bool(p.mcp_read_workouts) : true,
      body: p ? bool(p.mcp_read_body) : true,
      gyms: p ? bool(p.mcp_read_gyms) : true,
      propose: p ? bool(p.mcp_propose) : true,
      logWorkouts: p ? bool(p.mcp_log_workouts) : false,
    }))
```

Above `/** \`write\`, with the refusal of one of its caps …` (below Task S4's `agentNameSql`), add:

```ts
/**
 * Why the save refused a workout log_workout adds, as its refusal: a cap's code with an agent's words, or `invalid`
 * with what D1 or the save's parser refused (the tool checks values first, so this is the backstop). Null for any
 * other error, which stays an error.
 */
function workoutRefusal(error: unknown): { reason: string; message: string } | null {
  const code = error instanceof ApiError ? error.code : raisedCode(error)
  if (code !== null && Object.hasOwn(AGENT_WORKOUT_CAPS, code)) {
    return { reason: code, message: AGENT_WORKOUT_CAPS[code as keyof typeof AGENT_WORKOUT_CAPS] }
  }
  if (error instanceof RowError) return { reason: 'invalid', message: error.message }
  const constraint = constraintMessage(error)
  return constraint === null ? null : { reason: 'invalid', message: constraint }
}

/**
 * A workout log_workout adds, as the app's save sends one (src/sync/workouts.ts): an import with done sets, no gym,
 * no routine and no records, and its volume as the app counts it (working sets, weight × reps).
 */
function loggedBody(id: string, w: LoggedWorkout, editedAt: string): Record<string, unknown> {
  const working = w.exercises.flatMap((e) => e.sets).filter((s) => !s.warmup)
  return {
    id,
    started_at: w.started_at,
    ended_at: w.ended_at,
    paused_sec: 0,
    routine_id: null,
    name: w.name,
    source: 'import',
    note: w.note,
    vol_kg: working.reduce((sum, s) => sum + s.weight_kg * s.reps, 0),
    records: [],
    gym_id: null,
    client_updated_at: editedAt,
    deleted_at: null,
    entries: w.exercises.map((e, position) => ({
      id: crypto.randomUUID(),
      exercise_id: e.exercise_id,
      position,
      sets: e.sets.map((s, j) => ({
        id: crypto.randomUUID(),
        position: j,
        w_kg: s.weight_kg,
        r: s.reps,
        sec: s.sec,
        dist_m: s.dist_m,
        done: true,
        warmup: s.warmup,
        multiplier: 1,
      })),
    })),
  }
}

```

And in the class, replace

```ts
  async audit(tool: string, ok: boolean, argsDigest: string): Promise<void> {
```

with

```ts
  async mayLogWorkouts(): Promise<boolean> {
    return (await this.allowed()).logWorkouts
  }

  /** The agent's own ids, checked: the answer says only which of them exist. */
  async loggableExerciseIds(list: string[]): Promise<Set<string>> {
    if (list.length === 0) return new Set()
    const rows = await this.all<{ id: string }>(
      `SELECT id FROM exercises WHERE ${inJson('id', '?2')} UNION ` +
        `SELECT id FROM custom_exercises WHERE user_id = ?1 AND deleted_at IS NULL AND ${inJson('id', '?2')}`,
      this.userId,
      ids(list),
    )
    return new Set(rows.map((r) => r.id))
  }

  async agentName(): Promise<string | null> {
    const row = await this.db.prepare(`SELECT ${agentNameSql('?1')} AS name`).bind(this.clientId)
      .first<{ name: string | null }>()
    return row?.name ?? null
  }

  /** A new workout, while Add workouts is on, through the app's own save (src/sync/workouts.ts, addWorkout). */
  async insertWorkout(w: LoggedWorkout, addedBy: string): Promise<WorkoutAdded> {
    if (!(await this.allowed()).logWorkouts) throw new ToolError(NOT_ALLOWED)
    const id = crypto.randomUUID()
    try {
      const saved = await addWorkout(this.db, this.userId, loggedBody(id, w, stamp(new Date().toISOString())), addedBy)
      // A fresh random id can't meet a stored row; if one ever did, the save answers stale, and that is an error.
      if (saved.status !== 'ok') throw new Error(`log_workout: workout ${id} met a stored row`)
      return { added: true, id }
    } catch (error) {
      const refusal = workoutRefusal(error)
      if (refusal === null) throw error
      return { added: false, ...refusal }
    }
  }

  async audit(tool: string, ok: boolean, argsDigest: string): Promise<void> {
```

`ids()` dedupes the list, so the tool may pass an id more than once.

- [ ] **Step 7: FakeDb, in `server/test/mcp/fake-db.ts`**

In the type import, replace

```ts
  GymRow,
  MuscleTargetRow,
```

with

```ts
  GymRow,
  LoggedWorkout,
  MuscleTargetRow,
```

and

```ts
  WorkoutQuery,
  WorkoutRow,
} from '../../src/mcp/db.ts'
```

with

```ts
  WorkoutAdded,
  WorkoutQuery,
  WorkoutRow,
} from '../../src/mcp/db.ts'
```

Then replace

```ts
  audit(tool: string, ok: boolean, argsDigest: string): Promise<void> {
```

with

```ts
  /** The Add workouts switch; off unless a test turns it on. */
  logWorkouts = false
  readonly insertedWorkouts: { workout: LoggedWorkout; addedBy: string }[] = []
  /** The calling client's name (D1Db reads oauthClient). */
  agent: string | null = 'Claude'

  mayLogWorkouts(): Promise<boolean> {
    return Promise.resolve(this.logWorkouts)
  }

  loggableExerciseIds(ids: string[]): Promise<Set<string>> {
    const known = new Set(this.allExercises.map((e) => e.id))
    return Promise.resolve(new Set(ids.filter((id) => known.has(id))))
  }

  agentName(): Promise<string | null> {
    return Promise.resolve(this.agent)
  }

  insertWorkout(workout: LoggedWorkout, addedBy: string): Promise<WorkoutAdded> {
    this.insertedWorkouts.push({ workout, addedBy })
    return Promise.resolve({ added: true, id: `workout-${this.insertedWorkouts.length}` })
  }

  audit(tool: string, ok: boolean, argsDigest: string): Promise<void> {
```

- [ ] **Step 8: The write surface, in `server/test/mcp/d1-db.test.ts`**

Replace

```ts
  it('has no other way to change data than proposals, body weight, the audit and the call slots', () => {
    const methods = Object.getOwnPropertyNames(D1Db.prototype).filter((m) =>
      /^(insert|update|delete|upsert|save|set)/i.test(m)
    )
    expect(methods.sort()).toEqual(['insertBodyweight', 'insertProposal'])
  })
```

with

```ts
  it('has no other way to change data than proposals, body weight, added workouts, the audit and the call slots', () => {
    const methods = Object.getOwnPropertyNames(D1Db.prototype).filter((m) =>
      /^(insert|update|delete|upsert|save|set)/i.test(m)
    )
    expect(methods.sort()).toEqual(['insertBodyweight', 'insertProposal', 'insertWorkout'])
  })
```

- [ ] **Step 9: Run the tests to see them pass**

Run: `cd server && npx vitest run test/mcp/d1-workouts.test.ts test/mcp/d1-db.test.ts test/sync-workouts.test.ts test/account-caps.test.ts`
Expected: PASS, `Test Files  4 passed (4)`, `Tests  83 passed (83)`.

- [ ] **Step 10: Everything**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  52 passed (52)`, `Tests  720 passed (720)`; `tsc` prints nothing.

- [ ] **Step 11: Commit**

```bash
git add server/src/sync/caps.ts server/src/sync/workouts.ts server/src/mcp/db.ts server/src/mcp/d1-db.ts \
  server/test/mcp/fake-db.ts server/test/mcp/d1-db.test.ts server/test/mcp/d1-workouts.test.ts
git commit -m "feat(server): an agent's workout is written by the app's own save, marked added_by"
```

---

### Task S8: The log_workout tool (switch, checks, exercises, writes)

**Files:**
- Create: `server/src/mcp/tools/log-workout.ts`
- Modify: `server/src/mcp/tools/schemas.ts`, `server/src/mcp/tools/register.ts`, `server/src/mcp/db.ts`,
  `server/src/mcp/d1-db.ts`, `server/src/mcp/tools/read.ts`, `server/test/mcp/tools/read.test.ts`,
  `server/test/mcp/app.test.ts`, `server/test/claude-connection.test.ts`
- Test: `server/test/mcp/tools/log-workout.test.ts`, `server/test/log-workout.test.ts`

- [ ] **Step 1: Write the failing unit tests (FakeDb)**

`server/test/mcp/tools/log-workout.test.ts`:

```ts
// log_workout's rules (plan 32; docs/specs/2026-11-09-ai-agents-design.md, section 3.4) on FakeDb: the switch, each
// workout's checks, and what reaches the Db. test/log-workout.test.ts runs the tool against D1 through /mcp.
import { describe, expect, it } from 'vitest'
import { DomainLimits } from '../../../src/shared/domain-limits.ts'
import { AGENT_WORKOUT_CAPS } from '../../../src/sync/caps.ts'
import {
  type LogWorkoutArgs,
  logWorkouts,
  NOT_ALLOWED_WORKOUTS,
  UNNAMED_AGENT,
} from '../../../src/mcp/tools/log-workout.ts'
import type { ToolResult } from '../../../src/mcp/tools/result.ts'
import { FakeDb, loadOwnerData } from '../fake-db.ts'

const NOW = new Date('2026-11-09T12:00:00Z')
type WorkoutArg = LogWorkoutArgs['workouts'][number]

const UPPER: WorkoutArg = {
  started_at: '2026-10-08T17:02:00Z',
  ended_at: '2026-10-08T18:05:00+00:00',
  name: '  Upper ',
  note: ' From Fitbod ',
  exercises: [{ exercise_id: '0025', sets: [{ reps: 8, weight_kg: 63.5 }, { reps: 10, weight_kg: 20, warmup: true }] }],
}

/** UPPER `days` days later, so workouts in one call don't overlap. */
function later(days: number, overrides: Partial<WorkoutArg> = {}): WorkoutArg {
  const shift = (iso: string) => new Date(Date.parse(iso) + days * 86_400_000).toISOString()
  return { ...UPPER, started_at: shift(UPPER.started_at), ended_at: shift(UPPER.ended_at), ...overrides }
}

async function fakeDb(logWorkouts = true): Promise<FakeDb> {
  const db = new FakeDb(await loadOwnerData())
  db.logWorkouts = logWorkouts
  return db
}

const run = (db: FakeDb, workouts: WorkoutArg[]) => logWorkouts({ db, now: NOW }, { workouts })
const results = (r: ToolResult) => JSON.parse(r.content[0]!.text).results

describe('the Add workouts switch', () => {
  it('refuses every workout while it is off, and reads nothing else', async () => {
    const db = await fakeDb(false)
    const read = () => {
      throw new Error('read while not allowed')
    }
    db.loggableExerciseIds = read
    db.agentName = read
    const r = await run(db, [UPPER, later(1)])
    expect(r.isError).toBe(true)
    expect(results(r)).toEqual([0, 1].map((index) => ({
      index,
      status: 'refused',
      reason: 'not_allowed',
      message: NOT_ALLOWED_WORKOUTS,
    })))
    expect(db.insertedWorkouts).toEqual([])
  })
})

describe('each workout', () => {
  it('reaches the Db checked: times in the stored form, trimmed text, warm-ups flagged, the agent named', async () => {
    const db = await fakeDb()
    const r = await run(db, [UPPER, later(1, { name: undefined, note: '  ' })])
    expect(r.isError).toBeUndefined()
    expect(results(r)).toEqual([
      { index: 0, status: 'added', workout_id: 'workout-1' },
      { index: 1, status: 'added', workout_id: 'workout-2' },
    ])
    expect(db.insertedWorkouts[0]).toEqual({
      addedBy: 'Claude',
      workout: {
        started_at: '2026-10-08T17:02:00.000000Z',
        ended_at: '2026-10-08T18:05:00.000000Z',
        name: 'Upper',
        note: 'From Fitbod',
        exercises: [{
          exercise_id: '0025',
          sets: [
            { reps: 8, weight_kg: 63.5, sec: null, dist_m: null, warmup: false },
            { reps: 10, weight_kg: 20, sec: null, dist_m: null, warmup: true },
          ],
        }],
      },
    })
    expect(db.insertedWorkouts[1]!.workout).toMatchObject({ name: 'Workout', note: null })
  })

  it(`is marked "${UNNAMED_AGENT}" when the client registered no name`, async () => {
    const db = await fakeDb()
    db.agent = null
    await run(db, [UPPER])
    expect(db.insertedWorkouts.map((w) => w.addedBy)).toEqual([UNNAMED_AGENT])
  })

  it('is refused as invalid for bad times, alone, while the others are added', async () => {
    const db = await fakeDb()
    const r = await run(db, [
      later(0, { ended_at: UPPER.started_at }),
      later(1, { started_at: 'yesterday' }),
      later(2, { ended_at: '2026-11-09T12:06:00Z', started_at: '2026-11-09T11:00:00Z' }),
      later(3, { ended_at: later(4).ended_at }),
      later(5),
    ])
    expect(results(r)).toEqual([
      { index: 0, status: 'refused', reason: 'invalid', message: 'ended_at must be after started_at.' },
      {
        index: 1,
        status: 'refused',
        reason: 'invalid',
        message: "started_at isn't a timestamp like 2026-10-08T17:02:00Z.",
      },
      { index: 2, status: 'refused', reason: 'invalid', message: 'The workout ends in the future.' },
      { index: 3, status: 'refused', reason: 'invalid', message: 'A workout can last at most 24 hours.' },
      { index: 4, status: 'added', workout_id: 'workout-1' },
    ])
  })

  it('takes a workout that ends up to 5 minutes past the clock', async () => {
    const db = await fakeDb()
    const r = await run(db, [later(0, { started_at: '2026-11-09T11:00:00Z', ended_at: '2026-11-09T12:05:00Z' })])
    expect(results(r)).toEqual([{ index: 0, status: 'added', workout_id: 'workout-1' }])
  })

  it('is refused as invalid for a value out of range, naming it', async () => {
    const db = await fakeDb()
    const set = (s: Record<string, unknown>) =>
      later(0, { exercises: [{ exercise_id: '0025', sets: [{ reps: 8, weight_kg: 60, ...s }] }] })
    const r = await run(db, [
      set({ reps: 1001 }),
      set({ weight_kg: -1 }),
      set({ sec: 86_401 }),
      set({ dist_m: 1_000_001 }),
      later(0, { name: 'x'.repeat(DomainLimits.workoutNameMax + 1) }),
      later(0, { exercises: [] }),
      later(0, { exercises: [{ exercise_id: '0025', sets: [] }] }),
    ])
    expect(results(r).map((x: { message: string }) => x.message)).toEqual([
      'exercises[0].sets[0].reps must be 0–1,000.',
      'exercises[0].sets[0].weight_kg must be 0–1,000.',
      'exercises[0].sets[0].sec must be 0–86,400.',
      'exercises[0].sets[0].dist_m must be 0–1,000,000.',
      'name must be 1–80 characters.',
      'A workout needs at least one exercise.',
      'exercises[0] needs at least one set.',
    ])
    expect(results(r).every((x: { reason: string }) => x.reason === 'invalid')).toBe(true)
    expect(r.isError).toBe(true)
    expect(db.insertedWorkouts).toEqual([])
  })

  it("is refused past one workout's caps, with the cap's code", async () => {
    const db = await fakeDb()
    const exercise = UPPER.exercises[0]!
    const r = await run(db, [
      later(0, { exercises: Array.from({ length: DomainLimits.workoutEntriesMax + 1 }, () => exercise) }),
      later(1, {
        exercises: [{ exercise_id: '0025', sets: Array.from({ length: DomainLimits.entrySetsMax + 1 }, () => exercise.sets[0]!) }],
      }),
      later(2, { exercises: Array.from({ length: DomainLimits.workoutEntriesMax }, () => exercise) }),
    ])
    expect(results(r)).toEqual([
      {
        index: 0,
        status: 'refused',
        reason: 'too_many_workout_exercises',
        message: AGENT_WORKOUT_CAPS.too_many_workout_exercises,
      },
      { index: 1, status: 'refused', reason: 'too_many_exercise_sets', message: AGENT_WORKOUT_CAPS.too_many_exercise_sets },
      { index: 2, status: 'added', workout_id: 'workout-1' },
    ])
  })

  it('is refused as unknown_exercise when an id is neither a library id nor a custom exercise, naming them', async () => {
    const db = await fakeDb()
    const r = await run(db, [
      later(0, { exercises: [{ exercise_id: 'nope', sets: [{ reps: 5, weight_kg: 50 }] }, ...UPPER.exercises] }),
      later(1, {
        exercises: [
          { exercise_id: 'zzz', sets: [{ reps: 5, weight_kg: 50 }] },
          { exercise_id: 'nope', sets: [{ reps: 5, weight_kg: 50 }] },
          { exercise_id: 'zzz', sets: [{ reps: 5, weight_kg: 50 }] },
        ],
      }),
    ])
    expect(results(r)).toEqual([
      {
        index: 0,
        status: 'refused',
        reason: 'unknown_exercise',
        message: "Unknown exercise id: nope. Use search_exercises for library ids and the owner's custom exercises.",
      },
      {
        index: 1,
        status: 'refused',
        reason: 'unknown_exercise',
        message: "Unknown exercise ids: zzz, nope. Use search_exercises for library ids and the owner's custom exercises.",
      },
    ])
  })
})
```

`FakeDb`'s library holds `'0025'` (`test/mcp/testdata/owner.json`); its workouts are in September 2026, so none of
these times meets them (Task S9 reads them).

- [ ] **Step 2: Write the failing integration tests (D1, through /mcp)**

`server/test/log-workout.test.ts`:

```ts
// log_workout through /mcp against D1 (plan 32; docs/specs/2026-11-09-ai-agents-design.md, sections 3.4 and 5): an
// agent adds past workouts behind the owner's Add workouts switch, each checked on its own, and the phone pulls them
// marked with the agent's name.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { NOT_ALLOWED_WORKOUTS } from '../src/mcp/tools/log-workout.ts'
import { DomainLimits } from '../src/shared/domain-limits.ts'
import { AGENT_WORKOUT_CAPS } from '../src/sync/caps.ts'
import { countOf, seedRows } from './cap-fixtures.ts'
import { connectAgent, connectClaude, type Connection, mcp } from './claude.ts'
import { request } from './helpers.ts'
import { readRpc, toolJson } from './mcp/rpc.ts'

const T = '2026-11-07T10:00:00.000000Z'

interface Result {
  index: number
  status: 'added' | 'refused'
  workout_id?: string
  reason?: string
  message?: string
}

/** A past session on 2026-10-`day`, 17:00 to 18:00 UTC, with `overrides`. */
function session(day: number, overrides: Record<string, unknown> = {}) {
  const date = `2026-10-${String(day).padStart(2, '0')}`
  return {
    started_at: `${date}T17:00:00Z`,
    ended_at: `${date}T18:00:00Z`,
    name: 'Upper',
    exercises: [{ exercise_id: '0025', sets: [{ reps: 8, weight_kg: 63.5 }, { reps: 8, weight_kg: 63.5 }] }],
    ...overrides,
  }
}

/** A connected account whose profile has Add workouts on, unless `on` is false. */
async function owner(on = true): Promise<Connection> {
  const c = await connectClaude()
  await env.DB.prepare(
    'INSERT INTO profiles (user_id, mcp_log_workouts, client_updated_at, updated_at) VALUES (?1, ?2, ?3, ?3)',
  ).bind(c.userId, on ? 1 : 0, T).run()
  return c
}

async function logWorkout(token: string, workouts: unknown[]): Promise<{ isError: boolean; results: Result[] }> {
  const msg = await readRpc(await mcp(token, 'tools/call', { name: 'log_workout', arguments: { workouts } }, 2))
  return { isError: msg.result.isError === true, results: toolJson(msg).results }
}

async function pulled(appToken: string): Promise<Record<string, any>[]> {
  const res = await request('GET', '/v1/sync/workouts', { token: appToken })
  expect(res.status).toBe(200)
  return (await res.json<{ rows: Record<string, any>[] }>()).rows
}

const lastAudit = (userId: string) =>
  env.DB.prepare("SELECT ok FROM mcp_audit WHERE user_id = ?1 AND tool = 'log_workout' ORDER BY id DESC LIMIT 1")
    .bind(userId).first()

describe('log_workout', () => {
  it('adds past workouts to the history, marked with the agent, and the phone pulls them', async () => {
    const c = await owner()
    const { isError, results } = await logWorkout(c.tokens.access_token, [session(6), session(8)])
    expect(isError).toBe(false)
    expect(results).toEqual([
      { index: 0, status: 'added', workout_id: expect.stringMatching(/^[0-9a-f-]{36}$/) },
      { index: 1, status: 'added', workout_id: expect.stringMatching(/^[0-9a-f-]{36}$/) },
    ])
    const rows = await pulled(c.appToken)
    expect(rows.map((w) => w.id).sort()).toEqual(results.map((r) => r.workout_id).sort())
    expect(rows.find((w) => w.id === results[0]!.workout_id)).toMatchObject({
      started_at: '2026-10-06T17:00:00.000000Z',
      ended_at: '2026-10-06T18:00:00.000000Z',
      name: 'Upper',
      source: 'import',
      added_by: 'Claude Code',
      vol_kg: 1016,
      entries: [{ exercise_id: '0025', sets: [{ w_kg: 63.5, r: 8, done: true }, { w_kg: 63.5, r: 8, done: true }] }],
    })
    expect(await lastAudit(c.userId)).toEqual({ ok: 1 })
  })

  it('marks a workout "Agent" when its client registered no name', async () => {
    const c = await owner()
    const unnamed = await connectAgent(c.appToken)
    expect((await logWorkout(unnamed.tokens.access_token, [session(6)])).results[0]!.status).toBe('added')
    expect((await pulled(c.appToken)).map((w) => w.added_by)).toEqual(['Agent'])
  })

  it('refuses every workout while Add workouts is off, as a failed call, and adds nothing', async () => {
    for (const c of [await owner(false), await connectClaude()]) {
      const { isError, results } = await logWorkout(c.tokens.access_token, [session(6), session(8)])
      expect(isError).toBe(true)
      expect(results).toEqual([0, 1].map((index) => ({
        index,
        status: 'refused',
        reason: 'not_allowed',
        message: NOT_ALLOWED_WORKOUTS,
      })))
      expect(await countOf('workouts', c.userId)).toBe(0)
      expect(await lastAudit(c.userId)).toEqual({ ok: 0 })
    }
  })

  it("takes the owner's custom exercise, and refuses only the workout naming an unknown one", async () => {
    const c = await owner()
    const custom = `custom-${crypto.randomUUID()}`
    await env.DB.prepare(
      'INSERT INTO custom_exercises (id, user_id, n, bp, eq, tg, mode, client_updated_at, updated_at) ' +
        "VALUES (?1, ?2, 'Sled push', 'upper legs', 'sled machine', 'quads', 'reps', ?3, ?3)",
    ).bind(custom, c.userId, T).run()
    const sets = [{ reps: 10, weight_kg: 90 }]
    const { isError, results } = await logWorkout(c.tokens.access_token, [
      session(6, { exercises: [{ exercise_id: custom, sets }] }),
      session(8, { exercises: [{ exercise_id: 'not-an-exercise', sets }] }),
    ])
    expect(isError).toBe(false)
    expect(results.map((r) => [r.status, r.reason])).toEqual([['added', undefined], ['refused', 'unknown_exercise']])
    expect(results[1]!.message).toContain('not-an-exercise')
    expect((await pulled(c.appToken)).map((w) => w.entries[0].exercise_id)).toEqual([custom])
  })

  it('refuses a workout with bad times as invalid, and adds the rest', async () => {
    const c = await owner()
    const { results } = await logWorkout(c.tokens.access_token, [
      session(6, { ended_at: '2026-10-06T16:00:00Z' }),
      session(7, { started_at: '2099-01-01T10:00:00Z', ended_at: '2099-01-01T11:00:00Z' }),
      session(8),
    ])
    expect(results.map((r) => r.reason ?? r.status)).toEqual(['invalid', 'invalid', 'added'])
    expect(await countOf('workouts', c.userId)).toBe(1)
  })

  it("refuses a workout past the account's cap with the cap's code", async () => {
    const c = await owner()
    await seedRows('workouts', c.userId, DomainLimits.workoutsMax - 1)
    const { results } = await logWorkout(c.tokens.access_token, [session(6), session(8)])
    expect(results).toEqual([
      { index: 0, status: 'added', workout_id: expect.any(String) },
      { index: 1, status: 'refused', reason: 'too_many_workouts', message: AGENT_WORKOUT_CAPS.too_many_workouts },
    ])
    expect(await countOf('workouts', c.userId)).toBe(DomainLimits.workoutsMax)
  })
})
```

- Each test makes at most a few calls, far under the 60 a minute.
- The seeded workouts are dated 2026-11-07 (`test/cap-fixtures.ts`), so none overlaps October once Task S9 checks.

- [ ] **Step 3: Run them to see them fail**

Run: `cd server && npx vitest run test/mcp/tools/log-workout.test.ts test/log-workout.test.ts`
Expected: FAIL: both files fail to load, because `src/mcp/tools/log-workout.ts` doesn't exist yet
(`Failed to load url ../../../src/mcp/tools/log-workout.ts` and `../src/mcp/tools/log-workout.ts`).

- [ ] **Step 4: The input schema, in `server/src/mcp/tools/schemas.ts`**

Replace

```ts
import { z } from 'zod'
import type { PlanChangeType } from '../../shared/plan-validation.ts'
```

with

```ts
import { z } from 'zod'
import { DomainLimits } from '../../shared/domain-limits.ts'
import type { PlanChangeType } from '../../shared/plan-validation.ts'
```

Replace

```ts
export const schemas = {
```

with

```ts
const range = ({ min, max }: { min: number; max: number }) => `${min}–${max}`

/**
 * One set of a past workout (log_workout), named as get_workout answers sets: reps, weight_kg, sec, dist_m, warmup
 * (the sync stores them as r, w_kg, sec, dist_m, warmup). Ranges are checked per workout, so one bad value refuses only
 * its workout; the types here are checked for the whole call.
 */
const loggedSet = z.object({
  reps: z.number().int().describe(`${range(DomainLimits.setReps)}; 0 for a timed or distance set`),
  weight_kg: z.number().describe(`kg, ${range(DomainLimits.setWeightKg)}; 0 for bodyweight`),
  sec: z.number().int().optional().describe(`Seconds, for a timed set: ${range(DomainLimits.setSeconds)}`),
  dist_m: z.number().optional().describe(`Metres, for a distance set: ${range(DomainLimits.setDistanceM)}`),
  warmup: z.boolean().optional().describe('true for a warm-up set. Default false'),
})

const loggedWorkout = z.object({
  started_at: isoDate.describe('When it started: an ISO 8601 timestamp with a time zone, e.g. 2026-10-08T17:02:00Z'),
  ended_at: isoDate.describe('When it ended: after started_at, at most 24 hours later, not in the future'),
  name: z.string().max(200).optional().describe(`1–${DomainLimits.workoutNameMax} characters. Default "Workout"`),
  note: z.string().max(1000).optional(),
  exercises: z.array(z.object({
    exercise_id: ref.describe("A library id from search_exercises, or one of the owner's custom exercise ids"),
    sets: z.array(loggedSet).describe(`1–${DomainLimits.entrySetsMax} sets, in the order done`),
  })).describe(`1–${DomainLimits.workoutEntriesMax} exercises, in the order done`),
})

export const schemas = {
```

and at the end of `schemas`, replace

```ts
  logBodyweight: z.object({
    weight_kg: z.number().min(30).max(300),
    date: isoDate.optional().describe('Default: now'),
    body_fat_pct: z.number().min(3).max(60).optional(),
  }),
}
```

with

```ts
  logBodyweight: z.object({
    weight_kg: z.number().min(30).max(300),
    date: isoDate.optional().describe('Default: now'),
    body_fat_pct: z.number().min(3).max(60).optional(),
  }),
  logWorkout: z.object({ workouts: z.array(loggedWorkout).min(1).max(5) }),
}
```

- zod checks the call's shape and types (a fractional `reps` refuses the whole call, as `propose_plan_changes`'s
  integer fields do). Every range, a too-long name and the per-workout caps are each workout's own refusal, so the
  arrays inside a workout have no zod bounds: the 256 KiB `/mcp` body limit (`src/mcp/app.ts`) bounds them.
- `name` (200) and `note` (1,000) have zod bounds only to keep a call small; `note` has no other limit
  (`workouts.note` has none).

- [ ] **Step 5: The tool, `server/src/mcp/tools/log-workout.ts`**

```ts
// log_workout (plan 32; docs/specs/2026-11-09-ai-agents-design.md, section 3.4): past workouts an agent adds
// straight to the owner's history, behind the Add workouts switch. Each workout is checked on its own, so one bad
// workout doesn't block the rest, and the result lists every one as added (with its id) or refused (with a reason).
import type { z } from 'zod'
import { DomainLimits } from '../../shared/domain-limits.ts'
import { AGENT_WORKOUT_CAPS, grouped } from '../../sync/caps.ts'
import { isStorableText } from '../../sync/columns.ts'
import { normalizeTimestamp } from '../../sync/time.ts'
import type { LoggedSet, LoggedWorkout } from '../db.ts'
import { ok, type ToolCtx, type ToolResult } from './result.ts'
import type { schemas } from './schemas.ts'

export type LogWorkoutArgs = z.infer<typeof schemas.logWorkout>
type WorkoutArg = LogWorkoutArgs['workouts'][number]
type SetArg = WorkoutArg['exercises'][number]['sets'][number]

/** A workout's name when the agent gives none. */
export const DEFAULT_WORKOUT_NAME = 'Workout'
/** added_by for a client that registered no name. */
export const UNNAMED_AGENT = 'Agent'
/** How far past the server's clock a workout may end: the agent's clock may run a little ahead. */
export const END_SLACK_MS = 5 * 60_000
/** The longest workout taken. A longer one is a mistake (a wrong date), and would block a day of others. */
export const MAX_WORKOUT_MS = 24 * 3_600_000
export const NOT_ALLOWED_WORKOUTS =
  "Not allowed: the owner hasn't turned on Add workouts for agents in the app. Nothing was added."

type Refused = { index: number; status: 'refused'; reason: string; message: string }
type Outcome = { index: number; status: 'added'; workout_id: string } | Refused

const refused = (index: number, reason: string, message: string): Refused => ({
  index,
  status: 'refused',
  reason,
  message,
})

/** The set fields with a range, as DomainLimits (and the D1 CHECKs) bound them. */
const SET_RANGES = [
  ['reps', DomainLimits.setReps],
  ['weight_kg', DomainLimits.setWeightKg],
  ['sec', DomainLimits.setSeconds],
  ['dist_m', DomainLimits.setDistanceM],
] as const

/** Milliseconds since the epoch of a time in the stored form (YYYY-MM-DDTHH:MM:SS.ffffffZ). */
const msOf = (stored: string) => Date.parse(`${stored.slice(0, 23)}Z`)

/** The first value out of range in a set, as words, or null. */
function setProblem(s: SetArg): string | null {
  for (const [field, { min, max }] of SET_RANGES) {
    const value = s[field]
    if (value !== undefined && (value < min || value > max)) {
      return `${field} must be ${grouped(min)}–${grouped(max)}.`
    }
  }
  return null
}

/** The workout's exercises, checked: the first problem, as a refusal, or the sets as the Db takes them. */
function checkedExercises(w: WorkoutArg, index: number): LoggedWorkout['exercises'] | Refused {
  if (w.exercises.length === 0) return refused(index, 'invalid', 'A workout needs at least one exercise.')
  if (w.exercises.length > DomainLimits.workoutEntriesMax) {
    return refused(index, 'too_many_workout_exercises', AGENT_WORKOUT_CAPS.too_many_workout_exercises)
  }
  const exercises: LoggedWorkout['exercises'] = []
  for (const [i, e] of w.exercises.entries()) {
    if (e.sets.length === 0) return refused(index, 'invalid', `exercises[${i}] needs at least one set.`)
    if (e.sets.length > DomainLimits.entrySetsMax) {
      return refused(index, 'too_many_exercise_sets', AGENT_WORKOUT_CAPS.too_many_exercise_sets)
    }
    const sets: LoggedSet[] = []
    for (const [j, s] of e.sets.entries()) {
      const problem = setProblem(s)
      if (problem !== null) return refused(index, 'invalid', `exercises[${i}].sets[${j}].${problem}`)
      sets.push({
        reps: s.reps,
        weight_kg: s.weight_kg,
        sec: s.sec ?? null,
        dist_m: s.dist_m ?? null,
        warmup: s.warmup ?? false,
      })
    }
    exercises.push({ exercise_id: e.exercise_id, sets })
  }
  return exercises
}

/** One workout, checked against everything but the exercise ids and the history: the Db's workout, or a refusal. */
function checked(w: WorkoutArg, index: number, now: Date): LoggedWorkout | Refused {
  const invalid = (message: string) => refused(index, 'invalid', message)
  const started = normalizeTimestamp(w.started_at)
  if (started === null) return invalid("started_at isn't a timestamp like 2026-10-08T17:02:00Z.")
  const ended = normalizeTimestamp(w.ended_at)
  if (ended === null) return invalid("ended_at isn't a timestamp like 2026-10-08T18:05:00Z.")
  if (ended <= started) return invalid('ended_at must be after started_at.')
  if (msOf(ended) > now.getTime() + END_SLACK_MS) return invalid('The workout ends in the future.')
  if (msOf(ended) - msOf(started) > MAX_WORKOUT_MS) return invalid('A workout can last at most 24 hours.')
  const name = w.name?.trim() || DEFAULT_WORKOUT_NAME
  if ([...name].length > DomainLimits.workoutNameMax || !isStorableText(name)) {
    return invalid(`name must be 1–${DomainLimits.workoutNameMax} characters.`)
  }
  const note = w.note?.trim() || null
  if (note !== null && !isStorableText(note)) return invalid('note has a character that cannot be stored.')
  const exercises = checkedExercises(w, index)
  if (!Array.isArray(exercises)) return exercises
  return { started_at: started, ended_at: ended, name, note, exercises }
}

const isRefused = (c: LoggedWorkout | Refused): c is Refused => 'status' in c

/** The ids among the workout's that the owner can't log, each once, in the order sent. */
const unknownIds = (w: LoggedWorkout, known: Set<string>) =>
  [...new Set(w.exercises.map((e) => e.exercise_id))].filter((id) => !known.has(id))

function unknownExercise(index: number, ids: string[]): Refused {
  const which = ids.length === 1 ? `id: ${ids[0]}` : `ids: ${ids.join(', ')}`
  return refused(
    index,
    'unknown_exercise',
    `Unknown exercise ${which}. Use search_exercises for library ids and the owner's custom exercises.`,
  )
}

/** The results, as an error for the client and the audit when nothing was added. */
function answer(results: Outcome[]): ToolResult {
  const result = ok({ results })
  return results.some((r) => r.status === 'added') ? result : { ...result, isError: true }
}

export async function logWorkouts({ db, now }: ToolCtx, args: LogWorkoutArgs): Promise<ToolResult> {
  if (!(await db.mayLogWorkouts())) {
    return answer(args.workouts.map((_, index) => refused(index, 'not_allowed', NOT_ALLOWED_WORKOUTS)))
  }
  const all = args.workouts.map((w, index) => checked(w, index, now))
  const candidates = all.filter((c): c is LoggedWorkout => !isRefused(c))
  if (candidates.length === 0) return answer(all as Refused[])
  const known = await db.loggableExerciseIds(candidates.flatMap((w) => w.exercises.map((e) => e.exercise_id)))
  const agent = (await db.agentName()) ?? UNNAMED_AGENT
  /** One checked workout, in the call's order: refused for its exercises, or written. */
  const add = async (w: LoggedWorkout, index: number): Promise<Outcome> => {
    const unknown = unknownIds(w, known)
    if (unknown.length > 0) return unknownExercise(index, unknown)
    const written = await db.insertWorkout(w, agent)
    if (!written.added) return refused(index, written.reason, written.message)
    return { index, status: 'added', workout_id: written.id }
  }
  const results: Outcome[] = []
  // One at a time: each write must see the ones before it.
  for (const [index, c] of all.entries()) results.push(isRefused(c) ? c : await add(c, index))
  return answer(results)
}
```

- `normalizeTimestamp` is the sync's own parser, so a time the app's history can hold is one this takes, and the
  stored form compares as text.
- The Db reads stay at three a call whatever the number of workouts (switch, exercises, name), plus one batch per
  workout written (decision 3).

- [ ] **Step 6: Register it, in `server/src/mcp/tools/register.ts`**

Replace

```ts
import { getProposal, logBodyweight, proposePlanChanges } from './write.ts'
```

with

```ts
import { logWorkouts } from './log-workout.ts'
import { getProposal, logBodyweight, proposePlanChanges } from './write.ts'
```

and at the end of `TOOL_SPECS`, replace

```ts
    input: schemas.logBodyweight,
    annotations: WRITE,
    run: (ctx, a) => logBodyweight(ctx, a),
  }),
]
```

with

```ts
    input: schemas.logBodyweight,
    annotations: WRITE,
    run: (ctx, a) => logBodyweight(ctx, a),
  }),
  spec({
    name: 'log_workout',
    title: 'Log past workouts',
    description:
      "Add past workouts the owner did to their history, straight away (they aren't reviewed first): up to 5 a " +
      'call, each with its start and end time, its exercises in order and their sets. Use it only for sessions ' +
      'missing from GymRollins (check list_workouts first). Weights are kg: convert from lb. exercise_id is a ' +
      "library id from search_exercises or one of the owner's custom exercises. Each workout is checked on its " +
      'own, and the result lists each one as added (with its workout_id) or refused with a reason: not_allowed (the ' +
      "owner hasn't allowed agents to add workouts), unknown_exercise, invalid, or a storage cap (too_many_…). " +
      'Only works if the owner allowed agents to add workouts.',
    input: schemas.logWorkout,
    annotations: WRITE,
    run: (ctx, a) => logWorkouts(ctx, a),
  }),
]
```

`WRITE` is the same annotation as `log_bodyweight`'s (`readOnlyHint: false`, `destructiveHint: false`).
`registerTools` appends `USER_DATA_NOTE` and audits every call through `runAudited`, as for every tool.

- [ ] **Step 7: get_profile shows the switch**

In `server/src/mcp/db.ts`, in `Profile`, replace

```ts
  mcp_propose: boolean
  mcp_auto_apply: boolean
```

with

```ts
  mcp_propose: boolean
  mcp_auto_apply: boolean
  /** Add workouts (plan 32); absent counts as off, its default. */
  mcp_log_workouts?: boolean
```

In `server/src/mcp/d1-db.ts`, in `profile()`, replace

```ts
        'mcp_auto_apply, sex, birth_year FROM profiles WHERE user_id = ?1',
```

with

```ts
        'mcp_auto_apply, mcp_log_workouts, sex, birth_year FROM profiles WHERE user_id = ?1',
```

and

```ts
      mcp_auto_apply: bool(p.mcp_auto_apply),
    } as Profile
```

with

```ts
      mcp_auto_apply: bool(p.mcp_auto_apply),
      mcp_log_workouts: bool(p.mcp_log_workouts),
    } as Profile
```

In `server/src/mcp/tools/read.ts`, in `getProfile`, replace

```ts
      propose: p.mcp_propose,
      auto_apply: p.mcp_auto_apply,
    },
```

with

```ts
      propose: p.mcp_propose,
      auto_apply: p.mcp_auto_apply,
      log_workouts: p.mcp_log_workouts ?? false,
    },
```

and in `server/test/mcp/tools/read.test.ts`, in "get_profile: unit, goal with display, limits, permissions", replace

```ts
    propose: true,
    auto_apply: false,
  })
})
```

with

```ts
    propose: true,
    auto_apply: false,
    log_workouts: false,
  })
})
```

(`owner.json`'s profile has no `mcp_log_workouts`: off.)

- [ ] **Step 8: Sixteen tools**

In `server/test/mcp/app.test.ts`, replace

```ts
test('initialize and tools/list: 15 tools with titles and annotations', async () => {
```

with

```ts
test('initialize and tools/list: 16 tools with titles and annotations', async () => {
```

and

```ts
  assertEquals(tools.length, 15)
  const writes = ['propose_plan_changes', 'log_bodyweight']
```

with

```ts
  assertEquals(tools.length, 16)
  const writes = ['propose_plan_changes', 'log_bodyweight', 'log_workout']
```

In `server/test/claude-connection.test.ts`, replace

```ts
  it("lists the 15 tools and calls one with the owner's data, audited", async () => {
```

with

```ts
  it("lists the 16 tools and calls one with the owner's data, audited", async () => {
```

and

```ts
    expect((await readRpc(await mcp(c.tokens.access_token, 'tools/list'))).result.tools).toHaveLength(15)
```

with

```ts
    expect((await readRpc(await mcp(c.tokens.access_token, 'tools/list'))).result.tools).toHaveLength(16)
```

- [ ] **Step 9: Run the tests to see them pass**

Run: `cd server && npx vitest run test/mcp test/log-workout.test.ts test/claude-connection.test.ts`
Expected: PASS; `test/mcp/tools/log-workout.test.ts` has 8 tests and `test/log-workout.test.ts` 6.

- [ ] **Step 10: Everything**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  54 passed (54)`, `Tests  734 passed (734)`; `tsc` prints nothing.

- [ ] **Step 11: Commit**

```bash
git add server/src/mcp/tools/log-workout.ts server/src/mcp/tools/schemas.ts server/src/mcp/tools/register.ts \
  server/src/mcp/db.ts server/src/mcp/d1-db.ts server/src/mcp/tools/read.ts server/test/mcp/tools/read.test.ts \
  server/test/mcp/app.test.ts server/test/claude-connection.test.ts server/test/mcp/tools/log-workout.test.ts \
  server/test/log-workout.test.ts
git commit -m "feat(server): log_workout adds an agent's past workouts behind the Add workouts switch"
```

---

### Task S9: log_workout refuses a workout whose time is taken

**Files:**
- Modify: `server/src/mcp/db.ts`, `server/src/mcp/d1-db.ts`, `server/test/mcp/fake-db.ts`,
  `server/src/mcp/tools/log-workout.ts`, `server/src/mcp/tools/register.ts`
- Test: `server/test/log-workout.test.ts`

- [ ] **Step 1: Write the failing tests**

In `server/test/log-workout.test.ts`, replace

```ts
import { request } from './helpers.ts'
```

with

```ts
import { request } from './helpers.ts'
import { workoutSample } from './samples.ts'
```

and add at the end of the file:

```ts

/** A workout the phone saved, from `started` to `ended` (null: none, as a Fitbod import has), deleted or not. */
async function savedByPhone(appToken: string, started: string, ended: string | null, deleted: string | null = null) {
  const res = await request('POST', '/v1/sync/workouts', {
    token: appToken,
    body: workoutSample({ started_at: started, ended_at: ended, deleted_at: deleted }),
  })
  expect(res.status).toBe(200)
}

const OVERLAPS_HISTORY = "It overlaps a workout already in the owner's history, so it was not added."

describe('log_workout and the time a workout takes', () => {
  it('refuses a workout overlapping one in the history, or one added earlier in the call', async () => {
    const c = await owner()
    await savedByPhone(c.appToken, '2026-10-06T17:30:00.000000Z', '2026-10-06T18:30:00.000000Z')
    const { isError, results } = await logWorkout(c.tokens.access_token, [
      session(6),
      session(8),
      session(8, { started_at: '2026-10-08T17:30:00Z', ended_at: '2026-10-08T18:30:00Z' }),
      session(9),
    ])
    expect(isError).toBe(false)
    expect(results).toEqual([
      { index: 0, status: 'refused', reason: 'overlaps', message: OVERLAPS_HISTORY },
      { index: 1, status: 'added', workout_id: expect.any(String) },
      {
        index: 2,
        status: 'refused',
        reason: 'overlaps',
        message: 'It overlaps workout 1 of this call, which was added, so it was not added.',
      },
      { index: 3, status: 'added', workout_id: expect.any(String) },
    ])
    expect(await countOf('workouts', c.userId)).toBe(3)
  })

  it('takes a stored workout with no end as the moment it started', async () => {
    const c = await owner()
    await savedByPhone(c.appToken, '2026-10-06T17:00:00.000000Z', null)
    await savedByPhone(c.appToken, '2026-10-07T17:30:00.000000Z', null)
    const { results } = await logWorkout(c.tokens.access_token, [
      session(6),
      session(7),
      session(7, { started_at: '2026-10-07T18:00:00Z', ended_at: '2026-10-07T19:00:00Z' }),
    ])
    expect(results.map((r) => r.reason ?? r.status)).toEqual(['overlaps', 'overlaps', 'added'])
  })

  it('ignores deleted workouts, and one that ends as the new one starts', async () => {
    const c = await owner()
    await savedByPhone(c.appToken, '2026-10-06T17:00:00.000000Z', '2026-10-06T18:00:00.000000Z', T)
    await savedByPhone(c.appToken, '2026-10-08T16:00:00.000000Z', '2026-10-08T17:00:00.000000Z')
    const { results } = await logWorkout(c.tokens.access_token, [session(6), session(8)])
    expect(results.map((r) => r.status)).toEqual(['added', 'added'])
  })

  it("checks the history even while the owner hides workouts from agents, and says only that it's taken", async () => {
    const c = await owner()
    await env.DB.prepare('UPDATE profiles SET mcp_read_workouts = 0 WHERE user_id = ?1').bind(c.userId).run()
    await savedByPhone(c.appToken, '2026-10-06T17:30:00.000000Z', '2026-10-06T18:30:00.000000Z')
    expect((await logWorkout(c.tokens.access_token, [session(6)])).results)
      .toEqual([{ index: 0, status: 'refused', reason: 'overlaps', message: OVERLAPS_HISTORY }])
  })

  it('adds nothing when the same workouts are sent again', async () => {
    const c = await owner()
    const muse = await connectAgent(c.appToken, { name: 'Muse' })
    expect((await logWorkout(muse.tokens.access_token, [session(6), session(8)])).isError).toBe(false)
    const again = await logWorkout(muse.tokens.access_token, [session(6), session(8)])
    expect(again.isError).toBe(true)
    expect(again.results.map((r) => r.reason)).toEqual(['overlaps', 'overlaps'])
    expect(await countOf('workouts', c.userId)).toBe(2)
    expect((await pulled(c.appToken)).map((w) => w.added_by)).toEqual(['Muse', 'Muse'])
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/log-workout.test.ts`
Expected: FAIL, 4 failed, 7 passed. "ignores deleted workouts, and one that ends as the new one starts" passes already:
nothing checks times yet.

- [ ] **Step 3: The history's times, in the Db**

In `server/src/mcp/db.ts`, replace

```ts
  /** The calling client's registered name (1 to 64 characters), or null. */
  agentName(): Promise<string | null>
```

with

```ts
  /** The calling client's registered name (1 to 64 characters), or null. */
  agentName(): Promise<string | null>
  /**
   * The times of the owner's workouts that aren't deleted and start in [since, until), in the stored form, whatever
   * mcp_read_workouts says: log_workout's overlap check, which tells the agent only that a time is taken.
   */
  workoutTimes(since: string, until: string): Promise<{ started_at: string; ended_at: string | null }[]>
```

In `server/src/mcp/d1-db.ts`, replace

```ts
  /** A new workout, while Add workouts is on, through the app's own save (src/sync/workouts.ts, addWorkout). */
```

with

```ts
  /** Through workouts_user_started (user_id, started_at). At most the account's 10,000 workouts. */
  async workoutTimes(since: string, until: string): Promise<{ started_at: string; ended_at: string | null }[]> {
    return await this.all<{ started_at: string; ended_at: string | null }>(
      'SELECT started_at, ended_at FROM workouts WHERE user_id = ?1 AND deleted_at IS NULL ' +
        'AND started_at >= ?2 AND started_at < ?3 ORDER BY started_at',
      this.userId,
      stamp(since),
      stamp(until),
    )
  }

  /** A new workout, while Add workouts is on, through the app's own save (src/sync/workouts.ts, addWorkout). */
```

In `server/test/mcp/fake-db.ts`, replace

```ts
import ownerText from './testdata/owner.json?raw'
```

with

```ts
import ownerText from './testdata/owner.json?raw'
import { normalizeTimestamp } from '../../src/sync/time.ts'
```

and

```ts
  insertWorkout(workout: LoggedWorkout, addedBy: string): Promise<WorkoutAdded> {
```

with

```ts
  workoutTimes(since: string, until: string): Promise<{ started_at: string; ended_at: string | null }[]> {
    const rows = this.data.workouts.filter((w) => time(w.started_at) >= time(since) && time(w.started_at) < time(until))
    return Promise.resolve(rows.map((w) => ({
      started_at: normalizeTimestamp(w.started_at)!,
      ended_at: w.ended_at === null ? null : normalizeTimestamp(w.ended_at),
    })))
  }

  insertWorkout(workout: LoggedWorkout, addedBy: string): Promise<WorkoutAdded> {
```

- [ ] **Step 4: The check, in `server/src/mcp/tools/log-workout.ts`**

Replace

```ts
const isRefused = (c: LoggedWorkout | Refused): c is Refused => 'status' in c
```

with

```ts
const isRefused = (c: LoggedWorkout | Refused): c is Refused => 'status' in c

/** A workout's time, [start, end) in the stored form. A stored workout with no length is the moment it started. */
interface Span {
  start: string
  end: string
}

const spanOf = (t: { started_at: string; ended_at: string | null }): Span => ({
  start: t.started_at,
  end: t.ended_at !== null && t.ended_at > t.started_at ? t.ended_at : t.started_at,
})

/** True when a new workout's span `w` meets `other`: they overlap, or `other`'s moment falls inside `w`. */
function overlaps(other: Span, w: Span): boolean {
  if (other.end === other.start) return w.start <= other.start && other.start < w.end
  return other.start < w.end && w.start < other.end
}

/** The earliest time the stored form can hold, for a lookback that would go before it. */
const FIRST_STAMP = '0000-01-01T00:00:00.000000Z'

/**
 * The stored workouts that may overlap the candidates: those that start from a day (MAX_WORKOUT_MS) before the
 * earliest candidate, up to the latest candidate's end. A stored workout over a day long that started earlier is
 * still missed: the app's own workouts are that long only when left running.
 */
async function storedSpans(db: ToolCtx['db'], candidates: LoggedWorkout[]): Promise<Span[]> {
  const earliest = Math.min(...candidates.map((w) => msOf(w.started_at)))
  const since = normalizeTimestamp(new Date(earliest - MAX_WORKOUT_MS).toISOString()) ?? FIRST_STAMP
  const until = candidates.map((w) => w.ended_at).reduce((a, b) => (a > b ? a : b))
  return (await db.workoutTimes(since, until)).map(spanOf)
}

const OVERLAPS_HISTORY = "It overlaps a workout already in the owner's history, so it was not added."
const overlapsSibling = (index: number) =>
  `It overlaps workout ${index} of this call, which was added, so it was not added.`
```

and replace

```ts
  const known = await db.loggableExerciseIds(candidates.flatMap((w) => w.exercises.map((e) => e.exercise_id)))
  const agent = (await db.agentName()) ?? UNNAMED_AGENT
  /** One checked workout, in the call's order: refused for its exercises, or written. */
  const add = async (w: LoggedWorkout, index: number): Promise<Outcome> => {
    const unknown = unknownIds(w, known)
    if (unknown.length > 0) return unknownExercise(index, unknown)
    const written = await db.insertWorkout(w, agent)
    if (!written.added) return refused(index, written.reason, written.message)
    return { index, status: 'added', workout_id: written.id }
  }
```

with

```ts
  const known = await db.loggableExerciseIds(candidates.flatMap((w) => w.exercises.map((e) => e.exercise_id)))
  const stored = await storedSpans(db, candidates)
  const agent = (await db.agentName()) ?? UNNAMED_AGENT
  const added: { index: number; span: Span }[] = []
  /** One checked workout, in the call's order: refused for its exercises or its time, or written. */
  const add = async (w: LoggedWorkout, index: number): Promise<Outcome> => {
    const unknown = unknownIds(w, known)
    if (unknown.length > 0) return unknownExercise(index, unknown)
    const span = spanOf(w)
    const sibling = added.find((a) => overlaps(a.span, span))
    if (sibling !== undefined) return refused(index, 'overlaps', overlapsSibling(sibling.index))
    if (stored.some((s) => overlaps(s, span))) return refused(index, 'overlaps', OVERLAPS_HISTORY)
    const written = await db.insertWorkout(w, agent)
    if (!written.added) return refused(index, written.reason, written.message)
    added.push({ index, span })
    return { index, status: 'added', workout_id: written.id }
  }
```

- Only workouts this call added count as siblings: a refused one blocks nothing.
- The refusal names a sibling by its index (the agent's own data) and a stored workout by nothing (decision 7).

- [ ] **Step 5: Say so in the description, in `server/src/mcp/tools/register.ts`**

In `log_workout`'s description, replace

```ts
      "owner hasn't allowed agents to add workouts), unknown_exercise, invalid, or a storage cap (too_many_…). " +
      'Only works if the owner allowed agents to add workouts.',
```

with

```ts
      "owner hasn't allowed agents to add workouts), overlaps (its time overlaps a workout already in the history, " +
      'or one added earlier in this call), unknown_exercise, invalid, or a storage cap (too_many_…). Sending the ' +
      'same workouts again adds nothing: each overlaps its first copy. Only works if the owner allowed agents to ' +
      'add workouts.',
```

- [ ] **Step 6: Run the tests to see them pass**

Run: `cd server && npx vitest run test/log-workout.test.ts test/mcp/tools/log-workout.test.ts`
Expected: PASS, `Tests  19 passed (19)`.

- [ ] **Step 7: Everything**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  54 passed (54)`, `Tests  739 passed (739)`; `tsc` prints nothing.

- [ ] **Step 8: Commit**

```bash
git add server/src/mcp/db.ts server/src/mcp/d1-db.ts server/test/mcp/fake-db.ts server/src/mcp/tools/log-workout.ts \
  server/src/mcp/tools/register.ts server/test/log-workout.test.ts
git commit -m "feat(server): log_workout refuses a workout that overlaps the history or an earlier one in the call"
```

---

### Task S10: Tools speak of agents, not Claude

**Files:**
- Modify: `server/src/mcp/tools/register.ts`, `server/src/mcp/d1-db.ts`, `server/src/mcp/tools/insights.ts`,
  `server/src/mcp/tools/strength.ts`, `server/src/mcp/tools/gyms.ts`
- Test: `server/test/mcp/agent-wording.test.ts`

- [ ] **Step 1: Write the failing tests**

`server/test/mcp/agent-wording.test.ts`:

```ts
// Any agent uses these tools now (plan 32; docs/specs/2026-11-09-ai-agents-design.md, section 3.6), so what they say
// about the owner's permissions names agents, not Claude. The server's MCP instructions keep their Claude-specific
// advice (test/mcp/instructions.test.ts).
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { D1Db } from '../../src/mcp/d1-db.ts'
import { listGyms } from '../../src/mcp/tools/gyms.ts'
import { getTrainingInsights } from '../../src/mcp/tools/insights.ts'
import { TOOL_SPECS } from '../../src/mcp/tools/register.ts'
import { getStrengthLevels } from '../../src/mcp/tools/strength.ts'
import { signUp } from '../helpers.ts'
import { FakeDb, loadOwnerData } from './fake-db.ts'

const NOW = new Date('2026-11-09T12:00:00Z')
const T = '2026-11-07T10:00:00.000000Z'

describe("what the tools say about the owner's permissions", () => {
  it('names agents in every description, never Claude', () => {
    for (const s of TOOL_SPECS) expect(s.description, s.name).not.toContain('Claude')
    const byName = Object.fromEntries(TOOL_SPECS.map((s) => [s.name, s.description]))
    expect(byName.get_profile).toContain('which permissions agents have')
    expect(byName.log_bodyweight).toContain('the owner allowed agents to access body data')
    for (const name of ['get_training_insights', 'get_strength_levels', 'list_gyms', 'get_gym_equipment']) {
      expect(byName[name], name).toContain('Only works if the owner allowed agents to read')
    }
  })

  it('refuses a read in words for any agent', async () => {
    const data = await loadOwnerData()
    data.profile = { ...data.profile!, mcp_read_workouts: false, mcp_read_gyms: false }
    const ctx = { db: new FakeDb(data), now: NOW }
    await expect(getTrainingInsights(ctx, {})).rejects.toThrow(
      "Not allowed: insights need the owner's permission for agents to read workouts and read the plan in the app.",
    )
    await expect(getStrengthLevels(ctx, {})).rejects.toThrow(
      "Not allowed: strength levels need the owner's permission for agents to read workouts, body and the plan in " +
        'the app.',
    )
    await expect(listGyms(ctx)).rejects.toThrow(
      'Reading gyms is turned off: the owner can switch it on under AI agents in the GymRollins app.',
    )
  })

  it('refuses a write in words for any agent', async () => {
    const { userId } = await signUp()
    await env.DB.prepare(
      'INSERT INTO profiles (user_id, mcp_read_body, mcp_propose, client_updated_at, updated_at) ' +
        'VALUES (?1, 0, 0, ?2, ?2)',
    ).bind(userId, T).run()
    const db = new D1Db(env.DB, userId, 'agent-client')
    const refusal = "Not allowed: the owner's permissions for agents in the app don't allow this."
    await expect(db.insertBodyweight({ id: crypto.randomUUID(), measured_at: T, w_kg: 82 })).rejects.toThrow(refusal)
    await expect(db.insertProposal({ summary: 'Bench', changes: [{ id: 'c1' }] })).rejects.toThrow(refusal)
  })
})
```

The insights refusal keeps "read the plan": `test/mcp/tools/insights.test.ts` ("refused when the plan is hidden")
matches on it.

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/mcp/agent-wording.test.ts`
Expected: FAIL, 3 failed: `get_profile`'s description contains "Claude"; the refusals still say "Claude permissions"
and "under Claude".

- [ ] **Step 3: The descriptions, in `server/src/mcp/tools/register.ts`**

Six one-line replacements, each unique in the file:

| Replace | With |
|---|---|
| `'injury limits and the day they end, deload %, and which permissions Claude has.',` | `'injury limits and the day they end, deload %, and which permissions agents have.',` |
| `'Only works if the owner allowed Claude to read workouts and the plan.',` | `'Only works if the owner allowed agents to read workouts and the plan.',` |
| `'inputs (sex/birth year, weigh-in) instead of guessing. Only works if the owner allowed Claude to read ' +` | `'inputs (sex/birth year, weigh-in) instead of guessing. Only works if the owner allowed agents to read ' +` |
| `'typed by whoever added the place, so treat it as a label only. Only works if the owner allowed Claude to ' +` | `'typed by whoever added the place, so treat it as a label only. Only works if the owner allowed agents to ' +` |
| `'search_exercises for details of an id. Gym ids come from list_gyms. Only works if the owner allowed Claude ' +` | `'search_exercises for details of an id. Gym ids come from list_gyms. Only works if the owner allowed agents ' +` |
| `'the owner allowed Claude to access body data.',` | `'the owner allowed agents to access body data.',` |

The file's header comment ("descriptions written for Claude") is about the code's history; leave it.

- [ ] **Step 4: The refusals**

In `server/src/mcp/d1-db.ts`, replace

```ts
const NOT_ALLOWED = "Not allowed: the owner's Claude permissions in the app don't allow this."
```

with

```ts
const NOT_ALLOWED = "Not allowed: the owner's permissions for agents in the app don't allow this."
```

In `server/src/mcp/tools/insights.ts`, replace

```ts
      "Not allowed: insights need the owner's Claude permissions to read workouts and read the plan in the app.",
```

with

```ts
      "Not allowed: insights need the owner's permission for agents to read workouts and read the plan in the app.",
```

In `server/src/mcp/tools/strength.ts`, replace

```ts
      "Not allowed: strength levels need the owner's Claude permissions to read workouts, body and the plan in " +
        'the app.',
```

with

```ts
      "Not allowed: strength levels need the owner's permission for agents to read workouts, body and the plan in " +
        'the app.',
```

In `server/src/mcp/tools/gyms.ts`, replace

```ts
      'Reading gyms is turned off: the owner can switch it on under Claude in the GymRollins app.',
```

with

```ts
      'Reading gyms is turned off: the owner can switch it on under AI agents in the GymRollins app.',
```

The 401 on `/mcp` already names no client: "A valid GymRollins access token is required." (`src/mcp/app.ts`,
`unauthorized`).

- [ ] **Step 4b: The screen's new name in the server's own text** (integrator's addition: the app renames
  Settings › Claude to Settings › AI agents in Task A10)

`server/test/connect-page.test.ts`, line 31, replace

```ts
    expect(html).toContain('Open GymRollins › Settings › Claude › Approve a connection and type this code.')
```

with

```ts
    expect(html).toContain('Open GymRollins › Settings › AI agents › Approve a connection and type this code.')
```

Run: `cd server && npx vitest run test/connect-page.test.ts`
Expected: FAIL on that line (the page still says "Settings › Claude").

`server/src/claude/connect-page.ts`, line 151, replace

```ts
      '<p>Open GymRollins › Settings › Claude › Approve a connection and type this code.</p>' +
```

with

```ts
      '<p>Open GymRollins › Settings › AI agents › Approve a connection and type this code.</p>' +
```

`server/src/mcp/instructions.ts`, line 18, replace

```ts
  "- If a tool says a permission is off, tell the owner it's in Settings › Claude in the app.",
```

with

```ts
  "- If a tool says a permission is off, tell the owner it's in Settings › AI agents in the app.",
```

The rest of `SERVER_INSTRUCTIONS` keeps its Claude-specific advice. In the comments, `src/claude/routes.ts` line 1 and
`src/mcp/d1-db.ts` line 2, replace `Settings › Claude` with `Settings › AI agents`.

Run: `cd server && npx vitest run test/connect-page.test.ts`
Expected: PASS.

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd server && npx vitest run test/mcp`
Expected: PASS, every file in `test/mcp` (the existing refusal tests match on "Not allowed" and "read the plan").

- [ ] **Step 6: Everything**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  55 passed (55)`, `Tests  742 passed (742)`; `tsc` prints nothing.

- [ ] **Step 7: Commit**

```bash
git add server/src/mcp/tools/register.ts server/src/mcp/d1-db.ts server/src/mcp/tools/insights.ts \
  server/src/mcp/tools/strength.ts server/src/mcp/tools/gyms.ts server/test/mcp/agent-wording.test.ts \
  server/src/claude/connect-page.ts server/test/connect-page.test.ts server/src/mcp/instructions.ts \
  server/src/claude/routes.ts
git commit -m "fix(server): tool descriptions and refusals speak of agents, and name Settings › AI agents"
```

---

### Task S11: The docs

**Files:**
- Modify: `server/README.md`, `docs/cloudflare-checklist.md`

No test: nothing reads these files.

- [ ] **Step 1: `server/README.md`**

In the list of the app's routes, replace

```markdown
  - Claude: `/v1/claude/proposals`, `/v1/claude/last-use`, `/v1/claude/connect/:code`, `/v1/claude/revoke`,
```

with

```markdown
  - Claude: `/v1/claude/proposals`, `/v1/claude/last-use`, `/v1/claude/connect/:code`, `/v1/claude/revoke`,
  - the connected agents: `/v1/agents` and `/v1/agents/:clientId/disconnect` (section "Agents" below),
```

Replace

```markdown
- **Claude** at `/mcp`, the MCP server with the 15 tools, behind Better Auth's OAuth (`@better-auth/mcp`):
```

with

```markdown
- **Agents** (Claude, Meta's Muse, any MCP client) at `/mcp`, the MCP server with the 16 tools, behind Better Auth's
  OAuth (`@better-auth/mcp`):
```

In "Schema", replace

```markdown
- `0007_claude_connect.sql` holds the approval codes and their tries, `0008_connect_session.sql` marks Claude's browser
  session (`claudeConnect`), and `0009_connect_opener.sql` keeps where the sign-in page was opened.
```

with

```markdown
- `0007_claude_connect.sql` holds the approval codes and their tries, `0008_connect_session.sql` marks Claude's browser
  session (`claudeConnect`), and `0009_connect_opener.sql` keeps where the sign-in page was opened.
- `0011_ai_agents.sql` (plan 32) adds the Add workouts switch (`profiles.mcp_log_workouts`, off), the agent that added a
  workout (`workouts.added_by`) and the agent that sent a proposal (`proposals.from_agent`).
```

At the end of the file, replace

```markdown
The MCP tools in `src/mcp` and the shared rules in `src/shared` came from the earlier Deno server in plan 29; that code
is in git history before plan 30.
```

with

```markdown
The MCP tools in `src/mcp` and the shared rules in `src/shared` came from the earlier Deno server in plan 29; that code
is in git history before plan 30.

## Agents

Any agent connects the way Claude does (plan 32; `docs/specs/2026-11-09-ai-agents-design.md`). One set of switches
serves them all; each agent can be disconnected on its own. `src/claude/agents.ts` and `src/claude/agent-routes.ts`:
- `GET /v1/agents` answers `{"agents": [{client_id, name, host, known_host, connected_at, last_used_at}]}`, newest
  connection first: every OAuth client with a consent or a live refresh token for the account. `name` is the registered
  `client_name`, or the host; `host` is its first redirect URL's; `known_host` is true for claude.ai and claude.com
  (`src/claude/hosts.ts`, which the approve sheet uses too); `last_used_at` is its newest audited call, or null.
- `POST /v1/agents/:clientId/disconnect` answers `{"disconnected": true}`, or 404 `unknown_agent`. One batch removes,
  for this account and client only, the access and refresh tokens, the consent, the unredeemed codes (`verification`
  rows whose JSON has `$.userId` and `$.query.client_id`), the `connect_requests` rows and the `/connect` sessions
  they made. The client's registration stays. `POST /v1/claude/revoke` stays as Disconnect all.
- `propose_plan_changes` stores the client's name in `proposals.from_agent`; `GET /v1/claude/proposals` serves it.
- `log_workout` (`src/mcp/tools/log-workout.ts`) adds up to 5 past workouts per call straight to the history while the owner's
  Add workouts switch is on. Each is checked on its own: `not_allowed`, `invalid` (times, ranges, at most 24 hours,
  not in the future), `unknown_exercise`, `overlaps` (a workout already stored, or one added earlier in the call; a
  stored workout with no end is the moment it started) and the storage caps (`too_many_…`). An added workout is an
  `import` with `added_by` set to the agent's name (`Agent` when it registered none), written by the app's own save
  (`addWorkout` in `src/sync/workouts.ts`), so the caps hold and the phone pulls it. No save from the app changes
  `added_by`.
```

- [ ] **Step 2: `docs/cloudflare-checklist.md`, section 4**

Below the block "Every deploy after the first keeps the secret it has" and above "Then check from any machine",
replace

```markdown
Then check from any machine. These need no account:
```

with

```markdown
**Plan 32 (AI agents) brings migration `0011_ai_agents.sql`.** It only adds columns, each with its default, so the app
on the phone keeps working with it: a profile pushed without `mcp_log_workouts` is stored with Add workouts off. In
this order, from `server/` with `CLOUDFLARE_ACCOUNT_ID` exported:
1. Note a Time Travel bookmark (section 7): `npx wrangler d1 time-travel info gymrollins`.
2. `npx wrangler d1 migrations apply gymrollins --remote`: it lists `0011_ai_agents.sql` alone; confirm.
3. `npx wrangler deploy`, then the checks below. With `BASE` set as they set it,
   `curl -s -o /dev/null -w '%{http_code}\n' "$BASE/v1/agents"` prints 401 (the route is there, behind the session).
4. Only then the app build that shows Settings › AI agents.

Then check from any machine. These need no account:
```

The owner runs these, with their approval; this plan runs none of them.

- [ ] **Step 3: Commit**

```bash
git add server/README.md docs/cloudflare-checklist.md
git commit -m "docs: the agents endpoints, log_workout, and migration 0011's deploy steps"
```

---

## Self-review against the spec

| Spec | Where |
|---|---|
| 3.1 the list: consent or live refresh token, newest first, name/host/known_host, connected_at, last_used_at | S5 |
| 3.2 single disconnect in one batch: tokens, consent, codes, connect_requests and their sessions; 404; revoke stays | S6 |
| 3.3 `from_agent` stored by `propose_plan_changes` and served | S4 |
| 3.4 `log_workout`: up to 5, sets, library or custom ids, per-workout results, every refusal code, `import` + `added_by`, server timestamps, audited, a repeat adds nothing | S7, S8, S9 |
| 3.5 one migration: the three columns | S1; synced: S2 (switch), S3 (`added_by`) |
| 3.6 wording: tools and the 401 say agents; instructions keep Claude's advice | S10 |
| 5 server tests: list (consented, token-only, last use per client, other accounts); disconnect (refused after, other served, codes and sessions gone, 404); `from_agent`; `log_workout` (switch off, overlaps with stored and sibling, unknown exercise, invalid times, caps, partial success, pulled `added_by`); migration defaults | S1–S9 |
| 6 rollout: migration before the Worker, the Worker before the app, a bookmark first | S11 |

## Questions for the integrator

1. **"Settings › Claude" in server text.** Resolved by the integrator: Task S10, Step 4b renames it. `SERVER_INSTRUCTIONS` tells agents "If a tool says a permission is off,
   tell the owner it's in Settings › Claude in the app." (`server/src/mcp/instructions.ts`, line 18), and the
   `/connect` page says "Open GymRollins › Settings › Claude › Approve a connection and type this code."
   (`server/src/claude/connect-page.ts`, line 151; `server/test/connect-page.test.ts`, line 31 asserts it). Once the
   app renames the screen to "AI agents" both point at a screen that isn't there. The contract keeps the instructions;
   should both lines name "Settings › AI agents" (one line each, plus the test)?
2. **Records.** An agent's workout arrives with `records: []` and the server's `vol_kg`. If the app shows personal
   records from the pulled `records`, it may want to compute them for workouts with `added_by` set (app half).

## Uncertain

- **D1's per-invocation limit.** The Free plan allows 50 D1 queries per Worker invocation (Cloudflare's D1 limits, as
  remembered, not read in this repo). A full 20-workout call makes about 27 if a `batch` counts as one query. If each
  statement in a batch counts, a workout costs 7 and about 6 fit in one call. Past the limit, D1 throws, the call ends
  as the internal error, and the workouts written before it stay; a retry refuses those as `overlaps` and adds the
  rest. Worth checking against Cloudflare's current limits page before the owner's 9 sessions go in (sending them in
  calls of 5 is safe either way).
- **Better Auth's code JSON** is read from the pinned 1.7.18; an upgrade that moves `query.client_id` breaks S6's test
  first, which is the point of it.


---

# Plan 32, app half: Settings › AI agents, agent-added workouts, proposals by agent

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the app half of `docs/specs/2026-11-09-ai-agents-design.md` (section 4, and the app parts of section 5).
Settings › Claude becomes **Settings › AI agents**: one row per connected agent with its own Disconnect, plan changes
labelled "From Muse", a new **Add workouts** switch (off), and **Disconnect all**. A workout an agent added says
"Added by Muse" on its screen, and the approve sheet's warning names the host without saying "Claude".

**Architecture:**
- **Three new synced facts, each a field next to its siblings.** `mcp_log_workouts` rides the profile like the other
  `mcp_*` switches (`Profile.mcpLogWorkouts`). `added_by` comes down with workouts and is kept on
  `WorkoutSnapshot`/`WorkoutRecord`, not on GymCore's `Workout`, so the editor and every local save leave it alone and
  no push can carry it. `from_agent` comes down with proposals (`Proposal.fromAgent`).
- **The agents list is a GymSync call, not synced data.** `GET /v1/agents` and `POST /v1/agents/:clientId/disconnect`
  go through `ApiSyncTransport` → `SyncEngine` → `SyncCoordinator`, like `lastMcpUse` and `revokeOAuthGrants` today.
  Nothing about agents is stored on the phone.
- **One model, injected calls.** `AgentsModel` (app) holds the list, the line shown when there is none, and what
  Disconnect leaves; the calls are passed in (`AgentCalls`), as `ApproveConnectionModel` takes its lookups, so unit
  tests run it without a server and the hermetic UI tests use DEBUG's in-memory `-fakeAgents`.
- **Words change, names stay.** The type `ClaudeConnectionView`, `disconnectClaude()` and every `claude.*`
  accessibility identifier keep their names, so the existing UI tests keep finding them. New elements use `agents.*`
  on the AI agents screen, `detail.addedBy` and `proposal.from` on their screens.

**Tech stack:** Swift 6.2, SwiftUI, SwiftData, Swift Testing (packages and app unit tests), XCTest (UI tests),
XcodeGen, `xcodebuild` on the iOS 26.2 simulator.

**Spec:** `docs/specs/2026-11-09-ai-agents-design.md`, sections 2 (decisions 1–6), 4 and 5. The server half
(section 3) is drafted separately; this half needs it only in Task A15.

**Builds on:** plan 31 with its `## Outcome`. Base: `de2bda6` or later on `feat-ai-agents`.

**Branch:** `feat-ai-agents`.
- No push.
- Never open or print `ios/Config/Local.xcconfig`.
- Commit messages have no `Co-Authored-By`, `Generated with` or `Claude-Session` trailers; the owner forbids them.
- One `xcodebuild` at a time (the Mac runs short on memory).

**Not in this plan (app):**
- Per-agent switches, approve-before-adding for agent workouts (spec section 7).
- Renaming types, files or `claude.*` identifiers (decision A1 below).
- Today's chip ("Plan change from Claude", `TodayView.swift:440`), onboarding's Connect Claude step, the approve
  sheet's result lines ("Your browser returns to Claude in a moment.", asserted by `ProposalSyncUITests.swift:40`)
  and its `notACode`/`signInFirst` words: they still say Claude. Questions for the owner at the end.
- The README screenshots (`ReadmeScreenshotsUITests.test06ClaudeConnect`): regenerate only if the owner asks.

---

## App facts

Checked on `feat-ai-agents` at `de2bda6` (2026-11-08) by reading the code. The integrator can check the server half
against these.

| Fact | Where |
|---|---|
| The screen is `ClaudeConnectionView`, title "Claude", sections in this order: status (`claude.status` "Last used 5 Nov"/"Not connected yet", header `claude.view`), Connect, "Plan changes from Claude", Use with Claude, "What Claude can do", "Disconnect Claude" | `ios/GymRollins/Features/Claude/ClaudeConnectionView.swift:33-164` |
| Opened from Settings' `claudeSection` (header "Claude", row "Claude connection", id `settings.claude`, badge `settings.claude.badge` from `lastMcpUse`) and from Today's empty state | `ios/GymRollins/Features/Settings/SettingsView.swift:159-173`, `ios/GymRollins/Features/Today/TodayView.swift:89` |
| Permission flags: `Profile.mcpReadWorkouts/mcpReadBody/mcpReadPlan/mcpReadGyms/mcpPropose/mcpAutoApply`, same names on `ProfileRecord` and `ProfileSnapshot`; written by `ProfileRepository.setMcpPermissions(readWorkouts:readBody:readPlan:readGyms:propose:autoApply:)` and `AppEnvironment.saveMcpPermissions(...)` with the same labels | `ios/Packages/GymData/Sources/GymData/Values/Profile.swift:20-27`, `Repositories/ProfileRepository.swift:89-106`, `ios/GymRollins/App/AppEnvironment+Claude.swift:50-58` |
| New flag: `mcpLogWorkouts` (Profile, ProfileRecord, ProfileSnapshot), `logWorkouts:` as the **last** argument of both setters | this plan, Task A1 |
| Wire encoding of the switches: `ProfileDTO` encodes each `mcp_*` as a JSON boolean (`try c.encode(mcpReadGyms, forKey: .mcpReadGyms)`); the server's column kind is `bool`, JSON `true`/`false` ↔ SQLite 1/0 | `ios/Packages/GymSync/Sources/GymSync/DTO/ProfileDTO.swift:149-154`, `server/src/sync/entities.ts:88-92`, `server/src/sync/columns.ts:82-83,105` |
| `mcp_log_workouts`: encoded on every profile push as a JSON boolean; a pulled profile without the key reads as `false` | Task A2 |
| `WorkoutDTO` decodes pulled workouts (nested `entries` or `workout_entries`) and encodes pushes with an explicit key list | `ios/Packages/GymSync/Sources/GymSync/DTO/WorkoutDTO.swift:62-103` |
| `added_by`: decoded (string or null, absent = null), **never encoded**; stored as `WorkoutRecord.addedBy` only by pulls (`SyncStore` `write`), read with `WorkoutRepository.addedBy(_:)`; local saves (`WorkoutRepository.upsertRecord`) never touch it | Tasks A3, A4 |
| Proposals come from `GET /v1/claude/proposals` `{"rows": [...]}`, one `PulledProposal` per row; `ProposalDTO` has a custom `init(from:)` and a synthesized `encode` | `ios/Packages/GymSync/Sources/GymSync/ApiSyncTransport+Claude.swift:12-15`, `DTO/ProposalDTO.swift` |
| `from_agent`: decoded (string or null), `Proposal.fromAgent`, `ProposalRecord.fromAgent`; `ProposalRepository.upsertRemote` stores it on insert and fills it in on a stored proposal that has none | Tasks A5, A6 |
| Transport pattern: `ApiClient.get`/`post` decode with `SyncJSON.decoder` (dates via `SyncDate.parse`, microsecond ISO 8601), errors are `ApiError(status, code, message)`; codes are mapped to typed errors per route (`unknown_code` → `ConnectCodeError.unknownCode`) | `ios/Packages/GymSync/Sources/GymSync/ApiClient.swift:68-77`, `ApiError.swift`, `ApiSyncTransport+Claude.swift:53-62` |
| New GymSync API: `ConnectedAgent(clientId, name, host, knownHost, connectedAt, lastUsedAt)` decoded from `client_id, name, host, known_host, connected_at, last_used_at`; `AgentError.unknownAgent` for `404 unknown_agent`; `SyncTransport.connectedAgents()`, `disconnectAgent(clientId:)`; the same on `SyncEngine` and `SyncCoordinator` | Task A7, A8 |
| A client id is sent only if it is 1–128 characters of ASCII letters, digits, `-` and `_`. Better Auth makes them with `generateRandomString(32, "a-z", "A-Z")` | `server/node_modules/@better-auth/oauth-provider/dist/authorize-BzDrbYtI.mjs:4591` |
| A loopback client's host is expected as `127.0.0.1:53682` (with the port), the string `connect_requests.redirect_host` already gives | `ios/Packages/GymSync/Tests/GymSyncIntegrationTests/OAuthGrantTransportTests.swift:21` |
| SwiftData: **no** `VersionedSchema` or `SchemaMigrationPlan` anywhere. `GymStore.container` opens `Schema(GymStore.models)` with a plain `ModelConfiguration`. Earlier field additions relied on automatic lightweight migration: `ProfileRecord.mcpReadGyms: Bool = true` (commit 00b13d0), `WorkoutRecord.gymId: UUID?` (4766a04). This plan adds only defaulted or optional stored properties (`mcpLogWorkouts: Bool = false`, `addedBy: String?`, `fromAgent: String?`), so no schema version; Task A16 checks an upgrade on the simulator | `ios/Packages/GymData/Sources/GymData/Store/GymStore.swift:4-16` |
| UI-test harnesses: hermetic `-uiTesting` (sync backend `.disabled`, no engine) with seeds (`-seedProposal`, `-fakeGymCatalog`, …), used by every Claude-screen UI test (ProposalUITests, AccessibilityAuditUITests, DynamicTypeUITests, ClaudePromptsUITests, SettingsUITests, EmptyStatesUITests); and the local Worker (`-uiTestingBackend local`, `scripts/ios-test-sync.sh`), used by ProposalSyncUITests, which plays the agent with `ClaudeTestClient` | `ios/GymRollins/App/LaunchOptions.swift:207-213`, `ios/GymRollinsUITests/ProposalSyncUITests.swift:1-19` |
| This plan's hermetic seeds: `-fakeAgents` (Muse, `MuseFakeClientId`, `agent.meta.ai`, last used 2 h ago; Claude, `ClaudeFakeClientId`, `claude.ai`, never used) and `-seedAgentWorkout` (workout `AD0ED000-0000-4000-8000-000000000001`, "Upper", added by Muse); `-seedProposal`'s proposal is now from "Claude" | Task A9 |
| Tests that assert the old words: only `ProposalUITests.swift:151` (`claude.status` == "Not connected yet"). "What Claude can do", "Disconnect Claude" and "This isn't Claude's address" are reached only by identifier (`claude.perm.*`, `claude.disconnect`, `claude.disconnect.confirm`, `claude.disconnected`, `claude.gymsNote`, `connect.warning`) | `git grep` over `ios/GymRollinsUITests` and `ios/GymRollinsTests` |
| `claude.status` is the screen's ready marker in 7 places (`ClaudePromptsUITests.swift:18`, `DynamicTypeUITests.swift:263,278`, `EmptyStatesUITests.swift:26`, `ProposalUITests.swift:119,136,147`); it stays, on the line shown while there are no rows (always so in the hermetic build) | Task A10 |
| Relative time: `SyncStatusText.lastSynced(_:now:)` → "Just now", "2 min ago", "3 h ago", or a date | `ios/GymRollins/Features/Sync/SyncStatusText.swift:57-66` |
| Workout screen: `WorkoutDetailView` (ids `detail.*`), opened from Log cards `log.workout.<UUID>` | `ios/GymRollins/Features/Log/WorkoutDetailView.swift`, `WorkoutCard.swift:38` |
| Package tests run with `swift test` in each package; GymSync's unit tests with `--filter GymSyncTests`, its integration tests through `scripts/test-sync-integration.sh` | `scripts/test-all.sh:11-18` |

## Decisions this half makes

- **A1. Names stay, words change.** Renaming `ClaudeConnectionView`, `disconnectClaude()` or the `claude.*`
  identifiers would touch 30 test references for no user-visible gain. The brief asks for new ids under `agents.*`;
  the two new lines on other screens follow those screens' prefixes (`detail.addedBy`, `proposal.from`).
- **A2. `added_by` is not on GymCore's `Workout`.** `Workout` is the editor's value: every edit rebuilds it
  (`Workout+Editing.swift`) and `WorkoutRepository.save` writes all of it. Keeping the name on `WorkoutSnapshot` (the
  sync boundary) and `WorkoutRecord` means an edit can't drop it, and `dirtyWorkouts()` builds the pushed snapshot
  without it, so a push can't carry it even before `WorkoutDTO.encode` (which never writes it either).
- **A3. The section order is the spec's:** agents, Connect, proposals, What agents can do, Use with Claude, Disconnect
  all. Today Use with Claude sits above the switches; moving it pushes the switches up, so ProposalUITests' check of
  the switches after Disconnect all scrolls back up (Task A10).
- **A4. The status line becomes the empty state.** `claude.status` shows "Checking…", "No agents connected." or why
  the list couldn't load, and is absent while there are rows. Hermetic builds have no session, so it always reads
  "No agents connected." there and the 7 waits on it keep working.
- **A5. Signed out, the list is empty, and Disconnect says to sign in.** `SyncCoordinator.connectedAgents()` answers
  `[]` without an engine (as `revokeClaudeAccess` answers 0); `disconnectAgent` throws `SyncUnavailableError` (as
  `connectRequest` does).
- **A6. A 404 `unknown_agent` on Disconnect removes the row.** The agent has no grant left either way. Any other
  error keeps the row and says the agent still has access.
- **A7. Disconnect all also turns Add workouts off** (`disconnectClaude()` sets every flag off), and the list is asked
  again afterwards.
- **A8. A proposal pulled before the app knew senders learns its sender.** `upsertRemote` inserts only new rows today,
  so a pending proposal pulled by the old app would never show "From Muse". It now fills `fromAgent` when the stored
  one is nil; a name, once stored, stays.
- **A9. Words outside the spec's list that would be wrong after the rename** are fixed too: the approve sheet's footer
  ("Settings › Claude"), Connect's step 3 ("open Settings › Claude › Approve a connection"), the privacy summary
  ("the Claude section of Settings"; agents can now also add workouts), the Disconnect errors ("tap Disconnect Claude
  again"), and the review title ("Plan change from Claude" becomes "Plan change", with "From Muse" under the date when
  known).
- **A10. The hermetic fake lives in the app (DEBUG only), not in a transport.** The `.disabled` backend has no engine
  or transport to fake, so `-fakeAgents` swaps the screen's `AgentCalls` for an in-memory list made once per launch
  (`AppEnvironment.fakeAgentCalls`), as `-fakeGymCatalog` swaps the catalogue.

## File map

| File | Change | Task |
|---|---|---|
| `ios/Packages/GymData/Sources/GymData/Records/ProfileRecord.swift`, `Values/Profile.swift`, `Sync/SyncModels.swift` (ProfileSnapshot), `Repositories/ProfileRepository.swift`, `Sync/SyncStore+Profile.swift` | `mcpLogWorkouts` | A1 |
| `ios/GymRollins/App/AppEnvironment+Claude.swift`, `Features/Claude/ClaudeConnectionView.swift`, `Features/Settings/SettingsPreferences.swift`, `Features/Onboarding/ProfileSetupView.swift` | `logWorkouts` passed through | A1 |
| `ios/Packages/GymData/Tests/GymDataTests/ProposalTests.swift`, `SyncStoreTests.swift`; `ios/Packages/GymSync/Tests/GymSyncTests/SyncEngineTests.swift`; `ios/GymRollinsTests/ClaudeEnvironmentTests.swift`, `SignOutAndDisconnectTests.swift`, `TodayRoutineProposalTests.swift`, `ProfileLimitsTests.swift` | tests and call sites | A1 |
| `ios/Packages/GymSync/Sources/GymSync/DTO/ProfileDTO.swift`, `Tests/GymSyncTests/DTOTests.swift`, `ios/GymRollinsTests/SignOutAndDisconnectTests.swift` | `mcp_log_workouts` | A2 |
| `ios/Packages/GymData/Sources/GymData/Sync/SyncModels.swift` (WorkoutSnapshot), `Records/WorkoutRecords.swift`, `Sync/SyncStore+Workouts.swift`, `Repositories/WorkoutRepository.swift`, `Tests/GymDataTests/SyncStoreWorkoutTests.swift` | `addedBy` | A3 |
| `ios/Packages/GymSync/Sources/GymSync/DTO/WorkoutDTO.swift`, `Tests/GymSyncTests/DTOTests.swift` | `added_by` | A4 |
| `ios/Packages/GymData/Sources/GymData/Proposals/Proposal.swift`, `Records/ProposalRecord.swift`, `Repositories/ProposalRepository.swift`, `Tests/GymDataTests/ProposalTests.swift` | `fromAgent` | A5 |
| `ios/Packages/GymSync/Sources/GymSync/DTO/ProposalDTO.swift`, `Tests/GymSyncTests/DTOTests.swift`, `FakeTransport.swift`, `SyncEngineProposalTests.swift` | `from_agent` | A6 |
| `ios/Packages/GymSync/Sources/GymSync/ConnectedAgents.swift`, `ApiSyncTransport+Agents.swift` (create); `SyncTransport.swift`, `SyncEngine.swift`; `Tests/GymSyncTests/ApiAgentsTransportTests.swift`, `SyncEngineAgentsTests.swift` (create), `FakeTransport.swift` | agents list and disconnect | A7 |
| `ios/GymRollins/Features/Claude/AgentsModel.swift` (create), `ios/GymRollins/App/SyncCoordinator.swift`, `AppEnvironment+Claude.swift`; `ios/GymRollinsTests/AgentsModelTests.swift` (create), `SignOutAndDisconnectTests.swift` | the agents model | A8 |
| `ios/GymRollins/App/DebugAgents.swift` (create), `LaunchOptions.swift`, `AppEnvironment.swift`, `AppEnvironment+Claude.swift`, `DebugProposalSeed.swift`; `ios/GymRollinsTests/DebugAgentsTests.swift` (create) | hermetic seeds | A9 |
| `ios/GymRollins/Features/Claude/ClaudeConnectionView.swift` (rewrite), `ConnectedAgentsSection.swift` (create), `ConnectorInstructions.swift`; `ios/GymRollins/App/AppEnvironment+Claude.swift`; `Features/Settings/SettingsView.swift`, `PrivacyPolicyView.swift`; `ios/GymRollinsUITests/AgentsUITests.swift` (create), `ProposalUITests.swift` | the screen | A10 |
| `ClaudeConnectionView.swift`, `ProposalReviewView.swift`, `AgentsModel.swift`, `AgentsModelTests.swift`, `AgentsUITests.swift` | "From Muse" | A11 |
| `ios/GymRollins/Features/Log/WorkoutDetailView.swift`, `AgentsUITests.swift` | "Added by Muse" | A12 |
| `ios/GymRollins/Features/Claude/ApproveConnectionModel.swift`, `ApproveConnectionView.swift`, `ios/GymRollinsTests/ApproveConnectionModelTests.swift` | the warning | A13 |
| `ios/GymRollinsUITests/AccessibilityAuditUITests.swift`, `DynamicTypeUITests.swift` | audits | A14 |
| `ios/Packages/GymSync/Tests/GymSyncIntegrationTests/AgentsTransportTests.swift` (create), `ios/GymRollinsUITests/ProposalSyncUITests.swift` | end to end, local Worker | A15 |
| this plan | `## Outcome` | A16 |

## How to run things

```bash
(cd ios/Packages/GymData && swift test)                          # GymData
(cd ios/Packages/GymData && swift test --filter SyncStoreWorkoutTests)
(cd ios/Packages/GymSync && swift test --filter GymSyncTests)    # GymSync unit tests (fake transport, stub URL protocol)
(cd ios/Packages/GymSync && swift test --filter DTOTests)
scripts/test-sync-integration.sh                                 # GymSync integration tests on a throwaway Worker (:8788)
scripts/ios-test-sync.sh                                         # SyncUITests + ProposalSyncUITests on a throwaway Worker
```

- **App unit tests** (one suite; repeat `-only-testing:` for several):

  ```bash
  cd ios && xcodegen generate && xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:GymRollinsTests/<Suite>
  ```

- **UI tests:** the same command with `-only-testing:GymRollinsUITests/<Class>` (or `<Class>/<method>`).
- `swift test` prints `Test run with N tests in M suites passed`; `xcodebuild` ends `** TEST SUCCEEDED **` or
  `** TEST FAILED **` with the failing tests listed above it.
- **Counts.** Before Task A1, run `(cd ios/Packages/GymData && swift test)`, `(cd ios/Packages/GymSync && swift test
  --filter GymSyncTests)` and the full `-only-testing:GymRollinsTests` run once, and write the three counts into the
  Outcome. Each task adds the tests it names to them.
- **Reviews.** Each task ends with one, by a fresh reviewer: plan compliance (**code-reviewer**), then quality
  (**code-reviewer**, Swift). Tasks A7 and A8 also get **security-reviewer** (an id sent in a URL path; agent names
  from a third party shown on screen). Fix CRITICAL and HIGH findings in their own commits, with a test, and record
  them in the task as "added after review".

---

### Task A1: The Add workouts switch on the phone (`mcpLogWorkouts`)

The flag next to its siblings in GymData, and passed through every place that writes or rebuilds the profile, so a
Settings save, onboarding or the injury note can't turn it off. No toggle yet (Task A10).

**Files:**
- Modify: `ios/Packages/GymData/Sources/GymData/Records/ProfileRecord.swift`,
  `ios/Packages/GymData/Sources/GymData/Values/Profile.swift`, `ios/Packages/GymData/Sources/GymData/Sync/SyncModels.swift`,
  `ios/Packages/GymData/Sources/GymData/Repositories/ProfileRepository.swift`,
  `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+Profile.swift`, `ios/GymRollins/App/AppEnvironment+Claude.swift`,
  `ios/GymRollins/Features/Claude/ClaudeConnectionView.swift`, `ios/GymRollins/Features/Settings/SettingsPreferences.swift`,
  `ios/GymRollins/Features/Onboarding/ProfileSetupView.swift`
- Test: `ios/Packages/GymData/Tests/GymDataTests/ProposalTests.swift`,
  `ios/Packages/GymData/Tests/GymDataTests/SyncStoreTests.swift`,
  `ios/Packages/GymSync/Tests/GymSyncTests/SyncEngineTests.swift`, `ios/GymRollinsTests/ClaudeEnvironmentTests.swift`,
  `ios/GymRollinsTests/SignOutAndDisconnectTests.swift`, `ios/GymRollinsTests/TodayRoutineProposalTests.swift`,
  `ios/GymRollinsTests/ProfileLimitsTests.swift`

- [ ] **Step 1: Write the failing GymData tests**

In `ios/Packages/GymData/Tests/GymDataTests/ProposalTests.swift`, in `mcpPermissionsUpdateOnlyThoseFields`, replace

```swift
        try f.profiles.setMcpPermissions(readWorkouts: false, readBody: true, readPlan: false, readGyms: false, propose: false,
                                         autoApply: true)
        let p = try f.profiles.load()
        #expect(!p.mcpReadWorkouts && p.mcpReadBody && !p.mcpReadPlan && !p.mcpReadGyms && !p.mcpPropose && p.mcpAutoApply)
```

with

```swift
        #expect(try f.profiles.load().mcpLogWorkouts == false) // default off (plan 32)
        try f.profiles.setMcpPermissions(readWorkouts: false, readBody: true, readPlan: false, readGyms: false, propose: false,
                                         autoApply: true, logWorkouts: true)
        let p = try f.profiles.load()
        #expect(!p.mcpReadWorkouts && p.mcpReadBody && !p.mcpReadPlan && !p.mcpReadGyms && !p.mcpPropose && p.mcpAutoApply)
        #expect(p.mcpLogWorkouts)
```

and add after that test, inside `ProposalRepositoryTests`:

```swift
    /// Plan 32: a whole-profile save (Settings, onboarding, the injury note) keeps Add workouts as it was.
    @Test func aProfileSaveKeepsAddWorkouts() throws {
        try f.profiles.setMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true, propose: true,
                                         autoApply: false, logWorkouts: true)
        try f.profiles.save(try f.profiles.load().withLimits("Knee", until: nil))
        let saved = try f.profiles.load()
        #expect(saved.mcpLogWorkouts && saved.limits == "Knee")
    }
```

In `ios/Packages/GymData/Tests/GymDataTests/SyncStoreTests.swift`, in `applyingRemoteRowsNeverMarksDirty`, replace

```swift
        profile.mcpReadGyms = false
        try f.store.applyRemote(profile: SyncRow(value: profile, clientUpdatedAt: t, serverUpdatedAt: t))
```

with

```swift
        profile.mcpReadGyms = false
        profile.mcpLogWorkouts = true
        try f.store.applyRemote(profile: SyncRow(value: profile, clientUpdatedAt: t, serverUpdatedAt: t))
```

and replace

```swift
        #expect(try f.profiles.load().mcpReadGyms == false)
```

with

```swift
        #expect(try f.profiles.load().mcpReadGyms == false)
        #expect(try f.profiles.load().mcpLogWorkouts)
```

In the same file, in `dirtyProfileWeekdaysAndCustomExercisesRoundTrip`, replace

```swift
        try f.profiles.save(Profile(unit: .kg, goalWeightKg: 85))
```

with

```swift
        try f.profiles.save(Profile(unit: .kg, goalWeightKg: 85, mcpLogWorkouts: true))
```

and replace

```swift
        #expect(profile.value.goalWeightKg == 85)
```

with

```swift
        #expect(profile.value.goalWeightKg == 85)
        #expect(profile.value.mcpLogWorkouts)
```

- [ ] **Step 2: Run them to see them fail**

Run: `(cd ios/Packages/GymData && swift test --filter ProposalRepositoryTests)`
Expected: the build fails: `extra argument 'logWorkouts' in call`, `value of type 'Profile' has no member
'mcpLogWorkouts'`, `value of type 'ProfileSnapshot' has no member 'mcpLogWorkouts'`.

- [ ] **Step 3: The flag in GymData**

In `ios/Packages/GymData/Sources/GymData/Records/ProfileRecord.swift`, replace

```swift
    public var mcpAutoApply: Bool
```

with

```swift
    public var mcpAutoApply: Bool
    /// Plan 32's Add workouts: agents may add past workouts. A store from before it opens with the default.
    public var mcpLogWorkouts: Bool = false
```

In `ios/Packages/GymData/Sources/GymData/Values/Profile.swift`, replace

```swift
    public let mcpAutoApply: Bool
```

with

```swift
    public let mcpAutoApply: Bool
    /// Agents may add past workouts to the history (`log_workout`, plan 32); off by default.
    public let mcpLogWorkouts: Bool
```

replace

```swift
                mcpAutoApply: Bool = false, sex: ProfileSex? = nil, birthYear: Int? = nil) {
```

with

```swift
                mcpAutoApply: Bool = false, mcpLogWorkouts: Bool = false, sex: ProfileSex? = nil,
                birthYear: Int? = nil) {
```

replace

```swift
        self.mcpAutoApply = mcpAutoApply
```

with

```swift
        self.mcpAutoApply = mcpAutoApply
        self.mcpLogWorkouts = mcpLogWorkouts
```

and, in `withLimits`, replace

```swift
                       mcpAutoApply: mcpAutoApply, sex: sex, birthYear: birthYear)
```

with

```swift
                       mcpAutoApply: mcpAutoApply, mcpLogWorkouts: mcpLogWorkouts, sex: sex, birthYear: birthYear)
```

In `ios/Packages/GymData/Sources/GymData/Sync/SyncModels.swift`, in `ProfileSnapshot`, replace

```swift
    public var mcpAutoApply = false
```

with

```swift
    public var mcpAutoApply = false
    public var mcpLogWorkouts = false
```

In `ios/Packages/GymData/Sources/GymData/Repositories/ProfileRepository.swift`, in `load()`, replace

```swift
                       mcpAutoApply: r.mcpAutoApply,
```

with

```swift
                       mcpAutoApply: r.mcpAutoApply, mcpLogWorkouts: r.mcpLogWorkouts,
```

in `save(_:)`, replace

```swift
        r.mcpAutoApply = p.mcpAutoApply
```

with

```swift
        r.mcpAutoApply = p.mcpAutoApply
        r.mcpLogWorkouts = p.mcpLogWorkouts
```

and replace the whole `setMcpPermissions` with

```swift
    /// Updates only what agents may do (no other field is rewritten), creating the profile if needed.
    public func setMcpPermissions(readWorkouts: Bool, readBody: Bool, readPlan: Bool, readGyms: Bool,
                                  propose: Bool, autoApply: Bool, logWorkouts: Bool) throws {
        let r = try record() ?? {
            let new = ProfileRecord(now: now())
            context.insert(new)
            return new
        }()
        r.mcpReadWorkouts = readWorkouts
        r.mcpReadBody = readBody
        r.mcpReadPlan = readPlan
        r.mcpReadGyms = readGyms
        r.mcpPropose = propose
        r.mcpAutoApply = autoApply
        r.mcpLogWorkouts = logWorkouts
        r.updatedAt = now()
        r.dirty = true
        try context.save()
    }
```

In `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+Profile.swift`, replace

```swift
        s.mcpAutoApply = mcpAutoApply
```

with

```swift
        s.mcpAutoApply = mcpAutoApply
        s.mcpLogWorkouts = mcpLogWorkouts
```

and replace

```swift
        mcpAutoApply = s.mcpAutoApply
```

with

```swift
        mcpAutoApply = s.mcpAutoApply
        mcpLogWorkouts = s.mcpLogWorkouts
```

Run: `(cd ios/Packages/GymData && swift test)`
Expected: `Test run with <base + 1> tests in <base> suites passed` (one new test, `aProfileSaveKeepsAddWorkouts`).

- [ ] **Step 4: The other call sites of `setMcpPermissions`**

In `ios/Packages/GymSync/Tests/GymSyncTests/SyncEngineTests.swift`, replace **both** occurrences (in
`pushProfileNowStoresTheProfileOrThrows` and `pushProfileNowThrowsWhenTheServerKeptANewerEdit`) of

```swift
        try f.profiles.setMcpPermissions(readWorkouts: false, readBody: false, readPlan: false, readGyms: false, propose: false,
                                         autoApply: false)
```

with

```swift
        try f.profiles.setMcpPermissions(readWorkouts: false, readBody: false, readPlan: false, readGyms: false, propose: false,
                                         autoApply: false, logWorkouts: false)
```

Run: `(cd ios/Packages/GymSync && swift test --filter GymSyncTests)`
Expected: the count from the base, all passed.

- [ ] **Step 5: Write the failing app tests**

In `ios/GymRollinsTests/ProfileLimitsTests.swift`, add inside `ProfileLimitsTests`:

```swift
    /// Plan 32: Settings and onboarding rebuild the profile; Add workouts must come through as it was.
    @Test func settingsUpdatesKeepAddWorkouts() {
        let p = Profile(mcpLogWorkouts: true)
        #expect(p.with(deloadPct: 0.1).mcpLogWorkouts)
        #expect(p.with(restSec: 90, warmupRestSec: 45).mcpLogWorkouts)
        #expect(p.withStandardEquipment(for: .kg).mcpLogWorkouts)
        #expect(p.with(mcpLogWorkouts: false).mcpLogWorkouts == false)
        #expect(!Profile().with(restSec: 90).mcpLogWorkouts)
    }
```

In `ios/GymRollinsTests/ClaudeEnvironmentTests.swift`, replace

```swift
        try env.profiles.setMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true, propose: true,
                                           autoApply: true)
```

with

```swift
        try env.profiles.setMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true, propose: true,
                                           autoApply: true, logWorkouts: false)
```

replace

```swift
        try env.saveMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true, propose: true, autoApply: true)
        #expect(try await env.disconnectClaude() == 0) // hermetic build: no session, nothing to revoke
        let p = env.profile
        #expect(!p.mcpReadWorkouts && !p.mcpReadBody && !p.mcpReadPlan && !p.mcpReadGyms && !p.mcpPropose && !p.mcpAutoApply)
```

with

```swift
        try env.saveMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true, propose: true, autoApply: true,
                                   logWorkouts: true)
        #expect(try await env.disconnectClaude() == 0) // hermetic build: no session, nothing to revoke
        let p = env.profile
        #expect(!p.mcpReadWorkouts && !p.mcpReadBody && !p.mcpReadPlan && !p.mcpReadGyms && !p.mcpPropose && !p.mcpAutoApply)
        #expect(!p.mcpLogWorkouts)
```

replace

```swift
        try env.saveMcpPermissions(readWorkouts: true, readBody: true, readPlan: false, readGyms: true, propose: true, autoApply: false)
```

with

```swift
        try env.saveMcpPermissions(readWorkouts: true, readBody: true, readPlan: false, readGyms: true, propose: true, autoApply: false,
                                   logWorkouts: false)
```

replace

```swift
        try env.saveMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: false, propose: true,
                                   autoApply: false)
```

with

```swift
        try env.saveMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: false, propose: true,
                                   autoApply: false, logWorkouts: false)
```

and add at the end of `ClaudeEnvironmentTests`:

```swift
    /// Plan 32: Add workouts is off until the owner turns it on, survives a reload, and Disconnect all turns it off.
    @Test func addWorkoutsIsOffUntilTurnedOnAndDisconnectTurnsItOff() async throws {
        let env = try makeEnv()
        #expect(!env.profile.mcpLogWorkouts)
        try env.saveMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true, propose: true,
                                   autoApply: false, logWorkouts: true)
        env.reloadProfile()
        #expect(env.profile.mcpLogWorkouts && env.profile.mcpReadGyms)
        #expect(try await env.disconnectClaude() == 0)
        #expect(!env.profile.mcpLogWorkouts)
    }
```

In `ios/GymRollinsTests/SignOutAndDisconnectTests.swift`, replace

```swift
        try env.saveMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true, propose: true, autoApply: true)
```

with

```swift
        try env.saveMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true, propose: true, autoApply: true,
                                   logWorkouts: true)
```

In `ios/GymRollinsTests/TodayRoutineProposalTests.swift`, replace

```swift
        try env.profiles.setMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true, propose: true,
                                           autoApply: true)
```

with

```swift
        try env.profiles.setMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true, propose: true,
                                           autoApply: true, logWorkouts: false)
```

- [ ] **Step 6: Run them to see them fail**

Run (from the repo root): `cd ios && xcodegen generate && xcodebuild test -project GymRollins.xcodeproj -scheme
GymRollins -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
-only-testing:GymRollinsTests/ProfileLimitsTests -only-testing:GymRollinsTests/ClaudeEnvironmentTests`
Expected: `** TEST FAILED **` with build errors: `extra argument 'logWorkouts' in call` (AppEnvironment's
`saveMcpPermissions`), `extra argument 'mcpLogWorkouts' in call` (`Profile.with`), and `missing argument for parameter
'logWorkouts' in call` in `AppEnvironment+Claude.swift`.

- [ ] **Step 7: Pass it through the app**

In `ios/GymRollins/App/AppEnvironment+Claude.swift`, replace

```swift
    /// Saves Claude's permissions (synced with the profile); turning auto-apply on applies what's pending now.
    func saveMcpPermissions(readWorkouts: Bool, readBody: Bool, readPlan: Bool, readGyms: Bool, propose: Bool,
                            autoApply: Bool) throws {
        try profiles.setMcpPermissions(readWorkouts: readWorkouts, readBody: readBody, readPlan: readPlan,
                                       readGyms: readGyms, propose: propose, autoApply: autoApply)
```

with

```swift
    /// Saves what agents may do (synced with the profile); turning auto-apply on applies what's pending now.
    func saveMcpPermissions(readWorkouts: Bool, readBody: Bool, readPlan: Bool, readGyms: Bool, propose: Bool,
                            autoApply: Bool, logWorkouts: Bool) throws {
        try profiles.setMcpPermissions(readWorkouts: readWorkouts, readBody: readBody, readPlan: readPlan,
                                       readGyms: readGyms, propose: propose, autoApply: autoApply,
                                       logWorkouts: logWorkouts)
```

and, in `disconnectClaude()`, replace

```swift
        try saveMcpPermissions(readWorkouts: false, readBody: false, readPlan: false, readGyms: false, propose: false,
                               autoApply: false)
```

with

```swift
        try saveMcpPermissions(readWorkouts: false, readBody: false, readPlan: false, readGyms: false, propose: false,
                               autoApply: false, logWorkouts: false)
```

In `ios/GymRollins/Features/Claude/ClaudeConnectionView.swift`, replace

```swift
        var autoApply = false

        static let none = Permissions(readWorkouts: false, readBody: false, readPlan: false, readGyms: false,
                                      propose: false, autoApply: false)
```

with

```swift
        var autoApply = false
        var logWorkouts = false

        static let none = Permissions(readWorkouts: false, readBody: false, readPlan: false, readGyms: false,
                                      propose: false, autoApply: false, logWorkouts: false)
```

replace

```swift
        Permissions(readWorkouts: p.mcpReadWorkouts, readBody: p.mcpReadBody, readPlan: p.mcpReadPlan,
                    readGyms: p.mcpReadGyms, propose: p.mcpPropose, autoApply: p.mcpAutoApply)
```

with

```swift
        Permissions(readWorkouts: p.mcpReadWorkouts, readBody: p.mcpReadBody, readPlan: p.mcpReadPlan,
                    readGyms: p.mcpReadGyms, propose: p.mcpPropose, autoApply: p.mcpAutoApply,
                    logWorkouts: p.mcpLogWorkouts)
```

and replace

```swift
            try env.saveMcpPermissions(readWorkouts: new.readWorkouts, readBody: new.readBody, readPlan: new.readPlan,
                                       readGyms: new.readGyms, propose: new.propose, autoApply: new.autoApply)
```

with

```swift
            try env.saveMcpPermissions(readWorkouts: new.readWorkouts, readBody: new.readBody, readPlan: new.readPlan,
                                       readGyms: new.readGyms, propose: new.propose, autoApply: new.autoApply,
                                       logWorkouts: new.logWorkouts)
```

In `ios/GymRollins/Features/Settings/SettingsPreferences.swift`, replace

```swift
             mcpReadGyms: Bool? = nil, mcpPropose: Bool? = nil, mcpAutoApply: Bool? = nil) -> Profile {
```

with

```swift
             mcpReadGyms: Bool? = nil, mcpPropose: Bool? = nil, mcpAutoApply: Bool? = nil,
             mcpLogWorkouts: Bool? = nil) -> Profile {
```

and replace

```swift
               mcpAutoApply: mcpAutoApply ?? self.mcpAutoApply)
```

with

```swift
               mcpAutoApply: mcpAutoApply ?? self.mcpAutoApply, mcpLogWorkouts: mcpLogWorkouts ?? self.mcpLogWorkouts)
```

In `ios/GymRollins/Features/Onboarding/ProfileSetupView.swift`, replace

```swift
                              mcpReadGyms: current.mcpReadGyms, mcpPropose: current.mcpPropose, mcpAutoApply: current.mcpAutoApply)
```

with

```swift
                              mcpReadGyms: current.mcpReadGyms, mcpPropose: current.mcpPropose, mcpAutoApply: current.mcpAutoApply,
                              mcpLogWorkouts: current.mcpLogWorkouts)
```

Run: the command from Step 6, with `-only-testing:GymRollinsTests/ProfileLimitsTests
-only-testing:GymRollinsTests/ClaudeEnvironmentTests -only-testing:GymRollinsTests/ClaudeDisconnectTests
-only-testing:GymRollinsTests/TodayRoutineProposalTests`.
Expected: `** TEST SUCCEEDED **`; `settingsUpdatesKeepAddWorkouts` and `addWorkoutsIsOffUntilTurnedOnAndDisconnectTurnsItOff`
among the passed. (`logWorkouts:` has no default, so a call site this task missed doesn't compile.)

- [ ] **Step 8: Commit**

```bash
git add ios/Packages/GymData/Sources/GymData/Records/ProfileRecord.swift \
  ios/Packages/GymData/Sources/GymData/Values/Profile.swift ios/Packages/GymData/Sources/GymData/Sync/SyncModels.swift \
  ios/Packages/GymData/Sources/GymData/Repositories/ProfileRepository.swift \
  ios/Packages/GymData/Sources/GymData/Sync/SyncStore+Profile.swift \
  ios/Packages/GymData/Tests/GymDataTests/ProposalTests.swift ios/Packages/GymData/Tests/GymDataTests/SyncStoreTests.swift \
  ios/Packages/GymSync/Tests/GymSyncTests/SyncEngineTests.swift ios/GymRollins/App/AppEnvironment+Claude.swift \
  ios/GymRollins/Features/Claude/ClaudeConnectionView.swift ios/GymRollins/Features/Settings/SettingsPreferences.swift \
  ios/GymRollins/Features/Onboarding/ProfileSetupView.swift ios/GymRollinsTests/ClaudeEnvironmentTests.swift \
  ios/GymRollinsTests/SignOutAndDisconnectTests.swift ios/GymRollinsTests/TodayRoutineProposalTests.swift \
  ios/GymRollinsTests/ProfileLimitsTests.swift
git commit -m "feat(ios): the Add workouts permission on the profile, off by default"
```

- [ ] **Step 9: Review**

**code-reviewer** for plan compliance: every writer of the profile carries the flag
(`git grep -n "mcpAutoApply" -- ios/Packages/GymData/Sources ios/GymRollins` lists the same places with
`mcpLogWorkouts` next to each). Then the same agent for quality.

---

### Task A2: `mcp_log_workouts` on the wire

**Files:**
- Modify: `ios/Packages/GymSync/Sources/GymSync/DTO/ProfileDTO.swift`
- Test: `ios/Packages/GymSync/Tests/GymSyncTests/DTOTests.swift`, `ios/GymRollinsTests/SignOutAndDisconnectTests.swift`

- [ ] **Step 1: Write the failing tests**

In `ios/Packages/GymSync/Tests/GymSyncTests/DTOTests.swift`, add inside `DTOTests`, after
`profileGymsFlagRoundTripsAndAnOldRowReadsAsOn`:

```swift
    /// Plan 32: Add workouts travels as `mcp_log_workouts`, a JSON boolean like the other switches. A row from before
    /// the column existed reads as off, its default.
    @Test func profileAddWorkoutsFlagRoundTripsAndAnOldRowReadsAsOff() throws {
        var p = ProfileSnapshot()
        #expect(!p.mcpLogWorkouts)
        p.mcpLogWorkouts = true
        let row = SyncRow(value: p, clientUpdatedAt: t0)
        let body = try SyncJSON.encoder.encode(ProfileDTO(row))
        #expect(String(decoding: body, as: UTF8.self).contains(#""mcp_log_workouts":true"#))
        #expect(try wire(ProfileDTO(row)).toDomain().value.mcpLogWorkouts)

        var json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        json.removeValue(forKey: "mcp_log_workouts")
        let old = try SyncJSON.decoder.decode(ProfileDTO.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.mcpLogWorkouts)
        #expect(!old.toDomain().value.mcpLogWorkouts)
    }
```

In `ios/GymRollinsTests/SignOutAndDisconnectTests.swift`, in `successPushesTheFlagsBeforeRevoking`, replace

```swift
        #expect(await transport.storedProfile?.mcpReadGyms == false)
```

with

```swift
        #expect(await transport.storedProfile?.mcpReadGyms == false)
        #expect(await transport.storedProfile?.mcpLogWorkouts == false)
```

- [ ] **Step 2: Run them to see them fail**

Run: `(cd ios/Packages/GymSync && swift test --filter DTOTests)`
Expected: the build fails: `value of type 'ProfileDTO' has no member 'mcpLogWorkouts'`.

- [ ] **Step 3: The key in `ProfileDTO`**

In `ios/Packages/GymSync/Sources/GymSync/DTO/ProfileDTO.swift`, replace

```swift
    public let mcpAutoApply: Bool
    /// `male` / `female` or null (strength levels only).
```

with

```swift
    public let mcpAutoApply: Bool
    /// Plan 32's Add workouts (`mcp_log_workouts`): agents may add past workouts.
    public let mcpLogWorkouts: Bool
    /// `male` / `female` or null (strength levels only).
```

replace

```swift
        case mcpAutoApply = "mcp_auto_apply", clientUpdatedAt = "client_updated_at", updatedAt = "updated_at"
    }

    /// Synthesized decoding, except that a row without `mcp_read_gyms` reads as on, the column's default.
```

with

```swift
        case mcpAutoApply = "mcp_auto_apply", clientUpdatedAt = "client_updated_at", updatedAt = "updated_at"
        case mcpLogWorkouts = "mcp_log_workouts"
    }

    /// Synthesized decoding, except that a row without `mcp_read_gyms` reads as on and one without `mcp_log_workouts`
    /// as off, each column's default.
```

replace

```swift
        mcpAutoApply = try c.decode(Bool.self, forKey: .mcpAutoApply)
```

with

```swift
        mcpAutoApply = try c.decode(Bool.self, forKey: .mcpAutoApply)
        mcpLogWorkouts = try c.decodeIfPresent(Bool.self, forKey: .mcpLogWorkouts) ?? false
```

replace

```swift
        mcpAutoApply = p.mcpAutoApply
```

with

```swift
        mcpAutoApply = p.mcpAutoApply
        mcpLogWorkouts = p.mcpLogWorkouts
```

replace

```swift
        p.mcpAutoApply = mcpAutoApply
```

with

```swift
        p.mcpAutoApply = mcpAutoApply
        p.mcpLogWorkouts = mcpLogWorkouts
```

and replace

```swift
        try c.encode(mcpAutoApply, forKey: .mcpAutoApply)
```

with

```swift
        try c.encode(mcpAutoApply, forKey: .mcpAutoApply)
        try c.encode(mcpLogWorkouts, forKey: .mcpLogWorkouts)
```

Run: `(cd ios/Packages/GymSync && swift test --filter GymSyncTests)`
Expected: all passed, one test more than after Task A1.

Run (from the repo root): `cd ios && xcodegen generate && xcodebuild test -project GymRollins.xcodeproj -scheme
GymRollins -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
-only-testing:GymRollinsTests/ClaudeDisconnectTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/GymSync/Sources/GymSync/DTO/ProfileDTO.swift ios/Packages/GymSync/Tests/GymSyncTests/DTOTests.swift \
  ios/GymRollinsTests/SignOutAndDisconnectTests.swift
git commit -m "feat(ios): Add workouts syncs with the profile as mcp_log_workouts"
```

- [ ] **Step 5: Review**

**code-reviewer**: the key matches the server half's column name and kind (`mcp_log_workouts`, `bool`), and a profile
pulled from a Worker before the migration still decodes. Then the same agent for quality.

---

### Task A3: Who added a workout, on the phone (`addedBy`)

**Files:**
- Modify: `ios/Packages/GymData/Sources/GymData/Sync/SyncModels.swift`,
  `ios/Packages/GymData/Sources/GymData/Records/WorkoutRecords.swift`,
  `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+Workouts.swift`,
  `ios/Packages/GymData/Sources/GymData/Repositories/WorkoutRepository.swift`
- Test: `ios/Packages/GymData/Tests/GymDataTests/SyncStoreWorkoutTests.swift`

- [ ] **Step 1: Write the failing tests**

In `ios/Packages/GymData/Tests/GymDataTests/SyncStoreWorkoutTests.swift`, add inside `SyncStoreWorkoutTests`, after
`dirtyWorkoutsCarryRecordsAndVolume`:

```swift
    /// Plan 32: who added a workout comes with the pull, stays through the owner's edits, and is never pushed.
    @Test func anAgentsNameComesWithThePullAndOutlastsALocalEdit() throws {
        defer { f.tearDown() }
        let w = sampleWorkout(at: f.clock.now)
        let pulled = SyncRow(value: WorkoutSnapshot(workout: w, records: [], volumeKg: WorkoutMetrics.volumeKg(w),
                                                    addedBy: "Muse"),
                             clientUpdatedAt: f.clock.now, serverUpdatedAt: f.clock.now)
        try f.store.applyRemote(workouts: [pulled])
        #expect(try f.workouts.addedBy(w.id) == "Muse")
        #expect(try f.store.dirtyWorkouts().isEmpty)

        f.clock.advance()
        try f.workouts.save(sampleWorkout(id: w.id, name: "Upper", at: w.startedAt, weightKg: 65))
        #expect(try f.workouts.addedBy(w.id) == "Muse")
        let dirty = try #require(try f.store.dirtyWorkouts().first)
        #expect(dirty.value.workout.name == "Upper")
        #expect(dirty.value.addedBy == nil) // the push leaves it to the server
    }

    @Test func theOwnersWorkoutsNameNoAgentAndADeletedOneNone() throws {
        defer { f.tearDown() }
        let mine = sampleWorkout(at: f.clock.now)
        try f.workouts.save(mine)
        #expect(try f.workouts.addedBy(mine.id) == nil)
        #expect(try f.workouts.addedBy(UUID()) == nil)

        let theirs = sampleWorkout(at: f.clock.now.addingTimeInterval(-86_400))
        try f.store.applyRemote(workouts: [SyncRow(value: WorkoutSnapshot(workout: theirs, records: [], volumeKg: 0,
                                                                          addedBy: "Muse"),
                                                   clientUpdatedAt: f.clock.now, serverUpdatedAt: f.clock.now)])
        try f.workouts.delete(theirs.id)
        #expect(try f.workouts.addedBy(theirs.id) == nil)
    }

    /// "Keep other" takes the other version whole, the agent's name included.
    @Test func keepingTheOtherVersionTakesItsAgent() throws {
        defer { f.tearDown() }
        let w = sampleWorkout(at: f.clock.now)
        try savedAndSynced(w, server: f.clock.now)
        f.clock.advance()
        try f.workouts.save(sampleWorkout(id: w.id, name: "Mine", at: w.startedAt))
        let theirs = sampleWorkout(id: w.id, name: "Theirs", at: w.startedAt)
        let remote = SyncRow(value: WorkoutSnapshot(workout: theirs, records: [], volumeKg: 0, addedBy: "Muse"),
                             clientUpdatedAt: f.clock.now, serverUpdatedAt: f.clock.now.addingTimeInterval(1))
        try f.store.resolveWorkoutConflict(id: w.id, keepLocal: false, remote: remote)
        #expect(try f.workouts.workout(w.id)?.name == "Theirs")
        #expect(try f.workouts.addedBy(w.id) == "Muse")
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `(cd ios/Packages/GymData && swift test --filter SyncStoreWorkoutTests)`
Expected: the build fails: `extra argument 'addedBy' in call` and `value of type 'WorkoutRepository' has no member
'addedBy'`.

- [ ] **Step 3: The field, written only by pulls**

In `ios/Packages/GymData/Sources/GymData/Sync/SyncModels.swift`, replace the whole `WorkoutSnapshot` with

```swift
/// A finished workout plus the derived data stored with it.
public struct WorkoutSnapshot: Sendable, Equatable {
    public let workout: Workout
    public let records: [PersonalRecord]
    public let volumeKg: Double
    /// The agent that added it through `log_workout` (the server's `added_by`, plan 32); nil for the owner's own.
    /// The server owns it: pulls carry it, pushes never do.
    public let addedBy: String?

    public init(workout: Workout, records: [PersonalRecord], volumeKg: Double, addedBy: String? = nil) {
        self.workout = workout
        self.records = records
        self.volumeKg = volumeKg
        self.addedBy = addedBy
    }
}
```

In `ios/Packages/GymData/Sources/GymData/Records/WorkoutRecords.swift`, replace

```swift
    public var gymId: UUID?

    public init(id: UUID, startedAt: Date, name: String, sourceRaw: String, isActive: Bool, now: Date) {
```

with

```swift
    public var gymId: UUID?
    /// The agent that added it (`WorkoutSnapshot.addedBy`, plan 32). Only a pull writes it, so the owner's edits keep
    /// it; nil for the owner's own and for rows from before it existed.
    public var addedBy: String?

    public init(id: UUID, startedAt: Date, name: String, sourceRaw: String, isActive: Bool, now: Date) {
```

In `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+Workouts.swift`, replace

```swift
                let snapshot = try record.snapshot()
                let sent = WorkoutSnapshot(workout: try sendable(snapshot.workout), records: snapshot.records,
                                           volumeKg: snapshot.volumeKg)
```

with

```swift
                let snapshot = try record.snapshot()
                // `added_by` is the server's (plan 32): the pushed snapshot never carries it.
                let sent = WorkoutSnapshot(workout: try sendable(snapshot.workout), records: snapshot.records,
                                           volumeKg: snapshot.volumeKg)
```

replace

```swift
        r.gymId = w.gymId
        r.isActive = false
```

with

```swift
        r.gymId = w.gymId
        r.addedBy = row.value.addedBy
        r.isActive = false
```

and replace

```swift
        return WorkoutSnapshot(workout: value, records: records, volumeKg: volumeKg)
```

with

```swift
        return WorkoutSnapshot(workout: value, records: records, volumeKg: volumeKg, addedBy: addedBy)
```

In `ios/Packages/GymData/Sources/GymData/Repositories/WorkoutRepository.swift`, replace

```swift
    public func workout(_ id: UUID) throws -> Workout? {
        try record(id).flatMap { $0.deletedAt == nil ? $0.value : nil }
    }
```

with

```swift
    public func workout(_ id: UUID) throws -> Workout? {
        try record(id).flatMap { $0.deletedAt == nil ? $0.value : nil }
    }

    /// The agent that added this workout (plan 32), or nil: the owner's own, deleted, or not on this iPhone.
    public func addedBy(_ id: UUID) throws -> String? {
        try record(id).flatMap { $0.deletedAt == nil ? $0.addedBy : nil }
    }
```

Run: `(cd ios/Packages/GymData && swift test)`
Expected: all passed, three tests more than after Task A1.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/GymData/Sources/GymData/Sync/SyncModels.swift \
  ios/Packages/GymData/Sources/GymData/Records/WorkoutRecords.swift \
  ios/Packages/GymData/Sources/GymData/Sync/SyncStore+Workouts.swift \
  ios/Packages/GymData/Sources/GymData/Repositories/WorkoutRepository.swift \
  ios/Packages/GymData/Tests/GymDataTests/SyncStoreWorkoutTests.swift
git commit -m "feat(ios): a pulled workout keeps the agent that added it through the owner's edits"
```

- [ ] **Step 5: Review**

**code-reviewer** for decision A2: `git grep -n "addedBy" -- ios/Packages/GymData/Sources` shows one writer
(`SyncStore` `write`) and `upsertRecord` doesn't touch it. Then the same agent for quality.

---

### Task A4: `added_by` on the wire, pulls only

**Files:**
- Modify: `ios/Packages/GymSync/Sources/GymSync/DTO/WorkoutDTO.swift`
- Test: `ios/Packages/GymSync/Tests/GymSyncTests/DTOTests.swift`

- [ ] **Step 1: Write the failing test**

In `ios/Packages/GymSync/Tests/GymSyncTests/DTOTests.swift`, add inside `DTOTests`, after
`decodesTheLinksAServerRowCarriesAndToleratesNulls`:

```swift
    /// Plan 32: a pulled workout says which agent added it (null or absent: nobody); a push never names one, whatever
    /// the phone holds, because the server owns it.
    @Test func addedByIsReadFromPullsAndNeverSent() throws {
        let json = #"{"id":"8f7c0a2e-3b1d-4c55-9a51-2f7e0b8c9d10","started_at":"2026-10-08T17:02:00Z","#
            + #""ended_at":"2026-10-08T18:05:00Z","name":"Upper","source":"import","#
            + #""client_updated_at":"2026-11-09T01:31:12Z","updated_at":"2026-11-09T01:31:12Z","#
            + #""added_by":"Muse","entries":[]}"#
        let pulled = try SyncJSON.decoder.decode(WorkoutDTO.self, from: Data(json.utf8))
        #expect(pulled.addedBy == "Muse")
        #expect(pulled.toDomain().value.addedBy == "Muse")
        #expect(pulled.toDomain().value.workout.source == .import)

        let unnamed = json.replacingOccurrences(of: #""added_by":"Muse","#, with: #""added_by":null,"#)
        #expect(try SyncJSON.decoder.decode(WorkoutDTO.self, from: Data(unnamed.utf8)).addedBy == nil)
        let older = json.replacingOccurrences(of: #""added_by":"Muse","#, with: "")
        #expect(try SyncJSON.decoder.decode(WorkoutDTO.self, from: Data(older.utf8)).addedBy == nil)

        let sent = String(decoding: try SyncJSON.encoder.encode(WorkoutDTO(pulled.toDomain())), as: UTF8.self)
        #expect(!sent.contains("added_by"))
        #expect(!sent.contains("Muse"))
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `(cd ios/Packages/GymSync && swift test --filter DTOTests)`
Expected: the build fails: `value of type 'WorkoutDTO' has no member 'addedBy'`.

- [ ] **Step 3: Decode it, never encode it**

In `ios/Packages/GymSync/Sources/GymSync/DTO/WorkoutDTO.swift`, replace

```swift
    public let gymId: UUID?
    public let clientUpdatedAt: Date
```

with

```swift
    public let gymId: UUID?
    /// The agent that added it (`added_by`, plan 32): read from pulls and never encoded, because the server owns it.
    public let addedBy: String?
    public let clientUpdatedAt: Date
```

replace

```swift
        case baseUpdatedAt = "base_updated_at", force
    }
```

with

```swift
        case baseUpdatedAt = "base_updated_at", force, addedBy = "added_by"
    }
```

replace

```swift
        gymId = w.gymId
        clientUpdatedAt = row.clientUpdatedAt
```

with

```swift
        gymId = w.gymId
        addedBy = row.value.addedBy
        clientUpdatedAt = row.clientUpdatedAt
```

replace

```swift
        gymId = try c.decodeIfPresent(UUID.self, forKey: .gymId)
        clientUpdatedAt = try c.decode(Date.self, forKey: .clientUpdatedAt)
```

with

```swift
        gymId = try c.decodeIfPresent(UUID.self, forKey: .gymId)
        addedBy = try c.decodeIfPresent(String.self, forKey: .addedBy)
        clientUpdatedAt = try c.decode(Date.self, forKey: .clientUpdatedAt)
```

replace

```swift
        try c.encode(baseUpdatedAt, forKey: .baseUpdatedAt)
        try c.encode(force, forKey: .force)
    }
```

with

```swift
        try c.encode(baseUpdatedAt, forKey: .baseUpdatedAt)
        try c.encode(force, forKey: .force)
        // `added_by` is never written: the server keeps it through the owner's edits (plan 32).
    }
```

and replace

```swift
        return SyncRow(value: WorkoutSnapshot(workout: workout, records: records, volumeKg: volKg),
                       clientUpdatedAt: clientUpdatedAt, deletedAt: deletedAt, serverUpdatedAt: updatedAt)
```

with

```swift
        return SyncRow(value: WorkoutSnapshot(workout: workout, records: records, volumeKg: volKg, addedBy: addedBy),
                       clientUpdatedAt: clientUpdatedAt, deletedAt: deletedAt, serverUpdatedAt: updatedAt)
```

Run: `(cd ios/Packages/GymSync && swift test --filter GymSyncTests)`
Expected: all passed, one test more than after Task A2 (`workoutRoundTripWithRecords` still passes: its snapshot has no
agent).

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/GymSync/Sources/GymSync/DTO/WorkoutDTO.swift ios/Packages/GymSync/Tests/GymSyncTests/DTOTests.swift
git commit -m "feat(ios): workout pulls read added_by, and pushes never send it"
```

- [ ] **Step 5: Review**

**code-reviewer**: the contract's "never sends it in a push" holds at both layers (A3's pushed snapshot, A4's encoder).
Then the same agent for quality.

---

### Task A5: Who sent a proposal, on the phone (`fromAgent`)

**Files:**
- Modify: `ios/Packages/GymData/Sources/GymData/Proposals/Proposal.swift`,
  `ios/Packages/GymData/Sources/GymData/Records/ProposalRecord.swift`,
  `ios/Packages/GymData/Sources/GymData/Repositories/ProposalRepository.swift`
- Test: `ios/Packages/GymData/Tests/GymDataTests/ProposalTests.swift`

- [ ] **Step 1: Write the failing test**

In `ios/Packages/GymData/Tests/GymDataTests/ProposalTests.swift`, add inside `ProposalRepositoryTests`, after
`pendingProposalsResolvedElsewhereAreDropped`:

```swift
    /// Plan 32: the sender's name is stored with a new proposal, and one pulled before the app knew senders learns it
    /// from the next pull. A name, once stored, stays.
    @Test func theSendersNameIsKeptAndFilledInOnce() throws {
        let unnamed = f.kneeBreak()
        try f.proposals.upsertRemote([unnamed])
        #expect(try f.proposals.proposal(unnamed.id)?.fromAgent == nil)

        let named = Proposal(id: unnamed.id, createdAt: unnamed.createdAt, summary: unnamed.summary,
                             changes: unnamed.changes, fromAgent: "Muse")
        try f.proposals.upsertRemote([named])
        #expect(try f.proposals.proposal(unnamed.id)?.fromAgent == "Muse")
        let renamed = Proposal(id: unnamed.id, createdAt: unnamed.createdAt, summary: unnamed.summary,
                               changes: unnamed.changes, fromAgent: "Claude")
        try f.proposals.upsertRemote([renamed])
        #expect(try f.proposals.proposal(unnamed.id)?.fromAgent == "Muse")

        let fresh = Proposal(id: UUID(), createdAt: f.clock.now, summary: "Add dips", changes: [
            PlanChange(id: "c1", type: .addExercise, routineId: f.id(f.push), exerciseId: "dips", sets: 3, reps: 10),
        ], fromAgent: "Claude")
        try f.proposals.upsertRemote([named, fresh])
        #expect(try f.proposals.proposal(fresh.id)?.fromAgent == "Claude")
        try f.proposals.dismiss(fresh.id)
        #expect(try f.proposals.proposal(fresh.id)?.fromAgent == "Claude") // a resolution keeps it
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `(cd ios/Packages/GymData && swift test --filter ProposalRepositoryTests)`
Expected: the build fails: `extra argument 'fromAgent' in call` and `value of type 'Proposal' has no member 'fromAgent'`.

- [ ] **Step 3: The field**

In `ios/Packages/GymData/Sources/GymData/Proposals/Proposal.swift`, replace

```swift
    public let autoApplied: Bool
    public let hasSnapshot: Bool

    public init(id: UUID, createdAt: Date, source: String = "claude", summary: String, changes: [PlanChange],
                status: ProposalStatus = .pending, appliedChangeIds: [String] = [], skipped: [PlanViolation] = [],
                resolvedAt: Date? = nil, autoApplied: Bool = false, hasSnapshot: Bool = false) {
```

with

```swift
    public let autoApplied: Bool
    public let hasSnapshot: Bool
    /// The agent that sent it (the server's `from_agent`, plan 32); nil for proposals from before the server kept it.
    public let fromAgent: String?

    public init(id: UUID, createdAt: Date, source: String = "claude", summary: String, changes: [PlanChange],
                status: ProposalStatus = .pending, appliedChangeIds: [String] = [], skipped: [PlanViolation] = [],
                resolvedAt: Date? = nil, autoApplied: Bool = false, hasSnapshot: Bool = false,
                fromAgent: String? = nil) {
```

and replace

```swift
        self.hasSnapshot = hasSnapshot
    }
```

with

```swift
        self.hasSnapshot = hasSnapshot
        self.fromAgent = fromAgent
    }
```

In `ios/Packages/GymData/Sources/GymData/Records/ProposalRecord.swift`, replace

```swift
    public var source: String
    public var summary: String
```

with

```swift
    public var source: String
    /// The agent that sent it (`Proposal.fromAgent`, plan 32); nil for older proposals.
    public var fromAgent: String?
    public var summary: String
```

In `ios/Packages/GymData/Sources/GymData/Repositories/ProposalRepository.swift`, replace

```swift
    /// Stores the server's pending proposals. New ones are inserted clean; a proposal still pending here but no
    /// longer in the server's list was resolved on another device, so it is dropped. Local resolutions are kept.
    public func upsertRemote(_ remote: [Proposal]) throws {
        let ids = Set(remote.map(\.id))
        for p in remote where try record(p.id) == nil {
            let r = ProposalRecord(id: p.id, createdAt: p.createdAt, source: p.source, summary: p.summary,
                                   changesData: try JSONEncoder().encode(p.changes), statusRaw: p.status.rawValue,
                                   now: now())
            context.insert(r)
        }
```

with

```swift
    /// Stores the server's pending proposals. New ones are inserted clean; a proposal still pending here but no
    /// longer in the server's list was resolved on another device, so it is dropped. Local resolutions are kept.
    /// Plan 32: a stored proposal without a sender (pulled before the app read `from_agent`) takes the pulled one's.
    public func upsertRemote(_ remote: [Proposal]) throws {
        let ids = Set(remote.map(\.id))
        for p in remote {
            if let stored = try record(p.id) {
                if stored.fromAgent == nil { stored.fromAgent = p.fromAgent }
                continue
            }
            let r = ProposalRecord(id: p.id, createdAt: p.createdAt, source: p.source, summary: p.summary,
                                   changesData: try JSONEncoder().encode(p.changes), statusRaw: p.status.rawValue,
                                   now: now())
            r.fromAgent = p.fromAgent
            context.insert(r)
        }
```

and, in `value(_:)`, replace

```swift
                            autoApplied: r.autoApplied, hasSnapshot: r.snapshotData != nil)
```

with

```swift
                            autoApplied: r.autoApplied, hasSnapshot: r.snapshotData != nil, fromAgent: r.fromAgent)
```

Run: `(cd ios/Packages/GymData && swift test)`
Expected: all passed, one test more than after Task A3.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/GymData/Sources/GymData/Proposals/Proposal.swift \
  ios/Packages/GymData/Sources/GymData/Records/ProposalRecord.swift \
  ios/Packages/GymData/Sources/GymData/Repositories/ProposalRepository.swift \
  ios/Packages/GymData/Tests/GymDataTests/ProposalTests.swift
git commit -m "feat(ios): proposals keep the name of the agent that sent them"
```

- [ ] **Step 5: Review**

**code-reviewer** for decision A8, then for quality.

---

### Task A6: `from_agent` on the wire

**Files:**
- Modify: `ios/Packages/GymSync/Sources/GymSync/DTO/ProposalDTO.swift`,
  `ios/Packages/GymSync/Tests/GymSyncTests/FakeTransport.swift`
- Test: `ios/Packages/GymSync/Tests/GymSyncTests/DTOTests.swift`,
  `ios/Packages/GymSync/Tests/GymSyncTests/SyncEngineProposalTests.swift`

- [ ] **Step 1: Write the failing tests**

In `ios/Packages/GymSync/Tests/GymSyncTests/DTOTests.swift`, add inside `DTOTests`, after `decodesProposal`:

```swift
    /// Plan 32: the sender's name when the server kept one; older rows have none.
    @Test func aProposalSaysWhoSentItWhenKnown() throws {
        let named = #"{"id":"0f0f0f0f-0000-4000-8000-000000000004","created_at":"2026-11-09T01:20:00Z","#
            + #""summary":"Pull day","changes":[],"status":"pending","from_agent":"Muse"}"#
        let dto = try SyncJSON.decoder.decode(ProposalDTO.self, from: Data(named.utf8))
        #expect(dto.fromAgent == "Muse")
        #expect(dto.toDomain().fromAgent == "Muse")
        #expect(try wire(dto).fromAgent == "Muse")

        let older = named.replacingOccurrences(of: #","from_agent":"Muse""#, with: "")
        let old = try SyncJSON.decoder.decode(ProposalDTO.self, from: Data(older.utf8))
        #expect(old.fromAgent == nil && old.toDomain().fromAgent == nil)
        let null = named.replacingOccurrences(of: #""from_agent":"Muse""#, with: #""from_agent":null"#)
        #expect(try SyncJSON.decoder.decode(ProposalDTO.self, from: Data(null.utf8)).fromAgent == nil)
    }
```

In `ios/Packages/GymSync/Tests/GymSyncTests/SyncEngineProposalTests.swift`, add inside `SyncEngineProposalTests`,
after `pulledProposalAppearsPendingAndDismissPushesStatus`:

```swift
    /// Plan 32: a pulled proposal keeps its sender's name, and resolving it changes nothing about who sent it.
    @Test func aPulledProposalKeepsItsSendersName() async throws {
        defer { f.tearDown() }
        let id = UUID()
        await f.server.seed(proposal: ProposalDTO(id: id, createdAt: f.clock.now.addingTimeInterval(-60),
                                                  summary: "Heavier bench", changes: [
            PlanChange(id: "c1", type: .weight, routineId: push.id.uuidString.lowercased(), exerciseId: "bench",
                       weightKg: 65),
        ], fromAgent: "Muse"))
        await engine.sync()
        #expect(try proposals.proposal(id)?.fromAgent == "Muse")

        try proposals.dismiss(id)
        await engine.sync()
        #expect(await f.server.proposals[id]?.status == "dismissed")
        #expect(await f.server.proposals[id]?.fromAgent == "Muse")
        #expect(try proposals.proposal(id)?.fromAgent == "Muse")
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `(cd ios/Packages/GymSync && swift test --filter DTOTests)`
Expected: the build fails: `value of type 'ProposalDTO' has no member 'fromAgent'` and `extra argument 'fromAgent'
in call`.

- [ ] **Step 3: The key in `ProposalDTO`, and the fake keeps it**

In `ios/Packages/GymSync/Sources/GymSync/DTO/ProposalDTO.swift`, replace

```swift
    public let resolvedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, source, summary, changes, status
        case createdAt = "created_at", appliedChangeIds = "applied_change_ids", resolvedAt = "resolved_at"
    }

    public init(id: UUID, createdAt: Date, source: String = "claude", summary: String, changes: [PlanChange],
                status: String = "pending", appliedChangeIds: [String] = [], resolvedAt: Date? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.summary = summary
        self.changes = changes
        self.status = status
        self.appliedChangeIds = appliedChangeIds
        self.resolvedAt = resolvedAt
    }
```

with

```swift
    public let resolvedAt: Date?
    /// The agent that sent it (`from_agent`, plan 32); nil for proposals from before the server kept it.
    public let fromAgent: String?

    enum CodingKeys: String, CodingKey {
        case id, source, summary, changes, status
        case createdAt = "created_at", appliedChangeIds = "applied_change_ids", resolvedAt = "resolved_at"
        case fromAgent = "from_agent"
    }

    public init(id: UUID, createdAt: Date, source: String = "claude", summary: String, changes: [PlanChange],
                status: String = "pending", appliedChangeIds: [String] = [], resolvedAt: Date? = nil,
                fromAgent: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.summary = summary
        self.changes = changes
        self.status = status
        self.appliedChangeIds = appliedChangeIds
        self.resolvedAt = resolvedAt
        self.fromAgent = fromAgent
    }
```

replace

```swift
                  resolvedAt: try c.decodeIfPresent(Date.self, forKey: .resolvedAt))
    }
```

with

```swift
                  resolvedAt: try c.decodeIfPresent(Date.self, forKey: .resolvedAt),
                  fromAgent: try c.decodeIfPresent(String.self, forKey: .fromAgent))
    }
```

and replace

```swift
                 status: ProposalStatus(rawValue: status) ?? .pending, appliedChangeIds: appliedChangeIds,
                 resolvedAt: resolvedAt)
```

with

```swift
                 status: ProposalStatus(rawValue: status) ?? .pending, appliedChangeIds: appliedChangeIds,
                 resolvedAt: resolvedAt, fromAgent: fromAgent)
```

In `ios/Packages/GymSync/Tests/GymSyncTests/FakeTransport.swift`, in `resolveProposal`, replace

```swift
        proposals[id] = ProposalDTO(id: p.id, createdAt: p.createdAt, source: p.source, summary: p.summary,
                                    changes: p.changes, status: status, appliedChangeIds: appliedChangeIds,
                                    resolvedAt: at)
```

with

```swift
        proposals[id] = ProposalDTO(id: p.id, createdAt: p.createdAt, source: p.source, summary: p.summary,
                                    changes: p.changes, status: status, appliedChangeIds: appliedChangeIds,
                                    resolvedAt: at, fromAgent: p.fromAgent)
```

Run: `(cd ios/Packages/GymSync && swift test --filter GymSyncTests)`
Expected: all passed, two tests more than after Task A4.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/GymSync/Sources/GymSync/DTO/ProposalDTO.swift \
  ios/Packages/GymSync/Tests/GymSyncTests/FakeTransport.swift ios/Packages/GymSync/Tests/GymSyncTests/DTOTests.swift \
  ios/Packages/GymSync/Tests/GymSyncTests/SyncEngineProposalTests.swift
git commit -m "feat(ios): proposal pulls read from_agent"
```

- [ ] **Step 5: Review**

**code-reviewer**, then for quality.

---

### Task A7: Connected agents in GymSync (`GET /v1/agents`, disconnect one)

**Files:**
- Create: `ios/Packages/GymSync/Sources/GymSync/ConnectedAgents.swift`,
  `ios/Packages/GymSync/Sources/GymSync/ApiSyncTransport+Agents.swift`,
  `ios/Packages/GymSync/Tests/GymSyncTests/ApiAgentsTransportTests.swift`,
  `ios/Packages/GymSync/Tests/GymSyncTests/SyncEngineAgentsTests.swift`
- Modify: `ios/Packages/GymSync/Sources/GymSync/SyncTransport.swift`, `ios/Packages/GymSync/Sources/GymSync/SyncEngine.swift`,
  `ios/Packages/GymSync/Tests/GymSyncTests/FakeTransport.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/Packages/GymSync/Tests/GymSyncTests/ApiAgentsTransportTests.swift`:

```swift
import Foundation
import Testing
@testable import GymSync

/// `ApiSyncTransport` against a stub of `/v1/agents` (plan 32, spec section 3): the list as the server answers it,
/// and Disconnect for one agent.
@Suite struct ApiAgentsTransportTests {
    private static let museJSON = #"{"client_id": "MuseClientIdAbc", "name": "Muse", "host": "agent.meta.ai", "#
        + #""known_host": false, "connected_at": "2026-11-09T01:20:00.000000Z", "#
        + #""last_used_at": "2026-11-09T01:31:12.000000Z"}"#
    private static let claudeJSON = #"{"client_id": "ClaudeClientIdXyz", "name": "Claude", "host": "claude.ai", "#
        + #""known_host": true, "connected_at": "2026-11-01T10:00:00.000000Z", "last_used_at": null}"#

    @Test func theListIsEachAgentInTheServersOrder() async throws {
        let server = StubServer { _ in .json(200, #"{"agents": [\#(Self.museJSON), \#(Self.claudeJSON)]}"#) }

        let agents = try await ApiSyncTransport(api: server.client()).connectedAgents()

        let request = try #require(server.requests.first)
        #expect(request.method == "GET" && request.path == "/v1/agents")
        #expect(agents == [
            ConnectedAgent(clientId: "MuseClientIdAbc", name: "Muse", host: "agent.meta.ai", knownHost: false,
                           connectedAt: SyncDate.parse("2026-11-09T01:20:00Z")!,
                           lastUsedAt: SyncDate.parse("2026-11-09T01:31:12Z")),
            ConnectedAgent(clientId: "ClaudeClientIdXyz", name: "Claude", host: "claude.ai", knownHost: true,
                           connectedAt: SyncDate.parse("2026-11-01T10:00:00Z")!, lastUsedAt: nil),
        ])
        #expect(agents.map(\.id) == ["MuseClientIdAbc", "ClaudeClientIdXyz"])
    }

    @Test func noAgentsIsAnEmptyList() async throws {
        let server = StubServer { _ in .json(200, #"{"agents": []}"#) }
        #expect(try await ApiSyncTransport(api: server.client()).connectedAgents().isEmpty)
    }

    @Test func disconnectPostsForThatAgentOnly() async throws {
        let server = StubServer { _ in .json(200, #"{"disconnected": true}"#) }

        try await ApiSyncTransport(api: server.client()).disconnectAgent(clientId: "MuseClientIdAbc")

        let request = try #require(server.requests.first)
        #expect(request.method == "POST" && request.path == "/v1/agents/MuseClientIdAbc/disconnect")
        #expect(server.requests.count == 1)
    }

    /// Only the server's `unknown_agent` says the account has no grant for it. A missing route (an older Worker) or a
    /// proxy's page stays an error.
    @Test func anAgentTheAccountDoesntHaveIsUnknown() async throws {
        let unknown = StubServer { _ in
            .json(404, #"{"error": {"code": "unknown_agent", "message": "No such agent."}}"#)
        }
        await #expect(throws: AgentError.unknownAgent) {
            try await ApiSyncTransport(api: unknown.client()).disconnectAgent(clientId: "MuseClientIdAbc")
        }
        let noRoute = StubServer { _ in .json(404, #"{"error": {"code": "not_found", "message": "No such route."}}"#) }
        await #expect(throws: ApiError(status: 404, code: "not_found", message: "No such route.")) {
            try await ApiSyncTransport(api: noRoute.client()).disconnectAgent(clientId: "MuseClientIdAbc")
        }
    }

    /// The id goes into the URL path, so only the characters a client id is made of are ever sent.
    @Test func anIdThatCantBeAClientIdIsNeverSent() async throws {
        let server = StubServer { _ in .json(200, #"{"disconnected": true}"#) }
        for id in ["", "../claude/revoke", "a/b", "Muse Client", "mus\u{00E9}", "a?b=c", String(repeating: "a", count: 129)] {
            await #expect(throws: AgentError.unknownAgent) {
                try await ApiSyncTransport(api: server.client()).disconnectAgent(clientId: id)
            }
        }
        #expect(server.requests.isEmpty)
        try await ApiSyncTransport(api: server.client()).disconnectAgent(clientId: "Abc_def-123")
        #expect(server.requests.count == 1)
    }
}
```

Create `ios/Packages/GymSync/Tests/GymSyncTests/SyncEngineAgentsTests.swift`:

```swift
import Foundation
import Testing
@testable import GymSync

/// Plan 32: the engine hands Settings › AI agents the server's list and Disconnect for one agent.
@MainActor
@Suite struct SyncEngineAgentsTests {
    let f: EngineFixture
    init() throws { f = try EngineFixture() }

    private static let muse = ConnectedAgent(clientId: "MuseClientIdAbc", name: "Muse", host: "agent.meta.ai",
                                             knownHost: false, connectedAt: t0, lastUsedAt: t0.addingTimeInterval(600))
    private static let claude = ConnectedAgent(clientId: "ClaudeClientIdXyz", name: "Claude", host: "claude.ai",
                                               knownHost: true, connectedAt: t0.addingTimeInterval(-86_400),
                                               lastUsedAt: nil)

    @Test func theListIsTheServersAndDisconnectCutsOnlyThatAgent() async throws {
        defer { f.tearDown() }
        await f.server.seed(agents: [Self.muse, Self.claude])
        #expect(try await f.engine.connectedAgents() == [Self.muse, Self.claude])

        try await f.engine.disconnectAgent(clientId: Self.muse.clientId)
        #expect(try await f.engine.connectedAgents() == [Self.claude])
        await #expect(throws: AgentError.unknownAgent) {
            try await f.engine.disconnectAgent(clientId: Self.muse.clientId)
        }
    }

    @Test func offlineTheListAndDisconnectFailAndNothingGoes() async throws {
        defer { f.tearDown() }
        await f.server.seed(agents: [Self.muse])
        await f.server.fail(with: URLError(.notConnectedToInternet))
        await #expect(throws: URLError.self) { try await f.engine.connectedAgents() }
        await #expect(throws: URLError.self) { try await f.engine.disconnectAgent(clientId: Self.muse.clientId) }
        #expect(await f.server.agents == [Self.muse])
    }
}
```

In `ios/Packages/GymSync/Tests/GymSyncTests/FakeTransport.swift`, replace

```swift
    private(set) var revokedGrants: [UUID] = []
```

with

```swift
    private(set) var revokedGrants: [UUID] = []
    /// The agents connected to the account (plan 32), newest connection first.
    private(set) var agents: [ConnectedAgent] = []
```

replace

```swift
    func seed(grants clientIds: [UUID]) { grants = clientIds }
```

with

```swift
    func seed(grants clientIds: [UUID]) { grants = clientIds }
    func seed(agents list: [ConnectedAgent]) { agents = list }
```

and replace

```swift
        grants = []
        return revoked.count
    }
```

with

```swift
        grants = []
        return revoked.count
    }

    func connectedAgents() throws -> [ConnectedAgent] {
        if let failure { throw failure } // a read: not counted in pushCalls
        return agents
    }

    /// `POST /v1/agents/:clientId/disconnect`: only that agent goes; one the account doesn't have is `unknown_agent`.
    func disconnectAgent(clientId: String) throws {
        try gate()
        guard agents.contains(where: { $0.clientId == clientId }) else { throw AgentError.unknownAgent }
        agents = agents.filter { $0.clientId != clientId }
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `(cd ios/Packages/GymSync && swift test --filter ApiAgentsTransportTests)`
Expected: the build fails: `cannot find 'ConnectedAgent' in scope`, `cannot find 'AgentError' in scope`.

- [ ] **Step 3: The agent, its error, and the transport**

Create `ios/Packages/GymSync/Sources/GymSync/ConnectedAgents.swift`:

```swift
import Foundation

/// One agent connected to the account, as Settings › AI agents lists it (`GET /v1/agents`, plan 32): an OAuth client
/// that holds this account's consent or a live refresh token. The server lists them newest connection first.
public struct ConnectedAgent: Decodable, Equatable, Sendable, Identifiable {
    public let clientId: String
    /// The name it registered with (at most 64 characters), or its host when it gave none. Chosen by the agent: shown
    /// as plain text only.
    public let name: String
    /// The host of its first redirect URL: `claude.ai`, `agent.meta.ai`, or `127.0.0.1:53682` for a loopback one.
    public let host: String
    /// True for Claude's own hosts (claude.ai, claude.com), as on the approve sheet.
    public let knownHost: Bool
    public let connectedAt: Date
    /// Its newest MCP call for this account; nil before the first.
    public let lastUsedAt: Date?

    public var id: String { clientId }

    public init(clientId: String, name: String, host: String, knownHost: Bool, connectedAt: Date, lastUsedAt: Date?) {
        self.clientId = clientId
        self.name = name
        self.host = host
        self.knownHost = knownHost
        self.connectedAt = connectedAt
        self.lastUsedAt = lastUsedAt
    }

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id", name, host, knownHost = "known_host", connectedAt = "connected_at"
        case lastUsedAt = "last_used_at"
    }
}

/// Why Disconnect couldn't act on an agent.
public enum AgentError: Error, Equatable, Sendable {
    /// The account has no grant for this client (`404 unknown_agent`), or the id can't be a client id: it is already
    /// disconnected, or was never connected.
    case unknownAgent
}
```

Create `ios/Packages/GymSync/Sources/GymSync/ApiSyncTransport+Agents.swift`:

```swift
import Foundation

/// The agents connected to the account (plan 32, spec section 3), behind the app's session like the rest of `/v1`:
/// - `GET /v1/agents` → `{"agents": [...]}`, newest connection first.
/// - `POST /v1/agents/:clientId/disconnect` → `{"disconnected": true}`, or `404 unknown_agent` when the account has
///   no grant for that client. Every other agent keeps its access; `POST /v1/claude/revoke` stays as Disconnect all.
extension ApiSyncTransport {
    public func connectedAgents() async throws -> [ConnectedAgent] {
        let answer: AgentList = try await api.get("/v1/agents")
        return answer.agents
    }

    public func disconnectAgent(clientId: String) async throws {
        guard Self.isClientId(clientId) else { throw AgentError.unknownAgent }
        do {
            let _: Disconnected = try await api.post("/v1/agents/\(clientId)/disconnect", NothingToSend())
        } catch let error as ApiError where error.status == 404 && error.code == "unknown_agent" {
            throw AgentError.unknownAgent
        }
    }

    /// The id goes into the URL path, so only what a client id is made of is sent: ASCII letters (Better Auth's are
    /// 32 of them), digits, `-` and `_`, at most 128. Anything else names no agent of this account.
    static func isClientId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

private struct AgentList: Decodable {
    let agents: [ConnectedAgent]
}

private struct Disconnected: Decodable {
    let disconnected: Bool
}

private struct NothingToSend: Encodable {}
```

In `ios/Packages/GymSync/Sources/GymSync/SyncTransport.swift`, replace

```swift
    /// Revokes every OAuth grant the signed-in user has given (the Claude connector is GymRollins' only OAuth
    /// client); returns how many were revoked.
    func revokeOAuthGrants() async throws -> Int
```

with

```swift
    /// Revokes every OAuth grant the signed-in user has given, every agent's (Disconnect all); returns how many were
    /// revoked.
    func revokeOAuthGrants() async throws -> Int
    /// The agents connected to this account, newest connection first (plan 32).
    func connectedAgents() async throws -> [ConnectedAgent]
    /// Ends one agent's access; the others keep theirs. Throws `AgentError.unknownAgent` when the account has no grant
    /// for it.
    func disconnectAgent(clientId: String) async throws
```

and replace

```swift
    public func revokeOAuthGrants() async throws -> Int { 0 }
```

with

```swift
    public func revokeOAuthGrants() async throws -> Int { 0 }

    /// Test doubles that predate plan 32 have no agents: nothing listed, nothing to disconnect.
    public func connectedAgents() async throws -> [ConnectedAgent] { [] }
    public func disconnectAgent(clientId: String) async throws { throw AgentError.unknownAgent }
```

In `ios/Packages/GymSync/Sources/GymSync/SyncEngine.swift`, replace

```swift
    /// Revokes the OAuth grants this account gave (Claude's connector); returns how many.
    public func revokeOAuthGrants() async throws -> Int {
        try await transport.revokeOAuthGrants()
    }
```

with

```swift
    /// Revokes the OAuth grants this account gave, every agent's (Disconnect all); returns how many.
    public func revokeOAuthGrants() async throws -> Int {
        try await transport.revokeOAuthGrants()
    }

    /// The agents connected to this account, newest connection first (Settings › AI agents).
    public func connectedAgents() async throws -> [ConnectedAgent] {
        try await transport.connectedAgents()
    }

    /// Disconnects one agent; the others keep their access.
    public func disconnectAgent(clientId: String) async throws {
        try await transport.disconnectAgent(clientId: clientId)
    }
```

Run: `(cd ios/Packages/GymSync && swift test --filter GymSyncTests)`
Expected: all passed, seven tests more than after Task A6 (five in `ApiAgentsTransportTests`, two in
`SyncEngineAgentsTests`).

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/GymSync/Sources/GymSync/ConnectedAgents.swift \
  ios/Packages/GymSync/Sources/GymSync/ApiSyncTransport+Agents.swift ios/Packages/GymSync/Sources/GymSync/SyncTransport.swift \
  ios/Packages/GymSync/Sources/GymSync/SyncEngine.swift ios/Packages/GymSync/Tests/GymSyncTests/FakeTransport.swift \
  ios/Packages/GymSync/Tests/GymSyncTests/ApiAgentsTransportTests.swift \
  ios/Packages/GymSync/Tests/GymSyncTests/SyncEngineAgentsTests.swift
git commit -m "feat(ios): list the account's agents and disconnect one"
```

- [ ] **Step 5: Review**

**code-reviewer** against the contract (paths, keys, the 404 code). **security-reviewer**: the client id in the path
(`isClientId`), and that nothing but the stored bearer goes to `/v1/agents` (it is `ApiClient`'s, which refuses
redirects). Then **code-reviewer** for quality.

---

### Task A8: The agents model (app)

**Files:**
- Create: `ios/GymRollins/Features/Claude/AgentsModel.swift`, `ios/GymRollinsTests/AgentsModelTests.swift`
- Modify: `ios/GymRollins/App/SyncCoordinator.swift`, `ios/GymRollins/App/AppEnvironment+Claude.swift`
- Test: `ios/GymRollinsTests/SignOutAndDisconnectTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/GymRollinsTests/AgentsModelTests.swift`:

```swift
import Foundation
import GymSync
import Testing
@testable import GymRollins

/// Connected agents without a server (plan 32): what the list shows, the line in place of rows, and what Disconnect
/// leaves.
@MainActor
@Suite struct AgentsModelTests {
    private static let now = Date(timeIntervalSince1970: 1_790_413_200) // Sat 26 Sep 2026, 09:00 UTC
    private static let muse = ConnectedAgent(clientId: "MuseClientIdAbc", name: "Muse", host: "agent.meta.ai",
                                             knownHost: false, connectedAt: now - 86_400, lastUsedAt: now - 7_200)
    private static let claude = ConnectedAgent(clientId: "ClaudeClientIdXyz", name: "Claude", host: "claude.ai",
                                               knownHost: true, connectedAt: now - 6 * 86_400, lastUsedAt: nil)

    /// A server for one test: the list it answers (or the error it throws), and the agents it was asked to disconnect.
    @MainActor private final class Server {
        var listed: Result<[ConnectedAgent], any Error> = .success([])
        var refusal: (any Error)?
        private(set) var disconnected: [String] = []

        var calls: AgentCalls {
            AgentCalls(list: { [self] in try listed.get() }, disconnect: { [self] id in
                if let refusal { throw refusal }
                disconnected.append(id)
            })
        }
    }

    private func loaded(_ agents: [ConnectedAgent]) async -> (AgentsModel, Server) {
        let server = Server()
        server.listed = .success(agents)
        let model = AgentsModel()
        await model.load(server.calls)
        return (model, server)
    }

    @Test func itSaysItIsCheckingUntilTheFirstAnswer() {
        let model = AgentsModel()
        #expect(model.statusText == "Checking\u{2026}")
        #expect(model.agents.isEmpty && model.error == nil)
    }

    @Test func theAgentsAreTheServersInItsOrder() async {
        let (model, _) = await loaded([Self.muse, Self.claude])
        #expect(model.agents == [Self.muse, Self.claude])
        #expect(model.statusText == nil && model.error == nil)
    }

    @Test func noAgentsSaysSo() async {
        let (model, _) = await loaded([])
        #expect(model.statusText == "No agents connected.")
    }

    @Test func aFirstLoadThatFailsSaysWhy() async {
        let model = AgentsModel()
        let server = Server()
        server.listed = .failure(URLError(.notConnectedToInternet))
        await model.load(server.calls)
        #expect(model.statusText
            == "Couldn't reach GymRollins to list your agents. Check your connection and try again.")
        server.listed = .failure(ApiError(status: 403, code: "forbidden", message: "No."))
        await model.load(server.calls)
        #expect(model.statusText == "Couldn't load your agents. Try again.")
        server.listed = .failure(ApiError(status: 401, code: "signed_out", message: "Sign in."))
        await model.load(server.calls)
        #expect(model.statusText == "Sign in to GymRollins to see your agents.")
        #expect(model.agents.isEmpty)
    }

    @Test func aReloadThatFailsKeepsTheRowsAndSaysWhyBelowThem() async {
        let (model, server) = await loaded([Self.muse])
        server.listed = .failure(URLError(.timedOut))
        await model.load(server.calls)
        #expect(model.agents == [Self.muse] && model.statusText == nil)
        #expect(model.error == "Couldn't reach GymRollins to list your agents. Check your connection and try again.")
        server.listed = .success([Self.muse])
        await model.load(server.calls)
        #expect(model.error == nil)
    }

    @Test func disconnectCutsOnlyThatAgent() async {
        let (model, server) = await loaded([Self.muse, Self.claude])
        await model.disconnect(Self.muse, server.calls)
        #expect(server.disconnected == ["MuseClientIdAbc"])
        #expect(model.agents == [Self.claude])
        #expect(model.error == nil && model.disconnecting == nil)
        await model.disconnect(Self.claude, server.calls)
        #expect(model.statusText == "No agents connected.")
    }

    @Test func anAgentTheServerNoLongerHasGoesToo() async {
        let (model, server) = await loaded([Self.muse, Self.claude])
        server.refusal = AgentError.unknownAgent
        await model.disconnect(Self.muse, server.calls)
        #expect(model.agents == [Self.claude] && model.error == nil)
    }

    @Test func aDisconnectThatFailsKeepsTheAgentAndSaysItStillHasAccess() async {
        let (model, server) = await loaded([Self.muse, Self.claude])
        let offline = "Couldn't reach GymRollins, so Muse still has access. Check your connection and try again."
        let signIn = "Sign in to GymRollins first, with the account Muse uses."
        let cases: [(any Error, String)] = [
            (URLError(.notConnectedToInternet), offline),
            (ApiError(status: 503, code: "http_503", message: "Busy."), offline),
            (ApiError(status: 403, code: "forbidden", message: "No."),
             "Couldn't disconnect Muse, so it still has access. Try again."),
            (ApiError(status: 401, code: "signed_out", message: "Sign in."), signIn),
            (SyncUnavailableError(), signIn),
        ]
        for (refusal, words) in cases {
            server.refusal = refusal
            await model.disconnect(Self.muse, server.calls)
            #expect(model.agents == [Self.muse, Self.claude])
            #expect(model.error == words)
            #expect(model.disconnecting == nil)
        }
        #expect(server.disconnected.isEmpty)
    }

    @Test func theRowsWords() {
        let now = Self.now
        #expect(AgentText.lastUsed(nil, now: now) == "Not used yet")
        #expect(AgentText.lastUsed(now, now: now) == "Last used just now")
        #expect(AgentText.lastUsed(now - 120, now: now) == "Last used 2 min ago")
        #expect(AgentText.lastUsed(now - 3 * 3_600, now: now) == "Last used 3 h ago")
        #expect(AgentText.confirmDisconnect("Muse") == "Disconnect Muse? It loses access until you approve it again.")
        #expect(AgentText.disconnectLabel("Muse") == "Disconnect Muse")
        #expect(AgentText.from("Muse") == "From Muse")
        #expect(AgentText.addedBy("Muse") == "Added by Muse")
        #expect(AgentText.none == "No agents connected.")
    }
}
```

In `ios/GymRollinsTests/SignOutAndDisconnectTests.swift`, replace

```swift
    private(set) var storedProfile: ProfileDTO?
```

with

```swift
    private(set) var storedProfile: ProfileDTO?
    private(set) var agents: [ConnectedAgent] = []
    private(set) var disconnectedAgents: [String] = []
```

replace

```swift
    func set(revokeFails value: Bool) { revokeFails = value }
```

with

```swift
    func set(revokeFails value: Bool) { revokeFails = value }
    func set(agents list: [ConnectedAgent]) { agents = list }
```

replace

```swift
        if revokeFails { throw URLError(.timedOut) }
        revokes += 1
        return 1
    }
}
```

with

```swift
        if revokeFails { throw URLError(.timedOut) }
        revokes += 1
        return 1
    }
    func connectedAgents() async throws -> [ConnectedAgent] {
        try gate()
        return agents
    }
    func disconnectAgent(clientId: String) async throws {
        try gate()
        guard agents.contains(where: { $0.clientId == clientId }) else { throw AgentError.unknownAgent }
        disconnectedAgents.append(clientId)
        agents = agents.filter { $0.clientId != clientId }
    }
}
```

and add at the end of the file:

```swift
/// Plan 32: Settings › AI agents asks the account through the sync coordinator. Without a session there's nothing to
/// list, and nothing to disconnect with.
@MainActor
@Suite struct AgentCallsTests {
    private static let muse = ConnectedAgent(clientId: "MuseClientIdAbc", name: "Muse", host: "agent.meta.ai",
                                             knownHost: false, connectedAt: Date(timeIntervalSince1970: 1_790_326_800),
                                             lastUsedAt: nil)
    private static let claude = ConnectedAgent(clientId: "ClaudeClientIdXyz", name: "Claude", host: "claude.ai",
                                               knownHost: true, connectedAt: Date(timeIntervalSince1970: 1_789_894_800),
                                               lastUsedAt: nil)

    @Test func theListAndDisconnectGoToTheAccount() async throws {
        let transport = SwitchableTransport()
        await transport.set(agents: [Self.muse, Self.claude])
        let env = try await makeEnv(transport)
        let calls = env.agentCalls

        #expect(try await calls.list() == [Self.muse, Self.claude])
        try await calls.disconnect(Self.muse.clientId)
        #expect(await transport.disconnectedAgents == [Self.muse.clientId])
        #expect(try await calls.list() == [Self.claude])
        await #expect(throws: AgentError.unknownAgent) { try await calls.disconnect(Self.muse.clientId) }

        await transport.set(offline: true)
        await #expect(throws: URLError.self) { try await calls.list() }
    }

    @Test func withoutASessionNothingIsListedAndDisconnectNeedsASignIn() async throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentCallsTests.\(UUID())"))
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]), defaults: defaults)
        #expect(try await env.agentCalls.list().isEmpty)
        await #expect(throws: SyncUnavailableError.self) { try await env.agentCalls.disconnect(Self.muse.clientId) }
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run (from the repo root): `cd ios && xcodegen generate && xcodebuild test -project GymRollins.xcodeproj -scheme
GymRollins -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:GymRollinsTests/AgentsModelTests
-only-testing:GymRollinsTests/AgentCallsTests`
Expected: `** TEST FAILED **`, build errors: `cannot find 'AgentCalls' in scope`, `cannot find 'AgentsModel' in scope`,
`cannot find 'AgentText' in scope`, `value of type 'AppEnvironment' has no member 'agentCalls'`.

- [ ] **Step 3: The model, the coordinator's calls, and `agentCalls`**

Create `ios/GymRollins/Features/Claude/AgentsModel.swift`:

```swift
import Foundation
import GymSync
import Observation

/// The calls behind Settings › AI agents' Connected agents (plan 32): the account's through the sync coordinator
/// (`AppEnvironment.agentCalls`), or DEBUG's in-memory list under `-fakeAgents`. Passed in on each call, so the tests
/// run `AgentsModel` without a server.
struct AgentCalls {
    typealias List = @MainActor () async throws -> [ConnectedAgent]
    typealias Disconnect = @MainActor (String) async throws -> Void

    let list: List
    let disconnect: Disconnect
}

/// What Connected agents shows, apart from how it looks (spec section 4): the account's agents as the server lists
/// them, newest connection first; the one line shown while there's no row; and what a Disconnect leaves.
@MainActor @Observable
final class AgentsModel {
    enum Phase: Equatable {
        case loading
        case loaded([ConnectedAgent])
        /// The first load failed, with the words to show.
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    /// The agent whose Disconnect is on its way; its button is disabled meanwhile.
    private(set) var disconnecting: String?
    /// Why the last Disconnect, or a reload of a list already shown, didn't work.
    private(set) var error: String?

    var agents: [ConnectedAgent] {
        if case .loaded(let agents) = phase { return agents }
        return []
    }

    /// The line shown in place of rows (`claude.status`); nil while there are rows.
    var statusText: String? {
        switch phase {
        case .loading: "Checking\u{2026}"
        case .loaded(let agents): agents.isEmpty ? AgentText.none : nil
        case .failed(let message): message
        }
    }

    /// Asks for the list. A failed reload keeps the rows already shown and says why below them.
    func load(_ calls: AgentCalls) async {
        do {
            let listed = try await calls.list()
            if Task.isCancelled { return }
            phase = .loaded(listed)
            error = nil
        } catch {
            if Task.isCancelled { return }
            let message = Self.loadMessage(for: error)
            if case .loaded = phase {
                self.error = message
            } else {
                phase = .failed(message)
            }
        }
    }

    /// Disconnects one agent, after its row's confirmation. Only it goes; one the server no longer has goes too
    /// (decision A6). Any other failure keeps the row and says the agent still has access.
    func disconnect(_ agent: ConnectedAgent, _ calls: AgentCalls) async {
        guard disconnecting == nil else { return }
        disconnecting = agent.clientId
        error = nil
        defer { disconnecting = nil }
        do {
            try await calls.disconnect(agent.clientId)
            phase = .loaded(agents.filter { $0.clientId != agent.clientId })
        } catch AgentError.unknownAgent {
            phase = .loaded(agents.filter { $0.clientId != agent.clientId })
        } catch {
            self.error = Self.disconnectMessage(for: error, name: agent.name)
        }
    }

    static func loadMessage(for error: Error) -> String {
        if let api = error as? ApiError, api.status == 401 { return "Sign in to GymRollins to see your agents." }
        return ApiError.isOffline(error)
            ? "Couldn't reach GymRollins to list your agents. Check your connection and try again."
            : "Couldn't load your agents. Try again."
    }

    static func disconnectMessage(for error: Error, name: String) -> String {
        switch error {
        case is SyncUnavailableError:
            "Sign in to GymRollins first, with the account \(name) uses."
        case let api as ApiError where api.status == 401:
            "Sign in to GymRollins first, with the account \(name) uses."
        default:
            ApiError.isOffline(error)
                ? "Couldn't reach GymRollins, so \(name) still has access. Check your connection and try again."
                : "Couldn't disconnect \(name), so it still has access. Try again."
        }
    }
}

/// The words the agents' screens share (plan 32). Agent names come from the agent: they go into `Text` as plain
/// `String`s, never as Markdown.
enum AgentText {
    static let none = "No agents connected."

    /// "Last used 2 min ago", in Account's sync wording (`SyncStatusText.lastSynced`), or "Not used yet".
    static func lastUsed(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not used yet" }
        let when = SyncStatusText.lastSynced(date, now: now)
        return "Last used " + (when == "Just now" ? "just now" : when)
    }

    static func confirmDisconnect(_ name: String) -> String {
        "Disconnect \(name)? It loses access until you approve it again."
    }

    static func disconnectLabel(_ name: String) -> String { "Disconnect \(name)" }

    static func from(_ name: String) -> String { "From \(name)" }

    static func addedBy(_ name: String) -> String { "Added by \(name)" }
}
```

In `ios/GymRollins/App/SyncCoordinator.swift`, replace

```swift
    /// When Claude last used the MCP server for this account; nil if never, signed out, or unreachable.
    func lastMcpUse() async -> Date? {
        do { return try await engine?.lastMcpUse() } catch {
            Self.log.error("Read Claude's last use failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
```

with

```swift
    /// When an agent last used the MCP server for this account; nil if never, signed out, or unreachable.
    func lastMcpUse() async -> Date? {
        do { return try await engine?.lastMcpUse() } catch {
            Self.log.error("Read Claude's last use failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The agents connected to this account, newest connection first (Settings › AI agents). None while signed out:
    /// there's no session to ask with.
    func connectedAgents() async throws -> [ConnectedAgent] {
        try await engine?.connectedAgents() ?? []
    }

    /// Ends one agent's access; the others keep theirs. Signed out there's no session to do it with.
    func disconnectAgent(clientId: String) async throws {
        guard let engine else { throw SyncUnavailableError() }
        try await engine.disconnectAgent(clientId: clientId)
    }
```

In `ios/GymRollins/App/AppEnvironment+Claude.swift`, replace

```swift
    /// Auto-apply after a sync round's pull. The round may have pulled custom exercises the proposals refer to,
```

with

```swift
    /// Settings › AI agents' calls: the account's agents through the sync coordinator.
    var agentCalls: AgentCalls {
        let sync = sync
        return AgentCalls(list: { try await sync.connectedAgents() },
                          disconnect: { try await sync.disconnectAgent(clientId: $0) })
    }

    /// Auto-apply after a sync round's pull. The round may have pulled custom exercises the proposals refer to,
```

and add `import GymSync` under `import GymData` at the top of `AppEnvironment+Claude.swift` if it isn't there.

Run: the command from Step 2.
Expected: `** TEST SUCCEEDED **`, 11 tests passed (9 in `AgentsModelTests`, 2 in `AgentCallsTests`).

- [ ] **Step 4: Commit**

```bash
git add ios/GymRollins/Features/Claude/AgentsModel.swift ios/GymRollins/App/SyncCoordinator.swift \
  ios/GymRollins/App/AppEnvironment+Claude.swift ios/GymRollinsTests/AgentsModelTests.swift \
  ios/GymRollinsTests/SignOutAndDisconnectTests.swift
git commit -m "feat(ios): the agents model behind Settings › AI agents"
```

- [ ] **Step 5: Review**

**code-reviewer** for decisions A5 and A6. **security-reviewer**: agent names are third-party text; they reach the
screen only through `AgentText` as `String` (no Markdown, no links). Then **code-reviewer** for quality.

---

### Task A9: Hermetic seeds for the UI tests (`-fakeAgents`, `-seedAgentWorkout`)

**Files:**
- Create: `ios/GymRollins/App/DebugAgents.swift`, `ios/GymRollinsTests/DebugAgentsTests.swift`
- Modify: `ios/GymRollins/App/LaunchOptions.swift`, `ios/GymRollins/App/AppEnvironment.swift`,
  `ios/GymRollins/App/AppEnvironment+Claude.swift`, `ios/GymRollins/App/DebugProposalSeed.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/GymRollinsTests/DebugAgentsTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import GymSync
import Testing
@testable import GymRollins

/// The DEBUG seeds the hermetic UI tests use for plan 32.
@MainActor
@Suite struct DebugAgentsTests {
    private func makeEnv(_ arguments: [String]) throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: "DebugAgentsTests.\(UUID())"))
        return try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"] + arguments), defaults: defaults)
    }

    @Test func theLaunchFlagsAreRead() {
        let options = LaunchOptions(arguments: ["-uiTesting", "-fakeAgents", "-seedAgentWorkout"])
        #expect(options.fakeAgents && options.seedAgentWorkout)
        let plain = LaunchOptions(arguments: ["-uiTesting"])
        #expect(!plain.fakeAgents && !plain.seedAgentWorkout)
    }

    @Test func fakeAgentsAreMuseThenClaudeAndDisconnectRemovesOneForTheLaunch() async throws {
        let env = try makeEnv(["-fakeAgents"])
        let listed = try await env.agentCalls.list()
        #expect(listed.map(\.name) == ["Muse", "Claude"])
        #expect(listed.map(\.clientId) == [DebugAgents.museId, DebugAgents.claudeId])
        #expect(listed.map(\.host) == ["agent.meta.ai", "claude.ai"])
        #expect(AgentText.lastUsed(listed[0].lastUsedAt, now: env.now()) == "Last used 2 h ago")
        #expect(listed[1].lastUsedAt == nil)

        try await env.agentCalls.disconnect(DebugAgents.museId)
        #expect(try await env.agentCalls.list().map(\.name) == ["Claude"]) // the same list, asked again
        await #expect(throws: AgentError.unknownAgent) { try await env.agentCalls.disconnect(DebugAgents.museId) }
    }

    @Test func withoutTheFlagTheAccountIsAsked() async throws {
        let env = try makeEnv([])
        #expect(try await env.agentCalls.list().isEmpty) // hermetic: no session, so nothing listed
    }

    @Test func theSeededWorkoutWasAddedByMuseAndStoredAsAPull() throws {
        let env = try makeEnv(["-seedAgentWorkout"])
        let workout = try #require(try env.workouts.workout(DebugAgents.workoutId))
        #expect(workout.name == "Upper" && workout.source == .import)
        #expect(workout.entries.first?.sets.map(\.reps) == [8, 8, 7])
        #expect(try env.workouts.addedBy(DebugAgents.workoutId) == "Muse")
        #expect(try env.syncStore.dirtyWorkouts().isEmpty)
    }

    @Test func theSeededProposalIsFromClaude() throws {
        let env = try makeEnv(["-seedProposal"])
        #expect(try env.proposals.proposal(DebugProposalSeed.id)?.fromAgent == "Claude")
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run (from the repo root): `cd ios && xcodegen generate && xcodebuild test -project GymRollins.xcodeproj -scheme
GymRollins -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:GymRollinsTests/DebugAgentsTests`
Expected: `** TEST FAILED **`, build errors: `value of type 'LaunchOptions' has no member 'fakeAgents'`, `cannot find
'DebugAgents' in scope`.

- [ ] **Step 3: The flags, the fake, and the seeds**

In `ios/GymRollins/App/LaunchOptions.swift`, replace

```swift
    let fakeGymCatalogGrows: Bool
```

with

```swift
    let fakeGymCatalogGrows: Bool
    /// DEBUG/UI-test only (`-fakeAgents`): Settings › AI agents lists Muse and Claude from memory (`DebugAgents`), and
    /// Disconnect removes one; nothing is sent.
    let fakeAgents: Bool
    /// DEBUG/UI-test only (`-seedAgentWorkout`): a past workout Muse added, stored as a pull stores it (`DebugAgents`).
    let seedAgentWorkout: Bool
```

replace

```swift
        fakeGymCatalogGrows = arguments.contains("-fakeGymCatalogGrows")
```

with

```swift
        fakeGymCatalogGrows = arguments.contains("-fakeGymCatalogGrows")
        fakeAgents = arguments.contains("-fakeAgents")
        seedAgentWorkout = arguments.contains("-seedAgentWorkout")
```

and replace

```swift
        fakeGymCatalogGrows = false
```

with

```swift
        fakeGymCatalogGrows = false
        fakeAgents = false
        seedAgentWorkout = false
```

Create `ios/GymRollins/App/DebugAgents.swift`:

```swift
#if DEBUG
import Foundation
import GymCore
import GymData
import GymSync

/// DEBUG/UI-test only, for Settings › AI agents and the workout screen without a server (plan 32).
/// - `-fakeAgents`: the Connected agents list is this in-memory one, made once per launch: Muse (agent.meta.ai,
///   connected a day ago, last used 2 h ago) above Claude (claude.ai, connected 6 days ago, never used). Disconnect
///   removes one for the rest of the launch. Disconnect all goes to the account as usual, so it leaves this list alone.
///   Nothing leaves the phone.
/// - `-seedAgentWorkout`: a past workout Muse added, stored as a pull stores it (clean, with `addedBy`).
@MainActor
final class DebugAgents {
    static let museId = "MuseFakeClientId"
    static let claudeId = "ClaudeFakeClientId"
    static let workoutId = UUID(uuidString: "AD0ED000-0000-4000-8000-000000000001")!
    private static let hour: TimeInterval = 3_600
    private static let day: TimeInterval = 86_400

    private var agents: [ConnectedAgent]

    init(now: Date) {
        agents = [
            ConnectedAgent(clientId: Self.museId, name: "Muse", host: "agent.meta.ai", knownHost: false,
                           connectedAt: now - Self.day, lastUsedAt: now - 2 * Self.hour),
            ConnectedAgent(clientId: Self.claudeId, name: "Claude", host: "claude.ai", knownHost: true,
                           connectedAt: now - 6 * Self.day, lastUsedAt: nil),
        ]
    }

    /// The calls Settings › AI agents makes. They hold this list, so it lives as long as the launch's environment.
    var calls: AgentCalls {
        AgentCalls(list: { [self] in agents }, disconnect: { [self] clientId in try remove(clientId) })
    }

    private func remove(_ clientId: String) throws {
        guard agents.contains(where: { $0.clientId == clientId }) else { throw AgentError.unknownAgent }
        agents = agents.filter { $0.clientId != clientId }
    }

    /// `-seedAgentWorkout`: "Upper", four days before `now` (Tuesday 22 Sep under the UI tests' fixed now), bench press
    /// 8, 8 and 7 at 63.5 kg, as Muse's `log_workout` lands after a pull.
    static func seedWorkout(into store: SyncStore, now: Date) throws {
        let start = now - 4 * day
        let sets = [8, 8, 7].map { WorkoutSet(weightKg: 63.5, reps: $0, done: true, completedAt: start) }
        let workout = Workout(id: workoutId, startedAt: start, endedAt: start + 63 * 60, name: "Upper",
                              entries: [WorkoutEntry(exerciseId: "0025", sets: sets)], source: .import)
        let snapshot = WorkoutSnapshot(workout: workout, records: [], volumeKg: WorkoutMetrics.volumeKg(workout),
                                       addedBy: "Muse")
        try store.applyRemote(workouts: [SyncRow(value: snapshot, clientUpdatedAt: now, serverUpdatedAt: now)])
    }
}
#endif
```

In `ios/GymRollins/App/AppEnvironment.swift`, replace

```swift
    /// `<API_URL>/mcp`, nil when this build has no API.
    let connectorURL: String?
```

with

```swift
    /// `<API_URL>/mcp`, nil when this build has no API.
    let connectorURL: String?
    /// DEBUG's in-memory agents under `-fakeAgents` (`DebugAgents`), one list for the launch; nil otherwise.
    let fakeAgentCalls: AgentCalls?
```

replace

```swift
        if options.seedTodayProposal { try DebugProposalSeed.applyToday(context: context, now: now()) }
```

with

```swift
        if options.seedTodayProposal { try DebugProposalSeed.applyToday(context: context, now: now()) }
        if options.seedAgentWorkout { try DebugAgents.seedWorkout(into: syncStore, now: now()) }
```

and replace

```swift
        self.connectorURL = SyncCoordinator.connectorURL(options: options)
```

with

```swift
        self.connectorURL = SyncCoordinator.connectorURL(options: options)
        #if DEBUG
        self.fakeAgentCalls = options.fakeAgents ? DebugAgents(now: now()).calls : nil
        #else
        self.fakeAgentCalls = nil
        #endif
```

In `ios/GymRollins/App/AppEnvironment+Claude.swift`, replace

```swift
    /// Settings › AI agents' calls: the account's agents through the sync coordinator.
    var agentCalls: AgentCalls {
        let sync = sync
```

with

```swift
    /// Settings › AI agents' calls: the account's agents through the sync coordinator, or DEBUG's in-memory list under
    /// `-fakeAgents`.
    var agentCalls: AgentCalls {
        if let fakeAgentCalls { return fakeAgentCalls }
        let sync = sync
```

In `ios/GymRollins/App/DebugProposalSeed.swift`, replace

```swift
/// DEBUG-only (`-seedProposal`): a pending proposal shaped like the shared fixture's "valid knee-break proposal",
```

with

```swift
/// DEBUG-only (`-seedProposal`): a pending proposal from Claude, shaped like the shared fixture's "valid knee-break proposal",
```

and replace

```swift
            PlanChange(id: "c4", type: .removeExercise, routineId: legs, exerciseId: "0585", reason: "Knee"),
        ])
```

with

```swift
            PlanChange(id: "c4", type: .removeExercise, routineId: legs, exerciseId: "0585", reason: "Knee"),
        ], fromAgent: "Claude")
```

Run: the command from Step 2.
Expected: `** TEST SUCCEEDED **`, 5 tests passed.

- [ ] **Step 4: Commit**

```bash
git add ios/GymRollins/App/DebugAgents.swift ios/GymRollins/App/LaunchOptions.swift ios/GymRollins/App/AppEnvironment.swift \
  ios/GymRollins/App/AppEnvironment+Claude.swift ios/GymRollins/App/DebugProposalSeed.swift \
  ios/GymRollinsTests/DebugAgentsTests.swift
git commit -m "test(ios): DEBUG seeds for connected agents and an agent's workout"
```

- [ ] **Step 5: Review**

**code-reviewer**: the fake exists only in DEBUG (`git grep -n "DebugAgents" -- ios/GymRollins` shows no use outside
`#if DEBUG`), decision A10. Then for quality.

---

### Task A10: Settings › AI agents

The screen per spec section 4, top to bottom: Connected agents, Connect, Plan changes from your agents, What agents
can do (with Add workouts), Use with Claude, Disconnect all. The Settings row says "AI agents".

**Files:**
- Create: `ios/GymRollins/Features/Claude/ConnectedAgentsSection.swift`, `ios/GymRollinsUITests/AgentsUITests.swift`
- Modify: `ios/GymRollins/Features/Claude/ClaudeConnectionView.swift` (whole file), `ios/GymRollins/App/AppEnvironment+Claude.swift`,
  `ios/GymRollins/Features/Settings/SettingsView.swift`, `ios/GymRollins/Features/Claude/ConnectorInstructions.swift`,
  `ios/GymRollins/Features/Settings/PrivacyPolicyView.swift`
- Test: `ios/GymRollinsUITests/ProposalUITests.swift`

- [ ] **Step 1: Write the failing UI tests**

Create `ios/GymRollinsUITests/AgentsUITests.swift`:

```swift
import XCTest

/// Settings › AI agents, hermetic (plan 32). `-fakeAgents` lists Muse (agent.meta.ai, last used 2 h before the fixed
/// now) above Claude (claude.ai, never used) from memory; `-seedProposal` adds a pending proposal from Claude, and
/// `-seedAgentWorkout` a workout Muse added on Tuesday 22 Sep.
@MainActor
final class AgentsUITests: XCTestCase {
    private var app: XCUIApplication!
    private let muse = "MuseFakeClientId"
    private let claude = "ClaudeFakeClientId"

    override func setUp() { continueAfterFailure = false }

    private func openAgents(_ extra: [String]) {
        app = XCUIApplication.launchReady(extra)
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.claude"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        scrollTo(row)
        XCTAssertTrue(row.label.contains("AI agents"), row.label)
        row.tap()
        XCTAssertTrue(app.navigationBars["AI agents"].waitForExistence(timeout: 5))
    }

    private func scrollTo(_ element: XCUIElement, maxSwipes: Int = 12) {
        for _ in 0..<maxSwipes where !element.isHittable { app.swipeUp() }
    }

    /// A label, whatever case the Form shows it in.
    private func text(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
    }

    /// Flips a SwiftUI `Toggle` (the inner switch when there is one, else the right edge where the knob is).
    private func flip(_ toggle: XCUIElement) {
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let before = toggle.value as? String
        let inner = toggle.switches.firstMatch
        if inner.exists { inner.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let changed = NSPredicate(format: "value != %@", before ?? "")
        wait(for: [expectation(for: changed, evaluatedWith: toggle)], timeout: 3)
    }

    func testTheAgentsAreListedWithTheirHostAndLastUse() {
        openAgents(["-fakeAgents"])
        let museName = app.staticTexts["agents.name.\(muse)"]
        XCTAssertTrue(museName.waitForExistence(timeout: 5))
        XCTAssertEqual(museName.label, "Muse")
        XCTAssertEqual(app.staticTexts["agents.host.\(muse)"].label, "agent.meta.ai")
        XCTAssertEqual(app.staticTexts["agents.lastUsed.\(muse)"].label, "Last used 2 h ago")
        let claudeName = app.staticTexts["agents.name.\(claude)"]
        XCTAssertEqual(claudeName.label, "Claude")
        XCTAssertEqual(app.staticTexts["agents.host.\(claude)"].label, "claude.ai")
        XCTAssertEqual(app.staticTexts["agents.lastUsed.\(claude)"].label, "Not used yet")
        XCTAssertLessThan(museName.frame.minY, claudeName.frame.minY) // newest connection first
        XCTAssertFalse(app.staticTexts["claude.status"].exists) // the rows replace the status line
    }

    func testDisconnectAsksFirstThenCutsOnlyThatAgent() {
        openAgents(["-fakeAgents"])
        let disconnect = app.buttons["agents.disconnect.\(muse)"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        XCTAssertEqual(disconnect.label, "Disconnect Muse")
        disconnect.tap()
        XCTAssertTrue(app.staticTexts["Disconnect Muse? It loses access until you approve it again."]
            .waitForExistence(timeout: 5))
        app.buttons["agents.disconnect.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["agents.name.\(muse)"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["agents.name.\(claude)"].exists)

        app.buttons["agents.disconnect.\(claude)"].tap()
        app.buttons["agents.disconnect.confirm"].firstMatch.tap()
        let status = app.staticTexts["claude.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "No agents connected.")
    }

    func testAddWorkoutsIsOffUntilTurnedOnAndStaysOn() {
        openAgents([])
        let add = app.switches["agents.perm.logWorkouts"]
        scrollTo(add)
        XCTAssertTrue(add.isHittable)
        XCTAssertEqual(add.value as? String, "0")
        XCTAssertTrue(add.label.contains("Add workouts"), add.label)
        XCTAssertTrue(add.label.contains("Let agents add past workouts to your history"), add.label)
        flip(add)
        XCTAssertEqual(add.value as? String, "1")

        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["settings.claude"].tap()
        XCTAssertTrue(app.navigationBars["AI agents"].waitForExistence(timeout: 5))
        scrollTo(add)
        XCTAssertEqual(add.value as? String, "1")
    }

    func testTheSectionsAreWordedForAnyAgent() {
        openAgents(["-seedProposal"])
        XCTAssertTrue(text("Connected agents").waitForExistence(timeout: 5))
        let status = app.staticTexts["claude.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let none = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "No agents connected."),
                                             object: status)
        XCTAssertEqual(XCTWaiter().wait(for: [none], timeout: 5), .completed, status.label)
        XCTAssertTrue(text("Connect").exists)

        let proposals = text("Plan changes from your agents")
        scrollTo(proposals)
        XCTAssertTrue(proposals.exists)
        XCTAssertFalse(text("Plan changes from Claude").exists)

        let permissions = text("What agents can do")
        scrollTo(permissions)
        XCTAssertTrue(permissions.exists)
        XCTAssertFalse(text("What Claude can do").exists)
        let gymsNote = app.staticTexts["claude.gymsNote"]
        scrollTo(gymsNote)
        XCTAssertTrue(gymsNote.label.hasPrefix("Agents can read gyms"), gymsNote.label)

        let useWithClaude = text("Use with Claude")
        scrollTo(useWithClaude)
        XCTAssertTrue(useWithClaude.exists)

        let disconnectAll = app.buttons["claude.disconnect"]
        scrollTo(disconnectAll)
        XCTAssertEqual(disconnectAll.label, "Disconnect all")
        disconnectAll.tap()
        XCTAssertTrue(app.staticTexts["Disconnect every agent?"].waitForExistence(timeout: 5))
        app.buttons["claude.disconnect.confirm"].firstMatch.tap()
        let revoked = app.staticTexts["claude.disconnected"]
        XCTAssertTrue(revoked.waitForExistence(timeout: 5))
        XCTAssertTrue(revoked.label.hasPrefix("Every agent's access was revoked"), revoked.label)
    }
}
```

In `ios/GymRollinsUITests/ProposalUITests.swift`, replace

```swift
        scrollTo(autoApply) // the Use with Claude section pushes it below the fold
```

with

```swift
        scrollTo(autoApply) // the agents and Connect sections push it below the fold
```

replace

```swift
        XCTAssertEqual(app.staticTexts["claude.status"].label, "Not connected yet")
```

with

```swift
        let status = app.staticTexts["claude.status"]
        let none = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "No agents connected."),
                                             object: status)
        XCTAssertEqual(XCTWaiter().wait(for: [none], timeout: 5), .completed, status.label)
```

replace

```swift
        let disconnect = app.buttons["claude.disconnect"]
        scrollTo(disconnect)
        disconnect.tap()
        app.buttons["claude.disconnect.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["claude.disconnected"].waitForExistence(timeout: 5))
        for id in ["readWorkouts", "readBody", "readPlan", "readGyms", "propose", "autoApply"] {
            let toggle = app.switches["claude.perm.\(id)"]
            scrollTo(toggle)
            XCTAssertEqual(toggle.value as? String, "0", id)
        }
    }
```

with

```swift
        let disconnect = app.buttons["claude.disconnect"]
        scrollTo(disconnect)
        XCTAssertEqual(disconnect.label, "Disconnect all")
        disconnect.tap()
        app.buttons["claude.disconnect.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["claude.disconnected"].waitForExistence(timeout: 5))
        // The switches sit above Use with Claude now: from the bottom, back up through them (decision A3).
        let switches = ["claude.perm.autoApply", "claude.perm.propose", "agents.perm.logWorkouts", "claude.perm.readGyms",
                        "claude.perm.readPlan", "claude.perm.readBody", "claude.perm.readWorkouts"]
        for id in switches {
            let toggle = app.switches[id]
            scrollBack(to: toggle)
            XCTAssertTrue(toggle.isHittable, id)
            XCTAssertEqual(toggle.value as? String, "0", id)
        }
    }

    /// Like `scrollTo`, for an element above the screen.
    private func scrollBack(to element: XCUIElement, maxSwipes: Int = 12) {
        var swipes = 0
        while !element.isHittable && swipes < maxSwipes {
            app.swipeDown()
            swipes += 1
        }
    }
```

- [ ] **Step 2: Run them to see them fail**

Run (from the repo root): `cd ios && xcodegen generate && xcodebuild test -project GymRollins.xcodeproj -scheme
GymRollins -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:GymRollinsUITests/AgentsUITests
-only-testing:GymRollinsUITests/ProposalUITests/testClaudeScreenShowsConnectorPendingAndDisconnect`
Expected: `** TEST FAILED **`: every `AgentsUITests` test fails at `row.label.contains("AI agents")` ("Claude connection,
Not connected"), and `testClaudeScreenShowsConnectorPendingAndDisconnect` fails waiting for "No agents connected."
(the label is "Not connected yet").

- [ ] **Step 3: The Connected agents section**

Create `ios/GymRollins/Features/Claude/ConnectedAgentsSection.swift`:

```swift
import GymSync
import SwiftUI

/// Settings › AI agents, first section (plan 32): one row per agent connected to the account, newest connection
/// first, each with Disconnect, which asks first. While there's no row, one line says why: checking, none connected,
/// or couldn't load (`claude.status`, where "Last used" was before plan 32).
struct ConnectedAgentsSection: View {
    let model: AgentsModel
    let now: Date
    let onDisconnect: (ConnectedAgent) -> Void

    var body: some View {
        Section {
            if let status = model.statusText {
                Text(status).foregroundStyle(Theme.textSecondary).accessibilityIdentifier("claude.status")
            }
            ForEach(model.agents) { agent in
                AgentRow(agent: agent, now: now, busy: model.disconnecting == agent.clientId) { onDisconnect(agent) }
            }
            if let error = model.error {
                Text(error).font(.footnote).foregroundStyle(Theme.destructive).accessibilityIdentifier("agents.error")
            }
        } header: {
            Text("Connected agents")
        } footer: {
            Text("Agents you approve can read your training and suggest plan changes you review here, within what "
                 + "agents can do below.")
                .accessibilityIdentifier("claude.view")
        }
    }
}

/// One agent: its name, the host its sign-in returns to, when it last used GymRollins, and Disconnect. Disconnect is
/// a borderless button of its own, so tapping the row's text does nothing (a Form row fires every button it holds).
private struct AgentRow: View {
    let agent: ConnectedAgent
    let now: Date
    let busy: Bool
    let onDisconnect: () -> Void
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(agent.name).font(.body.weight(.semibold)).lineLimit(2)
                .accessibilityIdentifier("agents.name.\(agent.clientId)")
            Text(agent.host).font(.footnote).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("agents.host.\(agent.clientId)")
            Text(AgentText.lastUsed(agent.lastUsedAt, now: now)).font(.footnote).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("agents.lastUsed.\(agent.clientId)")
            Button("Disconnect", role: .destructive) { confirming = true }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .disabled(busy)
                .accessibilityLabel(AgentText.disconnectLabel(agent.name))
                .accessibilityIdentifier("agents.disconnect.\(agent.clientId)")
        }
        .confirmationDialog(AgentText.confirmDisconnect(agent.name), isPresented: $confirming,
                            titleVisibility: .visible) {
            Button("Disconnect", role: .destructive, action: onDisconnect)
                .accessibilityIdentifier("agents.disconnect.confirm")
        }
    }
}
```

- [ ] **Step 4: The screen**

Replace the whole of `ios/GymRollins/Features/Claude/ClaudeConnectionView.swift` with:

```swift
import GymData
import GymSync
import SwiftUI

/// Settings › AI agents (plan 32; the screen was "Claude" before), top to bottom: the agents connected to the
/// account, each with Disconnect; Connect (the MCP connector URL and Approve a connection); plan changes the agents
/// proposed; what agents may do (synced profile flags, one set for every agent, enforced by the server); the prompt to
/// use with Claude; and Disconnect all. The type and its `claude.*` identifiers keep their names, so the tests stay
/// put; elements new in plan 32 use `agents.*`.
struct ClaudeConnectionView: View {
    struct Permissions: Equatable {
        var readWorkouts = true
        var readBody = true
        var readPlan = true
        var readGyms = true
        var propose = true
        var autoApply = false
        var logWorkouts = false

        static let none = Permissions(readWorkouts: false, readBody: false, readPlan: false, readGyms: false,
                                      propose: false, autoApply: false, logWorkouts: false)
    }

    @Environment(AppEnvironment.self) private var env
    @State private var permissions = Permissions()
    @State private var loaded = false
    @State private var agents = AgentsModel()
    @State private var pending: [Proposal] = []
    @State private var recent: [Proposal] = []
    @State private var copied = false
    @State private var approving = false
    @State private var confirmDisconnect = false
    @State private var disconnected = false
    @State private var error: String?

    var body: some View {
        Form {
            ConnectedAgentsSection(model: agents, now: env.now()) { agent in
                Task { await agents.disconnect(agent, env.agentCalls) }
            }
            connectSection
            if !pending.isEmpty || !undoable.isEmpty { proposalsSection }
            permissionsSection
            UseWithClaudeSection()
            disconnectSection
            if let error {
                Section { Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("claude.error") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("AI agents")
        .task(id: env.planRevision) { reload() }
        .task { await loadAgents() }
        .refreshable { await loadAgents() }
        .onChange(of: permissions) { _, new in save(new) }
        .confirmationDialog("Disconnect every agent?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect all", role: .destructive) { Task { await disconnect() } }
                .accessibilityIdentifier("claude.disconnect.confirm")
        } message: {
            Text("Each one loses access until you approve it again, and everything agents can do is turned off.")
        }
        .sheet(isPresented: $approving, onDismiss: { Task { await loadAgents() } }) { approveSheet }
    }

    // MARK: Sections

    private var connectSection: some View {
        Section("Connect") {
            ConnectorInstructions(connectorURL: env.connectorURL, copied: $copied)
            Button("Approve a connection") { approving = true }
                .accessibilityIdentifier("claude.approveConnection")
        }
    }

    /// A fresh model each time the sheet opens, asking through the account's sync coordinator.
    private var approveSheet: some View {
        NavigationStack {
            ApproveConnectionView(model: ApproveConnectionModel(
                lookUp: { [sync = env.sync] code in try await sync.connectRequest(code: code) },
                decide: { [sync = env.sync] code, decision in
                    try await sync.decideConnect(code: code, decision: decision)
                }
            ))
        }
    }

    private var undoable: [Proposal] { recent.filter { $0.canUndo(at: env.now()) } }

    private var proposalsSection: some View {
        Section("Plan changes from your agents") {
            ForEach(pending) { p in
                NavigationLink { ProposalReviewView(proposalId: p.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.summary).lineLimit(2)
                        Text(p.createdAt.formatted(.dateTime.day().month(.abbreviated)) + " \u{00B7} Review")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .accessibilityIdentifier("claude.proposal.\(p.id.uuidString)")
            }
            ForEach(undoable) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.summary).lineLimit(2)
                        Text(p.autoApplied ? "Applied automatically" : "Applied").font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Undo") { undo(p.id) }.buttonStyle(.glass)
                        .accessibilityIdentifier("claude.undo.\(p.id.uuidString)")
                }
            }
        }
    }

    private var permissionsSection: some View {
        Section {
            Toggle("Read workouts and sets", isOn: $permissions.readWorkouts)
                .accessibilityIdentifier("claude.perm.readWorkouts")
            Toggle("Read bodyweight", isOn: $permissions.readBody).accessibilityIdentifier("claude.perm.readBody")
            Toggle("Read your plan and profile", isOn: $permissions.readPlan)
                .accessibilityIdentifier("claude.perm.readPlan")
            Toggle("Gyms", isOn: $permissions.readGyms).accessibilityIdentifier("claude.perm.readGyms")
            Toggle(isOn: $permissions.logWorkouts) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add workouts")
                    Text("Let agents add past workouts to your history")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            .accessibilityIdentifier("agents.perm.logWorkouts")
            Toggle("Propose plan changes", isOn: $permissions.propose).accessibilityIdentifier("claude.perm.propose")
            Toggle("Apply changes without asking", isOn: $permissions.autoApply)
                .accessibilityIdentifier("claude.perm.autoApply")
        } header: {
            Text("What agents can do")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Agents can read gyms you've synced or shared. \"This phone only\" gyms stay on your phone, so "
                     + "agents can't see them.")
                    .accessibilityIdentifier("claude.gymsNote")
                Text("A workout an agent adds goes straight into your history, marked with the agent's name. You can "
                     + "edit or delete it like any other.")
                    .accessibilityIdentifier("agents.logWorkoutsNote")
                Text("Applied changes can be undone for 7 days.")
            }
        }
        .tint(Theme.primaryFill)
    }

    private var disconnectSection: some View {
        Section {
            Button("Disconnect all", role: .destructive) { confirmDisconnect = true }
                .accessibilityIdentifier("claude.disconnect")
            if disconnected {
                Text("Every agent's access was revoked: none can read your data, propose changes or add workouts. "
                     + "To remove the connector from an agent too, remove GymRollins from its connectors (in Claude: "
                     + "Settings \u{2192} Connectors).")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("claude.disconnected")
            }
        }
    }

    // MARK: Actions

    private func reload() {
        let fromProfile = Self.permissions(env.profile)
        if !loaded || fromProfile != permissions {
            permissions = fromProfile
            loaded = true
        }
        pending = env.pendingProposals()
        do { recent = try env.proposals.recent(limit: 10) } catch {
            AppEnvironment.log.error("Load recent proposals failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadAgents() async {
        await agents.load(env.agentCalls)
    }

    private static func permissions(_ p: Profile) -> Permissions {
        Permissions(readWorkouts: p.mcpReadWorkouts, readBody: p.mcpReadBody, readPlan: p.mcpReadPlan,
                    readGyms: p.mcpReadGyms, propose: p.mcpPropose, autoApply: p.mcpAutoApply,
                    logWorkouts: p.mcpLogWorkouts)
    }

    private func save(_ new: Permissions) {
        guard loaded, new != Self.permissions(env.profile) else { return }
        do {
            try env.saveMcpPermissions(readWorkouts: new.readWorkouts, readBody: new.readBody, readPlan: new.readPlan,
                                       readGyms: new.readGyms, propose: new.propose, autoApply: new.autoApply,
                                       logWorkouts: new.logWorkouts)
            error = nil
        } catch {
            AppEnvironment.log.error("Save agent permissions failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save what agents can do. Please try again."
        }
    }

    /// Every flag off and pushed to the account, then every agent's grant revoked; "revoked" shows only when both
    /// worked. The list is asked again either way.
    private func disconnect() async {
        do {
            try await env.disconnectClaude()
            error = nil
            disconnected = true
        } catch {
            AppEnvironment.log.error("Disconnect all failed: \(error.localizedDescription, privacy: .public)")
            self.error = (error as? ClaudeDisconnectError ?? .permissionsNotSaved).message
            disconnected = false
        }
        permissions = Self.permissions(env.profile)
        await loadAgents()
    }

    private func undo(_ id: UUID) {
        do {
            if try !env.undoProposal(id) { error = "This change can no longer be undone." }
        } catch {
            AppEnvironment.log.error("Undo proposal failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't undo. Your plan wasn't changed."
        }
    }
}
```

- [ ] **Step 5: The words around it**

In `ios/GymRollins/App/AppEnvironment+Claude.swift`, replace

```swift
/// Which step of "Disconnect Claude" failed (the permissions are off on this iPhone either way).
enum ClaudeDisconnectError: Error, Equatable {
    /// The server didn't store the permissions-off profile (offline, refused, or kept a newer edit).
    case permissionsNotSaved
    /// The permissions are off in the account, but the OAuth grant couldn't be revoked.
    case accessNotRevoked

    var message: String {
        switch self {
        case .permissionsNotSaved:
            "Claude's permissions are off on this iPhone but couldn't be saved to your account, so Claude may still "
                + "have access. Check your connection and tap Disconnect Claude again."
        case .accessNotRevoked:
            "Claude's permissions are off, but its access couldn't be revoked. Check your connection and tap "
                + "Disconnect Claude again."
        }
    }
}
```

with

```swift
/// Which step of "Disconnect all" failed (what agents can do is off on this iPhone either way).
enum ClaudeDisconnectError: Error, Equatable {
    /// The server didn't store the permissions-off profile (offline, refused, or kept a newer edit).
    case permissionsNotSaved
    /// The permissions are off in the account, but the OAuth grants couldn't be revoked.
    case accessNotRevoked

    var message: String {
        switch self {
        case .permissionsNotSaved:
            "What agents can do is off on this iPhone but couldn't be saved to your account, so agents may still have "
                + "access. Check your connection and tap Disconnect all again."
        case .accessNotRevoked:
            "What agents can do is off, but their access couldn't be revoked. Check your connection and tap "
                + "Disconnect all again."
        }
    }
}
```

In `ios/GymRollins/Features/Settings/SettingsView.swift`, replace

```swift
    // MARK: Claude

    private var claudeSection: some View {
        Section("Claude") {
            NavigationLink { ClaudeConnectionView() } label: {
                HStack {
                    Text("Claude connection")
```

with

```swift
    // MARK: AI agents

    private var claudeSection: some View {
        Section("AI agents") {
            NavigationLink { ClaudeConnectionView() } label: {
                HStack {
                    Text("AI agents")
```

In `ios/GymRollins/Features/Claude/ConnectorInstructions.swift`, replace

```swift
        step(3, "When Claude shows a code, open Settings \u{203A} Claude \u{203A} Approve a connection and type it")
```

with

```swift
        step(3, "When Claude shows a code, open Settings \u{203A} AI agents \u{203A} Approve a connection and type it")
```

In `ios/GymRollins/Features/Settings/PrivacyPolicyView.swift`, replace

```swift
        "Claude can only read what you allow in the Claude section of Settings, and only proposes plan changes "
            + "you review (or explicitly allow it to apply automatically).",
```

with

```swift
        "Agents you connect, such as Claude, can only read what you allow in Settings \u{203A} AI agents. They "
            + "propose plan changes you review (or explicitly allow to apply automatically), and add past workouts "
            + "only if you turn on Add workouts.",
```

and replace the type's doc comment

```swift
/// Plain-language privacy summary: what's stored, what Claude can see, and what GymRollins never does.
```

with

```swift
/// Plain-language privacy summary: what's stored, what agents can see and do, and what GymRollins never does.
```

- [ ] **Step 6: Run the screen's UI tests**

Run (from the repo root): `cd ios && xcodegen generate && xcodebuild test -project GymRollins.xcodeproj -scheme
GymRollins -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:GymRollinsUITests/AgentsUITests
-only-testing:GymRollinsUITests/ProposalUITests -only-testing:GymRollinsUITests/ClaudePromptsUITests
-only-testing:GymRollinsUITests/SettingsUITests/testClaudeBadgeDefaultsToNotConnected
-only-testing:GymRollinsUITests/EmptyStatesUITests/testTodayEmptyPlanStateOffersAskClaude`
Expected: `** TEST SUCCEEDED **`: the 4 `AgentsUITests`, the 5 `ProposalUITests`, `ClaudePromptsUITests`, and the two
single tests.

Then the app unit tests that touch the screen's code paths:
`... -only-testing:GymRollinsTests/ClaudeEnvironmentTests -only-testing:GymRollinsTests/ClaudeDisconnectTests
-only-testing:GymRollinsTests/AgentsModelTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add ios/GymRollins/Features/Claude/ConnectedAgentsSection.swift ios/GymRollins/Features/Claude/ClaudeConnectionView.swift \
  ios/GymRollins/App/AppEnvironment+Claude.swift ios/GymRollins/Features/Settings/SettingsView.swift \
  ios/GymRollins/Features/Claude/ConnectorInstructions.swift ios/GymRollins/Features/Settings/PrivacyPolicyView.swift \
  ios/GymRollinsUITests/AgentsUITests.swift ios/GymRollinsUITests/ProposalUITests.swift
git commit -m "feat(ios): Settings › AI agents lists each agent, with Add workouts and Disconnect all"
```

- [ ] **Step 8: Review**

**code-reviewer** against spec section 4 (the six sections in order, every quoted text) and decisions A1, A3, A4, A7,
A9. Then the same agent for quality (Swift, SwiftUI).

---

### Task A11: "From Muse" on proposals

**Files:**
- Modify: `ios/GymRollins/Features/Claude/ClaudeConnectionView.swift`, `ios/GymRollins/Features/Claude/ProposalReviewView.swift`,
  `ios/GymRollins/Features/Claude/AgentsModel.swift`
- Test: `ios/GymRollinsTests/AgentsModelTests.swift`, `ios/GymRollinsUITests/AgentsUITests.swift`

- [ ] **Step 1: Write the failing tests**

In `ios/GymRollinsTests/AgentsModelTests.swift`, add inside `AgentsModelTests`:

```swift
    /// A proposal row's second line: the parts joined with " · ", leaving out a sender the server didn't know.
    @Test func aProposalsCaptionNamesItsSenderWhenKnown() {
        #expect(AgentText.caption(["25 Sep", AgentText.from("Muse"), "Review"]) == "25 Sep \u{00B7} From Muse \u{00B7} Review")
        #expect(AgentText.caption(["25 Sep", nil, "Review"]) == "25 Sep \u{00B7} Review")
        #expect(AgentText.caption(["Applied", nil]) == "Applied")
    }
```

In `ios/GymRollinsUITests/AgentsUITests.swift`, add inside `AgentsUITests`:

```swift
    func testProposalsSayWhoSentThem() {
        openAgents(["-seedProposal"])
        let row = app.buttons["claude.proposal.C1A0DE00-0000-4000-8000-000000000001"]
        scrollTo(row)
        XCTAssertTrue(row.isHittable)
        XCTAssertTrue(row.label.contains("From Claude"), row.label)
        row.tap()
        let from = app.staticTexts["proposal.from"]
        XCTAssertTrue(from.waitForExistence(timeout: 5))
        XCTAssertEqual(from.label, "From Claude")
        XCTAssertTrue(app.descendants(matching: .any)["proposal.review"].exists)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run (from the repo root): `cd ios && xcodegen generate && xcodebuild test -project GymRollins.xcodeproj -scheme
GymRollins -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:GymRollinsTests/AgentsModelTests`
Expected: `** TEST FAILED **`, build error: `type 'AgentText' has no member 'caption'`.

- [ ] **Step 3: The caption, the rows, the review**

In `ios/GymRollins/Features/Claude/AgentsModel.swift`, replace

```swift
    static func addedBy(_ name: String) -> String { "Added by \(name)" }
}
```

with

```swift
    static func addedBy(_ name: String) -> String { "Added by \(name)" }

    /// A proposal row's second line: the parts joined with " · ", leaving out a sender the server didn't know.
    static func caption(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}
```

In `ios/GymRollins/Features/Claude/ClaudeConnectionView.swift`, replace

```swift
                        Text(p.createdAt.formatted(.dateTime.day().month(.abbreviated)) + " \u{00B7} Review")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
```

with

```swift
                        Text(AgentText.caption([p.createdAt.formatted(.dateTime.day().month(.abbreviated)),
                                                p.fromAgent.map(AgentText.from), "Review"]))
                            .font(.caption).foregroundStyle(Theme.textSecondary)
```

and replace

```swift
                        Text(p.autoApplied ? "Applied automatically" : "Applied").font(.caption)
                            .foregroundStyle(Theme.textSecondary)
```

with

```swift
                        Text(AgentText.caption([p.autoApplied ? "Applied automatically" : "Applied",
                                                p.fromAgent.map(AgentText.from)]))
                            .font(.caption).foregroundStyle(Theme.textSecondary)
```

In `ios/GymRollins/Features/Claude/ProposalReviewView.swift`, replace

```swift
/// Reviews one Claude proposal: a card per change with a toggle (valid ones on by default; changes that don't fit
```

with

```swift
/// Reviews one agent's proposal ("From Muse" when the server knows who sent it): a card per change with a toggle
/// (valid ones on by default; changes that don't fit
```

and replace

```swift
            Text(p.createdAt.formatted(.dateTime.day().month(.abbreviated)))
                .font(.footnote).foregroundStyle(Theme.textSecondary)
            DisplayTitle(text: "Plan change from Claude", size: 34)
                .accessibilityIdentifier("proposal.review")
```

with

```swift
            Text(p.createdAt.formatted(.dateTime.day().month(.abbreviated)))
                .font(.footnote).foregroundStyle(Theme.textSecondary)
            if let from = p.fromAgent {
                Text(AgentText.from(from)).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("proposal.from")
            }
            DisplayTitle(text: "Plan change", size: 34)
                .accessibilityIdentifier("proposal.review")
```

Run: the command from Step 2.
Expected: `** TEST SUCCEEDED **`.

Run: `... -only-testing:GymRollinsUITests/AgentsUITests/testProposalsSayWhoSentThem
-only-testing:GymRollinsUITests/ProposalUITests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ios/GymRollins/Features/Claude/ClaudeConnectionView.swift ios/GymRollins/Features/Claude/ProposalReviewView.swift \
  ios/GymRollins/Features/Claude/AgentsModel.swift ios/GymRollinsTests/AgentsModelTests.swift \
  ios/GymRollinsUITests/AgentsUITests.swift
git commit -m "feat(ios): plan changes say which agent sent them"
```

- [ ] **Step 5: Review**

**code-reviewer**, then for quality.

---

### Task A12: "Added by Muse" on the workout screen

**Files:**
- Modify: `ios/GymRollins/Features/Log/WorkoutDetailView.swift`
- Test: `ios/GymRollinsUITests/AgentsUITests.swift`

- [ ] **Step 1: Write the failing UI test**

In `ios/GymRollinsUITests/AgentsUITests.swift`, add inside `AgentsUITests`:

```swift
    /// The workout Muse added says so, and still does after the owner edits it (the edit is saved and read back).
    func testAWorkoutAnAgentAddedSaysWhoAndKeepsItThroughAnEdit() {
        app = XCUIApplication.launchReady(["-seedAgentWorkout"])
        app.tabBars.buttons["Log"].tap()
        let card = app.descendants(matching: .any)["log.workout.AD0ED000-0000-4000-8000-000000000001"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        let added = app.staticTexts["detail.addedBy"]
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        XCTAssertEqual(added.label, "Added by Muse")

        app.buttons["detail.menu"].tap()
        XCTAssertTrue(app.buttons["detail.edit"].waitForExistence(timeout: 5))
        app.buttons["detail.edit"].tap()
        let reps = app.textFields["detail.set.0.0.reps"]
        XCTAssertTrue(reps.waitForExistence(timeout: 5))
        reps.clearAndType("9")
        app.dismissKeyboardIfPresent()
        app.buttons["detail.save"].tap()
        let edited = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "1 9 \u{00D7}")).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 5))

        app.buttons["detail.back"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        XCTAssertEqual(added.label, "Added by Muse")
        XCTAssertTrue(edited.waitForExistence(timeout: 5)) // the edit was saved, and read back with the name
    }

    func testTheOwnersWorkoutsSayNothing() {
        app = XCUIApplication.launchReady(["-seedHistory"])
        app.tabBars.buttons["Log"].tap()
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        cards.firstMatch.tap()
        XCTAssertTrue(app.buttons["detail.menu"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["detail.addedBy"].exists)
    }
```

(A set row reads "<label> <reps> × <weight>", so the first working set edited to 9 reps reads "1 9 × …".)

- [ ] **Step 2: Run it to see it fail**

Run (from the repo root): `cd ios && xcodegen generate && xcodebuild test -project GymRollins.xcodeproj -scheme
GymRollins -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
-only-testing:GymRollinsUITests/AgentsUITests/testAWorkoutAnAgentAddedSaysWhoAndKeepsItThroughAnEdit`
Expected: `** TEST FAILED **` at `added.waitForExistence(timeout: 5)` (no `detail.addedBy`).

- [ ] **Step 3: The line under the title**

In `ios/GymRollins/Features/Log/WorkoutDetailView.swift`, replace

```swift
    @State private var recordCount = 0
```

with

```swift
    @State private var recordCount = 0
    /// The agent that added this workout (plan 32), read with it; nil for the owner's own.
    @State private var addedBy: String?
```

replace

```swift
            Text(workout.name).font(Theme.display(34)).foregroundStyle(Theme.textPrimary)
        }
    }
```

with

```swift
            Text(workout.name).font(Theme.display(34)).foregroundStyle(Theme.textPrimary)
            if let addedBy {
                Text(AgentText.addedBy(addedBy)).font(.footnote).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("detail.addedBy")
            }
        }
    }
```

and replace

```swift
    private func load() {
        workout = try? env.workouts.workout(workoutId)
        recordCount = (try? env.workouts.records(for: workoutId).count) ?? 0
    }
```

with

```swift
    private func load() {
        workout = try? env.workouts.workout(workoutId)
        recordCount = (try? env.workouts.records(for: workoutId).count) ?? 0
        addedBy = try? env.workouts.addedBy(workoutId)
    }
```

Run: the command from Step 2, with `-only-testing:GymRollinsUITests/AgentsUITests
-only-testing:GymRollinsUITests/LogUITests`.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ios/GymRollins/Features/Log/WorkoutDetailView.swift ios/GymRollinsUITests/AgentsUITests.swift
git commit -m "feat(ios): a workout an agent added says which one"
```

- [ ] **Step 5: Review**

**code-reviewer**, then for quality.

---

### Task A13: The approve sheet's warning names the host

**Files:**
- Modify: `ios/GymRollins/Features/Claude/ApproveConnectionModel.swift`, `ios/GymRollins/Features/Claude/ApproveConnectionView.swift`
- Test: `ios/GymRollinsTests/ApproveConnectionModelTests.swift`

- [ ] **Step 1: Write the failing test**

In `ios/GymRollinsTests/ApproveConnectionModelTests.swift`, add inside `ApproveConnectionModelTests`, after
`theBrowserIsNamedFromItsUserAgent`:

```swift
    /// Plan 32: for a host that isn't Claude's own the sheet warns, naming the host and not Claude; Claude's own hosts
    /// get no warning, as before.
    @Test func theWarningNamesAHostThatIsntClaudes() {
        #expect(ApproveConnectionModel.hostWarning(for: Self.request)
            == "Approve only if you started this connection yourself, in 127.0.0.1:53682.")
        let muse = ConnectRequest(code: "ABCD-EFGH", clientName: "Muse", redirectHost: "agent.meta.ai", knownHost: false,
                                  expiresAt: Self.opened + 600, openedAt: Self.opened)
        #expect(ApproveConnectionModel.hostWarning(for: muse)
            == "Approve only if you started this connection yourself, in agent.meta.ai.")
        let claude = ConnectRequest(code: "ABCD-EFGH", clientName: "Claude", redirectHost: "claude.ai", knownHost: true,
                                    expiresAt: Self.opened + 600, openedAt: Self.opened)
        #expect(ApproveConnectionModel.hostWarning(for: claude) == nil)
    }
```

- [ ] **Step 2: Run it to see it fail**

Run (from the repo root): `cd ios && xcodegen generate && xcodebuild test -project GymRollins.xcodeproj -scheme
GymRollins -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
-only-testing:GymRollinsTests/ApproveConnectionModelTests`
Expected: `** TEST FAILED **`, build error: `type 'ApproveConnectionModel' has no member 'hostWarning'`.

- [ ] **Step 3: The words, in the model and on the sheet**

In `ios/GymRollins/Features/Claude/ApproveConnectionModel.swift`, replace

```swift
    static let caution = "Approve only a code that's on your own screen, from a connection you started just now."
```

with

```swift
    static let caution = "Approve only a code that's on your own screen, from a connection you started just now."

    /// Plan 32: for a host that isn't Claude's own (claude.ai, claude.com), a warning that names it, worded for any
    /// agent; none for Claude's.
    static func hostWarning(for request: ConnectRequest) -> String? {
        request.knownHost ? nil : "Approve only if you started this connection yourself, in \(request.redirectHost)."
    }
```

In `ios/GymRollins/Features/Claude/ApproveConnectionView.swift`, replace

```swift
/// Settings › Claude › Approve a connection (spec section 5). Claude's sign-in page in the browser shows a code; the
```

with

```swift
/// Settings › AI agents › Approve a connection (spec section 5). The agent's sign-in page in the browser shows a code; the
```

replace

```swift
            if !request.knownHost {
                Text("This isn't Claude's address. Approve only if you started this connection yourself, for example "
                     + "in Claude Code on your computer.")
                    .font(.footnote).foregroundStyle(Theme.destructive)
                    .accessibilityIdentifier("connect.warning")
            }
```

with

```swift
            if let warning = ApproveConnectionModel.hostWarning(for: request) {
                Text(warning)
                    .font(.footnote).foregroundStyle(Theme.destructive)
                    .accessibilityIdentifier("connect.warning")
            }
```

and replace

```swift
            Text("Claude can then use what Settings \u{203A} Claude allows, until you disconnect it.")
```

with

```swift
            Text("It can then use what Settings \u{203A} AI agents allows, until you disconnect it.")
```

Run: the command from Step 2.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ios/GymRollins/Features/Claude/ApproveConnectionModel.swift ios/GymRollins/Features/Claude/ApproveConnectionView.swift \
  ios/GymRollinsTests/ApproveConnectionModelTests.swift
git commit -m "feat(ios): the approve sheet's warning names the host, for any agent"
```

- [ ] **Step 5: Review**

**code-reviewer**: the warning shows exactly when `known_host` is false (the server's set: claude.ai, claude.com).
Then for quality.

---

### Task A14: Accessibility audits and Dynamic Type

**Files:**
- Test: `ios/GymRollinsUITests/AccessibilityAuditUITests.swift`, `ios/GymRollinsUITests/DynamicTypeUITests.swift`

- [ ] **Step 1: Write the audits**

In `ios/GymRollinsUITests/AccessibilityAuditUITests.swift`, replace

```swift
        XCTAssertTrue(coach.isHittable)
        audit(app, "Use with Claude")
    }
```

with

```swift
        XCTAssertTrue(coach.isHittable)
        audit(app, "Use with Claude")
    }

    /// Plan 32: the agent rows, Disconnect's confirmation, and Add workouts.
    func testAgentsAudit() {
        let app = launch(["-seedHistory", "-fakeAgents", "-seedProposal"])
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.claude"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tap()
        let disconnect = app.buttons["agents.disconnect.MuseFakeClientId"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        waitUntilSettled(disconnect)
        audit(app, "AI agents")

        let add = app.switches["agents.perm.logWorkouts"]
        for _ in 0..<12 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.isHittable)
        waitUntilSettled(add)
        audit(app, "AI agents: what agents can do")

        for _ in 0..<12 where !disconnect.isHittable { app.swipeDown() }
        disconnect.tap()
        let confirm = app.buttons["agents.disconnect.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        waitUntilSettled(confirm)
        audit(app, "AI agents: disconnect one")
    }

    /// Plan 32: the workout screen with "Added by Muse". This is the screen's first audit: an issue on any element other
    /// than `detail.addedBy` predates this plan (Step 2 says what to do).
    func testWorkoutAddedByAnAgentAudit() {
        let app = launch(["-seedAgentWorkout"])
        app.tabBars.buttons["Log"].tap()
        let card = app.descendants(matching: .any)["log.workout.AD0ED000-0000-4000-8000-000000000001"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        let added = app.staticTexts["detail.addedBy"]
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        waitUntilSettled(added)
        audit(app, "Workout added by an agent")
    }
```

In `ios/GymRollinsUITests/DynamicTypeUITests.swift`, in `testClaudeGymsToggleAtAccessibilityXL` (Add workouts now sits
between the Gyms switch and the footer, so at AX-XL the footer can be below the screen and not built yet), replace

```swift
        XCTAssertGreaterThanOrEqual(gyms.frame.height, 44)
        XCTAssertTrue(app.staticTexts["claude.gymsNote"].exists)
        screenshot("claude-gyms-ax-xl")
```

with

```swift
        XCTAssertGreaterThanOrEqual(gyms.frame.height, 44)
        screenshot("claude-gyms-ax-xl")
        let note = app.staticTexts["claude.gymsNote"]
        for _ in 0..<6 where !note.isHittable { app.swipeUp() }
        XCTAssertTrue(note.exists)
```

In the same file, in `testUseWithClaudeAtAccessibilityXL`, replace

```swift
        let coach = app.buttons["claude.coach.copy"]
        for _ in 0..<12 where !coach.isHittable { app.swipeUp() }
        XCTAssertTrue(coach.isHittable)
        XCTAssertGreaterThanOrEqual(coach.frame.height, 44)
        screenshot("claude-coach-ax-xl")
    }
```

with

```swift
        let coach = app.buttons["claude.coach.copy"]
        for _ in 0..<20 where !coach.isHittable { app.swipeUp() } // below the switches since plan 32
        XCTAssertTrue(coach.isHittable)
        XCTAssertGreaterThanOrEqual(coach.frame.height, 44)
        screenshot("claude-coach-ax-xl")
    }

    /// Plan 32: an agent's row and Add workouts stay readable and tappable at AX-XL.
    func testAgentsAtAccessibilityXL() {
        let app = launch(extra: ["-seedHistory", "-fakeAgents"])
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.claude"]
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tapCenter()
        let name = app.staticTexts["agents.name.MuseFakeClientId"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let disconnect = app.buttons["agents.disconnect.MuseFakeClientId"]
        for _ in 0..<6 where !disconnect.isHittable { app.swipeUp() }
        XCTAssertTrue(disconnect.isHittable)
        XCTAssertGreaterThanOrEqual(disconnect.frame.height, 44)
        XCTAssertTrue(app.staticTexts["agents.lastUsed.MuseFakeClientId"].exists)
        screenshot("agents-ax-xl")

        let add = app.switches["agents.perm.logWorkouts"]
        for _ in 0..<20 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.isHittable)
        XCTAssertGreaterThanOrEqual(add.frame.height, 44)
        screenshot("agents-add-workouts-ax-xl")
    }
```

- [ ] **Step 2: Run them**

Run (from the repo root): `cd ios && xcodegen generate && xcodebuild test -project GymRollins.xcodeproj -scheme
GymRollins -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
-only-testing:GymRollinsUITests/AccessibilityAuditUITests -only-testing:GymRollinsUITests/DynamicTypeUITests`
Expected: `** TEST SUCCEEDED **`; the log lists no `A11Y-AUDIT [...] ISSUE` line.

- An `ISSUE` on an element plan 32 added (`agents.*`, `detail.addedBy`, `proposal.from`, `claude.status`'s new
  words): fix the view, in this task, and run again.
- An `ISSUE` in `testWorkoutAddedByAnAgentAudit` on any other element: the workout screen had no audit before, so it
  predates this plan. Stop, record the issue lines in the Outcome, and ask the owner whether to fix it now or exclude
  it with evidence (as `exclusionReason` does). Don't add an exclusion without that answer.

- [ ] **Step 3: Commit**

```bash
git add ios/GymRollinsUITests/AccessibilityAuditUITests.swift ios/GymRollinsUITests/DynamicTypeUITests.swift
git commit -m "test(ios): accessibility audits and AX-XL checks for Settings › AI agents and agent-added workouts"
```

- [ ] **Step 4: Review**

**code-reviewer**: each new element is audited at least once and reachable at AX-XL. Then for quality.

---

### Task A15: End to end against the local Worker

Needs the server half done and committed: the migration (`mcp_log_workouts`, `added_by`, `from_agent`), `GET
/v1/agents`, `POST /v1/agents/:clientId/disconnect`, `from_agent` in `GET /v1/claude/proposals`, and the
`log_workout` tool. Run `(cd server && npx vitest run)` first: it must pass.

**Files:**
- Create: `ios/Packages/GymSync/Tests/GymSyncIntegrationTests/AgentsTransportTests.swift`
- Modify: `ios/GymRollinsUITests/ProposalSyncUITests.swift`

- [ ] **Step 1: The GymSync integration tests**

Create `ios/Packages/GymSync/Tests/GymSyncIntegrationTests/AgentsTransportTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// Plan 32 against the local Worker: agents (real OAuth clients, `ClaudeTestClient`) connect to one account, and the
/// owner's transport lists them, disconnects one while the other keeps working, pulls a proposal with its sender's
/// name, and turns on Add workouts, after which an agent's `log_workout` reaches the workout pull with `added_by`.
@MainActor
@Suite(.enabled(if: apiConfigured, "Set API_URL to run against a local Worker"))
struct AgentsTransportTests {
    private struct Connected {
        let client: ClaudeTestClient
        let clientId: String
        let tokens: ClaudeTestClient.Tokens
    }

    /// Registers an agent named `name`, approves its code with the owner's transport, and returns it with its tokens.
    private func connect(_ name: String, to transport: ApiSyncTransport) async throws -> Connected {
        let agent = ClaudeTestClient(base: try IntegrationEnv.config().baseURL)
        let clientId = try await agent.register(name: name)
        let signIn = try await agent.startSignIn(clientId: clientId)
        try await transport.decideConnect(code: signIn.code, decision: .approve)
        let tokens = try await agent.exchange(signIn, code: try await agent.finish(signIn))
        return Connected(client: agent, clientId: clientId, tokens: tokens)
    }

    @Test func eachAgentIsListedAndDisconnectingOneLeavesTheOther() async throws {
        let user = try await Account.signUp()
        let transport = user.transport
        #expect(try await transport.connectedAgents().isEmpty)
        let claude = try await connect("Claude Code", to: transport)
        let muse = try await connect("Muse", to: transport)

        let listed = try await transport.connectedAgents()
        #expect(listed.map(\.clientId) == [muse.clientId, claude.clientId]) // newest connection first
        #expect(listed.map(\.name) == ["Muse", "Claude Code"])
        #expect(listed.allSatisfy { $0.host == "127.0.0.1:53682" && !$0.knownHost && $0.lastUsedAt == nil })
        #expect(listed.allSatisfy { abs($0.connectedAt.timeIntervalSinceNow) < 120 })

        let read = try await muse.client.callTool(muse.tokens.access, "get_profile")
        #expect(!read.isError, "\(read.json)")
        let used = try await transport.connectedAgents()
        let museUse = try #require(used.first { $0.clientId == muse.clientId }?.lastUsedAt)
        #expect(abs(museUse.timeIntervalSinceNow) < 120)
        #expect(used.first { $0.clientId == claude.clientId }?.lastUsedAt == nil)

        try await transport.disconnectAgent(clientId: muse.clientId)
        #expect(try await muse.client.mcp(muse.tokens.access, method: "tools/list").status == 401)
        let refresh = try await muse.client.refreshStatus(clientId: muse.clientId, refreshToken: muse.tokens.refresh)
        #expect((400..<500).contains(refresh), "refresh after Disconnect answered HTTP \(refresh)")
        #expect(try await claude.client.mcp(claude.tokens.access, method: "tools/list").status == 200)
        #expect(try await transport.connectedAgents().map(\.clientId) == [claude.clientId])
        await #expect(throws: AgentError.unknownAgent) { try await transport.disconnectAgent(clientId: muse.clientId) }

        #expect(try await transport.revokeOAuthGrants() == 1) // Disconnect all: the one left
        #expect(try await transport.connectedAgents().isEmpty)
        try await user.deleteAccount()
    }

    @Test func aProposalSaysWhichAgentSentIt() async throws {
        let user = try await Account.signUp()
        let muse = try await connect("Muse", to: user.transport)
        let proposed = try await muse.client.callTool(muse.tokens.access, "propose_plan_changes", [
            "summary": "Add a Pull day",
            "changes": [["id": "c1", "type": "add-routine", "routineId": "new-pull", "name": "Pull"]],
        ])
        #expect(!proposed.isError, "\(proposed.json)")
        let pulled = try await user.transport.pendingProposals()
        guard case .valid(let proposal) = try #require(pulled.first), pulled.count == 1 else {
            Issue.record("expected one valid proposal, got \(pulled)")
            return
        }
        #expect(proposal.fromAgent == "Muse")
        #expect(proposal.toDomain().fromAgent == "Muse")
        try await user.deleteAccount()
    }

    @Test func withAddWorkoutsOnAnAgentsWorkoutIsPulledWithItsName() async throws {
        let user = try await Account.signUp()
        let transport = user.transport
        var profile = ProfileSnapshot()
        profile.mcpLogWorkouts = true
        #expect(try await transport.push(profile: ProfileDTO(SyncRow(value: profile, clientUpdatedAt: Date()))) != nil)
        #expect(try await transport.pullProfile(since: nil).first?.mcpLogWorkouts == true)

        let muse = try await connect("Muse", to: transport)
        let logged = try await muse.client.callTool(muse.tokens.access, "log_workout", ["workouts": [[
            "started_at": "2026-10-08T17:02:00Z", "ended_at": "2026-10-08T18:05:00Z", "name": "Upper",
            "exercises": [["exercise_id": "0025", "sets": [["reps": 8, "weight_kg": 63.5], ["reps": 7, "weight_kg": 63.5]]]],
        ]]])
        #expect(!logged.isError, "\(logged.json)")

        let pulled = try #require(try await transport.pullWorkouts(since: nil).first { $0.name == "Upper" })
        #expect(pulled.addedBy == "Muse")
        #expect(pulled.source == "import")
        #expect(pulled.entries.first?.sets.map(\.r) == [8, 7])
        #expect(pulled.toDomain().value.addedBy == "Muse")
        try await user.deleteAccount()
    }
}
```

Run: `scripts/test-sync-integration.sh`
Expected: every GymSyncIntegrationTests suite passes, `AgentsTransportTests` with 3 tests among them, and the script
ends `Account deletion verified: … 0 rows left`.

- [ ] **Step 2: The local-Worker UI tests**

In `ios/GymRollinsUITests/ProposalSyncUITests.swift`, replace

```swift
/// `ClaudeTestClient` (a real OAuth client and MCP caller); the owner signs up in the app, approves Claude's code in
/// Settings › Claude › Approve a connection, and reviews what Claude proposes.
```

with

```swift
/// `ClaudeTestClient` (a real OAuth client and MCP caller); the owner signs up in the app, approves the agent's code in
/// Settings › AI agents › Approve a connection, and reviews what it proposes or sees what it added.
```

replace

```swift
        XCTAssertTrue(app.staticTexts["connect.warning"].exists, "a loopback callback isn't Claude's own host")
```

with

```swift
        XCTAssertTrue(app.staticTexts["connect.warning"].exists, "a loopback callback isn't Claude's own host")
        XCTAssertEqual(app.staticTexts["connect.warning"].label,
                       "Approve only if you started this connection yourself, in 127.0.0.1:53682.")
```

replace

```swift
        let tokens = try await claude.exchange(signIn, code: try await claude.finish(signIn))
        app.buttons["connect.done"].tap()
```

with

```swift
        let tokens = try await claude.exchange(signIn, code: try await claude.finish(signIn))
        app.buttons["connect.done"].tap()
        waitForLabel(app.staticTexts["agents.name.\(signIn.clientId)"], "Claude Code", timeout: 10)
        XCTAssertEqual(app.staticTexts["agents.host.\(signIn.clientId)"].label, "127.0.0.1:53682")
```

replace

```swift
        XCTAssertEqual(app.buttons["proposal.apply"].label, "Apply 1 change")
```

with

```swift
        XCTAssertEqual(app.buttons["proposal.apply"].label, "Apply 1 change")
        XCTAssertEqual(app.staticTexts["proposal.from"].label, "From Claude Code")
```

replace the whole `openApproveConnection(_:)` helper

```swift
    private func openApproveConnection(_ app: XCUIApplication) {
        // The Claude row sits below the fold of Settings' Form (rows load lazily): scroll until it is there.
        let claude = app.descendants(matching: .any)["settings.claude"]
        scroll(app, to: claude, from: .bottom)
        claude.tap()
        let approve = app.buttons["claude.approveConnection"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        approve.tap()
        XCTAssertTrue(app.textFields["connect.code"].waitForExistence(timeout: 5))
    }
```

with

```swift
    /// From Settings: Settings › AI agents.
    private func openAgents(_ app: XCUIApplication) {
        // The AI agents row sits below the fold of Settings' Form (rows load lazily): scroll until it is there.
        let row = app.descendants(matching: .any)["settings.claude"]
        scroll(app, to: row, from: .bottom)
        row.tap()
        XCTAssertTrue(app.buttons["claude.approveConnection"].waitForExistence(timeout: 5))
    }

    private func openApproveConnection(_ app: XCUIApplication) {
        openAgents(app)
        openApproveSheet(app)
    }

    /// On Settings › AI agents: opens Approve a connection.
    private func openApproveSheet(_ app: XCUIApplication) {
        app.buttons["claude.approveConnection"].tap()
        XCTAssertTrue(app.textFields["connect.code"].waitForExistence(timeout: 5))
    }

    /// In the open sheet: types `signIn`'s code, checks who asks, and approves.
    private func approve(_ app: XCUIApplication, _ signIn: ClaudeTestClient.SignIn, name: String) {
        type(signIn.code, into: app.textFields["connect.code"])
        waitForLabel(app.staticTexts["connect.client"], name, timeout: 10)
        app.buttons["connect.approve"].tap()
        waitForLabel(app.staticTexts["connect.result"], "Approved. Your browser returns to Claude in a moment.")
    }

    /// Turns a SwiftUI `Toggle` on (the inner switch when there is one, else the right edge where the knob is).
    private func turnOn(_ toggle: XCUIElement) {
        guard toggle.value as? String != "1" else { return }
        let inner = toggle.switches.firstMatch
        if inner.exists { inner.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let on = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        XCTAssertEqual(XCTWaiter().wait(for: [on], timeout: 5), .completed)
    }
```

and add, after `testAWrongCodeSaysSo`:

```swift
    /// Plan 32: with Add workouts on, Muse adds a past workout straight into history; both agents are listed, and
    /// disconnecting Muse from its row leaves Claude Code working. The workout reaches the phone as "Added by Muse".
    func testAnAgentAddsAWorkoutAndDisconnectingItLeavesTheOther() async throws {
        let app = launch()
        openSettings(app)
        signUp(app, email: "ui-\(UUID().uuidString.lowercased())@test.local")
        waitForLabel(app.staticTexts["account.status"], "Up to date")

        // 1. Add workouts on, and in the account.
        openAgents(app)
        let addWorkouts = app.switches["agents.perm.logWorkouts"]
        scroll(app, to: addWorkouts, from: .bottom)
        turnOn(addWorkouts)
        goBack(app, to: "Settings")
        syncNow(app)
        waitForLabel(app.staticTexts["account.status"], "Up to date")

        // 2. Muse, then Claude Code, connect through the sheet.
        let muse = ClaudeTestClient(base: apiURL)
        let museSignIn = try await muse.startSignIn(clientId: try await muse.register(name: "Muse"))
        openApproveConnection(app)
        approve(app, museSignIn, name: "Muse")
        let museTokens = try await muse.exchange(museSignIn, code: try await muse.finish(museSignIn))
        app.buttons["connect.done"].tap()
        let claude = ClaudeTestClient(base: apiURL)
        let claudeSignIn = try await claude.startSignIn(clientId: try await claude.register())
        openApproveSheet(app)
        approve(app, claudeSignIn, name: "Claude Code")
        let claudeTokens = try await claude.exchange(claudeSignIn, code: try await claude.finish(claudeSignIn))
        app.buttons["connect.done"].tap()

        // 3. Both are listed, the newest connection first.
        let museRow = app.staticTexts["agents.name.\(museSignIn.clientId)"]
        let claudeRow = app.staticTexts["agents.name.\(claudeSignIn.clientId)"]
        waitForLabel(claudeRow, "Claude Code", timeout: 10)
        waitForLabel(museRow, "Muse")
        XCTAssertLessThan(claudeRow.frame.minY, museRow.frame.minY)

        // 4. Muse adds a past workout.
        let logged = try await muse.callTool(museTokens.access, "log_workout", ["workouts": [[
            "started_at": "2026-09-20T17:02:00Z", "ended_at": "2026-09-20T18:05:00Z", "name": "Fitbod upper",
            "exercises": [["exercise_id": "0025", "sets": [["reps": 8, "weight_kg": 63.5], ["reps": 7, "weight_kg": 63.5]]]],
        ]]])
        XCTAssertFalse(logged.isError, "\(logged.json)")

        // 5. Disconnect Muse from its row: it is refused; Claude Code still works.
        app.buttons["agents.disconnect.\(museSignIn.clientId)"].tap()
        app.buttons["agents.disconnect.confirm"].firstMatch.tap()
        XCTAssertTrue(museRow.waitForNonExistence(timeout: 10))
        XCTAssertTrue(claudeRow.exists)
        let refused = try await muse.mcp(museTokens.access, method: "tools/list").status
        XCTAssertEqual(refused, 401)
        let served = try await claude.mcp(claudeTokens.access, method: "tools/list").status
        XCTAssertEqual(served, 200)

        // 6. The workout reaches the phone, marked with the agent that added it.
        goBack(app, to: "Settings")
        syncNow(app)
        waitForLabel(app.staticTexts["account.status"], "Up to date")
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        waitForLabel(app.staticTexts["detail.addedBy"], "Added by Muse", timeout: 10)
    }
```

Run: `scripts/ios-test-sync.sh`
Expected: `** TEST SUCCEEDED **`: every `SyncUITests` test and the 4 `ProposalSyncUITests` tests.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/GymSync/Tests/GymSyncIntegrationTests/AgentsTransportTests.swift \
  ios/GymRollinsUITests/ProposalSyncUITests.swift
git commit -m "test(ios): agents end to end on the local Worker: the list, one disconnect, an added workout"
```

- [ ] **Step 4: Review**

**code-reviewer**: the tests exercise the contract as fixed in the brief (keys, order, 404 code, `host` with port,
`added_by` and `from_agent` as the client's name). If one fails on a shape the server half chose differently, stop:
don't change the app to match, report it to the integrator.

---

### Task A16: Verify everything, and the Outcome

- [ ] **Step 1: Every suite**

```bash
(cd ios/Packages/GymData && swift test)
(cd ios/Packages/GymSync && swift test --filter GymSyncTests)
cd ios && xcodegen generate && xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:GymRollinsTests; cd ..
scripts/ios-test.sh
scripts/test-sync-integration.sh
scripts/ios-test-sync.sh
```

Expected: every run passes. GymData: base + 5 tests (A1 1, A3 3, A5 1). GymSync unit: base + 11 (A2 1, A4 1, A6 2,
A7 7). App unit: base + 20 (A1 2, A8 11, A9 5, A11 1, A13 1). `scripts/ios-test.sh` runs the unit tests and
every UI test but PerformanceUITests: `AgentsUITests` 7, and the new audit and AX-XL tests among them.

- [ ] **Step 2: No old words left on screen**

Run: `git grep -n -e '"What Claude can do"' -e '"Disconnect Claude"' -e '"Plan changes from Claude"' -e "This isn't Claude's address" -e '"Claude connection"' -e 'Settings \\u{203A} Claude' -- ios`
Expected: no output.

- [ ] **Step 3: An upgrade keeps the data (SwiftData's lightweight migration)**

On the simulator only, never the owner's phone. `<scratchpad>` is this session's scratch folder.

```bash
git worktree add <scratchpad>/gym-main de2bda6
(cd <scratchpad>/gym-main/ios && xcodegen generate --quiet && xcodebuild build -project GymRollins.xcodeproj \
  -scheme GymRollins -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' \
  -derivedDataPath <scratchpad>/dd-main -quiet)
(cd ios && xcodebuild build -project GymRollins.xcodeproj -scheme GymRollins \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -derivedDataPath <scratchpad>/dd-branch -quiet)
xcrun simctl boot "iPhone 17 Pro" || true
xcrun simctl uninstall booted com.rollins.gymrollins
xcrun simctl install booted <scratchpad>/dd-main/Build/Products/Debug-iphonesimulator/GymRollins.app
xcrun simctl launch booted com.rollins.gymrollins -seedOwner -seedHistory -skipOnboarding
xcrun simctl terminate booted com.rollins.gymrollins
xcrun simctl install booted <scratchpad>/dd-branch/Build/Products/Debug-iphonesimulator/GymRollins.app
xcrun simctl launch booted com.rollins.gymrollins -skipOnboarding
xcrun simctl io booted screenshot <scratchpad>/upgrade-today.png
```

Expected: the second launch opens Today with the seeded plan (not onboarding, not a crash). Open Log by hand: the
seeded history is there; open Settings › AI agents: "No agents connected." and Add workouts off. Then
`git worktree remove <scratchpad>/gym-main` and `xcrun simctl uninstall booted com.rollins.gymrollins`.

- [ ] **Step 4: The Outcome**

Add `## Outcome` to this plan: the commits, the base and final counts of the three suites, the UI and integration runs,
the upgrade check, any finding "added after review", and the answers the questions below still need.

```bash
git add docs/plans/2026-11-09-plan-32-ai-agents.part-app.md
git commit -m "docs: plan 32 app half outcome"
```

---

## Self-review against the spec

| Spec | Where |
|---|---|
| 4.1 Connected agents: name, host, "Last used …"/"Not used yet", Disconnect asking "Disconnect Muse? It loses access until you approve it again.", empty "No agents connected." | A7, A8, A10 (`ConnectedAgentsSection`), tests in A8, A10 |
| 4.2 Connect unchanged | A10 (`connectSection` as before; step 3's path text only) |
| 4.3 "Plan changes from your agents", "From Muse" | A5, A6, A10, A11 |
| 4.4 "What agents can do" + Add workouts ("Let agents add past workouts to your history"), off | A1, A2, A10 |
| 4.5 Use with Claude unchanged | A10 (same `UseWithClaudeSection`) |
| 4.6 Disconnect all, with a confirmation | A10 |
| "Added by Muse"; editable and deletable like any other | A3, A4, A12 |
| Approve screen: neutral warning naming the host; none for Claude's hosts | A13 |
| 5 App: model tests (list, disconnect, empty, errors), labels, UI tests (sections, Disconnect's confirmation, Add workouts), audits | A8, A10–A14 |
| 5 End to end, local: an agent logs a workout and it reaches the simulator marked "Added by …" | A15 |

## Questions for the owner

1. Today's chip still reads "Plan change from Claude" for any agent's proposal (`TodayView.swift:440`). "Plan change
   from Muse" when known, "Plan change" otherwise?
2. The approve sheet's results say "Your browser returns to Claude in a moment." and "Denied. Claude wasn't given
   access." for any agent; its code hint says "Claude's page shows 8 letters and digits". Reword for any agent?
3. Settings' badge still says Connected when any agent ever used the server (`lastMcpUse`). Should it count the
   connected agents instead ("2 connected")?

## Notes for the integrator (server half)

- A profile push from the app always carries `mcp_log_workouts`. The phone runs the old app between the Worker deploy
  and the app install (spec section 6), and the old app's profile pushes have no such key: the server should treat a
  missing key as "leave as stored" or `false`, never refuse the row.
- The app never sends `added_by`, and an old app's workout push can't either: the server must keep a stored
  `added_by` when a push updates the workout.
- `host` for a loopback client is expected as `127.0.0.1:53682` (host and port), like `connect_requests.redirect_host`.
