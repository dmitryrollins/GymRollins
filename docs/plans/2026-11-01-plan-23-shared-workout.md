# Plan 23: Shared workouts

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two people do the same workout on one day, each on their own phone with their own weights. One sends it by QR code
or link, and the other opens it and uses it as today's plan.

**Architecture:** `SharedWorkout` in GymCore is the only code that knows the link's format. The app turns a workout into
`SharedWorkout.Source` values on Today, the Build result and the running workout, and shows a QR code and a link. An incoming
link becomes a `.built` `TodayPlan` with every item pinned and no weights, so `SessionPlanner` plans it from that phone's
history. Nothing in this feature uses the network, the database or `GymSync`.

**Tech stack:** Swift 6.2, SwiftUI, Core Image, Vision (tests only), Swift Testing, XCUITest, static HTML with a Node test.

**Spec:** `docs/specs/2026-11-01-shared-workout-design.md`.

**Branch:** `feat-shared-workout`, stacked on `feat-gym-moderation`. No push. Supabase stays local and isn't used here.
Commit messages have no `Co-Authored-By`, `Generated with` or `Claude-Session` trailers: the owner forbids them.

---

## Decisions this plan makes

1. **The incoming sheet is presented with UIKit, from the top view controller.** The spec says it opens over whatever is on
   screen, and a workout runs in a `.fullScreenCover`. A `.sheet` on `RootView` can't appear above that. A small coordinator
   finds the top controller and presents a `UIHostingController`, and waits while an alert or system sheet is up.
2. **Today hears about the new plan through a notification,** `.todayPlanReplaced`, like its existing day-change `.onReceive`.
   `AppEnvironment.swift` is at 399 lines, and `planChanged()` would also schedule a sync, though no synced data changed.
   `.resumeWorkoutRequested` works the same way.
3. **"This replaces today's plan" shows only when something would be lost:** a plan with exercises that's edited, switched
   or built. A plain rest-day suggestion comes back by itself, so it gets no warning.
4. **A running workout's sets have no rep range,** so its link carries the first working set's reps as a single number.
5. **The link's id rule also catches custom exercises.** An id must be 1 to 8 ASCII letters or digits, so `custom-*` is left
   out by the same check that reads incoming links. A test proves every id in the real library passes.
6. **No test for `https://` opening the app:** it needs the domain, the signed entitlement and a real iPhone (spec section 10).

## File map

| File | Change |
|---|---|
| `ios/Packages/GymCore/Sources/GymCore/SharedWorkout/SharedWorkout.swift` | Create: types, `routineItems` |
| `ios/Packages/GymCore/Sources/GymCore/SharedWorkout/SharedWorkout+Sending.swift` | Create: `Source`, `Draft`, `make(from:)` |
| `ios/Packages/GymCore/Sources/GymCore/SharedWorkout/SharedWorkout+Link.swift` | Create: `linkText`, `decode` |
| `ios/Packages/GymCore/Tests/GymCoreTests/SharedWorkout/SharedWorkoutTests.swift` | Create |
| `ios/project.yml`, `ios/Config/Base.xcconfig` | URL scheme, `SHARE_LINK_HOST` |
| `ios/GymRollins/Features/SharedWorkout/WorkoutLink.swift` | Create |
| `ios/GymRollins/Features/SharedWorkout/QRCodeImage.swift` | Create |
| `ios/GymRollins/Features/SharedWorkout/ShareWorkoutModel.swift` | Create |
| `ios/GymRollins/Features/SharedWorkout/ShareWorkoutSheet.swift` | Create: sheet and `ShareWorkoutButton` |
| `ios/GymRollins/Features/SharedWorkout/IncomingWorkoutScreen.swift` | Create: what the sheet shows |
| `ios/GymRollins/Features/SharedWorkout/IncomingWorkoutSheet.swift` | Create |
| `ios/GymRollins/Features/SharedWorkout/IncomingWorkoutCoordinator.swift` | Create: waits for onboarding, presents |
| `ios/GymRollins/App/AppEnvironment+SharedWorkout.swift` | Create |
| `ios/GymRollins/App/RootView.swift` | Receive links |
| `ios/GymRollins/Features/Today/TodayPlan.swift` | `shared(items:day:)`, `shareSources` |
| `ios/GymRollins/Features/Today/TodayView.swift` | Share button, two `.onReceive` |
| `ios/GymRollins/Features/Gyms/BuildResultView.swift`, `ios/GymRollins/Features/Workout/WorkoutOverviewView.swift` | Share button |
| `ios/GymRollins/Features/Settings/PrivacyPolicyView.swift` | One sentence |
| `web/share/` | Create: page, script, Apple's domain file template, Node test |
| `ios/GymRollinsTests/WorkoutLinkTests.swift`, `QRCodeImageTests.swift`, `ShareWorkoutModelTests.swift`, `TodayPlanSharedTests.swift`, `IncomingWorkoutScreenTests.swift` | Create |
| `ios/GymRollinsUITests/SharedWorkoutUITests.swift` | Create |
| `ios/GymRollinsUITests/AccessibilityAuditUITests.swift`, `DynamicTypeUITests.swift` | Add tests |
| `scripts/test-all.sh`, `README.md` | Test row, feature sentence |

## How to run things

**GymCore:** `cd ios/Packages/GymCore && swift test --filter SharedWorkoutTests`

**One app test class** (run from `ios/`, one `xcodebuild` at a time; the Mac runs short on memory, so if it sits at 0% CPU for
15 minutes, kill only your own and retry once):

```bash
xcodegen generate --quiet
xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' \
  -only-testing:GymRollinsTests/WorkoutLinkTests \
  -resultBundlePath build/TestResults-one-$(date +%s).xcresult -quiet
xcrun xcresulttool get test-results summary --path "$(ls -td build/TestResults-one-*.xcresult | head -1)"
```

Use only that destination: on the iOS 26.4 preview runtime, History and Swap sheets don't open, even on `main`. Change
`-only-testing` for other classes (`GymRollinsUITests/SharedWorkoutUITests`, and so on). A UI test file needs
`xcodegen generate` first, because the project is generated.

---

### Task 1: `SharedWorkout` in GymCore

**Files:**
- Create: `ios/Packages/GymCore/Sources/GymCore/SharedWorkout/SharedWorkout.swift`
- Create: `ios/Packages/GymCore/Sources/GymCore/SharedWorkout/SharedWorkout+Sending.swift`
- Create: `ios/Packages/GymCore/Sources/GymCore/SharedWorkout/SharedWorkout+Link.swift`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/SharedWorkout/SharedWorkoutTests.swift`

- [x] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import GymCore

@Suite struct SharedWorkoutTests {
    private func item(_ id: String, sets: Int = 3, _ target: SharedWorkout.Target = .reps(min: nil, max: 10),
                      superset: Int? = nil) -> SharedWorkout.Item {
        SharedWorkout.Item(exerciseId: id, sets: sets, target: target, superset: superset)
    }

    private func decode(_ text: String) -> SharedWorkout.Decoded { SharedWorkout.decode(text) { _ in true } }

    private func set(_ reps: Int = 8, weight: Double = 63.5, sec: Int? = nil, minutes: Double? = nil,
                     warmup: Bool = false) -> WorkoutSet {
        WorkoutSet(weightKg: weight, reps: reps, sec: sec, minutes: minutes, warmup: warmup)
    }

    // MARK: The text

    @Test func writesTheSpecsFormat() {
        let workout = SharedWorkout(items: [
            item("0001", .reps(min: 8, max: 10)),
            item("1512", superset: 1),
            item("0201", .reps(min: nil, max: 12), superset: 1),
            item("0300", sets: 1, .seconds(600)),
        ])
        #expect(workout.linkText == "1.0001_3_8-10.1512_3_10_g1.0201_3_12_g1.0300_1_s600")
    }

    @Test func roundTrips() {
        let workout = SharedWorkout(items: [
            item("0001", .reps(min: 8, max: 10)),
            item("ABCDEFGH", sets: 10, .reps(min: nil, max: 100), superset: 2),
            item("7", sets: 1, .seconds(5)),
            item("0300", sets: 1, .seconds(3600)),
        ])
        #expect(decode(workout.linkText) == .valid(workout, droppedUnknown: 0))
    }

    @Test(arguments: [
        "", "1", "1.", "1..0001_3_10", "1.0001_3_10.", ".0001_3_10", "abc.0001_3_10", "0.0001_3_10", "01.0001_3_10",
        "1.0001_3", "1.0001", "1.0001_3_10_g1_x", "1.0001_0_10", "1.0001_11_10", "1.0001_03_10", "1.0001_+3_10",
        "1.0001_3_0", "1.0001_3_101", "1.0001_3_10-8", "1.0001_3_8-10-12", "1.0001_3_-10", "1.0001_3_8-",
        "1.0001_3_s4", "1.0001_3_s3601", "1.0001_3_s", "1.0001_3_10_g0", "1.0001_3_10_g21", "1.0001_3_10_x1",
        "1.0001_3_10_g", "1.custom-1_3_10", "1.ABCDEFGHI_3_10", "1._3_10", "1.\u{00FF}_3_10", "1.0001_3_\u{0661}\u{0660}",
        "1.0001_3_10 ", "1.0001%5F3%5F10",
    ])
    func refusesBrokenText(text: String) {
        #expect(decode(text) == .damaged)
    }

    @Test(arguments: ["1.0001_1_1", "1.0001_10_100", "1.0001_3_s5", "1.0001_3_s3600", "1.0001_3_8-8", "1.0001_3_10_g20",
                      "1.ABCDEFGH_3_10"])
    func acceptsTheLimits(text: String) {
        guard case let .valid(workout, dropped) = decode(text) else {
            Issue.record("\(text) should be valid")
            return
        }
        #expect(workout.items.count == 1)
        #expect(dropped == 0)
    }

    @Test func refusesTooLongBeforeReadingIt() {
        #expect(decode("1." + String(repeating: "0", count: SharedWorkout.maxLinkLength)) == .damaged)
    }

    @Test func refusesMoreThanARoutinesExercises() {
        let fields = { (count: Int) in (0..<count).map { _ in "0001_3_10" }.joined(separator: ".") }
        guard case let .valid(workout, _) = decode("1." + fields(DomainLimits.routineExercisesMax)) else {
            Issue.record("20 exercises should be valid")
            return
        }
        #expect(workout.items.count == DomainLimits.routineExercisesMax)
        #expect(decode("1." + fields(DomainLimits.routineExercisesMax + 1)) == .damaged)
    }

    @Test(arguments: ["2", "2.anything", "999.0001_3_10"])
    func newerVersionsAreTooNew(text: String) {
        #expect(decode(text) == .tooNew)
    }

    @Test func dropsAndCountsUnknownExercises() {
        let decoded = SharedWorkout.decode("1.0001_3_10.9999_3_10.0002_3_10") { $0 != "9999" }
        #expect(decoded == .valid(SharedWorkout(items: [item("0001"), item("0002")]), droppedUnknown: 1))
    }

    @Test func allUnknownIsDamaged() {
        #expect(SharedWorkout.decode("1.0001_3_10") { _ in false } == .damaged)
    }

    @Test func randomTextNeverCrashesAndAnythingValidRoundTrips() {
        var generator = SeededGenerator(seed: 23)
        let alphabet = Array("0123456789_-.gsABC \u{00FF}%#")
        for _ in 0..<5_000 {
            let length = Int.random(in: 0...40, using: &generator)
            let text = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
            if case let .valid(workout, _) = decode(text) {
                #expect(decode(workout.linkText) == .valid(workout, droppedUnknown: 0))
            }
        }
    }

    // MARK: Sending

    @Test func clampsValuesSoASenderCanAlwaysShare() {
        let sources = [
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0001", sets: 15, reps: 500)),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0002", sets: 0, reps: 0)),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0003", sets: 3, reps: 5, repsMin: 8)),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0004", sets: 3, reps: 1, sec: 1, mode: .time)),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0005", sets: 3, reps: 1, sec: 9_000, mode: .cardio)),
        ]
        let workout = SharedWorkout.make(from: sources).workout
        #expect(workout?.items == [
            item("0001", sets: 10, .reps(min: nil, max: 100)),
            item("0002", sets: 1, .reps(min: nil, max: 1)),
            item("0003", .reps(min: nil, max: 5)),
            item("0004", .seconds(5)),
            item("0005", .seconds(3600)),
        ])
    }

    @Test func keepsTheFirstTwentyAndCountsTheRest() {
        let sources = (0..<23).map { SharedWorkout.Source(item: RoutineExercise(exerciseId: "\($0)", sets: 3, reps: 10)) }
        let draft = SharedWorkout.make(from: sources)
        #expect(draft.workout?.items.map(\.exerciseId) == (0..<20).map { "\($0)" })
        #expect(draft.cutOffCount == 3)
    }

    @Test func leavesCustomExercisesOutAndNamesThem() {
        let draft = SharedWorkout.make(from: [
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "custom-abc", sets: 3, reps: 10)),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0001", sets: 3, reps: 10)),
        ])
        #expect(draft.workout?.items.map(\.exerciseId) == ["0001"])
        #expect(draft.leftOutIds == ["custom-abc"])
    }

    @Test func onlyCustomExercisesLeavesNothingToSend() {
        let draft = SharedWorkout.make(from: [
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "custom-abc", sets: 3, reps: 10)),
        ])
        #expect(draft.workout == nil)
        #expect(draft.leftOutIds == ["custom-abc"])
    }

    @Test func renumbersSupersetsAndNeverSendsTheLabel() {
        let draft = SharedWorkout.make(from: [
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0001", sets: 3, reps: 10, supersetGroup: "call-me")),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0002", sets: 3, reps: 10)),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0003", sets: 3, reps: 10, supersetGroup: "z")),
            SharedWorkout.Source(item: RoutineExercise(exerciseId: "0004", sets: 3, reps: 10, supersetGroup: "call-me")),
        ])
        #expect(draft.workout?.items.map(\.superset) == [1, nil, 2, 1])
        #expect(draft.workout?.linkText.contains("call-me") == false)
    }

    @Test func noWeightOrWarmUpEverReachesTheText() throws {
        let entry = WorkoutEntry(exerciseId: "0025", sets: [
            set(5, weight: 20, warmup: true), set(8, weight: 63.5), set(8, weight: 63.5), set(8, weight: 63.5),
        ])
        let source = try #require(SharedWorkout.Source(entry: entry))
        let text = try #require(SharedWorkout.make(from: [source]).workout?.linkText)
        #expect(text == "1.0025_3_8")
    }

    @Test func routineItemsCarryTheirWeightsNowhere() {
        let source = SharedWorkout.Source(item: RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, repsMin: 8,
                                                                 weightKg: 63.5, weightSetAt: .now))
        let items = SharedWorkout.make(from: [source]).workout?.routineItems { _ in .reps } ?? []
        #expect(items.map(\.weightKg) == [nil])
        #expect(items.map(\.weightSetAt) == [nil])
        #expect(items.map(\.repsMin) == [8])
        #expect(items.map(\.reps) == [10])
    }

    @Test func editedSetsUseTheWorkingCountAndTheFirstSet() throws {
        let source = try #require(SharedWorkout.Source(exerciseId: "0001", group: "A", sets: [
            set(12, warmup: true), set(10), set(6),
        ]))
        #expect(source == SharedWorkout.Source(exerciseId: "0001", sets: 2, target: .reps(min: nil, max: 10), group: "A"))
    }

    @Test func onlyWarmUpsMeansNoSource() {
        #expect(SharedWorkout.Source(exerciseId: "0001", group: nil, sets: [set(warmup: true)]) == nil)
    }

    @Test func timedAndCardioSetsBecomeSeconds() throws {
        let timed = try #require(SharedWorkout.Source(exerciseId: "0001", group: nil, sets: [set(sec: 45)]))
        #expect(timed.target == .seconds(45))
        let cardio = try #require(SharedWorkout.Source(exerciseId: "0002", group: nil, sets: [set(minutes: 10)]))
        #expect(cardio.target == .seconds(600))
    }

    @Test func secondsBecomeCardioOnlyWhenTheLibrarySaysSo() {
        let workout = SharedWorkout(items: [item("0001", .seconds(60)), item("0002", .seconds(600)), item("0003")])
        let items = workout.routineItems { $0 == "0002" ? .cardio : .reps }
        #expect(items.map(\.mode) == [.time, .cardio, .reps])
        #expect(items.map(\.sec) == [60, 600, nil])
    }

    @Test func supersetsStayTogetherOnThePhone() {
        let workout = SharedWorkout(items: [item("0001", superset: 1), item("0002", superset: 1), item("0003", superset: 2)])
        let groups = workout.routineItems { _ in .reps }.map(\.supersetGroup)
        #expect(groups[0] != nil)
        #expect(groups[0] == groups[1])
        #expect(groups[1] != groups[2])
    }
}

/// A small repeatable generator, so a failure in the random test can be reproduced.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
```

