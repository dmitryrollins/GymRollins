# Plan 03: Workout flow (start → log → rest → finish → summary → resume)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a full workout on the phone: start today's routine with suggested weights and warm-ups, log sets on the
Fitbod-style logging screen (hexagon set timeline, big reps/weight boxes, Log Set / Log All Sets), rest timer with
notification, plate calculator, swap/add/remove exercises, notes, workout clock with pause, finish (discard or mark
remaining sets), summary with PRs, and resume after the app is killed.

**Architecture:** Pure editing and summary logic lives in GymCore (`Workout+Editing`, `WorkoutSummary`) and is
unit-tested with `swift test`. The app has a pure `SessionPlanner` (routine → new `Workout`) and an `@Observable`
`WorkoutSession` that holds the in-progress `Workout` value. Every mutation produces a new `Workout` value and is
persisted through `WorkoutRepository.saveActive`. Views are thin and talk only to `WorkoutSession`. The rest timer is
a value (`RestTimer`) plus a `RestNotifier` protocol, with a UserNotifications implementation and a no-op for tests.

**Tech Stack:** Swift 6.2, SwiftUI iOS 26 (Liquid Glass), Swift Charts, UserNotifications, SwiftData via GymData,
Swift Testing, XCUITest.

**Depends on:** Plan 02 merged (app shell, GymData repositories, design system, Today), including its review fixes:
`Exercise.bilateral` (GymCore), a single active workout enforced by `WorkoutRepository`, plates stored in kg, and
`CustomExerciseRepository.create` throwing on an empty name. Also note that `RoutineExercise.init` takes
`weightSetAt:` as its **last** parameter.
**Spec:** §5 "Workout session". **Mockups:** `docs/design/WorkoutOverview, Logging, RestSettings, Plates, HowTo, Swap,
ExerciseOptions, AddExercise, FinishConfirm, Summary`.

**Scope decisions (YAGNI, and different from the mockups):** Exercise options ship with Notes, Add warm-up set and
Remove from workout. Per-exercise units and "recommend more/less often" are dropped for v1. Rest settings are global
(profile `restSec` / `warmupRestSec` plus two toggles stored in `UserDefaults`), not per exercise.

**Conventions:** Branch `plan-03-workout-flow` from `main`. Commit per task with the trailer lines
(`Co-Authored-By: Claude <model> <noreply@anthropic.com>`,
`Claude-Session: https://claude.ai/code/session_01LD8UaVzMa2mmiCXaEUujBN`). Never `git add -A`. Simulator
`platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2` via `scripts/ios-test.sh`. Show weights with
`WeightFormatter`; store in kg. Accessibility identifiers are listed per task.

---

## File structure

```
ios/Packages/GymCore/Sources/GymCore/
  Model/Workout+Editing.swift          immutable editing helpers
  Metrics/WorkoutSummary.swift         duration, sets, volume, records
ios/Packages/GymCore/Tests/GymCoreTests/WorkoutEditingTests.swift, WorkoutSummaryTests.swift
ios/Packages/GymData/Sources/GymData/
  Store/GymStore.swift                 (modify) on-disk URL option for UI tests
  Seed/OwnerSeed.swift                 (modify) optional history sessions
ios/GymRollins/
  App/LaunchOptions.swift              (modify) -diskStore, -resetStore, -seedHistory
  App/AppEnvironment.swift             (modify) session lifecycle
  Features/Workout/SessionPlanner.swift
  Features/Workout/RestTimer.swift      RestTimer value + RestNotifier
  Features/Workout/WorkoutSession.swift
  Features/Workout/WorkoutFlowView.swift        full-screen container
  Features/Workout/WorkoutOverviewView.swift
  Features/Workout/LoggingView.swift
  Features/Workout/SetTimelineRow.swift         hex badge + reps/weight boxes
  Features/Workout/RestBar.swift
  Features/Workout/Sheets/RestSettingsSheet.swift
  Features/Workout/Sheets/PlatesSheet.swift
  Features/Workout/Sheets/SwapSheet.swift
  Features/Workout/Sheets/ExerciseOptionsSheet.swift
  Features/Workout/Sheets/FinishSheet.swift
  Features/Workout/SummaryView.swift
  Features/History/ExerciseHistoryView.swift     history list + e1RM chart
  Features/Today/TodayView.swift                 (modify) Start / Resume
ios/GymRollinsTests/SessionPlannerTests.swift, WorkoutSessionTests.swift, RestTimerTests.swift
ios/GymRollinsUITests/WorkoutFlowUITests.swift
```

---

### Task 1: GymCore editing helpers and summary

**Files:** Create `Model/Workout+Editing.swift`, `Metrics/WorkoutSummary.swift`; Tests `WorkoutEditingTests.swift`,
`WorkoutSummaryTests.swift`.

- [ ] **Step 1: Branch** `git checkout main && git checkout -b plan-03-workout-flow`

- [ ] **Step 2: Failing tests** `WorkoutEditingTests.swift`

```swift
import Foundation
import Testing
@testable import GymCore

@Suite struct WorkoutEditingTests {
    let warm = WorkoutSet(weightKg: 20.41, reps: 10, warmup: true)
    let s1 = WorkoutSet(weightKg: 63.5, reps: 8)
    let s2 = WorkoutSet(weightKg: 63.5, reps: 8)
    var bench: WorkoutEntry { WorkoutEntry(exerciseId: "0025", sets: [warm, s1, s2]) }
    var curl: WorkoutEntry { WorkoutEntry(exerciseId: "0070", sets: [WorkoutSet(weightKg: 24.9, reps: 10)]) }
    var workout: Workout { Workout(startedAt: Date(timeIntervalSince1970: 0), name: "Push", entries: [bench, curl]) }

    @Test func updatingSetReturnsNewWorkout() {
        let w = workout
        let e = w.entries[0]
        let updated = w.updatingSet(entryId: e.id, setId: e.sets[1].id) { $0.with(weightKg: 65, reps: 9) }
        #expect(updated.entries[0].sets[1].weightKg == 65)
        #expect(updated.entries[0].sets[1].reps == 9)
        #expect(w.entries[0].sets[1].weightKg == 63.5) // original untouched
    }

    @Test func appendingSetCopiesLastWorkingSetUndone() {
        let w = workout
        let e = w.entries[0]
        let done = w.updatingSet(entryId: e.id, setId: e.sets[2].id) { $0.completing(at: Date()) }
        let appended = done.appendingSet(entryId: e.id)
        let last = appended.entries[0].sets.last!
        #expect(appended.entries[0].sets.count == 4)
        #expect(last.weightKg == 63.5 && last.reps == 8 && !last.done && !last.warmup)
        #expect(last.id != e.sets[2].id)
    }

    @Test func insertingWarmupGoesBeforeFirstWorkingSet() {
        let w = workout
        let e = w.entries[0]
        let result = w.insertingWarmup(entryId: e.id, set: WorkoutSet(weightKg: 47.6, reps: 5, warmup: true))
        #expect(result.entries[0].sets.map(\.warmup) == [true, true, false, false])
        #expect(result.entries[0].sets[1].weightKg == 47.6)
    }

    @Test func removeSetEntryAndReplaceExercise() {
        let w = workout
        let e = w.entries[0]
        #expect(w.removingSet(entryId: e.id, setId: e.sets[0].id).entries[0].sets.count == 2)
        #expect(w.removingEntry(entryId: e.id).entries.map(\.exerciseId) == ["0070"])
        #expect(w.replacingExercise(entryId: e.id, exerciseId: "0314").entries[0].exerciseId == "0314")
        #expect(w.appendingEntries([WorkoutEntry(exerciseId: "0251")]).entries.count == 3)
        #expect(w.settingNote(entryId: e.id, note: "elbows in").entries[0].note == "elbows in")
    }

    @Test func undoneCountsAndFinish() {
        let w = workout
        let e = w.entries[0]
        let partly = w.updatingSet(entryId: e.id, setId: e.sets[1].id) { $0.completing(at: Date(timeIntervalSince1970: 60)) }
        #expect(partly.undoneSetCount == 3)
        #expect(partly.entriesWithUndoneSets.map(\.exerciseId) == ["0025", "0070"])
        let end = Date(timeIntervalSince1970: 3_000)
        let discarded = partly.finished(at: end, discardingUndone: true)
        #expect(discarded.endedAt == end)
        #expect(discarded.entries.map(\.exerciseId) == ["0025"])
        #expect(discarded.entries[0].sets.count == 1)
        let all = partly.markingAllDone(at: end).finished(at: end, discardingUndone: true)
        #expect(all.undoneSetCount == 0)
        #expect(all.entries.flatMap(\.sets).count == 4)
    }

    @Test func missingIdsAreNoOps() {
        let w = workout
        #expect(w.updatingSet(entryId: UUID(), setId: UUID()) { $0.with(weightKg: 1, reps: 1) } == w)
        #expect(w.removingEntry(entryId: UUID()) == w)
    }
}
```

