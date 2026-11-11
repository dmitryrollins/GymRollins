# Plan 34: the week is the plan, and later days can be changed

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
- **My Plan shows the week.** Each day has a row with its workout, and the owner taps a day to change it. A workout that is on other days too asks whether the change is for all of those days or for this day only.
- **Today edits later days.** A later day takes the same edits as today, for that date only. Switch and Save Changes ask whether a change is for this date or for every week.

**Architecture:** routines stay the data model and the server, sync and agents don't change. Only the screens change. The UI says "workout" for a routine.
- **A later day's changes** are a `TodayPlan` per date in a new `LaterDayPlanStore` (UserDefaults, phone only, like `PlannedSwitchStore`).
  - Today's `TodayPlanEditor` edits that plan through a small `TodayPlanSaving` protocol: `TodayPlanStore` for today, `LaterDayPlanSaver` for a later date.
  - On the day itself, `todaysPlan(at:)` takes the entry into `TodayPlanStore`, the same way it already takes an agent's planned switch.
- **"Only Monday"** makes a copy of the workout (new ids, named "Push + Arms (Mon)") and puts it on that one weekday.

**Tech Stack:** SwiftUI (iOS 26); Swift Testing unit tests in `GymRollinsTests`; XCUITest in `GymRollinsUITests`; XcodeGen picks up new files under `ios/GymRollins` and the test folders.

---

## Decisions (owner, 2026-11-10)

1. **Routines stay underneath.**
   - The owner's week trains 4 days with 3 workouts, so one workout is on two days. 2 more workouts are kept for switching.
   - Every agent change type names a routine, and so do sync, the server, Switch, the rest-day suggestion, Save Changes and the export.
   - Removing routines would mean converting the only live copy of the owner's data. The change is to the screens only.
2. **The week is the plan.**
   - My Plan lists Monday to Sunday. Each row has the day's workout (or Rest), its first three exercises and "+N" for the rest. Today's row is marked.
   - Tapping a day opens that day's editor. A workout picker at the top offers a saved workout, a new one, or Rest, and the workout's exercises are edited below it.
   - If the workout is also on other days, Done asks "Change Monday and Saturday" or "Only Monday". Only Monday makes a copy named "Push + Arms (Mon)", which the owner can rename, and puts it on Monday.
   - A "Saved workouts" row at the bottom opens the old routines list: every workout, paused ones included, plus "+ Workout".
3. **Later days work like today.**
   - A later day has Switch, the exercise menu, Add Exercise, set editing and Save Changes. "Back to today" stays where Start is: a later day can't be started.
   - Its changes are for that date only. The day then says "changed for this day", and "Reset this day" returns it to the week.
4. **Switch asks where.** Any pick other than the day's own workout asks "Only Sat 26 Sep" or "Every Saturday". For an empty workout on today, the second choice reads "Rest every Saturday".
   - A paused workout can't go on the week, so it gets the first choice only.
   - On a later rest day the empty choice reads "Rest".
5. **Save Changes asks about shared days.** When the day's own workout is on other days too, it asks "Change Monday and Saturday" or "Only Saturday".
   - A switched workout is saved for its own days without asking.
   - After "Only …" the day shows the copy. Today's typed sets that the copy didn't keep (warm-ups, rest) go.
6. **A changed date keeps its own version.**
   - My Plan edits don't reach a date with its own version until it is reset. The same rule already applies to today's stored plan: a plan with unsaved exercise changes keeps its snapshot.
   - An agent's later `today` change for that date replaces the owner's change, with the usual undo. An owner's change replaces an agent's earlier planned switch for that date.
7. **One-date changes stay on this iPhone.** Agents see the week, not the one-date changes. A date's change is dropped once the day has passed.

Out of scope:
- Server, MCP tools, agent prompts and sync.
- The words "routine" in agent-facing text (proposal labels, `SyncStatusText`, `SignInGate`).
- Editing past days.
- Rest-day suggestions on later days.

## File map

New:
- `ios/GymRollins/Features/Today/LaterDayPlanStore.swift`: `LaterDayPlanStore` and the `TodayPlanSaving` protocol.
- `ios/GymRollins/App/AppEnvironment+LaterDays.swift`: `LaterDay`, `laterDay(on:)`, `LaterDayPlanSaver`, `laterDaySaver(on:scheduled:)`, `isLaterDayChanged`, `resetLaterDay` and `takeLaterDayPlan`.
- `ios/GymRollins/Features/Plan/WeekPlan.swift`: day names, the list of a workout's days, the exercise line and the copy.
- `ios/GymRollins/App/AppEnvironment+WeekPlan.swift`: `otherDays(of:besides:)`, `saveWorkout(_:onlyOn:)` and `schedule(every:_:)`.
- `ios/GymRollins/Features/Today/TodaySwitchSheet.swift`.
- `ios/GymRollins/Features/Today/TodayGymNote.swift`, moved out of the preview file.
- `ios/GymRollins/Features/Plan/RoutineExercisesSection.swift`.
- `ios/GymRollins/Features/Plan/DayWorkoutEditView.swift`.
- `ios/GymRollins/Features/Plan/SavedWorkoutsView.swift`.
- Tests:
  - `ios/GymRollinsTests/LaterDayPlanStoreTests.swift`
  - `ios/GymRollinsTests/LaterDayEnvironmentTests.swift`
  - `ios/GymRollinsTests/WeekPlanTests.swift`
  - `ios/GymRollinsUITests/TodayScopeUITests.swift`

Modified:
- `ios/GymRollins/Features/Today/TodayPlan.swift`: `TodayPlanStore.current`.
- `ios/GymRollins/Features/Today/PlannedSwitchStore.swift`: `remove(day:)`.
- `ios/GymRollins/Features/Today/TodayPlanEditor.swift`: the store is `any TodayPlanSaving`.
- `ios/GymRollins/App/AppEnvironment+Watch.swift`: `todaysPlan(at:)` takes the later-day plan.
- `ios/GymRollins/App/AppEnvironment+TodayRoutine.swift`: an agent's change replaces the owner's, and the reset clears the new store.
- `ios/GymRollins/App/AppEnvironment.swift`: `eraseAllLocalData`.
- `ios/GymRollins/Features/Today/TodayDay.swift`: `DayPreview.laterDay` replaces `DayPreview.model`.
- `ios/GymRollins/Features/Today/TodayView.swift`.
- `ios/GymRollins/Features/Workout/LoggingView.swift`: `canStart`.
- `ios/GymRollins/Features/Plan/PlanView.swift`.
- `ios/GymRollins/Features/Plan/RoutineEditView.swift`.
- `ios/GymRollins/Features/Settings/SettingsPreferences.swift`: `newRoutineDraft`.
- `ios/GymRollins/Features/Limits/LimitsCheckInCard.swift`: one line of wording.
- `README.md`: line 37.
- Tests:
  - `ios/GymRollinsTests/TodayDayTests.swift`
  - `ios/GymRollinsUITests/TodayDaysUITests.swift`
  - `ios/GymRollinsUITests/TodayFlexUITests.swift`
  - `ios/GymRollinsUITests/TodayPlanScreenUITests.swift`
  - `ios/GymRollinsUITests/PlanUITests.swift`
  - `ios/GymRollinsUITests/FlowCoverageUITests.swift`
  - `ios/GymRollinsUITests/LimitsCheckInUITests.swift`
  - `ios/GymRollinsUITests/ProposalUITests.swift`
  - `ios/GymRollinsUITests/AccessibilityAuditUITests.swift`
  - `ios/GymRollinsUITests/DynamicTypeUITests.swift`

Deleted:
- `ios/GymRollins/Features/Today/TodayDayPreviewView.swift`
- `ios/GymRollins/App/AppEnvironment+DayPreview.swift`
- `ios/GymRollinsTests/DayPreviewEnvironmentTests.swift`

**Running tests.** From the repo root, run `scripts/ios-test.sh -only-testing:<Target>/<Suite>`. It regenerates the project, so new files are included. The script writes `ios/build/TestResults-<time>.xcresult`. Read the latest result with:

```bash
R=$(ls -td ios/build/TestResults-*.xcresult | head -1); xcrun xcresulttool get test-results summary --path "$R" | grep -E '"(result|passedTests|failedTests|skippedTests)"'
```

**UI test seed.** `-uiTesting` with `-fixedNow 2026-09-26T09:00:00Z`, which is a Saturday.
- **Monday:** Push + Arms.
- **Wednesday:** Pull + Shoulders + Triceps.
- **Friday:** Upper weak points.
- **Saturday:** Push + Arms.
- **Legs:** paused and not on the week.
- **Push + Arms** starts with Bench Press, `0025`, at 3 sets.

**Commits.** Use conventional messages with no attribution trailers: no Co-Authored-By, no "Generated with", no Claude-Session.

---

### Task 1: A store for later days' changes

**Files:**
- Create: `ios/GymRollins/Features/Today/LaterDayPlanStore.swift`
- Modify: `ios/GymRollins/Features/Today/TodayPlan.swift` (`TodayPlanStore.load(day:routines:scheduled:)`)
- Modify: `ios/GymRollins/Features/Today/PlannedSwitchStore.swift`
- Modify: `ios/GymRollins/Features/Today/TodayPlanEditor.swift:18-40`
- Test: `ios/GymRollinsTests/LaterDayPlanStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/GymRollinsTests/LaterDayPlanStoreTests.swift`:

```swift
import Foundation
import GymCore
import Testing
@testable import GymRollins

/// The owner's changes to later days (owner, 2026-11-10): one `TodayPlan` per date, under the rules today's stored plan
/// follows, taken on the day.
@Suite struct LaterDayPlanStoreTests {
    private let monday = "2026-09-28"

    private func routine(_ name: String, _ ids: [String]) -> Routine {
        Routine(name: name, exercises: ids.map { RoutineExercise(exerciseId: $0, sets: 3, reps: 8) })
    }

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "LaterDayPlanStoreTests.\(UUID())"))
    }

    @Test func aDatesChangeIsKeptForThatDateOnly() throws {
        let store = LaterDayPlanStore(defaults: try defaults())
        let push = routine("Push", ["0025", "0027"])
        let edited = TodayPlan.make(scheduled: push, routines: [push], lastDone: [:], day: monday)
            .deleting(push.exercises[0].id)
        store.save(edited)

        #expect(store.plan(day: monday, routines: [push], scheduled: push.id) == edited)
        #expect(store.plan(day: "2026-09-29", routines: [push], scheduled: push.id) == nil)
        #expect(store.days() == [monday])
    }

    @Test func theRulesOfTodaysStoredPlanApply() throws {
        let store = LaterDayPlanStore(defaults: try defaults())
        let push = routine("Push", ["0025"]), pull = routine("Pull", ["0027"])
        let switched = TodayPlan.make(scheduled: push, routines: [push, pull], lastDone: [:], day: monday).switched(to: pull)
        store.save(switched)
        #expect(store.plan(day: monday, routines: [push], scheduled: push.id) == nil, "its workout was deleted")

        let edited = TodayPlan.make(scheduled: push, routines: [push], lastDone: [:], day: monday)
            .deleting(push.exercises[0].id)
        store.save(edited)
        #expect(store.plan(day: monday, routines: [push, pull], scheduled: pull.id) == nil,
                "Monday now trains another workout: a change to the old one is dropped")
    }

    @Test func takingTheDayRemovesItAndEveryEarlierDay() throws {
        let store = LaterDayPlanStore(defaults: try defaults())
        let push = routine("Push", ["0025"])
        let sunday = TodayPlan.make(scheduled: nil, routines: [], lastDone: [:], day: "2026-09-27").switched(to: push)
        let monday = TodayPlan.make(scheduled: nil, routines: [], lastDone: [:], day: self.monday).switched(to: push)
        let tuesday = TodayPlan.make(scheduled: nil, routines: [], lastDone: [:], day: "2026-09-29").switched(to: push)
        [sunday, monday, tuesday].forEach(store.save)

        #expect(store.take(day: self.monday) == monday)
        #expect(store.days() == ["2026-09-29"])
        #expect(store.take(day: self.monday) == nil)
    }

    @Test func removeAndClear() throws {
        let store = LaterDayPlanStore(defaults: try defaults())
        let push = routine("Push", ["0025"])
        store.save(TodayPlan.make(scheduled: nil, routines: [], lastDone: [:], day: monday).switched(to: push))
        store.remove(day: monday)
        #expect(store.days().isEmpty)
        store.save(TodayPlan.make(scheduled: nil, routines: [], lastDone: [:], day: monday).switched(to: push))
        store.clear()
        #expect(store.days().isEmpty)
    }

    @Test func anAgentsSwitchForADateCanBeRemovedWhateverItPicks() throws {
        let planned = PlannedSwitchStore(defaults: try defaults())
        planned.set(UUID(), on: monday)
        planned.remove(day: monday)
        #expect(planned.all().isEmpty)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/LaterDayPlanStoreTests`
Expected: the build fails with "cannot find 'LaterDayPlanStore' in scope".

- [ ] **Step 3: Share today's stored-plan rules**