- [x] **Step 2: Run them and see them fail**

Run: `cd ios/Packages/GymCore && swift test --filter SharedWorkoutTests`
Expected: FAIL to compile, "cannot find 'SharedWorkout' in scope".

- [x] **Step 3: Write `SharedWorkout.swift`**

```swift
import Foundation

/// One day's workout as it travels between two phones (docs/specs/2026-11-01-shared-workout-design.md): library exercise
/// ids and numbers only. No weights, warm-ups, rest, names or other text, so each phone plans it from its own history and a
/// link can't put a stranger's words in the app.
public struct SharedWorkout: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// `min` is nil for a single rep count.
        case reps(min: Int?, max: Int)
        case seconds(Int)
    }

    public struct Item: Equatable, Sendable {
        public let exerciseId: String
        public let sets: Int
        public let target: Target
        /// Numbered from 1 in order of appearance, never the sender's own label.
        public let superset: Int?

        public init(exerciseId: String, sets: Int, target: Target, superset: Int? = nil) {
            self.exerciseId = exerciseId
            self.sets = sets
            self.target = target
            self.superset = superset
        }
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    /// The routine items a phone plans this from. They carry no weight, so `SessionPlanner` takes it from that phone's
    /// history. `mode` is the exercise's mode in that phone's library.
    public func routineItems(mode: (String) -> ExerciseMode?) -> [RoutineExercise] {
        items.map { item in
            let group = item.superset.map { "S\($0)" }
            switch item.target {
            case let .reps(low, high):
                return RoutineExercise(exerciseId: item.exerciseId, sets: item.sets, reps: high, repsMin: low,
                                       mode: .reps, supersetGroup: group)
            case let .seconds(seconds):
                return RoutineExercise(exerciseId: item.exerciseId, sets: item.sets, reps: 1, sec: seconds,
                                       mode: mode(item.exerciseId) == .cardio ? .cardio : .time, supersetGroup: group)
            }
        }
    }

    /// 1 to 8 ASCII letters or digits. Every library id fits; `custom-*` doesn't.
    static func isShareableId<S: StringProtocol>(_ id: S) -> Bool {
        (1...8).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
    }
}
```

- [x] **Step 4: Write `SharedWorkout+Sending.swift`**

```swift
import Foundation

public extension SharedWorkout {
    /// What one exercise on the sender's phone contributes, before limits and numbering.
    struct Source: Equatable, Sendable {
        public let exerciseId: String
        public let sets: Int
        public let target: Target
        public let group: String?

        public init(exerciseId: String, sets: Int, target: Target, group: String?) {
            self.exerciseId = exerciseId
            self.sets = sets
            self.target = target
            self.group = group
        }

        public init(item: RoutineExercise) {
            let seconds = item.mode == .reps ? nil : item.sec
            self.init(exerciseId: item.exerciseId, sets: item.sets,
                      target: seconds.map(Target.seconds) ?? .reps(min: item.repsMin, max: item.reps),
                      group: item.supersetGroup)
        }

        /// Edited or running sets: the number of working sets and the first one's target. Nil with no working sets.
        public init?(exerciseId: String, group: String?, sets: [WorkoutSet]) {
            let working = sets.filter { !$0.warmup }
            guard let first = working.first else { return nil }
            let target: Target
            if let sec = first.sec {
                target = .seconds(sec)
            } else if let minutes = first.minutes, minutes.isFinite {
                target = .seconds(Int(min(max(minutes, 0), 60) * 60))
            } else {
                target = .reps(min: nil, max: first.reps)
            }
            self.init(exerciseId: exerciseId, sets: working.count, target: target, group: group)
        }

        public init?(entry: WorkoutEntry) {
            self.init(exerciseId: entry.exerciseId, group: entry.supersetGroup, sets: entry.sets)
        }
    }

    /// What can go in a link, and what can't.
    struct Draft: Equatable, Sendable {
        /// Nil when nothing can go.
        public let workout: SharedWorkout?
        /// Exercises that aren't in the shared library, such as custom ones.
        public let leftOutIds: [String]
        /// Exercises past `DomainLimits.routineExercisesMax`.
        public let cutOffCount: Int
    }

    /// Applies the limits (values are clamped, so a sender can always share) and numbers the supersets.
    static func make(from sources: [Source]) -> Draft {
        let shareable = sources.filter { isShareableId($0.exerciseId) }
        let kept = Array(shareable.prefix(DomainLimits.routineExercisesMax))
        let numbers = kept.compactMap(\.group).reduce(into: [String: Int]()) { numbers, group in
            if numbers[group] == nil { numbers[group] = numbers.count + 1 }
        }
        let items = kept.map { source in
            Item(exerciseId: source.exerciseId, sets: clamp(source.sets, to: PlanChangeLimits.sets),
                 target: limited(source.target), superset: source.group.flatMap { numbers[$0] })
        }
        return Draft(workout: items.isEmpty ? nil : SharedWorkout(items: items),
                     leftOutIds: sources.map(\.exerciseId).filter { !isShareableId($0) },
                     cutOffCount: shareable.count - kept.count)
    }

    private static func limited(_ target: Target) -> Target {
        switch target {
        case let .reps(low, high):
            let top = clamp(high, to: PlanChangeLimits.reps)
            let bottom = low.map { clamp($0, to: PlanChangeLimits.reps.lowerBound...top) }
            return .reps(min: bottom == top ? nil : bottom, max: top)
        case let .seconds(seconds):
            return .seconds(clamp(seconds, to: PlanChangeLimits.sec))
        }
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
```

- [x] **Step 5: Write `SharedWorkout+Link.swift`**

```swift
import Foundation

/// The text after the link's `#`: `1.0001_3_8-10.1512_3_10_g1.0300_1_s600`. The first field is the version, then one field
/// per exercise: id, sets, target (`10`, `8-10` or `s600`), and an optional superset (`g1`). Only letters, digits and `_ - .`,
/// so chat apps keep it in the link.
public extension SharedWorkout {
    static let linkVersion = 1
    static let maxLinkLength = 1024

    enum Decoded: Equatable, Sendable {
        case valid(SharedWorkout, droppedUnknown: Int)
        case damaged
        case tooNew
    }

    var linkText: String {
        ([String(Self.linkVersion)] + items.map(Self.field)).joined(separator: ".")
    }

    /// The link is untrusted: any broken syntax or value outside the limits makes the whole of it damaged. An exercise this
    /// phone doesn't have is only dropped and counted, because a newer app can have exercises an older one lacks.
    static func decode(_ text: String, isKnown: (String) -> Bool) -> Decoded {
        guard text.utf8.count <= maxLinkLength else { return .damaged }
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = fields.first, let version = number(first), version >= 1 else { return .damaged }
        guard version == linkVersion else { return .tooNew }
        let itemFields = fields.dropFirst()
        guard (1...DomainLimits.routineExercisesMax).contains(itemFields.count) else { return .damaged }
        let parsed = itemFields.map(item)
        guard parsed.allSatisfy({ $0 != nil }) else { return .damaged }
        let all = parsed.compactMap { $0 }
        let known = all.filter { isKnown($0.exerciseId) }
        guard !known.isEmpty else { return .damaged }
        return .valid(SharedWorkout(items: known), droppedUnknown: all.count - known.count)
    }

    private static func field(_ item: Item) -> String {
        let target: String
        switch item.target {
        case .reps(let low?, let high): target = "\(low)-\(high)"
        case .reps(nil, let high): target = "\(high)"
        case let .seconds(seconds): target = "s\(seconds)"
        }
        let parts = [item.exerciseId, "\(item.sets)", target] + (item.superset.map { ["g\($0)"] } ?? [])
        return parts.joined(separator: "_")
    }

    private static func item(_ field: Substring) -> Item? {
        let parts = field.split(separator: "_", omittingEmptySubsequences: false)
        guard (3...4).contains(parts.count), isShareableId(parts[0]),
              let sets = number(parts[1]), PlanChangeLimits.sets.contains(sets),
              let target = target(parts[2]) else { return nil }
        let exerciseId = String(parts[0])
        guard parts.count == 4 else { return Item(exerciseId: exerciseId, sets: sets, target: target) }
        guard parts[3].hasPrefix("g"), let superset = number(parts[3].dropFirst()),
              (1...DomainLimits.routineExercisesMax).contains(superset) else { return nil }
        return Item(exerciseId: exerciseId, sets: sets, target: target, superset: superset)
    }