`WorkoutSummaryTests.swift`:
```swift
import Foundation
import Testing
@testable import GymCore

@Suite struct WorkoutSummaryTests {
    @Test func summarizesDurationSetsVolumeAndRecords() {
        let start = Date(timeIntervalSince1970: 0)
        let workout = Workout(startedAt: start, endedAt: start.addingTimeInterval(3_520), pausedSeconds: 40,
                              name: "Push + Biceps", entries: [
            WorkoutEntry(exerciseId: "bench", sets: [
                WorkoutSet(weightKg: 20, reps: 10, done: true, warmup: true),
                WorkoutSet(weightKg: 58.967, reps: 10, done: true),
                WorkoutSet(weightKg: 58.967, reps: 10, done: true),
            ]),
        ])
        let prior = ["bench": ExerciseBests(e1RMKg: 70.76, repsAtWeight: [58_967: 6], volumeKg: 1_061.4)]
        let summary = WorkoutSummary(workout: workout, previousBests: prior)
        #expect(summary.durationSeconds == 3_480)
        #expect(summary.workingSets == 2)
        #expect(abs(summary.volumeKg - 1_179.34) < 0.01)
        #expect(summary.records.map(\.kind).contains(.e1RM))
    }
}
```

- [ ] **Step 3: Implement** `Model/Workout+Editing.swift`

```swift
import Foundation

extension WorkoutSet {
    public func with(weightKg: Double, reps: Int) -> WorkoutSet {
        WorkoutSet(id: id, weightKg: weightKg, reps: reps, sec: sec, minutes: minutes, distanceM: distanceM, done: done,
                   warmup: warmup, rir: rir, rpe: rpe, multiplier: multiplier, completedAt: completedAt)
    }

    /// Fresh copy (new id, not done) used for "Add set".
    func duplicatedUndone() -> WorkoutSet {
        WorkoutSet(weightKg: weightKg, reps: reps, sec: sec, minutes: minutes, distanceM: distanceM, done: false,
                   warmup: false, multiplier: multiplier)
    }
}

extension WorkoutEntry {
    public func with(sets: [WorkoutSet]) -> WorkoutEntry {
        WorkoutEntry(id: id, exerciseId: exerciseId, sets: sets, note: note, supersetGroup: supersetGroup)
    }

    func with(exerciseId: String) -> WorkoutEntry {
        WorkoutEntry(id: id, exerciseId: exerciseId, sets: sets, note: note, supersetGroup: supersetGroup)
    }

    func with(note: String?) -> WorkoutEntry {
        WorkoutEntry(id: id, exerciseId: exerciseId, sets: sets, note: note, supersetGroup: supersetGroup)
    }
}

extension Workout {
    public func with(entries: [WorkoutEntry]) -> Workout {
        Workout(id: id, startedAt: startedAt, endedAt: endedAt, pausedSeconds: pausedSeconds, routineId: routineId,
                name: name, entries: entries, source: source, note: note)
    }

    public func with(endedAt: Date?, pausedSeconds: TimeInterval) -> Workout {
        Workout(id: id, startedAt: startedAt, endedAt: endedAt, pausedSeconds: pausedSeconds, routineId: routineId,
                name: name, entries: entries, source: source, note: note)
    }

    private func mappingEntry(_ entryId: UUID, _ transform: (WorkoutEntry) -> WorkoutEntry) -> Workout {
        guard entries.contains(where: { $0.id == entryId }) else { return self }
        return with(entries: entries.map { $0.id == entryId ? transform($0) : $0 })
    }

    public func updatingSet(entryId: UUID, setId: UUID, _ transform: (WorkoutSet) -> WorkoutSet) -> Workout {
        mappingEntry(entryId) { entry in entry.with(sets: entry.sets.map { $0.id == setId ? transform($0) : $0 }) }
    }

    public func appendingSet(entryId: UUID) -> Workout {
        mappingEntry(entryId) { entry in
            let template = entry.sets.last(where: { !$0.warmup }) ?? entry.sets.last
            let new = template?.duplicatedUndone() ?? WorkoutSet(weightKg: 0, reps: 8)
            return entry.with(sets: entry.sets + [new])
        }
    }

    public func insertingWarmup(entryId: UUID, set: WorkoutSet) -> Workout {
        mappingEntry(entryId) { entry in
            let index = entry.sets.firstIndex(where: { !$0.warmup }) ?? entry.sets.count
            return entry.with(sets: Array(entry.sets[..<index]) + [set] + Array(entry.sets[index...]))
        }
    }

    public func removingSet(entryId: UUID, setId: UUID) -> Workout {
        mappingEntry(entryId) { $0.with(sets: $0.sets.filter { $0.id != setId }) }
    }

    public func removingEntry(entryId: UUID) -> Workout {
        with(entries: entries.filter { $0.id != entryId })
    }

    public func replacingExercise(entryId: UUID, exerciseId: String) -> Workout {
        mappingEntry(entryId) { $0.with(exerciseId: exerciseId) }
    }

    public func appendingEntries(_ new: [WorkoutEntry]) -> Workout {
        with(entries: entries + new)
    }

    public func settingNote(entryId: UUID, note: String?) -> Workout {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return mappingEntry(entryId) { $0.with(note: trimmed?.isEmpty == true ? nil : trimmed) }
    }

    public var undoneSetCount: Int { entries.reduce(0) { $0 + $1.sets.filter { !$0.done }.count } }

    public var entriesWithUndoneSets: [WorkoutEntry] { entries.filter { $0.sets.contains { !$0.done } } }

    public func markingAllDone(at date: Date) -> Workout {
        with(entries: entries.map { e in e.with(sets: e.sets.map { $0.done ? $0 : $0.completing(at: date) }) })
    }

    /// Ends the workout. With `discardingUndone`, undone sets and then-empty entries are removed.
    public func finished(at date: Date, discardingUndone: Bool) -> Workout {
        let kept = discardingUndone
            ? entries.map { $0.with(sets: $0.sets.filter(\.done)) }.filter { !$0.sets.isEmpty }
            : entries
        return with(entries: kept).with(endedAt: date, pausedSeconds: pausedSeconds)
    }
}
```

