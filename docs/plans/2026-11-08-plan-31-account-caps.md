# Plan 31: Per-account storage caps

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** before the first deploy, one account can't fill D1. The Worker caps what one account stores, with the
owner's numbers:
- 10,000 workouts, 20,000 weigh-ins, 200 routines and 1,000 custom exercises per account, deleted rows included;
- 100 Claude proposals waiting for review at a time;
- 50 exercises in one workout, and 50 sets in one exercise of a workout.

Each cap is tested at its exact number. An edit of a stored row is never refused. A refused row stays on the phone,
isn't sent again in a loop, and Account shows the server's plain words for it. The phone stops at the per-workout caps
too, so nothing made by hand is refused.

**Architecture:**
- **One set of numbers.** Seven new constants in `DomainLimits.swift`, copied in `server/src/shared/domain-limits.ts`.
  The drift test checks the copy and the numbers in the triggers.
- **Account caps are SQLite triggers,** as plan 28's gym caps are. A push stays one statement, and a refusal fails the
  whole statement. A table the triggers keep, `account_rows`, holds each account's count, so a check reads one row.
- **Pending proposals** are a live count (at most 100 rows) behind a partial index.
- **Per-workout caps** are checked in TypeScript when a save is parsed, because a save rewrites exactly the entries and
  sets it carries.
- **The app** already treats any 422 as a refused row: it keeps the row, parks it, and lists it in Account. This plan
  groups identical refusals into one line there, rewords the footer, and makes the phone stop at 50 and 50.

**Tech stack:** as plans 26–30. The Worker (Hono 4.13.17, Better Auth 1.7.18, D1 and R2 through wrangler 4.158.0,
Vitest 4.1.12 with `@cloudflare/vitest-plugin` 1.6.0 in workerd), Swift 6.2 (`swift test`, `xcodebuild`, XcodeGen).

**Spec:** `docs/specs/2026-11-07-cloudflare-backend-design.md`: sections 4 ("Sync"), 6 (errors) and 8 ("Limits").
`docs/cloudflare-checklist.md`, section 5, which asked for this plan.

**Builds on:** plans 26–30, each built and with its `## Outcome`. The base is `699f6a4` or later on `feat-cloudflare`.

**Branch:** `feat-cloudflare`.
- No push.
- Local only: never run `wrangler login`, `wrangler deploy`, or any `wrangler` command without `--local`.
- The owner's personal data never goes into the repo. Task 8 reads a copy kept outside it, numbers only.
- Commit messages have no `Co-Authored-By`, `Generated with` or `Claude-Session` trailers; the owner forbids them.