    private static func target(_ text: Substring) -> Target? {
        if text.hasPrefix("s") {
            guard let seconds = number(text.dropFirst()), PlanChangeLimits.sec.contains(seconds) else { return nil }
            return .seconds(seconds)
        }
        let bounds = text.split(separator: "-", omittingEmptySubsequences: false).map(number)
        switch bounds.count {
        case 1:
            guard let reps = bounds[0], PlanChangeLimits.reps.contains(reps) else { return nil }
            return .reps(min: nil, max: reps)
        case 2:
            guard let low = bounds[0], let high = bounds[1], PlanChangeLimits.reps.contains(low),
                  PlanChangeLimits.reps.contains(high), low <= high else { return nil }
            return .reps(min: low, max: high)
        default:
            return nil
        }
    }

    /// ASCII digits only, in their shortest form, so each value has one spelling.
    private static func number(_ text: Substring) -> Int? {
        let bytes = Array(text.utf8)
        guard (1...6).contains(bytes.count), bytes.allSatisfy({ (48...57).contains($0) }),
              bytes.count == 1 || bytes[0] != 48 else { return nil }
        return Int(text)
    }
}
```

- [x] **Step 6: Run them and see them pass**

Run: `cd ios/Packages/GymCore && swift test --filter SharedWorkoutTests`
Expected: PASS, all tests. Fix the code, not the tests. If a test looks wrong, say which and why in your report.

- [x] **Step 7: Check the coverage gate**

Run: `scripts/coverage-gymcore.sh`
Expected: `Line coverage: ...% (threshold 90%)`, exit 0. All three new files appear near 100%.

- [x] **Step 8: Commit**

```bash
git add ios/Packages/GymCore/Sources/GymCore/SharedWorkout ios/Packages/GymCore/Tests/GymCoreTests/SharedWorkout
git commit -m "feat(core): a workout as link text, with no weights or free text"
```

---

### Task 2: The link

**Files:**
- Modify: `ios/project.yml` (the app target's `info.properties`), `ios/Config/Base.xcconfig`
- Create: `ios/GymRollins/Features/SharedWorkout/WorkoutLink.swift`
- Test: `ios/GymRollinsTests/WorkoutLinkTests.swift`

- [x] **Step 1: Write the failing test**

```swift
import Foundation
import GymCore
import Testing
@testable import GymRollins

@Suite struct WorkoutLinkTests {
    private let workout = SharedWorkout(items: [SharedWorkout.Item(exerciseId: "0025", sets: 3,
                                                                    target: .reps(min: 8, max: 10))])
    private let web = WorkoutLink(host: "gym.example")
    private let noHost = WorkoutLink(host: nil)

    @Test func makesAnAppLinkWithNoHost() {
        #expect(noHost.url(for: workout)?.absoluteString == "gymrollins://w#1.0025_3_8-10")
    }

    @Test func makesAWebLinkWithAHost() {
        #expect(web.url(for: workout)?.absoluteString == "https://gym.example/w#1.0025_3_8-10")
    }

    @Test(arguments: ["", "   "])
    func aBlankHostMeansNone(host: String) {
        #expect(WorkoutLink(host: host) == noHost)
    }

    /// The setting and the scheme reach the app. It doesn't pin the value: the owner sets it once the domain exists.
    @Test func theSettingAndTheSchemeReachTheApp() throws {
        let host = try #require(Bundle.main.object(forInfoDictionaryKey: "SHARE_LINK_HOST") as? String)
        #expect(!host.contains("$("))
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        #expect(types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains(WorkoutLink.scheme) == true })
    }

    @Test(arguments: ["gymrollins://w#1.0025_3_10", "GYMROLLINS://w#1.0025_3_10", "https://gym.example/w#1.0025_3_10",
                      "https://gym.example/w/#1.0025_3_10", "https://GYM.example/w#1.0025_3_10"])
    func readsBothKinds(text: String) throws {
        #expect(web.payload(in: try #require(URL(string: text))) == "1.0025_3_10")
    }

    @Test func aBuildWithNoHostStillReadsAppLinks() throws {
        #expect(noHost.payload(in: try #require(URL(string: "gymrollins://w#1.0025_3_10"))) == "1.0025_3_10")
    }

    @Test(arguments: ["https://evil.example/w#1.0025_3_10", "https://gym.example.evil.example/w#1.0025_3_10",
                      "http://gym.example/w#1.0025_3_10", "https://gym.example/x#1.0025_3_10",
                      "https://gym.example/w/x#1.0025_3_10", "https://gym.example/w", "gymrollins://x#1.0025_3_10",
                      "gymrollins://w/x#1.0025_3_10", "gymrollins://w", "other://w#1.0025_3_10",
                      "https://me@gym.example/w#1.0025_3_10", "https://gym.example:8443/w#1.0025_3_10",
                      "https://gym.example/w?a=1#1.0025_3_10"])
    func refusesEverythingElse(text: String) throws {
        #expect(web.payload(in: try #require(URL(string: text))) == nil)
    }

    @Test func aBuildWithNoHostRefusesEveryWebLink() throws {
        #expect(noHost.payload(in: try #require(URL(string: "https://gym.example/w#1.0025_3_10"))) == nil)
    }
}
```

- [x] **Step 2: Add the URL scheme and the setting**

In `ios/project.yml`, under the `GymRollins` target's `info.properties`, right after `PHOTO_HOSTING: $(PHOTO_HOSTING)`:

```yaml
        # The domain workout links use (Config/Base.xcconfig). Empty: they use the gymrollins scheme below.
        SHARE_LINK_HOST: $(SHARE_LINK_HOST)
        CFBundleURLTypes:
          - CFBundleURLName: com.rollins.gymrollins.workout-link
            CFBundleURLSchemes: [gymrollins]
```

In `ios/Config/Base.xcconfig`, right after `PHOTO_HOSTING = bundle`:

```
// The domain for workout links (docs/specs/2026-11-01-shared-workout-design.md, section 10). Empty until it's bought: the
// app makes gymrollins:// links. Set it here once it exists, without a scheme, e.g. gym.example. The app reads both kinds.
SHARE_LINK_HOST =
```

- [x] **Step 3: Run it and see it fail**

Run the one-class command with `-only-testing:GymRollinsTests/WorkoutLinkTests`.
Expected: compile error, "cannot find 'WorkoutLink' in scope".

- [x] **Step 4: Write `WorkoutLink.swift`**

```swift
import Foundation
import GymCore

/// Where a workout link points. With no host the app makes `gymrollins://w#…`, and with one `https://<host>/w#…`. It reads
/// both, so links sent before the domain existed keep working. The workout sits after the `#`, which browsers don't send
/// to the website.
struct WorkoutLink: Equatable {
    static let scheme = "gymrollins"
    private static let appLinkHost = "w"

    let host: String?

    init(host: String?) {
        let trimmed = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.host = trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    /// This build's link, from `SHARE_LINK_HOST` in `Config/Base.xcconfig`.
    static var configured: WorkoutLink {
        WorkoutLink(host: Bundle.main.object(forInfoDictionaryKey: "SHARE_LINK_HOST") as? String)
    }

    func url(for workout: SharedWorkout) -> URL? {
        let start = host.map { "https://\($0)/w" } ?? "\(Self.scheme)://\(Self.appLinkHost)"
        return URL(string: "\(start)#\(workout.linkText)")
    }

    /// The text after the `#`, or nil when `url` isn't a workout link this build accepts.
    func payload(in url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.port == nil, parts.query == nil,
              let fragment = parts.percentEncodedFragment, !fragment.isEmpty else { return nil }
        switch parts.scheme?.lowercased() {
        case Self.scheme:
            return parts.host == Self.appLinkHost && parts.path.isEmpty ? fragment : nil
        case "https":
            guard let host, parts.host?.lowercased() == host, parts.path == "/w" || parts.path == "/w/" else { return nil }
            return fragment
        default:
            return nil
        }
    }
}
```

- [x] **Step 5: Run it and see it pass**

Run the one-class command with `-only-testing:GymRollinsTests/WorkoutLinkTests`.
Expected: `'result': 'Passed'`, no failures.

- [x] **Step 6: Commit**

```bash
git add ios/project.yml ios/Config/Base.xcconfig ios/GymRollins/Features/SharedWorkout/WorkoutLink.swift ios/GymRollinsTests/WorkoutLinkTests.swift
git commit -m "feat(workouts): workout links, on an app scheme until the domain exists"
```

---

### Task 3: The share screen

**Files:**
- Create: `ios/GymRollins/Features/SharedWorkout/QRCodeImage.swift`, `ShareWorkoutModel.swift`, `ShareWorkoutSheet.swift`
- Test: `ios/GymRollinsTests/QRCodeImageTests.swift`, `ios/GymRollinsTests/ShareWorkoutModelTests.swift`

- [x] **Step 1: Write the failing tests**

`QRCodeImageTests.swift`:

```swift
import CoreGraphics
import Testing
import Vision
@testable import GymRollins

/// A code that can't be read is no use, so these read it back with Vision.
@Suite struct QRCodeImageTests {
    private func read(_ image: CGImage) throws -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        #if targetEnvironment(simulator)
        // The simulator's GPU can't create Vision's inference context ("Could not create inference context").
        let cpu = try request.supportedComputeStageDevices[.main]?.first { if case .cpu = $0 { true } else { false } }
        if let cpu { try request.setComputeDevice(cpu, for: .main) }
        #endif
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results?.first?.payloadStringValue
    }

    @Test func aShortLinkReadsBack() throws {
        let link = "gymrollins://w#1.0025_3_8-10"
        #expect(try read(try #require(QRCodeImage.make(link))) == link)
    }