`Metrics/WorkoutSummary.swift`:
```swift
import Foundation

public struct WorkoutSummary: Sendable, Equatable {
    public let durationSeconds: TimeInterval
    public let workingSets: Int
    public let volumeKg: Double
    public let records: [PersonalRecord]

    public init(workout: Workout, previousBests: [String: ExerciseBests]) {
        let end = workout.endedAt ?? workout.startedAt
        durationSeconds = max(0, end.timeIntervalSince(workout.startedAt) - workout.pausedSeconds)
        workingSets = WorkoutMetrics.workingSetCount(workout)
        volumeKg = WorkoutMetrics.volumeKg(workout)
        records = RecordDetector.records(for: workout, previous: previousBests)
    }
}
```

Run `cd ios/Packages/GymCore && swift test` → PASS. **Commit:** `feat(core): immutable workout editing helpers and summary`

---

### Task 2: Launch options, disk store, history seed

**Files:** Modify `GymData/Store/GymStore.swift`, `GymData/Seed/OwnerSeed.swift`, `App/LaunchOptions.swift`,
`App/AppEnvironment.swift`; Test `GymDataTests/OwnerSeedTests.swift` (add a test).

- [ ] **Step 1: GymStore with URL**

```swift
public static func container(inMemory: Bool, url: URL? = nil) throws -> ModelContainer {
    let config = url.map { ModelConfiguration(url: $0) } ?? ModelConfiguration(isStoredInMemoryOnly: inMemory)
    return try ModelContainer(for: Schema(models), configurations: config)
}
```

- [ ] **Step 2: Seeded history** (for deterministic suggestions and PRs in UI tests). Add to `OwnerSeed`:

```swift
/// Two real bench sessions (12 Sep: 3×6 @130 lb; 19 Sep: 3×10 @130 lb) so Today suggests 135 lb and PRs can fire.
public static func applyHistory(to context: ModelContext, now: Date) throws {
    let workouts = WorkoutRepository(context: context, now: { now })
    guard try workouts.recent(limit: 1).isEmpty else { return }
    let bench = { (day: String, reps: Int) -> Workout in
        let start = ISO8601DateFormatter().date(from: "\(day)T18:00:00Z")!
        return Workout(startedAt: start, endedAt: start.addingTimeInterval(3_500), name: "Push + Biceps", entries: [
            WorkoutEntry(exerciseId: "0025", sets: (0..<3).map { _ in
                WorkoutSet(weightKg: lb(130), reps: reps, done: true, completedAt: start) }),
        ])
    }
    try workouts.save(bench("2026-09-12", 6))
    try workouts.save(bench("2026-09-19", 10))
}
```
Test (add to `OwnerSeedTests`): after `applyHistory` twice, `recent(limit: 10).count == 2` and
`history(exerciseId: "0025", limit: 5).first?.reps == [10, 10, 10]`.

- [ ] **Step 3: LaunchOptions** add:

```swift
/// UI tests that relaunch need a store that survives the process: -diskStore uses a file in tmp.
let diskStoreURL: URL?
/// Delete the disk store before opening (first launch of a test).
let resetStore: Bool
let seedHistory: Bool
```
initialized as:
```swift
diskStoreURL = arguments.contains("-diskStore")
    ? FileManager.default.temporaryDirectory.appendingPathComponent("gymrollins-uitest.store") : nil
resetStore = arguments.contains("-resetStore")
seedHistory = arguments.contains("-seedHistory")
```
In `AppEnvironment.init`: if `resetStore`, remove the store file and its `-shm`/`-wal` siblings (ignore
not-found errors), then open with `GymStore.container(inMemory: options.inMemory && options.diskStoreURL == nil, url: options.diskStoreURL)`.
Seeding when `seedOwner` also calls `applyHistory` if `seedHistory`.

Run the GymData tests and `scripts/ios-test.sh` → PASS. **Commit:** `feat(app): disk store and history seed launch options for UI tests`

---

### Task 3: SessionPlanner and RestTimer (pure, unit-tested)

**Files:** Create `Features/Workout/SessionPlanner.swift`, `Features/Workout/RestTimer.swift`; Tests
`SessionPlannerTests.swift`, `RestTimerTests.swift`.

- [ ] **Step 1: Failing tests** `SessionPlannerTests.swift`

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@Suite struct SessionPlannerTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private func inLb(_ kg: Double) -> Double { (UnitConverter.fromKg(kg, to: .lb) * 10).rounded() / 10 }
    private let library = ExerciseLibrary(exercises: [
        Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
        Exercise(id: "0313", name: "dumbbell hammer curl", bodyPart: "upper arms", equipment: "dumbbell", target: "biceps"),
    ])

    @Test func buildsEntriesWithWarmupsAndSuggestions() {
        let routine = Routine(name: "Push + Arms", exercises: [
            RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, repsMin: 8, weightKg: lb(130), incKg: lb(5)),
            RoutineExercise(exerciseId: "0313", sets: 3, reps: 10, repsMin: 8, weightKg: lb(22.5), incKg: lb(2.5)),
        ])
        let history = ["0025": [SessionResult(date: .now, weightKg: lb(130), reps: [10, 10, 10])]]
        let start = Date(timeIntervalSince1970: 1_000)
        let w = SessionPlanner.start(routine: routine, profile: Profile(), library: library, now: start,
                                     history: { history[$0] ?? [] })
        #expect(w.name == "Push + Arms")
        #expect(w.routineId == routine.id)
        #expect(w.startedAt == start)
        let bench = w.entries[0]
        #expect(bench.sets.filter(\.warmup).map { inLb($0.weightKg) } == [45, 100])   // 75% of 135 -> 100 lb
        #expect(bench.sets.filter { !$0.warmup }.map { inLb($0.weightKg) } == [135, 135, 135])
        #expect(bench.sets.filter { !$0.warmup }.map(\.reps) == [8, 8, 8])
        let curl = w.entries[1]
        #expect(curl.sets.allSatisfy { !$0.warmup })          // no warm-ups for dumbbells
        #expect(curl.sets.allSatisfy { $0.multiplier == 2 })  // dumbbell pair
        #expect(curl.sets.count == 3)
    }

    @Test func bodyweightExerciseHasZeroWeight() {
        let lib = ExerciseLibrary(exercises: [
            Exercise(id: "0251", name: "chest dip", bodyPart: "chest", equipment: "body weight", target: "pectorals")])
        let routine = Routine(name: "Upper", exercises: [RoutineExercise(exerciseId: "0251", sets: 3, reps: 10)])
        let w = SessionPlanner.start(routine: routine, profile: Profile(), library: lib, now: .now, history: { _ in [] })
        #expect(w.entries[0].sets.map(\.weightKg) == [0, 0, 0])
        #expect(w.entries[0].sets.map(\.reps) == [10, 10, 10])
    }

    @Test func emptyWorkoutForQuickStart() {
        let w = SessionPlanner.empty(now: Date(timeIntervalSince1970: 5))
        #expect(w.entries.isEmpty)
        #expect(w.name == "Workout")
    }
}
```
(Expected warm-up: 75% of 135 lb = 101.25 lb, rounded to the nearest 5 lb = 100 lb. Check against
`WarmupGenerator` + `LoadRounder.barbellLb.nearest`.)

`RestTimerTests.swift`:
```swift
import Foundation
import Testing
@testable import GymRollins

