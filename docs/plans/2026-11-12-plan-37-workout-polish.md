# Plan 37: keyboard bar, app icon, Body switch, exercise muscle map

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Four asks from the owner on 2026-11-12, after using the plan 36 build on their phone:

1. The keyboard bar on the exercise screen has a black strip behind its buttons, and the buttons touch the number pad.
2. The app has no icon.
3. On the Body tab, Muscle Recovery sits below the weigh-in list, so it takes a long scroll to reach.
4. An exercise's Muscles tab is only text. It should show the body map, as Body does.

**Owner's choices (2026-11-12):**
- **Keyboard bar:** no black layer behind the buttons, and the buttons 6 points above the keys.
- **Icon:** option C. A white "GR" in Barlow Condensed ExtraBold Italic sits inside the red set-number hexagon, on near-black.
- **Body:** a switch at the top with Muscles · Weight · Strength.
  - Muscles holds the recovery card and weekly sets.
  - Weight holds the goal, the chart and the weigh-ins.
  - Strength holds the top lifts and the strength level.
  - The tab opens on the last section picked, and on Muscles the first time.
- **Muscle map:** front and back figures, the same as Body's. Target muscles are in the app's red, secondary ones in a lighter amber, with a small key. The "Target / Secondary" text stays under the map.

The owner also asked to store weights in pounds as well as kilograms, so that a pound value doesn't come back as 44.8 lb. That changes stored and synced data, so it gets its own plan (38) after an investigation.

**Branch:** `feat-workout-polish`, from `feat-workout-fixes` e228b64. The phone runs plans 34-36 from that branch.

**Rules for implementers:**
- No `Co-Authored-By` or other attribution lines in commits.
- Don't run `scripts/test-db.sh`. Don't touch the phone, Cloudflare, `server/`, `.dev.vars` or `ios/Config/Local.xcconfig`.
- App tests: `scripts/ios-test.sh -only-testing:<target>/<class>` (`DEST=...` picks the simulator). Read the counts with `xcrun xcresulttool get test-results summary --path <newest ios/build/TestResults-*.xcresult>`.
- Don't use `rm -rf`.
- Match the surrounding code: doc comments on types and non-obvious functions, small files, value types, no `print`.

---

## Task 1: Keyboard bar without the black strip, 6 points above the keys

**Files:**
- `ios/GymRollins/Features/Workout/KeyboardBar.swift` (new)
- `ios/GymRollins/Features/Workout/LoggingView.swift`

**Cause of the strip:** the screen's `.background(Theme.background)` stops at the keyboard's safe area, so the window's black shows behind the system `.keyboard` toolbar. On the simulator, pixels below the keyboard's top edge are `#000000`, against `#0B0B10` above it. The system toolbar also leaves no room for a gap above the keys.

**Change:**
- Replace the `.keyboard` toolbar with `KeyboardBar`, which the screen's bottom `safeAreaInset` shows while a box has focus. The log bar shows when nothing has focus, as before.
- The bar:
  - previous and next chevrons in one glass capsule, and "Done" in its own capsule, all white (`Theme.textPrimary`);
  - nothing painted behind the capsules;
  - `KeyboardBar.gap` (6 points) of bottom padding above the keyboard.
- The background is `Theme.background.ignoresSafeArea()`, so it reaches under the keyboard too.
- The identifiers `keyboard.previous`, `keyboard.next` and `keyboard.done` stay, so the UI tests still find the buttons.

- [ ] **Step 1:** Build. `SetEditingUITests`, `TodayPlanScreenUITests` and `WorkoutFlowUITests` pass.
- [ ] **Step 2:** On the simulator, take a screenshot with the number pad up and the bar settled. There should be no black strip, and the capsules should clear the keys.
- [ ] **Step 3: Commit** `fix(app): the keyboard bar floats 6 pt above the keys with nothing behind it`.

## Task 2: App icon

**Files:**
- `scripts/make-app-icon.py` (new, needs Pillow)
- `ios/GymRollins/Resources/Assets.xcassets/AppIcon.appiconset/` (`AppIcon.png` and `Contents.json`)

**Change:**
- The script draws the icon: a 1024 × 1024 RGB PNG with no alpha.
- One universal icon. iOS derives the dark, tinted and clear looks from it. The icon is dark already.
- The watch app's icon set stays empty, because the watch app isn't embedded in phone builds.

- [ ] **Step 1:** Build. The built app's `Info.plist` names `AppIcon`, and `Assets.car` contains it.
- [ ] **Step 2: Commit** `feat(app): app icon, GR in the set-number hexagon`.

## Task 3: Body tab switch, Muscles · Weight · Strength

