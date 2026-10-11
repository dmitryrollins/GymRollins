# Plan 09: Lock-screen Live Activity for the in-progress workout

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** While a workout is in progress, show a Live Activity on the lock screen and in the Dynamic Island: the rest
countdown (ticks on its own via `Text(timerInterval:)`), the exercise name and the next planned set
("Set 3/5 · 60 kg × 8", in the user's unit), with three buttons: **Log set** (logs the next set with its planned
weight/reps, no editing), **+30s** (extends the rest) and **Skip rest**.

**Architecture:** Everything the activity shows is computed by a pure app-level type, `WorkoutActivityContent`
(workout + current entry + rest + unit + library → `WorkoutActivityAttributes.ContentState?`). The buttons are
`LiveActivityIntent`s, which the system runs **in the app process** (the app is launched in the background if needed),
so they act on the same `WorkoutSession` the logging screen uses: the intents only build a `WorkoutActivityAction` and
hand it to `WorkoutActivityIntentRouter`, which the app wires to `AppEnvironment.performActivityAction` →
`WorkoutSession.perform(_:exercise:)` → the existing `logNextSet` / `adjustRest` / `skipRest`. No App Group and no
SwiftData access from the extension. `LiveActivityController` observes the environment (Observation tracking) and
starts/updates/ends the activity through a small `WorkoutActivityClient` protocol (real: ActivityKit; tests: a fake;
`-uiTesting`: an in-memory recorder that a DEBUG probe exposes to XCUITest).

**Shared code:** `ios/Shared/LiveActivity/` is compiled into both the app and the widget extension: the
`ActivityAttributes`, the intents and the action/router types. ActivityKit matches the attributes type across the two
binaries, and the widget needs the intent types to build `Button(intent:)`.

**Scope decisions:**
- Reps-based exercises only get **Log set**. Timed and cardio exercises keep the activity (exercise, set, "45 s" /
  "20 min") without the Log set button. Keeping one activity for the whole workout is simpler than ending and
  restarting it per exercise type.