@Suite struct RestTimerTests {
    @Test func remainingAndAdjust() {
        let t0 = Date(timeIntervalSince1970: 100)
        let timer = RestTimer(startedAt: t0, duration: 120)
        #expect(timer.remaining(at: t0.addingTimeInterval(36)) == 84)
        #expect(timer.remaining(at: t0.addingTimeInterval(500)) == 0)
        #expect(timer.isFinished(at: t0.addingTimeInterval(120)))
        #expect(timer.adjusted(by: 15).remaining(at: t0) == 135)
        #expect(timer.adjusted(by: -200).remaining(at: t0) == 0)
        #expect(timer.endsAt == t0.addingTimeInterval(120))
    }

    @Test func formatting() {
        #expect(RestTimer(startedAt: .now, duration: 84).label(at: .now) == "1:24")
    }
}
```

- [ ] **Step 2: Implement** `SessionPlanner.swift`

```swift
import Foundation
import GymCore
import GymData

/// Builds a new in-progress Workout from a routine: suggested weights, warm-ups for barbell lifts, dumbbell multiplier.
enum SessionPlanner {
    static let barbellEquipment: Set<String> = ["barbell", "olympic barbell", "ez barbell", "smith machine", "trap bar"]

    static func start(routine: Routine, profile: Profile, library: ExerciseLibrary, now: Date,
                      history: (String) -> [SessionResult]) -> Workout {
        let entries = routine.exercises.map { item in
            entry(for: item, policy: item.policy ?? routine.policy, profile: profile,
                  exercise: library.exercise(item.exerciseId), history: history(item.exerciseId))
        }
        return Workout(startedAt: now, routineId: routine.id, name: routine.name, entries: entries)
    }

    static func empty(now: Date) -> Workout { Workout(startedAt: now, name: "Workout") }

    static func entry(for item: RoutineExercise, policy: ProgressionPolicy, profile: Profile, exercise: Exercise?,
                      history: [SessionResult]) -> WorkoutEntry {
        let isBarbell = exercise.map { barbellEquipment.contains($0.equipment) } ?? false
        let isDumbbell = exercise?.equipment == "dumbbell" || exercise?.bilateral == true
        let rounder = LoadRounding.rounder(for: exercise, profile: profile) // from plan 02 (Codex fix)
        let engine = ProgressionEngine(rounder: rounder, deloadPct: profile.deloadPct)
        let target = ProgressionTarget(sets: item.sets, reps: item.reps, repsMin: item.repsMin, sec: item.sec,
                                       weightKg: item.weightKg ?? 0,
                                       incKg: item.incKg ?? UnitConverter.toKg(isBarbell ? 5 : 2.5, from: .lb),
                                       weightSetAt: item.weightSetAt)
        let suggestion = engine.suggest(policy: policy, target: target, history: history)
        let working = (0..<item.sets).map { _ in
            WorkoutSet(weightKg: suggestion.weightKg, reps: suggestion.reps, sec: suggestion.sec,
                       multiplier: isDumbbell ? 2 : 1)
        }
        let warmups = isBarbell
            ? WarmupGenerator.sets(workingKg: suggestion.weightKg, barKg: profile.barKg, rounder: rounder)
            : []
        return WorkoutEntry(exerciseId: item.exerciseId, sets: warmups + working, supersetGroup: item.supersetGroup)
    }
}
```

`RestTimer.swift`:
```swift
import Foundation
import UserNotifications
import os

struct RestTimer: Equatable, Sendable {
    let startedAt: Date
    let duration: TimeInterval

    var endsAt: Date { startedAt.addingTimeInterval(duration) }

    func remaining(at now: Date) -> TimeInterval { max(0, endsAt.timeIntervalSince(now)) }
    func isFinished(at now: Date) -> Bool { remaining(at: now) <= 0 }
    func adjusted(by seconds: TimeInterval) -> RestTimer {
        RestTimer(startedAt: startedAt, duration: max(0, duration + seconds))
    }
    func label(at now: Date) -> String { DurationFormatter.clock(remaining(at: now).rounded(.up)) }
}

@MainActor
protocol RestNotifier {
    func schedule(endsAt: Date)
    func cancel()
}

struct NoopRestNotifier: RestNotifier {
    func schedule(endsAt: Date) {}
    func cancel() {}
}

/// Local notification when rest ends (app in background). Asks for permission on first use.
@MainActor
struct UserNotificationRestNotifier: RestNotifier {
    private let id = "rest-timer"
    private static let log = Logger(subsystem: "com.rollins.gymrollins", category: "rest")

