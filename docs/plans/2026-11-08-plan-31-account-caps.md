# Plan 31: Per-account storage caps

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** before the first deploy, one account can't fill D1. The Worker caps what one account stores, with the
owner's numbers:
- per account, deleted rows included: 10,000 workouts, 50,000 exercises and 250,000 sets logged in them, 20,000
  weigh-ins, 200 routines, 1,000 custom exercises, 2,000 exercise preferences, and 500 private gyms and 5,000 private
  listings (beside today's 100 and 1,000 live ones, which stay);
- Claude: 100 proposals waiting for review at a time, and 5,000 in all, resolved ones included;
- one workout: 50 exercises, and 50 sets in one exercise.

Each cap is tested at its exact number. An edit of a stored row is never refused, and a save that would pass a cap is
refused whole and writes nothing. A refused row stays on the phone, isn't sent again in a loop, and Account shows the
server's plain words for it. The phone stops at the per-workout caps too, and the importers split a workout past them
into several, so nothing the phone makes is refused.

**Architecture:**
- **One set of numbers.** Thirteen new constants in `DomainLimits.swift`, copied in `server/src/shared/domain-limits.ts`.
  The drift test checks the copy and the numbers in the triggers.
- **Account caps are SQLite triggers,** as plan 28's gym caps are. A push stays one statement, and a refusal fails the
  whole statement. A table, `account_rows`, holds each account's counts, so a check reads one row.
- **Logged exercises and sets** are counted by the workout save itself: one statement a count moves it by what the save
  changes, in the save's batch, and a trigger on `account_rows` refuses a move past the cap.
- **Pending proposals** are a live count (at most 100 rows) behind a partial index.
- **Per-workout caps** are checked in TypeScript when a save is parsed, because a save rewrites exactly the entries and
  sets it carries.
- **The importers** cut a workout past 50 exercises or 50 sets an exercise into consecutive pieces ("Push", "Push (2)").
- **The app** already treats any 422 as a refused row: it keeps the row, parks it, and lists it in Account. This plan
  groups identical refusals into one line there, rewords the footer, and makes the phone stop at 50 and 50.

**The owner's answers** (2026-11-08) amended this plan: account-wide totals on top of the first seven caps (decisions 1,
5–7), and splitting oversized imports (decision 10). Questions they settle are gone from the list at the end.

**Tech stack:** as plans 26–30. The Worker (Hono 4.13.17, Better Auth 1.7.18, D1 and R2 through wrangler 4.158.0,
Vitest 4.1.12 with `@cloudflare/vitest-plugin` 1.6.0 in workerd), Swift 6.2 (`swift test`, `xcodebuild`, XcodeGen).

**Spec:** `docs/specs/2026-11-07-cloudflare-backend-design.md`: sections 4 ("Sync"), 6 (errors) and 8 ("Limits").
`docs/cloudflare-checklist.md`, section 5, which asked for this plan.

**Builds on:** plans 26–30, each built and with its `## Outcome`. The base is `658202e` or later on `feat-cloudflare`.

**Branch:** `feat-cloudflare`.
- No push.
- Local only: never run `wrangler login`, `wrangler deploy`, or any `wrangler` command without `--local`.
- The owner's personal data never goes into the repo. Task 1 reads a copy of the phone backup kept outside it, numbers
  only, and never opens the backup's store in place.
- Commit messages have no `Co-Authored-By`, `Generated with` or `Claude-Session` trailers; the owner forbids them.

**Not in this plan:**
- Purging tombstones, or any change to what sync sends (the owner's choice: deleted rows count).
- A one-time split of workouts already on a phone past the caps (decision 10 keeps them on the phone).
- A cap on Claude's audit rows (a question for the owner).
- Indexes for the pulls (found while writing; decision 17; a later plan).
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
   | `proposalsMax` | 5,000 | trigger `proposals_cap`, resolved proposals included |
   | `exercisePrefsMax` | 2,000 | trigger `exercise_prefs_cap` |
   | `privateGymsTotalMax` | 500 | trigger `gyms_total_cap`, beside `privateGymsMax` (100 live) |
   | `privateListingsTotalMax` | 5,000 | trigger `gym_equipment_total_cap`, beside `privateListingsMax` (1,000 live) |
   | `accountEntriesMax` | 50,000 | the workout save's count move, and trigger `account_rows_entries_cap` |
   | `accountSetsMax` | 250,000 | the same, and trigger `account_rows_sets_cap` |
   | `workoutEntriesMax` | 50 | `parseWorkout` (`server/src/sync/workouts.ts`), the phone's editing, the importers |
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
   - `RAISE(ABORT)` fails the whole statement instead, and the phone records the refusal (decision 11).
   - A trigger holds for every writer. Claude's `insertBodyweight` (`server/src/mcp/d1-db.ts:528-536`) inserts
     weigh-ins outside sync.
   - A workout save is one batch (`workouts.ts:144-150`). A `RAISE` in any of its statements rolls back the whole
     batch, entries and sets included (probe).

3. **Only new rows count against the cap.**
   - The trigger's condition starts `NOT EXISTS (SELECT 1 FROM <table> WHERE <key> = NEW.<key>)`: the id, or for
     exercise preferences the account and the exercise id. Proposals are only ever inserted, so theirs has none.
   - SQLite runs `BEFORE INSERT` for an upsert row that turns into an update too (plan 28, decision 1; probe), so an
     edit, a deletion or a revival passes at the cap.
   - `AFTER INSERT` runs only for a row actually inserted (probe), so the count never grows on an update.
   - Another account's id is refused with 403 before the statement runs (`table-sync.ts:48`, `:59-66`;
     `workouts.ts:119-121`).

4. **Deleted rows count, through counts kept in `account_rows (user_id, tbl, n)`.**
   - **Why not `count(*)`:** tombstones count, so no live-rows index helps (0005's `gyms_owner_live` serves live counts
     only, `0005_gyms_photos.sql:20-21`). `bodyweight`, `routines`, `custom_exercises` and `proposals` have no index on
     `user_id` at all (`0002_app_schema.sql:49-60`, `:62-75`, `:305-318`, `:321-333`). A `count(*)` reads the whole
     table (probe: one count reports `rows_read` 20,000), and every pushed row runs the trigger, up to 500 times a push.
   - **The cost:** two primary-key lookups per pushed row (probe: `SEARCH … USING INDEX sqlite_autoindex_…`), and one
     more row written per new row. Edits cost nothing more.
   - **Kept exact:** an `AFTER DELETE` trigger lowers a count, so `n` always equals `count(*)`. Today only an account's
     deletion removes these rows (`server/src/account/delete.ts:31`, by cascade), and the account's `account_rows`
     cascade with it.
   - **Rows from before the migration** are counted by the migration itself (the local dev D1 has some).
   - **At the cap an account stays full.** Deleting frees nothing, because its tombstone stays. The app's words say so
     (decision 11).