    /// The longest workout a link can hold: 20 exercises with the longest id and every optional field.
    @Test func theLongestLinkReadsBack() throws {
        let fields = (1...20).map { "ABCDEFGH_10_99-100_g\($0)" }.joined(separator: ".")
        let link = "https://a-long-domain-name.example/w#1.\(fields)"
        #expect(try read(try #require(QRCodeImage.make(link))) == link)
    }
}
```

`ShareWorkoutModelTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@Suite struct ShareWorkoutModelTests {
    private let library = ExerciseLibrary(exercises: [
        Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
        Exercise(id: "custom-1", name: "sled push", bodyPart: "upper legs", equipment: "other", target: "quads", isCustom: true),
    ])
    private let link = WorkoutLink(host: nil)

    private func source(_ id: String) -> SharedWorkout.Source {
        SharedWorkout.Source(item: RoutineExercise(exerciseId: id, sets: 3, reps: 10))
    }

    @Test func makesALinkAndACode() {
        let model = ShareWorkoutModel.make(sources: [source("0025")], library: library, link: link)
        #expect(model.url?.absoluteString == "gymrollins://w#1.0025_3_10")
        #expect(model.qrCode != nil)
        #expect(model.leftOutNotice == nil)
        #expect(model.cutOffNotice == nil)
        #expect(!model.nothingToSend)
    }

    @Test func namesWhatIsLeftOut() {
        let model = ShareWorkoutModel.make(sources: [source("0025"), source("custom-1")], library: library, link: link)
        #expect(model.url?.absoluteString == "gymrollins://w#1.0025_3_10")
        #expect(model.leftOutNotice == "Left out, because it's your own exercise: Sled Push")
    }

    @Test func aPluralNotice() {
        let library = ExerciseLibrary(exercises: [
            Exercise(id: "0025", name: "bench", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
            Exercise(id: "custom-1", name: "sled push", bodyPart: "back", equipment: "other", target: "lats", isCustom: true),
            Exercise(id: "custom-2", name: "rope pull", bodyPart: "back", equipment: "other", target: "lats", isCustom: true),
        ])
        let model = ShareWorkoutModel.make(sources: [source("0025"), source("custom-1"), source("custom-2")],
                                           library: library, link: link)
        #expect(model.leftOutNotice == "Left out, because they're your own exercises: Sled Push, Rope Pull")
    }

    @Test func onlyCustomExercisesLeaveNothingToSend() {
        let model = ShareWorkoutModel.make(sources: [source("custom-1")], library: library, link: link)
        #expect(model.nothingToSend)
        #expect(model.url == nil)
        #expect(model.qrCode == nil)
    }

    @Test func saysWhenOnlyTheFirstTwentyWent() {
        let sources = (0..<21).map { source(String(format: "%04d", $0)) }
        let model = ShareWorkoutModel.make(sources: sources, library: library, link: link)
        #expect(model.cutOffNotice == "Only the first 20 exercises are in this link.")
    }

    /// Decision 5: a library exercise that can't go in a link would vanish from a shared workout without explanation.
    @Test func everyRealLibraryExerciseCanBeShared() throws {
        let url = try #require(Bundle.main.url(forResource: "exercises", withExtension: "json"))
        let real = try ExerciseLibrary.load(from: url)
        let draft = SharedWorkout.make(from: real.exercises.map { source($0.id) })
        #expect(draft.leftOutIds.isEmpty)
    }
}
```

`DisplayName.of` capitalizes a stored name. Check its output for `"sled push"` against the expected `"Sled Push"` when this runs, and correct the two expected strings if its rule differs. Don't change `DisplayName`.

- [x] **Step 2: Run them and see them fail**

Run the one-class command with `-only-testing:GymRollinsTests/QRCodeImageTests -only-testing:GymRollinsTests/ShareWorkoutModelTests`.
Expected: compile error, "cannot find 'QRCodeImage' in scope".

- [x] **Step 3: Write `QRCodeImage.swift`**

```swift
import CoreImage
import CoreImage.CIFilterBuiltins

/// A QR code for a link: correction level M, dark on white with its quiet zone, scaled by a whole number so the edges stay
/// sharp.
enum QRCodeImage {
    private static let quietZoneModules: CGFloat = 4

    static func make(_ text: String, side: CGFloat = 1024) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let canvas = code.extent.insetBy(dx: -quietZoneModules, dy: -quietZoneModules)
        let withQuietZone = code.composited(over: CIImage(color: .white).cropped(to: canvas))
        let scale = (side / canvas.width).rounded(.down)
        guard scale >= 1 else { return nil }
        let scaled = withQuietZone.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
```

- [x] **Step 4: Write `ShareWorkoutModel.swift`**

```swift
import CoreGraphics
import Foundation
import GymCore
import GymData

/// What the share screen shows for one workout.
struct ShareWorkoutModel: Identifiable {
    let id = UUID()
    let url: URL?
    let qrCode: CGImage?
    let leftOutNotice: String?
    let cutOffNotice: String?

    var nothingToSend: Bool { url == nil }

    static func make(sources: [SharedWorkout.Source], library: ExerciseLibrary, link: WorkoutLink) -> ShareWorkoutModel {
        let draft = SharedWorkout.make(from: sources)
        let url = draft.workout.flatMap(link.url(for:))
        let names = draft.leftOutIds.map { DisplayName.of(library.exercise($0)?.name ?? $0) }
        return ShareWorkoutModel(url: url, qrCode: url.flatMap { QRCodeImage.make($0.absoluteString) },
                                 leftOutNotice: leftOutNotice(names, nothingLeft: url == nil),
                                 cutOffNotice: draft.cutOffCount > 0
                                     ? "Only the first \(DomainLimits.routineExercisesMax) exercises are in this link." : nil)
    }

    private static func leftOutNotice(_ names: [String], nothingLeft: Bool) -> String? {
        guard !names.isEmpty, !nothingLeft else { return nil }
        let list = names.joined(separator: ", ")
        return names.count == 1 ? "Left out, because it's your own exercise: \(list)"
            : "Left out, because they're your own exercises: \(list)"
    }
}
```

- [x] **Step 5: Write `ShareWorkoutSheet.swift`**

```swift
import GymCore
import SwiftUI

/// "Share workout": a button that makes its link when tapped, so it always sends the workout as it is now.
struct ShareWorkoutButton: View {
    @Environment(AppEnvironment.self) private var env
    let identifier: String
    let sources: () -> [SharedWorkout.Source]
    @State private var model: ShareWorkoutModel?

    var body: some View {
        SecondaryGlassButton(title: "Share workout", identifier: identifier) {
            model = ShareWorkoutModel.make(sources: sources(), library: env.library, link: .configured)
        }
        .sheet(item: $model) { ShareWorkoutSheet(model: $0) }
    }
}

/// The QR code and "Send link" (spec section 6).
struct ShareWorkoutSheet: View {
    let model: ShareWorkoutModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DisplayTitle(text: "Share workout", size: 34).accessibilityAddTraits(.isHeader)
                    if let url = model.url { sharing(url) } else { nothing }
                    if let notice = model.cutOffNotice { line(notice, identifier: "share.cutOff") }
                    if let notice = model.leftOutNotice { line(notice, identifier: "share.leftOut") }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("share.done")
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func sharing(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let code = model.qrCode {
                Image(code, scale: 1, label: Text("QR code for this workout"))
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("share.qr")
            }
            ShareLink(item: url) {
                Label("Send link", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("share.send")
            line("Your partner sees this workout with their own weights.", identifier: "share.note")
        }
    }

    private var nothing: some View {
        line("These are your own exercises, so they can't go in a link.", identifier: "share.nothing")
    }

    private func line(_ text: String, identifier: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }
}
```

- [x] **Step 6: Run them and see them pass**

Run the one-class command with `-only-testing:GymRollinsTests/QRCodeImageTests -only-testing:GymRollinsTests/ShareWorkoutModelTests`.
Expected: `'result': 'Passed'`.

- [x] **Step 7: Commit**

```bash
git add ios/GymRollins/Features/SharedWorkout ios/GymRollinsTests/QRCodeImageTests.swift ios/GymRollinsTests/ShareWorkoutModelTests.swift
git commit -m "feat(workouts): share screen with a QR code and a link"
```

---

### Task 4: Share from Today, the Build result and the running workout

**Files:**
- Modify: `ios/GymRollins/Features/Today/TodayPlan.swift` (next to `built`), `ios/GymRollins/Features/Today/TodayView.swift`
- Modify: `ios/GymRollins/Features/Gyms/BuildResultView.swift`, `ios/GymRollins/Features/Workout/WorkoutOverviewView.swift`
- Test: `ios/GymRollinsTests/TodayPlanSharedTests.swift`, `ios/GymRollinsUITests/SharedWorkoutUITests.swift`

- [x] **Step 1: Write the failing tests**

`TodayPlanSharedTests.swift`:

```swift
import Foundation
import GymCore
import Testing
@testable import GymRollins

@Suite struct TodayPlanSharedTests {
    private let day = "2026-11-01"
    private static let kinds = ["barbell", "dumbbells"].map {
        EquipmentKind(id: $0, name: $0, category: .freeWeight, load: .none)
    }
    private static let exercises = [
        Exercise(id: "bb", name: "bb", bodyPart: "chest", equipment: "barbell", target: "pectorals", secondary: ["triceps"]),
        Exercise(id: "db", name: "db", bodyPart: "chest", equipment: "dumbbell", target: "pectorals", secondary: ["triceps"]),
    ]
    private static let requirements = ExerciseRequirements(groups: ["bb": [["barbell"]], "db": [["dumbbells"]]])

    /// A gym with dumbbells and no barbell: normally `bb` would be swapped for `db` here.
    private var dumbbellGym: GymAdapter {
        let listing = InventoryListing(id: UUID(), kindId: "dumbbells")
        let matcher = InventoryMatcher(requirements: Self.requirements, kinds: Self.kinds,
                                       inventory: GymInventory(gymName: "Gym", listings: [listing]))
        return GymAdapter(matcher: matcher, exercises: Self.exercises)
    }

    private let item = RoutineExercise(exerciseId: "bb", sets: 3, reps: 10, repsMin: 8)

    @Test func isABuiltPlanNamedSharedWorkout() {
        let plan = TodayPlan.shared(items: [item], day: day)
        #expect(plan.kind == .built)
        #expect(plan.title == "Shared workout")
        #expect(plan.exercises == [item])
        #expect(plan.day == day)
        #expect(plan.routineToStart?.name == "Shared workout")
    }

    @Test func theGymCantSwapItsExercises() {
        let plan = TodayPlan.shared(items: [item], day: day).adapted(by: dumbbellGym)
        #expect(plan.exercises.map(\.exerciseId) == ["bb"])
        #expect(plan.gymSwaps.isEmpty)
    }

    @Test func aWithoutPinsControl() {
        let plan = TodayPlan.built(name: "Built", items: [item], day: day).adapted(by: dumbbellGym)
        #expect(plan.exercises.map(\.exerciseId) == ["db"])
    }

    @Test func survivesAReloadWithItsPins() throws {
        let plan = TodayPlan.shared(items: [item], day: day)
        let data = try JSONEncoder().encode(plan)
        let loaded = try JSONDecoder().decode(TodayPlan.self, from: data)
        #expect(loaded == plan)
        #expect(loaded.gymPinned == [item.id])
    }

    @Test func shareSourcesFollowEditedSets() {
        let edited = RoutineExercise(exerciseId: "db", sets: 3, reps: 10)
        let plan = TodayPlan.built(name: "Built", items: [item, edited], day: day)
            .editingSets(edited.id, [WorkoutSet(weightKg: 20, reps: 15, warmup: true), WorkoutSet(weightKg: 30, reps: 6),
                                     WorkoutSet(weightKg: 30, reps: 5)])
        #expect(plan.shareSources == [
            SharedWorkout.Source(exerciseId: "bb", sets: 3, target: .reps(min: 8, max: 10), group: nil),
            SharedWorkout.Source(exerciseId: "db", sets: 2, target: .reps(min: nil, max: 6), group: nil),
        ])
    }
}
```

`SharedWorkoutUITests.swift`:

```swift
import XCTest

/// Workout links opened the way iOS opens them (`XCUIApplication.open`), and the Share button on each screen.
@MainActor
final class SharedWorkoutUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    /// Scrolls until `button` can take a touch, then taps it.
    private func scrollAndTap(_ app: XCUIApplication, _ button: XCUIElement, file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertTrue(button.waitForExistence(timeout: 10), "missing \(button)", file: file, line: line)
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable, "\(button) can't be reached", file: file, line: line)
        button.tap()
    }

    private func expectShareScreen(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.images["share.qr"].waitForExistence(timeout: 10), "no QR code", file: file, line: line)
        XCTAssertTrue(element(app, "share.send").exists, "no Send link", file: file, line: line)
        XCTAssertEqual(app.staticTexts["share.note"].label, "Your partner sees this workout with their own weights.",
                       file: file, line: line)
        app.buttons["share.done"].tap()
        XCTAssertTrue(app.images["share.qr"].waitForNonExistence(timeout: 5), "the sheet didn't close",
                      file: file, line: line)
    }

    func testShareFromToday() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        scrollAndTap(app, app.buttons["today.share"])
        expectShareScreen(app)
    }

    func testShareFromTheBuildResult() {
        let app = XCUIApplication.launchReady(["-seedGym"]) { $0.buttons["today.gymChip"] }
        app.buttons["today.build"].tapCenter()
        XCTAssertTrue(app.buttons["build.go"].waitForExistence(timeout: 5))
        // The sheet remembers the last chips and length, so set them.
        for chip in ["chest", "back", "shoulders", "arms", "legs", "core"] {
            let button = app.buttons["build.chip.\(chip)"]
            if button.isSelected != (chip == "back") { button.tap() }
        }
        app.buttons["build.length.60"].tap()
        app.buttons["build.go"].tapCenter()
        XCTAssertTrue(element(app, "build.title").waitForExistence(timeout: 10))
        scrollAndTap(app, app.buttons["build.share"])
        expectShareScreen(app)
    }

    func testShareFromTheRunningWorkout() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.startWorkout()
        scrollAndTap(app, app.buttons["workout.share"])
        expectShareScreen(app)
    }
}
```

- [x] **Step 2: Run them and see them fail**

Run the one-class command with `-only-testing:GymRollinsTests/TodayPlanSharedTests`.
Expected: compile error, "type 'TodayPlan' has no member 'shared'".

- [x] **Step 3: Add `shared` and `shareSources` to `TodayPlan.swift`**

Right after `static func built(...)`:

```swift
    /// A workout someone shared by link. Every item is pinned, so the gym rules can't swap what was sent, and the items
    /// carry no weight, so they're planned from this phone's history.
    static func shared(items: [RoutineExercise], day: String) -> TodayPlan {
        TodayPlan(day: day, kind: .built, base: nil, exercises: items, edited: !items.isEmpty,
                  gymPinned: Set(items.map(\.id)), builtName: "Shared workout")
    }

    /// Today's exercises as shown, for a workout link: an exercise with edited sets uses those sets.
    var shareSources: [SharedWorkout.Source] {
        exercises.map { item in
            sets(for: item.id).flatMap { SharedWorkout.Source(exerciseId: item.exerciseId, group: item.supersetGroup, sets: $0) }
                ?? SharedWorkout.Source(item: item)
        }
    }