**Not in this plan:**
- Purging tombstones, or any change to what sync sends (the owner's choice: deleted rows count).
- A cap on sets per account, on gym and listing tombstones, on exercise preferences, on resolved proposals or on
  Claude's audit rows ("Questions for the owner").
- Splitting imported workouts that are past the per-workout caps (a question for the owner).
- Indexes for the pulls (found while writing; decision 13).
- Any step of `docs/cloudflare-checklist.md` that touches Cloudflare, the phone or claude.ai.

---

## Decisions this plan makes

1. **The numbers live in `DomainLimits.swift`,** with the same names in `server/src/shared/domain-limits.ts`:

   | Constant | Value | Enforced by |
   |---|---|---|
   | `workoutsMax` | 10,000 | trigger `workouts_cap` |
   | `bodyweightsMax` | 20,000 | trigger `bodyweight_cap` (sync and Claude's `log_bodyweight`) |
   | `routinesMax` | 200 | trigger `routines_cap` |
   | `customExercisesMax` | 1,000 | trigger `custom_exercises_cap` |
   | `pendingProposalsMax` | 100 | trigger `proposals_pending_cap` (Claude's `propose_plan_changes`) |
   | `workoutEntriesMax` | 50 | `parseWorkout` (`server/src/sync/workouts.ts`), and the phone's editing |
   | `entrySetsMax` | 50 | the same |

   - The drift test's `toEqual` (`server/test/domain-limits-drift.test.ts:72-74`) fails on any name or value that
     differs. A new case there checks each trigger's number in `0010_account_caps.sql`.
   - Each is written as a bare `= value`. The test's parser (`:21`) skips any other form, such as `: Int = 5`, which
     would pass silently.

2. **The account caps are triggers, as plan 28's are, not a conditional insert.**
   - A push is one `INSERT … SELECT … FROM json_each(?1) … ON CONFLICT … DO UPDATE … RETURNING` for up to 500 rows
     (`server/src/sync/table-sync.ts:20`, `:50`, `:68-83`).
   - "Insert only if under the cap" would skip rows silently. A skipped row gets no ack and stays dirty
     (`table-sync.ts:33-35`), so the phone would push it again on every round: the loop the owner ruled out.
   - `RAISE(ABORT)` fails the whole statement instead, and the phone records the refusal (decision 8).
   - A trigger holds for every writer. Claude's `insertBodyweight` (`server/src/mcp/d1-db.ts:528-536`) inserts
     weigh-ins outside sync.
   - A workout save is one batch (`workouts.ts:144-150`). A `RAISE` in its first statement rolls back the whole batch,
     entries and sets included (probe).

3. **Only new rows count against the cap.**
   - The trigger's condition starts `NOT EXISTS (SELECT 1 FROM <table> WHERE id = NEW.id)`.
   - SQLite runs `BEFORE INSERT` for an upsert row that turns into an update too (plan 28, decision 1; probe), so an
     edit, a deletion or a revival passes at the cap.
   - `AFTER INSERT` runs only for a row actually inserted (probe), so the count never grows on an update.
   - Another account's id is refused with 403 before the statement runs (`table-sync.ts:48`, `:59-66`;
     `workouts.ts:119-121`).

4. **Deleted rows count, through a count the triggers keep: `account_rows (user_id, tbl, n)`.**
   - **Why not `count(*)`:** tombstones count, so no live-rows index helps (0005's `gyms_owner_live` serves live counts
     only, `0005_gyms_photos.sql:20-21`). `bodyweight`, `routines` and `custom_exercises` have no index on `user_id` at
     all (`0002_app_schema.sql:49-60`, `:62-75`, `:305-318`). A `count(*)` reads the whole table (probe: one count
     reports `rows_read` 20,000), and every pushed row runs the trigger, up to 500 times a push.
   - **The cost of `account_rows`:** two primary-key lookups per pushed row (probe: `SEARCH … USING INDEX
     sqlite_autoindex_…`), and one more row written per new row. Edits cost nothing more.
   - **Kept exact:** an `AFTER DELETE` trigger lowers the count, so `n` always equals `count(*)`. Today only an
     account's deletion removes these rows (`server/src/account/delete.ts:31`, by cascade), and the account's
     `account_rows` cascade with it.
   - **Rows from before the migration** are counted by the migration itself (the local dev D1 has some).
   - **At the cap an account stays full.** Deleting frees nothing, because its tombstone stays. The app's words say so
     (decision 8).

5. **Pending proposals are a live count, plan 28's way.**
   - Claude's insert is the only writer, one row at a time (`d1-db.ts:497-510`), and it writes `pending` only
     (`:502-503`).
   - A resolved proposal never turns pending again: `parseResolution` refuses `pending` (`server/src/claude/proposals.ts:48-50`).
   - So a `count(*)` over at most 100 rows, through a new partial index, is enough. The index `proposals_user_pending`
     also serves the app's pull of pending proposals (`proposals.ts:21-26`), which read the whole table until now.
   - Resolving one frees a slot: the owner chose "pending at a time".

6. **The per-workout caps are checked in TypeScript, as the save is parsed** (`workouts.ts:92-103`).
   - A save deletes the workout's entries and writes the ones it carries (`workouts.ts:68-72`, `:146-148`). So the body
     is exactly what the save writes: checking it counts "only what the save writes".
   - A trigger would count once per inserted row, up to 2,500 sets of up to 50 reads each.
   - `pushWorkout` is the only writer of entries and sets (Task 3, Step 1 greps for others).
   - The check runs before the stale check, so a save that is too big hears that first, and nothing is written.
   - A save at both caps (2,500 sets) stays under the 1 MB body limit (`server/src/index.ts:23`, `:49-52`). Task 3
     tests it.

7. **The app allows more than 50 and 50 today, so the phone learns the caps too.**
   - **Nothing caps a workout's size on the phone.** `WorkoutRepository.save` checks nothing
     (`ios/Packages/GymData/Sources/GymData/Repositories/WorkoutRepository.swift:71-79`).
     - Add Set appends with no limit (`ios/Packages/GymCore/Sources/GymCore/Model/Workout+Editing.swift:84-90`, from
       `ios/GymRollins/Features/Workout/WorkoutSession.swift:143`); the button is never disabled
       (`ios/GymRollins/Features/Workout/LoggingView.swift:243-258`).
     - Add exercise appends every picked exercise (`Workout+Editing.swift:111-113`, `WorkoutSession.swift:168-169`).
     - The CSV importers put every row of a workout key into one workout (`ImportSupport.swift:167-188`), and FitNotes
       keys by date, so a whole day is one workout (`FitNotesImporter.swift:80`).
   - **The bounded paths stay far under 50 and 50.** A routine holds at most 20 exercises (`DomainLimits.swift:9`) of
     at most 10 working sets (`Plan/PlanChange.swift:143`), with 2 warm-ups generated (`WarmupGenerator.swift:8`), or
     up to 5 on Today (`ios/GymRollins/Features/Today/TodaySetEdits.swift:9-10`). A shared link holds at most 20
     exercises of 1–10 sets.
   - **The owner's data** averages 5.6 exercises and 3.2 sets per exercise (836 entries and 2,685 sets in 148 workouts,
     plan 30's server-move check). Task 8 reads the largest values from the same copy.
   - **So the owner's 50 and 50 stay,** and the phone stops there (Task 5): Add Set, warm-ups and Add exercise stop at
     the cap, and their buttons are disabled.
   - **Imports can still make a bigger workout.** It stays on the phone, and sync refuses it with the cap's words.
     Splitting such workouts at import is a question for the owner.

8. **The error: 422, the cap's code, and the app's words, as the gym caps** (`server/src/http/errors.ts:29-50`).
   - **Codes:** `too_many_workouts`, `too_many_body_weights`, `too_many_routines`, `too_many_custom_exercises` (the
     triggers), `too_many_workout_exercises`, `too_many_exercise_sets` (the save). `too_many_proposals` is raised only
     under Claude's insert (decision 10).
   - **Words:** "You've reached the limit of 20,000 weigh-ins on one account, deleted ones included. This one stays on
     this iPhone." The numbers come from `DomainLimits`, so they can't drift. They live in `server/src/sync/caps.ts`.
   - **How it reaches the app:**
     - `mappingRejections` turns any 422 into `SyncRecordRejected(code, message)` with the server's words
       (`ios/Packages/GymSync/Sources/GymSync/ApiSyncTransport.swift:156-166`).
     - The engine records it per row: a refused workout at `SyncEngine+Rounds.swift:66-70`, a refused batch row by row
       at `:96-110`, through `recordRejection` (`:139-143`).
     - The row stays dirty, and that edit isn't pushed again (`ios/Packages/GymData/Sources/GymData/Sync/SyncStore+Ownership.swift:66-68`).
       A later edit tries once more.
     - Account lists it under "N items couldn't sync" (`ios/GymRollins/Features/Account/AccountView.swift:102-124`).
     - That is how `too_many_gyms` shows today. No GymSync code changes; Task 6 pins the path with tests.
   - **A batch with a new row past the cap** is refused whole, then sent again row by row (`SyncEngine+Rounds.swift:96-110`).
     Edits in it go through; the new rows are refused, once each, then parked.

9. **Account shows identical refusals as one line.** At a cap every refused row carries the same words, and a Health
   import past 20,000 would list thousands of identical rows. `SyncStatusText.failureLines` groups them by kind and
   words ("Weigh-in · 300"). The footer "Edit the item to try again." becomes "They stay on this iPhone. Editing one
   tries again.", which holds for a cap too. The stored `SyncFailure` doesn't change.

10. **Claude's refusals are words for Claude.** `runAudited` shows any error that isn't a `ToolError` as the internal
    error (`server/src/mcp/tools/register.ts:251-257`). So `insertProposal` and `insertBodyweight` turn their cap's
    `RAISE` into a `ToolError` with plain words, and the call is audited as failed.

11. **D1's limits.**
    - No new bound values: the triggers bind nothing, and the push still binds two.
    - No `LIKE` or `GLOB`; the schema test's 50-byte check (`server/test/schema.test.ts:45-56`) covers the new
      migration anyway.
    - A batch is one transaction (decision 2).

12. **Tests at the exact number seed rows straight into D1,** with one `INSERT … SELECT … FROM json_each(?2)`. The
    seeded rows go through the same triggers, so `account_rows` counts them (probe: 19,998 rows in about 130 ms). Every
    other seeded row is a tombstone, because deleted rows count. Pushes then take the account to N-1, N and N+1.

13. **Found while writing: the pulls read whole tables.** `bodyweight`, `routines` and `custom_exercises` have no index
    that starts with `user_id`, and `workouts` has only `(user_id, started_at DESC)` (`0002_app_schema.sql:269`). So
    every pull of them scans, and rows read grow with every account's rows. Not changed here, apart from the proposals
    index: a later plan, before many accounts exist.

### Facts checked for this plan

Checked on 2026-11-08 against `699f6a4`. Every probe lived in a scratch folder outside the repo and was never committed.

| Check | Result |
|---|---|
| `sqlite3` 3.51.0, a scratch table with logging triggers, a three-row upsert (`a`, `b`, `a`) and an update | `BEFORE INSERT` runs for every row, the upsert's update included, and sees `exists=1` for it; `AFTER INSERT` runs for `a` and `b` only; a skipped update (`WHERE false`) runs no update trigger; a statement failing on its second row rolls back the first row's count |
| Same, deleting the user | the cascade runs each child's `AFTER DELETE`; the count rows go with the user |
| workerd, through the server's Vitest with a scratch config: the counter triggers on `bodyweight` with a cap of 3 | an edit and a tombstone at the cap pass; a new row fails with `D1_ERROR: too_many_body_weights: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_TRIGGER)`; in a batch the earlier `UPDATE` is rolled back; another account isn't counted |
| workerd, a cap trigger on `workouts` in a two-statement batch | `D1_ERROR: too_many_workouts: …`; the account keeps 1 workout |
| workerd, `applyD1Migrations` with this plan's `0010_account_caps.sql` | applies; 18 triggers; the 200th routine is stored and the 201st refused; an edit at the cap passes; the 101st pending proposal fails with `too_many_proposals`; `DELETE /v1/account` leaves 0 `account_rows` |
| workerd, query plans | `SEARCH account_rows USING INDEX sqlite_autoindex_account_rows_1 (user_id=? AND tbl=?)`; `SEARCH custom_exercises USING COVERING INDEX sqlite_autoindex_custom_exercises_1 (id=?)`; pending count and pull both `SEARCH proposals USING COVERING INDEX proposals_user_pending (user_id=?)` |
| workerd, seeding | 19,998 weigh-ins (half tombstones) through `json_each` in about 130 ms; one `count(*)` of them reports `rows_read` 20,000; 200 such counts take about 300 ms |
| `sqlite3`, 0001–0009 with rows already stored, then 0010 | `account_rows`: bodyweight 2 (one of them deleted), workouts 1, custom_exercises 1 |
| `sqlite3`, 10,000 sets in 200 entries | about 276 bytes a set, its indexes and its share of the entry included |
| `cd server && npx vitest run` at `699f6a4` | `Test Files  43 passed (43)`, `Tests  602 passed (602)` |
| Tasks 1–4's server steps, applied from this plan's text to a scratch copy of `server/` (with `fixtures/` and the two Swift files the drift test reads) | after Task 2 `Test Files  44 passed (44)`, `Tests  626 passed (626)`; after Task 3 `Tests  630 passed (630)`; after Task 4 `Test Files  45 passed (45)`, `Tests  635 passed (635)`; `tsc --noEmit` clean each time |
| Tasks 1, 5 and 6's Swift package steps, applied to a scratch copy of `ios/Packages` | GymCore `--filter 'DomainLimitsTests\|WorkoutEditingTests'`: 17 tests in 2 suites passed; the whole of GymCore counts 535 tests in 64 suites (the ones reading the app's bundled `exercises.json` can't pass in the copy, which lacks it); GymSync `ApiSyncTransportCapTests` and `SyncEngineCapTests` 3 tests in 2 suites passed; `GymSyncTests` 217 tests in 28 suites passed |
| Task 6's `failureLines`, compiled alone with stand-ins for `SyncEntity` and `SyncFailure` | 300 weigh-ins and 1 routine give `["Weigh-in · 300", "Routine"]` |
| D1's limits (developers.cloudflare.com/d1/platform/limits and /pricing, 2026-11-08) | a database holds 500 MB on the free plan, 10 GB on Workers Paid; 100 bound parameters; 50-byte `LIKE`/`GLOB` patterns; free: 5 million rows read and 100,000 written a day; "Indexes will add an additional written row" |

## File map

| File | Change | Task |
|---|---|---|
| `ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift` | The seven caps | 1 |
| `ios/Packages/GymCore/Tests/GymCoreTests/DomainLimitsTests.swift` | Their values | 1 |
| `server/src/shared/domain-limits.ts` | The copy | 1 |
| `server/test/domain-limits-drift.test.ts` | 47 constants (Task 1); the trigger numbers (Task 2) | 1, 2 |
| `server/migrations/0010_account_caps.sql` | Create: `account_rows`, the account caps, the pending-proposals cap and index | 2 |
| `server/src/sync/caps.ts` | Create: the codes' words (Tasks 2–4) | 2, 3, 4 |
| `server/src/http/errors.ts` | The new trigger codes | 2 |
| `server/test/cap-fixtures.ts` | Create: `seedRows`, `countOf` | 2 |
| `server/test/account-caps.test.ts` | Create: the four account caps | 2 |
| `server/test/schema.test.ts`, `server/test/limits.test.ts` | Query plans; requests that arrive together | 2 |
| `scripts/test-sync-integration.sh` | `account_rows` in the deletion check | 2 |
| `server/src/sync/workouts.ts`, `server/test/sync-workouts.test.ts` | The size of one workout | 3 |
| `server/src/mcp/d1-db.ts`, `server/test/claude-caps.test.ts` (create) | Claude's refusals | 4 |
| `ios/Packages/GymCore/Sources/GymCore/Model/Workout+Editing.swift`, `Tests/GymCoreTests/WorkoutEditingTests.swift` | The phone stops at 50 and 50 | 5 |
| `ios/GymRollins/Features/Workout/ExerciseScreenModel.swift`, `LoggingView.swift`, `WorkoutOverviewView.swift`, `ios/GymRollinsTests/WorkoutSessionTests.swift` | Add Set and Add exercise at the cap | 5 |
| `ios/Packages/GymSync/Tests/GymSyncTests/ApiSyncTransportCapTests.swift`, `SyncEngineCapTests.swift` (create), `FakeTransport.swift` | The caps' path through GymSync | 6 |
| `ios/GymRollins/Features/Sync/SyncStatusText.swift`, `ios/GymRollins/Features/Account/AccountView.swift`, `ios/GymRollinsTests/SyncSupportTests.swift` | One line per kind and reason | 6 |
| `docs/cloudflare-checklist.md`, `docs/release-readiness.md`, `server/README.md` | The caps built; what is open | 7 |
| this plan | `## Outcome` | 8 |

## How to run things

```bash
(cd server && npx vitest run && npx tsc --noEmit)          # the server; ignore the punycode DEP0040 warning
(cd server && npx vitest run test/account-caps.test.ts)    # one file
(cd ios/Packages/GymCore && swift test --filter DomainLimitsTests)
(cd ios/Packages/GymSync && swift test --filter GymSyncTests)
scripts/test-sync-integration.sh                           # GymSyncIntegrationTests on a throwaway Worker (:8788)
```

- Vitest ends with `Test Files  N passed (N)` and `Tests  M passed (M)`. `swift test` prints `Test run with N tests in M
  suites passed`.
- **Counts.** Each step names the count this plan expects from the base: the server at `Test Files  43 passed (43)`,
  `Tests  602 passed (602)`; GymCore 533 tests in 64 suites, GymSync 214 in 26 (plan 30's Outcome). If Task 1, Step 1
  finds other base numbers, add this plan's new tests to those instead, and record both in the Outcome.
- **One app test run** (from `ios/`, one `xcodebuild` at a time; the Mac runs short on memory):

  ```bash
  xcodegen generate --quiet
  xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' \
    -only-testing:GymRollinsTests/SyncStatusTextTests \
    -resultBundlePath build/TestResults-one-$(date +%s).xcresult -quiet
  xcrun xcresulttool get test-results summary --path "$(ls -td build/TestResults-one-*.xcresult | head -1)"
  ```

- **Reviews.** Each task ends with one, by a fresh reviewer:
  1. spec and plan compliance (**code-reviewer**),
  2. quality (**typescript-reviewer** for server code, **code-reviewer** for Swift),
  3. **security-reviewer** where the task says so.

  Fix CRITICAL and HIGH findings in their own commits, with a test, and record them in the task as "added after
  review", as plan 26 did.

---

### Task 1: The numbers, in `DomainLimits` and the server's copy

**Files:**
- Modify: `ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift`, `server/src/shared/domain-limits.ts`,
  `server/test/domain-limits-drift.test.ts`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/DomainLimitsTests.swift`, `server/test/domain-limits-drift.test.ts`

- [ ] **Step 1: Check the start**

Run:

```bash
git status --short
git rev-parse --short HEAD
grep -c '^## Outcome' docs/plans/2026-11-08-plan-30-remove-supabase.md
ls server/migrations | tail -1
(cd server && npx vitest run 2>&1 | grep -E 'Test Files|Tests ')
```

Expected:
- `git status` lists nothing tracked (an untracked `supabase/` folder may be on disk: plan 30's leftovers, never read).
- A sha: this plan's base. Write it at the top of the Outcome.
- `1`: plan 30 is built.
- `0009_connect_opener.sql`: `0010` is free. If another migration took `0010`, number this plan's the next free one,
  and change every `0010` in this plan with it.
- `Test Files  43 passed (43)`, `Tests  602 passed (602)`.

- [ ] **Step 2: Write the failing tests**

In `ios/Packages/GymCore/Tests/GymCoreTests/DomainLimitsTests.swift`, add inside `DomainLimitsTests`, after
`routineNameAndExerciseCount`:

```swift
    /// The server's storage caps read these numbers (server/test/domain-limits-drift.test.ts checks its copy and its
    /// triggers). Deleted rows count toward the account caps.
    @Test func storageCaps() {
        #expect(DomainLimits.workoutsMax == 10_000)
        #expect(DomainLimits.bodyweightsMax == 20_000)
        #expect(DomainLimits.routinesMax == 200)
        #expect(DomainLimits.customExercisesMax == 1_000)
        #expect(DomainLimits.pendingProposalsMax == 100)
        #expect(DomainLimits.workoutEntriesMax == 50)
        #expect(DomainLimits.entrySetsMax == 50)
    }
```

In `server/test/domain-limits-drift.test.ts`, replace

```ts
    expect(Object.keys(swift).length).toBeGreaterThanOrEqual(40)
```

with

```ts
    expect(Object.keys(swift).length).toBeGreaterThanOrEqual(47)
```

- [ ] **Step 3: Run them to see them fail**

Run: `(cd ios/Packages/GymCore && swift test --filter DomainLimitsTests)`
Expected: the build fails with `type 'DomainLimits' has no member 'workoutsMax'` (and the six others).

Run: `(cd server && npx vitest run test/domain-limits-drift.test.ts)`
Expected: FAIL in "finds the Swift constants": `expected 40 to be greater than or equal to 47`.

- [ ] **Step 4: Add the caps to `DomainLimits.swift`**

Replace the doc comment's first two lines

```swift
/// Value limits shared by local validation and the database CHECK constraints
/// (server/migrations/0002_app_schema.sql, 0005_gyms_photos.sql). Anything saved locally must fit these, or the row
```

with

```swift
/// Value limits shared by local validation and the database CHECK constraints and caps
/// (server/migrations/0002_app_schema.sql, 0005_gyms_photos.sql, 0010_account_caps.sql). Anything saved locally must
/// fit these, or the row
```

and after `public static let gymActiveListingsMax = 300`, add:

```swift
    // Storage per account, deleted rows included (server/migrations/0010_account_caps.sql)
    public static let workoutsMax = 10_000
    public static let bodyweightsMax = 20_000
    public static let routinesMax = 200
    public static let customExercisesMax = 1_000
    public static let pendingProposalsMax = 100
    // One workout, as each save stores it (server/src/sync/workouts.ts)
    public static let workoutEntriesMax = 50
    public static let entrySetsMax = 50
```

Each is a bare `= value`, the only form the drift test reads (decision 1).

Run: `(cd ios/Packages/GymCore && swift test --filter DomainLimitsTests)`
Expected: `Test run with 7 tests in 1 suite passed`.

Run: `(cd server && npx vitest run test/domain-limits-drift.test.ts)`
Expected: FAIL in "has every Swift limit in the server": the seven new names are missing from the server's copy.

- [ ] **Step 5: Add them to the server's copy**

In `server/src/shared/domain-limits.ts`, after `gymActiveListingsMax: 300,`, add:

```ts
  // Storage per account, deleted rows included (migrations/0010_account_caps.sql)
  workoutsMax: 10_000,
  bodyweightsMax: 20_000,
  routinesMax: 200,
  customExercisesMax: 1_000,
  pendingProposalsMax: 100,
  // One workout, as each save stores it (src/sync/workouts.ts)
  workoutEntriesMax: 50,
  entrySetsMax: 50,
```

Run: `(cd server && npx vitest run test/domain-limits-drift.test.ts && npx tsc --noEmit)`
Expected: `Tests  5 passed (5)`; `tsc` prints nothing.

Run: `(cd ios/Packages/GymCore && swift test)`
Expected: `Test run with 534 tests in 64 suites passed`.

- [ ] **Step 6: Commit**

```bash
git add ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift \
  ios/Packages/GymCore/Tests/GymCoreTests/DomainLimitsTests.swift server/src/shared/domain-limits.ts \
  server/test/domain-limits-drift.test.ts
git commit -m "feat: the storage caps' numbers in DomainLimits and the server's copy"
```

- [ ] **Step 7: Review**

Ask **code-reviewer**:
- the seven names and values against decision 1;
- the drift test fails when one changes: `workoutsMax = 10_001` in a scratch copy of `DomainLimits.swift`, never
  committed.

---

### Task 2: The account caps in D1

`0010_account_caps.sql` holds all of this plan's SQL: the count table, the four account caps, and the pending
proposals' cap and index. Claude's side of the proposals cap is Task 4.

**Files:**
- Create: `server/migrations/0010_account_caps.sql`, `server/src/sync/caps.ts`, `server/test/cap-fixtures.ts`,
  `server/test/account-caps.test.ts`
- Modify: `server/src/http/errors.ts`, `server/test/domain-limits-drift.test.ts`, `server/test/schema.test.ts`,
  `server/test/limits.test.ts`, `scripts/test-sync-integration.sh`

- [ ] **Step 1: Write the fixtures and the failing tests**

`server/test/cap-fixtures.ts`:

```ts
import { env } from 'cloudflare:workers'
import { expect } from 'vitest'

// Accounts near a storage cap (plan 31): rows written straight to D1, so a test can start a row or two short of
// 20,000. They go through the same triggers as a push, so the account's count (account_rows) includes them.

export type CappedTable = 'workouts' | 'bodyweight' | 'routines' | 'custom_exercises'

const T = '2026-11-07T10:00:00.000000Z'

/** What each table needs besides id, user_id and deleted_at: its columns and their SQL values (?3 is T). */
const FILL: Readonly<Record<CappedTable, { readonly columns: string; readonly values: string }>> = {
  workouts: { columns: 'started_at, name, client_updated_at, updated_at', values: "?3, 'Seeded', ?3, ?3" },
  bodyweight: { columns: 'measured_at, w_kg, client_updated_at, updated_at', values: '?3, 80, ?3, ?3' },
  routines: { columns: 'name, client_updated_at, updated_at', values: "'Seeded', ?3, ?3" },
  custom_exercises: {
    columns: 'n, bp, eq, tg, client_updated_at, updated_at',
    values: "'Seeded', 'legs', 'machine', 'quads', ?3, ?3",
  },
}

const newId = (table: CappedTable) =>
  table === 'custom_exercises' ? `custom-${crypto.randomUUID()}` : crypto.randomUUID()

/** `count` rows of `table` for the account, every other one deleted: deleted rows count toward the caps too. */
export async function seedRows(table: CappedTable, userId: string, count: number): Promise<void> {
  const { columns, values } = FILL[table]
  const ids = Array.from({ length: count }, () => newId(table))
  await env.DB.prepare(
    `INSERT INTO ${table} (id, user_id, ${columns}, deleted_at) ` +
      `SELECT value, ?1, ${values}, CASE WHEN key % 2 = 1 THEN ?3 END FROM json_each(?2)`,
  ).bind(userId, JSON.stringify(ids), T).run()
}

/** The account's rows in `table`, deleted ones included; fails when the count the triggers keep disagrees. */
export async function countOf(table: CappedTable, userId: string): Promise<number> {
  const row = (await env.DB.prepare(
    `SELECT (SELECT count(*) FROM ${table} WHERE user_id = ?1) AS stored, ` +
      '(SELECT n FROM account_rows WHERE user_id = ?1 AND tbl = ?2) AS kept',
  ).bind(userId, table).first<{ stored: number; kept: number | null }>())!
  expect(row.kept ?? 0, `account_rows for ${table}`).toBe(row.stored)
  return row.stored
}
```

`server/test/account-caps.test.ts`:

```ts
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { DomainLimits } from '../src/shared/domain-limits.ts'
import { ACCOUNT_CAPS } from '../src/sync/caps.ts'
import { type CappedTable, countOf, seedRows } from './cap-fixtures.ts'
import { insertUser } from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'
import { KEY, type Row, SAMPLES, T1, T2, workoutSample } from './samples.ts'

// Each account cap at its exact number (plan 31): N-1 and N are stored, N+1 is refused with its code and the app's
// words, and nothing of the refused push is stored. A stored row can still be edited, deleted and brought back at the
// cap. A deletion frees nothing, because its tombstone counts. Another account's rows don't count.

const T3 = '2026-11-07T12:00:00.000000Z'

async function refusedWith(res: Response, code: string): Promise<void> {
  expect(res.status).toBe(422)
  expect(await res.json()).toEqual({ error: { code, message: ACCOUNT_CAPS[code] } })
}

describe('the words', () => {
  it('say what the cap is, that deleted rows count, and that the row stays on the phone', () => {
    expect(ACCOUNT_CAPS.too_many_body_weights).toBe(
      "You've reached the limit of 20,000 weigh-ins on one account, deleted ones included. " +
        'This one stays on this iPhone.',
    )
    expect(Object.keys(ACCOUNT_CAPS).sort()).toEqual([
      'too_many_body_weights', 'too_many_custom_exercises', 'too_many_proposals', 'too_many_routines',
      'too_many_workouts',
    ])
  })
})

interface Synced {
  readonly entity: string
  readonly table: CappedTable
  readonly max: number
  readonly code: string
}

const SYNCED: Synced[] = [
  { entity: 'bodyweight', table: 'bodyweight', max: DomainLimits.bodyweightsMax, code: 'too_many_body_weights' },
  { entity: 'routines', table: 'routines', max: DomainLimits.routinesMax, code: 'too_many_routines' },
  {
    entity: 'custom-exercises', table: 'custom_exercises', max: DomainLimits.customExercisesMax,
    code: 'too_many_custom_exercises',
  },
]

describe.each(SYNCED)('$entity', ({ entity, table, max, code }) => {
  const push = (token: string, rows: Row[]) => request('POST', `/v1/sync/${entity}`, { token, body: { rows } })
  const fresh = () => SAMPLES[entity]()

  /** The stored row's edit time, or undefined when the row isn't stored. */
  async function storedEdit(row: Row, userId: string): Promise<string | undefined> {
    const stored = await env.DB.prepare(`SELECT client_updated_at FROM ${table} WHERE id = ?1`)
      .bind(KEY[entity](row, userId)).first<{ client_updated_at: string }>()
    return stored?.client_updated_at
  }

  it('holds the cap, deleted rows included: N-1 and N are stored, N+1 is refused', async () => {
    const { token, userId } = await signUp()
    await seedRows(table, userId, max - 2)
    expect((await push(token, [fresh()])).status).toBe(200)
    expect(await countOf(table, userId)).toBe(max - 1)
    expect((await push(token, [fresh()])).status).toBe(200)
    expect(await countOf(table, userId)).toBe(max)
    const last = fresh()
    await refusedWith(await push(token, [last]), code)
    expect(await countOf(table, userId)).toBe(max)
    expect(await storedEdit(last, userId)).toBeUndefined()
  })

  it('refuses a push holding a new row past the cap whole, and takes an edit, a deletion and a revival at the cap',
    async () => {
      const { token, userId } = await signUp()
      await seedRows(table, userId, max - 1)
      const row = fresh()
      expect((await push(token, [row])).status).toBe(200)
      const edit = { ...row, client_updated_at: T2 }
      await refusedWith(await push(token, [edit, fresh()]), code)
      expect(await storedEdit(row, userId)).toBe(T1)
      expect((await push(token, [edit])).status).toBe(200)
      expect((await push(token, [{ ...edit, deleted_at: T2 }])).status).toBe(200)
      expect((await push(token, [{ ...edit, client_updated_at: T3, deleted_at: null }])).status).toBe(200)
      expect(await storedEdit(row, userId)).toBe(T3)
      await refusedWith(await push(token, [fresh()]), code)
      expect(await countOf(table, userId)).toBe(max)
    })

  it('counts a deletion the server never had as a new row', async () => {
    const { token, userId } = await signUp()
    await seedRows(table, userId, max)
    await refusedWith(await push(token, [{ ...fresh(), deleted_at: T1 }]), code)
  })

  it("doesn't count another account's rows", async () => {
    await seedRows(table, await insertUser(), max)
    const { token, userId } = await signUp()
    expect((await push(token, [fresh()])).status).toBe(200)
    expect(await countOf(table, userId)).toBe(1)
  })
})

describe('workouts', () => {
  const max = DomainLimits.workoutsMax
  const save = (token: string, workout: Row) => request('POST', '/v1/sync/workouts', { token, body: workout })
  const entriesOf = async (userId: string) => (await env.DB.prepare(
    'SELECT count(*) AS n FROM workout_entries WHERE user_id = ?1',
  ).bind(userId).first<{ n: number }>())!.n

  it('holds 10,000, deleted ones included: N-1 and N are saved, N+1 is refused and none of its entries stored',
    async () => {
      const { token, userId } = await signUp()
      await seedRows('workouts', userId, max - 2)
      expect((await save(token, workoutSample())).status).toBe(200)
      expect(await countOf('workouts', userId)).toBe(max - 1)
      expect((await save(token, workoutSample())).status).toBe(200)
      expect(await countOf('workouts', userId)).toBe(max)
      await refusedWith(await save(token, workoutSample()), 'too_many_workouts')
      expect(await countOf('workouts', userId)).toBe(max)
      expect(await entriesOf(userId)).toBe(2)
    })

  it('saves an edit and a deletion of a stored workout at the cap, and the deletion frees nothing', async () => {
    const { token, userId } = await signUp()
    await seedRows('workouts', userId, max - 1)
    const w = workoutSample()
    const first = await (await save(token, w)).json<{ status: string; updated_at: string }>()
    const edited = await save(token, { ...w, name: 'Pull', client_updated_at: T2, base_updated_at: first.updated_at })
    const second = await edited.json<{ status: string; updated_at: string }>()
    expect(second.status).toBe('ok')
    const deleted = await save(token, {
      ...w, deleted_at: T3, client_updated_at: T3, base_updated_at: second.updated_at,
    })
    expect(await deleted.json()).toMatchObject({ status: 'ok' })
    await refusedWith(await save(token, workoutSample()), 'too_many_workouts')
    expect(await countOf('workouts', userId)).toBe(max)
  })

  it("doesn't count another account's workouts", async () => {
    await seedRows('workouts', await insertUser(), max)
    const { token, userId } = await signUp()
    expect((await save(token, workoutSample())).status).toBe(200)
    expect(await countOf('workouts', userId)).toBe(1)
  })
})

describe('the counts', () => {
  it('go with the account when it is deleted', async () => {
    const { token, userId } = await signUp()
    for (const table of ['workouts', 'bodyweight', 'routines', 'custom_exercises'] as const) {
      await seedRows(table, userId, 3)
    }
    expect((await request('DELETE', '/v1/account', { token })).status).toBe(204)
    const left = await env.DB.prepare('SELECT count(*) AS n FROM account_rows WHERE user_id = ?1').bind(userId)
      .first<{ n: number }>()
    expect(left!.n).toBe(0)
  })
})
```

In `server/test/domain-limits-drift.test.ts`, add to the imports:

```ts
import accountCaps from '../migrations/0010_account_caps.sql?raw'
```

and inside `describe('domain limits', …)`, after "keeps the cap triggers at the same numbers":

```ts
  it('keeps the account caps in their triggers at the same numbers', () => {
    const caps = [
      ['workouts', DomainLimits.workoutsMax, 'too_many_workouts'],
      ['bodyweight', DomainLimits.bodyweightsMax, 'too_many_body_weights'],
      ['routines', DomainLimits.routinesMax, 'too_many_routines'],
      ['custom_exercises', DomainLimits.customExercisesMax, 'too_many_custom_exercises'],
    ] as const
    for (const [table, max, code] of caps) {
      const trigger = `tbl = '${table}'), 0) >= ${max}\nBEGIN\n  SELECT RAISE(ABORT, '${code}');`
      expect(accountCaps.split(trigger).length - 1, code).toBe(1)
    }
    const pending = `status = 'pending') >= ${DomainLimits.pendingProposalsMax}\nBEGIN\n` +
      "  SELECT RAISE(ABORT, 'too_many_proposals');"
    expect(accountCaps.split(pending).length - 1).toBe(1)
  })
```

In `server/test/schema.test.ts`, add inside `describe('the D1 schema', …)`, after the `it.each` on the gym cap
triggers:

```ts
  it.each(['workouts', 'bodyweight', 'routines', 'custom_exercises'])(
    "finds %s_cap's row and the account's count through primary keys, never by counting",
    async (table) => {
      const { sql } = (await env.DB.prepare("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?1")
        .bind(`${table}_cap`).first<{ sql: string }>())!
      expect(sql).not.toMatch(/count\(/)
      const lookups = [...sql.matchAll(/\((SELECT (?:1|n) FROM \w+ WHERE [^)]*)\)/g)].map((m) => m[1]!)
      expect(lookups, sql).toHaveLength(2)
      for (const lookup of lookups) {
        const query = lookup.replace(/NEW\.(?:user_)?id/g, '?1')
        const plan = await env.DB.prepare(`EXPLAIN QUERY PLAN ${query}`).bind(crypto.randomUUID())
          .all<{ detail: string }>()
        expect(plan.results.map((r) => r.detail).join('\n'), query)
          .toMatch(/^SEARCH \w+ USING (COVERING )?INDEX sqlite_autoindex_\w+_1 \(/)
      }
    },
  )

  it("counts an account's pending proposals in proposals_pending_cap through proposals_user_pending", async () => {
    const { sql } = (await env.DB.prepare("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?1")
      .bind('proposals_pending_cap').first<{ sql: string }>())!
    const counted = /\(SELECT count\(\*\) FROM (\w+ WHERE [^)]*)\)/.exec(sql)
    expect(counted, sql).not.toBeNull()
    const query = `SELECT count(*) FROM ${counted![1]}`.replaceAll('NEW.user_id', '?1')
    const plan = await env.DB.prepare(`EXPLAIN QUERY PLAN ${query}`).bind(crypto.randomUUID())
      .all<{ detail: string }>()
    expect(plan.results.map((r) => r.detail).join('\n'), query)
      .toMatch(/USING (COVERING )?INDEX proposals_user_pending\b/)
  })
```

In `server/test/limits.test.ts`, add to the imports:

```ts
import { countOf, seedRows } from './cap-fixtures.ts'
```

change `import { appUUID, T1 } from './samples.ts'` to `import { appUUID, SAMPLES, T1 } from './samples.ts'`, and add
inside `describe('limits, with requests that arrive together', …)`, after "keep 100 live private gyms":

```ts
  it('keep 200 routines, deleted ones included', async () => {
    const { token, userId } = await signUp()
    await seedRows('routines', userId, 196)
    const answers = await together(6, () => request('POST', '/v1/sync/routines', {
      token, body: { rows: [SAMPLES.routines()] },
    }))
    expect(tally(answers)).toEqual({ 200: 4, 422: 2 })
    expect(await countOf('routines', userId)).toBe(200)
  })
```

- [ ] **Step 2: Run them to see them fail**

Run:

```bash
cd server && npx vitest run test/account-caps.test.ts test/domain-limits-drift.test.ts test/schema.test.ts \
  test/limits.test.ts
```

Expected: FAIL. `account-caps.test.ts` can't load `../src/sync/caps.ts`; the drift test can't load
`0010_account_caps.sql?raw`; the new schema cases find no trigger; the new limits case fails on
`no such table: account_rows`.

- [ ] **Step 3: Write `server/migrations/0010_account_caps.sql`**

```sql
-- Plan 31: storage caps per account (docs/plans/2026-11-08-plan-31-account-caps.md). The numbers are DomainLimits'
-- (ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift); test/domain-limits-drift.test.ts checks each one here.

-- How many rows each account holds in the four capped tables, deleted rows included. A deletion keeps its row as a
-- tombstone (deleted_at), so it still counts, and deleting frees nothing. The triggers below keep the count, so a cap
-- reads one row. A count(*) would read every row the account ever had, for every pushed row: no live-rows index can
-- serve it, and these tables have no index on user_id (a count reads the whole table).
CREATE TABLE account_rows (
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  tbl TEXT NOT NULL CHECK (tbl IN ('workouts','bodyweight','routines','custom_exercises')),
  n INTEGER NOT NULL,
  PRIMARY KEY (user_id, tbl)
);
INSERT INTO account_rows (user_id, tbl, n) SELECT user_id, 'workouts', count(*) FROM workouts GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n) SELECT user_id, 'bodyweight', count(*) FROM bodyweight GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n) SELECT user_id, 'routines', count(*) FROM routines GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n)
  SELECT user_id, 'custom_exercises', count(*) FROM custom_exercises GROUP BY user_id;