**Files:**
- `ios/GymRollins/Features/Body/BodyView.swift`
- UI tests under `ios/GymRollinsUITests/` that reach Body's sections: `BodyUITests`, `InsightsUITests` (`body.recovery`, `body.weeklySets.*`), `AppleHealthUITests` (`body.entry.*`), `FlowCoverageUITests` (`body.lift.0025`), and `AccessibilityAuditUITests` (`body.addWeighIn`).

**Look:**
- Under the "Body" title, a segmented `Picker` with Muscles · Weight · Strength, identifier `body.section`.
- Only the chosen section's content shows:
  - **Muscles:** `RecoveryCard(identifier: "body.recovery")` and `WeeklySetsCard()`.
  - **Weight:** the goal card, the range picker, the chart, and the weigh-in rows with swipe to delete. The add-weigh-in button goes wherever it is today.
  - **Strength:** the top lifts card (`strengthCard`, when there are lifts) and `StrengthLevelCard`.
- The choice is kept with `@AppStorage("bodySection")`. The first launch opens on Muscles.
- Keep every existing identifier.
- Check where `body.empty`, `body.trendPending` and `body.addWeighIn` live today, and put them in the section they belong to (Weight).

**Tests:**
- Tests that used Body's weigh-in or strength parts pick their section first (`body.section`), through a small helper in `UITestSupport` such as `app.openBodySection("Weight")`.
- A new UI test: Body opens on Muscles, showing `body.recovery` without scrolling. Pick Weight, leave the tab and come back: Weight is still picked.

- [ ] **Step 1:** Write the new UI test and run it to watch it fail.
- [ ] **Step 2:** Implement, update the tests, and run `BodyUITests`, `InsightsUITests`, `AppleHealthUITests`, `FlowCoverageUITests` and `AccessibilityAuditUITests`.
- [ ] **Step 3: Commit** `feat(app): Body opens on Muscles with a switch to Weight and Strength`.

## Task 4: The exercise's muscles on the body map

**Files:**
- `ios/GymRollins/Features/Insights/BodyMapView.swift`
- `ios/GymRollins/Features/Library/ExerciseDetailView.swift`
- A new small view such as `ios/GymRollins/Features/Library/ExerciseMuscleMap.swift`
- Tests

**Change:**
- `BodyMapView` colours regions from a snapshot today. Let it take a per-group fill instead. A `(MuscleGroup) -> Color` closure is one way, with an init that keeps the recovery behaviour for the existing callers (`RecoveryCard`, `RecoveryMapView`). The interactive mode and accessibility stay as they are.
- `ExerciseMuscleMap(exercise:)`:
  - front and back side by side, about 220 points tall;
  - target groups in `Theme.accent`, secondary groups in `Theme.record` (amber) mixed toward the muscle grey, the rest in `RecoveryPalette.muscle`;
  - groups come from GymCore `MuscleTaxonomy.contributions(for:)`, which puts the primary ones first and is empty for cardio;
  - a key under it: "Target" and "Secondary" swatches, leaving out Secondary when there are no secondary groups;
  - when the exercise maps to no group (cardio, unknown target), no map, only the text.
- On the Muscles tab, the map goes above the existing "Target: … / Secondary: …" card.
- Accessibility: the map is one element labelled like "Works chest; also shoulders, triceps", with identifier `detail.muscleMap`.

**Tests:**
- A unit test for the fill rule: a target group gets the target colour, a secondary group the secondary colour, and an untouched group the plain colour. If comparing colours is awkward, test a small pure helper that returns `.target`, `.secondary` or `.none` per group.
- A UI test: open Barbell Bench Press (0025) from the Library, tap Muscles, and `detail.muscleMap` exists with a label that mentions chest.

- [ ] **Step 1:** Failing tests.
- [ ] **Step 2:** Implement. Recovery screens look the same as before; check with `InsightsUITests`.
- [ ] **Step 3: Commit** `feat(app): an exercise's Muscles tab shows its muscles on the body map`.

## Task 5: Review, full suite, outcome

- [ ] A reviewer agent reviews `git diff feat-workout-fixes...HEAD`. Fix CRITICAL and HIGH findings.
- [ ] Full suite: `scripts/ios-test.sh`. Record the counts.
- [ ] Simulator screenshots: the keyboard bar with the pad up, the home screen icon, Body on Muscles, and an exercise's Muscles tab.
- [ ] Append `## Outcome` and commit `docs: plan 37 outcome`.
- [ ] A phone install only with the owner's go-ahead, after a Library backup. Not merged, not pushed.

## Outcome (2026-11-12)

**Commits** on `feat-workout-polish`, from `feat-workout-fixes` e228b64:

| Commit | What |
| --- | --- |
| d408aa4 | The plan |
| 7057c66 | Task 1: `KeyboardBar` in the screen's bottom inset replaces the `.keyboard` toolbar; the background reaches under the keys |
| 32192ef | Task 2: the app icon, option C, drawn by `scripts/make-app-icon.py` |
| 55b5409 | Plan 38's doc (weights keep their pound number) |
| 285f78e, merge 713b141 | Task 4: an exercise's Muscles tab shows its muscles on the body map (`ExerciseMuscleMap`) |
| 806c820, merge 1022739 | Task 3: Body opens on Muscles, with a Muscles · Weight · Strength switch |
| aba9832 | Review fixes |

**Review:** a reviewer agent checked `git diff feat-workout-fixes..1022739 -- ios scripts`. It found no CRITICAL or HIGH issues. Fixed in aba9832:
- **MEDIUM:** no test checked where the keyboard bar sits. `SetEditingUITests` now checks that Done sits above the keys (when the software keyboard shows) and that Done closes the bar.
- **MEDIUM:** the Body test only switched tabs and back, which a plain `@State` would pass too. It now relaunches on `-diskStore` and checks that Weight is still picked.
- **LOW:** the key showed "Target" for an exercise whose target isn't on the map. It now names only the colours the map uses (`ExerciseMuscleMap.keyRoles`).
- **LOW:** the keyboard bar's two capsules sit in one `GlassEffectContainer`.

**Left as they are:**
- **MEDIUM:** when a box takes focus, the bottom inset changes height (log bar to keyboard bar) during the keyboard animation, so `scrollTo` may centre a box near the bottom against the old layout. The simulator didn't show it. Check it on the phone with the last set of a long exercise.
- **LOW:**
  - colour is the only cue telling target from secondary on the map; the card under it names both;
  - switching Body sections rebuilds their cards, which may flash while they load;
  - `BodyMapView` holds two closures, so SwiftUI redraws its ~20 shapes on every parent update;
  - no test checks a stored section that isn't valid (it falls back to Muscles).

**Deviations from the plan:**
- In DEBUG, a `-uiTesting` launch without `-diskStore` forgets `bodySection`, so every UI test starts on Muscles. A `-diskStore` relaunch keeps it, as on a phone.
- `ExerciseMuscleMap`'s static helpers are `nonisolated`, so unit tests can call them off the main actor. The first test run crashed the test host without this.

**Tests:**
- Full suite on 1022739, before the review fixes (`scripts/ios-test.sh`, iPhone 17 Pro Max): 1288 tests, 1267 passed, 2 failed, 19 skipped.
  - `AccessibilityAuditUITests.testAgentsAudit`: text clipped on `agents.host.*` ("Connected from claude.ai"). It fails the same way on e228b64 on the Pro Max, so it predates this plan.
  - `AccessibilityAuditUITests.testUseWithClaudeAudit`: contrast on `claude.coach.text`. Run alone, it passed 2 of 2, so it's flaky.
- aba9832 is the same patch as 6090c49 on `feat-weights-lb`. That branch's full suite on 0661e86 (iPhone 17 Pro, plans 37 and 38 together) ran 1327 tests: 1308 passed, 0 failed, 19 skipped.

**Screenshots** (iPhone 17 Pro simulator):
- **Keyboard bar:** the number pad is up. The chevrons and Done are white glass capsules with nothing behind them and a gap above the keys. There's no black strip.
- **Muscles tab:** Barbell Bench Press (0025) and Cable Bar Lateral Pulldown (0150). Target muscles are red, secondary ones amber, the "Target · Secondary" key sits under the figures, and the text card is below that.
- **Body, Muscles:** the switch under the title, the recovery card, and all of weekly sets on one screen, with no scrolling needed.
- **Body, Weight:** the switch, the goal card with Add weigh-in, the chart and the weigh-ins.
- **Icon:** the 1024 px render. The built app's `Info.plist` names `AppIcon`, and the bundle has its PNGs and `Assets.car`. The simulator gave no home-screen capture ("Timeout waiting for screen surfaces").

**Found after the review:**
- `ReadmeScreenshotsUITests.test04Body` failed, so `scripts/readme-screenshots.sh` would have stopped on the missing `04-body`. It lifted weekly sets to just under the status bar, but the Muscles section now ends with weekly sets, so the list can't scroll that far. It now scrolls to the end of the list. The normal suite skips this class, which is why the full run didn't catch it. Its only helper user, `position`, went too.
- GymData's `DomainValidationTests` expected "routine" in two messages that plan 34 (57e6479) changed to "workout". The test now expects the new wording. GymData: 378 tests pass.

**Not verified:**
- The keyboard bar on the phone, with the real keyboard.
- How iOS's dark, tinted and clear looks render the icon.
- The phone install needs the owner's go-ahead and a Library backup first.
- Not merged and not pushed.
