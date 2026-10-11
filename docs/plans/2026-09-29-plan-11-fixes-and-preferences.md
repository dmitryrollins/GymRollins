# Plan 11: Large-phone accessibility fixes, a flaky UI test, exercise preferences

> Steps use checkbox (`- [x]`) syntax for tracking. TDD throughout: every change starts with a failing test.

**Goal:** (1) the accessibility audits pass on iPhone 17 Pro Max (the owner's 14 Pro Max class of screen) as well as
17 Pro, with real fixes, no new exclusions; (2) `WorkoutFlowUITests.testEditConsecutiveFieldsWithoutLeavingScreen`
stops failing as the first workout test of a run; (3) per-exercise recommendation preferences like Fitbod's
exercise ··· menu: **Recommend more often / Recommend less often / Don't recommend again**.

**Branch:** `feat-fixes-prefs` from `main`. Commit per task with the trailer lines. Never `git add -A`.

---

### Task 1: Accessibility audit on 17 Pro Max

- [x] Run `AccessibilityAuditUITests` on an iPhone 17 Pro Max simulator; record each issue with its element frame.
- [x] `body.lift.<id>` (Body → Est. 1RM rows): the row's hit region is its text height (< 44 pt). Give the row a
  44 pt minimum height and a full-width content shape inside the `NavigationLink` label.
- [x] Profile Setup experience picker: "Intermediate" is clipped in its third of the segmented control. Let the
  segment labels shrink/wrap instead of truncating (`minimumScaleFactor`, `lineLimit`) and fall back to a vertical
  layout (`ViewThatFits`) when the three labels don't fit side by side (large Dynamic Type).
- [x] Logging chips ("Swap"): the chip row scrolls horizontally, and on the wider screen "Swap" sits over the
  bright hero edge / scroll-edge fade so the glass samples too light a background. Give the chips a dark tint so
  the white label keeps ≥ 4.5:1 whatever is behind the glass.
- [x] Audits pass on 17 Pro and 17 Pro Max.
- [x] **Commit:** `fix(a11y): large-phone hit region, clipping and contrast`

### Task 2: Flaky first workout test

Root cause (found by reading the order of the suite): `TodayPlanStore` persists today's switched/edited plan in
`UserDefaults.standard`, keyed by day. UI tests run with an in-memory store but the same defaults and the same
`-fixedNow` day, so the last `TodayFlexUITests` test (`testSwitchToAnEmptyWorkoutAndAddAnExercise`, alphabetically
last) leaves an *empty workout with Chest Dip* stored for 2026-09-26. The next class alphabetically is
`WorkoutFlowUITests`, whose first test (`testEditConsecutive…`) then starts that stored workout — no
`workout.entry.0025` → failure at line 58. Starting the workout clears the stored plan, so a rerun passes.

- [x] Unit test: an `AppEnvironment` built on a fresh store (in-memory or `-resetStore`) ignores a today plan
  stored by an earlier launch (fails first).
- [x] Fix: a fresh store clears `TodayPlanStore` at launch (the stored plan belongs to data that no longer exists);
  the local-data reset (sign-out / account switch / erase) clears it too.
- [x] UI regression test: switch to an empty workout, relaunch, Today shows the scheduled routine again.
- [x] Proof: the test 5× cold (after `simctl erase`), the `TodayFlex → WorkoutFlow` order that used to fail, and
  the full `WorkoutFlowUITests` class — all green.
- [x] **Commit:** `fix(today): a fresh store doesn't reuse an old today plan`

### Task 3a: Exercise preferences — model, store, sync

- [x] GymCore `ExercisePreference` (`more | normal | less | never`) and `ExerciseRanking` (stable ordering: more,
  normal, less; `never` dropped from suggestions, kept last in an explicit search). Tests first.
- [x] GymData `ExercisePreferenceRecord` (id = exercise id, `prefRaw`, sync bookkeeping; `normal` is stored, not
  deleted, so a reset syncs like any edit) + `ExercisePreferenceRepository` (`all`, `preference(for:)`,
  `set(_:for:)`, `hidden()`); `SyncStore` dirty/applyRemote/markSynced; `resetAll` wipes it. Tests first.
- [x] Supabase migration `exercise_prefs` (`user_id, exercise_id` PK, `pref` check, `client_updated_at`,
  `updated_at`, LWW + updated_at triggers, RLS: owner full access, MCP read-only behind `mcp_flag('plan')`,
  no anon). pgTAP tests.
- [x] GymSync `ExercisePrefDTO`, transport push/pull (`onConflict: user_id,exercise_id`, tiebreak
  `exercise_id`), engine push/pull after custom exercises; FakeTransport; tests first.
- [x] **Commit(s):** `feat(prefs): …`

### Task 3b: Exercise preferences — UI and effect

- [x] Today row ··· menu: "Recommend more often" / "Recommend less often" toggles (checkmark = current),
  "Don't recommend again" (confirmation dialog). Exercise detail screen: the same three in a toolbar ··· menu.
- [x] Settings → Training → "Hidden exercises": list of `never` exercises, each with "Show again" (→ normal).
- [x] Swap/Replace sheet and the exercise picker's suggestion list: `more` first, `less` last, `never` hidden;
  typing a search still finds `never` exercises. Progression untouched.
- [x] Unit tests for ordering, UI tests for the menu, confirmation, hidden list and the picker.
- [x] **Commit:** `feat(prefs): recommend more/less/never from Today and exercise detail`

### Task 3c: Exercise preferences — MCP

- [x] `Db.exercisePreferences()`; `get_plan` returns `exercise_preferences` (more/less/never lists with names);
  `search_exercises` marks each result's `preference`; tool descriptions say never to propose a `never` exercise.
- [x] `propose_plan_changes` rejects adding/swapping to a `never` exercise (defence in depth).
- [x] Deno tests (FakeDb) first.
- [x] **Commit:** `feat(mcp): expose exercise preferences read-only`

### Task 4: Inline set editing on Today (owner request)

Tapping an exercise row on Today expands it in place (one open at a time, animated unless Reduce Motion) to show
its planned sets; the sets are edited right there instead of on another screen.

- [x] `TodayPlan` gains per-exercise planned sets for today (`TodaySets`: weight kg, reps / seconds, warm-up flag)
  plus the exercise's rest. Built from what Start Workout would plan (`SessionPlanner`, progression-suggested
  weights) the first time a row is edited; untouched rows keep following the plan. Edits: weight, reps/seconds,
  add set, remove set, toggle warm-up, rest; `resetSets` goes back to the suggestion. Unit tests first
  (edit, add/remove, warm-up, reset, next-day discard via `TodayPlanStore`, save-to-routine includes set count,
  reps range top, working weight and rest).