    func schedule(endsAt: Date) {
        let center = UNUserNotificationCenter.current()
        let seconds = endsAt.timeIntervalSinceNow
        guard seconds > 1 else { return }
        Task {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                let content = UNMutableNotificationContent()
                content.title = "Rest over"
                content.body = "Time for your next set."
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
                center.removePendingNotificationRequests(withIdentifiers: [id])
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            } catch {
                Self.log.error("Rest notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
```
(`DurationFormatter` comes from GymCore; add `import GymCore`.)

**DRY with Today:** extract the suggestion part of `entry(for:…)` into
`static func suggestion(for item: RoutineExercise, policy: ProgressionPolicy, profile: Profile, exercise: Exercise?, history: [SessionResult]) -> Suggestion`
(it picks the barbell or dumbbell rounder and the increment the same way), and change `TodayModel.make` to call it,
so Today shows exactly the weight the workout will start with. Add a `TodayModelTests` case: a dumbbell exercise at
27.5 lb shows "27.5 lb", not a barbell-rounded 30 lb.

Run `scripts/ios-test.sh -only-testing:GymRollinsTests` → PASS. **Commit:** `feat(workout): session planner and rest timer`

---

### Task 4: WorkoutSession (observable, persisted, unit-tested)

**Files:** Create `Features/Workout/WorkoutSession.swift`; Test `WorkoutSessionTests.swift`.

`WorkoutSession` owns the in-progress `Workout` value, the `WorkoutClock`, the current entry and the rest timer.
Every mutation assigns a **new** `Workout` value and calls `persist(workout, clock)`. Finishing computes the summary
against the bests from *before* saving.

- [ ] **Step 1: Failing tests** `WorkoutSessionTests.swift`

```swift
import Foundation
import GymCore
import Testing
@testable import GymRollins

@MainActor
@Suite struct WorkoutSessionTests {
    final class Spy {
        var persisted: [Workout] = []
        var finished: Workout?
        var discarded = false
        var scheduled: [Date] = []
    }
    struct SpyNotifier: RestNotifier {
        let spy: Spy
        func schedule(endsAt: Date) { spy.scheduled.append(endsAt) }
        func cancel() {}
    }

    var t = Date(timeIntervalSince1970: 1_000)

    func make(_ spy: Spy, now: @escaping () -> Date) -> WorkoutSession {
        let workout = Workout(startedAt: Date(timeIntervalSince1970: 1_000), name: "Push", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [
                WorkoutSet(weightKg: 20.41, reps: 10, warmup: true),
                WorkoutSet(weightKg: 61.2, reps: 8),
                WorkoutSet(weightKg: 61.2, reps: 8),
            ]),
            WorkoutEntry(exerciseId: "0070", sets: [WorkoutSet(weightKg: 24.9, reps: 10)]),
        ])
        return WorkoutSession(
            workout: workout, clock: WorkoutClock(startedAt: workout.startedAt),
            restSeconds: 120, warmupRestSeconds: 60, notifier: SpyNotifier(spy: spy), now: now,
            persist: { w, _ in spy.persisted.append(w) },
            previousBests: { _ in ExerciseBests(e1RMKg: 70, repsAtWeight: [:], volumeKg: 100) },
            saveFinished: { spy.finished = $0 },
            discard: { spy.discarded = true })
    }

    @Test func logSetMarksNextUndoneAndStartsRest() throws {
        let spy = Spy()
        var now = Date(timeIntervalSince1970: 1_100)
        let s = make(spy, now: { now })
        s.logNextSet(weightKg: 20.41, reps: 10)
        #expect(s.workout.entries[0].sets[0].done)
        #expect(s.rest?.duration == 60)                          // warm-up rest
        now = Date(timeIntervalSince1970: 1_200)
        s.logNextSet(weightKg: 63.5, reps: 8)                     // edited values are applied
        #expect(s.workout.entries[0].sets[1].weightKg == 63.5)
        #expect(s.rest?.duration == 120)
        #expect(spy.scheduled.count == 2)
        #expect(spy.persisted.count == 2)
    }

    @Test func finishingAnEntryAdvancesCurrent() {
        let spy = Spy()
        let s = make(spy, now: { Date(timeIntervalSince1970: 1_100) })
        let first = s.workout.entries[0].id
        #expect(s.currentEntryId == first)
        s.logAllSets()
        #expect(s.workout.entries[0].sets.allSatisfy(\.done))
        #expect(s.currentEntryId == s.workout.entries[1].id)
    }

    @Test func pauseResumeAffectsElapsed() {
        let spy = Spy()
        var now = Date(timeIntervalSince1970: 1_600)
        let s = make(spy, now: { now })
        s.togglePause()
        now = Date(timeIntervalSince1970: 1_900)
        s.togglePause()
        #expect(s.elapsed(at: Date(timeIntervalSince1970: 2_000)) == 700)
    }

    @Test func finishDiscardingUndoneSavesAndSummarizes() throws {
        let spy = Spy()
        let s = make(spy, now: { Date(timeIntervalSince1970: 4_000) })
        s.logAllSets() // bench done; curl undone
        let summary = try s.finish(discardingUndone: true)
        let saved = try #require(spy.finished)
        #expect(saved.entries.map(\.exerciseId) == ["0025"])
        #expect(saved.endedAt == Date(timeIntervalSince1970: 4_000))
        #expect(summary.workingSets == 2)
        #expect(summary.records.contains { $0.kind == .volume })
    }

    @Test func editingOperationsPersist() {
        let spy = Spy()
        let s = make(spy, now: { Date(timeIntervalSince1970: 1_100) })
        let bench = s.workout.entries[0].id
        s.addSet(entryId: bench)
        s.addWarmup(entryId: bench, barKg: 20.41)
        s.swap(entryId: bench, to: "0314")
        s.setNote(entryId: bench, note: "slow eccentric")
        s.addExercises(["0251"], makeEntry: { WorkoutEntry(exerciseId: $0, sets: [WorkoutSet(weightKg: 0, reps: 10)]) })
        s.removeEntry(s.workout.entries[1].id)
        #expect(s.workout.entries.map(\.exerciseId) == ["0314", "0251"])
        #expect(s.workout.entries[0].sets.count == 5)
        #expect(s.workout.entries[0].note == "slow eccentric")
        #expect(spy.persisted.count == 6)
    }

    @Test func discardCallsDiscard() {
        let spy = Spy()
        let s = make(spy, now: { .now })
        s.discardWorkout()
        #expect(spy.discarded)
    }
}
```

- [ ] **Step 2: Implement** `WorkoutSession.swift`

```swift
import Foundation
import GymCore
import Observation
import os

@MainActor
@Observable
final class WorkoutSession: Identifiable {
    nonisolated let id = UUID()
    private(set) var workout: Workout
    private(set) var clock: WorkoutClock
    private(set) var currentEntryId: UUID?
    private(set) var rest: RestTimer?
    private(set) var lastError: String?
    var restSeconds: TimeInterval
    var warmupRestSeconds: TimeInterval

    private let notifier: RestNotifier
    private let now: () -> Date
    private let persist: (Workout, WorkoutClock) throws -> Void
    private let previousBests: (String) throws -> ExerciseBests?
    private let saveFinished: (Workout) throws -> Void
    private let discard: () throws -> Void
    private static let log = Logger(subsystem: "com.rollins.gymrollins", category: "session")

    init(workout: Workout, clock: WorkoutClock, restSeconds: TimeInterval, warmupRestSeconds: TimeInterval,
         notifier: RestNotifier, now: @escaping () -> Date,
         persist: @escaping (Workout, WorkoutClock) throws -> Void,
         previousBests: @escaping (String) throws -> ExerciseBests?,
         saveFinished: @escaping (Workout) throws -> Void, discard: @escaping () throws -> Void) {
        self.workout = workout
        self.clock = clock
        self.restSeconds = restSeconds
        self.warmupRestSeconds = warmupRestSeconds
        self.notifier = notifier
        self.now = now
        self.persist = persist
        self.previousBests = previousBests
        self.saveFinished = saveFinished
        self.discard = discard
        self.currentEntryId = workout.entriesWithUndoneSets.first?.id ?? workout.entries.first?.id
    }

    // MARK: Clock

    func elapsed(at date: Date) -> TimeInterval { clock.elapsed(at: date) }
    var isPaused: Bool { clock.isPaused }

    func togglePause() {
        clock = clock.isPaused ? clock.resuming(at: now()) : clock.pausing(at: now())
        save()
    }

    // MARK: Logging

    func select(_ entryId: UUID) { currentEntryId = entryId }

    var currentEntry: WorkoutEntry? { workout.entries.first { $0.id == currentEntryId } }

    /// Updates the draft values of a set without completing it.
    func update(entryId: UUID, setId: UUID, weightKg: Double, reps: Int) {
        apply(workout.updatingSet(entryId: entryId, setId: setId) { $0.with(weightKg: weightKg, reps: reps) })
    }

    /// Completes the next undone set of the current entry with the given values and starts the rest timer.
    func logNextSet(weightKg: Double, reps: Int) {
        guard let entry = currentEntry, let next = entry.sets.first(where: { !$0.done }) else { return }
        let date = now()
        apply(workout.updatingSet(entryId: entry.id, setId: next.id) {
            $0.with(weightKg: weightKg, reps: reps).completing(at: date)
        })
        startRest(warmup: next.warmup, at: date)
        advanceIfComplete(entry.id)
    }

    func logAllSets() {
        guard let entry = currentEntry else { return }
        let date = now()
        let updated = entry.sets.filter { !$0.done }.reduce(workout) { w, set in
            w.updatingSet(entryId: entry.id, setId: set.id) { $0.completing(at: date) }
        }
        apply(updated)
        startRest(warmup: false, at: date)
        advanceIfComplete(entry.id)
    }

    func adjustRest(by seconds: TimeInterval) {
        guard let rest else { return }
        self.rest = rest.adjusted(by: seconds)
        notifier.schedule(endsAt: rest.adjusted(by: seconds).endsAt)
    }

    func skipRest() {
        rest = nil
        notifier.cancel()
    }

    // MARK: Editing

    func addSet(entryId: UUID) { apply(workout.appendingSet(entryId: entryId)) }

    func addWarmup(entryId: UUID, barKg: Double) {
        apply(workout.insertingWarmup(entryId: entryId, set: WorkoutSet(weightKg: barKg, reps: 10, warmup: true)))
    }

    func removeSet(entryId: UUID, setId: UUID) { apply(workout.removingSet(entryId: entryId, setId: setId)) }

    func swap(entryId: UUID, to exerciseId: String) {
        apply(workout.replacingExercise(entryId: entryId, exerciseId: exerciseId))
    }

    func setNote(entryId: UUID, note: String?) { apply(workout.settingNote(entryId: entryId, note: note)) }

    func addExercises(_ ids: [String], makeEntry: (String) -> WorkoutEntry) {
        apply(workout.appendingEntries(ids.map(makeEntry)))
        if currentEntryId == nil { currentEntryId = workout.entries.first?.id }
    }

    func removeEntry(_ entryId: UUID) {
        apply(workout.removingEntry(entryId: entryId))
        if currentEntryId == entryId { currentEntryId = workout.entriesWithUndoneSets.first?.id ?? workout.entries.first?.id }
    }

    // MARK: Finish

    func markAllDone() { apply(workout.markingAllDone(at: now())) }

    /// Saves the finished workout and returns its summary (records computed against pre-save bests).
    func finish(discardingUndone: Bool) throws -> WorkoutSummary {
        let end = clock.isPaused ? clock.resuming(at: now()) : clock
        let finished = workout.with(endedAt: nil, pausedSeconds: end.pausedSeconds)
            .finished(at: now(), discardingUndone: discardingUndone)
        let bests = try Dictionary(uniqueKeysWithValues: Set(finished.entries.map(\.exerciseId)).compactMap { id in
            try previousBests(id).map { (id, $0) }
        })
        try saveFinished(finished)
        notifier.cancel()
        rest = nil
        workout = finished
        return WorkoutSummary(workout: finished, previousBests: bests)
    }

    func discardWorkout() {
        do { try discard(); notifier.cancel() }
        catch { report("Couldn't discard the workout.", error) }
    }

    // MARK: Private

    private func apply(_ new: Workout) {
        workout = new
        save()
    }

    private func save() {
        do { try persist(workout, clock); lastError = nil }
        catch { report("Couldn't save your last change. Keep going; we'll retry.", error) }
    }

    private func startRest(warmup: Bool, at date: Date) {
        let timer = RestTimer(startedAt: date, duration: warmup ? warmupRestSeconds : restSeconds)
        rest = timer
        notifier.schedule(endsAt: timer.endsAt)
    }

    private func advanceIfComplete(_ entryId: UUID) {
        guard let entry = workout.entries.first(where: { $0.id == entryId }), entry.sets.allSatisfy(\.done) else { return }
        currentEntryId = workout.entriesWithUndoneSets.first?.id ?? entryId
    }

    private func report(_ message: String, _ error: Error) {
        Self.log.error("\(message, privacy: .public) \(error.localizedDescription, privacy: .public)")
        lastError = message
    }
}
```

Run `scripts/ios-test.sh -only-testing:GymRollinsTests/WorkoutSessionTests` → PASS. **Commit:** `feat(workout): observable workout session with persistence and rest`

---

### Task 5: Environment wiring, Today Start/Resume

**Files:** Modify `App/AppEnvironment.swift`, `Features/Today/TodayView.swift`.

- [ ] **Step 1: AppEnvironment** gains:

```swift
private(set) var session: WorkoutSession?

/// Restores an in-progress workout after relaunch.
func restoreSession() {
    do {
        guard let workout = try workouts.active(), let clock = try workouts.activeClock() else { return }
        session = makeSession(workout: workout, clock: clock)
    } catch {
        Self.log.error("Restore session failed: \(error.localizedDescription, privacy: .public)")
    }
}

func startSession(routine: Routine?) {
    let workout = routine.map {
        SessionPlanner.start(routine: $0, profile: profile, library: library, now: now(),
                             history: { [workouts] in (try? workouts.history(exerciseId: $0, limit: 5)) ?? [] })
    } ?? SessionPlanner.empty(now: now())
    let session = makeSession(workout: workout, clock: WorkoutClock(startedAt: workout.startedAt))
    do { try workouts.saveActive(workout, pausedAt: nil) }
    catch { Self.log.error("Start session save failed: \(error.localizedDescription, privacy: .public)") }
    self.session = session
}

func endSession() { session = nil }

private func makeSession(workout: Workout, clock: WorkoutClock) -> WorkoutSession {
    let repo = workouts
    return WorkoutSession(
        workout: workout, clock: clock,
        restSeconds: TimeInterval(profile.restSec), warmupRestSeconds: TimeInterval(profile.warmupRestSec),
        notifier: LaunchOptions().inMemory ? NoopRestNotifier() : UserNotificationRestNotifier(),
        now: now,
        persist: { w, c in try repo.saveActive(w.with(endedAt: nil, pausedSeconds: c.pausedSeconds), pausedAt: c.pausedAt) },
        previousBests: { try repo.bests(exerciseId: $0) },
        saveFinished: { try repo.save($0) },
        discard: { try repo.discardActive() })
}
```
Call `restoreSession()` at the end of `init`. The saveActive/clock round trip is covered by `WorkoutRepository`
(plan 02): `activeClock()` rebuilds `WorkoutClock` from `startedAt`, `pausedAt` and `pausedSeconds`.

- [ ] **Step 2: Today** — the bottom button shows **Resume Workout** (identifier `today.resume`) when
`env.session != nil`, otherwise **Start Workout** (`today.start`), which calls
`env.startSession(routine: currentRoutine)`. Keep the current routine in `@State` from `reload()`. Add a resume banner
above the list when a session exists: glass capsule "Workout in progress · <name> · <clock>" using
`TimelineView(.periodic(from: .now, by: 1))`. Present the flow with
`.fullScreenCover(item: Binding(get: { presented ? env.session : nil }, set: { if $0 == nil { presented = false } }))`
where `presented` becomes true on Start/Resume. Simplest correct implementation: a `@State var showWorkout = false`,
set it true after starting or resuming, and use `.fullScreenCover(isPresented: $showWorkout) { if let s = env.session { WorkoutFlowView(session: s) } }`.

Commit after Task 6 compiles (the cover needs `WorkoutFlowView`).

---

### Task 6: Workout screens

**Files:** Create the views listed in the file structure. **Mockups are the visual source of truth**:
`docs/design/WorkoutOverview.dc.html`, `Logging.dc.html`, `RestSettings.dc.html`, `Plates.dc.html`, `Swap.dc.html`,
`ExerciseOptions.dc.html`, `FinishConfirm.dc.html`, `Summary.dc.html`. Use DesignSystem components (`Theme`,
`PrimaryGlassButton`, `GlassPillButton`, `glassCapsule`, `glassCircle`, `SolidCard`, `SectionLabel`, `Badge`,
`BodyPartIcon`, `DisplayName`). Liquid Glass goes on controls only; content stays solid.

Required behavior and identifiers (UI tests depend on these exactly):

**WorkoutFlowView(session:)**: `NavigationStack` rooted at `WorkoutOverviewView`, with `navigationDestination` for
`LoggingView(entryId:)`. When the session's summary is set after finishing, it shows `SummaryView`.

**WorkoutOverviewView**
- Glass top bar: pause/resume circle `workout.pause` (label "Pause"/"Resume"), clock text `workout.clock`
  (`TimelineView` each second showing `DurationFormatter.clock(session.elapsed(at:))`), prominent "Finish" `workout.finish`.
- Title = workout name (display font), subtitle "<weekday day month> · N exercises".
- A solid row per entry `workout.entry.<exerciseId>` showing name, a "3 × 8 · 140 lb (63.5 kg)" style summary of the
  working sets, and a done counter "d/n" (`workout.entry.<exerciseId>.count`). The current entry has an accent border
  and an "IN PROGRESS" label. Tapping pushes Logging.
- Glass "+ Add exercise" `workout.addExercise` opens `ExercisePickerView` (reuse from plan 02). Added entries use
  `SessionPlanner.entry(for: RoutineExercise(exerciseId:, sets: 3, reps: 10, repsMin: 8), …)` with history from the env.
- A floating glass rest capsule `workout.rest` ("Rest 1:24") when `session.rest` is running, tappable to skip.
- Top-left "Close" (`workout.close`) dismisses the cover. The session keeps running (Resume on Today).

**LoggingView(entryId:)** (per the Fitbod-style mockup)
- Hero: rounded card ~260 pt with `BodyPartIcon` (size 120) centered, a small glass clock capsule
  `logging.clock` at top-left, glass circles `logging.options` (•••) and `logging.close` (✕ pops to the overview)
  at top-right, the exercise title over the bottom-left (`logging.title`, display font 34), and a glass "▶ How-To"
  capsule `logging.howto` at bottom-right (pushes `ExerciseDetailView`).
- Chip row (horizontal `ScrollView`, `GlassEffectContainer`): "2:00 rest" `logging.chip.rest` (RestSettingsSheet),
  "History" `logging.chip.history` (ExerciseHistoryView sheet), "Plate Calculator" `logging.chip.plates`
  (PlatesSheet for the active set weight), "Swap" `logging.chip.swap` (SwapSheet).
- Progression hint card (solid, success tint) built from the entry's first working set vs `history.first`:
  "Last time 3 × 10 @ 130 lb. Today 135 lb × 8." Omit it when there's no history.
- Set timeline: `SetTimelineRow` per set. A vertical line joins hexagon badges ("W" for warm-up, else the working
  index 1…n; filled white for the active set, teal check for done sets). Two big boxes: reps and weight (in the
  profile unit). They're `TextField`s with `.keyboardType(.numberPad/.decimalPad)`, identifiers
  `logging.set.<index>.reps` and `logging.set.<index>.weight` (index = 0-based position in the entry). The active
  set shows floating labels ("Warm-up Reps"/"Reps", "Weight (lb)") and a "Bar + Plates" caption under the weight
  when the exercise is a barbell. Done sets are dimmed with a check. Editing a box calls
  `session.update(entryId:setId:weightKg:reps:)` (convert the unit to kg with `UnitConverter.toKg`).
- "+ Add Set" row `logging.addSet`.
- Floating bottom bar (glass container): "Log All Sets" `logging.logAll` (glass) and "Log Set" `logging.logSet`
  (prominent, ~60% width). When all sets are done, "Log Set" becomes "Next exercise" `logging.next` (pops to the
  overview), or "Finish" if it's the last exercise.
- When `session.rest` is running, "Log Set" is replaced by a glass rest bar (`RestBar`, identifier `logging.rest`,
  showing the remaining time) with −15s `logging.rest.minus`, +15s `logging.rest.plus` and prominent Skip
  `logging.rest.skip`. When the timer reaches 0 the bar disappears and a success haptic plays
  (`.sensoryFeedback(.success, trigger:)`).

**RestSettingsSheet**: segmented Working/Warm-up; a wheel `Picker` of 0:30…5:00 in 15 s steps bound to the session
(`restSeconds` / `warmupRestSeconds`); toggles "Rest timer between sets" (`@AppStorage("restTimerEnabled")`; when
off, `startRest` isn't called, so add `var restEnabled` to `WorkoutSession`) and "Sound + haptic when rest ends"
(`@AppStorage("restSound")`). "Done" `rest.done`. The profile default changes in Settings (plan 07).

**PlatesSheet(weightKg:)**: big number in the profile unit, "<bar> <unit> bar", a plate stack drawing (rectangles
whose heights scale with plate size, heaviest innermost), a list "LOAD EACH SIDE" with "n × <plate> <unit>" rows
(`plates.side.<plate>`), and the remainder when it isn't 0 ("Can't make exactly: 2 lb short"). Uses
`PlateCalculator.load(targetKg:inventory: env.profile.plateInventory)`.

**SwapSheet(entryId:)**: current exercise card. Candidates are library exercises with the same `target`, then the
same `bodyPart`, excluding the current one, sorted by how often they've been logged (count from
`env.workouts.recent(limit: 200)`) and then by name. Each row shows the equipment and "Logged N×", with identifier
`swap.row.<id>`. There's a system search field. Tapping calls `session.swap` and dismisses.

**ExerciseOptionsSheet(entryId:)**: Notes (`TextField`, `options.note`, saves on submit/dismiss), "Add warm-up set"
`options.addWarmup` (`session.addWarmup(barKg: env.profile.barKg)`), destructive "Remove from workout"
`options.remove`, Cancel.

**FinishSheet**: presented from "Finish" when `workout.undoneSetCount > 0`. Otherwise it finishes directly.
- Title "Finish workout?"; message "N sets not done in <names>."; "Workout time mm:ss".
- Prominent "Finish and discard empty sets" `finish.discardEmpty` → `finish(discardingUndone: true)`.
- "Mark all as done" `finish.markAll` → `markAllDone()`, then `finish(discardingUndone: false)`.
- "Keep going" `finish.keepGoing` dismisses. Destructive "Discard workout" `finish.discard` → confirmation dialog →
  `discardWorkout()`, `env.endSession()`, close the cover.
- On error, show an inline message and keep the sheet open.

**SummaryView(summary:workout:)**: "WORKOUT COMPLETE" label, name (`summary.title`), date · N exercises; 2×2
stat grid: Duration `summary.duration` (`DurationFormatter.clock`), Sets `summary.sets`, Volume `summary.volume`
("7.1 t" when ≥ 1000 kg, otherwise "<n> kg"; shown in kg, which is fine for volume), Records `summary.records`. An
amber "NEW RECORDS" card with a row per record (`summary.record.<index>`): "Bench Press · rep record" with "10 reps
@ 130 lb (59 kg)", or "· est. 1RM" with "78.6 kg (173 lb), up from 70.8", or "· volume". Then per-exercise
lines. A prominent "Done" `summary.done` calls `env.endSession()` and closes the cover.

**ExerciseHistoryView(exerciseId:)**: segmented History/Trends. History lists
`env.workouts.history(exerciseId:limit: 20)` sessions (date, "3 × 10 @ 130 lb"). Trends shows a Swift Charts
`LineMark` of e1RM per session (`OneRepMax.estimate` of the best set) with `PointMark`s, plus a "Best set" card.
Identifier `history.chart`.

- [ ] **Step 1:** Implement the views to the behavior above; build with `scripts/ios-test.sh -only-testing:GymRollinsTests`
  (compile gate).
- [ ] **Step 2:** Visual check against the mockups on the simulator (`xcrun simctl io booted screenshot`). Save
  screenshots to `docs/screenshots/plan-03/` (overview, logging, rest bar, plates, finish sheet, summary).
- [ ] **Step 3: Commit** `feat(workout): workout overview, logging, rest, plates, swap, options, finish, summary, history`

---

### Task 7: End-to-end UI tests

**Files:** Create `GymRollinsUITests/WorkoutFlowUITests.swift`.

- [ ] **Step 1: Tests**

```swift
import XCTest

final class WorkoutFlowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-seedHistory", "-fixedNow", "2026-09-26T09:00:00Z"] + extra
        app.launch()
        return app
    }