```

- [x] **Step 4: Run them and see them pass**

Run the one-class command with `-only-testing:GymRollinsTests/TodayPlanSharedTests`.
Expected: `'result': 'Passed'`.

- [x] **Step 5: Add the three buttons**

`TodayView.swift`, inside `if env.session == nil { ... }` after the save button:

```swift
                    if env.session == nil {
                        addExerciseRow
                        if plan?.canSaveToRoutine == true { saveToRoutineButton }
                        if let plan, !plan.exercises.isEmpty {
                            ShareWorkoutButton(identifier: "today.share") { plan.shareSources }
                        }
                    }
```

`BuildResultView.swift`, in `content(_:)` after `ForEach(model.rows) { row($0) }`:

```swift
            if !model.isEmpty, let built = run.built {
                ShareWorkoutButton(identifier: "build.share") { built.items.map { SharedWorkout.Source(item: $0.exercise) } }
            }
```

`WorkoutOverviewView.swift`, after `addExerciseButton`:

```swift
                if !session.workout.entries.isEmpty {
                    ShareWorkoutButton(identifier: "workout.share") {
                        session.workout.entries.compactMap(SharedWorkout.Source.init(entry:))
                    }
                }
```

- [x] **Step 6: Run the UI tests and the screens' existing suites**

Run the one-class command with `-only-testing:GymRollinsUITests/SharedWorkoutUITests -only-testing:GymRollinsUITests/BuildWorkoutUITests -only-testing:GymRollinsUITests/TodayFlexUITests -only-testing:GymRollinsUITests/WorkoutFlowUITests`.
Expected: `'result': 'Passed'`. The new button pushes content down, so an existing test that scrolls to something may need another swipe. Change only that, and say which.

- [x] **Step 7: Commit**

```bash
git add ios/GymRollins/Features/Today ios/GymRollins/Features/Gyms/BuildResultView.swift ios/GymRollins/Features/Workout/WorkoutOverviewView.swift ios/GymRollinsTests/TodayPlanSharedTests.swift ios/GymRollinsUITests/SharedWorkoutUITests.swift
git commit -m "feat(workouts): share from Today, the Build result and the running workout"
```

---

### Task 5: Opening a link

**Files:**
- Create: `ios/GymRollins/Features/SharedWorkout/IncomingWorkoutScreen.swift`, `IncomingWorkoutSheet.swift`, `IncomingWorkoutCoordinator.swift`
- Create: `ios/GymRollins/App/AppEnvironment+SharedWorkout.swift`
- Modify: `ios/GymRollins/App/RootView.swift`, `ios/GymRollins/Features/Today/TodayView.swift`
- Test: `ios/GymRollinsTests/IncomingWorkoutScreenTests.swift`, `ios/GymRollinsUITests/SharedWorkoutUITests.swift`

- [x] **Step 1: Write the failing unit tests**

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@Suite struct IncomingWorkoutScreenTests {
    private let library = ExerciseLibrary(exercises: [
        Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
        Exercise(id: "0251", name: "chest dip", bodyPart: "chest", equipment: "body weight", target: "pectorals"),
    ])
    private let day = "2026-11-01"
    private let benchLink = URL(string: "gymrollins://w#1.0025_3_8-10")!

    private func screen(_ url: URL, running: Bool = false, current: TodayPlan? = nil,
                        history: @escaping (String) -> [SessionResult] = { _ in [] }) -> IncomingWorkoutScreen {
        IncomingWorkoutScreen.make(url: url, link: WorkoutLink(host: nil), library: library, profile: Profile(), day: day,
                                   isWorkoutRunning: running, currentPlan: current, history: history, gym: nil)
    }

    private func preview(_ url: URL, current: TodayPlan? = nil,
                         history: @escaping (String) -> [SessionResult] = { _ in [] }) throws -> IncomingWorkoutScreen.Preview {
        guard case let .preview(preview) = screen(url, current: current, history: history) else {
            throw Failure.notAPreview
        }
        return preview
    }

    private enum Failure: Error { case notAPreview }

    private func kg(_ pounds: Double) -> Double { UnitConverter.toKg(pounds, from: .lb) }

    /// Spec criterion 1: the same link, two people, each with their own weight.
    @Test func eachPersonSeesTheirOwnWeight() throws {
        let heavy = try preview(benchLink) { _ in [SessionResult(date: .now, weightKg: kg(140), reps: [8, 8, 8])] }
        let light = try preview(benchLink) { _ in [SessionResult(date: .now, weightKg: kg(95), reps: [8, 8, 8])] }
        #expect(heavy.rows[0].row.subtitle.contains("140 lb"))
        #expect(light.rows[0].row.subtitle.contains("95 lb"))
        #expect(!light.rows[0].row.subtitle.contains("140"))
    }

    /// Spec criterion 2.
    @Test func aNewExerciseSaysSetOnFirstSet() throws {
        let shown = try preview(benchLink)
        #expect(shown.rows[0].note == "Set on first set")
    }

    @Test func aKnownExerciseHasNoNote() throws {
        let shown = try preview(benchLink) { _ in [SessionResult(date: .now, weightKg: kg(95), reps: [8, 8, 8])] }
        #expect(shown.rows[0].note == nil)
    }

    @Test func bodyweightHasNoNote() throws {
        let shown = try preview(URL(string: "gymrollins://w#1.0251_3_10")!)
        #expect(shown.rows[0].note == nil)
    }

    @Test func thePlanCarriesNoWeightAndPinsItsItems() throws {
        let plan = try preview(benchLink).plan
        #expect(plan.exercises.map(\.weightKg) == [nil])
        #expect(plan.gymPinned == Set(plan.exercises.map(\.id)))
        #expect(plan.day == day)
    }

    @Test func countsTheExercises() throws {
        #expect(try preview(benchLink).countText == "1 exercise")
        #expect(try preview(URL(string: "gymrollins://w#1.0025_3_10.0251_3_10")!).countText == "2 exercises")
    }

    @Test func saysHowManyWereDropped() throws {
        #expect(try preview(benchLink).droppedNotice == nil)
        #expect(try preview(URL(string: "gymrollins://w#1.0025_3_10.ZZZZ_3_10")!).droppedNotice
            == "1 exercise isn't in your version of the app.")
        #expect(try preview(URL(string: "gymrollins://w#1.0025_3_10.ZZZZ_3_10.YYYY_3_10")!).droppedNotice
            == "2 exercises aren't in your version of the app.")
    }

    @Test(arguments: ["gymrollins://w#nonsense", "gymrollins://w#1.0025_99_10", "gymrollins://w#1.ZZZZ_3_10",
                      "https://evil.example/w#1.0025_3_10", "gymrollins://x#1.0025_3_10", "gymrollins://w"])
    func damagedLinksSayDamaged(text: String) throws {
        #expect(screen(try #require(URL(string: text))) == .damaged)
    }

    @Test func aNewerLinkAsksForAnUpdate() {
        #expect(screen(URL(string: "gymrollins://w#2.anything")!) == .tooNew)
    }

    /// Spec criterion 7.
    @Test func aRunningWorkoutChangesNothing() {
        #expect(screen(benchLink, running: true) == .workoutRunning)
    }

    @Test func aDamagedLinkDuringAWorkoutStillSaysDamaged() {
        #expect(screen(URL(string: "gymrollins://w#nonsense")!, running: true) == .damaged)
    }

    // MARK: "This replaces today's plan"

    private let routine = Routine(name: "Push", exercises: [RoutineExercise(exerciseId: "0025", sets: 3, reps: 10)])

    @Test func aPlainScheduledPlanNeedsNoWarning() throws {
        let plan = TodayPlan.make(scheduled: routine, routines: [routine], lastDone: [:], day: day)
        #expect(try !preview(benchLink, current: plan).replacesToday)
    }

    @Test func noPlanNeedsNoWarning() throws {
        #expect(try !preview(benchLink).replacesToday)
    }

    @Test func aBuiltPlanIsWarnedAbout() throws {
        let plan = TodayPlan.built(name: "Built", items: routine.exercises, day: day)
        #expect(try preview(benchLink, current: plan).replacesToday)
    }

    @Test func anEditedPlanIsWarnedAbout() throws {
        let plan = TodayPlan.make(scheduled: routine, routines: [routine], lastDone: [:], day: day)
            .adding([RoutineExercise(exerciseId: "0251", sets: 3, reps: 10)])
        #expect(try preview(benchLink, current: plan).replacesToday)
    }

    @Test func aSwitchedPlanIsWarnedAbout() throws {
        let plan = TodayPlan.make(scheduled: nil, routines: [routine], lastDone: [:], day: day).switched(to: routine)
        #expect(try preview(benchLink, current: plan).replacesToday)
    }
}

/// `useSharedWorkout` on a real environment: today's plan, the next day and a running workout.
@MainActor
@Suite struct UseSharedWorkoutTests {
    private func environment() throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: "UseSharedWorkoutTests.\(UUID())"))
        return try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]),
                                  defaults: defaults)
    }

    private func plan(_ env: AppEnvironment) -> TodayPlan {
        TodayPlan.shared(items: [RoutineExercise(exerciseId: "0025", sets: 3, reps: 10)], day: TodayPlan.dayKey(env.now()))
    }

    @Test func becomesTodaysPlan() throws {
        let env = try environment()
        #expect(env.useSharedWorkout(plan(env)))
        #expect(try env.todaysPlan().plan.title == "Shared workout")
    }

    /// Spec criterion 4.
    @Test func theNormalPlanIsBackTheNextDayAndRoutinesDontChange() throws {
        let env = try environment()
        let before = try env.routines.all()
        #expect(env.useSharedWorkout(plan(env)))
        let tomorrow = env.now().addingTimeInterval(24 * 60 * 60)
        #expect(try env.todaysPlan(at: tomorrow).plan.title != "Shared workout")
        #expect(try env.routines.all() == before)
    }

    /// The sheet was open when a workout started on the watch.
    @Test func refusedWhileAWorkoutRuns() throws {
        let env = try environment()
        env.startSession(routine: nil)
        let before = try env.todaysPlan().plan
        #expect(!env.useSharedWorkout(plan(env)))
        #expect(try env.todaysPlan().plan == before)
    }
}
```

- [x] **Step 2: Run them and see them fail**

Run the one-class command with `-only-testing:GymRollinsTests/IncomingWorkoutScreenTests -only-testing:GymRollinsTests/UseSharedWorkoutTests`.
Expected: compile error, "cannot find 'IncomingWorkoutScreen' in scope".

- [x] **Step 3: Write `IncomingWorkoutScreen.swift`**

```swift
import Foundation
import GymCore
import GymData

/// What opening a workout link shows (spec sections 5 and 7). Pure: everything it needs is passed in.
enum IncomingWorkoutScreen: Equatable {
    case preview(Preview)
    case damaged
    case tooNew
    case workoutRunning

    struct Preview: Equatable {
        /// What Use for today applies.
        let plan: TodayPlan
        let countText: String
        let rows: [Row]
        let droppedNotice: String?
        let replacesToday: Bool
    }

    struct Row: Equatable, Identifiable {
        /// The same row Today will show, in this person's weights and units.
        let row: TodayModel.Row
        let note: String?
        var id: UUID { row.id }
    }

    private static let bodyweightEquipment = "body weight"

    static func make(url: URL, link: WorkoutLink, library: ExerciseLibrary, profile: Profile, day: String,
                     isWorkoutRunning: Bool, currentPlan: TodayPlan?, history: (String) -> [SessionResult],
                     gym: TodayGymContext?) -> IncomingWorkoutScreen {
        guard let payload = link.payload(in: url) else { return .damaged }
        switch SharedWorkout.decode(payload, isKnown: { library.exercise($0) != nil }) {
        case .damaged:
            return .damaged
        case .tooNew:
            return .tooNew
        case let .valid(workout, dropped):
            if isWorkoutRunning { return .workoutRunning }
            let items = workout.routineItems { library.exercise($0)?.mode }
            let plan = TodayPlan.shared(items: items, day: day)
            let model = TodayModel.make(plan: plan, profile: profile, library: library, history: history, gym: gym,
                                        loads: { gym?.loads(for: $0) })
            let rows = model.rows.map { Row(row: $0, note: note(for: $0, exercise: library.exercise($0.exerciseId))) }
            return .preview(Preview(plan: plan, countText: count(rows.count), rows: rows,
                                    droppedNotice: droppedNotice(dropped), replacesToday: replacesSomething(currentPlan)))
        }
    }

    private static func count(_ count: Int) -> String { count == 1 ? "1 exercise" : "\(count) exercises" }

    private static func note(for row: TodayModel.Row, exercise: Exercise?) -> String? {
        guard (row.suggestedKg ?? 0) == 0, let exercise, exercise.mode == .reps,
              exercise.equipment != bodyweightEquipment else { return nil }
        return "Set on first set"
    }

    private static func droppedNotice(_ dropped: Int) -> String? {
        switch dropped {
        case 0: nil
        case 1: "1 exercise isn't in your version of the app."
        default: "\(dropped) exercises aren't in your version of the app."
        }
    }

    /// Decision 3: only when something would be lost. A plain plan comes back by itself.
    private static func replacesSomething(_ plan: TodayPlan?) -> Bool {
        guard let plan, !plan.exercises.isEmpty else { return false }
        return plan.edited || !plan.setOverrides.isEmpty || plan.restSec != nil || plan.kind == .switched
            || plan.kind == .built
    }
}
```