In `ios/GymRollins/Features/Today/TodayPlan.swift`, replace the body of `TodayPlanStore.load(day:routines:scheduled:)` and add `current` right after it. Keep the doc comment above `load`.

```swift
    func load(day: String, routines: [Routine], scheduled: UUID?) -> TodayPlan? {
        load(day: day, routineIds: Set(routines.map(\.id))).flatMap {
            Self.current($0, routines: routines, scheduled: scheduled)
        }
    }

    /// `plan` under the current plan, as `load(day:routines:scheduled:)` describes; also used for a later day's change
    /// (`LaterDayPlanStore`). Nil when the schedule moved on from it.
    static func current(_ plan: TodayPlan, routines: [Routine], scheduled: UUID?) -> TodayPlan? {
        switch plan.kind {
        case .scheduled where plan.base?.id != scheduled: return nil
        case .restDaySuggestion where scheduled != nil: return nil
        default: break
        }
        guard !plan.edited || plan.exercisesMatchBase,
              let current = plan.base.flatMap({ base in routines.first { $0.id == base.id } }) else { return plan }
        return plan.rebased(on: current)
    }
```

- [ ] **Step 4: Write the store and the saving protocol**

Create `ios/GymRollins/Features/Today/LaterDayPlanStore.swift`:

```swift
import Foundation
import GymCore

/// Where `TodayPlanEditor` keeps the day's changes: `TodayPlanStore` for today, `LaterDayPlanSaver` for a later day.
protocol TodayPlanSaving {
    func save(_ plan: TodayPlan)
    func clear()
}

extension TodayPlanStore: TodayPlanSaving {}

/// The owner's changes to later days (owner, 2026-11-10): yyyy-MM-dd → that day's `TodayPlan`, kept on this iPhone
/// (UserDefaults, like `PlannedSwitchStore`) and never synced. On the day, Today takes the entry and stores it as
/// today's plan (`AppEnvironment.takeLaterDayPlan`); an agent's later `today` change for the date replaces it.
struct LaterDayPlanStore {
    static let key = "gymrollins.laterDayPlans"
    let defaults: UserDefaults

    /// The change stored for `day`, under the rules today's stored plan follows (`TodayPlanStore.current`). Nil when
    /// there is none, its workout is gone, or the schedule moved on from it.
    func plan(day: String, routines: [Routine], scheduled: UUID?) -> TodayPlan? {
        guard let plan = all()[day] else { return nil }
        if let base = plan.base, !routines.contains(where: { $0.id == base.id }) { return nil }
        return TodayPlanStore.current(plan, routines: routines, scheduled: scheduled)
    }

    /// The dates that have a change stored.
    func days() -> Set<String> { Set(all().keys) }

    func save(_ plan: TodayPlan) {
        write(all().merging([plan.day: plan]) { _, new in new })
    }

    func remove(day: String) {
        write(all().filter { $0.key != day })
    }

    /// The change stored for `day`, removed from the store along with anything for earlier days.
    func take(day: String) -> TodayPlan? {
        let current = all()
        guard current.keys.contains(where: { $0 <= day }) else { return nil }
        write(current.filter { $0.key > day })
        return current[day]
    }

    func clear() { defaults.removeObject(forKey: Self.key) }

    private func all() -> [String: TodayPlan] {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode([String: TodayPlan].self, from: data) else { return [:] }
        return stored
    }

    private func write(_ entries: [String: TodayPlan]) {
        guard !entries.isEmpty, let data = try? JSONEncoder().encode(entries) else { clear(); return }
        defaults.set(data, forKey: Self.key)
    }
}
```

In `ios/GymRollins/Features/Today/PlannedSwitchStore.swift`, add after `remove(day:routineId:)`:

```swift
    /// Removes the entry for `day`, whatever it picks (the owner changed or reset that date).
    func remove(day: String) {
        write(all().filter { $0.key != day })
    }
```

- [ ] **Step 5: Let the editor save to either store**

In `ios/GymRollins/Features/Today/TodayPlanEditor.swift`:
- Change the class comment's second sentence to: "Every change is a `TodayPlan` edit for that one day, kept in its store (`TodayPlanSaving`: today's `TodayPlanStore`, or a later day's `LaterDayPlanSaver`)."
- Replace `@ObservationIgnored private var store: TodayPlanStore?` with `@ObservationIgnored private var store: (any TodayPlanSaving)?`.
- In `init`, change the parameter to `store: (any TodayPlanSaving)? = nil`.
- In `configure`, change it to `store: any TodayPlanSaving`.
- Change the comment on `apply` to "Applies a change for the day and keeps it in the day's store (ignored while locked)."

- [ ] **Step 6: Run the tests**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/LaterDayPlanStoreTests -only-testing:GymRollinsTests/TodayPlanTests -only-testing:GymRollinsTests/TodayPlanEditorTests -only-testing:GymRollinsTests/TodayPlanLaunchTests`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add ios/GymRollins/Features/Today/LaterDayPlanStore.swift ios/GymRollins/Features/Today/TodayPlan.swift \
  ios/GymRollins/Features/Today/PlannedSwitchStore.swift ios/GymRollins/Features/Today/TodayPlanEditor.swift \
  ios/GymRollinsTests/LaterDayPlanStoreTests.swift
git commit -m "feat(ios): a store for later days' changes, under the rules today's stored plan follows"
```

---

### Task 2: The app reads, saves, resets and takes a later day's change

**Files:**
- Create: `ios/GymRollins/App/AppEnvironment+LaterDays.swift`
- Modify: `ios/GymRollins/App/AppEnvironment+Watch.swift:23-34` (`todaysPlan(at:)`)
- Modify: `ios/GymRollins/App/AppEnvironment+TodayRoutine.swift:11-29`
- Modify: `ios/GymRollins/App/AppEnvironment.swift` (`eraseAllLocalData`)
- Test: `ios/GymRollinsTests/LaterDayEnvironmentTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/GymRollinsTests/LaterDayEnvironmentTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// A later day on Today (owner, 2026-11-10): its plan (the owner's change, else an agent's switch, else the week), its
/// changes for that date only, Reset this day, and the change becoming today's plan on the day. The seed's Saturday
/// 26 Sep: Sunday is a rest day, Monday trains Push + Arms.
@MainActor
@Suite struct LaterDayEnvironmentTests {
    private func makeEnv() throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: "LaterDayEnvironmentTests.\(UUID())"))
        return try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]),
                                  defaults: defaults)
    }

    private func date(_ offset: Int, _ env: AppEnvironment) -> Date { TodayDay(offset: offset).date(now: env.now()) }

    private func pull(_ env: AppEnvironment) throws -> Routine {
        try #require(try env.routines.all().first { $0.name.hasPrefix("Pull") })
    }

    @Test func aRestDayIsAnEmptyPlanAndMondayIsPush() throws {
        let env = try makeEnv()
        let sunday = try env.laterDay(on: date(1, env))
        #expect(sunday.plan.kind == .empty)
        #expect(sunday.plan.exercises.isEmpty)
        #expect(sunday.scheduled == nil)
        #expect(!sunday.changed)
        let monday = try env.laterDay(on: date(2, env))
        #expect(monday.plan.title == "Push + Arms")
        #expect(monday.scheduled?.name == "Push + Arms")
        #expect(!monday.changed)
    }

    @Test func anAgentsPlannedSwitchShowsAsChangedAndStaysUntilItsDay() throws {
        let env = try makeEnv(), pull = try pull(env)
        let monday = TodayPlan.dayKey(date(2, env))
        PlannedSwitchStore(defaults: env.defaults).set(pull.id, on: monday)
        let later = try env.laterDay(on: date(2, env))
        #expect(later.plan.base?.id == pull.id)
        #expect(later.changed)
        #expect(PlannedSwitchStore(defaults: env.defaults).all()[monday] == pull.id, "reading doesn't take it")
        #expect(try env.todaysPlan().plan.title != pull.name)
    }

    @Test func theOwnersChangeIsForThatDateOnly() throws {
        let env = try makeEnv()
        let monday = try env.laterDay(on: date(2, env))
        let count = monday.plan.exercises.count
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id)
            .save(monday.plan.deleting(monday.plan.exercises[0].id))

        let changed = try env.laterDay(on: date(2, env))
        #expect(changed.changed)
        #expect(changed.plan.exercises.count == count - 1)
        #expect(env.isLaterDayChanged(TodayPlan.dayKey(date(2, env))))
        #expect(try env.laterDay(on: date(9, env)).plan.exercises.count == count, "the next Monday is as planned")
        #expect(try env.todaysPlan().plan.exercises.count == count, "today (Saturday, Push + Arms) is untouched")
    }

    @Test func theOwnersChangeReplacesAnAgentsEarlierSwitch() throws {
        let env = try makeEnv(), pull = try pull(env)
        let mondayKey = TodayPlan.dayKey(date(2, env))
        PlannedSwitchStore(defaults: env.defaults).set(pull.id, on: mondayKey)
        let monday = try env.laterDay(on: date(2, env))
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id)
            .save(monday.plan.deleting(monday.plan.exercises[0].id))
        #expect(PlannedSwitchStore(defaults: env.defaults).all()[mondayKey] == nil)
        #expect(try env.laterDay(on: date(2, env)).plan.base?.id == pull.id, "the edit was made on Pull")
    }

    @Test func anAgentsLaterChangeReplacesTheOwners() throws {
        let env = try makeEnv(), pull = try pull(env)
        let monday = try env.laterDay(on: date(2, env))
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id)
            .save(monday.plan.deleting(monday.plan.exercises[0].id))
        env.applyDayRoutines([PlanDayRoutine(changeId: "c1", day: TodayPlan.dayKey(date(2, env)), routineId: pull.id)])
        let later = try env.laterDay(on: date(2, env))
        #expect(later.plan.base?.id == pull.id)
        #expect(!later.plan.edited)
    }

    @Test func resetThisDayFollowsTheWeekAgain() throws {
        let env = try makeEnv(), pull = try pull(env)
        let mondayKey = TodayPlan.dayKey(date(2, env))
        let monday = try env.laterDay(on: date(2, env))
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id).save(monday.plan.switched(to: pull))
        env.resetLaterDay(mondayKey)
        let reset = try env.laterDay(on: date(2, env))
        #expect(reset.plan.title == "Push + Arms")
        #expect(!reset.changed)
        #expect(!env.isLaterDayChanged(mondayKey))
    }

    @Test func restOnATrainingDateIsKept_andAnEmptyRestDayIsNotAChange() throws {
        let env = try makeEnv()
        let monday = try env.laterDay(on: date(2, env))
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id).save(monday.plan.switched(to: nil))
        let rested = try env.laterDay(on: date(2, env))
        #expect(rested.changed)
        #expect(rested.plan.kind == .empty)

        let sunday = try env.laterDay(on: date(1, env))
        let saver = env.laterDaySaver(on: date(1, env), scheduled: nil)
        saver.save(sunday.plan)
        #expect(!env.isLaterDayChanged(TodayPlan.dayKey(date(1, env))), "nothing on a rest day is no change")
    }

    @Test func onTheDayTheChangeBecomesTodaysPlan() throws {
        let env = try makeEnv()
        let monday = try env.laterDay(on: date(2, env))
        let count = monday.plan.exercises.count
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id)
            .save(monday.plan.deleting(monday.plan.exercises[0].id))

        let onTheDay = try env.todaysPlan(at: date(2, env)).plan
        #expect(onTheDay.exercises.count == count - 1)
        #expect(LaterDayPlanStore(defaults: env.defaults).days().isEmpty, "taken")
        #expect(try env.todaysPlan(at: date(2, env)).plan.exercises.count == count - 1, "now today's stored plan")
    }

    @Test func aChangeWhoseWorkoutIsGoneIsDroppedWhenRead() throws {
        let env = try makeEnv(), pull = try pull(env)
        let mondayKey = TodayPlan.dayKey(date(2, env))
        let monday = try env.laterDay(on: date(2, env))
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id).save(monday.plan.switched(to: pull))
        try env.routines.delete(pull.id)
        #expect(!(try env.laterDay(on: date(2, env)).changed))
        #expect(!env.isLaterDayChanged(mondayKey))
    }

    @Test func wipingTheSwitchesClearsLaterDays() throws {
        let env = try makeEnv(), pull = try pull(env)
        let monday = try env.laterDay(on: date(2, env))
        env.laterDaySaver(on: date(2, env), scheduled: monday.scheduled?.id).save(monday.plan.switched(to: pull))
        AppEnvironment.clearTodaySwitches(in: env.defaults)
        #expect(LaterDayPlanStore(defaults: env.defaults).days().isEmpty)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/LaterDayEnvironmentTests`
Expected: the build fails with "value of type 'AppEnvironment' has no member 'laterDay'".

- [ ] **Step 3: Write the environment part**

Create `ios/GymRollins/App/AppEnvironment+LaterDays.swift`:

```swift
import Foundation
import GymCore
import GymData

/// Later days on Today (owner, 2026-11-10): a later day is edited like today, for that date only. The owner's change
/// waits in `LaterDayPlanStore` until the day, when it becomes today's stored plan. An agent's planned switch for a
/// date (`PlannedSwitchStore`) and the owner's change replace each other: the newer one wins.
extension AppEnvironment {
    /// The later day Today shows.
    struct LaterDay {
        let plan: TodayPlan
        /// The workout the week has on that day (nil: a rest day, or its workout is paused).
        let scheduled: Routine?
        /// The owner or an agent changed this date: Today says so and offers Reset this day.
        let changed: Bool
    }

    /// The later day `date` falls on: the owner's change for it, else an agent's planned switch, else the week (a
    /// rest day is an empty plan), at the current gym. A change that no longer applies is removed; nothing is taken.
    func laterDay(on date: Date) throws -> LaterDay {
        let all = try routines.all()
        let routine = try routines.schedule().routineId(on: date).flatMap { id in all.first { $0.id == id } }
        let scheduled = routine?.paused == true ? nil : routine
        let day = TodayPlan.dayKey(date)
        let store = LaterDayPlanStore(defaults: defaults)
        if let stored = store.plan(day: day, routines: all, scheduled: scheduled?.id) {
            return LaterDay(plan: stored.adapted(by: gymAdapter()), scheduled: scheduled, changed: true)
        }
        if store.days().contains(day) { store.remove(day: day) }
        let preview = DayPreview.plan(day: day, scheduled: scheduled, routines: all,
                                      planned: PlannedSwitchStore(defaults: defaults).all()[day])
        let plan = preview ?? TodayPlan(day: day, kind: .empty, base: nil, exercises: [], edited: false)
        return LaterDay(plan: plan.adapted(by: gymAdapter()), scheduled: scheduled, changed: preview?.kind == .switched)
    }

    /// Where Today's editor keeps changes to the later day `date` falls on.
    func laterDaySaver(on date: Date, scheduled: UUID?) -> LaterDayPlanSaver {
        LaterDayPlanSaver(day: TodayPlan.dayKey(date), scheduled: scheduled, defaults: defaults)
    }

    /// Whether the owner or an agent changed the later day `day` (yyyy-MM-dd).
    func isLaterDayChanged(_ day: String) -> Bool {
        LaterDayPlanStore(defaults: defaults).days().contains(day) || PlannedSwitchStore(defaults: defaults).all()[day] != nil
    }

    /// Reset this day: the date follows the week again (the owner's change and an agent's switch for it go).
    func resetLaterDay(_ day: String) {
        LaterDayPlanStore(defaults: defaults).remove(day: day)
        PlannedSwitchStore(defaults: defaults).remove(day: day)
    }

    /// On the day itself: the owner's change for it, taken from `LaterDayPlanStore` and stored as today's plan (unless
    /// today already has one). Nil when there is none or it no longer applies.
    func takeLaterDayPlan(day: String, routines all: [Routine], scheduled: Routine?) -> TodayPlan? {
        guard let plan = LaterDayPlanStore(defaults: defaults).take(day: day),
              plan.base.map({ base in all.contains { $0.id == base.id } }) ?? true,
              let current = TodayPlanStore.current(plan, routines: all, scheduled: scheduled?.id) else { return nil }
        let store = TodayPlanStore(defaults: defaults) // no revision bump: this runs while the plan is being read
        guard store.load(day: day, routineIds: Set(all.map(\.id))) == nil else { return nil }
        store.save(current)
        return current
    }
}

/// Where Today's editor keeps a later day's changes: `LaterDayPlanStore`. Saving also drops an agent's planned switch
/// for that date (the owner's change is the newer one); a plan that is the day as planned is no change.
struct LaterDayPlanSaver: TodayPlanSaving {
    let day: String
    /// The workout the week has on that day (nil: a rest day).
    let scheduled: UUID?
    let defaults: UserDefaults

    func save(_ plan: TodayPlan) {
        PlannedSwitchStore(defaults: defaults).remove(day: day)
        let store = LaterDayPlanStore(defaults: defaults)
        let asPlanned = !plan.hasTodayChanges || (scheduled == nil && plan.kind == .empty && plan.exercises.isEmpty)
        if asPlanned { store.remove(day: day) } else { store.save(plan) }
    }

    func clear() {
        PlannedSwitchStore(defaults: defaults).remove(day: day)
        LaterDayPlanStore(defaults: defaults).remove(day: day)
    }
}
```

- [ ] **Step 4: Take the change on the day**

In `ios/GymRollins/App/AppEnvironment+Watch.swift`, in `todaysPlan(at:)`, replace these lines:

```swift
        let planned = takePlannedSwitch(day: day, routines: all, scheduled: scheduled)
        let plan = TodayPlanStore(defaults: defaults).load(day: day, routines: all, scheduled: scheduled?.id)
            ?? planned
            ?? TodayPlan.make(scheduled: scheduled, routines: all, lastDone: lastDoneByRoutine(), day: day)
```

with:

```swift
        // The owner's change for this date goes first; an agent's planned switch then finds today's plan stored.
        let laterDay = takeLaterDayPlan(day: day, routines: all, scheduled: scheduled)
        let planned = takePlannedSwitch(day: day, routines: all, scheduled: scheduled)
        let plan = TodayPlanStore(defaults: defaults).load(day: day, routines: all, scheduled: scheduled?.id)
            ?? laterDay
            ?? planned
            ?? TodayPlan.make(scheduled: scheduled, routines: all, lastDone: lastDoneByRoutine(), day: day)
```

Change the doc comment's first sentence to: "`todaysPlan()` for the day `date` falls on (the owner's change for that date, or a switch Claude planned for it, becomes its stored plan)."

- [ ] **Step 5: An agent's change replaces the owner's, and every wipe clears later days**

In `ios/GymRollins/App/AppEnvironment+TodayRoutine.swift`:
- In `clearTodaySwitches(in:)`, add `LaterDayPlanStore(defaults: defaults).clear()` after the `PlannedSwitchStore` line, and change its comment to "Forgets today's switched/edited plan, the owner's changes to later days and Claude's planned switches (a fresh, reset or wiped store)."
- In `applyDayRoutines(_:)`, add `let later = LaterDayPlanStore(defaults: defaults)` after `let planned = …`. In the `else if item.day > today` branch, put `later.remove(day: item.day) // the agent's change is the newer one` before `planned.set(…)`.

In `ios/GymRollins/App/AppEnvironment.swift`, in `eraseAllLocalData()`, add `LaterDayPlanStore(defaults: defaults).clear()` after `PlannedSwitchStore(defaults: defaults).clear()`.

- [ ] **Step 6: Run the tests**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/LaterDayEnvironmentTests -only-testing:GymRollinsTests/DayPreviewEnvironmentTests -only-testing:GymRollinsTests/TodayRoutineProposalTests -only-testing:GymRollinsTests/WatchTodaySyncTests`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add ios/GymRollins/App/AppEnvironment+LaterDays.swift ios/GymRollins/App/AppEnvironment+Watch.swift \
  ios/GymRollins/App/AppEnvironment+TodayRoutine.swift ios/GymRollins/App/AppEnvironment.swift \
  ios/GymRollinsTests/LaterDayEnvironmentTests.swift
git commit -m "feat(ios): a later day's change is read, saved and reset, and becomes today's plan on the day"
```

---

### Task 3: The week's helpers: day names, shared days and the one-day copy

**Files:**
- Create: `ios/GymRollins/Features/Plan/WeekPlan.swift`
- Create: `ios/GymRollins/App/AppEnvironment+WeekPlan.swift`
- Test: `ios/GymRollinsTests/WeekPlanTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/GymRollinsTests/WeekPlanTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// The week as the plan (owner, 2026-11-10): day names, which days a workout is on, and "Only Monday", a copy of the
/// workout that takes over that one day.
@MainActor
@Suite struct WeekPlanTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    @Test func dayNamesRunMondayToSunday() {
        #expect(WeekPlan.dayName(1, calendar: calendar) == "Monday")
        #expect(WeekPlan.dayName(7, calendar: calendar) == "Sunday")
        #expect(WeekPlan.shortDayName(6, calendar: calendar) == "Sat")
        #expect(WeekPlan.dayList([6, 1], calendar: calendar) == "Monday and Saturday")
    }

    @Test func aWorkoutsDaysComeMondayFirst() {
        let push = UUID(), pull = UUID()
        let schedule = WeekSchedule(days: [6: push, 1: push, 3: pull])
        #expect(WeekPlan.weekdays(of: push, in: schedule) == [1, 6])
        #expect(WeekPlan.weekdays(of: UUID(), in: schedule).isEmpty)
    }

    @Test func theExerciseLineNamesThreeAndCountsTheRest() {
        #expect(WeekPlan.exerciseLine(["Bench", "Dips", "Curl", "Fly", "Raise"]) == "Bench \u{00B7} Dips \u{00B7} Curl +2")
        #expect(WeekPlan.exerciseLine(["Bench"]) == "Bench")
        #expect(WeekPlan.exerciseLine([]) == "")
    }

    @Test func theCopyIsANewWorkoutForThatDay() {
        let item = RoutineExercise(exerciseId: "0025", sets: 4, reps: 8, weightKg: 60, supersetGroup: "A",
                                   weightSetAt: Date(timeIntervalSince1970: 1))
        let push = Routine(name: "Push + Arms", emoji: "💪", policy: .linear, exercises: [item])
        let copy = WeekPlan.copy(of: push, for: 1, calendar: calendar)
        #expect(copy.id != push.id)
        #expect(copy.name == "Push + Arms (Mon)")
        #expect(copy.emoji == "💪")
        #expect(copy.policy == .linear)
        #expect(!copy.paused)
        #expect(copy.exercises.map(\.id) != push.exercises.map(\.id), "an item id belongs to one workout")
        #expect(copy.exercises.map(\.exerciseId) == ["0025"])
        #expect(copy.exercises[0].sets == 4)
        #expect(copy.exercises[0].weightKg == 60)
        #expect(copy.exercises[0].supersetGroup == "A")
        #expect(copy.exercises[0].weightSetAt == item.weightSetAt)
    }

    @Test func theCopysNameStaysWithinTheLimit() {
        let long = Routine(name: String(repeating: "x", count: DomainLimits.routineNameMax), exercises: [])
        let copy = WeekPlan.copy(of: long, for: 3, calendar: calendar)
        #expect(copy.name.count == DomainLimits.routineNameMax)
        #expect(copy.name.hasSuffix(" (Wed)"))
    }

    // MARK: On the store (seed: Push + Arms on Monday and Saturday, Pull on Wednesday)

    private func makeEnv() throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: "WeekPlanTests.\(UUID())"))
        return try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]),
                                  defaults: defaults)
    }

    private func push(_ env: AppEnvironment) throws -> Routine {
        try #require(try env.routines.all().first { $0.name == "Push + Arms" })
    }

    @Test func theOtherDaysOfAWorkout() throws {
        let env = try makeEnv(), push = try push(env)
        #expect(try env.otherDays(of: push.id, besides: 6) == [1])
        #expect(try env.otherDays(of: push.id, besides: 2) == [1, 6])
    }

    @Test func savingForEveryDayEditsTheWorkout() throws {
        let env = try makeEnv(), push = try push(env)
        let edited = push.with(exercises: Array(push.exercises.dropFirst()))
        let saved = try env.saveWorkout(edited)
        #expect(saved.id == push.id)
        #expect(try env.routines.routine(push.id)?.exercises.count == push.exercises.count - 1)
        #expect(try env.routines.schedule().days[1] == push.id)
    }

    @Test func savingForOneDayPutsACopyOnThatDayOnly() throws {
        let env = try makeEnv(), push = try push(env)
        let edited = push.with(exercises: Array(push.exercises.dropFirst()))
        let copy = try env.saveWorkout(edited, onlyOn: 1)
        let schedule = try env.routines.schedule()
        #expect(schedule.days[1] == copy.id)
        #expect(schedule.days[6] == push.id)
        #expect(try env.routines.routine(push.id)?.exercises.count == push.exercises.count, "Saturday's is untouched")
        #expect(try env.routines.routine(copy.id)?.exercises.count == push.exercises.count - 1)
    }

    @Test func everyWeekdayTrainsTheNewPick() throws {
        let env = try makeEnv(), push = try push(env)
        try env.schedule(every: 2, push.id)
        #expect(try env.routines.schedule().days[2] == push.id)
        try env.schedule(every: 2, nil)
        #expect(try env.routines.schedule().days[2] == nil)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/WeekPlanTests`
Expected: the build fails with "cannot find 'WeekPlan' in scope".

- [ ] **Step 3: Write the helpers**

Create `ios/GymRollins/Features/Plan/WeekPlan.swift`:

```swift
import Foundation
import GymCore
import GymData

/// The week as the plan (owner, 2026-11-10): day names (ISO weekday 1 = Monday … 7 = Sunday), the days a workout is
/// on, a day row's exercise line, and the copy that lets one day change on its own.
enum WeekPlan {
    /// "Monday" for 1 … "Sunday" for 7.
    static func dayName(_ weekday: Int, calendar: Calendar = .current) -> String {
        calendar.standaloneWeekdaySymbols[weekday % 7]
    }

    /// "Mon" for 1 … "Sun" for 7.
    static func shortDayName(_ weekday: Int, calendar: Calendar = .current) -> String {
        calendar.shortStandaloneWeekdaySymbols[weekday % 7]
    }

    /// "Monday and Saturday", Monday first, in the calendar's language.
    static func dayList(_ weekdays: [Int], calendar: Calendar = .current) -> String {
        let formatter = ListFormatter()
        formatter.locale = calendar.locale ?? .current
        return formatter.string(from: weekdays.sorted().map { dayName($0, calendar: calendar) }) ?? ""
    }

    /// The days `routineId` is on, Monday first.
    static func weekdays(of routineId: UUID, in schedule: WeekSchedule) -> [Int] {
        schedule.days.filter { $0.value == routineId }.map(\.key).sorted()
    }

    /// A day row's exercises: "Bench Press · Dips · Curl +2".
    static func exerciseLine(_ names: [String]) -> String {
        let shown = names.prefix(3)
        let more = names.count - shown.count
        return shown.joined(separator: " \u{00B7} ") + (more > 0 ? " +\(more)" : "")
    }

    /// `routine` for one day only: a new workout with new ids (an item id belongs to one workout), named
    /// "Push + Arms (Mon)" within the name limit.
    static func copy(of routine: Routine, for weekday: Int, calendar: Calendar = .current) -> Routine {
        let suffix = " (\(shortDayName(weekday, calendar: calendar)))"
        let name = String(routine.name.prefix(DomainLimits.routineNameMax - suffix.count)) + suffix
        let items = routine.exercises.map { item in
            RoutineExercise(exerciseId: item.exerciseId, sets: item.sets, reps: item.reps, repsMin: item.repsMin,
                            sec: item.sec, weightKg: item.weightKg, mode: item.mode, policy: item.policy,
                            incKg: item.incKg, supersetGroup: item.supersetGroup, weightSetAt: item.weightSetAt)
        }
        return Routine(name: name, emoji: routine.emoji, policy: routine.policy, exercises: items)
    }
}
```

Create `ios/GymRollins/App/AppEnvironment+WeekPlan.swift`:

```swift
import Foundation
import GymCore
import GymData

/// Changes to the week (owner, 2026-11-10), shared by My Plan's day editor and Today's Switch and Save Changes.
extension AppEnvironment {
    /// The days `routineId` is on besides `weekday`, Monday first: the days a change to it from that day also reaches.
    func otherDays(of routineId: UUID, besides weekday: Int) throws -> [Int] {
        WeekPlan.weekdays(of: routineId, in: try routines.schedule()).filter { $0 != weekday }
    }

    /// Saves an edited workout for every day it's on, or (`onlyOn`) as a copy that takes over that one weekday.
    /// Returns the workout that was saved. Throws `GymDataError.invalidInput` for a name or size the server rejects.
    @discardableResult
    func saveWorkout(_ routine: Routine, onlyOn weekday: Int? = nil) throws -> Routine {
        guard let weekday else {
            try routines.upsert(routine)
            planChanged()
            return routine
        }
        let copy = WeekPlan.copy(of: routine, for: weekday)
        try routines.upsert(copy)
        try routines.setSchedule(weekday: weekday, routineId: copy.id)
        planChanged()
        return copy
    }

    /// Every `weekday` trains `routineId` from now on (nil: a rest day).
    func schedule(every weekday: Int, _ routineId: UUID?) throws {
        try routines.setSchedule(weekday: weekday, routineId: routineId)
        planChanged()
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/WeekPlanTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add ios/GymRollins/Features/Plan/WeekPlan.swift ios/GymRollins/App/AppEnvironment+WeekPlan.swift \
  ios/GymRollinsTests/WeekPlanTests.swift
git commit -m "feat(ios): the week's day names, a workout's other days, and a one-day copy of a workout"
```

---

### Task 4: Today edits a later day for that date only

**Files:**
- Modify: `ios/GymRollins/Features/Today/TodayView.swift`
- Modify: `ios/GymRollins/Features/Today/TodayDay.swift` (`DayPreview`)
- Modify: `ios/GymRollins/Features/Workout/LoggingView.swift:13, 376-382`
- Create: `ios/GymRollins/Features/Today/TodayGymNote.swift`
- Delete: `ios/GymRollins/Features/Today/TodayDayPreviewView.swift`, `ios/GymRollins/App/AppEnvironment+DayPreview.swift`, `ios/GymRollinsTests/DayPreviewEnvironmentTests.swift`
- Test: `ios/GymRollinsTests/TodayDayTests.swift`, `ios/GymRollinsUITests/TodayDaysUITests.swift`

- [ ] **Step 1: Write the failing tests**

In `ios/GymRollinsTests/TodayDayTests.swift`, replace the last two tests (`aRestDayModelSaysRest` and `anAgentsChangeIsSaidInTheSummary`) with:

```swift
    private func model(_ plan: TodayPlan) -> TodayModel {
        TodayModel.make(plan: plan, profile: Profile(), library: ExerciseLibrary(exercises: []), history: { _ in [] })
    }

    @Test func aLaterRestDaySaysRest() {
        let rest = TodayPlan(day: "2026-09-27", kind: .empty, base: nil, exercises: [], edited: false)
        let model = DayPreview.laterDay(model(rest), plan: rest, changed: false)
        #expect(model.title == "Rest day")
        #expect(model.summary == "Recover and eat well")
        #expect(model.rows.isEmpty)
        #expect(DayPreview.laterDay(model(rest), plan: rest, changed: true).summary == "Changed for this day")
    }

    @Test func aChangedLaterDaySaysSoInsteadOfEditedForToday() {
        let bench = Routine(name: "Push", exercises: [RoutineExercise(exerciseId: "0025", sets: 3, reps: 8),
                                                      RoutineExercise(exerciseId: "0027", sets: 3, reps: 8)])
        let edited = TodayPlan.make(scheduled: bench, routines: [bench], lastDone: [:], day: "2026-09-28")
            .deleting(bench.exercises[0].id)
        let changed = DayPreview.laterDay(model(edited), plan: edited, changed: true)
        #expect(changed.title == "Push")
        #expect(changed.summary == "1 exercise \u{00B7} changed for this day")
        let planned = TodayPlan.make(scheduled: bench, routines: [bench], lastDone: [:], day: "2026-09-28")
        #expect(DayPreview.laterDay(model(planned), plan: planned, changed: false).summary == "2 exercises")
    }
```

In `ios/GymRollinsUITests/TodayDaysUITests.swift`:
- Change the class comment to "Today's later days (owner, 2026-11-10): swipe left for the next day, tap the date for a calendar, Back to today returns. A later day is changed for that date only."
- In `testSwitchingShowsLaterDaysAndBackToTodayReturns`, replace `XCTAssertFalse(app.buttons["today.switch"].exists)` with `XCTAssertTrue(app.buttons["today.switch"].exists, "a later day can be switched")`.
- Add this test:

```swift
    /// Monday loses Bench Press for that date only: today keeps it, Monday says so, and Reset this day brings it back.
    func testALaterDayIsChangedForThatDateOnly() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        app.scrollViews.firstMatch.swipeLeft()
        app.scrollViews.firstMatch.swipeLeft()
        waitForLabel(title(app), "Monday")
        XCTAssertFalse(app.buttons["today.start"].exists, "a later day can't be started")
        let bench = app.descendants(matching: .any)["today.row.0025"]
        XCTAssertTrue(bench.waitForExistence(timeout: 5))
        app.buttons["today.row.menu.0025"].tap()
        let delete = app.buttons["Delete from Workout"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(bench.waitForNonExistence(timeout: 5))
        waitForLabel(app.staticTexts["today.summary"].firstMatch, "changed for this day", contains: true)

        app.buttons["today.backToToday"].tapCenter()
        waitForLabel(title(app), "Today")
        XCTAssertTrue(bench.waitForExistence(timeout: 5), "today's Push + Arms still has it")

        app.scrollViews.firstMatch.swipeLeft()
        app.scrollViews.firstMatch.swipeLeft()
        waitForLabel(title(app), "Monday")
        XCTAssertFalse(bench.exists, "Monday kept its change")
        let reset = app.buttons["today.resetDay"]
        app.scrollToHittable(reset)
        reset.tap()
        XCTAssertTrue(bench.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["today.summary"].firstMatch.label.contains("changed"))
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/TodayDayTests`
Expected: the build fails with "type 'DayPreview' has no member 'laterDay'".

- [ ] **Step 3: The later day's model**

In `ios/GymRollins/Features/Today/TodayDay.swift`:
- Change `DayPreview`'s comment to "What a later day trains, as Today shows it: an agent's one-day change for that date (`PlannedSwitchStore`) wins over the week schedule, under the rules Today applies on the day (`takePlannedSwitch`). Nil is a rest day." (Only "previews" becomes "shows".)
- Replace `DayPreview.model(plan:profile:library:history:gym:)` with:

```swift
    /// A later day's model, made like today's (`TodayModel.make`): a rest day reads "Rest day", and a date the owner
    /// or an agent changed says "changed for this day" (never "edited for today").
    static func laterDay(_ model: TodayModel, plan: TodayPlan, changed: Bool) -> TodayModel {
        if plan.kind == .empty && plan.exercises.isEmpty {
            return TodayModel(routineId: nil, title: "Rest day",
                              summary: changed ? "Changed for this day" : "Recover and eat well", rows: [])
        }
        let count = model.rows.count == 1 ? "1 exercise" : "\(model.rows.count) exercises"
        return TodayModel(routineId: model.routineId, title: model.title,
                          summary: changed ? "\(count) \u{00B7} changed for this day" : count, rows: model.rows,
                          gymNote: model.gymNote)
    }
```

- [ ] **Step 4: The exercise screen can't start a later day**

In `ios/GymRollins/Features/Workout/LoggingView.swift`, add after the `startWorkout` property:

```swift
    /// Plan mode: false on a later day (it can be edited, not started).
    var canStart = true
```

In `bottomBar(_:)`, change `case .plan:` to `case .plan where canStart:` and add `case .plan: EmptyView()` after that case.

- [ ] **Step 5: Today shows any day with the same controls**

Move `TodayGymNote` from `TodayDayPreviewView.swift` into a new `ios/GymRollins/Features/Today/TodayGymNote.swift`. Copy it verbatim and add `import SwiftUI` at the top. Then delete `TodayDayPreviewView.swift`, `AppEnvironment+DayPreview.swift` and `ios/GymRollinsTests/DayPreviewEnvironmentTests.swift`. `LaterDayEnvironmentTests` covers what those tests did.

In `ios/GymRollins/Features/Today/TodayView.swift`:

1. Delete `@State private var currentRoutine: Routine?`. In `reload()`, `scheduledRoutine` is set directly.
2. Replace the comment on `day` with "The day shown: today, or a later day edited for that date only (owner, 2026-11-10)." Then add:

```swift
    /// The later day shown was changed by the owner or an agent ("changed for this day", Reset this day).
    @State private var dayChanged = false
```

3. In `body`, replace the `if day.isToday { todayContent } else { TodayDayPreviewView(…) }` block with `dayContent`.
4. Change the exercise screen destination to `LoggingView(model: .plan(editor, itemId: itemId), startWorkout: start(from:), canStart: day.isToday)`.
5. Replace `.task(id: env.planRevision) { reload() }` with:

```swift
            .task(id: ReloadKey(day: day, plan: env.planRevision, gym: env.gymRevision, unit: env.profile.unit)) {
                reload()
            }
```

Add this nested type before `body`:

```swift
    /// Today reloads when the day moves, the plan changes (My Plan, a sync, an agent's change), the gym or its
    /// equipment changes, or the unit is switched in Settings.
    private struct ReloadKey: Equatable {
        let day: TodayDay
        let plan: Int
        let gym: Int
        let unit: WeightUnit
    }
```

6. Replace `todayContent` with:

```swift
    /// The day's content: its title, plan, rows and the editing controls (today's status lines on today only).
    @ViewBuilder
    private var dayContent: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                DisplayTitle(text: day.title(now: env.now()), size: 48)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .accessibilityIdentifier("today.title")
                Text("\(model.title) \u{00B7} \(model.summary)")
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("today.summary")
            }
            Spacer(minLength: 8)
            if env.session == nil && (env.hasAnyRoutine || plan?.kind == .built) { switchButton }
        }
        if day.isToday { todayStatus }
        if let loadError { Text(loadError).foregroundStyle(Theme.destructive) }
        if let session = env.session { resumeBanner(session) }
        if day.isToday && !env.hasAnyRoutine && model.rows.isEmpty { emptyPlanState }
        if let note = model.gymNote { TodayGymNote(text: note) }
        ForEach(model.rows) { row in exerciseRow(row) }
        if env.session == nil {
            addExerciseRow
            if plan?.canSaveToRoutine == true { saveToRoutineButton }
            if !day.isToday && dayChanged { resetDayButton }
            if let plan, !plan.exercises.isEmpty {
                ShareWorkoutButton(identifier: "today.share") { plan.shareSources }
            }
        }
    }

    /// Today only: the gym, the injury-note check-in, an agent's proposal, sync and recovery.
    @ViewBuilder
    private var todayStatus: some View {
        if env.session == nil { GymChipRow(gym: currentGym) }
        LimitsReminder(openPlan: { showPlan = true })
        if let pendingProposal { proposalChip(pendingProposal) }
        SyncStatusBanner()
        RecoveryCard(identifier: "today.recovery")
    }

    /// A later day back to the week: the owner's change and an agent's switch for that date go.
    private var resetDayButton: some View {
        SecondaryGlassButton(title: "Reset this day", identifier: "today.resetDay") {
            guard let plan else { return }
            env.resetLaterDay(plan.day)
            reload()
        }
    }
```

