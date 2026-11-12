# Plan 36: workout screen fixes from a real workout

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix four things the owner hit during a workout on 2026-11-11 (Push + Arms, screenshots in the chat):

1. Changing a set's reps doesn't change the sets after it. Weight already carries; reps don't.
2. "Next exercise" goes back to the workout list instead of opening the next exercise.
3. The rest time is one number for the whole workout, so a change on one exercise leaks into every exercise after it.
4. Swipe-to-delete on a set looks broken. The whole row slides, including the set number and the "Reps" label, and the red button is a tall block.

**Owner's choices (2026-11-11):**
- Rest: a change on one exercise sticks to that exercise in every workout, saved on this phone only. Other exercises keep their own rest or the default.
- Exercises with no rest of their own get a suggestion by type. Big barbell lifts rest at least 3:00 and single-muscle moves at most 1:30; everything else uses the Settings default.
- Delete: a tidy swipe. Only the boxes move, and the button is one box tall.

**Architecture:** App only. No server, sync or agent changes. GymCore gets the pure rules:
- carrying a value to later sets;
- which exercise is next;
- the rest suggestion.

The app gets an observable per-exercise rest store in UserDefaults. The workout session and Today's plan editor read and write it through injected closures, so `ExerciseScreenModel` stays free of the environment.

**Branch:** `feat-workout-fixes`, from `feat-week-plan` 087d1d8, which is what the phone runs (plans 34 and 35).

**Rules for implementers:**
- No `Co-Authored-By` or other attribution lines in commits.
- Don't run `scripts/test-db.sh`. Don't touch the phone, Cloudflare, `server/`, `.dev.vars` or `ios/Config/Local.xcconfig`.
- App tests: `scripts/ios-test.sh -only-testing:<target>/<class>`.
- GymCore tests: `cd ios/Packages/GymCore && swift test --filter <name>`.
- Match the surrounding code: doc comments on types and non-obvious functions, small files, value types, no `print`.

---

## Task 1: Reps carry to the later sets, like weight

**Files:**
- `ios/Packages/GymCore/Sources/GymCore/Session/SetWeightCarry.swift` and its tests
- `ios/GymRollins/Features/Workout/ExerciseScreenModel.swift` (`updateSetCarryingWeight`)
- `ios/GymRollinsTests/SetWeightCarrySessionTests.swift`
- `ios/GymRollinsUITests/SetEditingUITests.swift`

**Rule:** the same as weight today, applied to each value separately: weight, reps and seconds.
- When a set's value changes, the later sets that aren't logged follow, as long as they still hold the old value.
- The first later set with a different value stops the carry for that value.
- Logged sets and warm-ups are skipped, and editing a warm-up carries nothing.

Example: sets 10/10/10, set 2 changed to 12, gives 10/12/12. Sets 10/10/8 with set 1 changed to 12 gives 12/12/8.

- [ ] **Step 1: Failing GymCore tests.**
  - Generalize `SetWeightCarry` into `SetCarry`, with one `following` per value. Doubles compare with the same 0.001 tolerance; reps and seconds compare exactly.
  - Keep the existing weight tests green under the new name.
  - Add tests for reps: the example above, the stop on a different value, logged and warm-up sets skipped, and an edited warm-up carrying nothing. Add one for seconds.
- [ ] **Step 2: Run them and watch them fail.**
- [ ] **Step 3: Implement.**
  - `ExerciseScreenModel.updateSetCarryingWeight` becomes `updateSetCarrying`, which carries each value that changed.
  - Plan mode applies typing on every keystroke. Typing "1" then "12" over 10 must end with the later sets at 12, which works because each keystroke carries from the value just before it.
  - Update both call sites in `LoggingView`.
- [ ] **Step 4: App unit test** in `SetWeightCarrySessionTests`: a workout entry with 3×10, set 2 changed to 12 → 10/12/12.
- [ ] **Step 5: UI test** in `SetEditingUITests`: type 12 into set 2's reps, tap Done, and set 3's reps box shows 12.
- [ ] **Step 6: Run the GymCore tests and those two test classes. Commit** `feat(app): changing a set's reps carries to the sets after it, like weight`.

## Task 2: Next exercise opens the next exercise