`TodayGymContext` must be usable from a non-`@MainActor` function. If the compiler objects, match how `TodayModel.make` takes it.

- [x] **Step 4: Write `AppEnvironment+SharedWorkout.swift`**

```swift
import Foundation

extension Notification.Name {
    /// Today's plan was replaced from outside Today: Today reloads.
    static let todayPlanReplaced = Notification.Name("gymrollins.todayPlanReplaced")
    /// The incoming sheet's Resume: Today opens the running workout.
    static let resumeWorkoutRequested = Notification.Name("gymrollins.resumeWorkoutRequested")
}

/// Workout links (docs/specs/2026-11-01-shared-workout-design.md).
extension AppEnvironment {
    func incomingWorkoutScreen(url: URL) -> IncomingWorkoutScreen {
        let currentPlan: TodayPlan?
        do {
            currentPlan = try todaysPlan().plan
        } catch {
            Self.log.error("Reading today's plan for a workout link failed: \(error.localizedDescription, privacy: .public)")
            currentPlan = nil
        }
        return IncomingWorkoutScreen.make(url: url, link: .configured, library: library, profile: profile,
                                          day: TodayPlan.dayKey(now()), isWorkoutRunning: session != nil,
                                          currentPlan: currentPlan,
                                          history: { [workouts] in (try? workouts.history(exerciseId: $0, limit: 5)) ?? [] },
                                          gym: todayGymContext())
    }

    /// Makes `plan` today's plan. False, with nothing changed, when a workout started meanwhile (the watch).
    func useSharedWorkout(_ plan: TodayPlan) -> Bool {
        guard session == nil else { return false }
        todayPlanStore.save(plan)
        NotificationCenter.default.post(name: .todayPlanReplaced, object: nil)
        return true
    }
}
```

- [x] **Step 5: Run the unit tests and see them pass**

Run the one-class command with `-only-testing:GymRollinsTests/IncomingWorkoutScreenTests -only-testing:GymRollinsTests/UseSharedWorkoutTests`.
Expected: `'result': 'Passed'`.

- [x] **Step 6: Add the failing UI tests**

Add to `SharedWorkoutUITests`:

```swift
    private let benchAndCurl = URL(string: "gymrollins://w#1.0025_3_8-10.0313_3_10")!

    private func opened(_ url: URL) -> XCUIApplication {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.open(url)
        return app
    }

    /// Spec criteria 1 and 5: their own weights on the sheet, then on Today and in the workout.
    func testALinkBecomesTodaysPlan() {
        let app = opened(benchAndCurl)
        XCTAssertTrue(app.buttons["incoming.use"].waitForExistence(timeout: 10), "the sheet didn't open")
        XCTAssertEqual(app.staticTexts["incoming.count"].label, "2 exercises")
        XCTAssertTrue(element(app, "incoming.row.0025").label.contains("lb"), element(app, "incoming.row.0025").label)
        app.buttons["incoming.use"].tapCenter()
        XCTAssertTrue(app.buttons["incoming.use"].waitForNonExistence(timeout: 5))
        let summary = app.staticTexts["today.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        let shared = NSPredicate(format: "label CONTAINS 'Shared workout'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: shared, object: summary)], timeout: 5),
                       .completed, summary.label)
        app.startWorkout()
        XCTAssertTrue(app.buttons["workout.entry.0025"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workout.entry.0313"].exists)
        XCTAssertFalse(app.buttons["workout.entry.0194"].exists, "the seeded routine's triceps exercise is still there")
    }

    func testNotNowLeavesTodayAlone() {
        let app = opened(benchAndCurl)
        let before = app.staticTexts["today.summary"].label
        XCTAssertTrue(app.buttons["incoming.notNow"].waitForExistence(timeout: 10))
        app.buttons["incoming.notNow"].tapCenter()
        XCTAssertTrue(app.buttons["incoming.notNow"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["today.summary"].label, before)
    }

    /// Spec criterion 2.
    func testANewExerciseSaysSetOnFirstSet() {
        let app = XCUIApplication.launchReady(["-emptyStore", "-skipOnboarding"]) { $0.staticTexts["today.summary"] }
        app.open(benchAndCurl)
        let row = element(app, "incoming.row.0025")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Set on first set"), row.label)
    }

    /// Spec criterion 6.
    func testADamagedLinkSaysSoAndChangesNothing() {
        let app = opened(URL(string: "gymrollins://w#nonsense")!)
        let message = app.staticTexts["incoming.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertEqual(message.label, "This link doesn't work. Ask for a new one.")
        XCTAssertFalse(app.buttons["incoming.use"].exists)
        app.buttons["incoming.close"].tapCenter()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["today.summary"].label.contains("Shared workout"))
    }

    func testANewerLinkAsksForAnUpdate() {
        let app = opened(URL(string: "gymrollins://w#2.anything")!)
        let message = app.staticTexts["incoming.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertEqual(message.label, "Update GymRollins to open this workout.")
    }

    func testSaysWhenAnExerciseIsMissing() {
        let app = opened(URL(string: "gymrollins://w#1.0025_3_10.ZZZZ_3_10")!)
        let notice = app.staticTexts["incoming.dropped"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(notice.label, "1 exercise isn't in your version of the app.")
    }

    /// Spec criterion 7. The sheet opens over the full-screen workout, and Resume goes back to it.
    func testALinkDuringAWorkoutChangesNothing() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.startWorkout()
        app.open(benchAndCurl)
        let message = app.staticTexts["incoming.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10), "the sheet didn't open over the workout")
        XCTAssertEqual(message.label, "Finish your current workout first.")
        app.buttons["incoming.resume"].tapCenter()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["workout.clock"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workout.entry.0194"].waitForExistence(timeout: 5), "the workout changed")
    }

    /// Resume from Today, where the workout's closed: it opens.
    func testResumeOpensAClosedWorkout() {
        let app = XCUIApplication.launchReady(["-seedHistory"]) { $0.buttons["today.start"] }
        app.startWorkout()
        app.buttons["workout.close"].tap()
        XCTAssertTrue(element(app, "today.resumeBanner").waitForExistence(timeout: 5))
        app.open(benchAndCurl)
        XCTAssertTrue(app.buttons["incoming.resume"].waitForExistence(timeout: 10))
        app.buttons["incoming.resume"].tapCenter()
        XCTAssertTrue(app.staticTexts["workout.clock"].waitForExistence(timeout: 5), "the workout didn't open")
    }

    func testASecondLinkReplacesTheFirst() {
        let app = opened(benchAndCurl)
        XCTAssertTrue(element(app, "incoming.row.0313").waitForExistence(timeout: 10))
        app.open(URL(string: "gymrollins://w#1.0194_3_10")!)
        XCTAssertTrue(element(app, "incoming.row.0194").waitForExistence(timeout: 10), "the second link didn't show")
        XCTAssertFalse(element(app, "incoming.row.0313").exists)
    }

    /// A first-time partner finishes onboarding, then sees the workout.
    func testALinkWaitsForOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-onboarding", "-fixedNow", XCUIApplication.fixedNow]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.skip"].waitForExistence(timeout: 10))
        app.open(benchAndCurl)
        XCTAssertFalse(app.buttons["incoming.use"].waitForExistence(timeout: 3), "the sheet opened over onboarding")
        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(app.buttons["setup.continue"].waitForExistence(timeout: 5))
        let bodyweight = app.textFields["setup.bodyweight"]
        bodyweight.tap()
        bodyweight.typeText("180")
        app.dismissKeyboardIfPresent()
        app.buttons["setup.continue"].tap()
        XCTAssertTrue(app.buttons["import.skip"].waitForExistence(timeout: 5))
        app.buttons["import.skip"].tap()
        XCTAssertTrue(app.buttons["incoming.use"].waitForExistence(timeout: 10), "the sheet didn't open after onboarding")
    }
```

Check `testSkipImportFinishesWithNoWorkouts` in `OnboardingUITests.swift` for what follows `import.skip`. If it taps another button before Today, add that tap here.

- [x] **Step 7: Run them and see them fail**

Run the one-class command with `-only-testing:GymRollinsUITests/SharedWorkoutUITests/testALinkBecomesTodaysPlan`.
Expected: FAIL, "the sheet didn't open". The URL scheme is registered and nothing handles it.

- [x] **Step 8: Write `IncomingWorkoutSheet.swift`**

```swift
import GymCore
import SwiftUI

/// The partner's view of a workout link: their own weights, Use for today or Not now, or why it can't open.
struct IncomingWorkoutSheet: View {
    @Environment(AppEnvironment.self) private var env
    @State var screen: IncomingWorkoutScreen
    let close: () -> Void
    let used: () -> Void
    let resume: () -> Void

    var body: some View {
        Group {
            switch screen {
            case let .preview(preview): self.preview(preview)
            case .damaged: message("This link doesn't work. Ask for a new one.", action: closeButton)
            case .tooNew: message("Update GymRollins to open this workout.", action: closeButton)
            case .workoutRunning: message("Finish your current workout first.", action: resumeButton)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private func preview(_ preview: IncomingWorkoutScreen.Preview) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DisplayTitle(text: preview.plan.title, size: 34).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("incoming.title")
                Text(preview.countText).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("incoming.count")
                if let notice = preview.droppedNotice { line(notice, identifier: "incoming.dropped") }
                if preview.replacesToday { line("This replaces today's plan.", identifier: "incoming.replaces") }
                ForEach(preview.rows) { row in
                    ExerciseRow(exercise: env.library.exercise(row.row.exerciseId), fallbackName: row.row.name,
                                subtitle: row.row.subtitle, note: row.note, photoFile: row.row.photoFile)
                        .accessibilityIdentifier("incoming.row.\(row.row.exerciseId)")
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                PrimaryGlassButton(title: "Use for today", identifier: "incoming.use") { use(preview.plan) }
                SecondaryGlassButton(title: "Not now", identifier: "incoming.notNow", action: close)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 8)
        }
    }

    /// A workout that started while the sheet was open (the watch) wins, and the sheet says so.
    private func use(_ plan: TodayPlan) {
        if env.useSharedWorkout(plan) {
            used()
        } else {
            screen = .workoutRunning
        }
    }

    private func message(_ text: String, action: some View) -> some View {
        VStack(spacing: 24) {
            Text(text).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                .accessibilityIdentifier("incoming.message")
            action
        }
        .padding(.horizontal, Theme.gutter)
    }

    private var closeButton: some View {
        SecondaryGlassButton(title: "Close", identifier: "incoming.close", action: close)
    }

    private var resumeButton: some View {
        PrimaryGlassButton(title: "Resume Workout", identifier: "incoming.resume", action: resume)
    }

    private func line(_ text: String, identifier: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.record)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }
}
```

- [x] **Step 9: Write `IncomingWorkoutCoordinator.swift`**