7. After `private var planStore`, add:

```swift
    /// Where the day's changes are kept: today's stored plan, or the later day's (that date only).
    private var dayStore: any TodayPlanSaving {
        day.isToday ? planStore : env.laterDaySaver(on: day.date(now: env.now()), scheduled: scheduledRoutine?.id)
    }
```

8. Replace `reload()` with:

```swift
    private func reload() {
        // The plan may have changed underneath (My Plan, sync, a new day): the exercise screen shows the new plan
        // (and closes if its exercise is gone).
        historyCache = [:]
        let env = self.env
        editor.isLocked = env.session != nil
        let gym = env.todayGymContext()
        gymContext = gym
        currentGym = env.currentGym
        do {
            let plan: TodayPlan
            if day.isToday {
                let today = try env.todaysPlan()
                plan = today.plan
                scheduledRoutine = today.scheduled
                pendingProposal = env.pendingProposals().first?.id
            } else {
                let later = try env.laterDay(on: day.date(now: env.now()))
                plan = later.plan
                scheduledRoutine = later.scheduled
            }
            editor.configure(store: dayStore, defaultRestSec: env.profile.restSec) { item, plan in
                SessionPlanner.entry(for: item, policy: item.policy ?? plan.base?.policy ?? .double, profile: env.profile,
                                     exercise: env.library.exercise(item.exerciseId),
                                     history: (try? env.workouts.history(exerciseId: item.exerciseId, limit: 5)) ?? [],
                                     autoWarmups: WarmupPreferences.autoWarmupsEnabled(env.defaults),
                                     loads: gym?.preferring(plan.builtListings).loads(for: item.exerciseId)).sets
            }
            editor.load(plan)
            gymContext = gym?.preferring(plan.builtListings)
            refreshModel()
            loadError = nil
        } catch {
            AppEnvironment.log.error("Today load failed: \(error.localizedDescription, privacy: .public)")
            loadError = day.isToday ? "Couldn't load today's plan." : "Couldn't load this day's plan."
        }
    }
```

9. In `refreshModel()`, replace the final `model = TodayModel.make(…)` statement with:

```swift
        let made = TodayModel.make(plan: plan, profile: env.profile, library: env.library,
                                   history: { cache[$0] ?? [] }, gym: gym, loads: { gym?.loads(for: $0) })
        if day.isToday {
            model = made
        } else {
            dayChanged = env.isLaterDayChanged(plan.day)
            model = DayPreview.laterDay(made, plan: plan, changed: dayChanged)
        }
```

10. Change `apply`'s comment to "Applies a change for the day shown and keeps it for that day."
11. Replace `choose(_:)` with the version below. Task 5 replaces it again.

```swift
    /// Switch for the day shown. Picking the day's own workout (on a later rest day, Rest) is the plan as scheduled.
    private func choose(_ routine: Routine?) {
        showSwitch = false
        guard let current = plan else { return }
        if routine?.id == scheduledRoutine?.id && (routine != nil || !day.isToday) {
            dayStore.clear()
            reload()
        } else {
            apply(current.switched(to: routine).adapted(by: env.gymAdapter()))
        }
    }
```

12. In `saveToRoutineButton`, on a later day the saved workout replaces the day's change. Replace the `do` block with the code below. Task 5 replaces this too.

```swift
            do {
                try env.routines.upsert(routine)
                if day.isToday { apply(plan.savedToRoutine(at: env.now())) } else { dayStore.clear() }
                env.planChanged()
            } catch GymDataError.invalidInput(let message) {
```

Also change the switch button's hint to `"Pick another workout for this day"`.

- [ ] **Step 6: Run the tests**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/TodayDayTests -only-testing:GymRollinsTests/LaterDayEnvironmentTests -only-testing:GymRollinsUITests/TodayDaysUITests -only-testing:GymRollinsUITests/TodayFlexUITests -only-testing:GymRollinsUITests/TodayPlanScreenUITests`
Expected: all pass. `TodayFlexUITests` and `TodayPlanScreenUITests` are unchanged here: today behaves as before.

- [ ] **Step 7: Commit**

```bash
git add -A ios/GymRollins/Features/Today ios/GymRollins/Features/Workout/LoggingView.swift \
  ios/GymRollins/App/AppEnvironment+DayPreview.swift ios/GymRollinsTests/TodayDayTests.swift \
  ios/GymRollinsTests/DayPreviewEnvironmentTests.swift ios/GymRollinsUITests/TodayDaysUITests.swift
git commit -m "feat(ios): a later day on Today is edited like today, for that date only, with Reset this day"
```

---

### Task 5: Switch and Save Changes ask where a change goes

**Files:**
- Create: `ios/GymRollins/Features/Today/TodaySwitchSheet.swift`
- Modify: `ios/GymRollins/Features/Today/TodayView.swift`
- Test: `ios/GymRollinsUITests/TodayScopeUITests.swift`
- Modify tests: `ios/GymRollinsUITests/TodayFlexUITests.swift`, `ios/GymRollinsUITests/TodayPlanScreenUITests.swift`

- [ ] **Step 1: Write the failing UI tests**

Create `ios/GymRollinsUITests/TodayScopeUITests.swift`:

```swift
import XCTest

/// Switch and Save Changes ask where a change goes (owner, 2026-11-10): this date only, or every week. The seed's today
/// is Saturday 26 Sep; Push + Arms is on Monday and Saturday, Pull on Wednesday.
final class TodayScopeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func summary(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["today.summary"].firstMatch }

    private func waitForSummary(_ app: XCUIApplication, containing text: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: summary(app))],
                                      timeout: 5)
        XCTAssertEqual(result, .completed, "summary was '\(summary(app).label)'", file: file, line: line)
    }

    private func onlyButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Only '")).firstMatch
    }

    private func openMonday(_ app: XCUIApplication) {
        app.scrollViews.firstMatch.swipeLeft()
        app.scrollViews.firstMatch.swipeLeft()
        waitForSummary(app, containing: "Push + Arms")
    }

    private func mondayRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["today.backToToday"].tapCenter()
        app.buttons["today.myPlan"].tap()
        let monday = app.buttons["plan.day.1"]
        XCTAssertTrue(monday.waitForExistence(timeout: 5))
        return monday
    }

    func testSwitchingALaterDayOnlyChangesThatDate() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        openMonday(app)
        app.buttons["today.switch"].tap()
        let pull = app.buttons["today.switch.routine.Pull + Shoulders + Triceps"]
        XCTAssertTrue(pull.waitForExistence(timeout: 5))
        pull.tap()
        XCTAssertTrue(onlyButton(app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Every Monday"].exists)
        onlyButton(app).tap()
        waitForSummary(app, containing: "Pull + Shoulders + Triceps")
        waitForSummary(app, containing: "changed for this day")

        let monday = mondayRow(app)
        XCTAssertTrue(monday.label.contains("Push + Arms"), "the week is unchanged: \(monday.label)")
    }

    func testSwitchingEveryWeekChangesTheWeek() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        openMonday(app)
        app.buttons["today.switch"].tap()
        let pull = app.buttons["today.switch.routine.Pull + Shoulders + Triceps"]
        XCTAssertTrue(pull.waitForExistence(timeout: 5))
        pull.tap()
        let every = app.buttons["Every Monday"]
        XCTAssertTrue(every.waitForExistence(timeout: 5))
        every.tap()
        waitForSummary(app, containing: "Pull + Shoulders + Triceps")
        XCTAssertFalse(summary(app).label.contains("changed for this day"), summary(app).label)

        let monday = mondayRow(app)
        XCTAssertTrue(monday.label.contains("Pull"), monday.label)
    }

    func testSaveChangesOnlyThisDayMakesItsOwnCopy() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        app.buttons["today.row.menu.0025"].tap()
        let delete = app.buttons["Delete from Workout"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let save = app.buttons["today.saveToRoutine"]
        app.scrollToHittable(save)
        save.tap()
        let only = app.buttons["Only Saturday"]
        XCTAssertTrue(only.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Change Monday and Saturday"].exists)
        only.tap()
        waitForSummary(app, containing: "Push + Arms (Sat)")

        app.buttons["today.myPlan"].tap()
        let monday = app.buttons["plan.day.1"], saturday = app.buttons["plan.day.6"]
        XCTAssertTrue(monday.waitForExistence(timeout: 5))
        XCTAssertFalse(monday.label.contains("(Sat)"), monday.label)
        XCTAssertTrue(saturday.label.contains("Push + Arms (Sat)"), saturday.label)
    }

    /// Monday switched to Pull (on Wednesday only): Save Changes writes into Pull without asking, and Monday still trains
    /// Pull, without the deleted exercise.
    func testSaveChangesOnASwitchedLaterDayKeepsTheSwitch() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        openMonday(app)
        app.buttons["today.switch"].tap()
        let pull = app.buttons["today.switch.routine.Pull + Shoulders + Triceps"]
        XCTAssertTrue(pull.waitForExistence(timeout: 5))
        pull.tap()
        XCTAssertTrue(onlyButton(app).waitForExistence(timeout: 5))
        onlyButton(app).tap()
        waitForSummary(app, containing: "Pull + Shoulders + Triceps")
        let menu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'today.row.menu.'")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let exerciseId = String(menu.identifier.dropFirst("today.row.menu.".count))
        menu.tap()
        let delete = app.buttons["Delete from Workout"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let save = app.buttons["today.saveToRoutine"]
        app.scrollToHittable(save)
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5), "saved without a question")
        waitForSummary(app, containing: "Pull + Shoulders + Triceps")
        XCTAssertFalse(app.descendants(matching: .any)["today.row.\(exerciseId)"].exists)
    }
}
```

Three of these tests read the week rows, which Task 6 builds. Before it, `plan.day.N` is the week grid's `Menu`, labelled with the short name ("Push"). In this task, run only `testSaveChangesOnASwitchedLaterDayKeepsTheSwitch` from this suite; run the whole suite in Task 6. The updated existing tests below carry the rest of the check.

Update the existing tests for the new question:
- `ios/GymRollinsUITests/TodayFlexUITests.swift`, in `testSwitchToAnEmptyWorkoutAndAddAnExercise` and `testSwitchedPlanDoesNotLeakIntoAFreshLaunch`: after `empty.tap()`, add:

```swift
        let only = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Only '")).firstMatch
        XCTAssertTrue(only.waitForExistence(timeout: 5))
        only.tap()
```

- `TodayFlexUITests.testRowMenuDeletesForTodayAndSavesToTheRoutine` and `ios/GymRollinsUITests/TodayPlanScreenUITests.swift`, `testSaveChangesWritesThePlanScreenEditsIntoTheRoutine`: after `save.tap()`, add:

```swift
        let both = app.buttons["Change Monday and Saturday"] // Push + Arms is on both days
        XCTAssertTrue(both.waitForExistence(timeout: 5))
        both.tap()
```

- [ ] **Step 2: Run them to see them fail**

Run: `scripts/ios-test.sh -only-testing:GymRollinsUITests/TodayFlexUITests`
Expected: the switch and save tests fail waiting for the "Only …" and "Change Monday and Saturday" buttons.

- [ ] **Step 3: The Switch sheet**

Create `ios/GymRollins/Features/Today/TodaySwitchSheet.swift`:

```swift
import GymCore
import GymData
import SwiftUI

/// Today's Switch, on today or a later day: the saved workouts, and an empty workout (Rest on a later day). Picking the
/// day's own workout is the plan as scheduled; any other pick asks where it goes (owner, 2026-11-10): only this date,
/// or every week on this weekday. A paused workout can't go on the week, so it is this date only.
struct TodaySwitchSheet: View {
    enum Scope { case thisDay, everyWeek }

    /// A pick waiting for its scope (no workout: an empty workout, or Rest).
    struct Pick: Identifiable {
        let routine: Routine?
        var id: UUID? { routine?.id }
    }

    let routines: [Routine]
    /// The workout the day shows now (checkmarked).
    let current: UUID?
    /// The workout the week has on this day (nil: a rest day).
    let scheduled: UUID?
    let date: Date
    let isToday: Bool
    let onAsScheduled: () -> Void
    let onSwitch: (Routine?, Scope) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var asking: Pick?