**Files:**
- GymCore `Workout`: next entry to do.
- `ios/GymRollins/Features/Workout/WorkoutLogBar.swift`, `LoggingView.swift`, `WorkoutFlowView.swift`
- The UI tests that tap `logging.next`

**Rule:** after an exercise's last set, the primary button shows:
- **"Next exercise"** (`logging.next`) when another exercise still has sets to do. The next one is the first exercise after this one with sets left; if there's none after, the first one before it with sets left.
  - Tapping it replaces this screen with that exercise's screen in the navigation path, so Back still leads to the workout list.
  - The list's "in progress" highlight follows, since `LoggingView` already calls `session.select` on appear.
- **"Finish"** (`workout.finish`) when no exercise has sets left.

This changes one case: on the last exercise, with an earlier exercise skipped, the button used to say Finish. It now offers that skipped exercise.

- [ ] **Step 1: Failing GymCore test** for `Workout.nextEntryToDo(after:) -> UUID?`. Cover:
  - the next exercise after;
  - skipping an exercise that's already done;
  - wrapping round to an earlier exercise;
  - nil when all are done;
  - nil for an unknown id.
- [ ] **Step 2: Implement it**, and see the test pass.
- [ ] **Step 3: App.**
  - `WorkoutLogBar` gets `open: (UUID) -> Void` in place of `next`, and uses `nextEntryToDo`.
  - `LoggingView` gets `var openEntry: (UUID) -> Void = { _ in }`.
  - `WorkoutFlowView` passes `{ id in if !path.isEmpty { path.removeLast() }; path.append(id) }`.
- [ ] **Step 4: UI tests.**
  - Fix the tests that tapped `logging.next` and then expected the list: AccessibilityAuditUITests:262, AppleHealthUITests:58, IdleFinishUITests:16 and :54, InsightsUITests:131, LiveActivityUITests:34, SyncUITests:43.
  - Each must still test what it was testing. Where it went through the list to reach the next exercise, it's now already there.
  - Add one test: log all of exercise 1, tap Next exercise, see exercise 2's title (`logging.title`), tap Back, see the list.
- [ ] **Step 5: Run the changed UI test classes. Commit** `feat(app): Next exercise opens the next exercise instead of the workout list`.

## Task 1b: Carry while typing, and the keyboard bar (owner, 2026-11-11, added mid-plan)

The owner added two asks after the plan was written. They sent a screenshot of the iOS 26 form keyboard bar from Safari.

- **Carry while typing.** In a workout, set 3 changes while the owner types in set 2, not only after Done.
  - `draftBinding` applies every parseable keystroke in both modes; before, only plan mode did.
  - The typed text still stays in `drafts` until the box is left.
- **Keyboard bar.**
  - On the left, a capsule with up and down chevrons: `keyboard.previous` / `keyboard.next` ("Previous field" / "Next field"). They walk every box in screen order.
  - On the right, a plain text "Done" (`keyboard.done`), not the round red check.
- [x] Done in ed90073, with the UI tests `testNewRepsCarryToTheLaterSets` (asserts before Done) and `testKeyboardNextMovesToTheNextBox`.

## Task 3: Rest per exercise, with a suggestion by type

**Files:**
- GymCore: new `Session/ExerciseRest.swift` and its tests.
- App: new `Features/Workout/ExerciseRestStore.swift`, plus `WorkoutSession.swift`, `AppEnvironment.swift` (`makeSession`, the wipe), `ExerciseScreenModel.swift`, `Sheets/RestSettingsSheet.swift`, `Features/Today/TodayPlanEditor.swift`, `TodayView.swift` (`editor.configure`) and `Features/Settings/SettingsView.swift` (`RestDefaultsView`).
- Tests.

**Rule (GymCore, pure):**

```swift
/// Rest between working sets for one exercise: the owner's own choice for it, else a suggestion by its type.
public enum ExerciseRest {
    public enum Kind: Equatable, Sendable { case bigLift, isolation, other }
    public static let bigLiftSec = 180
    public static let isolationSec = 90
    public static func kind(of exercise: Exercise) -> Kind
    /// bigLift → max(default, 180); isolation → min(default, 90); other → default.
    public static func suggested(for exercise: Exercise?, defaultSec: Int) -> Int
    public static func working(custom: Int?, exercise: Exercise?, defaultSec: Int) -> Int  // custom ?? suggested
}
```