5. **Logged exercises and sets: the workout save moves the counts, once a save.**
   - A save deletes the workout's entries (and, by cascade, their sets) and writes the ones it carries
     (`workouts.ts:68-72`, `:146-148`). Row triggers on `workout_entries` and `workout_sets` would write the count once
     per row deleted and once per row inserted, on every save: about 5,100 more rows written for a re-save at both
     per-workout caps.
   - So the save's batch gets two statements before its delete, `MOVE_ENTRIES` and `MOVE_SETS`. Each moves the count by
     the rows the save writes minus the rows it replaces, and writes nothing when that is 0. They run only while the
     row is still this save's (`write_id`), like the entries and sets, so a stale save moves nothing.
   - `account_rows_entries_cap` and `account_rows_sets_cap` (`BEFORE UPDATE OF n ON account_rows`) refuse a move that
     raises a count past its cap. A move that keeps or lowers it always passes. The refusal fails the whole batch: the
     workout row, its entries and sets stay as they were.
   - **What counts:** a deleted workout keeps its entries and sets as stored rows, so they count. A set removed from a
     workout is deleted outright, so removing sets frees room. Nothing else deletes these rows.
   - **The cost:** 4 bound values a statement, and one or two rows read per entry and set the workout had. Measured in
     workerd: no extra row written on a re-save that keeps the size, 3 on a first save (6 on an account's first save).
   - **The catch:** the counts are exact while `pushWorkout` is the only writer of entries and sets. Task 3, Step 1
     greps for others, and a comment on the statements says so.

6. **Proposals: at most 100 waiting, and 5,000 in all.**
   - Claude's insert is the only writer, one row at a time (`d1-db.ts:497-510`), and it writes `pending` only
     (`:502-503`). A resolved proposal never turns pending again: `parseResolution` refuses `pending`
     (`server/src/claude/proposals.ts:48-50`).
   - **Waiting:** a `count(*)` over at most 100 rows, through a new partial index, is enough. The index
     `proposals_user_pending` also serves the app's pull of pending proposals (`proposals.ts:21-26`), which read the
     whole table until now. Resolving one frees a slot.
   - **In all:** `proposals_cap` reads the count in `account_rows`; resolving frees nothing.
   - Codes: `too_many_pending_proposals` and `too_many_proposals`. Claude hears words for each (decision 13).

7. **Private gyms and listings: totals beside the live caps.**
   - `gyms_total_cap` (500) and `gym_equipment_total_cap` (5,000) count the account's private rows (`owner_id`),
     deleted ones included. Plan 28's live caps (`gyms_private_cap`, 100; `gym_equipment_private_cap`, 1,000) stay as
     they are.
   - Shared gyms and listings belong to the catalogue (no owner), and the daily limits already bound them (10 new gyms
     and 30 shares a day). Nothing here counts them.
   - Both caps are `BEFORE INSERT` triggers on the same table. When both would refuse, which code the account hears
     isn't specified; the tests check the totals with the live counts far under their caps.

8. **The per-workout caps are checked in TypeScript, as the save is parsed** (`workouts.ts:92-103`).
   - The body is exactly what the save writes (decision 5), so checking it counts "only what the save writes".
   - A trigger would count once per inserted row, up to 2,500 sets of up to 50 reads each.
   - The check runs before the stale check, so a save that is too big hears that first, and nothing is written.
   - A save at both caps (2,500 sets) stays under the 1 MB body limit (`server/src/index.ts:23`, `:49-52`). Task 3
     tests it.

9. **The app allows more than 50 and 50 today, so the phone learns the caps too.**
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
   - **The owner's data** (measured on a copy of the phone backup, 2026-11-08): at most 15 exercises in one workout
     and 8 sets in one exercise, 45 sets in one workout. 144 of the 148 workouts are imports. Task 1, Step 2 measures
     again before any code is written.
   - **So the owner's 50 and 50 stay.** The phone stops there (Task 5): Add Set, warm-ups and Add exercise stop at the
     cap, and their buttons are disabled. The importers split (decision 10).

10. **The importers split a workout past the caps into consecutive pieces** (`ImportSplit`, in GymCore, applied in
    `ImportAssembler.result`, so all four importers do it).
    - An exercise with more than 50 sets goes on as another entry of the same exercise, in runs of 50; the next run
      goes into the next piece when this one is full. Exercises keep their order, and every set is kept.
    - Each piece holds at most 50 entries. Piece 1 keeps the source's id, title and note, and starts at its start.
      Piece k's id is made from the source's (`ImportID`), the same on every import; it keeps the title and note.
    - **Times** (changed after review): the pieces follow each other through the session, so Health, calories and
      total time count it once. With an end time, each piece gets a share of the session by its sets (equal shares
      when there are none), at least a second each: piece 1 starts at the source's start, each next one where the one
      before ended, and the last ends at the source's end. Without an end time (Fitbod, FitNotes), or one less than a
      second a piece after the start, piece k starts k − 1 seconds after the source and keeps the source's end, so the
      pieces still sort next to each other in order.
    - **What the user sees:** "Push", "Push (2)", "Push (3)": the export's title, or the app's default ("FitNotes
      workout"), then the number, within the 80-character name limit (`ImportSplit.name`).
    - **Duplicates:** the pieces stay or go with their first piece (`ImportService.withoutDuplicates`). Pieces can start
      within a minute of each other (`ImportService.duplicateWindow`), so on their own a re-import would keep piece 1
      (its id is known) and drop the rest as its duplicates; and another app's copy of the session would drop piece 1
      but keep the pieces that start later.
    - **Workouts already on a phone past the caps stay there.** Sync refuses them with the cap's words, and Account
      lists them; nothing is lost on the phone. A one-time split on the phone was the other choice. It isn't taken:
      - the phone holds the only live copy of the training data, and a split rewrites stored workouts (new ids, entries
        moved between workouts, records and gym links recomputed) before the data has a server copy;
      - the owner's data has none past the caps (decision 9), so the code would run for nobody today;
      - a user who has one can re-import the export: piece 1 overwrites the old workout by id, and the rest come in
        as new workouts.

11. **The error: 422, the cap's code, and the app's words, as the gym caps** (`server/src/http/errors.ts:29-50`).
    - **Codes the app can meet:** `too_many_workouts`, `too_many_body_weights`, `too_many_routines`,
      `too_many_custom_exercises`, `too_many_exercise_prefs`, `too_many_gyms_total`, `too_many_listings_total`,
      `too_many_logged_exercises`, `too_many_logged_sets` (the triggers); `too_many_workout_exercises`,
      `too_many_exercise_sets` (the save). The two proposal codes are raised only under Claude's insert (decision 13).
    - **Words:** "You've reached the limit of 20,000 weigh-ins on one account, deleted ones included. This one stays on
      this iPhone." The numbers come from `DomainLimits`, so they can't drift. They live in `server/src/sync/caps.ts`.
    - **How it reaches the app:**
      - `mappingRejections` turns any 422 into `SyncRecordRejected(code, message)` with the server's words
        (`ios/Packages/GymSync/Sources/GymSync/ApiSyncTransport.swift:156-166`).
      - The engine records it per row: a refused workout at `SyncEngine+Rounds.swift:66-70`, a refused batch row by
        row at `:96-110`, through `recordRejection` (`:139-143`).
      - The row stays dirty, and that edit isn't pushed again
        (`ios/Packages/GymData/Sources/GymData/Sync/SyncStore+Ownership.swift:66-68`). A later edit tries once more.
      - Account lists it under "N items couldn't sync" (`ios/GymRollins/Features/Account/AccountView.swift:102-124`).
      - That is how `too_many_gyms` shows today. No GymSync code changes; Task 7 pins the path with tests.
    - **A batch with a new row past the cap** is refused whole, then sent again row by row
      (`SyncEngine+Rounds.swift:96-110`). Edits in it go through; the new rows are refused, once each, then parked.

12. **Account shows identical refusals as one line.** At a cap every refused row carries the same words, and a Health
    import past 20,000 would list thousands of identical rows. `SyncStatusText.failureLines` groups them by kind and
    words ("Weigh-in · 300"). The footer "Edit the item to try again." becomes "They stay on this iPhone. Editing one
    tries again.", which holds for a cap too. The stored `SyncFailure` doesn't change.

13. **Claude's refusals are words for Claude.** `runAudited` shows any error that isn't a `ToolError` as the internal
    error (`server/src/mcp/tools/register.ts:251-257`). So `insertProposal` (both proposal caps) and `insertBodyweight`
    turn their caps' `RAISE` into a `ToolError` with plain words, and the call is audited as failed.

14. **What a session costs in rows written** (the free plan allows 100,000 a day for the whole Worker). Measured in
    workerd's local D1 (`meta.rows_written`, summed over the save's batch); Cloudflare's own counting may differ:

    | One workout | First save, today | First save, plan 31 | Each re-save, today and plan 31 |
    |---|---|---|---|
    | 6 exercises × 3 sets (the owner's average is 5.6 × 3.2) | 81 | 87 (84 after the account's first) | 104 |
    | 15 × 3 (the owner's largest) | 198 | 201 | 257 |
    | 50 × 50 (both per-workout caps) | 7,703 | 7,706 | 10,252 |

    - A normal session is one save when the workout ends (active workouts don't sync) and maybe an edit: about 90–260
      rows written. The free plan's day holds about 400–1,100 such sessions.
    - Re-saving a workout at both caps costs about 10,000 rows each time, so about 9 re-saves a day use the whole free
      allowance. Only the per-IP rate limits (checklist, section 1) stand in the way: a question for the owner.

15. **D1's limits.**
    - No new bound values on pushes: the triggers bind nothing, and the push still binds two. The two count moves bind
      four each.
    - No `LIKE` or `GLOB`; the schema test's 50-byte check (`server/test/schema.test.ts:45-56`) covers the new
      migration anyway.
    - A batch is one transaction (decision 2).

16. **Tests at the exact number seed rows straight into D1,** with one `INSERT … SELECT … FROM json_each(?2)`. The
    seeded rows go through the same triggers, so `account_rows` counts them (probe: 19,998 rows in about 130 ms). Every
    other seeded row is a tombstone, because deleted rows count; seeded gyms and listings are all tombstones, so the
    live caps stay out of the way. Pushes then take the account to N-1, N and N+1. The logged counts are seeded as
    counts (`seedCount`): their caps read only the count, and 250,000 real sets would be a 10 MB JSON value, past D1's
    2 MB.

17. **Found while writing: the pulls read whole tables.** `bodyweight`, `routines` and `custom_exercises` have no index
    that starts with `user_id`, and `workouts` has only `(user_id, started_at DESC)` (`0002_app_schema.sql:269`). So
    every pull of them scans, and rows read grow with every account's rows. Not changed here, apart from the proposals
    index: a later plan, before many accounts exist.

### Facts checked for this plan

Checked on 2026-11-08 against `658202e`. Every probe lived in a scratch folder outside the repo and was never committed.

| Check | Result |
|---|---|
| The owner's phone backup, a copy of the whole folder (Task 1, Step 2's query) | `15\|8\|148\|836\|2685\|23\|6\|42\|0\|4\|1\|1`: at most 15 exercises in a workout and 8 sets in an exercise; 148 workouts (144 imported, 0 deleted, 0 active), 836 entries, 2,685 sets, 23 weigh-ins, 6 routines, 42 custom exercises, 0 exercise preferences, 4 proposals, 1 gym and 1 listing on the phone; at most 45 sets in one workout |
| `sqlite3` 3.51.0, a scratch table with logging triggers, a three-row upsert (`a`, `b`, `a`) and an update | `BEFORE INSERT` runs for every row, the upsert's update included, and sees `exists=1` for it; `AFTER INSERT` runs for `a` and `b` only; a skipped update (`WHERE false`) runs no update trigger; a statement failing on its second row rolls back the first row's count |
| Same, deleting the user | the cascade runs each child's `AFTER DELETE`; the count rows go with the user |
| workerd, through the server's Vitest with a scratch config: the counter triggers on `bodyweight` with a cap of 3 | an edit and a tombstone at the cap pass; a new row fails with `D1_ERROR: too_many_body_weights: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_TRIGGER)`; in a batch the earlier `UPDATE` is rolled back; another account isn't counted |
| workerd, query plans | `SEARCH account_rows USING INDEX sqlite_autoindex_account_rows_1 (user_id=? AND tbl=?)`; `SEARCH custom_exercises USING COVERING INDEX sqlite_autoindex_custom_exercises_1 (id=?)`; pending count and pull both `SEARCH proposals USING COVERING INDEX proposals_user_pending (user_id=?)` |
| workerd, seeding | 19,998 weigh-ins (half tombstones) through `json_each` in about 130 ms; one `count(*)` of them reports `rows_read` 20,000; 200 such counts take about 300 ms |
| `sqlite3`, 0001–0009 with rows already stored, then a draft of 0010 | the backfill counts them: bodyweight 2 (one of them deleted), workouts 1, custom_exercises 1 |
| `sqlite3`, 10,000 sets in 200 entries | about 276 bytes a set, its indexes and its share of the entry included |
| workerd, rows written per workout save, today's code and this plan's | decision 14's table |
| `cd server && npx vitest run` at `658202e` | `Test Files  43 passed (43)`, `Tests  602 passed (602)` |
| Tasks 1–4's server steps, applied from this plan's text to a scratch copy of `server/` (with `fixtures/` and the two Swift files the drift test reads) | after Task 2 `Test Files  44 passed (44)`, `Tests  636 passed (636)`; after Task 3 `Tests  646 passed (646)`; after Task 4 `Test Files  45 passed (45)`, `Tests  652 passed (652)`; `tsc --noEmit` clean each time |
| Tasks 1, 5, 6 and 7's Swift package steps, applied to a scratch copy of `ios/Packages` | GymCore `--filter ImportSplitTests`: 6 tests in 1 suite passed, each importer's case among them; `--filter 'Importer\|ImportSplit'`: 67 tests in 6 suites passed; the whole of GymCore counts 541 tests in 65 suites (the ones reading the app's bundled `exercises.json` can't pass in the copy, which lacks it); GymSync `ApiSyncTransportCapTests` and `SyncEngineCapTests` 3 tests in 2 suites passed; `GymSyncTests` 217 tests in 28 suites passed |
| Same, GymSync after a GymCore file was added | the incremental build couldn't find `ImportSplit` until `swift package clean` ("How to run things") |
| Task 7's `failureLines`, compiled alone with stand-ins for `SyncEntity` and `SyncFailure` | 300 weigh-ins and 1 routine give `["Weigh-in · 300", "Routine"]` |
| D1's limits (developers.cloudflare.com/d1/platform/limits and /pricing, 2026-11-08) | a database holds 500 MB on the free plan, 10 GB on Workers Paid; 100 bound parameters; 50-byte `LIKE`/`GLOB` patterns; free: 5 million rows read and 100,000 written a day; "Indexes will add an additional written row" |

## File map

| File | Change | Task |
|---|---|---|
| `ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift`, `Tests/GymCoreTests/DomainLimitsTests.swift` | The thirteen caps | 1 |
| `server/src/shared/domain-limits.ts` | The copy | 1 |
| `server/test/domain-limits-drift.test.ts` | 53 constants (Task 1); the trigger numbers (Task 2) | 1, 2 |
| `server/migrations/0010_account_caps.sql` | Create: `account_rows`, every cap's trigger, the pending-proposals index | 2 |
| `server/src/sync/caps.ts` | Create: the codes' words (Tasks 2–4) | 2, 3, 4 |
| `server/src/http/errors.ts` | The new trigger codes | 2 |
| `server/test/cap-fixtures.ts` | Create: `seedRows`, `countOf`, `seedCount`, `kept` | 2 |
| `server/test/account-caps.test.ts` | Create: the account caps (Task 2); logged exercises and sets (Task 3) | 2, 3 |
| `server/test/schema.test.ts`, `server/test/limits.test.ts` | Query plans; requests that arrive together | 2, 3 |
| `scripts/test-sync-integration.sh` | `account_rows` in the deletion check | 2 |
| `server/src/sync/workouts.ts`, `server/test/sync-workouts.test.ts` | One workout's size; the save moves the logged counts | 3 |
| `server/src/mcp/d1-db.ts`, `server/test/claude-caps.test.ts` (create) | Claude's refusals | 4 |
| `ios/Packages/GymCore/Sources/GymCore/Model/Workout+Editing.swift`, `Tests/GymCoreTests/WorkoutEditingTests.swift` | The phone stops at 50 and 50 | 5 |
| `ios/GymRollins/Features/Workout/ExerciseScreenModel.swift`, `LoggingView.swift`, `WorkoutOverviewView.swift`, `ios/GymRollinsTests/WorkoutSessionTests.swift` | Add Set and Add exercise at the cap | 5 |
| `ios/Packages/GymCore/Sources/GymCore/Import/ImportSplit.swift` (create), `ImportTypes.swift`, `ImportSupport.swift`, `Tests/GymCoreTests/ImportSplitTests.swift` (create) | The importers split | 6 |
| `ios/GymRollins/Features/Import/ImportService.swift`, `ios/GymRollinsTests/ImportServiceTests.swift` | The pieces' titles and duplicates | 6 |
| `ios/Packages/GymSync/Tests/GymSyncTests/ApiSyncTransportCapTests.swift`, `SyncEngineCapTests.swift` (create), `FakeTransport.swift` | The caps' path through GymSync | 7 |
| `ios/GymRollins/Features/Sync/SyncStatusText.swift`, `ios/GymRollins/Features/Account/AccountView.swift`, `ios/GymRollinsTests/SyncSupportTests.swift` | One line per kind and reason | 7 |
| `docs/cloudflare-checklist.md`, `docs/release-readiness.md`, `server/README.md` | The caps built; what is open | 8 |
| this plan | `## Outcome` | 9 |

GymData's code doesn't change: the caps reach it only as sync failures, which it already stores.

## How to run things

```bash
(cd server && npx vitest run && npx tsc --noEmit)          # the server; ignore the punycode DEP0040 warning
(cd server && npx vitest run test/account-caps.test.ts)    # one file
(cd ios/Packages/GymCore && swift test --filter DomainLimitsTests)
(cd ios/Packages/GymSync && swift test --filter GymSyncTests)
scripts/test-sync-integration.sh                           # GymSyncIntegrationTests on a throwaway Worker (:8788)
```

- Vitest ends with `Test Files  N passed (N)` and `Tests  M passed (M)`. `swift test` prints `Test run with N tests in M
  suites passed`; a parameterized test counts once.
- **A new GymCore file and the packages that use it:** after Task 6 adds `ImportSplit.swift`, GymSync's (and GymData's)
  incremental build may not see it ("cannot find 'ImportSplit' in scope"). Run `swift package clean` in that package
  once, then test again.
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

### Task 1: The owner's sizes, and the numbers in `DomainLimits`

Read-only first: the caps and the import split are checked against the owner's real data before any code is written.

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

- [ ] **Step 2: Measure the owner's data (read-only, numbers only)**

The owner's phone backup is personal data, kept outside the repo. On 2026-11-08 it was the scratch folder
`phone-backup-p25-1794090751`. Copy the whole folder, open only the copy, and remove the copy afterwards. Opening the
backup's own `default.store` would rewrite its log, and it would stop being a copy of the phone.

```bash
BACKUP=<the owner's backup folder, outside the repo>
READ="$(mktemp -d)"
cp -R "$BACKUP" "$READ/"
DB="$READ/$(basename "$BACKUP")/Library/Application Support/default.store"
sqlite3 "$DB" "select (select max(n) from (select count(*) n from ZWORKOUTENTRYRECORD group by ZWORKOUT)), (select max(n) from (select count(*) n from ZSETRECORD group by ZENTRY)), (select count(*) from ZWORKOUTRECORD), (select count(*) from ZWORKOUTENTRYRECORD), (select count(*) from ZSETRECORD), (select count(*) from ZBODYWEIGHTRECORD), (select count(*) from ZROUTINERECORD), (select count(*) from ZCUSTOMEXERCISERECORD), (select count(*) from ZEXERCISEPREFERENCERECORD), (select count(*) from ZPROPOSALRECORD), (select count(*) from ZGYMRECORD), (select count(*) from ZGYMLISTINGRECORD)"
rm -rf "$READ"
```

Expected: `15|8|148|836|2685|23|6|42|0|4|1|1` (2026-11-08), or a newer backup's numbers within every cap:
- the largest exercises in one workout, then sets in one exercise: at most 50 each;
- workouts, entries, sets, weigh-ins, routines, custom exercises, exercise preferences, proposals, gyms and listings:
  far under 10,000, 50,000, 250,000, 20,000, 200, 1,000, 2,000, 5,000, 500 and 5,000.

Write the line in the Outcome. If a largest value is over 50, or a count near its cap, stop and ask the owner: that
data would be refused at the cutover (decision 10).

- [ ] **Step 3: Write the failing tests**

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
        #expect(DomainLimits.proposalsMax == 5_000)
        #expect(DomainLimits.exercisePrefsMax == 2_000)
        #expect(DomainLimits.privateGymsTotalMax == 500)
        #expect(DomainLimits.privateListingsTotalMax == 5_000)
        #expect(DomainLimits.accountEntriesMax == 50_000)
        #expect(DomainLimits.accountSetsMax == 250_000)
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
    expect(Object.keys(swift).length).toBeGreaterThanOrEqual(53)
```

- [ ] **Step 4: Run them to see them fail**

Run: `(cd ios/Packages/GymCore && swift test --filter DomainLimitsTests)`
Expected: the build fails with `type 'DomainLimits' has no member 'workoutsMax'` (and the twelve others).

Run: `(cd server && npx vitest run test/domain-limits-drift.test.ts)`
Expected: FAIL in "finds the Swift constants": `expected 40 to be greater than or equal to 53`.

- [ ] **Step 5: Add the caps to `DomainLimits.swift`**

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
    public static let proposalsMax = 5_000
    public static let exercisePrefsMax = 2_000
    public static let privateGymsTotalMax = 500
    public static let privateListingsTotalMax = 5_000
    // Exercises and sets logged per account, deleted workouts included (server/src/sync/workouts.ts keeps the counts)
    public static let accountEntriesMax = 50_000
    public static let accountSetsMax = 250_000
    // One workout, as each save stores it (server/src/sync/workouts.ts)
    public static let workoutEntriesMax = 50
    public static let entrySetsMax = 50
```

Each is a bare `= value`, the only form the drift test reads (decision 1).

Run: `(cd ios/Packages/GymCore && swift test --filter DomainLimitsTests)`
Expected: `Test run with 7 tests in 1 suite passed`.

Run: `(cd server && npx vitest run test/domain-limits-drift.test.ts)`
Expected: FAIL in "has every Swift limit in the server": the thirteen new names are missing from the server's copy.

- [ ] **Step 6: Add them to the server's copy**

In `server/src/shared/domain-limits.ts`, after `gymActiveListingsMax: 300,`, add:

```ts
  // Storage per account, deleted rows included (migrations/0010_account_caps.sql)
  workoutsMax: 10_000,
  bodyweightsMax: 20_000,
  routinesMax: 200,
  customExercisesMax: 1_000,
  pendingProposalsMax: 100,
  proposalsMax: 5_000,
  exercisePrefsMax: 2_000,
  privateGymsTotalMax: 500,
  privateListingsTotalMax: 5_000,
  // Exercises and sets logged per account, deleted workouts included (src/sync/workouts.ts keeps the counts)
  accountEntriesMax: 50_000,
  accountSetsMax: 250_000,
  // One workout, as each save stores it (src/sync/workouts.ts)
  workoutEntriesMax: 50,
  entrySetsMax: 50,
```

Run: `(cd server && npx vitest run test/domain-limits-drift.test.ts && npx tsc --noEmit)`
Expected: `Tests  5 passed (5)`; `tsc` prints nothing.

Run: `(cd ios/Packages/GymCore && swift test)`
Expected: `Test run with 534 tests in 64 suites passed`.

- [ ] **Step 7: Commit**

```bash
git add ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift \
  ios/Packages/GymCore/Tests/GymCoreTests/DomainLimitsTests.swift server/src/shared/domain-limits.ts \
  server/test/domain-limits-drift.test.ts
git commit -m "feat: the storage caps' numbers in DomainLimits and the server's copy"
```

- [ ] **Step 8: Review**

Ask **code-reviewer**:
- the thirteen names and values against decision 1;
- the drift test fails when one changes: `accountSetsMax = 250_001` in a scratch copy of `DomainLimits.swift`, never
  committed.

---

### Task 2: The account caps in D1

`0010_account_caps.sql` holds all of this plan's SQL: the counts, every account cap, the two caps on the logged counts
(their moves are Task 3), and the pending proposals' cap and index. Claude's side of the proposal caps is Task 4.

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

export type CappedTable =
  | 'workouts'
  | 'bodyweight'
  | 'routines'
  | 'custom_exercises'
  | 'exercise_prefs'
  | 'gyms'
  | 'gym_equipment'
/** The two counts a workout save moves itself (src/sync/workouts.ts). */
export type LoggedTable = 'workout_entries' | 'workout_sets'
/** Every table account_rows counts. Proposals are seeded by test/claude-caps.test.ts. */
export type CountedTable = CappedTable | LoggedTable | 'proposals'

const T = '2026-11-07T10:00:00.000000Z'
/** Every other seeded row is deleted: deleted rows count toward the caps too. */
const HALF_DELETED = 'CASE WHEN key % 2 = 1 THEN ?3 END'
const GENERIC_DUMBBELLS =
  "(SELECT id FROM equipment_items WHERE kind_id = 'dumbbells' AND brand IS NULL AND model IS NULL)"

/** Each table's columns, and their values over json_each: `value` a new key, ?1 the account, ?3 T, ?4 a gym. */
const FILL: Readonly<Record<CappedTable, { readonly columns: string; readonly values: string }>> = {
  workouts: {
    columns: 'id, user_id, started_at, name, client_updated_at, updated_at, deleted_at',
    values: `value, ?1, ?3, 'Seeded', ?3, ?3, ${HALF_DELETED}`,
  },
  bodyweight: {
    columns: 'id, user_id, measured_at, w_kg, client_updated_at, updated_at, deleted_at',
    values: `value, ?1, ?3, 80, ?3, ?3, ${HALF_DELETED}`,
  },
  routines: {
    columns: 'id, user_id, name, client_updated_at, updated_at, deleted_at',
    values: `value, ?1, 'Seeded', ?3, ?3, ${HALF_DELETED}`,
  },
  custom_exercises: {
    columns: 'id, user_id, n, bp, eq, tg, client_updated_at, updated_at, deleted_at',
    values: `value, ?1, 'Seeded', 'legs', 'machine', 'quads', ?3, ?3, ${HALF_DELETED}`,
  },
  // No deleted_at: a preference is only ever set.
  exercise_prefs: {
    columns: 'user_id, exercise_id, pref, client_updated_at, updated_at',
    values: "?1, value, 'more', ?3, ?3",
  },
  // All deleted, so the live caps (100 gyms, 1,000 listings) stay out of the way.
  gyms: {
    columns: 'id, visibility, owner_id, created_by, name, client_updated_at, created_at, updated_at, deleted_at',
    values: "value, 'private', ?1, ?1, 'Seeded', ?3, ?3, ?3, ?3",
  },
  gym_equipment: {
    columns:
      'id, gym_id, item_id, visibility, owner_id, added_by, client_updated_at, created_at, updated_at, deleted_at',
    values: `value, ?4, ${GENERIC_DUMBBELLS}, 'private', ?1, ?1, ?3, ?3, ?3, ?3`,
  },
}

const newKey = (table: CappedTable) => {
  if (table === 'custom_exercises') return `custom-${crypto.randomUUID()}`
  if (table === 'exercise_prefs') return `ex_${crypto.randomUUID()}`
  return crypto.randomUUID()
}

/** `count` rows of `table` for the account (listings at one private gym of their own, which counts as a gym). */
export async function seedRows(table: CappedTable, userId: string, count: number): Promise<void> {
  const { columns, values } = FILL[table]
  const keys = JSON.stringify(Array.from({ length: count }, () => newKey(table)))
  const insert = env.DB.prepare(`INSERT INTO ${table} (${columns}) SELECT ${values} FROM json_each(?2)`)
  if (table !== 'gym_equipment') {
    await insert.bind(userId, keys, T).run()
    return
  }
  const gym = crypto.randomUUID()
  await env.DB.prepare(
    `INSERT INTO gyms (${FILL.gyms.columns}) VALUES (?2, 'private', ?1, ?1, 'Seeded', ?3, ?3, ?3, ?3)`,
  ).bind(userId, gym, T).run()
  await insert.bind(userId, keys, T, gym).run()
}

const OWNER: Readonly<Record<string, string>> = { gyms: 'owner_id', gym_equipment: 'owner_id' }

/** The account's rows in `table`, deleted ones included; fails when the count kept in account_rows disagrees. */
export async function countOf(table: CountedTable, userId: string): Promise<number> {
  const owner = OWNER[table] ?? 'user_id'
  const row = (await env.DB.prepare(
    `SELECT (SELECT count(*) FROM ${table} WHERE ${owner} = ?1) AS stored, ` +
      '(SELECT n FROM account_rows WHERE user_id = ?1 AND tbl = ?2) AS kept',
  ).bind(userId, table).first<{ stored: number; kept: number | null }>())!
  expect(row.kept ?? 0, `account_rows for ${table}`).toBe(row.stored)
  return row.stored
}

/** The count account_rows keeps for the account. */
export async function kept(table: LoggedTable, userId: string): Promise<number> {
  const row = await env.DB.prepare('SELECT n FROM account_rows WHERE user_id = ?1 AND tbl = ?2').bind(userId, table)
    .first<{ n: number }>()
  return row?.n ?? 0
}

/** Sets the account's count of logged entries or sets without writing the rows: the caps read only the count. */
export async function seedCount(table: LoggedTable, userId: string, n: number): Promise<void> {
  await env.DB.prepare(
    'INSERT INTO account_rows (user_id, tbl, n) VALUES (?1, ?2, ?3) ' +
      'ON CONFLICT (user_id, tbl) DO UPDATE SET n = excluded.n',
  ).bind(userId, table, n).run()
}
```

`server/test/account-caps.test.ts`:

```ts
import { env } from 'cloudflare:workers'
import { beforeAll, describe, expect, it } from 'vitest'
import { DomainLimits } from '../src/shared/domain-limits.ts'
import { ACCOUNT_CAPS } from '../src/sync/caps.ts'
import { type CappedTable, countOf, seedRows } from './cap-fixtures.ts'
import { insertUser } from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'
import { KEY, type Row, SAMPLES, sampleNeeds, T1, T2, workoutSample } from './samples.ts'

// Each account cap at its exact number (plan 31): N-1 and N are stored, N+1 is refused with its code and the app's
// words, and nothing of the refused push is stored. A stored row can still be edited, deleted and brought back at the
// cap. A deletion frees nothing, because its tombstone counts. Another account's rows don't count.

beforeAll(sampleNeeds)

const T3 = '2026-11-07T12:00:00.000000Z'

interface Saved {
  status: 'ok' | 'stale'
  updated_at: string
}

const push = (token: string, entity: string, rows: Row[]) =>
  request('POST', `/v1/sync/${entity}`, { token, body: { rows } })
const save = (token: string, workout: Row) => request('POST', '/v1/sync/workouts', { token, body: workout })

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
    expect(ACCOUNT_CAPS.too_many_logged_sets).toBe(
      "You've reached the limit of 250,000 sets logged on one account, deleted workouts included. " +
        'This workout stays on this iPhone.',
    )
    expect(Object.keys(ACCOUNT_CAPS).sort()).toEqual([
      'too_many_body_weights', 'too_many_custom_exercises', 'too_many_exercise_prefs', 'too_many_gyms_total',
      'too_many_listings_total', 'too_many_logged_exercises', 'too_many_logged_sets', 'too_many_pending_proposals',
      'too_many_proposals', 'too_many_routines', 'too_many_workouts',
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
    expect((await push(token, entity, [fresh()])).status).toBe(200)
    expect(await countOf(table, userId)).toBe(max - 1)
    expect((await push(token, entity, [fresh()])).status).toBe(200)
    expect(await countOf(table, userId)).toBe(max)
    const last = fresh()
    await refusedWith(await push(token, entity, [last]), code)
    expect(await countOf(table, userId)).toBe(max)
    expect(await storedEdit(last, userId)).toBeUndefined()
  })

  it('refuses a push holding a new row past the cap whole, and takes an edit, a deletion and a revival at the cap',
    async () => {
      const { token, userId } = await signUp()
      await seedRows(table, userId, max - 1)
      const row = fresh()
      expect((await push(token, entity, [row])).status).toBe(200)
      const edit = { ...row, client_updated_at: T2 }
      await refusedWith(await push(token, entity, [edit, fresh()]), code)
      expect(await storedEdit(row, userId)).toBe(T1)
      expect((await push(token, entity, [edit])).status).toBe(200)
      expect((await push(token, entity, [{ ...edit, deleted_at: T2 }])).status).toBe(200)
      expect((await push(token, entity, [{ ...edit, client_updated_at: T3, deleted_at: null }])).status).toBe(200)
      expect(await storedEdit(row, userId)).toBe(T3)
      await refusedWith(await push(token, entity, [fresh()]), code)
      expect(await countOf(table, userId)).toBe(max)
    })

  it('counts a deletion the server never had as a new row', async () => {
    const { token, userId } = await signUp()
    await seedRows(table, userId, max)
    await refusedWith(await push(token, entity, [{ ...fresh(), deleted_at: T1 }]), code)
  })

  it("doesn't count another account's rows", async () => {
    await seedRows(table, await insertUser(), max)
    const { token, userId } = await signUp()
    expect((await push(token, entity, [fresh()])).status).toBe(200)
    expect(await countOf(table, userId)).toBe(1)
  })
})