```swift
import SwiftUI
import UIKit

/// A workout link on its way to the screen: it waits for onboarding, then the sheet opens over whatever is up. That can be
/// the full-screen workout, which a `.sheet` on the root view can't appear above, so this presents from the top controller.
/// A second link replaces the first. Links are held in memory only: if the app quits first, the person taps it again.
@MainActor
final class IncomingWorkoutCoordinator {
    private var pending: URL?
    private var presenting: Task<Void, Never>?
    private weak var shown: UIViewController?

    func receive(_ url: URL, env: AppEnvironment, showToday: @escaping @MainActor () -> Void) {
        pending = url
        showIfReady(env: env, showToday: showToday)
    }

    func showIfReady(env: AppEnvironment, showToday: @escaping @MainActor () -> Void) {
        guard env.onboardingComplete, let url = pending else { return }
        pending = nil
        presenting?.cancel()
        shown?.dismiss(animated: false)
        presenting = Task { [weak self] in await self?.present(url, env: env, showToday: showToday) }
    }

    /// Waits while the top controller can't present: while it moves, or a system sheet or alert is up.
    private func present(_ url: URL, env: AppEnvironment, showToday: @escaping @MainActor () -> Void) async {
        while !Task.isCancelled {
            if let top = Self.topController() {
                let host = UIHostingController(rootView: sheet(env.incomingWorkoutScreen(url: url), env: env,
                                                               showToday: showToday))
                shown = host
                top.present(host, animated: true)
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func sheet(_ screen: IncomingWorkoutScreen, env: AppEnvironment,
                       showToday: @escaping @MainActor () -> Void) -> some View {
        IncomingWorkoutSheet(
            screen: screen,
            close: { [weak self] in self?.shown?.dismiss(animated: true) },
            used: { [weak self] in
                showToday()
                self?.shown?.dismiss(animated: true)
            },
            resume: { [weak self] in
                showToday()
                self?.shown?.dismiss(animated: true) {
                    NotificationCenter.default.post(name: .resumeWorkoutRequested, object: nil)
                }
            })
            .environment(env)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
    }

    private static func topController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let top, !top.isBeingPresented, !top.isBeingDismissed, !(top is UIAlertController),
              !(top is UIActivityViewController), !(top is UIImagePickerController) else { return nil }
        return top
    }
}
```

- [x] **Step 10: Receive links in `RootView.swift`**

Replace `body` and add the state and helper. `mainTabs` stays as it is.

```swift
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .today
    @State private var incoming = IncomingWorkoutCoordinator()

    var body: some View {
        Group {
            if env.onboardingComplete {
                mainTabs
                #if DEBUG
                    // During a workout the probe is on the workout flow instead (one probe on screen).
                    .overlay(alignment: .top) { if FakeWatchTransport.isEnabled && env.session == nil { FakeWatchProbe() } }
                #endif
            } else {
                OnboardingFlow().preferredColorScheme(.dark)
            }
        }
        .onOpenURL { receive($0) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { receive(url) }
        }
        .onChange(of: env.onboardingComplete) { _, _ in incoming.showIfReady(env: env, showToday: showToday) }
    }

    private func receive(_ url: URL) { incoming.receive(url, env: env, showToday: showToday) }

    private func showToday() { tab = .today }
```

- [x] **Step 11: Let Today hear about it, in `TodayView.swift`**

Next to the other `.onReceive` lines:

```swift
            .onReceive(NotificationCenter.default.publisher(for: .todayPlanReplaced)) { _ in reload() }
            .onReceive(NotificationCenter.default.publisher(for: .resumeWorkoutRequested)) { _ in
                if env.session != nil { showWorkout = true }
            }
```

- [x] **Step 12: Run the UI tests and see them pass**

Run the one-class command with `-only-testing:GymRollinsUITests/SharedWorkoutUITests`.
Expected: `'result': 'Passed'`. If the sheet doesn't appear in one case, read the failure screenshot first
(`xcrun xcresulttool export attachments --path <bundle> --output-path <dir> --test-id "<id>"`).

- [x] **Step 13: Run the existing Today and onboarding suites**

Run the one-class command with `-only-testing:GymRollinsUITests/OnboardingUITests -only-testing:GymRollinsUITests/TodayFlexUITests -only-testing:GymRollinsTests/SmokeTests`.
Expected: `'result': 'Passed'`. `RootView`'s body now has a `Group`, and these prove nothing else moved.

- [x] **Step 14: Commit**

```bash
git add ios/GymRollins/Features/SharedWorkout ios/GymRollins/App/AppEnvironment+SharedWorkout.swift ios/GymRollins/App/RootView.swift ios/GymRollins/Features/Today/TodayView.swift ios/GymRollinsTests/IncomingWorkoutScreenTests.swift ios/GymRollinsUITests/SharedWorkoutUITests.swift
git commit -m "feat(workouts): open a workout link with your own weights and use it for today"
```

---

### Task 6: Accessibility

**Files:**
- Modify: `ios/GymRollinsUITests/AccessibilityAuditUITests.swift`, `ios/GymRollinsUITests/DynamicTypeUITests.swift`

- [x] **Step 1: Add the audits**

In `AccessibilityAuditUITests`, after `testBuildResultAudit`:

```swift
    func testShareWorkoutAudit() {
        let app = launch()
        let share = app.buttons["today.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        for _ in 0..<6 where !share.isHittable { app.swipeUp() }
        share.tap()
        XCTAssertTrue(app.images["share.qr"].waitForExistence(timeout: 10))
        audit(app, "Share workout")
    }

    func testIncomingWorkoutAudit() throws {
        let app = launch()
        app.open(try XCTUnwrap(URL(string: "gymrollins://w#1.0025_3_8-10.0313_3_10.ZZZZ_3_10")))
        XCTAssertTrue(app.buttons["incoming.use"].waitForExistence(timeout: 10))
        audit(app, "Incoming workout")
    }

    func testIncomingWorkoutMessageAudit() throws {
        let app = launch()
        app.open(try XCTUnwrap(URL(string: "gymrollins://w#nonsense")))
        XCTAssertTrue(app.staticTexts["incoming.message"].waitForExistence(timeout: 10))
        audit(app, "Incoming workout message")
    }
```

- [x] **Step 2: Add the large-text test**

In `DynamicTypeUITests`, after `testBuildSheetAndResultAtAccessibilityXL`:

```swift
    func testSharedWorkoutSheetsAtAccessibilityXL() throws {
        let app = launch()
        let share = app.buttons["today.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        for _ in 0..<10 where !share.isHittable { app.swipeUp() }
        XCTAssertTrue(share.isHittable, "Share workout can be reached")
        share.tap()
        XCTAssertTrue(app.images["share.qr"].waitForExistence(timeout: 10))
        let send = app.descendants(matching: .any)["share.send"]
        for _ in 0..<6 where !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.isHittable, "Send link can be reached")
        screenshot("share-workout-ax-xl")
        app.buttons["share.done"].tap()
        XCTAssertTrue(app.images["share.qr"].waitForNonExistence(timeout: 5))

        app.open(try XCTUnwrap(URL(string: "gymrollins://w#1.0025_3_8-10.0313_3_10")))
        let use = app.buttons["incoming.use"]
        XCTAssertTrue(use.waitForExistence(timeout: 10))
        XCTAssertTrue(use.isHittable, "Use for today can be reached")
        XCTAssertTrue(app.buttons["incoming.notNow"].isHittable, "Not now can be reached")
        screenshot("incoming-workout-ax-xl")
    }
```

- [x] **Step 3: Run them**

Run the one-class command with `-only-testing:GymRollinsUITests/AccessibilityAuditUITests/testShareWorkoutAudit -only-testing:GymRollinsUITests/AccessibilityAuditUITests/testIncomingWorkoutAudit -only-testing:GymRollinsUITests/AccessibilityAuditUITests/testIncomingWorkoutMessageAudit -only-testing:GymRollinsUITests/DynamicTypeUITests/testSharedWorkoutSheetsAtAccessibilityXL`.
Expected: `'result': 'Passed'`.

If an audit reports a real issue, fix the sheet. The likely ones are clipped text or a small hit region on "Send link". Read the screenshot before deciding anything's a false positive. Don't add an exclusion without the evidence in `exclusionReason`'s comment, and report any you add.

If the two bottom buttons don't fit at large text, make the `VStack` in `IncomingWorkoutSheet.preview` part of the scrolled content at that size, using `ViewThatFits`, as `BuildResultView.actions` does.

- [x] **Step 4: Commit**

```bash
git add ios/GymRollinsUITests/AccessibilityAuditUITests.swift ios/GymRollinsUITests/DynamicTypeUITests.swift ios/GymRollins/Features/SharedWorkout
git commit -m "test(workouts): accessibility audits and large text for the shared workout sheets"
```

---

### Task 7: The web page and the privacy sentence

**Files:**
- Create: `web/share/w/index.html`, `web/share/w/open.mjs`, `web/share/w/style.css`
- Create: `web/share/apple-app-site-association.template`, `web/share/README.md`
- Test: `web/share/share.test.mjs`
- Modify: `ios/GymRollins/Features/Settings/PrivacyPolicyView.swift`, `scripts/test-all.sh`, `README.md`

- [x] **Step 1: Write the failing test**

`web/share/share.test.mjs`:

```js
// The landing page a workout link opens when the app doesn't take it. Run: node --test web/share/share.test.mjs
// It must never send anything: the workout sits after the #, which browsers keep from the host.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { appLink, appStoreLink } from './w/open.mjs'

const read = (path) => readFileSync(new URL(path, import.meta.url), 'utf8')

test('hands a workout to the app', () => {
  assert.equal(appLink('#1.0025_3_8-10.1512_3_10_g1'), 'gymrollins://w#1.0025_3_8-10.1512_3_10_g1')
})

for (const hash of ['', '#', '#javascript:alert(1)', '#1.0025 3', '#a/b', '#a?b', '#a&b', '#%41', `#${'1'.repeat(1025)}`]) {
  test(`offers no link for ${JSON.stringify(hash.slice(0, 24))}`, () => {
    assert.equal(appLink(hash), null)
  })
}

test('the App Store button stays hidden until there is an address', () => {
  assert.equal(appStoreLink(''), null)
  assert.equal(appStoreLink('http://apps.apple.com/app/id1'), null)
  assert.equal(appStoreLink('https://apps.apple.com/app/id1'), 'https://apps.apple.com/app/id1')
})

test('the page blocks every request but its own files', () => {
  const html = read('./w/index.html')
  const policy = /http-equiv="Content-Security-Policy" content="([^"]+)"/.exec(html)?.[1]
  assert.ok(policy, 'no content security policy')
  for (const part of ["default-src 'none'", "connect-src 'none'", "script-src 'self'", "style-src 'self'",
    "base-uri 'none'", "form-action 'none'"]) {
    assert.ok(policy.includes(part), `missing ${part}`)
  }
  assert.ok(!/<script(?![^>]*\bsrc=)/.test(html), 'inline script')
  assert.ok(!/https?:\/\//.test(html), 'an outside address in the page')
})

test('the script makes no requests', () => {
  const script = read('./w/open.mjs')
  for (const banned of ['fetch(', 'XMLHttpRequest', 'sendBeacon', 'WebSocket', 'localStorage', 'document.cookie', 'import(']) {
    assert.ok(!script.includes(banned), banned)
  }
})

test("Apple's domain file covers only the link's path and this app", () => {
  const file = JSON.parse(read('./apple-app-site-association.template'))
  const [details] = file.applinks.details
  assert.deepEqual(details.appIDs, ['TEAM_ID.com.rollins.gymrollins'])
  assert.deepEqual(details.components.map((c) => c['/']), ['/w', '/w/'])
})
```

- [x] **Step 2: Run it and see it fail**

Run: `node --test web/share/share.test.mjs`
Expected: FAIL, "Cannot find module .../web/share/w/open.mjs".

- [x] **Step 3: Write the page**

`web/share/w/open.mjs`:

```js
// Leave APP_STORE_URL empty until the app is released: the button stays hidden.
const APP_STORE_URL = ''

// The same characters and length the app accepts, so nothing else can be put into the app's link.
const WORKOUT = /^#[A-Za-z0-9_.-]{1,1024}$/

export function appLink(hash) {
  return WORKOUT.test(hash) ? `gymrollins://w${hash}` : null
}

export function appStoreLink(address) {
  return address.startsWith('https://') ? address : null
}

function show(id, href) {
  const button = document.getElementById(id)
  if (!href) return
  button.href = href
  button.hidden = false
}

if (typeof document !== 'undefined') {
  show('open', appLink(location.hash))
  show('store', appStoreLink(APP_STORE_URL))
}
```

`web/share/w/index.html`:

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'none'; img-src 'self'; base-uri 'none'; form-action 'none'">
  <meta name="referrer" content="no-referrer">
  <title>Shared workout · GymRollins</title>
  <link rel="stylesheet" href="style.css">
  <script type="module" src="open.mjs"></script>
</head>
<body>
  <main>
    <h1>GymRollins</h1>
    <p>Someone shared a workout with you. You'll do it with your own weights.</p>
    <a id="open" class="primary" hidden>Open in GymRollins</a>
    <a id="store" class="secondary" hidden>Get the app</a>
  </main>
</body>
</html>
```

`web/share/w/style.css`:

```css
:root { color-scheme: dark; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #0d0d12; color: #f5f5f7; font: 17px/1.4 -apple-system, system-ui, sans-serif; }
main { max-width: 420px; padding: 24px 16px; text-align: center; }
h1 { font-size: 34px; margin: 0 0 8px; }
p { color: #b8b8c0; margin: 0 0 24px; }
a { display: block; padding: 16px; border-radius: 28px; font-weight: 600; text-decoration: none; margin-top: 8px; }
a[hidden] { display: none; }
.primary { background: #a32430; color: #fff; }
.secondary { border: 1px solid #55555f; color: #f5f5f7; }
```

`web/share/apple-app-site-association.template`:

```json
{
  "applinks": {
    "details": [
      {
        "appIDs": ["TEAM_ID.com.rollins.gymrollins"],
        "components": [
          { "/": "/w", "comment": "A workout link" },
          { "/": "/w/", "comment": "A workout link with a trailing slash" }
        ]
      }
    ]
  }
}
```

`web/share/README.md`:

```markdown
# Workout link page

What a workout link opens when the app doesn't take it. It isn't published yet, because the domain doesn't exist.

The steps for when it does are in `docs/specs/2026-11-01-shared-workout-design.md`, section 10. In short:

1. Publish `w/` at `/w` on any static host.
2. Copy `apple-app-site-association.template` to `/.well-known/apple-app-site-association`, with `TEAM_ID` replaced by the
   Apple team id. Serve it as `application/json`, with no redirect.
3. Set `SHARE_LINK_HOST` in `ios/Config/Base.xcconfig`, and add the associated domain to `ios/project.yml`.
4. Set `APP_STORE_URL` in `w/open.mjs` once the app is released.

The host must serve `.mjs` as JavaScript, or the browser won't run `open.mjs`.

Test: `node --test web/share/share.test.mjs`
```

- [x] **Step 4: Run it and see it pass**

Run: `node --test web/share/share.test.mjs`
Expected: `# fail 0`.

- [x] **Step 5: Add the privacy sentence**

In `PrivacyPolicyView.swift`, in the list right after the line about reports:

```swift
        "Sharing a workout link sends only its exercises, sets and reps: no weights, name or history.",
```

- [x] **Step 6: Add the test to `scripts/test-all.sh`**

Right after `node --test "$ROOT/web/consent/server.test.mjs"`:

```bash

echo "==> Workout link page (node test)"
node --test "$ROOT/web/share/share.test.mjs"
```

- [x] **Step 7: Add to `README.md`**

In the feature list, right after the gym equipment bullet:

```markdown
- **Train with a partner.** Share a day's workout by QR code or link. Your partner opens it with their own weights, and each
  of you logs on your own phone. No account or signal needed.
```

In the tests table, after the consent row:

```markdown
| Workout link page (no requests, content security policy, Apple's domain file) | `node --test web/share/share.test.mjs` |
```

- [x] **Step 8: Commit**

```bash
git add web/share ios/GymRollins/Features/Settings/PrivacyPolicyView.swift scripts/test-all.sh README.md
git commit -m "feat(workouts): the page a workout link opens without the app, and the privacy sentence"
```

---

### Task 8: Finish

- [x] **Step 1: Run every suite**

The app suite takes about an hour, and only one `xcodebuild` should run at a time.

```bash
scripts/coverage-gymcore.sh
(cd ios/Packages/GymData && swift test)
(cd ios/Packages/GymSync && swift test --filter GymSyncTests)
node --test web/share/share.test.mjs
node --test scripts/*.test.mjs
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' scripts/ios-test.sh
xcrun xcresulttool get test-results summary --path "$(ls -td ios/build/TestResults-*.xcresult | head -1)"
```

Expected: coverage at least 90%, every package passing, and the app suite with no failures. This feature doesn't touch
the database, MCP or sync, so `test-db.sh`, `test-mcp.sh` and the integration suites don't apply. If anything in `supabase/`
or `GymSync` did change, stop and say so.

If an audit fails, read its screenshot first. Report every failure with what you found.

- [x] **Step 2: Walk it on two simulators**

Use `iPhone 17 Pro Max` and `iPhone 17 Pro`, both iOS 26.2. Leave the booted iPhone 16 Pro on iOS 18.2 alone, because it may not be ours. With both signed out:

First stop the local server so nothing can reach one (spec criterion 3): `npx --yes supabase@2.118.0 stop`, from the repo. It stops only this project's containers. Don't turn off the Mac's network, and don't use `--all`, because the portal-headshots containers must keep running.

Launch each phone with `xcrun simctl launch --terminate-running-process <udid> com.rollins.gymrollins <flags>`. A's flags are `-diskStore -resetStore -seedOwner -seedHistory -skipOnboarding`, so it has weights. B's are `-diskStore -resetStore -seedOwner -skipOnboarding`, so it has no history.

1. On A, open Today, tap Share workout, and take a screenshot: `xcrun simctl io <A> screenshot <scratchpad>/a-qr.png`.
2. Read the link out of that screenshot, which proves the code on screen works. Save this as `<scratchpad>/readqr.swift` and run `swift <scratchpad>/readqr.swift <scratchpad>/a-qr.png`:

   ```swift
   import CoreImage
   let image = CIImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
   let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
   print(detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first ?? "no code")
   ```

3. On B, run `xcrun simctl openurl <B> '<link>'` and screenshot the sheet. Every loaded exercise says "Set on first set", and none of A's weights appear anywhere.
4. Tap Use for today, then Start Workout. Type a weight of your choice for the first exercise, log a set and finish. Check it's in B's Log, and that A's Log hasn't changed.
5. Open the same link on B again. The first exercise now shows the weight B logged (criterion 1). Tap Not now.
6. Run `xcrun simctl openurl` with `gymrollins://w#nonsense` and screenshot the message.
7. On B, start a workout, open the link, and screenshot the message and Resume.
8. Open Settings, then Privacy, and read the new sentence.

Save the screenshots to the scratchpad, not the repo. List anything that looks wrong, including unclear copy and layout problems.

- [x] **Step 3: Update the docs and finish**

Tick the boxes here and add `## Outcome` with the real numbers and the walk's results, in the form plan 22's uses. State what wasn't tested: the `https://` link opening the app, and a real camera scan. Update the spec if anything changed.

```bash
git add README.md docs/plans/2026-11-01-plan-23-shared-workout.md docs/specs/2026-11-01-shared-workout-design.md
git commit -m "docs: plan 23 outcome"
```

## Outcome

Done on 2026-11-01, branch `feat-shared-workout`, stacked on `feat-gym-moderation`, not pushed. Supabase stays local. Final run at `edbe8d0`:

| Suite | Result |
|---|---|
| App, unit and UI, iPhone 17 Pro Max, iOS 26.2, `PerformanceUITests` excluded | 1085 tests: 1070 passed, 0 failed, 15 skipped |
| `scripts/ios-test-sync.sh`, the app against the real local stack | 5 tests, all passed (5 of the 15 skips above) |
| `scripts/test-photo-hosting.sh` | 1 test, passed (1 of the 15 skips above) |
| GymCore (`scripts/coverage-gymcore.sh`) | 96.34% line coverage, threshold 90%; 100% on the `SharedWorkout` files when written |
| GymData | 352 tests in 48 suites |
| GymHealth | 85 tests in 17 suites |
| GymWatchLink | 63 tests in 8 suites |
| GymSync, `--filter GymSyncTests` | 142 tests in 20 suites |
| `web/share/share.test.mjs` | 17 tests |
| `web/consent/server.test.mjs` | 17 tests |
| `node --test scripts/*.test.mjs` | 148 tests |
| `scripts/watch-build.sh` | watchOS build OK |

Nothing under `supabase/`, `web/consent/` or the GymData, GymSync, GymHealth and GymWatchLink packages changed, so `test-db.sh`, `test-mcp.sh`, the sync integration suite and `test-gym-e2e.sh` weren't run. Plan 22's 18 consent tests are `server.test.mjs`'s 17 plus the one in `e2e.test.mjs`, which only `test-mcp.sh` runs. Plan 22's 181 GymSync tests came from a different way of running them, so don't compare it with the 142 here.

**Skips left:** `ReadmeScreenshotsUITests` (8) only runs when regenerating the README's screenshots. `RealExportImportTests` (1) needs the owner's export file.

**The walk.** The real app on two simulators, signed out, with the local Supabase stopped and without `-uiTesting`, before `edbe8d0`, which only changed the share note's wording. A UI test checks the new wording.
- The QR code read from a screenshot of phone A gave `gymrollins://w#1.0025_3_8-10.0314_3_8-10.0319_3_10-12_g1.0155_3_10-12_g1.0194_3_8-10.0313_3_8-10.0070_3_8-10`: ids and numbers only.
- Phone B's sheet showed B's own weights: bench 140 lb from B's routine, where A's plan said 135 lb. An exercise B had never done read "Set on first set".
- Use for today put "Shared workout · 7 exercises" on Today, with Switch. B logged 100 lb bench and 37.5 lb row, and they appear in B's Log. A's Log and Today didn't change.
- Opening the link again showed the weights B had just logged.
- Bad links gave the right messages. A link during a workout said so and offered Resume, and the workout was unchanged.
- Cardio read "1 × 10 min" with a Minutes box, and plank "3 × 1 min" with a Seconds box.
- Links from Build and from a running workout matched the screen and held no weights.
- The Privacy screen has the new sentence.

**The web page in real browsers.** `w/` at `edbe8d0`, Chromium and WebKit, served locally. With a link, "Open in GymRollins" pointed at `gymrollins://w#...`, the stylesheet loaded, and nothing failed or logged an error. With no link there's no button. In a frame there's no button. "Get the app" stays hidden while `APP_STORE_URL` is empty.

**Changed from the decisions above**
- Decision 1: the coordinator no longer only waits. Each sheet closes itself, an old one is cleared first, and it checks that UIKit really presented the new one, retrying if not.
- Decision 4: the link carries the first working set not yet done, not the first working set.
- Task 5's tests and Task 8's walk step 3 expected every exercise to read "Set on first set". The weight rule below replaced that.
- The UI tests reach the running app with `XCUIDevice.shared.system.open`. `XCUIApplication.open(url)` relaunches the app, which loses the in-memory store and only tests a cold start. `simctl openurl` stops at a dialog a test can't tap.

**Added after this plan's reviews.** The security review found nothing critical or high: 3M mutated links, none out of limits, and no free text reaches the app or Claude. The code review's one high and eight mediums are fixed.
- **Whose weight.** A weight is settled on the phone when the link opens and kept in `fixedWeightKg`: the person's own routine's suggestion, else what they last logged, else none ("Set on first set"). The sender's sets and reps never go through progression, because that gave a first set of -5 lb, a deload from the sender's targets, and 2.5 lb added to bodyweight moves.
- Timed and cardio rows read correctly. Seconds items carry no reps, and reps on a cardio exercise fall back to the cardio default of 20 minutes.
- The sheet shows "You marked this \"Don't recommend\"" and the person's injury note.
- Today comes back after Use for today, from under a pushed screen too, with no "No plan yet" above the rows and with Switch when the person has no routines.
- Links past midnight re-date. Duplicates are removed when sending and refused when reading. An empty day says "There's nothing to share yet."
- The web page uses absolute paths and offers nothing in a frame. The headers a host must send are in `web/share/README.md`.

**Not tested**
- The `https://` link opening the app, which needs the domain, a signed entitlement, a paid Apple team and a real iPhone.
- A real camera scan.
- The system share sheet not fetching the page.
- `testTwoLinksInARowLeaveOneSheetThatCloses` passes on the old coordinator too, so the animation-window race was never reproduced. That fix rests on reading the code.
- Task 4's UI tests were never seen failing before the buttons existed.
- Resume with a SwiftUI sheet up on another tab.

**Known and left**
- The Summary screen counts as a running workout, so a link there says "Finish your current workout first."
- A running workout's link carries single reps, not a range.
- "Set on first set" also shows on bands, balls and rollers. Only body weight is excluded.
- Log All Sets can still log a weight of 0 on a new exercise.
- The Watch doesn't carry a dialled weight to the next set.
- SwiftUI sheets stay up after Use for today, and `NavigationLink` pushes aren't popped.
- A last-logged weight isn't rounded to the plate grid.
- The error screens are bare.
- A superset is carried in the data but has no grouping on the overview, as before this plan.
- Summary's Volume reads kg or t while the rest of the app reads lb, as before this plan.
- The plank logging screen shows a Weight box and rest and plate chips. Whether that predates this plan wasn't checked.
- A link can arrive from any foreground app. All it can do is open the sheet.