`kind(of:)` works like this:
- An exercise that isn't `.reps` is `other`.
- **isolation:** the lowercased name contains one of fly, flye, curl, extension, raise, kickback, cross-over, crossover, pushdown, push-down, pec deck, shrug, calf or wrist, or the exercise has no secondary muscles.
  - The library's secondary muscles are too noisy to judge isolation by. Incline fly lists shoulders, rope triceps extension lists shoulders, and preacher curl lists forearms.
- **bigLift:** not isolation, `isBarbellLoaded`, and at least 2 secondary muscles. That covers barbell bench, squat, deadlift and bent-over row.
- Anything else is `other`.

Real library rows (from `Resources/exercises.json`) to use as test fixtures:

| Exercise | Equipment | Secondary muscles | Kind |
| --- | --- | --- | --- |
| barbell bench press | barbell | triceps, shoulders | bigLift |
| barbell full squat | barbell | quadriceps, hamstrings, calves, core | bigLift |
| barbell bent over row | barbell | biceps, forearms | bigLift |
| barbell preacher curl | barbell | forearms | isolation |
| dumbbell incline bench press | dumbbell | shoulders, triceps | other |
| dumbbell incline fly | dumbbell | shoulders | isolation |
| cable cross-over variation | cable | deltoids, triceps | isolation |
| cable overhead triceps extension (rope attachment) | cable | shoulders | isolation |
| dumbbell hammer curl | dumbbell | forearms | isolation |