describe('exercise preferences', () => {
  const max = DomainLimits.exercisePrefsMax

  it('hold 2,000 per account: N-1 and N are stored, N+1 is refused, and an edit at the cap goes through', async () => {
    const { token, userId } = await signUp()
    await seedRows('exercise_prefs', userId, max - 2)
    const pref = SAMPLES['exercise-prefs']()
    expect((await push(token, 'exercise-prefs', [pref])).status).toBe(200)
    expect(await countOf('exercise_prefs', userId)).toBe(max - 1)
    expect((await push(token, 'exercise-prefs', [SAMPLES['exercise-prefs']()])).status).toBe(200)
    await refusedWith(await push(token, 'exercise-prefs', [SAMPLES['exercise-prefs']()]), 'too_many_exercise_prefs')
    const edit = { ...pref, pref: 'never', client_updated_at: T2 }
    expect((await push(token, 'exercise-prefs', [edit])).status).toBe(200)
    expect(await countOf('exercise_prefs', userId)).toBe(max)
  })

  it("don't count another account's", async () => {
    await seedRows('exercise_prefs', await insertUser(), max)
    const { token } = await signUp()
    expect((await push(token, 'exercise-prefs', [SAMPLES['exercise-prefs']()])).status).toBe(200)
  })
})

const PRIVATE: Synced[] = [
  { entity: 'gyms', table: 'gyms', max: DomainLimits.privateGymsTotalMax, code: 'too_many_gyms_total' },
  {
    entity: 'gym-listings', table: 'gym_equipment', max: DomainLimits.privateListingsTotalMax,
    code: 'too_many_listings_total',
  },
]