-- Per table: <table>_cap refuses a new row once the account holds the cap; <table>_counted and <table>_uncounted keep
-- the count.
-- - A row is new when its id isn't stored yet. SQLite runs BEFORE INSERT for an upsert's row that turns into an
--   update too, so the id check is what lets an edit, a deletion or a revival through at the cap.
-- - AFTER INSERT runs only for a row actually inserted, never for an upsert's update.
-- - RAISE fails the whole statement, and the whole batch around it (a workout save). The server answers 422 with the
--   message as the code (src/http/errors.ts).
-- - Only an account's deletion removes these rows today, and the count goes with the account (ON DELETE CASCADE).
CREATE TRIGGER workouts_cap BEFORE INSERT ON workouts
  WHEN NOT EXISTS (SELECT 1 FROM workouts WHERE id = NEW.id)
    AND coalesce((SELECT n FROM account_rows WHERE user_id = NEW.user_id AND tbl = 'workouts'), 0) >= 10000
BEGIN
  SELECT RAISE(ABORT, 'too_many_workouts');
END;
CREATE TRIGGER workouts_counted AFTER INSERT ON workouts
BEGIN
  INSERT INTO account_rows (user_id, tbl, n) VALUES (NEW.user_id, 'workouts', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER workouts_uncounted AFTER DELETE ON workouts
BEGIN
  UPDATE account_rows SET n = n - 1 WHERE user_id = OLD.user_id AND tbl = 'workouts';
END;
CREATE TRIGGER bodyweight_cap BEFORE INSERT ON bodyweight
  WHEN NOT EXISTS (SELECT 1 FROM bodyweight WHERE id = NEW.id)
    AND coalesce((SELECT n FROM account_rows WHERE user_id = NEW.user_id AND tbl = 'bodyweight'), 0) >= 20000
BEGIN
  SELECT RAISE(ABORT, 'too_many_body_weights');
END;
CREATE TRIGGER bodyweight_counted AFTER INSERT ON bodyweight
BEGIN
  INSERT INTO account_rows (user_id, tbl, n) VALUES (NEW.user_id, 'bodyweight', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER bodyweight_uncounted AFTER DELETE ON bodyweight
BEGIN
  UPDATE account_rows SET n = n - 1 WHERE user_id = OLD.user_id AND tbl = 'bodyweight';
END;
CREATE TRIGGER routines_cap BEFORE INSERT ON routines
  WHEN NOT EXISTS (SELECT 1 FROM routines WHERE id = NEW.id)
    AND coalesce((SELECT n FROM account_rows WHERE user_id = NEW.user_id AND tbl = 'routines'), 0) >= 200
BEGIN
  SELECT RAISE(ABORT, 'too_many_routines');
END;
CREATE TRIGGER routines_counted AFTER INSERT ON routines
BEGIN
  INSERT INTO account_rows (user_id, tbl, n) VALUES (NEW.user_id, 'routines', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER routines_uncounted AFTER DELETE ON routines
BEGIN
  UPDATE account_rows SET n = n - 1 WHERE user_id = OLD.user_id AND tbl = 'routines';
END;
CREATE TRIGGER custom_exercises_cap BEFORE INSERT ON custom_exercises
  WHEN NOT EXISTS (SELECT 1 FROM custom_exercises WHERE id = NEW.id)
    AND coalesce((SELECT n FROM account_rows WHERE user_id = NEW.user_id AND tbl = 'custom_exercises'), 0) >= 1000
BEGIN
  SELECT RAISE(ABORT, 'too_many_custom_exercises');
END;
CREATE TRIGGER custom_exercises_counted AFTER INSERT ON custom_exercises
BEGIN
  INSERT INTO account_rows (user_id, tbl, n) VALUES (NEW.user_id, 'custom_exercises', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER custom_exercises_uncounted AFTER DELETE ON custom_exercises
BEGIN
  UPDATE account_rows SET n = n - 1 WHERE user_id = OLD.user_id AND tbl = 'custom_exercises';
END;

-- At most 100 proposals waiting for the owner (pending) per account. Claude's insert is the only writer
-- (src/mcp/d1-db.ts, insertProposal), one row at a time, and a resolved proposal never turns pending again
-- (src/claude/proposals.ts refuses it), so a live count is enough: at most 100 rows, read through this index, which
-- the app's pull of pending proposals uses too.
CREATE INDEX proposals_user_pending ON proposals (user_id, created_at, id) WHERE status = 'pending';
CREATE TRIGGER proposals_pending_cap BEFORE INSERT ON proposals
  WHEN NEW.status = 'pending'
    AND (SELECT count(*) FROM proposals WHERE user_id = NEW.user_id AND status = 'pending') >= 100
BEGIN
  SELECT RAISE(ABORT, 'too_many_proposals');
END;
```

The numbers are written without separators (`10000`): the drift test builds the same text from `DomainLimits`.

- [ ] **Step 4: Write `server/src/sync/caps.ts`**

```ts
import { DomainLimits } from '../shared/domain-limits.ts'

// The words for the storage caps (plan 31). The app shows a refusal's message in Account › "items couldn't sync",
// beside the row it keeps on the phone, so each says what happened and that nothing was lost. The numbers come from
// DomainLimits, as the triggers' do (test/domain-limits-drift.test.ts).

/** 10000 → "10,000", as the app writes numbers. */
export const grouped = (n: number): string => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',')

const full = (max: number, things: string) =>
  `You've reached the limit of ${grouped(max)} ${things} on one account, deleted ones included. ` +
  'This one stays on this iPhone.'

/** What migrations/0010_account_caps.sql RAISEs, with the app's words (src/http/errors.ts answers 422 with them). */
export const ACCOUNT_CAPS: Readonly<Record<string, string>> = {
  too_many_workouts: full(DomainLimits.workoutsMax, 'workouts'),
  too_many_body_weights: full(DomainLimits.bodyweightsMax, 'weigh-ins'),
  too_many_routines: full(DomainLimits.routinesMax, 'routines'),
  too_many_custom_exercises: full(DomainLimits.customExercisesMax, 'custom exercises'),
  // Raised only under Claude's insert, which words it for Claude (src/mcp/d1-db.ts).
  too_many_proposals: `${grouped(DomainLimits.pendingProposalsMax)} proposals are waiting for review.`,
}
```

- [ ] **Step 5: Name the new codes in `server/src/http/errors.ts`**

Add to the imports:

```ts
import { ACCOUNT_CAPS } from '../sync/caps.ts'
```

and replace

```ts
/** What the migrations' triggers RAISE (0005_gyms_photos.sql), with the app's words for each. */
const RAISED: Readonly<Record<string, string>> = {
  too_many_gyms: "You've reached the limit of gyms on one account.",
  too_many_listings: "You've reached the limit of equipment on one account.",
}
```

with

```ts
/** What the migrations' triggers RAISE (0005_gyms_photos.sql, 0010_account_caps.sql), with the app's words for each. */
const RAISED: Readonly<Record<string, string>> = {
  too_many_gyms: "You've reached the limit of gyms on one account.",
  too_many_listings: "You've reached the limit of equipment on one account.",
  ...ACCOUNT_CAPS,
}
```

`caps.ts` imports nothing from `http/`, so there is no import cycle.

- [ ] **Step 6: The deletion check in `scripts/test-sync-integration.sh`**

After the line

```
  + (select count(*) from bodyweight where user_id in ($ids))
```

add

```
  + (select count(*) from account_rows where user_id in ($ids))
```

- [ ] **Step 7: Run the tests to see them pass**

Run:

```bash
cd server && npx vitest run test/account-caps.test.ts test/domain-limits-drift.test.ts test/schema.test.ts \
  test/limits.test.ts
```

Expected: `Test Files  4 passed (4)`. The counts: 17 in `account-caps.test.ts`, 6 in the drift test, 5 more in the
schema test, 1 more in the limits test.

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  44 passed (44)`, `Tests  626 passed (626)`; `tsc` prints nothing. Every earlier test still
passes, so no sync, gym, Claude or account test came near a cap.

- [ ] **Step 8: Commit**

```bash
git add server/migrations/0010_account_caps.sql server/src/sync/caps.ts server/src/http/errors.ts \
  server/test/cap-fixtures.ts server/test/account-caps.test.ts server/test/domain-limits-drift.test.ts \
  server/test/schema.test.ts server/test/limits.test.ts scripts/test-sync-integration.sh
git commit -m "feat(server): per-account caps on workouts, weigh-ins, routines and custom exercises"
```

- [ ] **Step 9: Review**

Ask **code-reviewer** for decisions 2–5, 8, 11 and 12: only new rows are refused; a refused push stores nothing;
`n` equals `count(*)` in every test (`countOf`); the words. Then **security-reviewer**: no route reads or writes
`account_rows` (`git grep -n account_rows -- server/src` finds nothing), another account's rows never count, and a
refusal names no other account's data. Then **typescript-reviewer**.

---

### Task 3: The size of one workout

**Files:**
- Modify: `server/src/sync/workouts.ts`, `server/src/sync/caps.ts`
- Test: `server/test/sync-workouts.test.ts`

- [ ] **Step 1: Check that the save is the only writer of entries and sets**

Run: `git grep -n -E 'INSERT INTO workout_(entries|sets)|UPDATE workout_(entries|sets)' -- server/src`
Expected: two lines, both in `server/src/sync/workouts.ts` (`INSERT_ENTRIES`, `INSERT_SETS`). Any other line: stop and
report it; that writer needs the same caps.

- [ ] **Step 2: Write the failing tests**

In `server/test/sync-workouts.test.ts`, add to the imports:

```ts
import { WORKOUT_CAPS } from '../src/sync/caps.ts'
```

and at the end of the file:

```ts
describe('the size of one workout', () => {
  const sets = (n: number) => Array.from({ length: n }, (_, i) => ({ id: appUUID(), position: i, w_kg: 60, r: 8 }))
  const entries = (n: number, setsEach = 1) => Array.from({ length: n }, (_, i) => ({
    id: appUUID(), exercise_id: `ex_${i}`, position: i, note: null, superset_group: null, sets: sets(setsEach),
  }))
  /** Three exercises, the last with `n` sets. */
  const oneLong = (n: number) =>
    workoutSample({ entries: entries(3).map((e, i) => (i === 2 ? { ...e, sets: sets(n) } : e)) })
  const push = (token: string, workout: unknown) => request('POST', '/v1/sync/workouts', { token, body: workout })

  async function refusedWith(res: Response, code: keyof typeof WORKOUT_CAPS): Promise<void> {
    expect(res.status).toBe(422)
    expect(await res.json()).toEqual({ error: { code, message: WORKOUT_CAPS[code] } })
  }

  it('takes 49 and 50 exercises, and refuses 51 with the words the app shows', async () => {
    const { token } = await signUp()
    for (const n of [49, 50]) expect((await push(token, workoutSample({ entries: entries(n) }))).status).toBe(200)
    const refused = workoutSample({ entries: entries(51) })
    await refusedWith(await push(token, refused), 'too_many_workout_exercises')
    expect((await request('GET', `/v1/sync/workouts/${refused.id}`, { token })).status).toBe(404)
  })

  it('takes 49 and 50 sets in an exercise, and refuses 51 in any one of them', async () => {
    const { token } = await signUp()
    for (const n of [49, 50]) expect((await push(token, oneLong(n))).status).toBe(200)
    await refusedWith(await push(token, oneLong(51)), 'too_many_exercise_sets')
  })

  it('saves a workout at both caps, 50 exercises of 50 sets, within the body limit', async () => {
    const { token } = await signUp()
    const w = workoutSample({ entries: entries(50, 50) })
    expect(JSON.stringify(w).length).toBeLessThan(1024 * 1024)
    expect((await push(token, w)).status).toBe(200)
    const stored = await fetchOne(token, w.id)
    expect(stored.entries).toHaveLength(50)
    expect(stored.entries.every((e) => e.sets.length === 50)).toBe(true)
  })

  it('refuses before anything is written: a stored workout keeps its entries when an edit is too big', async () => {
    const { token } = await signUp()
    const w = workoutSample()
    const first = await save(token, w)
    const tooBig = { ...w, entries: entries(51), client_updated_at: T2, base_updated_at: first.updated_at }
    await refusedWith(await push(token, tooBig), 'too_many_workout_exercises')
    const stored = await fetchOne(token, w.id)
    expect(stored.entries.map((e) => e.id)).toEqual([w.entries[0].id.toLowerCase()])
    expect(stored.updated_at).toBe(first.updated_at)
  })
})
```

`save`, `fetchOne`, `appUUID`, `T2` and `workoutSample` are the file's own helpers and imports.

- [ ] **Step 3: Run them to see them fail**

Run: `cd server && npx vitest run test/sync-workouts.test.ts`
Expected: FAIL: `WORKOUT_CAPS` isn't exported from `../src/sync/caps.ts`.

- [ ] **Step 4: The words, in `server/src/sync/caps.ts`**

Add at the end:

```ts
/** What a workout save refuses before it writes (src/sync/workouts.ts): one workout's size, as the app shows it. */
export const WORKOUT_CAPS = {
  too_many_workout_exercises:
    `A workout can have up to ${DomainLimits.workoutEntriesMax} exercises. This one stays on this iPhone.`,
  too_many_exercise_sets:
    `An exercise in a workout can have up to ${DomainLimits.entrySetsMax} sets. This workout stays on this iPhone.`,
} as const
```

- [ ] **Step 5: The check, in `server/src/sync/workouts.ts`**

Add to the imports:

```ts
import { DomainLimits } from '../shared/domain-limits.ts'
import { WORKOUT_CAPS } from './caps.ts'
```

Replace `parseWorkout` with:

```ts
/** A save past one of the per-workout caps: refused whole, before anything is read or written. */
const tooBig = (code: keyof typeof WORKOUT_CAPS) => new ApiError(422, code, WORKOUT_CAPS[code])

/**
 * The save's rows. A save replaces the workout's entries and sets with the ones it carries, so the caps count the
 * body: at most DomainLimits.workoutEntriesMax exercises, each with at most entrySetsMax sets.
 */
function parseWorkout(body: unknown): Parsed {
  const workout = storedRow(WORKOUT, body, 'workout')
  const pushOnly = storedRow(PUSH_ONLY, body, 'workout')
  const rawEntries = listOf((body as Record<string, unknown>).entries, 'workout.entries')
  if (rawEntries.length > DomainLimits.workoutEntriesMax) throw tooBig('too_many_workout_exercises')
  const entries = rawEntries.map((raw, i) => {
    const label = `workout.entries[${i}]`
    const row = storedRow(ENTRY, raw, label)
    const rawSets = listOf((raw as Record<string, unknown>).sets, `${label}.sets`)
    if (rawSets.length > DomainLimits.entrySetsMax) throw tooBig('too_many_exercise_sets')
    return { row, sets: rawSets.map((set, j) => storedRow(SET, set, `${label}.sets[${j}]`)) }
  })
  return { workout, base: pushOnly.base_updated_at as string | null, force: pushOnly.force === 1, entries }
}
```

`parseWorkout` runs first in `pushWorkout`, before the workout is read, so a refused save writes nothing.

- [ ] **Step 6: Run the tests to see them pass**

Run: `cd server && npx vitest run test/sync-workouts.test.ts`
Expected: PASS, with 4 more tests than before.

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  44 passed (44)`, `Tests  630 passed (630)`; `tsc` prints nothing.

- [ ] **Step 7: Commit**

```bash
git add server/src/sync/workouts.ts server/src/sync/caps.ts server/test/sync-workouts.test.ts
git commit -m "feat(server): at most 50 exercises in a workout and 50 sets in an exercise"
```

- [ ] **Step 8: Review**

Ask **code-reviewer** for decision 6: a save at both caps is stored whole; a refused save changes nothing; the check
counts the body and nothing else. Then **typescript-reviewer**.

---

### Task 4: Claude's writes at a cap

**Files:**
- Modify: `server/src/mcp/d1-db.ts`, `server/src/sync/caps.ts`
- Test: `server/test/claude-caps.test.ts`

- [ ] **Step 1: Write the failing tests**

`server/test/claude-caps.test.ts`:

```ts
// Claude's writes at an account's storage caps (plan 31), through the MCP tools as Claude calls them: at most 100
// proposals waiting for review, and the account's 20,000 weigh-ins.
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { DomainLimits } from '../src/shared/domain-limits.ts'
import { CLAUDE_CAPS } from '../src/sync/caps.ts'
import { countOf, seedRows } from './cap-fixtures.ts'
import { connectClaude, mcp } from './claude.ts'
import { insertUser } from './gym-fixtures.ts'
import { request } from './helpers.ts'
import { readRpc, toolJson } from './mcp/rpc.ts'

const T = '2026-11-07T10:00:00.000000Z'
const PROPOSAL = {
  summary: 'Add a Push day',
  changes: [{ id: 'c1', type: 'add-routine', routineId: 'new-push', name: 'Push' }],
}

const callTool = (token: string, name: string, args: Record<string, unknown>) =>
  mcp(token, 'tools/call', { name, arguments: args }, 2)

/** `count` proposals for the account with `status`, written straight to D1; answers their ids. */
async function seedProposals(userId: string, count: number, status = 'pending'): Promise<string[]> {
  const ids = Array.from({ length: count }, () => crypto.randomUUID())
  await env.DB.prepare(
    'INSERT INTO proposals (id, user_id, created_at, summary, changes, status, applied_change_ids, ' +
      'client_updated_at, updated_at) ' +
      `SELECT value, ?1, ?3, 'Seeded', '[{"id":"c1","type":"weight"}]', ?4, '[]', ?3, ?3 FROM json_each(?2)`,
  ).bind(userId, JSON.stringify(ids), T, status).run()
  return ids
}

const pending = async (userId: string) => (await env.DB.prepare(
  "SELECT count(*) AS n FROM proposals WHERE user_id = ?1 AND status = 'pending'",
).bind(userId).first<{ n: number }>())!.n

/** Claude's call of propose_plan_changes: the tool's JSON, and whether it was an error. */
async function propose(token: string): Promise<{ isError: boolean; body: unknown }> {
  const msg = await readRpc(await callTool(token, 'propose_plan_changes', PROPOSAL))
  return { isError: msg.result.isError === true, body: toolJson(msg) }
}

describe("Claude's proposals, at most 100 waiting for review", () => {
  it('words the refusal for Claude', () => {
    expect(CLAUDE_CAPS.too_many_proposals).toBe(
      'The owner already has 100 proposals waiting for review, the most one account holds. Nothing was saved: ask ' +
        'the owner to apply or dismiss some in the app, then propose again.',
    )
  })

  it('takes the 99th and 100th, refuses the 101st, and never counts resolved ones', async () => {
    const c = await connectClaude()
    await seedProposals(c.userId, 5, 'dismissed')
    await seedProposals(c.userId, DomainLimits.pendingProposalsMax - 2)
    const token = c.tokens.access_token
    expect((await propose(token)).isError).toBe(false)
    expect((await propose(token)).isError).toBe(false)
    expect(await pending(c.userId)).toBe(100)
    expect(await propose(token)).toEqual({ isError: true, body: { error: CLAUDE_CAPS.too_many_proposals } })
    expect(await pending(c.userId)).toBe(100)
    const audit = await env.DB.prepare(
      "SELECT ok FROM mcp_audit WHERE user_id = ?1 AND tool = 'propose_plan_changes' ORDER BY id DESC LIMIT 1",
    ).bind(c.userId).first<{ ok: number }>()
    expect(audit).toEqual({ ok: 0 })
  })

  it('takes one more once the owner resolves one in the app', async () => {
    const c = await connectClaude()
    const [first] = await seedProposals(c.userId, DomainLimits.pendingProposalsMax)
    expect((await propose(c.tokens.access_token)).isError).toBe(true)
    const later = new Date(Date.now() + 60_000).toISOString().replace(/Z$/, '000Z')
    const resolved = await request('PATCH', `/v1/claude/proposals/${first}`, {
      token: c.appToken,
      body: { status: 'dismissed', applied_change_ids: [], resolved_at: later, client_updated_at: later },
    })
    expect(resolved.status).toBe(200)
    expect((await propose(c.tokens.access_token)).isError).toBe(false)
    expect(await pending(c.userId)).toBe(100)
  })

  it("doesn't count another account's pending proposals", async () => {
    await seedProposals(await insertUser(), DomainLimits.pendingProposalsMax)
    const c = await connectClaude()
    expect((await propose(c.tokens.access_token)).isError).toBe(false)
  })
})

describe("Claude's weigh-ins", () => {
  it("log_bodyweight refuses a weigh-in past the account's cap, with words for Claude", async () => {
    const c = await connectClaude()
    await seedRows('bodyweight', c.userId, DomainLimits.bodyweightsMax)
    const msg = await readRpc(await callTool(c.tokens.access_token, 'log_bodyweight', { weight_kg: 82 }))
    expect(msg.result.isError).toBe(true)
    expect(toolJson(msg)).toEqual({ error: CLAUDE_CAPS.too_many_body_weights })
    expect(await countOf('bodyweight', c.userId)).toBe(DomainLimits.bodyweightsMax)
  })
})
```

The propose test and the weigh-in test each make at most four tool calls, far under the 60 a minute.

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/claude-caps.test.ts`
Expected: FAIL: `CLAUDE_CAPS` isn't exported from `../src/sync/caps.ts`. Once it is (Step 3), the refusals still fail:
Claude gets "Something went wrong on the GymRollins server. Try again later." (`register.ts:56`), because the raw D1
error isn't a `ToolError`.

- [ ] **Step 3: Claude's words, in `server/src/sync/caps.ts`**

Add at the end:

```ts
/** Claude's words when a cap refuses its write (src/mcp/d1-db.ts): a ToolError, which Claude reads. */
export const CLAUDE_CAPS = {
  too_many_proposals:
    `The owner already has ${grouped(DomainLimits.pendingProposalsMax)} proposals waiting for review, the most one ` +
    'account holds. Nothing was saved: ask the owner to apply or dismiss some in the app, then propose again.',
  too_many_body_weights:
    `The owner's account already holds ${grouped(DomainLimits.bodyweightsMax)} weigh-ins, deleted ones included, ` +
    'the most it can. Nothing was saved.',
} as const
```

- [ ] **Step 4: Turn the refusals into `ToolError`s, in `server/src/mcp/d1-db.ts`**

Add to the imports:

```ts
import { raisedCode } from '../http/errors.ts'
import { CLAUDE_CAPS } from '../sync/caps.ts'
```

Add above `export class D1Db`:

```ts
/** `write`, with its cap's refusal (migrations/0010_account_caps.sql) as words for Claude. */
async function capped<T>(write: Promise<T>, code: keyof typeof CLAUDE_CAPS): Promise<T> {
  try {
    return await write
  } catch (error) {
    if (raisedCode(error) === code) throw new ToolError(CLAUDE_CAPS[code])
    throw error
  }
}
```

In `insertProposal`, wrap the insert. Replace

```ts
    const row = await this.db.prepare(
```

with

```ts
    const row = await capped(this.db.prepare(
```

and its end,

```ts
    ).bind(crypto.randomUUID(), this.userId, p.summary, JSON.stringify(p.changes)).first<
      { id: string; created_at: string }
    >()
    return row!
```

with

```ts
    ).bind(crypto.randomUUID(), this.userId, p.summary, JSON.stringify(p.changes)).first<
      { id: string; created_at: string }
    >(), 'too_many_proposals')
    return row!
```

In `insertBodyweight`, replace

```ts
    await this.db.prepare(
      'INSERT INTO bodyweight (id, user_id, measured_at, w_kg, bf_pct, client_updated_at, updated_at) ' +
        `VALUES (?1, ?2, ?3, ?4, ?5, ${NOW_SQL}, ${NOW_SQL})`,
    ).bind(r.id.toLowerCase(), this.userId, stamp(r.measured_at), r.w_kg, r.bf_pct ?? null).run()
```

with

```ts
    await capped(this.db.prepare(
      'INSERT INTO bodyweight (id, user_id, measured_at, w_kg, bf_pct, client_updated_at, updated_at) ' +
        `VALUES (?1, ?2, ?3, ?4, ?5, ${NOW_SQL}, ${NOW_SQL})`,
    ).bind(r.id.toLowerCase(), this.userId, stamp(r.measured_at), r.w_kg, r.bf_pct ?? null).run(),
    'too_many_body_weights')
```

`capped` is a module function, not a method, so `d1-db.test.ts`'s "has no other way to change data" still lists
`insertBodyweight` and `insertProposal` only.

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd server && npx vitest run test/claude-caps.test.ts test/mcp test/claude-proposals.test.ts test/claude-connection.test.ts`
Expected: PASS; `claude-caps.test.ts` has 5 tests.

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  45 passed (45)`, `Tests  635 passed (635)`; `tsc` prints nothing.

- [ ] **Step 6: Commit**

```bash
git add server/src/mcp/d1-db.ts server/src/sync/caps.ts server/test/claude-caps.test.ts
git commit -m "feat(server): Claude hears why a proposal or a weigh-in was refused at a cap"
```

- [ ] **Step 7: Review**

Ask **code-reviewer** for decisions 5 and 10, and spec section 6 ("Claude's tool errors keep `ToolError`"). Then
**security-reviewer**: Claude's words name no other account's data, and the refused call is audited. Then
**typescript-reviewer**.

---

### Task 5: The phone stops at 50 exercises and 50 sets

Decision 7: nothing made by hand is past the per-workout caps, so the server never refuses it.

**Files:**
- Modify: `ios/Packages/GymCore/Sources/GymCore/Model/Workout+Editing.swift`,
  `ios/GymRollins/Features/Workout/ExerciseScreenModel.swift`, `ios/GymRollins/Features/Workout/LoggingView.swift`,
  `ios/GymRollins/Features/Workout/WorkoutOverviewView.swift`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/WorkoutEditingTests.swift`, `ios/GymRollinsTests/WorkoutSessionTests.swift`

- [ ] **Step 1: Write the failing tests**

In `ios/Packages/GymCore/Tests/GymCoreTests/WorkoutEditingTests.swift`, add inside `WorkoutEditingTests`:

```swift
    /// The server stores at most 50 exercises a workout and 50 sets an exercise (server/src/sync/workouts.ts), so
    /// editing stops there too.
    @Test func setsAndExercisesStopAtTheServersCaps() {
        let full = WorkoutEntry(exerciseId: "0025",
                                sets: (0..<DomainLimits.entrySetsMax).map { _ in WorkoutSet(weightKg: 60, reps: 8) })
        let short = WorkoutEntry(exerciseId: "0070", sets: [WorkoutSet(weightKg: 24.9, reps: 10)])
        let w = Workout(startedAt: Date(timeIntervalSince1970: 0), name: "Push", entries: [full, short])
        #expect(!w.canAddSet(entryId: full.id))
        #expect(w.appendingSet(entryId: full.id).entries[0].sets.count == 50)
        #expect(w.insertingWarmup(entryId: full.id, set: warm).entries[0].sets.count == 50)
        #expect(w.canAddSet(entryId: short.id))
        #expect(w.appendingSet(entryId: short.id).entries[1].sets.count == 2)
        #expect(!w.canAddSet(entryId: UUID()))

        let more = (0..<60).map { WorkoutEntry(exerciseId: "e\($0)", sets: []) }
        let crowded = w.appendingEntries(more)
        #expect(crowded.entries.count == DomainLimits.workoutEntriesMax)
        #expect(crowded.entries.last?.exerciseId == "e47")
        #expect(!crowded.canAddEntries)
        #expect(crowded.appendingEntries([WorkoutEntry(exerciseId: "x", sets: [])]).entries.count == 50)
        #expect(w.canAddEntries)
    }
```

In `ios/GymRollinsTests/WorkoutSessionTests.swift`, add inside the `extension WorkoutSessionTests`, after
`removeSetIgnoresASetLoggedMeanwhile`:

```swift
    /// Add Set stops at 50 sets an exercise, the server's cap (DomainLimits.entrySetsMax).
    @Test func addSetStopsAtTheCap() {
        let session = make(Spy(), now: { Date(timeIntervalSince1970: 1_100) })
        let entry = session.workout.entries[0]
        let model = ExerciseScreenModel.workout(session, entryId: entry.id)
        #expect(model.canAddSet)
        for _ in 0..<60 { model.addSet() }
        #expect(session.entry(entry.id)?.sets.count == DomainLimits.entrySetsMax)
        #expect(!model.canAddSet)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `(cd ios/Packages/GymCore && swift test --filter WorkoutEditingTests)`
Expected: the build fails: `value of type 'Workout' has no member 'canAddSet'` (and `canAddEntries`).

- [ ] **Step 3: The caps in `Workout+Editing.swift`**

Replace `appendingSet` and `insertingWarmup` with:

```swift
    /// Whether the entry can take one more set: an exercise holds at most `DomainLimits.entrySetsMax` sets in a
    /// workout, as the server stores it.
    public func canAddSet(entryId: UUID) -> Bool {
        entries.first { $0.id == entryId }.map { $0.sets.count < DomainLimits.entrySetsMax } ?? false
    }

    /// Whether the workout can take one more exercise (`DomainLimits.workoutEntriesMax`).
    public var canAddEntries: Bool { entries.count < DomainLimits.workoutEntriesMax }

    public func appendingSet(entryId: UUID) -> Workout {
        guard canAddSet(entryId: entryId) else { return self }
        return mappingEntry(entryId) { entry in
            let template = entry.sets.last(where: { !$0.warmup }) ?? entry.sets.last
            let new = template?.duplicatedUndone() ?? WorkoutSet(weightKg: 0, reps: 8)
            return entry.with(sets: entry.sets + [new])
        }
    }

    public func insertingWarmup(entryId: UUID, set: WorkoutSet) -> Workout {
        guard canAddSet(entryId: entryId) else { return self }
        return mappingEntry(entryId) { entry in
            let index = entry.sets.firstIndex(where: { !$0.warmup }) ?? entry.sets.count
            return entry.with(sets: Array(entry.sets[..<index]) + [set] + Array(entry.sets[index...]))
        }
    }
```

and `appendingEntries` with:

```swift
    /// The new entries, as many as fit under `DomainLimits.workoutEntriesMax`.
    public func appendingEntries(_ new: [WorkoutEntry]) -> Workout {
        with(entries: entries + new.prefix(max(0, DomainLimits.workoutEntriesMax - entries.count)))
    }
```

Run: `(cd ios/Packages/GymCore && swift test)`
Expected: `Test run with 535 tests in 64 suites passed`.

- [ ] **Step 4: The buttons**

In `ios/GymRollins/Features/Workout/ExerciseScreenModel.swift`, after `func addSet()`, add:

```swift
    /// Add Set stops at the server's cap on sets an exercise holds in a workout; Today's plan editor has its own.
    var canAddSet: Bool {
        switch self {
        case .workout(let session, let entryId): session.workout.canAddSet(entryId: entryId)
        case .plan: true
        }
    }
```

In `ios/GymRollins/Features/Workout/LoggingView.swift`, in `addSetButton`, replace

```swift
        .buttonStyle(.plain)
        .padding(.top, 4)
        .accessibilityIdentifier("logging.addSet")
```

with

```swift
        .buttonStyle(.plain)
        .disabled(!model.canAddSet)
        .padding(.top, 4)
        .accessibilityIdentifier("logging.addSet")
```

In `ios/GymRollins/Features/Workout/WorkoutOverviewView.swift`, in `addExerciseButton`, replace

```swift
            GlassPillButton(title: "+ Add exercise", identifier: "workout.addExercise") { showAddExercise = true }
```

with

```swift
            GlassPillButton(title: "+ Add exercise", identifier: "workout.addExercise") { showAddExercise = true }
                .disabled(!session.workout.canAddEntries)
```

Run (from `ios/`, the one-test run from "How to run things" with
`-only-testing:GymRollinsTests/WorkoutSessionTests`).
Expected: the summary shows every `WorkoutSessionTests` test passed, `addSetStopsAtTheCap` among them, and 0 failed.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/GymCore/Sources/GymCore/Model/Workout+Editing.swift \
  ios/Packages/GymCore/Tests/GymCoreTests/WorkoutEditingTests.swift \
  ios/GymRollins/Features/Workout/ExerciseScreenModel.swift ios/GymRollins/Features/Workout/LoggingView.swift \
  ios/GymRollins/Features/Workout/WorkoutOverviewView.swift ios/GymRollinsTests/WorkoutSessionTests.swift
git commit -m "feat(app): a workout stops at 50 exercises and 50 sets an exercise, as the server stores it"
```

- [ ] **Step 6: Review**

Ask **code-reviewer** for decision 7: every path that adds a set or an exercise to an active workout goes through the
three functions (`git grep -n -E 'appendingSet|insertingWarmup|appendingEntries' -- ios`), and the importers are left
as decision 7 says. Then the same agent for quality (Swift).

---

### Task 6: A refused row on the phone, and one line per reason in Account

GymSync already turns every 422 into `SyncRecordRejected` with the server's words, and parks the row (decision 8). This
task pins that path for the caps, then groups identical refusals in Account (decision 9).

**Files:**
- Create: `ios/Packages/GymSync/Tests/GymSyncTests/ApiSyncTransportCapTests.swift`,
  `ios/Packages/GymSync/Tests/GymSyncTests/SyncEngineCapTests.swift`
- Modify: `ios/Packages/GymSync/Tests/GymSyncTests/FakeTransport.swift`, `ios/GymRollins/Features/Sync/SyncStatusText.swift`,
  `ios/GymRollins/Features/Account/AccountView.swift`
- Test: `ios/GymRollinsTests/SyncSupportTests.swift`

- [ ] **Step 1: GymSync's tests for the caps' path**

`ios/Packages/GymSync/Tests/GymSyncTests/ApiSyncTransportCapTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// The storage caps (server/src/sync/caps.ts) as `ApiSyncTransport` meets them: 422 with the cap's code and the
/// server's words, which the engine records beside the row it keeps.
@Suite struct ApiSyncTransportCapTests {
    private let t0 = SyncDate.parse("2026-11-08T08:00:00.123456Z")!
    private let codes = ["too_many_workouts", "too_many_body_weights", "too_many_routines",
                         "too_many_custom_exercises", "too_many_workout_exercises", "too_many_exercise_sets"]
    private let words = "You've reached the limit of 20,000 weigh-ins on one account, deleted ones included. "
        + "This one stays on this iPhone."

    private func refusing(_ code: String) -> StubServer {
        StubServer { _ in .json(422, #"{"error": {"code": "\#(code)", "message": "\#(words)"}}"#) }
    }

    @Test func aCapRefusesABatchWithTheServersWords() async throws {
        let row = BodyweightDTO(SyncRow(value: BodyweightEntry(date: t0, weightKg: 81), clientUpdatedAt: t0))
        for code in codes {
            let server = refusing(code) // held for the request: its deinit unregisters the host
            await #expect(throws: SyncRecordRejected(code: code, message: words)) {
                _ = try await ApiSyncTransport(api: server.client()).push(bodyweight: [row])
            }
        }
    }

    @Test func aCapRefusesAWorkoutWithTheServersWords() async throws {
        let workout = Workout(startedAt: t0, endedAt: t0 + 600, name: "Push", entries: [
            WorkoutEntry(exerciseId: "bench", sets: [WorkoutSet(weightKg: 60, reps: 8, done: true)]),
        ])
        let dto = WorkoutDTO(SyncRow(value: WorkoutSnapshot(workout: workout, records: [], volumeKg: 480),
                                     clientUpdatedAt: t0 + 600))
        for code in codes {
            let server = refusing(code)
            await #expect(throws: SyncRecordRejected(code: code, message: words)) {
                _ = try await ApiSyncTransport(api: server.client()).push(workout: dto)
            }
        }
    }
}
```

In `ios/Packages/GymSync/Tests/GymSyncTests/FakeTransport.swift`:

1. After `private var rejected: Set<String> = []`, add:

```swift
    /// The account's weigh-in cap, as server/migrations/0010_account_caps.sql keeps it: a push holding a new row past
    /// it is refused whole (one statement), with the server's words; edits of stored rows pass.
    private var bodyweightCap: Int?
    static let bodyweightCapWords = "You've reached the limit of 20,000 weigh-ins on one account, deleted ones "
        + "included. This one stays on this iPhone."
```

2. After `func reject(ids: [String]) { … }`, add:

```swift
    func capBodyweight(at max: Int) { bodyweightCap = max }
```

3. In `push(bodyweight:)`, after `try checkRejected(dtos.map(\.id.uuidString))`, add:

```swift
        if let cap = bodyweightCap, bodyweight.count + Set(dtos.map(\.id)).subtracting(bodyweight.keys).count > cap {
            throw SyncRecordRejected(code: "too_many_body_weights", message: Self.bodyweightCapWords)
        }
```

`ios/Packages/GymSync/Tests/GymSyncTests/SyncEngineCapTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymSync

/// A row past an account cap (server/migrations/0010_account_caps.sql) stays on this iPhone with the server's words,
/// isn't pushed again until it is edited, and doesn't hold back an edit pushed beside it.
@MainActor
@Suite struct SyncEngineCapTests {
    let f: EngineFixture
    init() throws { f = try EngineFixture() }

    @Test func aWeighInPastTheCapStaysOnThisIPhoneAndTheEditBesideItSyncs() async throws {
        defer { f.tearDown() }
        let stored = BodyweightEntry(date: f.clock.now, weightKg: 81)
        try f.body.add(stored)
        await f.engine.sync()
        #expect(await f.server.bodyweight.count == 1)

        await f.server.capBodyweight(at: 1)
        f.clock.advance()
        try f.body.upsert(BodyweightEntry(id: stored.id, date: stored.date, weightKg: 82))
        let refused = BodyweightEntry(date: f.clock.now, weightKg: 83)
        try f.body.add(refused)
        await f.engine.sync()

        #expect(f.engine.status == .idle)
        #expect(await f.server.bodyweight[stored.id]?.wKg == 82)
        #expect(await f.server.bodyweight[refused.id] == nil)
        let failures = f.store.syncFailures()
        #expect(failures.map(\.id) == [refused.id.uuidString])
        #expect(failures.map(\.message) == [FakeTransport.bodyweightCapWords])
        #expect(try f.store.dirtyBodyweight().map(\.value.id) == [refused.id])
        #expect(try f.body.hasRecord(id: refused.id))

        let calls = await f.server.pushCalls
        await f.engine.sync()
        #expect(await f.server.pushCalls == calls)
    }
}
```

Run: `(cd ios/Packages/GymSync && swift test --filter 'ApiSyncTransportCapTests|SyncEngineCapTests')`
Expected: `Test run with 3 tests in 2 suites passed`. These pass at once: GymSync already maps every 422
(`ApiSyncTransport.swift:156-166`) and parks a refused edit (`SyncStore+Ownership.swift:66-68`). They pin that for the
caps. If one fails, stop: decision 8 doesn't hold, and GymSync needs a fix before the server's caps can ship.

- [ ] **Step 2: Write the failing app test**

In `ios/GymRollinsTests/SyncSupportTests.swift`, add inside `SyncStatusTextTests`, after `accountStatusText`:

```swift
    /// At an account limit every refused row has the same words: Account shows one line for them, not hundreds.
    @Test func refusedRowsReadAsOneLinePerKindAndReason() {
        let full = "You've reached the limit of 20,000 weigh-ins on one account, deleted ones included. "
            + "This one stays on this iPhone."
        let check = "CHECK constraint failed: length(name) BETWEEN 1 AND 40"
        let failures = (0..<300).map {
            SyncFailure(entity: .bodyweight, id: "w\($0)", clientUpdatedAt: now, message: full)
        } + [SyncFailure(entity: .routines, id: "r1", clientUpdatedAt: now, message: check)]
        #expect(SyncStatusText.failureLines(failures) == [
            SyncFailureLine(title: "Weigh-in \u{00B7} 300", message: full),
            SyncFailureLine(title: "Routine", message: check),
        ])
        #expect(SyncStatusText.failures(failures.count) == "301 items couldn't sync")
        #expect(SyncStatusText.failuresFooter == "They stay on this iPhone. Editing one tries again.")
    }
```

Run (from `ios/`, the one-test run from "How to run things", as written: `-only-testing:GymRollinsTests/SyncStatusTextTests`).
Expected: the build fails: `type 'SyncStatusText' has no member 'failureLines'` (and `SyncFailureLine`,
`failuresFooter`).

- [ ] **Step 3: One line per kind and reason, in `SyncStatusText.swift`**

After `struct SyncBannerState { … }`, add:

```swift
/// One line of Account's refused rows: what they are, with how many when more than one, and the server's words.
struct SyncFailureLine: Equatable, Identifiable {
    struct Key: Hashable {
        let entity: SyncEntity
        let message: String
    }

    let title: String
    let message: String
    var id: String { "\(title)\n\(message)" }
}
```

In `enum SyncStatusText`, after `failures(_:)`, add:

```swift
    /// Under the refused rows: they stay on this phone, and an edit sends one again.
    static let failuresFooter = "They stay on this iPhone. Editing one tries again."

    /// Account's refused rows, one line per kind of row and reason, in the store's order. At an account limit every
    /// refused row has the same words, so 300 weigh-ins past it read as one line, not 300.
    static func failureLines(_ failures: [SyncFailure]) -> [SyncFailureLine] {
        let keys = failures.map { SyncFailureLine.Key(entity: $0.entity, message: $0.message) }
        let counts = Dictionary(keys.map { ($0, 1) }, uniquingKeysWith: +)
        let distinct = keys.reduce(into: [SyncFailureLine.Key]()) { if !$0.contains($1) { $0.append($1) } }
        return distinct.map { key in
            let name = entityName(key.entity)
            let count = counts[key, default: 1]
            return SyncFailureLine(title: count == 1 ? name : "\(name) \u{00B7} \(count)", message: key.message)
        }
    }
```

- [ ] **Step 4: Account shows the lines**

In `ios/GymRollins/Features/Account/AccountView.swift`, replace

```swift
    /// Rows the server refused: a count plus what each one is and why.
```

with

```swift
    /// Rows the server refused: a count, then one line per kind of row and reason.
```

and replace

```swift
                ForEach(env.sync.syncFailures, id: \.id) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SyncStatusText.entityName(failure.entity)).font(.subheadline.weight(.semibold))
                        Text(failure.message).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Text("Edit the item to try again.").font(.caption).foregroundStyle(Theme.textTertiary)
```

with

```swift
                ForEach(SyncStatusText.failureLines(env.sync.syncFailures)) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.title).font(.subheadline.weight(.semibold))
                        Text(line.message).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Text(SyncStatusText.failuresFooter).font(.caption).foregroundStyle(Theme.textTertiary)
```

No UI test reads the old footer (`git grep -n 'Edit the item to try again' -- ios` finds only this line before the
change).

Run (from `ios/`, the one-test run, `-only-testing:GymRollinsTests/SyncStatusTextTests`).
Expected: every `SyncStatusTextTests` test passed, `refusedRowsReadAsOneLinePerKindAndReason` among them, 0 failed.

Run: `(cd ios/Packages/GymSync && swift test --filter GymSyncTests)`
Expected: `Test run with 217 tests in 28 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/GymSync/Tests/GymSyncTests/ApiSyncTransportCapTests.swift \
  ios/Packages/GymSync/Tests/GymSyncTests/SyncEngineCapTests.swift \
  ios/Packages/GymSync/Tests/GymSyncTests/FakeTransport.swift ios/GymRollins/Features/Sync/SyncStatusText.swift \
  ios/GymRollins/Features/Account/AccountView.swift ios/GymRollinsTests/SyncSupportTests.swift
git commit -m "feat(app): a row refused at a cap stays on the phone, and Account shows one line per reason"
```

- [ ] **Step 6: Review**

Ask **code-reviewer** for decisions 8 and 9: the refused row stays dirty and isn't sent again until edited; the edit
beside it syncs; the words reach Account unchanged. Then the same agent for quality (Swift).

---

### Task 7: The docs

**Files:**
- Modify: `docs/cloudflare-checklist.md`, `docs/release-readiness.md`, `server/README.md`

- [ ] **Step 1: The checklist's section 5**

In `docs/cloudflare-checklist.md`, replace from `## 5. Usage caps (decide before step 2; build them in a plan of their own)`
down to, and not including, `- [ ] **Unused OAuth clients**`, with:

```markdown
## 5. Usage caps (plan 31 built them; decide what is open before step 2)

**Built** (plan 31, `server/migrations/0010_account_caps.sql`; the numbers are `DomainLimits`', in
`ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift`):
- Per account: 10,000 workouts, 20,000 weigh-ins, 200 routines and 1,000 custom exercises.
  - **Deleted rows count.** A deletion stays as a tombstone (`deleted_at`), so other devices learn of it, and nothing
    purges tombstones. So deleting frees nothing: an account that reaches a cap stays there.
- 100 Claude proposals waiting for review at a time. A resolved one frees a slot.
- One workout holds at most 50 exercises, and an exercise at most 50 sets in it. The app stops there too; an import
  can still make a bigger workout, which stays on the phone.
- Private gyms (100) and private listings (1,000) keep their caps (`0005_gyms_photos.sql`), which count live rows only.
- A refused row stays on the phone. Account lists it under "N items couldn't sync", with the server's words, and it
  isn't sent again until it is edited.

**Open** (plan 31, "Questions for the owner"), each a code change in a plan of its own:
- [ ] Sets per account. The caps above allow 25,000,000 (10,000 × 50 × 50), about 7 GB; a free D1 database holds
      500 MB.
- [ ] Gym and listing tombstones, which the gym caps don't count.
- [ ] Exercise preferences: one row per exercise id, and the id is any short text.
- [ ] Resolved proposals, and Claude's audit rows (90 days kept, up to 60 a minute).
- [ ] Imported workouts past 50 exercises or 50 sets: split them at import, or leave them on the phone.
```

- [ ] **Step 2: `docs/release-readiness.md`**

Replace

```markdown
  approved separately, and deciding when the phone moves to it. Before it: how to rate-limit on `workers.dev`, and
  the per-user row and tombstone caps (the checklist's sections 1 and 5).
```

with

```markdown
  approved separately, and deciding when the phone moves to it. Before it: how to rate-limit on `workers.dev`, and
  the caps plan 31 left open (the checklist's sections 1 and 5).
```

- [ ] **Step 3: `server/README.md`**

After the line

```markdown
- `0005_gyms_photos.sql` adds the catalogue's fold keys and the private caps (triggers).
```

add

```markdown
- `0010_account_caps.sql` caps what one account stores, deleted rows included: workouts, weigh-ins, routines and
  custom exercises (triggers, with the counts in `account_rows`), and the proposals waiting for review. The numbers
  are `DomainLimits`', and `test/domain-limits-drift.test.ts` checks them. The words are in `src/sync/caps.ts`.
```

- [ ] **Step 4: Check and commit**

Run: `git grep -n -E 'build them in a plan of their own|per-user row and tombstone' -- docs ':!docs/plans' ':!docs/specs' ':!docs/research'`
Expected: no output.

```bash
git add docs/cloudflare-checklist.md docs/release-readiness.md server/README.md
git commit -m "docs: the storage caps built, and what plan 31 left open"
```

- [ ] **Step 5: Review**

Ask **code-reviewer**: every number in the docs matches `DomainLimits`; nothing in the checklist suggests a step that
touches Cloudflare without the owner's approval.

---

### Task 8: Verify everything, and the Outcome

**Files:**
- Modify: this plan (`## Outcome`)

Before the long run, close other simulators if memory is short, and leave the dev Worker on 8787 alone. Port 8788 must
be free. `server/.dev.vars` must have a real `BETTER_AUTH_SECRET` and `ALLOW_PASSWORD_AUTH=1` (check without printing
it: `grep -c '^ALLOW_PASSWORD_AUTH=1$' server/.dev.vars` prints `1`).

- [ ] **Step 1: The server, and the caps in the migration**

Run:

```bash
(cd server && npx vitest run && npx tsc --noEmit)
git grep -n account_rows -- server/src
git grep -c 'CREATE TRIGGER' -- server/migrations/0010_account_caps.sql
```

Expected: `Test Files  45 passed (45)`, `Tests  635 passed (635)`; `tsc` prints nothing; no `account_rows` in
`server/src` (no route reads or writes it); `server/migrations/0010_account_caps.sql:13` (three triggers for each of
the four tables, and the proposals' one).

- [ ] **Step 2: The Swift packages**

Run:

```bash
(cd ios/Packages/GymCore && swift test)
(cd ios/Packages/GymData && swift test)
(cd ios/Packages/GymSync && swift test --filter GymSyncTests)
scripts/test-sync-integration.sh
```

Expected: GymCore `Test run with 535 tests in 64 suites passed`; GymData as plan 30 left it (371 tests in 50 suites);
GymSync `Test run with 217 tests in 28 suites passed`; the integration suite as plan 30 left it (`Test run with 45
tests in 11 suites passed`), then `Account deletion verified: … deleted users, 0 rows left`.

- [ ] **Step 3: The owner's data under the caps** (only with the copy plans 27–30 used, kept outside the repo)

If the owner's phone backup is at hand, read a copy of its store (never the backup in place: opening it rewrites its
log). Numbers only go into the Outcome:

```bash
READ="$(mktemp -d)"
cp "$BACKUP/Library/Application Support/default.store"* "$READ/"
sqlite3 "$READ/default.store" "select (select max(n) from (select count(*) n from ZWORKOUTENTRYRECORD group by ZWORKOUT)), (select max(n) from (select count(*) n from ZSETRECORD group by ZENTRY)), (select count(*) from ZWORKOUTRECORD), (select count(*) from ZBODYWEIGHTRECORD), (select count(*) from ZROUTINERECORD), (select count(*) from ZCUSTOMEXERCISERECORD)"
rm -rf "$READ"
```

Expected: the largest exercises in one workout and sets in one exercise are at most 50 each; the counts are far under
their caps (plan 30 found 148 workouts, 23 weigh-ins, 6 routines and 42 custom exercises). If a largest value is over
50, stop and ask the owner: that workout would be refused at the cutover.

Then the server-move check, as plan 30 ran it: `scripts/server-move-check.sh "$BACKUP" <a work folder outside the repo>`.
Expected: `Server move verified.`, with every count equal on both sides (148 workouts, 836 entries, 2,685 sets).

Without the backup, write "not measured" in the Outcome; the cutover's comparison (checklist, section 10) then covers
it.

- [ ] **Step 4: Everything**

Run: `SYNC_E2E=1 MCP_E2E=1 PHOTO_E2E=1 GYM_E2E=1 scripts/test-all.sh`
Expected: it ends with exit 0. Plan 30 found two accessibility audits that fail now and then
(`testClaudeConnectionAudit`, `testUnblockEveryoneAudit`); if one fails, re-run it alone and record both runs.

- [ ] **Step 5: The Outcome**

Fill in `## Outcome` below: the base sha, each task's commits, the counts above, Step 3's numbers or "not measured",
anything that differed from this plan, and anything left for the owner. Commit:

```bash
git add docs/plans/2026-11-08-plan-31-account-caps.md
git commit -m "docs: plan 31 outcome"
```

---

## Self-review against the spec

**Coverage**

| Spec, checklist or ask | Where |
|---|---|
| Checklist §5: per-user row caps, "a trigger or a conditional insert, with a test at the exact number" | Tasks 2–4; decisions 2–6 |
| Checklist §5: tombstone caps | decision 4: tombstones count toward the caps (the owner's choice); no purge |
| Spec §1 criterion 2: the daily limits and caps keep working | the gym caps and daily limits are untouched; Task 2, Step 7 runs every earlier test |
| Spec §1 criterion 3: isolation | another account's rows never count (Tasks 2, 4); no route reads `account_rows` (Task 8, Step 1) |
| Spec §1 criterion 8: the free plan | no KV, no Durable Objects; one more row written per new row (decision 4) |
| Spec §4 Sync: last-write-wins, acks | unchanged; an edit at the cap is stored and acked (Task 2) |
| Spec §4: requests within D1's limits | decision 11; a workout at both caps stays under 1 MB (Task 3) |
| Spec §6: one error body; 422 for a refused row, with the code | decision 8; Tasks 2 and 3 check the body |
| Spec §6: Claude's tool errors keep `ToolError` | decision 10; Task 4 |
| Spec §8: every cap at its exact number | Tasks 2–4 (N-1, N, N+1); Task 2's requests that arrive together |
| Spec §7: the owner's data stays out of the repo | Task 8, Step 3 reads a copy outside it, numbers only |
| The owner: updates never refused | decision 3; Task 2 (edit, deletion, revival at the cap), Task 3 (a refused edit changes nothing) |
| The owner: the phone keeps the data, no retry loop, a plain message | decisions 8 and 9; Task 6 |
| The owner: one place for the numbers, with the drift test | decision 1; Tasks 1 and 2 |

**What this plan found that the spec says differently** (for its next revision):
1. **§6 lists the error codes.** Plan 31 adds seven: `too_many_workouts`, `too_many_body_weights`,
   `too_many_routines`, `too_many_custom_exercises`, `too_many_proposals` (Claude only), `too_many_workout_exercises`
   and `too_many_exercise_sets`.
2. **§2, "Locks and limits", says each limit is "insert only if the count is under the limit".** A multi-row push
   can't be: it would skip rows silently and the phone would push them again forever (decision 2). The caps are
   triggers, as plan 28's gym caps already were.
3. **§1, "Out of scope", says no changes to the SwiftData models.** None here: `SyncFailure` keeps its fields, and the
   app's changes are GymCore's editing, two buttons and Account's list.

**Placeholders:** none in the steps. The Outcome is empty by design. Task 8, Step 3 holds the owner's numbers only when
the backup is at hand. Every code block is a file's full new text or an exact replacement.

**Names used across tasks:** `account_rows`, `seedRows`, `countOf`, `CappedTable` (Task 2); `ACCOUNT_CAPS` (Task 2),
`WORKOUT_CAPS` (Task 3), `CLAUDE_CAPS` and `capped` (Task 4), `grouped` (Task 2); `canAddSet`, `canAddEntries`
(Task 5); `SyncFailureLine`, `failureLines`, `failuresFooter`, `capBodyweight`, `bodyweightCapWords` (Task 6). Each is
defined in the task that first needs it.

## Questions for the owner

1. **Sets per account.** The owner's numbers allow 10,000 workouts × 50 exercises × 50 sets = 25,000,000 sets in one
   account. At about 276 bytes a set (measured, indexes included), that is about 7 GB. A D1 database holds 500 MB on
   the free plan and 10 GB on Workers Paid, for every account together. So the caps don't keep one account from
   filling D1.
   - A cap on sets per account would. 250,000 would be about 69 MB; the owner's 2,685 sets are 0.7 MB. It fits this
     plan's machinery: one `account_rows` count, kept by the workout save (which replaces its sets) in its own batch.
   - Related: a save at both caps writes about 2,500 sets and 50 entries plus their index rows, and every later save
     of it deletes and rewrites them. By D1's rule that each index adds a written row, that is roughly 15,000 rows
     written a save (not measured). The free plan allows 100,000 a day for the whole Worker.
2. **Imports past 50 and 50.** The CSV importers can make a bigger workout (FitNotes puts a whole day into one). It
   stays on the phone and sync refuses it with the cap's words (decision 7). Split such workouts at import, skip the
   extra rows with a note in the import summary, or leave it?
3. **Gym and listing tombstones.** The gym caps count live rows only (`0005_gyms_photos.sql:22-45`), so adding and
   deleting gyms or listings grows their tombstones without end. Count deleted ones there too, as plan 31's caps do?
   An account that deleted many gyms would then be refused.
4. **Exercise preferences.** One row per exercise id, and the id is any 1–80 characters (`0002_app_schema.sql:99-107`),
   so a client can make rows without end. Cap them, at the library and custom exercises (1,324 + 1,000), say?
5. **Resolved proposals and Claude's audit.** Only waiting proposals are capped (the owner's number). With auto-apply
   on, the app resolves each one, so Claude can keep adding, up to 60 calls a minute. The audit keeps 90 days of calls
   (`d1-db.ts:553`), so up to about 7.8 million rows for one busy connection. Cap the totals, or purge older rows?
6. **The words.** "You've reached the limit of 20,000 weigh-ins on one account, deleted ones included. This one stays
   on this iPhone." Keep, or reword before the cutover? They live in `server/src/sync/caps.ts`, and only the server
   changes.

## Outcome
