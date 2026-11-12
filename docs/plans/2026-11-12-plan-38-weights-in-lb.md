# Plan 38: keep the pound number of every weight

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A weight the owner thinks of in pounds shows as that pound number, such as 45 lb, never as 44.8 lb.

**What we found (2026-11-12).** Everything stores weights in kg only: GymCore, SwiftData, sync, D1 and MCP. Typing works: 45 lb is saved as 20.41165665 kg and shows as "45". The odd values come from weights that arrived in kg:
- **Agents' plan weights.** `change_plan` takes kg, and agents round their conversion. For example, 45 lb becomes 20.3 kg, which shows as 44.8 lb. On the phone, 12 of 37 plan weights are off the half-pound grid, and all 12 are tenths of a kg.
- **History imported from the old app.** 456 of 2131 imported sets are off the grid, and 402 of those are whole or half kg, such as 20 kg = 44.1 lb. Those are what was really lifted.
- **Sets logged in this app.** 27 of 56 are off the grid. They come from carried-forward kg values and agents' plan weights.

`ProgressionEngine` carries `last.weightKg` raw in keepGoing, off, time and fixed, so one bad value repeats from one session to the next.

**Owner's choices (2026-11-12):**
- Every weight keeps its pound number as well as kg. Kg stays the number used for maths.
- Agents send weights in the owner's unit.
- The 12 plan weights are cleaned up.
- Old kg history keeps showing converted, to one decimal: 20 kg shows as 44.1 lb. History is not rewritten.

**Design:**
- A new optional `weightLb` sits next to every `weightKg` that is a set or plan weight: `WorkoutSet`, `RoutineExercise` and `PlanChange`, plus their records, DTOs and server columns.
- **The rule:** `weightLb` is the pound number the weight was entered or chosen as. It's nil when nobody gave a pound number: kg entries, imports and old rows.
- **Invariant:** whenever `weightKg` changes, `weightLb` is set to the new pound number or cleared, so the two never disagree. On decode and on sync, a `weightLb` whose kg differs from `weightKg` by more than 0.01 kg is dropped.
- **Display in lb:** `weightLb ?? fromKg(weightKg)`, formatted as today: at most one decimal, no ".0". Display in kg shows `weightKg` as today.
- **Maths:** volume, e1RM, progression comparisons, plates and listing fits use `weightKg`, unchanged.
- **Who sets `weightLb`:**
  - typing in lb (`SetFieldFormat`);
  - the plan stepper in lb;
  - `LoadRounder` in lb (its result is a pound number);
  - the watch crown in lb;
  - agents (`change_plan` and `log_workout` with `weightLb` / `weight_lb`);
  - a gym listing created in pounds, where the fit's kg converts to a whole or quarter pound within 0.001.