**What the app uses:**
- **Workout default:** what the session has now. That's today's rest if the day has one, otherwise Settings' `profile.restSec`. `WorkoutSession.restSeconds` keeps this meaning, and `IdleFinish` keeps using it.
- **Working rest after a set:** `ExerciseRest.working(custom: store[exerciseId], exercise: library.exercise(exerciseId), defaultSec: workout default)`.
- **Warm-up rest:** unchanged. It's the session's `warmupRestSeconds`, edited in the sheet's warm-up section for this workout.
- **Plan mode (Today's exercise screen):** its rest chip shows and edits the same per-exercise rest, with Today's rest (`editor.restSec`) as the default.
  - No UI sets the day's `TodayPlan.restSec` any more.
  - A stored one is still read as that day's default.

- [ ] **Step 1: Failing GymCore tests** for `kind`, using the table above built as `Exercise` fixtures. Also test `suggested` with defaults 120 and 240 (bigLift gives 180 and 240; isolation gives 90 and 90), `working` with a custom value (custom wins), and a nil exercise (the default).
- [ ] **Step 2: Implement it**, and see the tests pass.
- [ ] **Step 3: The store.**
  - `ExerciseRestStore`: `@MainActor @Observable final class`, holding `private(set) var seconds: [String: Int]`.
  - It's loaded from and saved to UserDefaults key `exerciseRestSeconds`, with `func custom(_ id: String) -> Int?` and `func set(_ seconds: Int?, for id: String)`.
  - `AppEnvironment` owns one. The local-data wipe clears it: find where `removeGymLocalState` is called and clear the store beside it.
  - **Saving:** a value equal to the exercise's suggestion is stored as nil, so the exercise follows the suggestion and later default changes. `TodayPlanEditor.setRest` does the same with the default.
  - Unit test the store: it round-trips through a fresh suite's `UserDefaults`, nil removes, and a wipe clears.
- [ ] **Step 4: Session.**
  - `WorkoutSession.init` gets `workingRest: @escaping (String, TimeInterval) -> TimeInterval = { $1 }` (exercise id and workout default → seconds), and `saveWorkingRest: @escaping (String, TimeInterval, TimeInterval) -> Void = { _, _, _ in }` (exercise id, seconds, workout default).
  - Add `func workingRestSeconds(entryId:) -> TimeInterval` and `func setWorkingRest(_:entryId:)`.
  - `startRest` takes the entry and uses its working rest. Both `logNextSet` and `logAllSets` pass it.
  - `makeSession` wires both closures to the store and the library.
  - Unit tests:
    - with a custom 300 for exercise A and none for B, logging a set of A starts a 300-second rest, and logging B starts the workout default;
    - changing A's rest leaves B's alone.
- [ ] **Step 5: Plan editor.**
  - `TodayPlanEditor.configure` gets the same two closures, and adds `workingRest(itemId:)` and `setWorkingRest(_:itemId:)`.
  - `ExerciseScreenModel.restSeconds` and `setRestSeconds` call the session or editor versions for this entry or item.
- [ ] **Step 6: Sheet.**
  - In both modes the working section offers 0:30 to 15:00 in 15-second steps (`DomainLimits.restSec` upper bound).
  - Footnote for the working section: "<Exercise name> rests this long in every workout. Other exercises keep their own rest or the default in Settings."
  - When the exercise has its own value, show a "Use suggested (1:30)" button that clears it.
  - Warm-up section footnote: "Warm-up rest for this workout."
- [ ] **Step 7: Settings › Default rest (`RestDefaultsView`).**
  - Add a footer under the steppers: "Big barbell lifts rest at least 3:00 and single-muscle exercises at most 1:30, unless you set an exercise's own rest."
  - Add a section "Your exercise rests", listing each stored exercise's display name and time, sorted by name.
  - Swipe to delete clears it (`settings.rest.exercise.<id>`). The section is hidden when empty.
- [ ] **Step 8: UI tests.**
  - `FlowCoverageUITests:18-26` sets rest to 3:00 in a workout. Extend it: the next exercise's chip doesn't show 3:00 (it shows its suggestion or the default), and going back to the first exercise still shows 3:00.
  - `TodayPlanScreenUITests:39-67` sets 2:30 on Today. Keep it, now per exercise: another exercise's chip doesn't show 2:30.
- [ ] **Step 9: Run GymCore, the new unit tests, and those UI test classes. Commit** `feat(app): rest is per exercise, remembered, with a suggestion by type`.

## Task 4: A tidy swipe to delete a set

**Files:** `ios/GymRollins/DesignSystem/SwipeToDelete.swift`, `ios/GymRollins/Features/Workout/SetTimelineRow.swift` and `LoggingView.swift`. `SwipeToDelete` is used only on the set rows.

**Look:**
- The swipe moves only the set's boxes. The hexagon number, the timeline line and the labels' left edge stay put.
- The boxes make room by narrowing, not by sliding under the number.
- The revealed button:
  - a white trash icon on `Theme.primaryFill`, the Log Set red. The plan first said `Theme.destructive`, but white on it is only about 2.3:1 and looked washed out;
  - the boxes' 12-point corner radius, about 64 points wide;
  - exactly as tall as an input box and level with the boxes, never spanning the active row's "Reps / Weight" labels or its "Per Arm" / "Bar + Plates" caption.
- The rest of the behavior stays:
  - only horizontal drags count;
  - a long swipe deletes at once;
  - a short swipe snaps open or shut;
  - logged sets and the last set can't be swiped.
- Keep the `logging.set.<n>.delete` identifier and the "Delete set" label. The badge's long-press "Remove Set" and the VoiceOver action stay.
- Accessibility text sizes, where the boxes stack, must still work. There the button can be as tall as the first box.

**Suggested approach:**
- Apply the swipe inside `SetTimelineRow`, to the boxes' layout only.
- Measure the first input box with an anchor preference, and place the button from that anchor in an overlay. That way the labels and caption never change its height or position.

- [ ] **Step 1: Build it.**
- [ ] **Step 2:** `SetEditingUITests`' delete test (`logging.set.4.delete`) still passes.
- [ ] **Step 3: Simulator screenshots.**
  - Take two, each with the swipe open: on the active row (with labels) and on a non-active row.
  - Save them to the scratchpad and check them by eye: the button is level with the boxes and the number doesn't move.
- [ ] **Step 4: Commit** `fix(app): swiping a set slides only its boxes and shows a box-sized delete button`.

## Task 5: Review, full suite, outcome

- [ ] A reviewer agent reviews `git diff feat-week-plan...HEAD`. Fix CRITICAL and HIGH findings.
- [ ] Full suite: `scripts/ios-test.sh`, plus GymCore `swift test`. Record the counts.
- [ ] Append `## Outcome` (commits, tests, screenshots, what's unverified) and commit `docs: plan 36 outcome`.
- [ ] A phone install only with the owner's go-ahead: back up first (see the owner-phone-install memory). Not merged, not pushed.

**Not verified by tests:** how the swipe feels on a real phone, and whether the rest suggestions suit the owner. The owner checks both at the next workout.