- [x] `routineToStart` / `startSession` use the edited sets: `SessionPlanner` gets optional per-exercise set
  overrides, so the workout starts with exactly the values shown (test first).
- [x] "Save Changes to <routine>": set count, reps, working weight and rest go into the routine item.
- [x] UI: `TodayExerciseRow` (own file, so TodayView only swaps its row) — thumbnail/name tap expands; expanded
  rows show `SetTimelineRow`-style fields with numeric keyboards, − / + steppers (plate step via `LoadRounder`), add /
  remove set, warm-up toggle, rest stepper, an "edited" badge and "Reset to suggested". Keyboard toolbar Next/Done;
  the scroll view keeps the focused field above the keyboard and the bottom bar hides while typing.
- [x] Accessibility: the row announces expanded/collapsed; fields are labelled "Set 2 weight, pounds".
- [x] UI tests: expand, edit set 2 weight and reps, add a set, collapse, relaunch keeps edits, Start Workout shows
  the edited values on the logging screen, save to routine.
- [x] **Commit:** `feat(today): edit today's sets inline`

### Task 5: Verification and review

- [x] `scripts/ios-test.sh` (own simulator), GymCore/GymData/GymSync `swift test`, `scripts/test-db.sh`, deno MCP
  tests, swiftlint 0 errors.
- [x] `codex review --base main`; fix P0–P2 test-first until clean.

---

### Outcome

- Accessibility audits pass on iPhone 17 Pro and 17 Pro Max. The chip contrast failure was "Swap" half off the
  screen edge in the horizontally scrolling chip row; the chips now wrap (`FlowLayout`).
- Flaky test: reproduced by disabling the fix (fails at `WorkoutFlowUITests.swift:58` right after
  `TodayFlexUITests.testSwitchToAnEmptyWorkoutAndAddAnExercise`); with it, 5/5 cold runs after `simctl erase` and
  the TodayFlex → WorkoutFlow order are green.
- Exercise preferences: `exercise_prefs` (migration `20260929000003`, after workstream B's `…0002`) plus
  `never_exercise_ids(ids)` so proposals are checked even when `mcp_read_plan` is off (and nothing is revealed to an
  MCP token after Disconnect Claude). Preferences are in the JSON backup.
- Inline set editing: today's rest is today-only (routines have no rest field), stored with the in-progress workout
  so a relaunch keeps it. Save Changes writes working set count, reps (the range is kept when today's reps are
  inside it) and the working weight (stamped so it wins over progression); warm-ups stay generated.
- Codex review: 20 rounds; every P2 fixed test-first where testable; the last rounds are clean.