describe('private gyms and listings, deleted ones included', () => {
  it.each(PRIVATE)('$entity: N-1 and N are stored, N+1 is refused under the live cap, and an edit goes through',
    async ({ entity, table, max, code }) => {
      const { token, userId } = await signUp()
      await seedRows(table, userId, max - 2)
      const first = SAMPLES[entity]()
      expect((await push(token, entity, [first])).status).toBe(200)
      expect(await countOf(table, userId)).toBe(max - 1)
      expect((await push(token, entity, [SAMPLES[entity]()])).status).toBe(200)
      await refusedWith(await push(token, entity, [SAMPLES[entity]()]), code)
      expect((await push(token, entity, [{ ...first, client_updated_at: T2 }])).status).toBe(200)
      expect(await countOf(table, userId)).toBe(max)
    })

  it.each(PRIVATE)("$entity: another account's don't count", async ({ entity, table, max }) => {
    await seedRows(table, await insertUser(), max)
    const { token } = await signUp()
    expect((await push(token, entity, [SAMPLES[entity]()])).status).toBe(200)
  })
})

describe('workouts', () => {
  const max = DomainLimits.workoutsMax
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
    const first = await (await save(token, w)).json<Saved>()
    const second = await (await save(token, {
      ...w, name: 'Pull', client_updated_at: T2, base_updated_at: first.updated_at,
    })).json<Saved>()
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
    for (const table of ['workouts', 'bodyweight', 'routines', 'custom_exercises', 'exercise_prefs', 'gyms',
      'gym_equipment'] as const) {
      await seedRows(table, userId, 3)
    }
    expect((await save(token, workoutSample())).status).toBe(200)
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
    const counted = [
      ['workouts', DomainLimits.workoutsMax, 'too_many_workouts'],
      ['bodyweight', DomainLimits.bodyweightsMax, 'too_many_body_weights'],
      ['routines', DomainLimits.routinesMax, 'too_many_routines'],
      ['custom_exercises', DomainLimits.customExercisesMax, 'too_many_custom_exercises'],
      ['exercise_prefs', DomainLimits.exercisePrefsMax, 'too_many_exercise_prefs'],
      ['proposals', DomainLimits.proposalsMax, 'too_many_proposals'],
      ['gyms', DomainLimits.privateGymsTotalMax, 'too_many_gyms_total'],
      ['gym_equipment', DomainLimits.privateListingsTotalMax, 'too_many_listings_total'],
    ] as const
    for (const [table, max, code] of counted) {
      const trigger = `tbl = '${table}'), 0) >= ${max}\nBEGIN\n  SELECT RAISE(ABORT, '${code}');`
      expect(accountCaps.split(trigger).length - 1, code).toBe(1)
    }
    const logged = [
      [DomainLimits.accountEntriesMax, 'too_many_logged_exercises'],
      [DomainLimits.accountSetsMax, 'too_many_logged_sets'],
    ] as const
    for (const [max, code] of logged) {
      const trigger = `NEW.n > OLD.n AND NEW.n > ${max}\nBEGIN\n  SELECT RAISE(ABORT, '${code}');`
      expect(accountCaps.split(trigger).length - 1, code).toBe(1)
    }
    const pending = `status = 'pending') >= ${DomainLimits.pendingProposalsMax}\nBEGIN\n` +
      "  SELECT RAISE(ABORT, 'too_many_pending_proposals');"
    expect(accountCaps.split(pending).length - 1).toBe(1)
  })
```

In `server/test/schema.test.ts`, add inside `describe('the D1 schema', …)`, after the `it.each` on the gym cap
triggers:

```ts
  it.each([
    'workouts_cap', 'bodyweight_cap', 'routines_cap', 'custom_exercises_cap', 'exercise_prefs_cap', 'proposals_cap',
    'gyms_total_cap', 'gym_equipment_total_cap',
  ])("%s finds the row and the account's count through primary keys, never by counting", async (name) => {
    const { sql } = (await env.DB.prepare("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?1")
      .bind(name).first<{ sql: string }>())!
    expect(sql).not.toMatch(/count\(/)
    const lookups = [...sql.matchAll(/\((SELECT (?:1|n) FROM \w+ WHERE [^)]*)\)/g)].map((m) => m[1]!)
    expect(lookups.length, sql).toBeGreaterThanOrEqual(1)
    for (const lookup of lookups) {
      const query = lookup.replace(/NEW\.\w+/g, '?1')
      const plan = await env.DB.prepare(`EXPLAIN QUERY PLAN ${query}`).bind(crypto.randomUUID())
        .all<{ detail: string }>()
      expect(plan.results.map((r) => r.detail).join('\n'), query)
        .toMatch(/^SEARCH \w+ USING (COVERING )?INDEX sqlite_autoindex_\w+_1 \(/)
    }
  })

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

-- How many rows each account holds in the capped tables, deleted rows included. A deletion keeps its row as a
-- tombstone (deleted_at), so it still counts, and deleting frees nothing. The triggers below and the workout save
-- (src/sync/workouts.ts, for entries and sets) keep the counts, so a cap reads one row. A count(*) would read every row
-- the account ever had, for every pushed row: no live-rows index can serve it, and most of these tables have no index
-- on user_id (a count reads the whole table). gyms and gym_equipment count the account's private rows (owner_id).
CREATE TABLE account_rows (
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  tbl TEXT NOT NULL CHECK (tbl IN ('workouts','bodyweight','routines','custom_exercises','exercise_prefs','proposals',
    'gyms','gym_equipment','workout_entries','workout_sets')),
  n INTEGER NOT NULL,
  PRIMARY KEY (user_id, tbl)
);
INSERT INTO account_rows (user_id, tbl, n) SELECT user_id, 'workouts', count(*) FROM workouts GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n) SELECT user_id, 'bodyweight', count(*) FROM bodyweight GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n) SELECT user_id, 'routines', count(*) FROM routines GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n)
  SELECT user_id, 'custom_exercises', count(*) FROM custom_exercises GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n)
  SELECT user_id, 'exercise_prefs', count(*) FROM exercise_prefs GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n) SELECT user_id, 'proposals', count(*) FROM proposals GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n)
  SELECT owner_id, 'gyms', count(*) FROM gyms WHERE owner_id IS NOT NULL GROUP BY owner_id;
INSERT INTO account_rows (user_id, tbl, n)
  SELECT owner_id, 'gym_equipment', count(*) FROM gym_equipment WHERE owner_id IS NOT NULL GROUP BY owner_id;
INSERT INTO account_rows (user_id, tbl, n)
  SELECT user_id, 'workout_entries', count(*) FROM workout_entries GROUP BY user_id;
INSERT INTO account_rows (user_id, tbl, n)
  SELECT user_id, 'workout_sets', count(*) FROM workout_sets GROUP BY user_id;

-- Per table: <table>_cap (gyms_total_cap, gym_equipment_total_cap) refuses a new row once the account holds the cap;
-- <table>_counted and <table>_uncounted keep the count.
-- - A row is new when its key isn't stored yet. SQLite runs BEFORE INSERT for an upsert's row that turns into an
--   update too, so the key check is what lets an edit, a deletion or a revival through at the cap. Proposals are only
--   ever inserted, so theirs has none.
-- - AFTER INSERT runs only for a row actually inserted, never for an upsert's update.
-- - RAISE fails the whole statement, and the whole batch around it (a workout save). The server answers 422 with the
--   message as the code (src/http/errors.ts); under Claude's writes it becomes words for Claude (src/mcp/d1-db.ts).
-- - Only an account's deletion removes these rows today, and the counts go with the account (ON DELETE CASCADE).
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
CREATE TRIGGER exercise_prefs_cap BEFORE INSERT ON exercise_prefs
  WHEN NOT EXISTS (SELECT 1 FROM exercise_prefs WHERE user_id = NEW.user_id AND exercise_id = NEW.exercise_id)
    AND coalesce((SELECT n FROM account_rows WHERE user_id = NEW.user_id AND tbl = 'exercise_prefs'), 0) >= 2000
BEGIN
  SELECT RAISE(ABORT, 'too_many_exercise_prefs');