    var body: some View {
        NavigationStack {
            List {
                Section("Saved workouts") {
                    ForEach(routines) { routine in
                        Button { pick(routine) } label: { row(routine) }
                            .disabled(routine.exercises.isEmpty)
                            .accessibilityIdentifier("today.switch.routine.\(routine.name)")
                    }
                }
                Section {
                    Button(isToday ? "Empty Workout" : "Rest") { pick(nil) }
                        .accessibilityIdentifier("today.switch.empty")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Switch Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .confirmationDialog(title, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                                titleVisibility: .visible, presenting: asking) { pick in
                Button("Only \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))") {
                    finish(pick.routine, .thisDay)
                }
                if pick.routine?.paused != true {
                    Button(pick.routine == nil && isToday ? "Rest every \(weekdayName)" : "Every \(weekdayName)") {
                        finish(pick.routine, .everyWeek)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ routine: Routine) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.name).foregroundStyle(Theme.textPrimary)
                Text(routine.exercises.count == 1 ? "1 exercise" : "\(routine.exercises.count) exercises")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if routine.id == current {
                Image(systemName: "checkmark").foregroundStyle(Theme.primaryFill)
            }
        }
    }

    private var weekdayName: String { WeekPlan.dayName(WeekSchedule.isoWeekday(date)) }

    private var title: String {
        guard let asking else { return "" }
        return "Switch to \(asking.routine?.name ?? (isToday ? "an empty workout" : "rest"))"
    }

    private func pick(_ routine: Routine?) {
        // The day's own workout (on a later rest day, Rest) is the plan as scheduled: nothing to ask.
        if routine?.id == scheduled && (routine != nil || !isToday) {
            dismiss()
            onAsScheduled()
        } else {
            asking = Pick(routine: routine)
        }
    }

    private func finish(_ routine: Routine?, _ scope: Scope) {
        asking = nil
        dismiss()
        onSwitch(routine, scope)
    }
}
```

- [ ] **Step 4: Today uses it, and Save Changes asks about shared days**

In `ios/GymRollins/Features/Today/TodayView.swift`:

1. Add this state:

```swift
    /// Save Changes on a workout that is on other days too: those days, while the question is open.
    @State private var savingShared: [Int] = []
```

2. Replace `.sheet(isPresented: $showSwitch) { switchSheet }` with:

```swift
            .sheet(isPresented: $showSwitch) {
                TodaySwitchSheet(routines: (try? env.routines.all()) ?? [], current: plan?.base?.id,
                                 scheduled: scheduledRoutine?.id, date: day.date(now: env.now()), isToday: day.isToday,
                                 onAsScheduled: { dayStore.clear(); reload() }, onSwitch: switchDay)
            }
```

3. Delete `switchSheet` and `choose(_:)`, and add:

```swift
    private var weekday: Int { WeekSchedule.isoWeekday(day.date(now: env.now())) }

    /// Switch's pick: this date only, or every week on its weekday (the day then follows the new week).
    private func switchDay(to routine: Routine?, scope: TodaySwitchSheet.Scope) {
        guard let current = plan else { return }
        switch scope {
        case .thisDay:
            apply(current.switched(to: routine).adapted(by: env.gymAdapter()))
        case .everyWeek:
            do {
                try env.schedule(every: weekday, routine?.id)
                dayStore.clear()
            } catch {
                AppEnvironment.log.error("Switch every week failed: \(error.localizedDescription, privacy: .public)")
                loadError = "Couldn't change your week. Try again."
            }
        }
    }
```

4. Replace `saveToRoutineButton` with:

```swift
    private var saveToRoutineButton: some View {
        SecondaryGlassButton(title: "Save Changes to \(plan?.title ?? "Workout")", identifier: "today.saveToRoutine") {
            guard let base = plan?.base else { return }
            // The day's own workout asks when it's on other days too; a switched one is saved for its days.
            let others = base.id == scheduledRoutine?.id ? ((try? env.otherDays(of: base.id, besides: weekday)) ?? []) : []
            if others.isEmpty { saveChanges(onlyOn: nil) } else { savingShared = others }
        }
        .confirmationDialog("\(plan?.title ?? "This workout") is also on \(WeekPlan.dayList(savingShared))",
                            isPresented: Binding(get: { !savingShared.isEmpty }, set: { if !$0 { savingShared = [] } }),
                            titleVisibility: .visible) {
            Button("Change \(WeekPlan.dayList([weekday] + savingShared))") { saveChanges(onlyOn: nil) }
            Button("Only \(WeekPlan.dayName(weekday))") { saveChanges(onlyOn: weekday) }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Writes the day's edits into its workout, for every day it's on, or (`onlyOn`) into a copy that takes over this
    /// weekday (the day then shows the copy). Today keeps its sets for the workout about to start; a later day follows
    /// the saved workout again (a date switched to it stays switched to it).
    private func saveChanges(onlyOn weekday: Int?) {
        savingShared = []
        guard let plan, let routine = plan.routineWithEdits(at: env.now()) else { return }
        do {
            if let weekday {
                try env.saveWorkout(routine, onlyOn: weekday)
                dayStore.clear()
            } else {
                try env.routines.upsert(routine)
                if day.isToday {
                    apply(plan.savedToRoutine(at: env.now()))
                } else if plan.kind == .switched {
                    apply(plan.switched(to: routine).adapted(by: env.gymAdapter())) // still this date's workout
                } else {
                    dayStore.clear()
                }
                env.planChanged()
            }
        } catch GymDataError.invalidInput(let message) {
            loadError = message
        } catch {
            AppEnvironment.log.error("Save to routine failed: \(error.localizedDescription, privacy: .public)")
            loadError = "Couldn't save the workout. Try again."
        }
    }
```

- [ ] **Step 5: Run the tests**

Run: `scripts/ios-test.sh -only-testing:GymRollinsUITests/TodayScopeUITests/testSaveChangesOnASwitchedLaterDayKeepsTheSwitch -only-testing:GymRollinsUITests/TodayFlexUITests -only-testing:GymRollinsUITests/TodayPlanScreenUITests -only-testing:GymRollinsUITests/TodayDaysUITests -only-testing:GymRollinsUITests/SharedWorkoutUITests`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add ios/GymRollins/Features/Today/TodaySwitchSheet.swift ios/GymRollins/Features/Today/TodayView.swift \
  ios/GymRollinsUITests/TodayScopeUITests.swift ios/GymRollinsUITests/TodayFlexUITests.swift \
  ios/GymRollinsUITests/TodayPlanScreenUITests.swift
git commit -m "feat(ios): Switch asks this date or every week, and Save Changes asks about the workout's other days"
```

---

### Task 6: My Plan is the week

**Files:**
- Create: `ios/GymRollins/Features/Plan/RoutineExercisesSection.swift`
- Create: `ios/GymRollins/Features/Plan/DayWorkoutEditView.swift`
- Create: `ios/GymRollins/Features/Plan/SavedWorkoutsView.swift`
- Modify: `ios/GymRollins/Features/Plan/RoutineEditView.swift`, `ios/GymRollins/Features/Plan/PlanView.swift`
- Test: `ios/GymRollinsUITests/PlanUITests.swift`
- Modify tests: `ios/GymRollinsUITests/FlowCoverageUITests.swift:153-177`, `ios/GymRollinsUITests/LimitsCheckInUITests.swift:115-116`, `ios/GymRollinsUITests/ProposalUITests.swift:95-101`

- [ ] **Step 1: Write the failing UI tests**

Replace `ios/GymRollinsUITests/PlanUITests.swift` with:

```swift
import XCTest

/// My Plan is the week (owner, 2026-11-10): a row per day, tap a day to change it, and Saved workouts for the rest.
/// The seed: Push + Arms on Monday and Saturday (today), Pull on Wednesday, Upper weak points on Friday, Legs paused.
final class PlanUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication.launchReady { $0.buttons["today.myPlan"] }
        app.buttons["today.myPlan"].tap()
        XCTAssertTrue(app.buttons["plan.day.1"].waitForExistence(timeout: 5))
    }

    private func day(_ weekday: Int) -> XCUIElement { app.buttons["plan.day.\(weekday)"] }

    func testTheWeekShowsEachDaysWorkout() {
        XCTAssertTrue(day(1).label.contains("Monday"), day(1).label)
        XCTAssertTrue(day(1).label.contains("Push + Arms"), day(1).label)
        XCTAssertTrue(day(2).label.contains("Rest"), day(2).label)
        XCTAssertTrue(day(3).label.contains("Pull"), day(3).label)
        XCTAssertTrue(day(6).label.contains("Today"), day(6).label)
    }

    func testOnlyMondayGivesMondayItsOwnCopy() {
        day(1).tap()
        let sets = app.steppers["edit.sets.0025"]
        XCTAssertTrue(sets.waitForExistence(timeout: 5))
        sets.buttons["edit.sets.0025-Increment"].tap()
        app.buttons["edit.done"].tap()
        let only = app.buttons["Only Monday"]
        XCTAssertTrue(only.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Change Monday and Saturday"].exists)
        only.tap()
        XCTAssertTrue(day(1).waitForExistence(timeout: 5))
        let mondayCopy = NSPredicate(format: "label CONTAINS %@", "Push + Arms (Mon)")
        wait(for: [expectation(for: mondayCopy, evaluatedWith: day(1))], timeout: 5)
        XCTAssertFalse(day(6).label.contains("(Mon)"), day(6).label)
    }

    func testChangingBothDaysEditsTheWorkout() {
        day(1).tap()
        let sets = app.steppers["edit.sets.0025"]
        XCTAssertTrue(sets.waitForExistence(timeout: 5))
        sets.buttons["edit.sets.0025-Increment"].tap()
        app.buttons["edit.done"].tap()
        let both = app.buttons["Change Monday and Saturday"]
        XCTAssertTrue(both.waitForExistence(timeout: 5))
        both.tap()
        day(6).tap()
        XCTAssertTrue(app.staticTexts["4 sets"].waitForExistence(timeout: 5), "Saturday has the change too")
    }

    func testARestDayGetsASavedWorkout() {
        day(2).tap()
        let picker = app.buttons["day.workout"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Pull + Shoulders + Triceps"].tap()
        XCTAssertTrue(app.steppers.firstMatch.waitForExistence(timeout: 5), "its exercises show")
        app.buttons["edit.done"].tap()
        let pull = NSPredicate(format: "label CONTAINS %@", "Pull")
        wait(for: [expectation(for: pull, evaluatedWith: day(2))], timeout: 5)
    }

    func testSavedWorkoutsListsEveryWorkoutAndEditsOne() {
        let saved = app.buttons["plan.savedWorkouts"]
        app.scrollToHittable(saved)
        saved.tap()
        XCTAssertTrue(app.buttons["plan.routine.Push + Arms"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["plan.routine.Legs"].exists)
        XCTAssertTrue(app.staticTexts["Paused"].exists)

        app.buttons["plan.routine.Push + Arms"].tap()
        let sets = app.steppers["edit.sets.0025"]
        XCTAssertTrue(sets.waitForExistence(timeout: 5))
        // A Stepper with an explicit accessibilityIdentifier exposes its sub-buttons suffixed with that identifier.
        sets.buttons["edit.sets.0025-Increment"].tap()
        // The exercise List only realizes rows near the viewport, so "+ Add exercise" must be scrolled into view.
        let addExercise = app.buttons["edit.addExercise"]
        scrollUntilExists(addExercise)
        addExercise.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("chest dip")
        app.buttons["picker.row.0251"].tap()
        // While searching, .searchable hides the toolbar; Close ends the search so "picker.add" is reachable.
        app.buttons["Close"].tap()
        app.buttons["picker.add"].tap()
        let newRow = app.descendants(matching: .any)["edit.row.0251"]
        scrollUntilExists(newRow)
        XCTAssertTrue(newRow.exists)
        app.buttons["edit.done"].tap()
        app.buttons["plan.routine.Push + Arms"].tap()
        XCTAssertTrue(app.staticTexts["4 sets"].waitForExistence(timeout: 5))
    }

    /// Swipes up on the app to bring a lazily-realized List row into the accessibility tree.
    private func scrollUntilExists(_ element: XCUIElement, maxSwipes: Int = 12) {
        var attempts = 0
        while !element.exists && attempts < maxSwipes {
            app.swipeUp()
            attempts += 1
        }
    }
}
```

Update the tests that opened a routine straight from My Plan:
- `ios/GymRollinsUITests/FlowCoverageUITests.swift`:
  - After `app.buttons["today.myPlan"].tap()` (line 154), add `app.buttons["plan.savedWorkouts"].tap()`.
  - Replace `app.navigationBars.buttons.firstMatch.tap() // back to Today` with two taps: `app.navigationBars.buttons.firstMatch.tap() // back to My Plan` and `app.navigationBars.buttons.firstMatch.tap() // back to Today`.
- `ios/GymRollinsUITests/LimitsCheckInUITests.swift`: after `scrollAndTap(app, app.buttons["limits.openPlan"])`, add `scrollAndTap(app, app.buttons["plan.savedWorkouts"])`.
- `ios/GymRollinsUITests/ProposalUITests.swift`, lines 95–101. Check Saturday first, then open Saved workouts:

```swift
        // The routine was added, and the weekly schedule is untouched: Saturday doesn't become the home session.
        app.buttons["today.myPlan"].tap()
        let saturday = app.buttons["plan.day.6"]
        XCTAssertTrue(saturday.waitForExistence(timeout: 5))
        XCTAssertFalse(saturday.label.contains("Home"), saturday.label)
        app.buttons["plan.savedWorkouts"].tap()
        XCTAssertTrue(app.buttons["plan.routine.Home \u{00B7} KB Upper"].waitForExistence(timeout: 5))
```

- [ ] **Step 2: Run them to see them fail**

Run: `scripts/ios-test.sh -only-testing:GymRollinsUITests/PlanUITests`
Expected: `testTheWeekShowsEachDaysWorkout` fails, because the grid's label is the short name, not "Monday". The others fail waiting for `edit.sets.0025` or `plan.savedWorkouts`.

- [ ] **Step 3: One exercises section for both editors**

Create `ios/GymRollins/Features/Plan/RoutineExercisesSection.swift`. It moves `row`, `binding`, `weightBinding` and `replace` out of `RoutineEditView`, unchanged except that they write `items` through the binding.

```swift
import GymCore
import SwiftUI

/// A workout's exercises in an editor's list: sets, reps and weight steppers per row, reorder and delete, and
/// "+ Add exercise" (the parent shows the picker). Used by Saved workouts' editor and My Plan's day editor.
struct RoutineExercisesSection: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var items: [RoutineExercise]
    @Binding var showPicker: Bool

    var body: some View {
        Section("Exercises") {
            ForEach(items) { item in row(item) }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { items.remove(atOffsets: $0) }
            Button("+ Add exercise") { showPicker = true }
                .disabled(items.count >= DomainLimits.routineExercisesMax)
                .accessibilityIdentifier("edit.addExercise")
        }
    }

    private func row(_ item: RoutineExercise) -> some View {
        let ex = env.library.exercise(item.exerciseId)
        // The row identifier is placed on the name label rather than the enclosing VStack:
        // an accessibilityIdentifier applied to a container overrides (rather than merely
        // labels) every accessibility element nested inside it, which would otherwise stomp
        // the Steppers' own edit.sets/edit.reps/edit.weight identifiers below.
        return VStack(alignment: .leading, spacing: 6) {
            Text(DisplayName.of(ex?.name ?? item.exerciseId)).font(.headline)
                .accessibilityIdentifier("edit.row.\(item.exerciseId)")
            Stepper("\(item.sets) sets", value: binding(item, \.sets, 1...10))
                .accessibilityIdentifier("edit.sets.\(item.exerciseId)")
            Stepper("\(item.repsMin.map { "\($0)\u{2013}" } ?? "")\(item.reps) reps", value: binding(item, \.reps, 1...50))
                .accessibilityIdentifier("edit.reps.\(item.exerciseId)")
            Stepper(item.weightKg.map { WeightFormatter.format(kg: $0, unit: env.profile.unit) } ?? "Bodyweight",
                    value: weightBinding(item), step: 1)
                .accessibilityIdentifier("edit.weight.\(item.exerciseId)")
        }
    }

    /// Returns a binding that rebuilds the immutable RoutineExercise on change.
    private func binding(_ item: RoutineExercise, _ key: KeyPath<RoutineExercise, Int>,
                         _ range: ClosedRange<Int>) -> Binding<Int> {
        Binding(get: { item[keyPath: key] }, set: { newValue in
            let v = min(max(newValue, range.lowerBound), range.upperBound)
            replace(item, sets: key == \.sets ? v : item.sets, reps: key == \.reps ? v : item.reps, weightKg: item.weightKg)
        })
    }

    /// Weight stepper moves one loadable increment in the user's unit.
    private func weightBinding(_ item: RoutineExercise) -> Binding<Double> {
        let rounder = LoadRounding.rounder(for: env.library.exercise(item.exerciseId), profile: env.profile)
        let stepKg = UnitConverter.toKg(rounder.step, from: rounder.unit)
        return Binding(get: { (item.weightKg ?? 0) / stepKg }, set: { steps in
            let kg = max(0, rounder.nearest(steps.rounded() * stepKg))
            replace(item, sets: item.sets, reps: item.reps, weightKg: kg == 0 ? nil : kg)
        })
    }

    private func replace(_ item: RoutineExercise, sets: Int, reps: Int, weightKg: Double?) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let weightChanged = abs((weightKg ?? 0) - (item.weightKg ?? 0)) > 0.001
        items[index] = RoutineExercise(id: item.id, exerciseId: item.exerciseId, sets: sets, reps: reps,
                                       repsMin: item.repsMin.map { min($0, reps) }, sec: item.sec, weightKg: weightKg,
                                       mode: item.mode, policy: item.policy, incKg: item.incKg,
                                       supersetGroup: item.supersetGroup,
                                       weightSetAt: weightChanged ? env.now() : item.weightSetAt)
    }
}
```

Replace `ios/GymRollins/Features/Plan/RoutineEditView.swift` with:

```swift
import GymCore
import GymData
import SwiftUI

/// A saved workout, opened from Saved workouts: its name, Paused, and its exercises. A change here reaches every day
/// the workout is on; one day is changed on its own from My Plan's week (`DayWorkoutEditView`).
struct RoutineEditView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let routine: Routine
    @State private var name: String
    @State private var paused: Bool
    @State private var items: [RoutineExercise]
    @State private var showPicker = false
    @State private var error: String?

    init(routine: Routine) {
        self.routine = routine
        _name = State(initialValue: routine.name)
        _paused = State(initialValue: routine.paused)
        _items = State(initialValue: routine.exercises)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Workout name", text: $name).accessibilityIdentifier("edit.name")
                        .onChange(of: name) { _, new in
                            if new.count > DomainLimits.routineNameMax {
                                name = String(new.prefix(DomainLimits.routineNameMax))
                            }
                        }
                    Toggle("Paused", isOn: $paused)
                }
                RoutineExercisesSection(items: $items, showPicker: $showPicker)
                if let error {
                    Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("edit.error")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .environment(\.editMode, .constant(.active))
            .navigationTitle(name.isEmpty ? "Workout" : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save).buttonStyle(.glassProminent).tint(Theme.primaryButtonFill)
                        .accessibilityIdentifier("edit.done")
                }
            }
            .sheet(isPresented: $showPicker) {
                ExercisePickerView(excluded: Set(items.map(\.exerciseId))) { ids in
                    items += ids.compactMap { env.library.exercise($0) }
                        .map { RoutineDefaults.item(for: $0, profile: env.profile) }
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let edited = Routine(id: routine.id, name: trimmed, emoji: routine.emoji, policy: routine.policy,
                             paused: paused, exercises: items)
        if let violation = DomainLimits.routineViolation(edited) { error = violation; return }
        do {
            try env.routines.upsert(edited)
            env.planChanged()
            dismiss()
        } catch {
            AppEnvironment.log.error("Save routine failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save the workout. Try again."
        }
    }
}
```

- [ ] **Step 4: The day editor**

Create `ios/GymRollins/Features/Plan/DayWorkoutEditView.swift`:

```swift
import GymCore
import GymData
import SwiftUI

/// One day of the week (owner, 2026-11-10): which workout it trains (a saved one, a new one, or Rest) and that
/// workout's exercises. When the workout is on other days too and was changed, Done asks whether the change is for all
/// of them or this day only (a copy then takes over the day).
struct DayWorkoutEditView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let weekday: Int
    @State private var routines: [Routine] = []
    /// What the week had on this day when the editor opened (nil: Rest).
    @State private var originalId: UUID?
    /// The workout the day trains in this editor (nil: Rest), and whether it is new.
    @State private var picked: Routine?
    @State private var isNew = false
    @State private var name = ""
    @State private var items: [RoutineExercise] = []
    @State private var showPicker = false
    /// The other days the changed workout is on, while Done's question is open.
    @State private var sharedDays: [Int] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Menu { pickerItems } label: {
                        HStack {
                            Text("Workout").foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(picked == nil ? "Rest" : name).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .accessibilityIdentifier("day.workout")
                    if picked != nil {
                        TextField("Workout name", text: $name).accessibilityIdentifier("edit.name")
                            .onChange(of: name) { _, new in
                                if new.count > DomainLimits.routineNameMax {
                                    name = String(new.prefix(DomainLimits.routineNameMax))
                                }
                            }
                    }
                }
                if picked != nil { RoutineExercisesSection(items: $items, showPicker: $showPicker) }
                if let error {
                    Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("edit.error")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .environment(\.editMode, .constant(.active))
            .navigationTitle(WeekPlan.dayName(weekday))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done).buttonStyle(.glassProminent).tint(Theme.primaryButtonFill)
                        .accessibilityIdentifier("edit.done")
                }
            }
            .sheet(isPresented: $showPicker) {
                ExercisePickerView(excluded: Set(items.map(\.exerciseId))) { ids in
                    items += ids.compactMap { env.library.exercise($0) }
                        .map { RoutineDefaults.item(for: $0, profile: env.profile) }
                }
            }
            .confirmationDialog("\(name) is also on \(WeekPlan.dayList(sharedDays))",
                                isPresented: Binding(get: { !sharedDays.isEmpty }, set: { if !$0 { sharedDays = [] } }),
                                titleVisibility: .visible) {
                Button("Change \(WeekPlan.dayList([weekday] + sharedDays))") { save(onlyThisDay: false) }
                Button("Only \(WeekPlan.dayName(weekday))") { save(onlyThisDay: true) }
                Button("Cancel", role: .cancel) {}
            }
            .task { if !loaded { load() } }
        }
    }

    @ViewBuilder
    private var pickerItems: some View {
        Button("Rest") { pick(nil, isNew: false) }
        ForEach(routines.filter { !$0.paused }) { routine in
            Button(routine.name) { pick(routine, isNew: false) }
        }
        Button("New workout") {
            let draft = env.newRoutineDraft()
            pick(Routine(id: draft.id, name: "\(WeekPlan.dayName(weekday)) workout", policy: draft.policy), isNew: true)
        }
    }

    private func pick(_ routine: Routine?, isNew: Bool) {
        picked = routine
        self.isNew = isNew
        name = routine?.name ?? ""
        items = routine?.exercises ?? []
        error = nil
    }

    private func load() {
        do {
            routines = try env.routines.all()
            let id = try env.routines.schedule().days[weekday]
            let scheduled = routines.first { $0.id == id && !$0.paused }
            originalId = scheduled?.id
            pick(scheduled, isNew: false)
            loaded = true
        } catch {
            AppEnvironment.log.error("Day editor load failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't load this day."
        }
    }

    /// The picked workout with this editor's name and exercises.
    private var edited: Routine? {
        picked.map { Routine(id: $0.id, name: name.trimmingCharacters(in: .whitespaces), emoji: $0.emoji,
                             policy: $0.policy, paused: false, exercises: items) }
    }

    private var changed: Bool {
        guard let picked, let edited else { return false }
        return isNew || edited.name != picked.name || edited.exercises != picked.exercises
    }

    private func done() {
        guard let edited else { return assign(nil) }
        if let violation = DomainLimits.routineViolation(edited) { error = violation; return }
        let others = isNew ? [] : ((try? env.otherDays(of: edited.id, besides: weekday)) ?? [])
        if changed && !others.isEmpty { sharedDays = others } else { save(onlyThisDay: false) }
    }

    /// Writes the day: the workout (for all its days, or as this day's own copy) and the week.
    private func save(onlyThisDay: Bool) {
        sharedDays = []
        guard let edited else { return }
        do {
            if onlyThisDay {
                try env.saveWorkout(edited, onlyOn: weekday)
            } else {
                if changed { try env.saveWorkout(edited) }
                if edited.id != originalId { try env.schedule(every: weekday, edited.id) }
            }
            dismiss()
        } catch GymDataError.invalidInput(let message) {
            error = message
        } catch {
            AppEnvironment.log.error("Save day failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save this day. Try again."
        }
    }

    private func assign(_ id: UUID?) {
        guard id != originalId else { return dismiss() }
        do {
            try env.schedule(every: weekday, id)
            dismiss()
        } catch {
            AppEnvironment.log.error("Save day failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save this day. Try again."
        }
    }
}
```

- [ ] **Step 5: Saved workouts and the week**

Create `ios/GymRollins/Features/Plan/SavedWorkoutsView.swift`:

```swift
import GymCore
import GymData
import SwiftUI

/// Every saved workout, on the week or not (Switch and the rest-day suggestion pick from these), paused ones included,
/// and "+ Workout". Each row says which days it's on.
struct SavedWorkoutsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var routines: [Routine] = []
    @State private var schedule = WeekSchedule(days: [:])
    @State private var editing: Routine?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DisplayTitle(text: "Saved workouts")
                ForEach(routines) { routine in
                    Button { editing = routine } label: { row(routine) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("plan.routine.\(routine.name)")
                }
                GlassPillButton(title: "+ Workout", identifier: "plan.addRoutine") {
                    editing = env.newRoutineDraft()
                }
                if let error { Text(error).foregroundStyle(Theme.destructive) }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing, onDismiss: reload) { RoutineEditView(routine: $0) }
        .task(id: env.planRevision) { reload() }
    }

    private func row(_ routine: Routine) -> some View {
        let days = WeekPlan.weekdays(of: routine.id, in: schedule)
        let count = routine.exercises.count == 1 ? "1 exercise" : "\(routine.exercises.count) exercises"
        let on = days.isEmpty ? "not on your week" : days.map { WeekPlan.shortDayName($0) }.joined(separator: ", ")
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.name).font(.headline).foregroundStyle(Theme.textPrimary)
                Text("\(count) \u{00B7} \(on)").font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if routine.paused { Badge(text: "Paused", kind: .record) }
            Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
        }
        .padding(14)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        .opacity(routine.paused ? 0.7 : 1)
    }

    private func reload() {
        do { routines = try env.routines.all(); schedule = try env.routines.schedule(); error = nil }
        catch { self.error = "Couldn't load your workouts." }
    }
}
```

Replace `ios/GymRollins/Features/Plan/PlanView.swift` with:

```swift
import GymCore
import GymData
import SwiftUI

/// My Plan is the week (owner, 2026-11-10): Monday to Sunday, each day's workout and first exercises; tapping a day
/// opens its editor (`DayWorkoutEditView`). Saved workouts lists every workout, on the week or not.
struct PlanView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var routines: [Routine] = []
    @State private var schedule = WeekSchedule(days: [:])
    @State private var editingDay: EditingDay?
    @State private var error: String?

    /// The weekday open in the day editor.
    struct EditingDay: Identifiable {
        let weekday: Int
        var id: Int { weekday }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DisplayTitle(text: "My Plan")
                SectionLabel(text: "Your week")
                VStack(spacing: 8) {
                    ForEach(1...7, id: \.self) { weekday in
                        Button { editingDay = EditingDay(weekday: weekday) } label: { dayRow(weekday) }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Change this day's workout")
                            .accessibilityIdentifier("plan.day.\(weekday)")
                    }
                }
                NavigationLink { SavedWorkoutsView() } label: { savedRow }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("plan.savedWorkouts")
                if let error { Text(error).foregroundStyle(Theme.destructive) }
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingDay, onDismiss: reload) { DayWorkoutEditView(weekday: $0.weekday) }
        .task(id: env.planRevision) { reload() }
    }

    private func dayRow(_ weekday: Int) -> some View {
        let routine = schedule.days[weekday].flatMap { id in routines.first { $0.id == id && !$0.paused } }
        let names = (routine?.exercises ?? []).map { DisplayName.of(env.library.exercise($0.exerciseId)?.name ?? $0.exerciseId) }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(WeekPlan.dayName(weekday)).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    if weekday == WeekSchedule.isoWeekday(env.now()) { Badge(text: "Today", kind: .record) }
                }
                Text(routine?.name ?? "Rest").font(.headline)
                    .foregroundStyle(routine == nil ? Theme.textSecondary : Theme.textPrimary)
                if !names.isEmpty {
                    Text(WeekPlan.exerciseLine(names)).font(.footnote).foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
    }

    private var savedRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved workouts").font(.headline).foregroundStyle(Theme.textPrimary)
                Text(routines.count == 1 ? "1 workout" : "\(routines.count) workouts")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
        }
        .padding(14)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
    }

    private func reload() {
        do { routines = try env.routines.all(); schedule = try env.routines.schedule(); error = nil }
        catch { self.error = "Couldn't load your plan." }
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `scripts/ios-test.sh -only-testing:GymRollinsUITests/PlanUITests -only-testing:GymRollinsUITests/TodayScopeUITests -only-testing:GymRollinsUITests/FlowCoverageUITests -only-testing:GymRollinsUITests/LimitsCheckInUITests -only-testing:GymRollinsUITests/ProposalUITests -only-testing:GymRollinsUITests/EmptyStatesUITests`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add ios/GymRollins/Features/Plan ios/GymRollinsUITests/PlanUITests.swift ios/GymRollinsUITests/FlowCoverageUITests.swift \
  ios/GymRollinsUITests/LimitsCheckInUITests.swift ios/GymRollinsUITests/ProposalUITests.swift
git commit -m "feat(ios): My Plan is the week: tap a day to change it, Only Monday makes its own copy, Saved workouts list"
```

---

### Task 7: The app says "workout"

**Files:**
- Modify: `ios/GymRollins/Features/Today/TodayView.swift` (`emptyPlanState`)
- Modify: `ios/GymRollins/Features/Settings/SettingsPreferences.swift:50`
- Modify: `ios/GymRollins/Features/Limits/LimitsCheckInCard.swift:73`
- Modify: `README.md:37`

- [ ] **Step 1: Change the words**

- In `TodayView.emptyPlanState`:
  - "Build a routine to get started, or let Claude plan one for you." becomes "Build a workout to get started, or let Claude plan your week."
  - The button title "Create a Routine" becomes "Create a Workout". Keep the identifier `today.empty.createRoutine`.
- `newRoutineDraft()`: `"New routine"` becomes `"New workout"`.
- `LimitsCheckInCard`: "Start light: bring a paused routine back at 60% of its weights." becomes "Start light: bring a paused workout back at 60% of its weights."
- `README.md` line 37: "Routines on a weekly schedule," becomes "A weekly plan you change day by day, or for one date,".

- [ ] **Step 2: Check nothing else in Plan or Today still says "routine"**

Run: `grep -rnE '"[^"]*\b[Rr]outines?\b[^"]*"' ios/GymRollins/Features/Plan ios/GymRollins/Features/Today | grep -vE 'accessibilityIdentifier|identifier:|log\.|"(plan|today|edit)\.'`
Expected: no output.

- [ ] **Step 3: Run the affected tests**

Run: `scripts/ios-test.sh -only-testing:GymRollinsUITests/EmptyStatesUITests -only-testing:GymRollinsUITests/LimitsCheckInUITests -only-testing:GymRollinsUITests/OnboardingUITests`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add ios/GymRollins/Features/Today/TodayView.swift ios/GymRollins/Features/Settings/SettingsPreferences.swift \
  ios/GymRollins/Features/Limits/LimitsCheckInCard.swift README.md
git commit -m "feat(ios): the app says workout where it said routine"
```

---

### Task 8: My Plan, the day editor and a later day pass the accessibility checks

**Files:**
- Modify: `ios/GymRollinsUITests/AccessibilityAuditUITests.swift`
- Modify: `ios/GymRollinsUITests/DynamicTypeUITests.swift`

- [ ] **Step 1: Write the tests**

In `ios/GymRollinsUITests/AccessibilityAuditUITests.swift`, add after `testPlanScreenAudit`:

```swift
    /// My Plan's week, a day's editor and Saved workouts.
    func testMyPlanAudit() {
        let app = launch()
        app.buttons["today.myPlan"].tap()
        let monday = app.buttons["plan.day.1"]
        XCTAssertTrue(monday.waitForExistence(timeout: 5))
        waitUntilSettled(monday)
        audit(app, "My Plan")
        monday.tap()
        XCTAssertTrue(app.buttons["day.workout"].waitForExistence(timeout: 5))
        waitUntilSettled(app.buttons["day.workout"])
        audit(app, "Day editor")
        app.buttons["Cancel"].tap()
        let saved = app.buttons["plan.savedWorkouts"]
        app.scrollToHittable(saved)
        saved.tap()
        XCTAssertTrue(app.buttons["plan.addRoutine"].waitForExistence(timeout: 5))
        waitUntilSettled(app.buttons["plan.addRoutine"])
        audit(app, "Saved workouts")
    }

    /// A later day on Today, changed for that date.
    func testLaterDayAudit() {
        let app = launch()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))
        app.scrollViews.firstMatch.swipeLeft()
        app.scrollViews.firstMatch.swipeLeft()
        let menu = app.buttons["today.row.menu.0025"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        app.buttons["Delete from Workout"].tap()
        XCTAssertTrue(app.buttons["today.backToToday"].waitForExistence(timeout: 5))
        waitUntilSettled(app.buttons["today.backToToday"])
        audit(app, "Later day")
    }
```

`waitUntilSettled` already exists in this file. Check its signature before using it.

In `ios/GymRollinsUITests/DynamicTypeUITests.swift`, add after `testTodayDateButtonStaysCompactAtAccessibilityXL`:

```swift
    /// My Plan's day rows stay inside the screen and every day can be reached at the largest text size.
    func testMyPlanWeekAtAccessibilityXL() {
        let app = launch()
        app.buttons["today.myPlan"].tap()
        let monday = app.buttons["plan.day.1"]
        XCTAssertTrue(monday.waitForExistence(timeout: 5))
        screenshot("my-plan-ax-xl")
        let width = app.windows.firstMatch.frame.width
        for weekday in 1...7 {
            let row = app.buttons["plan.day.\(weekday)"]
            app.scrollToHittable(row)
            XCTAssertTrue(row.isHittable, "day \(weekday)")
            XCTAssertLessThanOrEqual(row.frame.maxX, width + 0.5, "day \(weekday) \(row.frame)")
        }
        app.buttons["plan.day.1"].tap()
        XCTAssertTrue(app.buttons["day.workout"].waitForExistence(timeout: 5))
        screenshot("day-editor-ax-xl")
    }
```

- [ ] **Step 2: Run them**

Run: `scripts/ios-test.sh -only-testing:GymRollinsUITests/AccessibilityAuditUITests/testMyPlanAudit -only-testing:GymRollinsUITests/AccessibilityAuditUITests/testLaterDayAudit -only-testing:GymRollinsUITests/DynamicTypeUITests/testMyPlanWeekAtAccessibilityXL`
Expected: all pass.
- If an audit reports a contrast issue on a My Plan text, use `Theme.textSecondary` for it. The rows already use it; the chevrons are hidden from accessibility.
- If a row at AX-XL overflows, allow the exercise line to wrap by raising `.lineLimit(2)` to `.lineLimit(3)`. Rerun after the fix.

- [ ] **Step 3: Look at the screenshots**

Export the AX-XL attachments:

```bash
R=$(ls -td ios/build/TestResults-*.xcresult | head -1)
xcrun xcresulttool export attachments --path "$R" --output-path <scratchpad>/p34-ax
```

Open `my-plan-ax-xl` and `day-editor-ax-xl`. Check that no text breaks one letter per line and nothing is cut off. Fix anything that is, then rerun Step 2.

- [ ] **Step 4: Commit**

```bash
git add ios/GymRollinsUITests/AccessibilityAuditUITests.swift ios/GymRollinsUITests/DynamicTypeUITests.swift \
  ios/GymRollins/Features/Plan
git commit -m "test(ios): My Plan, the day editor, Saved workouts and a later day pass the audit and the largest text size"
```

---

### Task 9: Whole suite, screenshots, outcome

- [ ] **Step 1: Run the whole app suite**

Run: `scripts/ios-test.sh`
Expected: everything passes apart from the known flake `AccessibilityAuditUITests/testUnblockEveryoneAudit` (contrast measured mid-fade on Settings). If that one fails, run it alone twice and record both results. Any other failure is a bug: fix it test-first and rerun.

- [ ] **Step 2: Screenshots in light and dark**

The app is dark-only. Take the simulator's light and dark appearance anyway, as in plan 33, so a system-colour slip shows up. Use a temporary UI test kept outside the repo, in `<scratchpad>`. It captures:
- My Plan;
- Monday's editor;
- the "Only Monday" question;
- Saved workouts;
- a later day changed for that date, with Reset this day;
- Switch's "Only … / Every …" question;
- Save Changes' question.

Put them on one contact sheet and look at every screen.

- [ ] **Step 3: Write the outcome**

Append an `## Outcome` section to this plan. Include:
- the commits;
- the counts from Step 1 (total, passed, failed, skipped);
- what the screenshots found and fixed;
- anything not verified.

Commit it as `docs: plan 34 outcome`.

---

## Self-review

| Decision | Where |
|---|---|
| 1. Routines stay; no server, sync or agent change | File map has no server files; Tasks 1–3 work on the existing routines and schedule |
| 2. The week is the plan: rows, today marked, day editor with picker, Only Monday copy, Saved workouts | Task 6 (`PlanView`, `DayWorkoutEditView`, `SavedWorkoutsView`); copy in Task 3 |
| 3. Later days like today: same controls, no Start, "changed for this day", Reset this day | Task 4 |
| 4. Switch asks Only / Every; paused is date-only; Rest on a later rest day; "Rest every …" for empty today | Task 5 (`TodaySwitchSheet`) |
| 5. Save Changes asks about shared days; a switched workout doesn't ask; the day shows the copy after Only | Task 5 (`saveToRoutineButton`, `saveChanges`) |
| 6. A changed date keeps its version; agent and owner replace each other, newest wins | Task 1 (`TodayPlanStore.current`), Task 2 (`LaterDayPlanSaver`, `applyDayRoutines`) |
| 7. One-date changes stay on the phone and are dropped once past | Task 1 (`take` drops earlier days), Task 2 (`takeLaterDayPlan`) |
| The word "workout" in My Plan and Today | Tasks 5, 6, 7 |
| Accessibility | Task 8 |