    func testFullWorkoutWithRestPlatesAndRecords() {
        let app = launch()
        app.buttons["today.start"].tap()
        XCTAssertTrue(app.staticTexts["workout.clock"].waitForExistence(timeout: 5))
        app.buttons["workout.entry.0025"].tap()
        XCTAssertEqual(app.staticTexts["logging.title"].label, "Barbell Bench Press")

        // Warm-up 1 logged -> rest bar appears with a warm-up duration
        app.buttons["logging.logSet"].tap()
        XCTAssertTrue(app.otherElements["logging.rest"].waitForExistence(timeout: 3) ||
                      app.staticTexts["logging.rest"].waitForExistence(timeout: 1))
        app.buttons["logging.rest.skip"].tap()

        // Plate calculator for the 135 lb working weight: 45 lb bar + one 45 lb plate each side
        app.buttons["logging.chip.plates"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["plates.side.45"].waitForExistence(timeout: 3))
        app.swipeDown()

        // Beat last session: 10 reps at 135 on every working set -> records
        for index in 2...4 {
            let reps = app.textFields["logging.set.\(index).reps"]
            reps.tap(); reps.clearAndType("10")
        }
        app.buttons["logging.logAll"].tap()
        app.buttons["logging.next"].tap()

        app.buttons["workout.finish"].tap()
        XCTAssertTrue(app.buttons["finish.discardEmpty"].waitForExistence(timeout: 3))
        app.buttons["finish.discardEmpty"].tap()

        XCTAssertTrue(app.staticTexts["summary.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["summary.sets"].label, "3")
        XCTAssertTrue(app.descendants(matching: .any)["summary.record.0"].exists)
        app.buttons["summary.done"].tap()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))
    }