- **Carrying a weight forward** (keepGoing, off, time, fixed; Today's edits; a swap keeping the weight; warm-ups from a set) copies `weightLb` with `weightKg`.
- **In lb mode, a carried weight with no `weightLb` snaps to the nearest ½ lb** and gets that `weightLb`. This stops an old off-grid value repeating in new plans. Logged history isn't touched.
- **Wire names:**
  - sync sets: `w_lb` (D1 `workout_sets.w_lb REAL NULL`);
  - routine exercise JSON: `weight_lb`;
  - proposal change JSON: `weightLb`;
  - MCP `change_plan`: `weightLb`;
  - MCP `log_workout`: `weight_lb`;
  - MCP reads: `weight_lb` next to `weight_kg` and `weight_display`.
- **Order:** the server ships first (Cloudflare, with the owner's approval). It accepts and stores `w_lb` and `weight_lb`, and keeps accepting rows without them. Then the phone build.

**Branch:** `feat-weights-lb`, from `feat-workout-polish` (plans 34-37).

**Rules for implementers:**
- No `Co-Authored-By` or other attribution lines in commits.
- Don't run `scripts/test-db.sh`. Don't touch the phone, don't deploy or run remote D1 commands (`wrangler ... --remote`), and don't print or edit `.dev.vars` or `ios/Config/Local.xcconfig`. Don't use `rm -rf`.
- App tests: `scripts/ios-test.sh -only-testing:<target>/<class>` (`DEST=...` picks the simulator). GymCore: `cd ios/Packages/GymCore && swift test --filter <name>`. GymData: `cd ios/Packages/GymData && swift test`. Server: `cd server && npm test` and `npx tsc --noEmit`.
- Match the surrounding code: doc comments, small files, value types, no `print`.
- TDD: write the failing test first.

---

## Task 1: GymCore and GymData carry `weightLb`

**Files:**
- GymCore: `Model/Workout.swift`, `Model/Routine.swift` and `Plan/PlanChange.swift`; the plan change appliers (`Plan/PlanChangeApplier+Edits.swift`); `Progression/ProgressionEngine.swift`; `Units/WeightFormatter.swift` and `Units/WeightUnit.swift`; `Units/LoadRounder.swift`.
- A new `Units/PoundWeight.swift` for the helpers.
- GymData: `Records/WorkoutRecords.swift` (`SetRecord`), `Records/RoutineRecords.swift` (`RoutineExerciseRecord`) and the mappings.
- GymSync DTOs: `WorkoutDTO` `w_lb`, `RoutineDTO` `weight_lb`.
- Tests next to each.

**Steps:**
- [ ] Add `weightLb: Double?` to `WorkoutSet`, `RoutineExercise` and `PlanChange`. Default it to nil in the inits, decode it with `decodeIfPresent`, and drop it on decode when it disagrees with kg by more than 0.01 kg.
- [ ] Add pure helpers with tests. One option:
  - `WeightUnit.displayValue(kg:lb:unit:)`;
  - `WeightFormatter.number(kg:lb:unit:)` and `format(kg:lb:unit:)`;
  - `entered(_ value:unit:) -> (kg: Double, lb: Double?)`;
  - `snappedToHalfPound(kg:) -> (kg, lb)`.
- [ ] Every place in GymCore that makes a new weight from another keeps the invariant: copy `weightLb` when the kg is copied; set it when a pound number is chosen; clear it otherwise. This covers:
  - `WorkoutSet` copy helpers (`with(...)`);
  - `SetCarry` and `SetFieldFormat.copying`;
  - the appliers: `.weight` and add/swap with a weight;
  - `ProgressionEngine`: rounder results get `weightLb` in lb mode; carried weights copy it or snap to ½ lb in lb mode;
  - the warm-up generator.

  Add tests for each.
- [ ] GymData: optional `weightLb` on `SetRecord` and `RoutineExerciseRecord`, as a lightweight migration (optional, no default). Add a migration test that opens a store written by the previous model and reads nil, if the package has such tests; otherwise a round-trip mapping test.
- [ ] GymSync DTOs: `w_lb` and `weight_lb`, both optional, with encode/decode tests.
- [ ] **Commit** `feat(core): sets and plan weights keep their pound number`.

## Task 2: The app sets and shows the pound number

**Files:** app call sites that show or set a set or plan weight:
- `SetFieldFormat` (display and typing);
- `LoggingView` (the hint line);
- `PlannedTarget` and `TodayModel`;
- `RoutineExercisesSection` (the stepper label and step);
- `ExerciseHistoryView`, `WorkoutDetailView` and `WorkoutText`;
- `SummaryView`, `WorkoutOverviewView` and `WorkoutAccessibilityText`;
- `WorkoutActivityContent` (Live Activity);
- `ProposalModel` (and `+Text`);
- `StrengthText` and `StrengthReport`, where they show a set's weight;
- `ConflictSheet`;
- the watch mapper (`WatchStateMapper`) and the crown, so the watch shows and sets the pound number;
- `SessionPlanner` and the listing fits.

Body weight, the bar and plates, listings, calories and the plate sheet are not set weights, so they stay as they are.

**Steps:**
- [ ] UI tests that fail first:
  - A seeded plan weight of 20.3 kg with `weightLb` 45 shows "45" on Today and the exercise screen.
  - Typing 47.5 in lb shows "47.5" after a relaunch.
- [ ] Switch every listed call site to the `kg:lb:` formatter, and make every place that writes a weight in lb pass the pound number.
- [ ] **One-time cleanup of plan weights:**
  - On launch, if the profile unit is lb and the flag `planWeightsLbV1` isn't set in UserDefaults, then every `RoutineExerciseRecord` with a weight and no `weightLb` snaps to its exercise's lb grid (`LoadRounding` for that exercise, the same rounder the plan stepper uses) and gets that `weightLb`.
  - Mark the routine dirty so it syncs, then set the flag.
  - Logged history is not touched.
  - Test with a store seeded with 20.3 kg on a barbell exercise: it becomes 45 lb (20.41 kg), and a second launch changes nothing.
- [ ] Run GymCore, GymData and the app unit tests, plus the UI classes touched: `SetEditingUITests`, `TodayPlanScreenUITests`, `WorkoutFlowUITests`, `FlowCoverageUITests` and the proposal UI tests.
- [ ] **Commit** `feat(app): weights show and keep their pound number`.

## Task 3: Server and agents

**Files:**
- `server/migrations/0012_weight_lb.sql` (new): `ALTER TABLE workout_sets ADD COLUMN w_lb REAL CHECK (w_lb IS NULL OR (w_lb >= 0 AND w_lb <= 2205))`.
- `server/src/sync/workouts.ts`: `SET` gets `{ name: 'w_lb', kind: 'real', nullable: true }`.
- Routine `exercises` and proposal `changes` are JSON, so check that their validators accept and keep `weight_lb` / `weightLb`.
- `server/src/shared/plan-validation.ts`: a `weightLb` range of 0–1100, refused when it disagrees with `weightKg` by more than 0.01 kg. When only `weightLb` is given, fill `weightKg = weightLb × 0.45359237` exactly.
- MCP:
  - `tools/schemas.ts`: `weightLb` on change_plan changes, `weight_lb` on log_workout sets, and describe them;
  - `tools/register.ts` and `instructions.ts`: "give weights in the owner's unit: weightLb when get_profile says lb; the server converts";
  - `tools/write.ts`, `tools/log-workout.ts` and `d1-db.ts`: store both;
  - `tools/format.ts` `weight()`: returns `weight_lb`, preferring the stored pound number for `weight_display`;
  - `tools/read.ts`: passes it through.
- Server tests:
  - sync round trip with and without `w_lb`;
  - change_plan with only `weightLb` stores the exact kg and the pound number;
  - log_workout with `weight_lb`;
  - get_plan shows "45 lb" for a pound weight stored as 20.41 kg.

**Steps:**
- [ ] Failing tests, implement, then `npm test` and `npx tsc --noEmit`.
- [ ] Apply the migration locally only (the local D1 the tests use). Deploying is the owner's call.
- [ ] **Commit** `feat(server): sets and plan changes keep their pound number; agents send pounds`.

## Task 4: Review, suites, deploy, install

- [ ] A reviewer agent reviews the whole diff, `git diff feat-workout-polish...HEAD`. Check the invariant hardest: no place may change `weightKg` and leave a stale `weightLb`. Fix CRITICAL and HIGH findings.
- [ ] Full iOS suite, plus GymCore, GymData and server tests. Record the counts.
- [ ] Privacy scan of the diff: no surname, no account ID, no secrets.
- [ ] Ask the owner, then apply migration 0012 to the remote D1 and deploy the Worker. Check `/mcp` gives 401 without a token.
- [ ] Ask the owner, then install on the phone after a Library backup. Compare row counts, and count plan weights that have `weightLb` afterwards.
- [ ] Append `## Outcome` and commit `docs: plan 38 outcome`.