END;
CREATE TRIGGER exercise_prefs_counted AFTER INSERT ON exercise_prefs
BEGIN
  INSERT INTO account_rows (user_id, tbl, n) VALUES (NEW.user_id, 'exercise_prefs', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER exercise_prefs_uncounted AFTER DELETE ON exercise_prefs
BEGIN
  UPDATE account_rows SET n = n - 1 WHERE user_id = OLD.user_id AND tbl = 'exercise_prefs';
END;
CREATE TRIGGER proposals_cap BEFORE INSERT ON proposals
  WHEN coalesce((SELECT n FROM account_rows WHERE user_id = NEW.user_id AND tbl = 'proposals'), 0) >= 5000
BEGIN
  SELECT RAISE(ABORT, 'too_many_proposals');
END;
CREATE TRIGGER proposals_counted AFTER INSERT ON proposals
BEGIN
  INSERT INTO account_rows (user_id, tbl, n) VALUES (NEW.user_id, 'proposals', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER proposals_uncounted AFTER DELETE ON proposals
BEGIN
  UPDATE account_rows SET n = n - 1 WHERE user_id = OLD.user_id AND tbl = 'proposals';
END;
CREATE TRIGGER gyms_total_cap BEFORE INSERT ON gyms
  WHEN NEW.owner_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM gyms WHERE id = NEW.id)
    AND coalesce((SELECT n FROM account_rows WHERE user_id = NEW.owner_id AND tbl = 'gyms'), 0) >= 500
BEGIN
  SELECT RAISE(ABORT, 'too_many_gyms_total');
END;
CREATE TRIGGER gyms_counted AFTER INSERT ON gyms
  WHEN NEW.owner_id IS NOT NULL
BEGIN
  INSERT INTO account_rows (user_id, tbl, n) VALUES (NEW.owner_id, 'gyms', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER gyms_uncounted AFTER DELETE ON gyms
  WHEN OLD.owner_id IS NOT NULL
BEGIN
  UPDATE account_rows SET n = n - 1 WHERE user_id = OLD.owner_id AND tbl = 'gyms';
END;
CREATE TRIGGER gym_equipment_total_cap BEFORE INSERT ON gym_equipment
  WHEN NEW.owner_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM gym_equipment WHERE id = NEW.id)
    AND coalesce((SELECT n FROM account_rows WHERE user_id = NEW.owner_id AND tbl = 'gym_equipment'), 0) >= 5000
BEGIN
  SELECT RAISE(ABORT, 'too_many_listings_total');
END;
CREATE TRIGGER gym_equipment_counted AFTER INSERT ON gym_equipment
  WHEN NEW.owner_id IS NOT NULL
BEGIN
  INSERT INTO account_rows (user_id, tbl, n) VALUES (NEW.owner_id, 'gym_equipment', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER gym_equipment_uncounted AFTER DELETE ON gym_equipment
  WHEN OLD.owner_id IS NOT NULL
BEGIN
  UPDATE account_rows SET n = n - 1 WHERE user_id = OLD.owner_id AND tbl = 'gym_equipment';
END;

-- Exercises and sets logged, deleted workouts included. A workout save deletes the workout's entries and sets and
-- writes the ones it carries, so it moves these two counts itself, once a save, by what it changes
-- (src/sync/workouts.ts, MOVE_ENTRIES and MOVE_SETS): row triggers here would write the count once per row deleted and
-- once per row written, on every save. These refuse a save that would take a count past its cap; a save that keeps or
-- lowers it always passes. The first count row an account gets is at most one workout's size, far under either cap.
CREATE TRIGGER account_rows_entries_cap BEFORE UPDATE OF n ON account_rows
  WHEN NEW.tbl = 'workout_entries' AND NEW.n > OLD.n AND NEW.n > 50000
BEGIN
  SELECT RAISE(ABORT, 'too_many_logged_exercises');
END;
CREATE TRIGGER account_rows_sets_cap BEFORE UPDATE OF n ON account_rows
  WHEN NEW.tbl = 'workout_sets' AND NEW.n > OLD.n AND NEW.n > 250000
BEGIN
  SELECT RAISE(ABORT, 'too_many_logged_sets');
END;

-- At most 100 proposals waiting for the owner (pending) per account, besides proposals_cap's 5,000 in all. Claude's
-- insert is the only writer (src/mcp/d1-db.ts, insertProposal), one row at a time, and a resolved proposal never turns
-- pending again (src/claude/proposals.ts refuses it), so a live count is enough: at most 100 rows, read through this
-- index, which the app's pull of pending proposals uses too.
CREATE INDEX proposals_user_pending ON proposals (user_id, created_at, id) WHERE status = 'pending';
CREATE TRIGGER proposals_pending_cap BEFORE INSERT ON proposals
  WHEN NEW.status = 'pending'
    AND (SELECT count(*) FROM proposals WHERE user_id = NEW.user_id AND status = 'pending') >= 100
BEGIN
  SELECT RAISE(ABORT, 'too_many_pending_proposals');
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

const full = (max: number, things: string, deleted = 'deleted ones', kept = 'This one') =>
  `You've reached the limit of ${grouped(max)} ${things} on one account, ${deleted} included. ` +
  `${kept} stays on this iPhone.`

/**
 * What migrations/0010_account_caps.sql RAISEs, with the app's words (src/http/errors.ts answers 422 with them). The
 * two proposal codes are raised only under Claude's insert, which words them for Claude (CLAUDE_CAPS).
 */
export const ACCOUNT_CAPS: Readonly<Record<string, string>> = {
  too_many_workouts: full(DomainLimits.workoutsMax, 'workouts'),
  too_many_body_weights: full(DomainLimits.bodyweightsMax, 'weigh-ins'),
  too_many_routines: full(DomainLimits.routinesMax, 'routines'),
  too_many_custom_exercises: full(DomainLimits.customExercisesMax, 'custom exercises'),
  too_many_exercise_prefs: `You've reached the limit of ${grouped(DomainLimits.exercisePrefsMax)} exercise ` +
    'preferences on one account. This one stays on this iPhone.',
  too_many_gyms_total: full(DomainLimits.privateGymsTotalMax, 'gyms'),
  too_many_listings_total: full(DomainLimits.privateListingsTotalMax, 'equipment listings'),
  too_many_logged_exercises:
    full(DomainLimits.accountEntriesMax, 'exercises logged', 'deleted workouts', 'This workout'),
  too_many_logged_sets: full(DomainLimits.accountSetsMax, 'sets logged', 'deleted workouts', 'This workout'),
  too_many_pending_proposals: `${grouped(DomainLimits.pendingProposalsMax)} proposals are waiting for review.`,
  too_many_proposals: `The account holds ${grouped(DomainLimits.proposalsMax)} proposals.`,
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

Expected: `Test Files  4 passed (4)`. The counts: 23 in `account-caps.test.ts`, 6 in the drift test, 9 more in the
schema test, 1 more in the limits test.

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  44 passed (44)`, `Tests  636 passed (636)`; `tsc` prints nothing. Every earlier test still
passes, so no sync, gym, Claude or account test came near a cap.

- [ ] **Step 8: Commit**

```bash
git add server/migrations/0010_account_caps.sql server/src/sync/caps.ts server/src/http/errors.ts \
  server/test/cap-fixtures.ts server/test/account-caps.test.ts server/test/domain-limits-drift.test.ts \
  server/test/schema.test.ts server/test/limits.test.ts scripts/test-sync-integration.sh
git commit -m "feat(server): per-account caps on what one account stores, deleted rows included"
```

- [ ] **Step 9: Review**

Ask **code-reviewer** for decisions 2–4, 6, 7, 11, 15 and 16: only new rows are refused; a refused push stores
nothing; `n` equals `count(*)` in every test (`countOf`); the words. Then **security-reviewer**: no route reads or
writes `account_rows` (`git grep -n account_rows -- server/src` finds nothing yet), another account's rows never
count, and a refusal names no other account's data. Then **typescript-reviewer**.

---

### Task 3: One workout's size, and the exercises and sets an account logs

**Files:**
- Modify: `server/src/sync/workouts.ts`, `server/src/sync/caps.ts`, `server/test/account-caps.test.ts`,
  `server/test/schema.test.ts`
- Test: `server/test/sync-workouts.test.ts`, `server/test/account-caps.test.ts`

- [ ] **Step 1: Check that the save is the only writer of entries and sets**

Run: `git grep -n -E '(INSERT INTO|UPDATE|DELETE FROM) workout_(entries|sets)' -- server/src`
Expected: three lines, all in `server/src/sync/workouts.ts` (`DELETE_ENTRIES`, `INSERT_ENTRIES`, `INSERT_SETS`). Any
other line: stop and report it. That writer would leave the logged counts wrong (decision 5).

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

In `server/test/account-caps.test.ts`, replace the import from `./cap-fixtures.ts` with

```ts
import { type CappedTable, countOf, kept, type LoggedTable, seedCount, seedRows } from './cap-fixtures.ts'
```

and the import from `./samples.ts` with

```ts
import { appUUID, KEY, type Row, SAMPLES, sampleNeeds, T1, T2, type WorkoutJSON, workoutSample } from './samples.ts'
```

add `const T4 = '2026-11-07T13:00:00.000000Z'` after `const T3 = …`, and add before `describe('the counts', …)`:

```ts
describe('exercises and sets logged, deleted workouts included', () => {
  /** A workout of `entries` exercises with `sets` sets each. */
  const sized = (entries: number, sets: number): WorkoutJSON => workoutSample({
    entries: Array.from({ length: entries }, (_, i) => ({
      id: appUUID(), exercise_id: `ex_${i}`, position: i, note: null, superset_group: null,
      sets: Array.from({ length: sets }, (_, j) => ({ id: appUUID(), position: j, w_kg: 60, r: 8 })),
    })),
  })
  const counts = async (userId: string) =>
    [await countOf('workout_entries', userId), await countOf('workout_sets', userId)]

  it('stay exact: a re-save moves nothing, a smaller one lowers them, a stale one and a deletion keep them',
    async () => {
      const { token, userId } = await signUp()
      const w = sized(3, 4)
      const first = await (await save(token, w)).json<Saved>()
      expect(await counts(userId)).toEqual([3, 12])
      const again = await (await save(token, {
        ...w, client_updated_at: T2, base_updated_at: first.updated_at,
      })).json<Saved>()
      expect(again.status).toBe('ok')
      expect(await counts(userId)).toEqual([3, 12])
      const stale = await (await save(token, {
        ...sized(5, 5), id: w.id, client_updated_at: T3, base_updated_at: first.updated_at,
      })).json<Saved>()
      expect(stale.status).toBe('stale')
      expect(await counts(userId)).toEqual([3, 12])
      const smaller = { ...w, entries: w.entries.slice(0, 2), client_updated_at: T3, base_updated_at: again.updated_at }
      const third = await (await save(token, smaller)).json<Saved>()
      expect(await counts(userId)).toEqual([2, 8])
      await save(token, { ...smaller, deleted_at: T4, client_updated_at: T4, base_updated_at: third.updated_at })
      expect(await counts(userId)).toEqual([2, 8])
    })

  interface Logged {
    readonly table: LoggedTable
    readonly max: number
    readonly code: string
    /** A new workout that adds exactly 1 to the count. */
    readonly one: () => WorkoutJSON
  }
  const LOGGED: Logged[] = [
    {
      table: 'workout_entries', max: DomainLimits.accountEntriesMax, code: 'too_many_logged_exercises',
      one: () => sized(1, 0),
    },
    { table: 'workout_sets', max: DomainLimits.accountSetsMax, code: 'too_many_logged_sets', one: () => sized(1, 1) },
  ]

  it.each(LOGGED)('$table: N-1 and N are saved, N+1 is refused whole and writes nothing', async (c) => {
    const { token, userId } = await signUp()
    await seedCount(c.table, userId, c.max - 2)
    expect((await save(token, c.one())).status).toBe(200)
    expect(await kept(c.table, userId)).toBe(c.max - 1)
    expect((await save(token, c.one())).status).toBe(200)
    expect(await kept(c.table, userId)).toBe(c.max)
    const refused = c.one()
    await refusedWith(await save(token, refused), c.code)
    expect(await kept(c.table, userId)).toBe(c.max)
    expect((await request('GET', `/v1/sync/workouts/${refused.id}`, { token })).status).toBe(404)
  })

  it('at the cap: a re-save passes, a bigger one is refused and changes nothing, a smaller one makes room',
    async () => {
      const { token, userId } = await signUp()
      await seedCount('workout_sets', userId, DomainLimits.accountSetsMax - 2)
      const w = sized(1, 2)
      const first = await (await save(token, w)).json<Saved>()
      expect(await kept('workout_sets', userId)).toBe(DomainLimits.accountSetsMax)
      const same = await (await save(token, {
        ...w, name: 'Pull', client_updated_at: T2, base_updated_at: first.updated_at,
      })).json<Saved>()
      expect(same.status).toBe('ok')
      const [entry] = w.entries
      const extra = { id: appUUID(), position: 2, w_kg: 60, r: 8 }
      const bigger = {
        ...w, entries: [{ ...entry, sets: [...entry.sets, extra] }], client_updated_at: T3,
        base_updated_at: same.updated_at,
      }
      await refusedWith(await save(token, bigger), 'too_many_logged_sets')
      const stored = await (await request('GET', `/v1/sync/workouts/${w.id}`, { token })).json<WorkoutJSON>()
      expect(stored.name).toBe('Pull')
      expect(stored.entries[0].sets).toHaveLength(2)
      const smaller = {
        ...w, entries: [{ ...entry, sets: entry.sets.slice(0, 1) }], client_updated_at: T3,
        base_updated_at: same.updated_at,
      }
      expect((await (await save(token, smaller)).json<Saved>()).status).toBe('ok')
      expect(await kept('workout_sets', userId)).toBe(DomainLimits.accountSetsMax - 1)
    })

  it("don't count another account's", async () => {
    const other = await insertUser()
    await seedCount('workout_entries', other, DomainLimits.accountEntriesMax)
    await seedCount('workout_sets', other, DomainLimits.accountSetsMax)
    const { token, userId } = await signUp()
    expect((await save(token, sized(1, 1))).status).toBe(200)
    expect(await counts(userId)).toEqual([1, 1])
  })
})
```

In `server/test/schema.test.ts`, add after the case on `proposals_pending_cap`:

```ts
  it("moves a workout's logged counts by reading its entries and sets through their indexes", async () => {
    for (const query of [
      'SELECT count(*) FROM workout_entries WHERE workout_id = ?1',
      'SELECT count(*) FROM workout_sets WHERE entry_id IN (SELECT id FROM workout_entries WHERE workout_id = ?1)',
    ]) {
      const plan = await env.DB.prepare(`EXPLAIN QUERY PLAN ${query}`).bind(crypto.randomUUID())
        .all<{ detail: string }>()
      const details = plan.results.map((r) => r.detail).join('\n')
      expect(details, query).toMatch(/INDEX workout_entries_workout\b/)
      expect(details, query).not.toMatch(/^SCAN/m)
    }
  })
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd server && npx vitest run test/sync-workouts.test.ts test/account-caps.test.ts test/schema.test.ts`
Expected: FAIL: `WORKOUT_CAPS` isn't exported from `../src/sync/caps.ts`. Once it is (Step 4), the logged-count tests
still fail: no save moves the counts yet, so `countOf('workout_entries', …)` finds 3 stored rows and a kept count of
0.

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

- [ ] **Step 5: The check and the count moves, in `server/src/sync/workouts.ts`**

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

`parseWorkout` runs first in `pushWorkout`, before the workout is read, so a save that is too big writes nothing.

After `INSERT_SETS`, add:

```ts

/**
 * Moves the account's count of logged entries or sets (account_rows, migrations/0010_account_caps.sql) by what this
 * save changes: the rows it writes (?4) minus the rows it replaces. Once a save, before the delete, and nothing when
 * the count stays. account_rows_entries_cap and account_rows_sets_cap refuse a move past a cap, and with it the batch.
 * The count is exact while this save is the only writer of entries and sets (plan 31, Task 3, Step 1).
 */
const moveCount = (tbl: 'workout_entries' | 'workout_sets', stored: string) =>
  `INSERT INTO account_rows (user_id, tbl, n)
SELECT ?3, '${tbl}', d FROM (SELECT ?4 - (${stored}) AS d) WHERE d <> 0 AND ${STILL_THIS_SAVE}
ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + excluded.n`
const MOVE_ENTRIES = moveCount('workout_entries', 'SELECT count(*) FROM workout_entries WHERE workout_id = ?1')
const MOVE_SETS = moveCount(
  'workout_sets',
  'SELECT count(*) FROM workout_sets WHERE entry_id IN (SELECT id FROM workout_entries WHERE workout_id = ?1)',
)
```

and in `pushWorkout`, replace

```ts
  const results = await db.batch([
    db.prepare(UPSERT).bind(...values, userId, writeId, force ? 1 : 0, base),
    db.prepare(DELETE_ENTRIES).bind(id, writeId),
    db.prepare(INSERT_ENTRIES).bind(id, writeId, userId, JSON.stringify(entryRows)),
    db.prepare(INSERT_SETS).bind(id, writeId, userId, JSON.stringify(setRows)),
    db.prepare('SELECT updated_at, write_id FROM workouts WHERE id = ?1').bind(id),
  ])
  const after = results[4].results[0] as { updated_at: string; write_id: string }
```

with

```ts
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
```

The moves come before `DELETE_ENTRIES`, so the rows they subtract are still there, and after the `UPSERT`, so
`STILL_THIS_SAVE` already knows whether the row is this save's.

- [ ] **Step 6: Run the tests to see them pass**

Run: `cd server && npx vitest run test/sync-workouts.test.ts test/account-caps.test.ts test/schema.test.ts`
Expected: PASS: 4 more tests in `sync-workouts.test.ts`, 28 in `account-caps.test.ts`, 1 more in the schema test.

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  44 passed (44)`, `Tests  646 passed (646)`; `tsc` prints nothing.

- [ ] **Step 7: Commit**

```bash
git add server/src/sync/workouts.ts server/src/sync/caps.ts server/test/sync-workouts.test.ts \
  server/test/account-caps.test.ts server/test/schema.test.ts
git commit -m "feat(server): one workout's size, and the exercises and sets an account logs"
```

- [ ] **Step 8: Review**

Ask **code-reviewer** for decisions 5, 8 and 14: a re-save moves no count; a smaller one lowers them; a stale save and
a deletion keep them; a save at both caps is stored whole; a refused save changes nothing. Then **typescript-reviewer**.

---

### Task 4: Claude's writes at a cap

**Files:**
- Modify: `server/src/mcp/d1-db.ts`, `server/src/sync/caps.ts`
- Test: `server/test/claude-caps.test.ts`

- [ ] **Step 1: Write the failing tests**

`server/test/claude-caps.test.ts`:

```ts
// Claude's writes at an account's storage caps (plan 31), through the MCP tools as Claude calls them: at most 100
// proposals waiting for review and 5,000 in all, and the account's 20,000 weigh-ins.
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
    expect(CLAUDE_CAPS.too_many_pending_proposals).toBe(
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
    expect(await propose(token))
      .toEqual({ isError: true, body: { error: CLAUDE_CAPS.too_many_pending_proposals } })
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

describe("Claude's proposals, at most 5,000 in all", () => {
  it('takes the 4,999th and 5,000th, and refuses the 5,001st though few are waiting', async () => {
    const c = await connectClaude()
    await seedProposals(c.userId, DomainLimits.proposalsMax - 2, 'dismissed')
    const token = c.tokens.access_token
    expect((await propose(token)).isError).toBe(false)
    expect((await propose(token)).isError).toBe(false)
    expect(await propose(token)).toEqual({ isError: true, body: { error: CLAUDE_CAPS.too_many_proposals } })
    expect(await pending(c.userId)).toBe(2)
    expect(await countOf('proposals', c.userId)).toBe(DomainLimits.proposalsMax)
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

The tests make at most four tool calls each, far under the 60 a minute.

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
  too_many_pending_proposals:
    `The owner already has ${grouped(DomainLimits.pendingProposalsMax)} proposals waiting for review, the most one ` +
    'account holds. Nothing was saved: ask the owner to apply or dismiss some in the app, then propose again.',
  too_many_proposals:
    `The owner's account already holds ${grouped(DomainLimits.proposalsMax)} proposals, resolved ones included, the ` +
    'most it can. Nothing was saved.',
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
/** `write`, with the refusal of one of its caps (migrations/0010_account_caps.sql) as words for Claude. */
async function capped<T>(write: Promise<T>, ...codes: (keyof typeof CLAUDE_CAPS)[]): Promise<T> {
  try {
    return await write
  } catch (error) {
    const raised = raisedCode(error)
    const code = codes.find((c) => c === raised)
    if (code !== undefined) throw new ToolError(CLAUDE_CAPS[code])
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
    >(), 'too_many_pending_proposals', 'too_many_proposals')
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
Expected: PASS; `claude-caps.test.ts` has 6 tests.

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: `Test Files  45 passed (45)`, `Tests  652 passed (652)`; `tsc` prints nothing.

- [ ] **Step 6: Commit**

```bash
git add server/src/mcp/d1-db.ts server/src/sync/caps.ts server/test/claude-caps.test.ts
git commit -m "feat(server): Claude hears why a proposal or a weigh-in was refused at a cap"
```

- [ ] **Step 7: Review**

Ask **code-reviewer** for decisions 6 and 13, and spec section 6 ("Claude's tool errors keep `ToolError`"). Then
**security-reviewer**: Claude's words name no other account's data, and the refused call is audited. Then
**typescript-reviewer**.

---

### Task 5: The phone stops at 50 exercises and 50 sets

Decision 9: nothing made by hand is past the per-workout caps, so the server never refuses it.

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

Ask **code-reviewer** for decision 9: every path that adds a set or an exercise to an active workout goes through the
three functions (`git grep -n -E 'appendingSet|insertingWarmup|appendingEntries' -- ios`). Then the same agent for
quality (Swift).

---

### Task 6: The importers split a workout past the caps

Decision 10. GymCore does the split, so every importer gets it; the app titles the pieces and keeps them together.

**Files:**
- Create: `ios/Packages/GymCore/Sources/GymCore/Import/ImportSplit.swift`,
  `ios/Packages/GymCore/Tests/GymCoreTests/ImportSplitTests.swift`
- Modify: `ios/Packages/GymCore/Sources/GymCore/Import/ImportTypes.swift`,
  `ios/Packages/GymCore/Sources/GymCore/Import/ImportSupport.swift`, `ios/GymRollins/Features/Import/ImportService.swift`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/ImportSplitTests.swift`, `ios/GymRollinsTests/ImportServiceTests.swift`

- [ ] **Step 1: Write the failing GymCore tests**

`ios/Packages/GymCore/Tests/GymCoreTests/ImportSplitTests.swift` (each importer's export is made in the test, from its
own header and row shape, so no fixture file is needed):

```swift
import Foundation
import Testing
@testable import GymCore

/// A workout from an export comes back as pieces the server stores (server/src/sync/workouts.ts): at most 50
/// exercises a piece and 50 sets an exercise, every set kept, in order.
@Suite struct ImportSplitTests {
    private let start = Date(timeIntervalSince1970: 1_767_636_000) // 2026-01-05 18:00 UTC
    private let utc = ImportOptions(weightUnit: .kg, timeZone: TimeZone(identifier: "UTC")!)

    private func entry(_ name: String, sets: Int) -> ImportedEntry {
        ImportedEntry(exerciseName: name, sets: (0..<sets).map { ImportedSet(weightKg: 60, reps: $0 + 1) })
    }

    private func workout(_ entries: [ImportedEntry]) -> ImportedWorkout {
        ImportedWorkout(id: UUID(), startedAt: start, entries: entries, name: "Big day", endedAt: start + 3_600)
    }

    @Test func aWorkoutThatFitsIsLeftAsItIs() {
        let fits = workout([entry("Bench", sets: 50)] + (1..<50).map { entry("Ex \($0)", sets: 1) })
        #expect(ImportSplit.pieces(fits) == [fits])
        let empty = workout([])
        #expect(ImportSplit.pieces(empty) == [empty])
    }

    @Test func anExerciseWithMoreThan50SetsGoesOnAsAnotherEntry() {
        let source = workout([entry("Bench", sets: 120), entry("Row", sets: 3)])
        let pieces = ImportSplit.pieces(source)
        #expect(pieces.count == 1)
        #expect(pieces[0].id == source.id && pieces[0].part == 1 && pieces[0].splitFrom == nil)
        #expect(pieces[0].entries.map(\.exerciseName) == ["Bench", "Bench", "Bench", "Row"])
        #expect(pieces[0].entries.map(\.sets.count) == [50, 50, 20, 3])
        #expect(pieces[0].entries.flatMap(\.sets) == source.entries.flatMap(\.sets))
    }

    @Test func moreThan50ExercisesGoOnInTheNextWorkoutsOneSecondApart() {
        let source = workout((0..<120).map { entry("Ex \($0)", sets: 2) })
        let pieces = ImportSplit.pieces(source)
        #expect(pieces.map(\.entries.count) == [50, 50, 20])
        #expect(pieces.map(\.part) == [1, 2, 3])
        #expect(pieces.map(\.id)[0] == source.id)
        #expect(pieces.dropFirst().allSatisfy { $0.splitFrom == source.id && $0.id != source.id })
        #expect(pieces.map(\.startedAt) == [start, start + 1, start + 2])
        #expect(pieces.allSatisfy { $0.name == "Big day" && $0.endedAt == source.endedAt })
        #expect(pieces.flatMap(\.entries) == source.entries)
        #expect(ImportSplit.pieces(source).map(\.id) == pieces.map(\.id)) // the same ids on every import
    }

    @Test func aLongExerciseMayContinueInTheNextWorkout() {
        let source = workout((0..<49).map { entry("Ex \($0)", sets: 1) } + [entry("Squat", sets: 70)])
        let pieces = ImportSplit.pieces(source)
        #expect(pieces.map(\.entries.count) == [50, 1])
        #expect(pieces[0].entries.last?.exerciseName == "Squat" && pieces[0].entries.last?.sets.count == 50)
        #expect(pieces[1].entries.map(\.exerciseName) == ["Squat"] && pieces[1].entries[0].sets.count == 20)
    }

    @Test func piecesAfterTheFirstAreNumberedWithinTheNameLimit() {
        #expect(ImportSplit.name("Push", part: 1) == "Push")
        #expect(ImportSplit.name("Push", part: 2) == "Push (2)")
        let long = String(repeating: "x", count: DomainLimits.workoutNameMax)
        #expect(ImportSplit.name(long, part: 1) == long)
        #expect(ImportSplit.name(long, part: 12).count == DomainLimits.workoutNameMax)
        #expect(ImportSplit.name(long, part: 12).hasSuffix(" (12)"))
    }

    /// One export per importer: a workout of 51 exercises, the first with 120 sets.
    private static let exports: [(ImportSource, String)] = [
        (.fitNotes, "Date,Exercise,Category,Weight (kg),Weight (lbs),Reps,Distance,Distance Unit,Time,Notes,Kind\n"
            + rows { "2026-01-05,\($0),Chest,60.0,,\($1 + 1),,,,,wr" }),
        (.strong, "Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,Notes,Workout Notes,RPE\n"
            + rows { "2026-01-05 18:00:00,Big day,1h 5m,\($0),\($1 + 1),60,\($1 + 1),0,0,,," }),
        (.hevy, "title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,"
            + "set_type,weight_kg,reps,distance_km,duration_seconds,rpe\n"
            + rows { #""Big day","5 Jan 2026, 18:00","5 Jan 2026, 19:10","","\#($0)",,"",\#($1),"normal",60,\#($1 + 1),,,"# }),
        (.fitbod, "Date,Exercise,Reps,Weight(kg),Duration(s),Distance(m),Incline,Resistance,isWarmup,Note,multiplier\n"
            + rows { "2026-01-05 18:00:00 +0000,\($0), \($1 + 1),60.0,0.0,0.0,0.0,0.0,false,, 1.0" }),
    ]

    /// "Ex 0" with 120 sets, then "Ex 1" … "Ex 50" with one set each: (exercise, set index) per row.
    private static func rows(_ row: (String, Int) -> String) -> String {
        ((0..<120).map { row("Ex 0", $0) } + (1...50).map { row("Ex \($0)", 0) }).joined(separator: "\n")
    }

    @Test(arguments: exports.map(\.0))
    func everyImporterSplitsAnOversizedWorkout(source: ImportSource) throws {
        let text = try #require(Self.exports.first { $0.0 == source }?.1)
        let result = try WorkoutImporters.parse(text, source: source, options: utc)
        #expect(result.rowErrors.isEmpty)
        #expect(result.workouts.map(\.part) == [1, 2])
        #expect(result.workouts.map(\.entries.count) == [50, 3])
        #expect(result.workouts.allSatisfy { $0.entries.allSatisfy { $0.sets.count <= DomainLimits.entrySetsMax } })
        let names = result.workouts.flatMap(\.entries).map(\.exerciseName)
        #expect(names == ["Ex 0", "Ex 0", "Ex 0"] + (1...50).map { "Ex \($0)" })
        #expect(result.workouts.flatMap(\.entries).flatMap(\.sets).count == 170)
        #expect(result.workouts[1].splitFrom == result.workouts[0].id)
        #expect(result.workouts[1].startedAt == result.workouts[0].startedAt + 1)
        #expect(try WorkoutImporters.parse(text, source: source, options: utc).workouts.map(\.id)
            == result.workouts.map(\.id))
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `(cd ios/Packages/GymCore && swift test --filter ImportSplitTests)`
Expected: the build fails: `cannot find 'ImportSplit' in scope`.

- [ ] **Step 3: The pieces' fields, in `ImportTypes.swift`**

In `ImportedWorkout`, replace

```swift
    /// Workout-level note (Strong "Workout Notes", Hevy `description`).
    public let note: String?

    public init(id: UUID, startedAt: Date, entries: [ImportedEntry], name: String? = nil, endedAt: Date? = nil,
                note: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.entries = entries
        self.name = name
        self.endedAt = endedAt
        self.note = note
    }
```

with

```swift
    /// Workout-level note (Strong "Workout Notes", Hevy `description`).
    public let note: String?
    /// 1, or the piece's number when a workout past the server's caps was split (`ImportSplit`).
    public let part: Int
    /// The source workout's id (piece 1's), on pieces 2 and later.
    public let splitFrom: UUID?

    public init(id: UUID, startedAt: Date, entries: [ImportedEntry], name: String? = nil, endedAt: Date? = nil,
                note: String? = nil, part: Int = 1, splitFrom: UUID? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.entries = entries
        self.name = name
        self.endedAt = endedAt
        self.note = note
        self.part = part
        self.splitFrom = splitFrom
    }
```

The defaults keep every existing caller as it is.

- [ ] **Step 4: Write `ios/Packages/GymCore/Sources/GymCore/Import/ImportSplit.swift`**

```swift
import Foundation

/// A workout from an export, cut into pieces the server stores (server/src/sync/workouts.ts): at most
/// `DomainLimits.workoutEntriesMax` exercises a piece, and at most `DomainLimits.entrySetsMax` sets an exercise.
/// - An exercise with more sets goes on as another entry of the same exercise, in the next piece when this one is full.
/// - Piece 1 keeps the source's id, start, end, title and note. Piece k starts k - 1 seconds after it, so the pieces
///   sort in order next to each other, has an id of its own made from the source's (the same on every import), and
///   names the source in `splitFrom`. The app titles it "<title> (k)" (`name(_:part:)`).
public enum ImportSplit {
    public static func pieces(_ workout: ImportedWorkout) -> [ImportedWorkout] {
        let entries = workout.entries.flatMap(runs)
        if entries.count <= DomainLimits.workoutEntriesMax && entries.count == workout.entries.count { return [workout] }
        let groups = stride(from: 0, to: entries.count, by: DomainLimits.workoutEntriesMax).map {
            Array(entries[$0..<min($0 + DomainLimits.workoutEntriesMax, entries.count)])
        }
        return groups.enumerated().map { index, entries in
            ImportedWorkout(id: index == 0 ? workout.id : ImportID.make([workout.id.uuidString, "part", "\(index + 1)"]),
                            startedAt: workout.startedAt.addingTimeInterval(TimeInterval(index)), entries: entries,
                            name: workout.name, endedAt: workout.endedAt, note: workout.note, part: index + 1,
                            splitFrom: index == 0 ? nil : workout.id)
        }
    }

    /// The title the user sees on piece `part`: the export's title (or the app's default), then " (2)", " (3)", …,
    /// within `DomainLimits.workoutNameMax`.
    public static func name(_ base: String, part: Int) -> String {
        guard part > 1 else { return String(base.prefix(DomainLimits.workoutNameMax)) }
        let suffix = " (\(part))"
        return String(base.prefix(DomainLimits.workoutNameMax - suffix.count)) + suffix
    }

    /// An entry's sets in runs of at most `DomainLimits.entrySetsMax`, each run an entry of its own.
    private static func runs(_ entry: ImportedEntry) -> [ImportedEntry] {
        guard entry.sets.count > DomainLimits.entrySetsMax else { return [entry] }
        return stride(from: 0, to: entry.sets.count, by: DomainLimits.entrySetsMax).map {
            ImportedEntry(exerciseName: entry.exerciseName,
                          sets: Array(entry.sets[$0..<min($0 + DomainLimits.entrySetsMax, entry.sets.count)]),
                          supersetGroup: entry.supersetGroup)
        }
    }
}
```

- [ ] **Step 5: Every importer splits, in `ImportSupport.swift`**

In `ImportAssembler.result`, replace

```swift
        return WorkoutImportResult(workouts: group(rows, id: id), rowErrors: errors,
```

with

```swift
        return WorkoutImportResult(workouts: group(rows, id: id).flatMap(ImportSplit.pieces), rowErrors: errors,
```

Run: `(cd ios/Packages/GymCore && swift test --filter 'Importer|ImportSplit')`
Expected: `Test run with 67 tests in 6 suites passed`: the four importers' suites and `WorkoutImportersTests` as
before (no fixture of theirs is past a cap), and the 6 new ones.

Run: `(cd ios/Packages/GymCore && swift test)`
Expected: `Test run with 541 tests in 65 suites passed`.

- [ ] **Step 6: The app's titles and duplicates**

In `ios/GymRollinsTests/ImportServiceTests.swift`, add inside `ImportServiceTests`, after `dedupeHelperUsesSortedStarts`:

```swift
    /// A split workout's pieces stay or go with their first piece (plan 31). A re-import keeps them all, though each
    /// piece starts a second after a workout already in the log; another app's copy of the session drops them all.
    @Test func aSplitWorkoutsPiecesStayOrGoTogether() throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let first = ImportedWorkout(id: UUID(), startedAt: base, entries: [])
        let second = ImportedWorkout(id: UUID(), startedAt: base.addingTimeInterval(1), entries: [], part: 2,
                                     splitFrom: first.id)
        let again = try ImportService.withoutDuplicates(
            [first, second], existing: [Workout(id: first.id, startedAt: base, name: "x")])
        #expect(again.0.map(\.id) == [first.id, second.id] && again.1 == 0)
        let otherApp = try ImportService.withoutDuplicates(
            [first, second], existing: [Workout(startedAt: base.addingTimeInterval(30), name: "x")])
        #expect(otherApp.0.isEmpty && otherApp.1 == 2)
    }

    @Test func piecesAfterTheFirstAreNumbered() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let untitled = ImportedWorkout(id: UUID(), startedAt: start, entries: [], part: 2, splitFrom: UUID())
        #expect(ImportService.workout(from: untitled, exerciseIds: [:], source: .fitNotes).name == "FitNotes workout (2)")
        let titled = ImportedWorkout(id: UUID(), startedAt: start, entries: [], name: "Push", part: 3, splitFrom: UUID())
        #expect(ImportService.workout(from: titled, exerciseIds: [:], source: .hevy).name == "Push (3)")
    }
```

Run (from `ios/`, the one-test run, `-only-testing:GymRollinsTests/ImportServiceTests`).
Expected: it builds (Step 3 added `part` and `splitFrom`), and the two new tests fail: the second piece is dropped
as a duplicate of the workout already in the log, and its title is "FitNotes workout".

In `ios/GymRollins/Features/Import/ImportService.swift`, replace

```swift
    /// direction, since their start says nothing about when the session happened.
    static func withoutDuplicates(_ imported: [ImportedWorkout], source: ImportSource = .fitbod,
                                  existing: [Workout]) throws -> ([ImportedWorkout], Int) {
        guard !isDateOnly(source) else { return (imported, 0) }
        let existingIds = Set(existing.map(\.id))
        let dateOnlyNote = workoutNote(for: .fitNotes)
        let starts = existing.filter { !($0.source == .import && ($0.note ?? "").hasPrefix(dateOnlyNote)) }
            .map(\.startedAt.timeIntervalSinceReferenceDate).sorted()
        let kept = imported.filter { workout in
            existingIds.contains(workout.id) || !hasStart(near: workout.startedAt, in: starts)
        }
        return (kept, imported.count - kept.count)
    }
```

with

```swift
    /// direction, since their start says nothing about when the session happened.
    /// The pieces of a split workout (`ImportSplit`) stay or go with their first piece. They start a second apart, so on
    /// their own a re-import would keep the first (its id is known) and drop the rest as its duplicates.
    static func withoutDuplicates(_ imported: [ImportedWorkout], source: ImportSource = .fitbod,
                                  existing: [Workout]) throws -> ([ImportedWorkout], Int) {
        guard !isDateOnly(source) else { return (imported, 0) }
        let existingIds = Set(existing.map(\.id))
        let dateOnlyNote = workoutNote(for: .fitNotes)
        let starts = existing.filter { !($0.source == .import && ($0.note ?? "").hasPrefix(dateOnlyNote)) }
            .map(\.startedAt.timeIntervalSinceReferenceDate).sorted()
        let firsts = imported.filter { workout in
            workout.splitFrom == nil
                && (existingIds.contains(workout.id) || !hasStart(near: workout.startedAt, in: starts))
        }
        let keptIds = Set(firsts.map(\.id))
        let kept = imported.filter { keptIds.contains($0.splitFrom ?? $0.id) }
        return (kept, imported.count - kept.count)
    }
```

and in `workout(from:exerciseIds:source:multiplier:)`, replace

```swift
        let name = imported.name.map { String($0.prefix(DomainLimits.workoutNameMax)) } ?? workoutName(for: source)
```

with

```swift
        let name = ImportSplit.name(imported.name ?? workoutName(for: source), part: imported.part)
```

For a piece 1 or a workout that wasn't split, the title is what it was.

Run the one-test run again, `-only-testing:GymRollinsTests/ImportServiceTests`.
Expected: every `ImportServiceTests` test passed, the two new ones among them, 0 failed.

- [ ] **Step 7: Commit**

```bash
git add ios/Packages/GymCore/Sources/GymCore/Import/ImportSplit.swift \
  ios/Packages/GymCore/Sources/GymCore/Import/ImportTypes.swift \
  ios/Packages/GymCore/Sources/GymCore/Import/ImportSupport.swift \
  ios/Packages/GymCore/Tests/GymCoreTests/ImportSplitTests.swift \
  ios/GymRollins/Features/Import/ImportService.swift ios/GymRollinsTests/ImportServiceTests.swift
git commit -m "feat(import): a workout past 50 exercises or 50 sets comes in as several, in order"
```

- [ ] **Step 8: Review**

Ask **code-reviewer** for decision 10: every set is kept and in order; the pieces' ids are the same on every import;
a re-import overwrites piece 1 and keeps the rest; another app's copy of the session drops them all; titles stay
within 80 characters. Then the same agent for quality (Swift).

---

### Task 7: A refused row on the phone, and one line per reason in Account

GymSync already turns every 422 into `SyncRecordRejected` with the server's words, and parks the row (decision 11).
This task pins that path for the caps, then groups identical refusals in Account (decision 12).

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
    /// Every code a sync push can meet at a cap; Claude's two proposal codes never reach the app.
    private let codes = ["too_many_workouts", "too_many_body_weights", "too_many_routines",
                         "too_many_custom_exercises", "too_many_exercise_prefs", "too_many_gyms_total",
                         "too_many_listings_total", "too_many_logged_exercises", "too_many_logged_sets",
                         "too_many_workout_exercises", "too_many_exercise_sets"]
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
Expected: `Test run with 3 tests in 2 suites passed` (after Task 6, run `swift package clean` here first if the build
can't find `ImportSplit`). These pass at once: GymSync already maps every 422 (`ApiSyncTransport.swift:156-166`) and
parks a refused edit (`SyncStore+Ownership.swift:66-68`). They pin that for the caps. If one fails, stop: decision 11
doesn't hold, and GymSync needs a fix before the server's caps can ship.

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

Ask **code-reviewer** for decisions 11 and 12: the refused row stays dirty and isn't sent again until edited; the edit
beside it syncs; the words reach Account unchanged. Then the same agent for quality (Swift).

---

### Task 8: The docs

**Files:**
- Modify: `docs/cloudflare-checklist.md`, `docs/release-readiness.md`, `server/README.md`

- [ ] **Step 1: The checklist's section 5**

In `docs/cloudflare-checklist.md`, replace from `## 5. Usage caps (decide before step 2; build them in a plan of their own)`
down to, and not including, `- [ ] **Unused OAuth clients**`, with:

```markdown
## 5. Usage caps (plan 31 built them; decide what is open before step 2)

**Built** (plan 31, `server/migrations/0010_account_caps.sql`; the numbers are `DomainLimits`', in
`ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift`):
- Per account, deleted rows included: 10,000 workouts, 50,000 exercises and 250,000 sets logged in them, 20,000
  weigh-ins, 200 routines, 1,000 custom exercises, 2,000 exercise preferences, 500 private gyms and 5,000 private
  listings.
  - **Deleted rows count.** A deletion stays as a tombstone (`deleted_at`), so other devices learn of it, and nothing
    purges tombstones. So deleting frees nothing: an account that reaches a cap stays there. Only sets removed from a
    workout free room.
- Private gyms (100) and private listings (1,000) also keep their live caps (`0005_gyms_photos.sql`).
- Claude: 100 proposals waiting for review at a time, and 5,000 in all.
- One workout holds at most 50 exercises, and an exercise at most 50 sets in it. The app stops there, and the importers
  split a bigger workout into several ("Push", "Push (2)").
- A refused row stays on the phone. Account lists it under "N items couldn't sync", with the server's words, and it
  isn't sent again until it is edited.
- One account at the caps holds about 70 MB of sets; a free D1 database holds 500 MB in all.

**Open** (plan 31, "Questions for the owner"):
- [ ] Claude's audit rows: 90 days kept, up to 60 a minute.
- [ ] A big workout re-saved again and again: about 10,000 rows written a save at both per-workout caps, against the
      free plan's 100,000 a day. Section 1's rate limits are the only guard.
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
- `0010_account_caps.sql` caps what one account stores, deleted rows included: triggers, with the counts in
  `account_rows`; the workout save moves the counts of logged exercises and sets itself (`src/sync/workouts.ts`). The
  numbers are `DomainLimits`', and `test/domain-limits-drift.test.ts` checks them. The words are in `src/sync/caps.ts`.
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

### Task 9: Verify everything, and the Outcome

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

Expected: `Test Files  45 passed (45)`, `Tests  652 passed (652)`; `tsc` prints nothing; `account_rows` only in
`server/src/sync/workouts.ts` (the count moves; no route reads it); `server/migrations/0010_account_caps.sql:27` (three
triggers for each of the eight counted tables, two on the logged counts, and the pending proposals' one).

- [ ] **Step 2: The Swift packages**

Run:

```bash
(cd ios/Packages/GymCore && swift test)
(cd ios/Packages/GymData && swift package clean && swift test)
(cd ios/Packages/GymSync && swift package clean && swift test --filter GymSyncTests)
scripts/test-sync-integration.sh
```

Expected: GymCore `Test run with 541 tests in 65 suites passed`; GymData as plan 30 left it (371 tests in 50 suites);
GymSync `Test run with 217 tests in 28 suites passed`; the integration suite as plan 30 left it (`Test run with 45
tests in 11 suites passed`), then `Account deletion verified: … deleted users, 0 rows left`.

- [ ] **Step 3: The server move, on a copy of the owner's data**

With the backup Task 1, Step 2 measured: `scripts/server-move-check.sh "$BACKUP" <a work folder outside the repo>`.
It only reads the backup and puts its own copies in the work folder.
Expected: `Server move verified.`, with every count equal on both sides (148 workouts, 836 entries, 2,685 sets, or the
newer backup's). Nothing of the owner's data is refused by a cap.

Without the backup, write "not run" in the Outcome; the cutover's comparison (checklist, section 10) then covers it.

- [ ] **Step 4: Everything**

Run: `SYNC_E2E=1 MCP_E2E=1 PHOTO_E2E=1 GYM_E2E=1 scripts/test-all.sh`
Expected: it ends with exit 0. Plan 30 found two accessibility audits that fail now and then
(`testClaudeConnectionAudit`, `testUnblockEveryoneAudit`); if one fails, re-run it alone and record both runs.

- [ ] **Step 5: The Outcome**

Fill in `## Outcome` below: the base sha, Task 1, Step 2's line, each task's commits, the counts above, anything that
differed from this plan, and anything left for the owner. Commit:

```bash
git add docs/plans/2026-11-08-plan-31-account-caps.md
git commit -m "docs: plan 31 outcome"
```

---

## Self-review against the spec

**Coverage**

| Spec, checklist or ask | Where |
|---|---|
| Checklist §5: per-user row caps, "a trigger or a conditional insert, with a test at the exact number" | Tasks 2–4; decisions 2–8 |
| Checklist §5: tombstone caps | decision 4: tombstones count toward the caps (the owner's choice); no purge |
| The owner's totals: 250,000 sets, 50,000 entries, 2,000 exercise preferences, 5,000 proposals, 500 gyms and 5,000 listings | decisions 5–7; Tasks 2–4 at the exact numbers |
| The owner: a re-save doesn't grow the counts; a save past a cap is refused whole and writes nothing | decision 5; Task 3's logged-count tests |
| The owner: split oversized imports, every importer, sensible times and titles | decision 10; Task 6 |
| The owner: workouts already on a phone past the caps | decision 10: they stay on the phone, listed in Account |
| The owner: measure the backup before code | Task 1, Step 2; the numbers in "Facts checked" |
| The owner: rows written, and a normal session's cost | decision 14 |
| Spec §1 criterion 2: the daily limits and caps keep working | the gym caps and daily limits are untouched; Task 2, Step 7 runs every earlier test |
| Spec §1 criterion 3: isolation | another account's rows never count (Tasks 2–4); no route reads `account_rows` (Task 9, Step 1) |
| Spec §1 criterion 8: the free plan | no KV, no Durable Objects; decision 14's costs |
| Spec §4 Sync: last-write-wins, acks | unchanged; an edit at the cap is stored and acked (Task 2) |
| Spec §4: requests within D1's limits | decision 15; a workout at both caps stays under 1 MB (Task 3) |
| Spec §6: one error body; 422 for a refused row, with the code | decision 11; Tasks 2 and 3 check the body |
| Spec §6: Claude's tool errors keep `ToolError` | decision 13; Task 4 |
| Spec §8: every cap at its exact number | Tasks 2–4 (N-1, N, N+1); Task 2's requests that arrive together |
| Spec §7: the owner's data stays out of the repo | Task 1, Step 2 and Task 9, Step 3 read copies outside it, numbers only |
| The owner: the phone keeps the data, no retry loop, a plain message | decisions 11 and 12; Task 7 |
| The owner: one place for the numbers, with the drift test | decision 1; Tasks 1 and 2 |

**What this plan found that the spec says differently** (for its next revision):
1. **§6 lists the error codes.** Plan 31 adds thirteen: `too_many_workouts`, `too_many_body_weights`,
   `too_many_routines`, `too_many_custom_exercises`, `too_many_exercise_prefs`, `too_many_gyms_total`,
   `too_many_listings_total`, `too_many_logged_exercises`, `too_many_logged_sets`, `too_many_workout_exercises`,
   `too_many_exercise_sets`, and for Claude only `too_many_pending_proposals` and `too_many_proposals`.
2. **§2, "Locks and limits", says each limit is "insert only if the count is under the limit".** A multi-row push
   can't be: it would skip rows silently and the phone would push them again forever (decision 2). The caps are
   triggers, as plan 28's gym caps already were.
3. **§1, "Out of scope", says no changes to the SwiftData models.** None here: `SyncFailure` keeps its fields, and
   `ImportedWorkout` (two new fields) is GymCore's import model, not stored.

**Placeholders:** none in the steps. The Outcome is empty by design. Task 1, Step 2 names the backup folder as the owner
keeps it. Every code block is a file's full new text or an exact replacement.

**Names used across tasks:** `account_rows`, `seedRows`, `countOf`, `seedCount`, `kept`, `CappedTable`, `LoggedTable`,
`CountedTable` (Task 2); `ACCOUNT_CAPS` (Task 2), `WORKOUT_CAPS`, `MOVE_ENTRIES`, `MOVE_SETS` (Task 3), `CLAUDE_CAPS`
and `capped` (Task 4), `grouped` (Task 2); `canAddSet`, `canAddEntries` (Task 5); `ImportSplit`, `part`, `splitFrom`
(Task 6); `SyncFailureLine`, `failureLines`, `failuresFooter`, `capBodyweight`, `bodyweightCapWords` (Task 7). Each is
defined in the task that first needs it.

## Questions for the owner

1. **Claude's audit.** It keeps 90 days of calls (`d1-db.ts:553`), up to 60 a minute, so up to about 7.8 million rows
   for one busy connection. Cap it per account, shorten the 90 days, or leave it to the rate limit?
2. **Re-saving a big workout.** A workout at both per-workout caps costs about 10,000 rows written on every re-save
   (decision 14), so about 9 a day use the free plan's 100,000 for everyone. Lower the per-workout caps, rely on the
   per-IP rate limits (checklist, section 1), or move to Workers Paid before others sign up?
3. **The size of the whole database.** One account at the caps holds about 69 MB of sets alone (250,000 × about 276
   bytes). The free plan's database holds 500 MB for every account together, so about seven such accounts fill it.
   Fine for one owner; before sign-ups open, Workers Paid (10 GB) or lower totals?
4. **Shared gyms and listings.** The new totals count private rows only (decision 7). Shared ones an account adds are
   bounded by the daily limits (10 gyms and 30 listings a day) but not in total. Leave them to the daily limits?
5. **The words.** "You've reached the limit of 20,000 weigh-ins on one account, deleted ones included. This one stays
   on this iPhone." Keep, or reword before the cutover? They live in `server/src/sync/caps.ts`, and only the server
   changes.
6. **A later plan: indexes for the pulls** (decision 17), before many accounts exist.

## Outcome

Built on 2026-11-08, on `feat-cloudflare`, from base `e60f376` (the plan's last commit). Local only, not pushed. No
Cloudflare account, resource or deploy; nothing on the phone or claude.ai.

**The owner's sizes** (Task 1, Step 2's query, run again in Task 9 on the server-move check's own copy of the backup):
`15|8|148|836|2685|23|6|42|0|4|1|1`, the line in "Facts checked". At most 15 exercises in a workout and 8 sets in an
exercise, so nothing of the owner's is split, and every count is far under its cap.

**Commits**

| Task | Commits |
|---|---|
| 1 The numbers in `DomainLimits` | `402674b` |
| 2 The account caps in D1 | `6729bee` |
| 3 One workout's size, and the logged counts | `132cadd` |
| 4 Claude's writes at a cap | `958b702` |
| 2–4, added after review | `938a2e6` (the counts on deletion and in the migration's backfill, an account at every cap deleted whole, resolved proposals still counting); `c7a25cd` (the logged counts after a lost race, a force save, a lost answer's retry, a bigger re-save and a revival) |
| 5 The phone stops at 50 and 50 | `c6d7a05`; after review `386b463` (Add exercise picks no more than the workout has room for; Add warm-up set stops at 50 sets) |
| 6 The importers split | `0bbb98b`; after review `aac1971` (the pieces follow each other through the session) and `6dfbaad` (a split workout counts once in the preview, the summary and the duplicates skipped) |
| 7 A refused row, one line per reason | `63f0ccb`; after review `2484205` (each line reads as one sentence; no promise of a retry at an account cap) |
| 8 The docs | `9c82ffa` |
| 9 Verify, and small fixes | `e04dcbe`, `f6bac10`, `d566ee3` (below); this Outcome |

**Task 9's small fixes**
1. `f6bac10`: `RealExportImportTests` (opt-in, `GYM_REAL_EXPORT`) compares the stored rows with the pieces
   (`plan.result.workouts.count`), and checks that the summary counts the export's workouts (`plan.stats.workouts`)
   and skips no duplicates. Its `142` still means the export's workouts: `stats.workouts` counts a split workout once
   since `6dfbaad`, and none of the owner's is past the caps. It compiles (`build-for-testing`); it can't run without
   the owner's export.
2. `e04dcbe`: `ImportSplitTimesTests`, a table of 14 start and end combinations (an hour, a start off the whole second,
   seven pieces, one piece with far fewer sets, a first piece with none, no sets at all, exactly and just under a
   second a piece, a span shorter than the pieces, an end at or before the start, no end time). With a span of at
   least a second a piece: the durations sum to the span, no overlap or gap, starts strictly increase, every piece
   lasts a second or more, the last ends at the source's end. Without one: the pieces start a second apart and keep
   the source's end. With the minimum-second pass removed from `ImportSplit.times`, the table fails.
3. `d566ee3`: the current docs give the API's address as `https://api.gymrollins.com` (the owner's custom domain,
   checklist section 1, option A): `docs/release-readiness.md`, `docs/media/README.md`'s cloud upload commands,
   `docs/design/STYLE.md` and the two design canvases showing the connector URL. The checklist's own `workers.dev`
   lines explain option B and stay.
4. **The two intermittent audits: not fixed.** About 22 minutes, each try `-test-iterations 5` on just the two tests:
   - Try 1: scroll to the end of the list, wait until two checks half a second apart see the same frame (and, for
     Unblock, until the dialog is gone), then audit. `testClaudeConnectionAudit` 4 of 5, `testUnblockEveryoneAudit`
     4 of 5.
   - Try 2: the same, with contrast audited first and Dynamic Type in a call of its own. 3 of 5 and 3 of 5.
   - Unblock's failures at the end all flag the "Apple Health" row (its label and the "Off" badge at y = 123.5, 3.5
     points past the 120-point top band the test excludes): the list's end puts that row at the navigation bar's edge. The Claude failures
     came at offsets short of the end (a swipe that didn't move the list ended the loop); there, at rest, "Approve a
     connection", "Show all", "Copy prompt", the Project note and "What Claude can do" (y 268 to 665) were flagged,
     though the screenshot shows them at full contrast.
   - Reverted; nothing committed.

**Final counts** (`DEST='platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2'` with `SYNC_E2E`, `MCP_E2E`,
`PHOTO_E2E` and `GYM_E2E`)
- Guard: `Old backend gone: no folder, no name outside docs/plans, docs/specs and docs/research, no script running Docker.`
- Server: `Test Files  46 passed (46)`, `Tests  669 passed (669)` on the re-run; `tsc --noEmit` clean. In the full run
  `Tests  1 failed | 668 passed (669)` (failure 3 below). `git grep -n account_rows -- server/src` finds only
  `server/src/sync/workouts.ts` (the count moves, at `:83`, and two comment lines); `0010_account_caps.sql` has 27
  `CREATE TRIGGER`.
- GymCore `Test run with 548 tests in 66 suites passed`; GymData 372 tests in 50 suites; GymSync `Test run with 217
  tests in 28 suites passed`; GymHealth 85 in 17; GymWatchLink 63 in 8. The Watch app builds for `watchsimulator` and
  `watchos`.
- Integration: `Test run with 45 tests in 11 suites passed`; `Account deletion verified: 66 deleted users, 0 rows left`.
- App unit and UI suite: 1,164 tests, 1,144 passed, 18 skipped, 2 failed (failures 2 and 4 below).
  - Skipped, all opt-in: `SyncUITests` 5 and `ProposalSyncUITests` 3 (need a Worker), `ReadmeScreenshotsUITests` 8,
    `StoragePhotoIntegrationTests` 1, `RealExportImportTests` 1.
- Sync UI: 8 tests, 7 passed, 1 skipped (the server-move test), 0 failed.
- Node: share page `# pass 17`; photo matcher 13; wger 21; alias tables 13; photo prompts and generator 32; strength
  14; uploader 22; seeds 3, and both `--check` runs match; store comparison 4. Every one `# fail 0`.
- `MCP_E2E`: 12 `ok` lines, from `discovery: 401 on /mcp points at the resource metadata` to `Disconnect Claude removed
  1 connection(s); the next call got 401`.
- `PHOTO_E2E`: `done: 2 uploaded`, then `done: 0 uploaded, 2 skipped, 0 failed; manifest unchanged (1 exercises)`, then
  `Test uploadedPhotosLoadThroughTheManifestAndProvider() passed`.
- `GYM_E2E`: `Test run with 5 tests in 1 suite passed`; `Stays on the phone verified: 5 markers absent from gyms,
  gym_equipment, equipment_items; 1 control present`.
- **No run of `scripts/test-all.sh` ended `exit 0`.** The first stopped at GymHealth (`exit 1`, failure 1); the second
  at the app suite (`exit 65`). The blocks after the app suite then ran from a copy of `test-all.sh`'s own lines that
  goes on past a failure: all passed apart from the server's one test (failure 3), which passed on its re-run. No
  tracked file changed (no screenshot re-rendered).

**The failures** (none caused by plan 31)
1. **GymHealth's build, first run:** `cannot find 'ImportSplit' in scope` in GymCore's `ImportSupport.swift`. It is the
   stale incremental build "How to run things" describes, in a package Task 9, Step 2 doesn't clean. After
   `swift package clean` there, GymHealth passed (85 in 17), and the second run passed it too.
2. **`AccessibilityAuditUITests/testUnblockEveryoneAudit`:** contrast on two of Settings' section headers (y = 135 and
   245); alone it failed again (one header, y = 228). Plan 30 found it intermittent on the code before the migration
   too. Plan 31 changes no Settings code and not this test (`git log e60f376..HEAD -- ios/GymRollins/Features/Settings`
   is empty). See Task 9's fix 4.
3. **Server, `claude-proposals.test.ts`, "lists the account's pending proposals, oldest first":** the two proposals
   came back in the other order. The pull orders by `created_at, id`, and `created_at` is SQLite's `now`, to the
   millisecond, so two proposals written in the same millisecond fall back to their random ids. The query and the
   test are `6d2f2f7`'s, before plan 31; the new index `proposals_user_pending (user_id, created_at, id)` doesn't
   change the order asked for. It passed in the server's re-run and in 6 runs of the file alone.
4. **`EmptyStatesUITests/testLibraryNoResultsOffersCreateCustomExercise`:** the search field got
   `Zzznotarealexerc` of `Zzznotarealexercise` (keystrokes dropped). It passed when re-run alone. Plan 31 touches no
   Library code.

**The server-move check** (numbers only; phone and D1 equal on every line): workouts 148, entries 836, sets 2,685,
routines 6, body weights 23, custom exercises 42, week days 4, profile 1, exercise preferences 0, muscle targets 0,
private gyms 0, private listings 0, workouts at a gym 0, entries at a listing 0; unsynced 0; `Stores match apart from
sync state.`, then `Server move verified.` Nothing of the owner's data was refused by a cap.
- It took three attempts, each on a fresh work folder outside the repo. The first hung: the new simulator never drew
  a screen (`simctl io` gave `Timeout waiting for screen surfaces`) and no request reached the Worker in 20 minutes;
  stopping `xcodebuild` let the script clean up. The second failed before any data moved: the email field never took
  keyboard focus (the 5-second `hasKeyboardFocus` wait). The third passed, in about 8 minutes with the build.
- The three work folders still hold copies of the backup, for the owner to delete.

**Where the build differs from this plan:**
1. **Counts.** The server is at 46 files and 669 tests, not 45 and 652: `account-rows.test.ts` and the other review
   tests (`938a2e6`, `c7a25cd`). GymCore 548 in 66, not 541 in 65 (`386b463` +1, `aac1971` +5, `e04dcbe` a suite of
   1). GymData 372, not 371 (`2484205`).
2. **`SyncFailure` keeps the server's code** (`2484205`): an optional `code`, so failures stored before decode with
   none, and `SyncEngine.recordRejection` passes it. Decision 12 said the stored `SyncFailure` wouldn't change, and
   decision 11 that no GymSync code would. It lets Account drop "Editing one tries again." when every refused row hit
   an account cap, where an edit is refused again; otherwise the footer reads as decision 12 says.
3. **The phone's caps reach further** than Task 5's buttons (`386b463`): Add exercise lets the picker choose no more
   than the room left, and Add warm-up set stops at 50 sets.
4. **The split's times and counts** changed after review (`aac1971`, `6dfbaad`); decision 10 records the times.
5. **`scripts/test-all.sh` never ended `exit 0` in one run,** as in plan 30 (above).
6. **The server-move check** needed three attempts (above).

**Left open for the owner** ("Questions for the owner" 1–6 are all still open):
- **Deleting an account at every cap writes about 349,000 rows** (an estimate made in review), against the free plan's
  100,000 a day. Move to Workers Paid before inviting anyone else. The checklist doesn't list this yet.
- Claude's audit rows have no per-account cap (90 days kept, up to 60 a minute; question 1).
- Shared gyms and listings are bounded only by the daily limits (question 4).
- Indexes for the pulls (decision 17), a later plan before many accounts exist (question 6).
- The refusals' words, in `server/src/sync/caps.ts` (question 5).
- Re-saving a workout at both per-workout caps, and the database's size (questions 2 and 3).
- A split workout without an end time (Fitbod, FitNotes): the app gives each piece its own estimated end
  (`ImportService.endedAt`: 45 minutes or more unless every set is timed), so the pieces overlap and its time counts
  once a piece. With an end
  time they share it (decision 10). No workout of the owner's is split.
- The two intermittent audits (Task 9's fix 4, and failure 2).
- `ReadmeScreenshotsUITests.swift:164` still launches with a `workers.dev` `API_URL`. It draws the tracked README
  screenshots, so changing it means rendering them again.