    func testResumeAfterRelaunch() {
        var app = launch(["-diskStore", "-resetStore"])
        app.buttons["today.start"].tap()
        app.buttons["workout.entry.0025"].tap()
        app.buttons["logging.logSet"].tap()
        app.terminate()

        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-diskStore", "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launch()
        XCTAssertTrue(app.buttons["today.resume"].waitForExistence(timeout: 5))
        app.buttons["today.resume"].tap()
        XCTAssertEqual(app.staticTexts["workout.entry.0025.count"].label, "1/5")
    }

    func testSwapAndAddExerciseAndDiscard() {
        let app = launch()
        app.buttons["today.start"].tap()
        app.buttons["workout.entry.0070"].tap()
        app.buttons["logging.chip.swap"].tap()
        let firstCandidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'swap.row.'")).firstMatch
        XCTAssertTrue(firstCandidate.waitForExistence(timeout: 3))
        firstCandidate.tap()
        app.buttons["logging.close"].tap()
        XCTAssertFalse(app.buttons["workout.entry.0070"].exists)

        app.buttons["workout.addExercise"].tap()
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("chest dip")
        app.buttons["picker.row.0251"].tap()
        app.buttons["picker.add"].tap()
        XCTAssertTrue(app.buttons["workout.entry.0251"].waitForExistence(timeout: 3))

        app.buttons["workout.finish"].tap()
        app.buttons["finish.discard"].tap()
        app.buttons["Discard"].tap() // confirmation dialog
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))
    }
}

extension XCUIElement {
    func clearAndType(_ text: String) {
        let current = (value as? String) ?? ""
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
}
```
The 135 lb working weight comes from seeded history (19 Sep 3×10 @130 lb → double progression +5 lb). Warm-ups are
45 × 10 and 100 × 5, so the working sets are entry indices 2, 3 and 4. Resume count "1/5" = 1 of 5 sets done
(2 warm-ups + 3 working).

- [ ] **Step 2:** `scripts/ios-test.sh` → all unit + UI tests pass. Fix flakiness with `waitForExistence`, never
  with sleeps.
- [ ] **Step 3: Commit** `test(e2e): workout flow, resume after relaunch, swap/add/discard`

---

### Task 8: Verify, review, merge

- [ ] `scripts/test-all.sh` green; `swiftlint lint --quiet` has 0 errors.
- [ ] `codex review --base main > /tmp/codex-plan03.txt` (no custom prompt with `--base`); fix P0/P1/P2 findings
  test-first.
- [ ] Merge: `git checkout main && git merge --no-ff plan-03-workout-flow -m "merge: plan 03 workout flow"`, then delete the branch.
