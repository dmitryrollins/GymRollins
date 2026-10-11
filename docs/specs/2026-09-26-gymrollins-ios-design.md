# GymRollins iOS: design spec

Date: 2026-09-26 · Status: approved in brainstorming; the user asked to build through to the end.
Mockups: https://claude.ai/artifact/49XbqyeLuXR35ABhvFpbzK (30 artboards; the flow map lists every step).

## 1. Goal

A native SwiftUI iPhone app for logging strength training, Fitbod-style. Its main difference is that **Claude reads the
training data and writes the next plan through MCP**, replacing today's loop of CSV export → chat → hand-written plan.
It is built for one user first (the owner, 81 → 85 kg lean goal, lb plates) and kept clean enough to ship to the App
Store later.

### In v1
1. Today's workout and live logging: warm-up flag, done checks, rest timer, plate calculator, workout clock.
2. Exercise library (1,324 exercises with instructions and GIFs), swap, custom exercises.
3. History: workout summary, PRs, estimated 1RM, per-exercise history and trend.
4. Deterministic weight suggestions (progression engine).
5. Cloud sync plus a remote MCP server so Claude can read data and propose plan changes.
6. Fitbod CSV import (`Date,Exercise,Reps,Weight(kg),Duration(s),Distance(m),Incline,Resistance,isWarmup,Note,multiplier`);
   since plan 13 also Strong, Hevy and FitNotes CSV exports (`docs/plans/2026-09-29-plan-13-importers.md`).
7. Body tracking: bodyweight and body-fat log, goal progress.

### Not in v1
Recovery muscle map, weekly set targets, streaks, Apple Health, Apple Watch, Live Activity, in-app AI chat, and
importers for other apps (Strong, Hevy, FitNotes) — the importers were added later in plan 13.

> **Plan 12 (2026-09-29, owner-approved):** the recovery muscle map, weekly set targets and weekly streaks were
> added after v1 — see `docs/plans/2026-09-29-plan-12-insights.md` (model, defaults, `muscle_targets` table and the
> `get_training_insights` MCP tool). The figure comes from react-native-body-highlighter (MIT,
> `docs/licenses/body-highlighter.md`; vulovix/body-muscles until 2026-10-03) and also draws each exercise's
> target-muscle badge on its thumbnail.

### Success criteria
- The owner can import the full export, run a workout on the phone with no signal, and see it in the Log.
- From the Claude app (connector added), Claude can answer "what did I bench last week" and propose a plan that
  appears in the app to apply.
- E2E suites pass on the iOS 26 simulator and against local Supabase. Core logic coverage is at least 80%.

## 2. Constraints and decisions

| Topic | Decision |
|---|---|
| Platform | iOS 26+ (Liquid Glass APIs), Swift 6, strict concurrency, SwiftUI, Xcode 26.3 |
| Project generation | XcodeGen (`ios/project.yml`); the `.xcodeproj` isn't committed |
| Local store | SwiftData, the offline source of truth on the device |
| Backend | Supabase: Postgres + RLS, Auth (Sign in with Apple, OAuth 2.1 server), Edge Functions (Deno) |
| Environments | **Local Supabase only** (CLI via `npx supabase`, Docker via colima) until the owner approves a cloud project |
| MCP | Remote MCP server as a Supabase Edge Function, Streamable HTTP, OAuth via Supabase Auth OAuth 2.1 server with dynamic client registration |
| AI writes | Claude never edits the plan directly; it creates **proposals** that the owner applies (opt-in auto-apply) |
| opengym | Reference only (AGPL-3.0). We reuse its **data shapes, naming and rules as behavior**, not its source files |
| Exercise data | From the dataset opengym uses (hasaneyldrm/exercises-dataset). Names, instructions and structure are **MIT** and bundled as JSON, with credit in Settings → About. Its images and GIFs are **© Gym visual, and no reuse rights are granted**, and are never used. **Media (owner decision 2026-09-28): stopgap public-domain photos** from yuhonas/free-exercise-db (Unlicense, pinned commit; `docs/licenses/free-exercise-db.md`), mapped by name at build time (`scripts/map-exercise-photos.mjs`, `docs/import/exercise-photo-review.md`; 300 / 1,324 exercises), loaded on demand from jsDelivr and cached on the device. Exercises without a photo keep the body-part illustration. GymRollins' own AI-generated images/GIFs replace them later through `ExerciseMediaProvider` (resolution order: own media → free-exercise-db photos → wger.de photos → illustration). **wger.de (plan 16):** Creative Commons photos (per-item license + author, credited on the detail photo; trusted/reviewed images only) fill remaining gaps, and other-language exercise names (CC0/CC-BY/CC-BY-SA) are searchable and used by the importers; `docs/licenses/wger.md` |
| Units | Stored in kg. Shown in the user's unit (default lb). Loads rounded to the available plates and dumbbells |
| Code review | Codex CLI (`codex review`) plus Claude reviewer agents at the end of each milestone |

