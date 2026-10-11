# Plan 18: Today opens the workout's exercise screen ("plan mode")

Owner request: "why we open workout like collapsible instead just same window like inside workout — let's use same
screen and delete additional code". Today's accordion set editor (plan 11 task 4) is replaced by the in-workout
exercise screen (`LoggingView`), driven by today's plan instead of a running workout.

## Design

- `ExerciseScreenModel` (enum adapter): `.workout(WorkoutSession, entryId:)` or `.plan(TodayPlanEditor, itemId:)`.
  It exposes what the screen's shared parts need: exercise id, sets, rest, update a set, add / remove a set, toggle
  warm-up. `LoggingView` renders the same hero, chips, hint, set timeline and bottom-bar slot for both; only a few
  spots switch on the mode.
- `TodayPlanEditor` (`@Observable`): the single copy of today's plan that Today and the plan screen both read and
  edit. Wraps the existing pure `TodayPlan` / `TodaySetEdits` edits and saves through `TodayPlanStore` on every change.
  Suggested sets are cached per item (stable set ids while typing) and dropped on reload / reset / replace.
- Plan-mode differences: no workout clock (an "Edited" capsule instead when edited); `···` is a menu with Today's row
  items (Video & Instructions, Exercise History, Replace, preferences, Reset to Suggested, Delete from Workout); the
  rest chip edits today's rest (working sets only); Swap replaces the exercise in today's plan (keeps the item id, so
  the screen stays); bottom bar is one "Start Workout" button that starts today's (edited) workout and opens the
  logging screen on this exercise. No paging (the workout screen has none).
- Set rows: same `SetTimelineRow`. A long-press menu on the set badge (and VoiceOver actions) removes a set in both
  modes (undone sets only in a workout) and, in plan mode, switches warm-up / working.
- Today rows become simple rows (thumbnail, name, summary, "Edited" badge, `···`); tapping pushes the plan screen.
  Not reachable while a workout runs (rows are inert then, as before).
- Semantics of plan 11 task 4 are unchanged: edits are today-only, persist across relaunch, start the workout; "Save
  Changes to <routine>" writes set count / reps / weight (rest stays today-only); stale-plan and swap rules unchanged.

## Tasks

- [x] Unit tests first: `TodayPlanEditor` (edit set 2 weight / reps, add, remove, warm-up, rest, reset, replace keeps
  the item id and drops edits, delete, suggestions stable, persisted), `TodayPlan.startEntryId` (start-from-exercise
  selects that exercise's entry).
- [x] `TodayPlanEditor` + `ExerciseScreenModel`; `LoggingView` driven by the model; `RestSettingsSheet` and
  `SwapSheet` take bindings / callbacks instead of the session.
- [x] `WorkoutFlowView(initialEntry:)` opens straight onto one exercise.
- [x] Today: simple rows, push the plan screen, Start from it; delete the accordion editor (`TodayExerciseRow`'s
  editor, `TodaySetText`, focus / keyboard / bottom-bar hiding) and `TodayInlineEditUITests`.
- [x] UI tests: `TodayPlanScreenUITests` (edit set 2, add set, rest, Edited on Today, relaunch, Start lands on the
  exercise with the edits, Replace, Reset, Save Changes); plan screen in `AccessibilityAuditUITests`.
- [x] Screenshots in `docs/screenshots/plan-screen/`; full `scripts/ios-test.sh`, swiftlint, `scripts/watch-build.sh`.
- [x] `codex review --base main`.

## Outcome

- `LoggingView` renders both modes from `ExerciseScreenModel`; the workout bottom bar moved to `WorkoutLogBar`,
  `RestSettingsSheet` / `SwapSheet` take bindings / a pick callback instead of the session.
- Deleted: the accordion editor in `TodayExerciseRow` (now a 60-line simple row + shared `TodayExerciseMenuItems`),
  `TodaySetText`, `TodaySetEdits.setting / applying / stepped` (only the stepper UI used them) and their tests,
  Today's `expandedRow` / `editingSets` / `planGeneration`, and `TodayInlineEditUITests`.
- Codex round 1 (3 × P2, fixed test-first): suggested set ids survive a reload (typing in progress still applies);
  a workout started from the watch closes the plan screen and locks the editor; today's rest offers 0–900 s.
  Round 2–4: ids reused only for identical rows on the same day; Remove Set rechecks the live set; plan typing goes
  into today's plan per keystroke and drafts drop on a unit change; Swap excludes the plan's other exercises.
  Round 5: clean.
- Full `scripts/ios-test.sh` (iPhone 17 Pro Max, iOS 26.2): 546 tests, 537 passed, 7 skipped, 2 failed (below).
- `AppleHealthUITests.testEnablingInSettings…` / `testFinishedWorkout…` fail on this iPhone 17 Pro Max simulator on
  `main` too (Settings Health row), unrelated to this change.