- "Next planned set" = the first undone set of the target entry, with the values it currently holds (the same values
  the logging screen's Log Set would use). The target entry is the session's current entry when it still has an
  undone set, otherwise the first entry with undone sets.
- A Log set tap carries the workout, entry and set ids it was rendered for and is ignored when that set is no longer
  the next one (stale activity, double tap, or the set was logged in the app meanwhile).
- +30s only extends a rest that is still running; Skip only clears an existing rest.
- When the rest runs out the countdown stops at 0:00 and `staleDate` (= rest end) flips the view to "Rest over"
  without an update from the app.
- The activity starts when a workout starts (or is restored on launch; an activity left over for the same workout is
  adopted, others are ended), updates on every change the lock screen shows, and ends when the workout is finished
  (summary on screen), discarded or abandoned (sign-out / wipe).

**Tech Stack:** ActivityKit, WidgetKit, AppIntents (`LiveActivityIntent`), SwiftUI iOS 26, Swift Testing, XCUITest.

**Depends on:** v0.1.0 (`main`).

**Conventions:** Branch `feat-live-activity` from `main`. Commit per task with the trailer lines. Never `git add -A`.

---

### Task 1: Pure content builder (TDD)

- [x] `ios/Shared/LiveActivity/WorkoutActivityAttributes.swift`: `WorkoutActivityAttributes` (`workoutId`,
  `workoutName`) with `ContentState` (`exerciseName`, `setLabel`, `setDetail`, `restStartedAt`, `restEndsAt`,
  `canLogSet`, `entryId`, `setId`, `isComplete`).
- [x] `GymRollinsTests/WorkoutActivityContentTests.swift` first: target entry (current / first undone / all done /
  empty workout), set label ("Warm-up 1/2", "Set 3/5"), detail in lb and kg ("135 lb × 8", "61.2 kg × 8", bodyweight
  "8 reps", timed "45 s", cardio "20 min · 3.1 mi"), reps-only `canLogSet` (reps yes; time/cardio and imported
  timed sets on a reps exercise no), rest included only while running, nil for a finished workout.
- [x] `ios/GymRollins/Features/LiveActivity/WorkoutActivityContent.swift` to make them pass.
- [x] **Commit:** `feat(live-activity): pure content state builder`

### Task 2: Actions on the shared session (TDD)

- [x] `ios/Shared/LiveActivity/WorkoutActivityAction.swift`: `WorkoutActivityAction` (`logPlannedSet`,
  `extendRest`, `skipRest`, each with the workout id) and `WorkoutActivityIntentRouter` (main-actor handler hook).
- [x] `GymRollinsTests/WorkoutActivityActionTests.swift` first, against a real `WorkoutSession` with spy persistence:
  log planned set completes exactly that set with its stored values and starts rest; stale set id / other workout /
  finished workout / timed exercise are no-ops; +30s extends a running rest and reschedules the notification, no-op
  when resting is over; skip clears the rest.
- [x] `ios/GymRollins/Features/LiveActivity/WorkoutSession+ActivityAction.swift` and
  `AppEnvironment.performActivityAction(_:)`.
- [x] **Commit:** `feat(live-activity): lock-screen actions act on the workout session`

### Task 3: Controller (TDD with a fake ActivityKit wrapper)

- [x] `GymRollinsTests/LiveActivityControllerTests.swift` first with `FakeActivityClient`: starts once for a new
  session, updates only on a changed state, ends on nil, adopts an existing activity for the same workout and ends
  others, a failing request (activities disabled) is logged and retried on the next change, observation of a real
  `WorkoutSession` triggers an update after a logged set.
- [x] `ios/GymRollins/Features/LiveActivity/LiveActivityController.swift`, `ActivityKitClient.swift` (real).
- [x] **Commit:** `feat(live-activity): controller that starts, updates and ends the activity`

### Task 4: Widget extension, intents, wiring

- [x] `project.yml`: `GymRollinsWidgets` app-extension target (WidgetKit extension point, `Shared/` sources, Theme and
  the Barlow fonts), embedded in the app; app gets `Shared/` and `NSSupportsLiveActivities`. Gitignore the generated
  extension `Info.plist`.
- [x] `ios/Shared/LiveActivity/WorkoutActivityIntents.swift`: `LogPlannedSetIntent`, `ExtendRestIntent`,
  `SkipRestIntent` (`LiveActivityIntent`) that route to the app and await the activity refresh.
- [x] `ios/GymRollinsWidgets/`: bundle, `ActivityConfiguration` with the lock-screen view and compact / expanded /
  minimal Dynamic Island in the DesignSystem's dark athletic style.
- [x] `GymRollinsApp`/`Boot`: build the controller (ActivityKit client; recorder under `-uiTesting`), start observing,
  install the router handler.
- [x] **Commit:** `feat(live-activity): widget extension and lock-screen intents`

### Task 5: UI test and verification

- [x] DEBUG `-liveActivityProbe`: a hidden probe text with the recorder's current state; `LiveActivityUITests`:
  starting a workout starts the activity, logging a set updates "Set x/y" and the rest, finishing ends it.
- [x] `scripts/ios-test.sh` green, SwiftLint 0 errors, simulator build of app + extension.
- [x] `codex review --base main`; fix P0–P2 test-first; self-review.
- [x] **Commit(s):** `test(live-activity): ...`, `fix(live-activity): review findings`

**Review fixes (Codex, P2):** the activity outlives the app process, so the running rest is now saved per workout
(`ActiveRestStore`, UserDefaults) and restored with the session, and a lock-screen Log set selects that exercise so a
cold-start relaunch doesn't switch the activity to an earlier exercise (`ActiveRestTests`,
`WorkoutActivityActionTests.loggingFromTheLockScreenSelectsThatExercise`).

**Needs a physical device:** the Dynamic Island look, the intents launching a killed app in the background, and the
lock-screen buttons with the phone locked (the simulator shows the lock screen but device-only behaviors such as
background launch budgets differ).