## 3. Architecture

```
┌──────────────── iPhone ────────────────┐        ┌──────────── Supabase ─────────────┐
│ SwiftUI features (Today, Workout, Log, │        │ Postgres (RLS by auth.uid())       │
│ Body, Library, Settings, Onboarding)   │        │ Auth: Apple ID token, OAuth 2.1    │
│        │ observes                      │  sync  │   server (+ DCR) for MCP clients   │
│ GymData: SwiftData store + SyncEngine ─┼───────►│ PostgREST (tables, RPC)            │
│        │ uses                          │        │ Edge Fn `mcp` (MCP tools)  ◄───────┼── Claude (custom
│ GymCore: pure Swift domain & rules     │        │                                     │    connector)
└────────────────────────────────────────┘        └────────────────────────────────────┘

Consent UI: `web/consent/` (a static site — index.html/consent.js/style.css, no server-side rendering) served
locally by `scripts/consent-server.mjs` on `http://127.0.0.1:55430`, **not** a Supabase Edge Function — Supabase
rewrites Edge Function HTML responses to `text/plain` (`docs/research/2026-09-26-mcp-on-supabase.md` §5), so the
page users approve/deny the OAuth request on can't be served by the `mcp` function or any other Edge Function.
`[auth] site_url` in `config.toml` points at the consent server, so `GET /auth/v1/oauth/authorize` redirects
there with `?authorization_id=...`. See §5 "OAuth consent" below and `README.md`'s "OAuth (Claude connector)"
section for the full flow.
```

### Repository layout (`GymRollins/app/`)
```
ios/
  project.yml                 XcodeGen spec
  GymRollins/                 App target: App entry, Features/*, DesignSystem/*, Resources/
  GymRollinsUITests/          XCUITest E2E
  Packages/GymCore/           Swift package: models, progression, 1RM, plates, CSV import, plan-change validation
  Packages/GymData/           Swift package: SwiftData schema, repositories, SyncEngine, SupabaseClient wrapper
web/
  consent/                    OAuth consent page: static site (index.html, consent.js, style.css)
supabase/
  config.toml                 local config (auth.oauth_server enabled, Apple provider)
  migrations/*.sql            schema, RLS, RPCs
  seed.sql                    exercise library seed and test users (local only)
  functions/mcp/              MCP server (TypeScript, @modelcontextprotocol/sdk)
  functions/_shared/          validation shared with the MCP tools (plan-change rules; plan-validation.ts)
  tests/                      pgTAP (RLS), deno tests (MCP tools, e2e over HTTP)
scripts/                      build-exercise-library, dev helpers, consent-server.mjs (serves web/consent/ on
                               127.0.0.1:55430), oauth-local-smoke.sh
docs/                         specs, plans
```

### Units and responsibilities
- **GymCore** (no I/O, fully unit-tested): value types (`Exercise`, `Routine`, `RoutineExercise`, `Workout`,
  `WorkoutEntry`, `WorkoutSet`, `BodyweightEntry`, `PlanProposal`, `PlanChange`); `ProgressionEngine`;
  `OneRepMax` (Epley by default, Brzycki, reps capped at 12); `PlateCalculator`; `UnitFormatter`; `FitbodCSVImporter`;
  `PlanChangeValidator`; `WorkoutClock` (elapsed time with pauses).
- **GymData**: the SwiftData `@Model` mirror of the server tables with sync metadata; repositories for each aggregate;
  `SyncEngine` (push dirty rows, pull by cursor, handle conflicts); `AuthService` (Apple → Supabase session);
  `ExerciseLibrary` (bundled JSON + custom exercises, search).
- **App**: feature modules with `@Observable` view models, a DesignSystem (glass components and tokens), navigation.

## 4. Data model (opengym naming; weights in kg)

Every user-owned table has `user_id uuid` (default `auth.uid()`), `client_updated_at timestamptz` (the device edit
time, used by the last-write-wins trigger), `updated_at timestamptz` set by trigger to `now()`,
`deleted_at timestamptz` (tombstone) and a client-generated `id uuid`. RLS on every table:
`user_id = auth.uid()` for select, insert, update and delete for the app; MCP OAuth clients get a narrower policy
(see "MCP-client RLS restrictions" below).

> **Plan 05 spec changes (aggregate sync):** routines sync as a single aggregate — `routine_exercises` is not a
> separate table; a routine's exercises live in a `routines.exercises jsonb` array (≤20 entries), pushed and pulled
> as one row. Workouts also sync as an aggregate through the `upsert_workout(payload)` RPC, which upserts the
> workout plus replaces its `workout_entries`/`workout_sets` children in one transaction (returning `{"status":
> "ok"|"stale"}`). `workout_entries` and `workout_sets` stay relational tables (not jsonb) so the MCP server (plan
> 06) can query workout history with plain SQL joins.

| Table | Key columns |
|---|---|
| `profiles` | `user_id` pk, `deload_pct` (5), `unit` ('kg'\|'lb'), `rest_sec` (120), `warmup_rest_sec` (60), `height_cm`, `goal_weight_kg`, `goal_date`, `training_days`, `experience`, `limits` text, `effort` (null\|'rir'\|'rpe'), `bar_kg`, `plates` jsonb, `dumbbell_step_kg`, `mcp_read_workouts`, `mcp_read_body`, `mcp_propose`, `mcp_auto_apply` (bool) |
| `exercises` | global read-only library: `id` text pk, `n`, `bp`, `eq`, `tg`, `mg`, `sm` text[], `st` text[], `img`, `gif`, `aliases` text[] |
| `custom_exercises` | `id`, `user_id`, `n`, `bp`, `eq`, `tg`, `mode` ('reps'\|'time'\|'cardio'), `bilateral` bool |
| `routines` | `id`, `name`, `emoji`, `prog` (policy), `position`, `paused` bool, `exercises` jsonb (array of `{id, exercise_id, position, sets, reps, reps_min, sec, weight_kg, mode, prog, inc_kg, sg}`, ≤20 entries — aggregate sync, replaces the old `routine_exercises` table) |
| `week_schedule` | `user_id`, `weekday` 1–7, `routine_id` (null = rest); pk (user_id, weekday) |
| `workouts` | `id`, `started_at`, `ended_at`, `paused_sec`, `routine_id`, `name`, `vol_kg`, `records` jsonb (PRs), `source` ('app'\|'import'), `note` — written through the `upsert_workout` RPC, never a direct table upsert |
| `workout_entries` | `id`, `workout_id`, `exercise_id`, `position`, `note`, `superset_group` (relational child of a workout, written by `upsert_workout`) |
| `workout_sets` | `id`, `entry_id`, `position`, `w_kg`, `r`, `sec`, `min`, `dist_m`, `done`, **`warmup`** (new versus opengym), `rir`, `rpe`, `multiplier`, `completed_at` (relational child, written by `upsert_workout`) |
| `bodyweight` | `id`, `measured_at`, `w_kg`, `bf_pct`, `t` ('morning'\|…) |
| `ex_weights` | `user_id`, `exercise_id` pk; `w_kg`, `d`: last working weight |
| `proposals` | `id`, `created_at`, `source` ('claude'), `summary`, `changes` jsonb, `status` ('pending'\|'applied'\|'dismissed'\|'partial'), `applied_change_ids` jsonb, `snapshot` jsonb (for undo), `resolved_at` |
| `mcp_audit` | `id`, `user_id`, `tool`, `args_digest`, `ok`, `at` (insert-only; the owner can read their own) |

**MCP-client RLS restrictions:** MCP OAuth access tokens carry a `client_id` claim (`public.is_mcp_client()` checks
`auth.jwt() ->> 'client_id'`). RLS denies such clients write access to every user table except inserting a
`pending` `proposals` row (gated by `profiles.mcp_propose`) and inserting `bodyweight` rows (gated by
`profiles.mcp_read_body`); all other inserts/updates/deletes, and the `upsert_workout` / `delete_my_account` RPCs,
raise `42501`. Reads of `workouts`/`workout_entries`/`workout_sets` and `bodyweight` are further filtered by the
owner's `mcp_read_workouts` / `mcp_read_body` flags. This is defense in depth under the MCP server's own
per-tool checks (§5 MCP server).

**Plan change types** (closed list, from opengym plus `weight`): `add-exercise`, `remove-exercise`, `swap-exercise`,
`sets`, `reps`, `repsMin`, `sec`, `weight`, `cardio`, `reorder`, `superset`, `routine-prog`, `exercise-prog`, `inc`,
`add-routine`, `remove-routine`, `rename-routine`, `pause-routine`, `week`, `today`. Limits: 25 changes per proposal,
7 routines, 20 exercises per routine. `PlanChangeValidator` (Swift) and `_shared/plan-validation.ts` (TS) implement
the same rules and share one JSON fixture suite.

> **`today` (one-off routine for a date):** `routineId` + `date` (yyyy-MM-dd, the owner's local date). Applying it
> does what Today → Switch does, for that date only: the week schedule is untouched and the next day is back to
> normal. Rules: the routine exists (or is added earlier in the same proposal) and isn't paused (after earlier
> changes); `date` is a real date from the owner's today to **7 days ahead** (`PlanChangeLimits.todayDaysAhead`,
> drift-guarded); one `today` change per date. The server doesn't know the owner's time zone, so `propose_plan_changes`
> checks against the UTC date with **±1 day** of slack; the app re-checks against the owner's local date when applying,
> and a date that has passed by then is skipped ("Date passed") while the rest of the proposal applies.
>
> Storage: like a manual Switch it is **local to the iPhone that applies it** (UserDefaults, never synced). A switch
> for today goes into `TodayPlanStore` (so the watch is re-sent today's routine); a later date waits in
> `PlannedSwitchStore` and becomes that day's stored plan the first time Today is read on it. A workout in progress
> is never altered — the switch only changes what Today offers next (also after a workout already finished that
> day). Picking the scheduled routine means "as scheduled" (clears a manual switch). Undo takes back switches that
> are still unedited. Recipe for Claude (tool description): a one-off session = `add-routine` (or reuse one) +
> `today`; `week` only for permanent schedule changes.

## 5. Key behaviors

### Workout session
- Starting a routine creates a `Workout` (local only while active) with entries prefilled from the routine targets
  plus `ProgressionEngine` suggestions. Warm-up sets come from the working weight (bar × 10, ~50–70% × 5), and the
  user can turn them off.
- **Workout clock**: `started_at` plus accumulated `paused_sec`; the elapsed time shows on the in-progress and logging
  screens. It's saved on every change, so a killed app resumes (resume banner).
- **Log Set** marks the next set done, stores `completed_at`, and starts the rest timer (working or warm-up default,
  or the per-exercise override). A local notification plus haptic fires when rest ends. **Log All Sets** marks all
  remaining sets with their shown values.
- **Finish**: summary of unfinished sets → discard empty sets or mark them done. It computes volume (dumbbell
  `multiplier`), PRs (rep record at a weight, e1RM record, volume record) and `ex_weights`, then queues the sync.
- Plate calculator: target load → per-side plates from the inventory (default lb: 45, 35, 25, 10, 5, 2.5; bar 45).

### Progression engine (behavior based on opengym's rules; our own code)
Policies: `off`, `linear` (+inc on success), `double` (default: all sets at the top of the rep range → +inc and back
to the bottom of the range), `greyskull` (AMRAP last set; double jump when reps ≥ 2× target), `time` (+sec).
Two misses in a row → deload by `deloadPct` (default 5%, the owner's rule; configurable per profile), rounded down to
loadable increments. Output: `Suggestion { weightKg, reps, reason }`, shown as the green hint.

### Fitbod CSV import
Rows are grouped into workouts by identical `Date` timestamp. Exercise names are matched by exact name, then alias
table, then normalized fuzzy match. Unmatched names go to a match screen (pick a library exercise or create a
custom one). `isWarmup` → `warmup`; Duration/Distance → cardio/time sets; `multiplier` kept; Incline and Resistance
ignored. Importing twice is idempotent (the workout id is a hash of the timestamp and the exercise list).

### Sync
Offline-first. Each local row has `dirty`, `serverUpdatedAt` and `baseUpdatedAt`. **Push** upserts dirty rows
(PostgREST, batched per table in dependency order) and clears `dirty` on success. **Pull** fetches rows with
`updated_at > cursor` per table and applies them unless the local row is dirty. **Conflict** (local dirty and server
`updated_at` > local base) is last write wins per row, except for workouts, where the owner picks
"Keep this iPhone's" or "Keep other". The active workout never syncs until it's finished. Triggers: app foreground,
workout finished, proposal resolved, pull-to-refresh, and every 5 minutes while in the foreground.

Routines push/pull as a single aggregate (`exercises jsonb`); workouts push/pull as a single aggregate through the
`upsert_workout` RPC (entries + sets in one transaction), which returns `stale` instead of silently dropping a
write so the app can offer the same "Keep this iPhone's / Keep other" choice (§4 Plan 05 spec changes).

**Base-version conflict rule for `upsert_workout`** (migration `supabase/migrations/20260928000001_workout_base_version.sql`):
every push carries `base_updated_at` — the server `updated_at` the device last saw for this workout, or `null`
if it never synced — and `force`, which is `true` only for the explicit "Keep this iPhone's" resolution. Under
the RPC's row lock, in order:
1. **No row yet** → insert (as before).
2. **`force = true`** → overwrite regardless of base/edit time; the stored `client_updated_at` becomes
   `max(incoming, stored)` so the table's `lww_guard` trigger (which skips older edits) never drops it.
3. **`base` differs from the stored `updated_at`** → `{status: 'stale'}`, nothing touched — another device
   changed the workout since this one last saw it. Exception: `base` is `null` and the stored
   `client_updated_at` already equals the incoming one — that's a retry of the same edit after a lost ack
   (the previous push's response never reached the device), so it applies instead of surfacing as a conflict.
4. **Otherwise** the ordinary `client_updated_at` last-write-wins guard still applies (an older edit is stale).

A `stale` result surfaces as a conflict for the owner to resolve ("Keep this iPhone's" / "Keep other"), same as
any other workout conflict.

**Local development:** the local Supabase stack (Postgres, Auth, PostgREST, Studio, etc.) runs on ports `554xx`
(API `55421`, DB `55422`, shadow DB `55420`, pooler `55429`, Studio `55423`, Inbucket `55424`, Analytics `55427`,
Edge Functions inspector `55483`) instead of the CLI defaults (`543xx`), so it doesn't collide with another local
Supabase project's containers on the same machine. `scripts/supabase-up.sh` starts it and writes connection details
to `supabase/.env.local` (gitignored); `scripts/test-db.sh` resets the database and runs the pgTAP suite.

### Auth
Sign in with Apple (`ASAuthorizationAppleIDProvider`) → `supabase.auth.signInWithIdToken(provider: .apple)`. A
DEBUG-only email/password login exists for the simulator and UI tests (compiled out of Release).

### MCP server (`functions/mcp`)
- Streamable HTTP, stateless. Unauthenticated calls return `401` with
  `WWW-Authenticate: Bearer resource_metadata=".../mcp/.well-known/oauth-protected-resource"`, and the function serves
  that metadata (authorization server = Supabase Auth `/auth/v1`).
- Each request creates a Supabase client with the caller's access token, **so RLS applies**. The service role is
  never used in tool paths. Each tool call is written to `mcp_audit`. There is a per-user rate limit (60 calls/min).
- Permissions from `profiles.mcp_*` are checked for each tool.
- **Read tools**: `get_profile`, `get_plan` (routines + week), `list_workouts(since?, until?, limit≤60)`,
  `get_workout(id)`, `get_exercise_history(exercise, since?)` (sets + e1RM per session), `get_training_summary(weeks≤12)`
  (frequency, volume by body part, stalls, PRs), `get_bodyweight(since?)`, `search_exercises(query, body_part?, equipment?)`,
  `get_training_insights(time_zone?)` (plan 12: recovery % per muscle group, weekly hard sets vs targets, streak).
- **Write tools**: `propose_plan_changes(summary, changes[])` → validated → `proposals` row (auto-applied only if
  `mcp_auto_apply`); `get_proposal(id)`; `log_bodyweight(d, w_kg, bf_pct?)` (gated by `mcp_read_body`).
- Tool descriptions state the units (kg) and the owner's unit preference so Claude talks in lb.

### OAuth consent (`web/consent/` + `scripts/consent-server.mjs`)
Supabase rewrites Edge Function HTML responses to `text/plain` (`docs/research/2026-09-26-mcp-on-supabase.md`
§5), so the consent screen the user approves/denies on can't be the `mcp` Edge Function, or any Edge Function —
it's a static site instead, served locally by a small Node HTTP server:

- **`web/consent/`** (`index.html`, `consent.js`, `style.css`) reads `authorization_id` from the query string,
  signs the user in if needed (email/password locally; Apple JS only when the cloud build sets
  `window.GYM_APPLE_ENABLED`), calls `supabase.auth.oauth.getAuthorizationDetails`, shows the client name, the
  full redirect URI and a first-time warning, then Approve/Deny → `approveAuthorization`/`denyAuthorization` →
  follows the returned `redirect_url`. Loads `supabase-js` from a pinned `esm.sh` URL.
- **`scripts/consent-server.mjs`** serves `web/consent/*` on `http://127.0.0.1:55430` (binds `127.0.0.1` only),
  maps `/oauth/consent` (and `/`) to `index.html`, and generates `/config.js`
  (`window.GYM_CONFIG = { url, anonKey }`) from `supabase/.env.local` — never the service-role key. It sets a
  strict CSP (no `'unsafe-inline'`, `connect-src` scoped to exactly the local API URL) and
  `X-Content-Type-Options: nosniff`, and blocks directory traversal.

`[auth] site_url` in `config.toml` is `http://127.0.0.1:55430`, so `GET /auth/v1/oauth/authorize` redirects
there with `?authorization_id=...`; the auth container reads `config.toml` only at startup, so a `site_url`
change needs a stack restart. Revoking is possible from Settings → Claude → Disconnect. `README.md`'s "OAuth
(Claude connector)" section is the reference for the full local dev flow, including
`scripts/oauth-local-smoke.sh` (automates the handshake up to the human's "Approve" click) and
`web/consent/e2e.test.mjs` (drives the click too, headless).

### Proposals in the app
The Today chip and Settings → Claude show pending proposals. The review screen lists each change (before → after,
reason) with a toggle.

> **Plan 05 spec change (applied on device):** proposals are **not** applied by a SQL RPC. **Apply** validates the
> selected changes on-device with GymCore's `PlanChangeValidator`, applies them locally with `PlanChangeApplier`
> (plan 06), and then syncs the changed routines like any other local edit; the proposal row is updated to
> `status = 'applied'` (or `'partial'`) with `applied_change_ids` as part of that same sync push. Auto-apply
> (`profiles.mcp_auto_apply`) happens on-device too, the next time the app syncs and sees a pending proposal — not
> server-side at insert time. Undo restores from a locally-kept snapshot for 7 days. Dismiss sets the status.
> This keeps `PlanChangeApplier`'s validation logic in one place (Swift) instead of duplicating it in SQL.
>
> **Apply/undo are atomic** (`ProposalService`, GymData): applying (or undoing) a proposal stages the
> routine/schedule changes, the undo snapshot and the proposal's resolution (`status`, `applied_change_ids`) in
> one SwiftData `ModelContext` and saves it once. On any failure partway through, the context is rolled back to
> its last save, so the plan on disk is unchanged and the proposal stays `pending` — there's no partially-applied
> state to reconcile.

## 6. UI

- Dark athletic look. Tokens: bg `#0B0B10`, solid content cards `#17171E`, text `#F2F2F5` / `#A9A9B5` / `#8E8E9A`,
  accent `#FF6B72`, primary fill `#D63A46`, success `#4FD1A5`, record/warning amber `#F5B75A`. Headlines are a
  condensed italic display face (Barlow Condensed, bundled under OFL); body text uses the system font, which is
  easier to read in the gym.
- **Liquid Glass on every control**: the system `TabView` (Tab API) gives the floating glass tab bar; `.buttonStyle(.glass)`
  and `.glassProminent` for buttons; `.glassEffect(.regular.interactive(), in: .capsule)` for chips, the timer bar,
  the workout clock and floating CTAs, grouped in a `GlassEffectContainer`; system sheets and toolbars (glass by
  default). Content (lists, set tables, charts) stays solid for legibility, per Apple's guidance.
- Tabs: **Today · Body · Library · Log**. Settings is reached from the avatar on Today and the gear on Log.
- Screens match the mockup flow map: onboarding 1.1–1.5, plan 2.1–2.4, workout 3.1–3.10, review 4.1–4.5, library
  and settings 5.1–5.4, system states 6.1–6.4.
- Accessibility: Dynamic Type up to XXL on logging screens, 44 pt targets, VoiceOver labels on icon buttons,
  contrast ≥ 4.5:1.

## 7. Error handling
- Network and sync failures never block logging. A glass "Offline" capsule appears, and a retry with backoff runs.
- Sign-in failure shows an inline message with a retry. An expired session refreshes silently and falls back to
  re-login, keeping local data.
- Import reports errors row by row. A bad file shows the first failing line and the expected header.
- MCP: validation errors return `isError: true` with a list of the rule violations. Auth errors return 401 with
  metadata. Rate limits return 429 with retry-after.
- Apply-proposal failure rolls back the transaction, and the app shows which change failed.
- Every error is logged with `os.Logger` (subsystem per module) in the app and `console.error` with a request id in
  the functions. No personal data goes in the logs.

## 8. Security and privacy
- RLS on every user table, with pgTAP tests proving cross-user isolation.
- The app ships only the anon/publishable key. There is no service key in the app or in MCP tool paths.
- MCP tokens are scoped to the user through OAuth, explicit consent and revocation. Proposals are validated against
  the closed change list and limits. There is an audit log.
- Input is validated at the boundaries: CSV parser, PostgREST check constraints (reps 0–100, weight 0–1000 kg,
  dates), MCP zod schemas.
- Account deletion from Settings (App Store requirement) through an RPC that deletes all user rows and the auth user.
- Export all data (JSON) from Settings.

## 9. Testing
- **GymCore unit tests** (Swift Testing): progression policies and deloads, 1RM, plates, unit rounding, CSV import
  (fixture: a trimmed slice of the owner's export plus edge cases), plan-change validation (shared fixture), clock.
  Target ≥ 90% line coverage.
- **GymData tests**: repositories on an in-memory SwiftData container; SyncEngine against a stub transport
  (push order, cursors, conflicts, tombstones).
- **Database tests** (pgTAP via `supabase test db`): RLS isolation, `apply_proposal` transactionality and undo,
  delete account.
- **MCP tests** (deno test): each tool against local Supabase with two test users (isolation, permission flags,
  validation errors, audit rows), plus an HTTP e2e that walks the 401 → metadata → token → `tools/list` →
  `propose_plan_changes` flow.
- **E2E UI tests** (XCUITest, iOS 26 simulator): (1) onboarding with the debug login → CSV import → match → Today;
  (2) start workout → log warm-up and working sets → rest timer → plate calculator → finish → summary → Log shows the
  duration; (3) a proposal inserted in the backend appears → apply → Today updates → undo; (4) weigh-in → Body goal
  progress; (5) offline logging → reconnect → synced; (6) swap exercise and add exercise mid-workout. The UI tests run
  against local Supabase (`UITEST_BACKEND=local`) and use launch arguments to reset state.
- The test command matrix lives in `app/README.md`; `scripts/test-all.sh` runs everything.

## 10. Milestones
M0 scaffold (XcodeGen, packages, local Supabase, CI script) → M1 GymCore (TDD) → M2 data layer + design system +
library → M3 workout flow → M4 log/body/history → M5 Supabase schema, RLS, auth, sync → M6 MCP server + OAuth consent +
proposals UI → M7 onboarding, import, settings, system states → M8 E2E suites green, Codex + Claude review, polish.
Each milestone ends with its tests passing and a review.

## 11. Risks
- **Supabase OAuth 2.1 server is in beta.** Mitigation: an MCP HTTP e2e test in CI; the tool logic is kept separate
  from the transport and auth.
- **A real Claude connector needs a public HTTPS URL**, so the local-only phase needs a tunnel (cloudflared or ngrok,
  with `jwt_issuer` set). Full Claude-app testing waits until the owner approves a cloud project.
- **Exercise media**: Gym visual media can't be used without our own license. v1 uses body-part illustrations, and `Exercise.gif` and `Exercise.image` stay in the model so a licensed media source can plug in later.
- **Liquid Glass APIs are iOS 26 only**, which is fine because the minimum target is iOS 26.
