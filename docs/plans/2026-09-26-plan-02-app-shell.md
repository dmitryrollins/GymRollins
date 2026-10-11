# Plan 02: App shell, design system, local store, library, Today and Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A launchable iOS 26 app with the Liquid Glass tab shell (Today · Body · Library · Log), a SwiftData store
(`GymData` package), the bundled 1,324-exercise library with search and custom exercises, the Today screen driven by
the week schedule and the progression engine, and the Plan / Edit Routine screens. It includes a UI test harness
with owner seed data.

**Architecture:** `GymData` is a Swift package (SwiftData records + repositories + library loader) tested with
`swift test` on macOS. The app target (XcodeGen) holds the design system and feature screens and depends on GymCore
and GymData. Repositories are `@MainActor` and expose GymCore value types; views never touch `@Model` records directly.
**Sync granularity** (a change from spec §4): aggregates sync as a unit. Workout = workout + entries + sets, and
routine = routine + exercises. So only aggregate-root records carry sync metadata (`updatedAt`, `serverUpdatedAt`,
`dirty`, `deletedAt`). Plan 05 updates the spec and adds server RPCs that upsert whole aggregates.

**Tech Stack:** Swift 6.2, SwiftUI (iOS 26 Liquid Glass APIs), SwiftData, XcodeGen 2.45, XCTest/XCUITest, Swift
Testing, Node (library build script).

**Spec:** `app/docs/specs/2026-09-26-gymrollins-ios-design.md` §3, §4, §6. **Mockups:** `app/docs/design/*.dc.html`
(Main = Today, Library, HowTo, CustomExercise, Plan, RoutineEdit; STYLE.md = tokens).

**Conventions**
- Branch `plan-02-app-shell` from `main`. Commit after every task. Trailer lines:
  `Co-Authored-By: Claude <model> <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01LD8UaVzMa2mmiCXaEUujBN`.
- Simulator destination (used by all `xcodebuild` commands): `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2`
  (stored in `scripts/ios-test.sh` as `DEST`).
- Signing: `ios/Config/Local.xcconfig` (gitignored) holds `DEVELOPMENT_TEAM = <TEAM_ID>`. Simulator builds don't
  need it.
- Display names: library names are lowercase ("barbell bench press"), so always show `DisplayName.of(exercise.name)`.
- Weights come from GymCore `WeightFormatter` in the profile unit (lb by default). No hand-rolled formatting.
- Accessibility identifiers on every interactive element used by UI tests (listed per task).

---

## File structure

```
app/
  scripts/build-exercise-library.mjs        opengym EXDB -> ios/GymRollins/Resources/exercises.json
  scripts/ios-test.sh                       xcodegen + xcodebuild test (unit + UI)
  ios/
    project.yml
    Config/Base.xcconfig                    #include? "Local.xcconfig"
    Packages/GymData/
      Package.swift
      Sources/GymData/
        Store/GymStore.swift                ModelContainer factory (disk / in-memory)
        Records/ProfileRecord.swift
        Records/RoutineRecords.swift        RoutineRecord, RoutineExerciseRecord, WeekdayRecord
        Records/WorkoutRecords.swift        WorkoutRecord, WorkoutEntryRecord, SetRecord
        Records/BodyRecords.swift           BodyweightRecord
        Records/LibraryRecords.swift        CustomExerciseRecord
        Values/Profile.swift                Profile value type
        Values/BodyweightEntry.swift
        Values/WeekSchedule.swift
        Mapping/RoutineMapping.swift
        Mapping/WorkoutMapping.swift
        History/SessionHistory.swift        WorkoutEntry -> SessionResult
        Repositories/ProfileRepository.swift
        Repositories/RoutineRepository.swift
        Repositories/WorkoutRepository.swift
        Repositories/BodyRepository.swift
        Repositories/CustomExerciseRepository.swift
        Library/ExerciseLibrary.swift
        Seed/OwnerSeed.swift                owner's real split for DEBUG + UI tests
      Tests/GymDataTests/…
    GymRollins/
      App/GymRollinsApp.swift
      App/AppEnvironment.swift
      App/LaunchOptions.swift
      App/RootView.swift
      DesignSystem/Theme.swift              colors, fonts, spacing
      DesignSystem/Glass.swift              glass modifiers + button styles
      DesignSystem/Components.swift         SolidCard, SectionLabel, Chip, Badge
      DesignSystem/ExerciseRow.swift
      DesignSystem/BodyPartIcon.swift
      DesignSystem/DisplayName.swift
      Features/Today/TodayView.swift
      Features/Today/TodayModel.swift
      Features/Library/LibraryView.swift
      Features/Library/ExerciseDetailView.swift
      Features/Library/CustomExerciseView.swift
      Features/Plan/PlanView.swift
      Features/Plan/RoutineEditView.swift
      Features/Plan/ExercisePickerView.swift
      Features/Placeholders/ComingSoonView.swift
      Resources/exercises.json
      Resources/Fonts/BarlowCondensed-*.ttf + OFL.txt
      Resources/Assets.xcassets             AccentColor, AppIcon placeholder
      Info.plist                            generated by XcodeGen
    GymRollinsTests/DisplayNameTests.swift, TodayModelTests.swift
    GymRollinsUITests/ShellUITests.swift, LibraryUITests.swift, PlanUITests.swift
```

---

### Task 1: Branch, exercise library JSON and fonts

**Files:** Create `app/scripts/build-exercise-library.mjs`, `app/ios/GymRollins/Resources/exercises.json`,
`app/ios/GymRollins/Resources/Fonts/*`, `app/ios/GymRollins/Resources/CREDITS.md`

- [ ] **Step 1:** `cd <repo> && git checkout main && git checkout -b plan-02-app-shell`

- [ ] **Step 2: Library build script** `scripts/build-exercise-library.mjs`

```js
#!/usr/bin/env node
// Builds the bundled exercise library from opengym's copy of hasaneyldrm/exercises-dataset (MIT: names,
// instructions, structure). Media (img/gif) is © Gym visual and is NOT used in v1, so it is not emitted.
import { writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

const src = process.argv[2] ?? resolve(process.env.HOME, 'APP_DEV/opengym/frontend/src/lib/exercises-data.js')
const out = process.argv[3] ?? resolve(import.meta.dirname, '../ios/GymRollins/Resources/exercises.json')

const { EXDB } = await import(src)
const fix = s => s.replaceAll('в°', '°').trim()
const rows = EXDB.map(e => ({
  id: e.id, n: fix(e.n), bp: e.bp, eq: e.eq, tg: e.tg,
  ...(e.mg ? { mg: e.mg } : {}),
  sm: e.sm ?? [], st: (e.st ?? []).map(fix),
}))
if (rows.length < 1300) throw new Error(`Expected ~1324 exercises, got ${rows.length}`)
writeFileSync(out, JSON.stringify(rows))
console.log(`Wrote ${rows.length} exercises to ${out}`)
```

Run: `node scripts/build-exercise-library.mjs` → Expected: `Wrote 1324 exercises to …/exercises.json`.
Check: `grep -c "в°" ios/GymRollins/Resources/exercises.json` → `0`.

- [ ] **Step 3: Fonts (OFL)**

```bash
mkdir -p ios/GymRollins/Resources/Fonts && cd ios/GymRollins/Resources/Fonts
for f in BarlowCondensed-BoldItalic BarlowCondensed-ExtraBoldItalic; do
  curl -fsSL -o "$f.ttf" "https://github.com/google/fonts/raw/main/ofl/barlowcondensed/$f.ttf"
done
curl -fsSL -o OFL.txt "https://github.com/google/fonts/raw/main/ofl/barlowcondensed/OFL.txt"
file *.ttf   # Expected: "TrueType Font data" for both
```

- [ ] **Step 4: Credits** `ios/GymRollins/Resources/CREDITS.md`

```markdown
# Credits
- Exercise names and instructions: hasaneyldrm/exercises-dataset (MIT License). Exercise media is not included.
- Barlow Condensed font: Jeremy Tribby, SIL Open Font License 1.1 (see Fonts/OFL.txt).
- Data model and naming inspired by openGym (AGPL-3.0); no openGym source code is included.
```

- [ ] **Step 5: Commit** `chore(ios): bundle exercise library JSON, fonts and credits`

---

### Task 2: GymData package: records, store, values, mapping

**Files:** Create everything under `ios/Packages/GymData/` listed in the file structure except Repositories, Library
and Seed. Test: `Tests/GymDataTests/MappingTests.swift`, `SessionHistoryTests.swift`.

- [ ] **Step 1: Package.swift**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GymData",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "GymData", targets: ["GymData"])],
    dependencies: [.package(path: "../GymCore")],
    targets: [
        .target(name: "GymData", dependencies: ["GymCore"]),
        .testTarget(name: "GymDataTests", dependencies: ["GymData", "GymCore"]),
    ]
)
```

- [ ] **Step 2: Records** (SwiftData `@Model`; enums stored as raw strings; only aggregate roots carry sync metadata)

`Records/ProfileRecord.swift`:
```swift
import Foundation
import SwiftData

@Model
public final class ProfileRecord {
    @Attribute(.unique) public var id: UUID
    public var unitRaw: String
    public var restSec: Int
    public var warmupRestSec: Int
    public var heightCm: Double?
    public var goalWeightKg: Double?
    public var goalDate: Date?
    public var trainingDays: Int
    public var experience: String
    public var limits: String
    public var deloadPct: Double
    public var barKg: Double
    public var plates: [Double]
    public var dumbbellStepKg: Double
    public var mcpReadWorkouts: Bool
    public var mcpReadBody: Bool
    public var mcpPropose: Bool
    public var mcpAutoApply: Bool
    // sync
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool

    public init(id: UUID = ProfileRecord.singletonID, now: Date = .now) {
        self.id = id
        self.unitRaw = "lb"
        self.restSec = 120
        self.warmupRestSec = 60
        self.trainingDays = 4
        self.experience = "intermediate"
        self.limits = ""
        self.deloadPct = 0.05
        self.barKg = 20.411656
        self.plates = [45, 35, 25, 10, 5, 2.5]
        self.dumbbellStepKg = 1.133981
        self.mcpReadWorkouts = true
        self.mcpReadBody = true
        self.mcpPropose = true
        self.mcpAutoApply = false
        self.updatedAt = now
        self.dirty = true
    }

    public static let singletonID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!
}
```

`Records/RoutineRecords.swift`:
```swift
import Foundation
import SwiftData

@Model
public final class RoutineRecord {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var emoji: String?
    public var policyRaw: String
    public var position: Int
    public var paused: Bool
    @Relationship(deleteRule: .cascade, inverse: \RoutineExerciseRecord.routine)
    public var exercises: [RoutineExerciseRecord] = []
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool
    public var deletedAt: Date?

    public init(id: UUID, name: String, emoji: String?, policyRaw: String, position: Int, paused: Bool, now: Date) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.policyRaw = policyRaw
        self.position = position
        self.paused = paused
        self.updatedAt = now
        self.dirty = true
    }
}

@Model
public final class RoutineExerciseRecord {
    @Attribute(.unique) public var id: UUID
    public var exerciseId: String
    public var position: Int
    public var sets: Int
    public var reps: Int
    public var repsMin: Int?
    public var sec: Int?
    public var weightKg: Double?
    /// When the plan weight was last set (user edit or applied proposal); drives the "planned" override.
    public var weightSetAt: Date?
    public var modeRaw: String
    public var policyRaw: String?
    public var incKg: Double?
    public var supersetGroup: String?
    public var routine: RoutineRecord?

    public init(id: UUID, exerciseId: String, position: Int, sets: Int, reps: Int, repsMin: Int?, sec: Int?,
                weightKg: Double?, weightSetAt: Date?, modeRaw: String, policyRaw: String?, incKg: Double?,
                supersetGroup: String?) {
        self.id = id
        self.exerciseId = exerciseId
        self.position = position
        self.sets = sets
        self.reps = reps
        self.repsMin = repsMin
        self.sec = sec
        self.weightKg = weightKg
        self.weightSetAt = weightSetAt
        self.modeRaw = modeRaw
        self.policyRaw = policyRaw
        self.incKg = incKg
        self.supersetGroup = supersetGroup
    }
}

/// ISO weekday 1 = Monday … 7 = Sunday. `routineId == nil` means rest day.
@Model
public final class WeekdayRecord {
    @Attribute(.unique) public var weekday: Int
    public var routineId: UUID?
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool

    public init(weekday: Int, routineId: UUID?, now: Date) {
        self.weekday = weekday
        self.routineId = routineId
        self.updatedAt = now
        self.dirty = true
    }
}
```

`Records/WorkoutRecords.swift`:
```swift
import Foundation
import SwiftData

@Model
public final class WorkoutRecord {
    @Attribute(.unique) public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var pausedSeconds: Double
    public var pausedAt: Date?
    public var routineId: UUID?
    public var name: String
    public var sourceRaw: String
    public var note: String?
    /// True while the workout is in progress (never synced while active).
    public var isActive: Bool
    public var volumeKg: Double
    @Relationship(deleteRule: .cascade, inverse: \WorkoutEntryRecord.workout)
    public var entries: [WorkoutEntryRecord] = []
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool
    public var deletedAt: Date?

    public init(id: UUID, startedAt: Date, name: String, sourceRaw: String, isActive: Bool, now: Date) {
        self.id = id
        self.startedAt = startedAt
        self.pausedSeconds = 0
        self.name = name
        self.sourceRaw = sourceRaw
        self.isActive = isActive
        self.volumeKg = 0
        self.updatedAt = now
        self.dirty = true
    }
}

@Model
public final class WorkoutEntryRecord {
    @Attribute(.unique) public var id: UUID
    public var exerciseId: String
    public var position: Int
    public var note: String?
    public var supersetGroup: String?
    @Relationship(deleteRule: .cascade, inverse: \SetRecord.entry)
    public var sets: [SetRecord] = []
    public var workout: WorkoutRecord?

    public init(id: UUID, exerciseId: String, position: Int, note: String?, supersetGroup: String?) {
        self.id = id
        self.exerciseId = exerciseId
        self.position = position
        self.note = note
        self.supersetGroup = supersetGroup
    }
}

@Model
public final class SetRecord {
    @Attribute(.unique) public var id: UUID
    public var position: Int
    public var weightKg: Double
    public var reps: Int
    public var sec: Int?
    public var minutes: Double?
    public var distanceM: Double?
    public var done: Bool
    public var warmup: Bool
    public var rir: Double?
    public var rpe: Double?
    public var multiplier: Double
    public var completedAt: Date?
    public var entry: WorkoutEntryRecord?

    public init(id: UUID, position: Int, weightKg: Double, reps: Int, sec: Int?, minutes: Double?, distanceM: Double?,
                done: Bool, warmup: Bool, rir: Double?, rpe: Double?, multiplier: Double, completedAt: Date?) {
        self.id = id
        self.position = position
        self.weightKg = weightKg
        self.reps = reps
        self.sec = sec
        self.minutes = minutes
        self.distanceM = distanceM
        self.done = done
        self.warmup = warmup
        self.rir = rir
        self.rpe = rpe
        self.multiplier = multiplier
        self.completedAt = completedAt
    }
}
```

`Records/BodyRecords.swift`:
```swift
import Foundation
import SwiftData

@Model
public final class BodyweightRecord {
    @Attribute(.unique) public var id: UUID
    public var date: Date
    public var weightKg: Double
    public var bodyFatPct: Double?
    public var timeOfDay: String?
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool
    public var deletedAt: Date?

    public init(id: UUID, date: Date, weightKg: Double, bodyFatPct: Double?, timeOfDay: String?, now: Date) {
        self.id = id
        self.date = date
        self.weightKg = weightKg
        self.bodyFatPct = bodyFatPct
        self.timeOfDay = timeOfDay
        self.updatedAt = now
        self.dirty = true
    }
}
```

`Records/LibraryRecords.swift`:
```swift
import Foundation
import SwiftData

@Model
public final class CustomExerciseRecord {
    @Attribute(.unique) public var id: String
    public var name: String
    public var bodyPart: String
    public var equipment: String
    public var target: String
    public var modeRaw: String
    public var bilateral: Bool
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool
    public var deletedAt: Date?

    public init(id: String, name: String, bodyPart: String, equipment: String, target: String, modeRaw: String,
                bilateral: Bool, now: Date) {
        self.id = id
        self.name = name
        self.bodyPart = bodyPart
        self.equipment = equipment
        self.target = target
        self.modeRaw = modeRaw
        self.bilateral = bilateral
        self.updatedAt = now
        self.dirty = true
    }
}
```

- [ ] **Step 3: Store** `Store/GymStore.swift`

```swift
import SwiftData

public enum GymStore {
    public static let models: [any PersistentModel.Type] = [
        ProfileRecord.self, RoutineRecord.self, RoutineExerciseRecord.self, WeekdayRecord.self,
        WorkoutRecord.self, WorkoutEntryRecord.self, SetRecord.self, BodyweightRecord.self, CustomExerciseRecord.self,
    ]

    public static func container(inMemory: Bool) throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: Schema(models), configurations: config)
    }
}
```

- [ ] **Step 4: Values**

`Values/Profile.swift`:
```swift
import Foundation
import GymCore

public struct Profile: Sendable, Equatable {
    public let unit: WeightUnit
    public let restSec: Int
    public let warmupRestSec: Int
    public let heightCm: Double?
    public let goalWeightKg: Double?
    public let goalDate: Date?
    public let trainingDays: Int
    public let experience: String
    public let limits: String
    public let deloadPct: Double
    public let barKg: Double
    public let plateInventory: PlateInventory
    public let dumbbellStepKg: Double
    public let mcpReadWorkouts: Bool
    public let mcpReadBody: Bool
    public let mcpPropose: Bool
    public let mcpAutoApply: Bool

    public init(unit: WeightUnit = .lb, restSec: Int = 120, warmupRestSec: Int = 60, heightCm: Double? = nil,
                goalWeightKg: Double? = nil, goalDate: Date? = nil, trainingDays: Int = 4,
                experience: String = "intermediate", limits: String = "", deloadPct: Double = 0.05,
                barKg: Double = 20.411656, plateInventory: PlateInventory = .standardLb,
                dumbbellStepKg: Double = 1.133981, mcpReadWorkouts: Bool = true, mcpReadBody: Bool = true,
                mcpPropose: Bool = true, mcpAutoApply: Bool = false) {
        self.unit = unit
        self.restSec = restSec
        self.warmupRestSec = warmupRestSec
        self.heightCm = heightCm
        self.goalWeightKg = goalWeightKg
        self.goalDate = goalDate
        self.trainingDays = trainingDays
        self.experience = experience
        self.limits = limits
        self.deloadPct = deloadPct
        self.barKg = barKg
        self.plateInventory = plateInventory
        self.dumbbellStepKg = dumbbellStepKg
        self.mcpReadWorkouts = mcpReadWorkouts
        self.mcpReadBody = mcpReadBody
        self.mcpPropose = mcpPropose
        self.mcpAutoApply = mcpAutoApply
    }

    /// Rounder for barbell-style loads in the user's unit.
    public var barbellRounder: LoadRounder { unit == .lb ? .barbellLb : .barbellKg }
    /// Rounder for dumbbells/machines in the user's unit.
    public var dumbbellRounder: LoadRounder {
        LoadRounder(unit: unit, step: UnitConverter.fromKg(dumbbellStepKg, to: unit).rounded(toPlaces: 2))
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
```

`Values/BodyweightEntry.swift`:
```swift
import Foundation

public struct BodyweightEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let date: Date
    public let weightKg: Double
    public let bodyFatPct: Double?
    public let timeOfDay: String?

    public init(id: UUID = UUID(), date: Date, weightKg: Double, bodyFatPct: Double? = nil, timeOfDay: String? = nil) {
        self.id = id
        self.date = date
        self.weightKg = weightKg
        self.bodyFatPct = bodyFatPct
        self.timeOfDay = timeOfDay
    }
}
```

`Values/WeekSchedule.swift`:
```swift
import Foundation

/// ISO weekday (1 = Monday … 7 = Sunday) -> routine id (nil = rest).
public struct WeekSchedule: Sendable, Equatable {
    public let days: [Int: UUID]

    public init(days: [Int: UUID]) { self.days = days }

    public func routineId(on date: Date, calendar: Calendar = .current) -> UUID? {
        days[Self.isoWeekday(date, calendar: calendar)]
    }

    public static func isoWeekday(_ date: Date, calendar: Calendar = .current) -> Int {
        let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
        return weekday == 1 ? 7 : weekday - 1
    }
}
```

- [ ] **Step 5: Mapping** (record ↔ GymCore values; children sorted by `position`)

`Mapping/RoutineMapping.swift`:
```swift
import Foundation
import GymCore

extension RoutineRecord {
    public var value: Routine {
        Routine(id: id, name: name, emoji: emoji, policy: ProgressionPolicy(rawValue: policyRaw) ?? .double,
                paused: paused, exercises: exercises.sorted { $0.position < $1.position }.map(\.value))
    }
}

extension RoutineExerciseRecord {
    public var value: RoutineExercise {
        RoutineExercise(id: id, exerciseId: exerciseId, sets: sets, reps: reps, repsMin: repsMin, sec: sec,
                        weightKg: weightKg, weightSetAt: weightSetAt, mode: ExerciseMode(rawValue: modeRaw) ?? .reps,
                        policy: policyRaw.flatMap(ProgressionPolicy.init(rawValue:)), incKg: incKg,
                        supersetGroup: supersetGroup)
    }

    public convenience init(_ value: RoutineExercise, position: Int) {
        self.init(id: value.id, exerciseId: value.exerciseId, position: position, sets: value.sets, reps: value.reps,
                  repsMin: value.repsMin, sec: value.sec, weightKg: value.weightKg, weightSetAt: value.weightSetAt,
                  modeRaw: value.mode.rawValue,
                  policyRaw: value.policy?.rawValue, incKg: value.incKg, supersetGroup: value.supersetGroup)
    }
}
```

`Mapping/WorkoutMapping.swift`:
```swift
import Foundation
import GymCore

extension WorkoutRecord {
    public var value: Workout {
        Workout(id: id, startedAt: startedAt, endedAt: endedAt, pausedSeconds: pausedSeconds, routineId: routineId,
                name: name, entries: entries.sorted { $0.position < $1.position }.map(\.value),
                source: WorkoutSource(rawValue: sourceRaw) ?? .app, note: note)
    }

    public var clock: WorkoutClock {
        WorkoutClock(startedAt: startedAt, pausedAt: pausedAt, pausedSeconds: pausedSeconds)
    }
}

extension WorkoutEntryRecord {
    public var value: WorkoutEntry {
        WorkoutEntry(id: id, exerciseId: exerciseId, sets: sets.sorted { $0.position < $1.position }.map(\.value),
                     note: note, supersetGroup: supersetGroup)
    }

    public convenience init(_ value: WorkoutEntry, position: Int) {
        self.init(id: value.id, exerciseId: value.exerciseId, position: position, note: value.note,
                  supersetGroup: value.supersetGroup)
        self.sets = value.sets.enumerated().map { SetRecord($1, position: $0) }
    }
}

extension SetRecord {
    public var value: WorkoutSet {
        WorkoutSet(id: id, weightKg: weightKg, reps: reps, sec: sec, minutes: minutes, distanceM: distanceM, done: done,
                   warmup: warmup, rir: rir, rpe: rpe, multiplier: multiplier, completedAt: completedAt)
    }

    public convenience init(_ value: WorkoutSet, position: Int) {
        self.init(id: value.id, position: position, weightKg: value.weightKg, reps: value.reps, sec: value.sec,
                  minutes: value.minutes, distanceM: value.distanceM, done: value.done, warmup: value.warmup,
                  rir: value.rir, rpe: value.rpe, multiplier: value.multiplier, completedAt: value.completedAt)
    }
}
```

- [ ] **Step 6: Session history** `History/SessionHistory.swift`

```swift
import Foundation
import GymCore

public enum SessionHistory {
    /// Working sets at the session's top weight become one progression data point.
    public static func result(for entry: WorkoutEntry, date: Date) -> SessionResult? {
        let working = WorkoutMetrics.workingSets(entry)
        guard let top = working.map(\.weightKg).max() else { return nil }
        let atTop = working.filter { abs($0.weightKg - top) < 0.01 }
        return SessionResult(date: date, weightKg: top, reps: atTop.map(\.reps), secs: atTop.compactMap(\.sec))
    }
}
```

- [ ] **Step 7: Tests** (write first; run `swift test` in `ios/Packages/GymData` and see them fail, then add the code above
until green)

`Tests/GymDataTests/MappingTests.swift`:
```swift
import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

@MainActor
@Suite struct MappingTests {
    @Test func routineRoundTripKeepsOrder() throws {
        let container = try GymStore.container(inMemory: true)
        let context = container.mainContext
        let routine = RoutineRecord(id: UUID(), name: "Push + Arms", emoji: nil, policyRaw: "double", position: 0,
                                    paused: false, now: .now)
        context.insert(routine)
        routine.exercises = [
            RoutineExerciseRecord(RoutineExercise(exerciseId: "0314", sets: 3, reps: 10, repsMin: 8), position: 1),
            RoutineExerciseRecord(RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, repsMin: 8, weightKg: 63.5), position: 0),
        ]
        try context.save()
        let value = try #require(try context.fetch(FetchDescriptor<RoutineRecord>()).first).value
        #expect(value.exercises.map(\.exerciseId) == ["0025", "0314"])
        #expect(value.policy == .double)
        #expect(value.exercises[0].weightKg == 63.5)
    }

    @Test func workoutRoundTrip() throws {
        let container = try GymStore.container(inMemory: true)
        let context = container.mainContext
        let entry = WorkoutEntry(exerciseId: "0025", sets: [
            WorkoutSet(weightKg: 20.41, reps: 10, done: true, warmup: true),
            WorkoutSet(weightKg: 58.97, reps: 10, done: true),
        ])
        let record = WorkoutRecord(id: UUID(), startedAt: .now, name: "Push", sourceRaw: "app", isActive: false, now: .now)
        context.insert(record)
        record.entries = [WorkoutEntryRecord(entry, position: 0)]
        try context.save()
        let value = try #require(try context.fetch(FetchDescriptor<WorkoutRecord>()).first).value
        #expect(value.entries[0].sets.map(\.warmup) == [true, false])
        #expect(value.entries[0].sets[1].weightKg == 58.97)
    }
}
```

`Tests/GymDataTests/SessionHistoryTests.swift`:
```swift
import Foundation
import GymCore
import Testing
@testable import GymData

@Suite struct SessionHistoryTests {
    @Test func usesWorkingSetsAtTopWeight() throws {
        let entry = WorkoutEntry(exerciseId: "0025", sets: [
            WorkoutSet(weightKg: 20, reps: 10, done: true, warmup: true),
            WorkoutSet(weightKg: 52.16, reps: 8, done: true),
            WorkoutSet(weightKg: 58.97, reps: 6, done: true),
            WorkoutSet(weightKg: 58.97, reps: 6, done: true),
            WorkoutSet(weightKg: 58.97, reps: 6, done: false),
        ])
        let result = try #require(SessionHistory.result(for: entry, date: .now))
        #expect(result.weightKg == 58.97)
        #expect(result.reps == [6, 6])
    }

    @Test func nilWithoutWorkingSets() {
        let entry = WorkoutEntry(exerciseId: "x", sets: [WorkoutSet(weightKg: 20, reps: 10, done: true, warmup: true)])
        #expect(SessionHistory.result(for: entry, date: .now) == nil)
    }
}
```

Also add `Tests/GymDataTests/WeekScheduleTests.swift`:
```swift
import Foundation
import Testing
@testable import GymData

@Suite struct WeekScheduleTests {
    @Test func isoWeekday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let saturday = Date(timeIntervalSince1970: 1_790_380_800) // 2026-09-26 00:00 UTC
        #expect(WeekSchedule.isoWeekday(saturday, calendar: cal) == 6)
        let push = UUID()
        #expect(WeekSchedule(days: [6: push]).routineId(on: saturday, calendar: cal) == push)
        #expect(WeekSchedule(days: [6: push]).routineId(on: saturday.addingTimeInterval(86_400), calendar: cal) == nil)
    }

    @Test func profileRounders() {
        #expect(Profile().barbellRounder == .barbellLb)
        #expect(Profile().dumbbellRounder == LoadRounder(unit: .lb, step: 2.5))
        #expect(Profile(unit: .kg).barbellRounder == .barbellKg)
    }
}
```
(Check the epoch with `date -j -u -f "%Y-%m-%d" 2026-09-26 +%s` before relying on it; use the printed value.)

Run: `cd ios/Packages/GymData && swift test` → Expected: PASS.

- [ ] **Step 8: Commit** `feat(data): SwiftData records, store, values, mapping and session history`

---

### Task 3: GymData repositories

**Files:** Create `Repositories/*.swift`; Tests `Tests/GymDataTests/RepositoryTests.swift`

Every write sets `updatedAt = now()` and `dirty = true` on the aggregate root. Deletes set `deletedAt` (tombstone)
instead of removing rows, except the active-workout discard, which really deletes (never synced). All reads filter
`deletedAt == nil`. Repositories take `now: @escaping () -> Date` so tests can control time.

- [ ] **Step 1: Failing tests** `RepositoryTests.swift`

```swift
import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

@MainActor
@Suite struct RepositoryTests {
    let container: ModelContainer
    let clock: () -> Date = { Date(timeIntervalSince1970: 1_790_000_000) }

    init() throws { container = try GymStore.container(inMemory: true) }

    @Test func profileDefaultsAndSave() throws {
        let repo = ProfileRepository(context: container.mainContext, now: clock)
        #expect(try repo.load().unit == .lb)
        try repo.save(Profile(unit: .kg, goalWeightKg: 85))
        let loaded = try repo.load()
        #expect(loaded.unit == .kg)
        #expect(loaded.goalWeightKg == 85)
    }

    @Test func routineUpsertReplacesExercisesAndMarksDirty() throws {
        let repo = RoutineRepository(context: container.mainContext, now: clock)
        let id = UUID()
        try repo.upsert(Routine(id: id, name: "Push", exercises: [RoutineExercise(exerciseId: "0025", sets: 3, reps: 8)]))
        try repo.upsert(Routine(id: id, name: "Push + Arms", exercises: [
            RoutineExercise(exerciseId: "0314", sets: 3, reps: 10),
            RoutineExercise(exerciseId: "0025", sets: 3, reps: 8),
        ]))
        let all = try repo.all()
        #expect(all.count == 1)
        #expect(all[0].name == "Push + Arms")
        #expect(all[0].exercises.map(\.exerciseId) == ["0314", "0025"])
        #expect(try repo.record(id)?.dirty == true)
        #expect(try container.mainContext.fetch(FetchDescriptor<RoutineExerciseRecord>()).count == 2)
    }

    @Test func routineDeleteIsTombstone() throws {
        let repo = RoutineRepository(context: container.mainContext, now: clock)
        let id = UUID()
        try repo.upsert(Routine(id: id, name: "Legs"))
        try repo.delete(id)
        #expect(try repo.all().isEmpty)
        #expect(try repo.record(id)?.deletedAt != nil)
    }

    @Test func scheduleAndRoutineForDate() throws {
        let repo = RoutineRepository(context: container.mainContext, now: clock)
        let push = UUID()
        try repo.upsert(Routine(id: push, name: "Push"))
        try repo.setSchedule(weekday: 6, routineId: push)
        #expect(try repo.schedule().days == [6: push])
        try repo.setSchedule(weekday: 6, routineId: nil)
        #expect(try repo.schedule().days.isEmpty)
    }

    @Test func workoutSaveHistoryAndBests() throws {
        let repo = WorkoutRepository(context: container.mainContext, now: clock)
        let bench = { (reps: Int, days: Double) in
            Workout(startedAt: Date(timeIntervalSince1970: 1_790_000_000 + days * 86_400), endedAt: nil, name: "Push",
                    entries: [WorkoutEntry(exerciseId: "0025", sets: (0..<3).map { _ in
                        WorkoutSet(weightKg: 58.97, reps: reps, done: true) })])
        }
        try repo.save(bench(6, 0))
        try repo.save(bench(10, 7))
        let history = try repo.history(exerciseId: "0025", limit: 5)
        #expect(history.map(\.reps) == [[10, 10, 10], [6, 6, 6]])
        let bests = try #require(try repo.bests(exerciseId: "0025"))
        #expect(bests.repsAtWeight[weightKey(58.97)] == 10)
        #expect(try repo.recent(limit: 10).count == 2)
    }

    @Test func activeWorkoutExcludedFromHistory() throws {
        let repo = WorkoutRepository(context: container.mainContext, now: clock)
        let workout = Workout(startedAt: clock(), name: "Push", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 60, reps: 8, done: true)])])
        try repo.saveActive(workout, pausedAt: nil)
        #expect(try repo.active()?.id == workout.id)
        #expect(try repo.history(exerciseId: "0025", limit: 5).isEmpty)
        try repo.discardActive()
        #expect(try repo.active() == nil)
    }

    @Test func bodyweightEntries() throws {
        let repo = BodyRepository(context: container.mainContext, now: clock)
        try repo.add(BodyweightEntry(date: clock(), weightKg: 81))
        try repo.add(BodyweightEntry(date: clock().addingTimeInterval(7 * 86_400), weightKg: 81.4))
        #expect(try repo.latest()?.weightKg == 81.4)
        #expect(try repo.entries(since: nil).map(\.weightKg) == [81, 81.4])
    }

    @Test func customExercises() throws {
        let repo = CustomExerciseRepository(context: container.mainContext, now: clock)
        let ex = try repo.create(name: "Handle Band Squat to Press", bodyPart: "upper legs", equipment: "band",
                                 target: "quads", mode: .reps, bilateral: false)
        #expect(ex.isCustom)
        #expect(ex.id.hasPrefix("custom-"))
        #expect(try repo.all().map(\.name) == ["Handle Band Squat to Press"])
    }
}
```

Run `swift test --filter RepositoryTests` → FAIL.

- [ ] **Step 2: Implement**

`Repositories/ProfileRepository.swift`:
```swift
import Foundation
import GymCore
import SwiftData

@MainActor
public final class ProfileRepository {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    public func load() throws -> Profile {
        guard let r = try record() else { return Profile() }
        return Profile(unit: WeightUnit(rawValue: r.unitRaw) ?? .lb, restSec: r.restSec, warmupRestSec: r.warmupRestSec,
                       heightCm: r.heightCm, goalWeightKg: r.goalWeightKg, goalDate: r.goalDate,
                       trainingDays: r.trainingDays, experience: r.experience, limits: r.limits,
                       deloadPct: r.deloadPct, barKg: r.barKg,
                       plateInventory: PlateInventory(unit: WeightUnit(rawValue: r.unitRaw) ?? .lb,
                                                      bar: UnitConverter.fromKg(r.barKg, to: WeightUnit(rawValue: r.unitRaw) ?? .lb).rounded(toPlaces: 2),
                                                      plates: r.plates),
                       dumbbellStepKg: r.dumbbellStepKg, mcpReadWorkouts: r.mcpReadWorkouts, mcpReadBody: r.mcpReadBody,
                       mcpPropose: r.mcpPropose, mcpAutoApply: r.mcpAutoApply)
    }

    public func save(_ p: Profile) throws {
        let r = try record() ?? {
            let new = ProfileRecord(now: now())
            context.insert(new)
            return new
        }()
        r.unitRaw = p.unit.rawValue
        r.restSec = p.restSec
        r.warmupRestSec = p.warmupRestSec
        r.heightCm = p.heightCm
        r.goalWeightKg = p.goalWeightKg
        r.goalDate = p.goalDate
        r.trainingDays = p.trainingDays
        r.experience = p.experience
        r.limits = p.limits
        r.deloadPct = p.deloadPct
        r.barKg = p.barKg
        r.plates = p.plateInventory.plates
        r.dumbbellStepKg = p.dumbbellStepKg
        r.mcpReadWorkouts = p.mcpReadWorkouts
        r.mcpReadBody = p.mcpReadBody
        r.mcpPropose = p.mcpPropose
        r.mcpAutoApply = p.mcpAutoApply
        r.updatedAt = now()
        r.dirty = true
        try context.save()
    }

    private func record() throws -> ProfileRecord? {
        let id = ProfileRecord.singletonID
        return try context.fetch(FetchDescriptor<ProfileRecord>(predicate: #Predicate { $0.id == id })).first
    }
}
```

`Repositories/RoutineRepository.swift`:
```swift
import Foundation
import GymCore
import SwiftData

@MainActor
public final class RoutineRepository {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    public func all() throws -> [Routine] {
        let descriptor = FetchDescriptor<RoutineRecord>(predicate: #Predicate { $0.deletedAt == nil },
                                                        sortBy: [SortDescriptor(\.position)])
        return try context.fetch(descriptor).map(\.value)
    }

    public func routine(_ id: UUID) throws -> Routine? {
        guard let r = try record(id), r.deletedAt == nil else { return nil }
        return r.value
    }

    func record(_ id: UUID) throws -> RoutineRecord? {
        try context.fetch(FetchDescriptor<RoutineRecord>(predicate: #Predicate { $0.id == id })).first
    }

    public func upsert(_ routine: Routine) throws {
        let existing = try record(routine.id)
        let r = existing ?? {
            let count = (try? context.fetchCount(FetchDescriptor<RoutineRecord>())) ?? 0
            let new = RoutineRecord(id: routine.id, name: routine.name, emoji: routine.emoji,
                                    policyRaw: routine.policy.rawValue, position: count, paused: routine.paused, now: now())
            context.insert(new)
            return new
        }()
        r.name = routine.name
        r.emoji = routine.emoji
        r.policyRaw = routine.policy.rawValue
        r.paused = routine.paused
        r.deletedAt = nil
        r.exercises.forEach(context.delete)
        r.exercises = routine.exercises.enumerated().map { RoutineExerciseRecord($1, position: $0) }
        r.updatedAt = now()
        r.dirty = true
        try context.save()
    }

    public func delete(_ id: UUID) throws {
        guard let r = try record(id) else { return }
        r.deletedAt = now()
        r.updatedAt = now()
        r.dirty = true
        let weekdays = try context.fetch(FetchDescriptor<WeekdayRecord>()).filter { $0.routineId == id }
        weekdays.forEach { $0.routineId = nil; $0.updatedAt = now(); $0.dirty = true }
        try context.save()
    }

    public func schedule() throws -> WeekSchedule {
        let days = try context.fetch(FetchDescriptor<WeekdayRecord>())
            .compactMap { r in r.routineId.map { (r.weekday, $0) } }
        return WeekSchedule(days: Dictionary(uniqueKeysWithValues: days))
    }

    public func setSchedule(weekday: Int, routineId: UUID?) throws {
        precondition((1...7).contains(weekday), "ISO weekday 1…7")
        let existing = try context.fetch(FetchDescriptor<WeekdayRecord>(predicate: #Predicate { $0.weekday == weekday })).first
        let r = existing ?? { let new = WeekdayRecord(weekday: weekday, routineId: nil, now: now()); context.insert(new); return new }()
        r.routineId = routineId
        r.updatedAt = now()
        r.dirty = true
        try context.save()
    }
}
```

`Repositories/WorkoutRepository.swift`:
```swift
import Foundation
import GymCore
import SwiftData

@MainActor
public final class WorkoutRepository {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    /// Finished, non-deleted workouts, newest first.
    public func recent(limit: Int) throws -> [Workout] {
        var d = FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.deletedAt == nil && $0.isActive == false },
                                               sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        d.fetchLimit = limit
        return try context.fetch(d).map(\.value)
    }

    public func workout(_ id: UUID) throws -> Workout? {
        try record(id).flatMap { $0.deletedAt == nil ? $0.value : nil }
    }

    /// Progression data points for one exercise, newest first.
    public func history(exerciseId: String, limit: Int) throws -> [SessionResult] {
        let finished = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.deletedAt == nil && $0.isActive == false },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return try context.fetch(finished)
            .lazy
            .compactMap { w in
                w.entries.first { $0.exerciseId == exerciseId }
                    .flatMap { SessionHistory.result(for: $0.value, date: w.startedAt) }
            }
            .prefix(limit)
            .map { $0 }
    }

    /// All-time bests for PR detection, or nil if never performed.
    public func bests(exerciseId: String) throws -> ExerciseBests? {
        let entries = try context.fetch(FetchDescriptor<WorkoutEntryRecord>(predicate: #Predicate { $0.exerciseId == exerciseId }))
            .filter { $0.workout?.deletedAt == nil && $0.workout?.isActive == false }
        guard !entries.isEmpty else { return nil }
        return entries.map { ExerciseBests(entry: $0.value) }.reduce(ExerciseBests(e1RMKg: nil, repsAtWeight: [:], volumeKg: 0)) { $0.merging($1) }
    }

    /// Saves a finished workout (insert or replace), computing volume.
    public func save(_ workout: Workout) throws {
        let r = try upsertRecord(workout, isActive: false)
        r.pausedAt = nil
        r.volumeKg = WorkoutMetrics.volumeKg(workout)
        try context.save()
    }

    /// Persists the in-progress workout after every change (resume after app kill).
    public func saveActive(_ workout: Workout, pausedAt: Date?) throws {
        let r = try upsertRecord(workout, isActive: true)
        r.pausedAt = pausedAt
        try context.save()
    }

    public func active() throws -> (Workout)? {
        try activeRecord()?.value
    }

    public func activeClock() throws -> WorkoutClock? {
        try activeRecord()?.clock
    }

    public func discardActive() throws {
        if let r = try activeRecord() { context.delete(r); try context.save() }
    }

    public func delete(_ id: UUID) throws {
        guard let r = try record(id) else { return }
        r.deletedAt = now()
        r.updatedAt = now()
        r.dirty = true
        try context.save()
    }

    // MARK: - Private

    private func record(_ id: UUID) throws -> WorkoutRecord? {
        try context.fetch(FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func activeRecord() throws -> WorkoutRecord? {
        try context.fetch(FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.isActive == true })).first
    }

    private func upsertRecord(_ w: Workout, isActive: Bool) throws -> WorkoutRecord {
        let r = try record(w.id) ?? {
            let new = WorkoutRecord(id: w.id, startedAt: w.startedAt, name: w.name, sourceRaw: w.source.rawValue,
                                    isActive: isActive, now: now())
            context.insert(new)
            return new
        }()
        r.startedAt = w.startedAt
        r.endedAt = w.endedAt
        r.pausedSeconds = w.pausedSeconds
        r.routineId = w.routineId
        r.name = w.name
        r.sourceRaw = w.source.rawValue
        r.note = w.note
        r.isActive = isActive
        r.deletedAt = nil
        r.entries.forEach(context.delete)
        r.entries = w.entries.enumerated().map { WorkoutEntryRecord($1, position: $0) }
        r.updatedAt = now()
        r.dirty = !isActive
        return r
    }
}
```

`Repositories/BodyRepository.swift`:
```swift
import Foundation
import SwiftData

@MainActor
public final class BodyRepository {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    public func entries(since: Date?) throws -> [BodyweightEntry] {
        let start = since ?? .distantPast
        let d = FetchDescriptor<BodyweightRecord>(predicate: #Predicate { $0.deletedAt == nil && $0.date >= start },
                                                  sortBy: [SortDescriptor(\.date)])
        return try context.fetch(d).map { BodyweightEntry(id: $0.id, date: $0.date, weightKg: $0.weightKg,
                                                          bodyFatPct: $0.bodyFatPct, timeOfDay: $0.timeOfDay) }
    }

    public func latest() throws -> BodyweightEntry? { try entries(since: nil).last }

    public func add(_ e: BodyweightEntry) throws {
        context.insert(BodyweightRecord(id: e.id, date: e.date, weightKg: e.weightKg, bodyFatPct: e.bodyFatPct,
                                        timeOfDay: e.timeOfDay, now: now()))
        try context.save()
    }

    public func delete(_ id: UUID) throws {
        guard let r = try context.fetch(FetchDescriptor<BodyweightRecord>(predicate: #Predicate { $0.id == id })).first
        else { return }
        r.deletedAt = now()
        r.updatedAt = now()
        r.dirty = true
        try context.save()
    }
}
```

`Repositories/CustomExerciseRepository.swift`:
```swift
import Foundation
import GymCore
import SwiftData

@MainActor
public final class CustomExerciseRepository {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    public func all() throws -> [Exercise] {
        try context.fetch(FetchDescriptor<CustomExerciseRecord>(predicate: #Predicate { $0.deletedAt == nil },
                                                                sortBy: [SortDescriptor(\.name)]))
            .map { Exercise(id: $0.id, name: $0.name, bodyPart: $0.bodyPart, equipment: $0.equipment, target: $0.target,
                            isCustom: true, mode: ExerciseMode(rawValue: $0.modeRaw)) }
    }

    @discardableResult
    public func create(name: String, bodyPart: String, equipment: String, target: String, mode: ExerciseMode,
                       bilateral: Bool) throws -> Exercise {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!trimmed.isEmpty, "Name required")
        let id = "custom-\(UUID().uuidString.lowercased())"
        context.insert(CustomExerciseRecord(id: id, name: trimmed, bodyPart: bodyPart, equipment: equipment,
                                            target: target, modeRaw: mode.rawValue, bilateral: bilateral, now: now()))
        try context.save()
        return Exercise(id: id, name: trimmed, bodyPart: bodyPart, equipment: equipment, target: target, isCustom: true,
                        mode: mode)
    }
}
```

Run: `swift test` → Expected: PASS (all GymData suites). If `#Predicate` with `$0.isActive == false` fails to
compile, write `!$0.isActive`. For the `bests` predicate on the optional relationship, filter in memory as shown.

- [ ] **Step 3: Commit** `feat(data): repositories for profile, routines, workouts, body, custom exercises`

---

### Task 4: Exercise library and owner seed

**Files:** Create `Library/ExerciseLibrary.swift`, `Seed/OwnerSeed.swift`; Tests `LibraryTests.swift`, `OwnerSeedTests.swift`

- [ ] **Step 1: Failing tests**

`LibraryTests.swift`:
```swift
import Foundation
import GymCore
import Testing
@testable import GymData

@Suite struct LibraryTests {
    static let sample = [
        Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
        Exercise(id: "0314", name: "dumbbell incline bench press", bodyPart: "chest", equipment: "dumbbell", target: "pectorals"),
        Exercise(id: "0198", name: "cable pulldown", bodyPart: "back", equipment: "cable", target: "lats"),
    ]

    @Test func searchByTextAndFilters() {
        let lib = ExerciseLibrary(exercises: Self.sample)
        #expect(lib.search(query: "bench").map(\.id) == ["0025", "0314"])
        #expect(lib.search(query: "BENCH", bodyPart: "chest", equipment: "dumbbell").map(\.id) == ["0314"])
        #expect(lib.search(query: "", bodyPart: "back").map(\.id) == ["0198"])
        #expect(lib.search(query: "pull down").map(\.id) == ["0198"])
    }

    @Test func lookupAndFacets() {
        let lib = ExerciseLibrary(exercises: Self.sample)
        #expect(lib.exercise("0198")?.name == "cable pulldown")
        #expect(lib.bodyParts == ["back", "chest"])
        #expect(lib.equipment == ["barbell", "cable", "dumbbell"])
    }

    @Test func mergingCustomExercises() {
        let custom = Exercise(id: "custom-1", name: "handle band squat to press", bodyPart: "upper legs",
                              equipment: "band", target: "quads", isCustom: true)
        let lib = ExerciseLibrary(exercises: Self.sample).merging(custom: [custom])
        #expect(lib.exercise("custom-1")?.isCustom == true)
        #expect(lib.search(query: "squat").map(\.id) == ["custom-1"])
    }

    @Test func loadsBundledJSON() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() // GymData
            .deletingLastPathComponent().deletingLastPathComponent()                             // ios
            .appendingPathComponent("GymRollins/Resources/exercises.json")
        let lib = try ExerciseLibrary.load(from: url)
        #expect(lib.exercises.count == 1_324)
        #expect(lib.exercise("0025")?.name == "barbell bench press")
    }
}
```

`OwnerSeedTests.swift`:
```swift
import Foundation
import SwiftData
import Testing
@testable import GymData

@MainActor
@Suite struct OwnerSeedTests {
    @Test func seedsSplitScheduleAndProfileOnce() throws {
        let container = try GymStore.container(inMemory: true)
        let context = container.mainContext
        try OwnerSeed.apply(to: context, now: Date(timeIntervalSince1970: 1_790_380_800))
        try OwnerSeed.apply(to: context, now: Date(timeIntervalSince1970: 1_790_380_800))
        let routines = try RoutineRepository(context: context).all()
        #expect(routines.map(\.name) == ["Push + Arms", "Pull + Shoulders + Triceps", "Upper weak points", "Legs"])
        #expect(routines[0].exercises.count == 7)
        #expect(routines[3].paused)
        #expect(try RoutineRepository(context: context).schedule().days[6] == routines[0].id)
        #expect(try ProfileRepository(context: context).load().goalWeightKg == 85)
    }
}
```

- [ ] **Step 2: Implement** `Library/ExerciseLibrary.swift`

```swift
import Foundation
import GymCore

/// Immutable, searchable exercise catalogue (bundled + custom).
public struct ExerciseLibrary: Sendable {
    public let exercises: [Exercise]
    private let byId: [String: Exercise]
    private let searchKeys: [String: String]

    public init(exercises: [Exercise]) {
        self.exercises = exercises
        self.byId = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.searchKeys = Dictionary(exercises.map { ($0.id, Self.key($0.name)) }, uniquingKeysWith: { first, _ in first })
    }

    public static func load(from url: URL) throws -> ExerciseLibrary {
        ExerciseLibrary(exercises: try JSONDecoder().decode([Exercise].self, from: Data(contentsOf: url)))
    }

    public func merging(custom: [Exercise]) -> ExerciseLibrary {
        ExerciseLibrary(exercises: custom + exercises.filter { !$0.isCustom })
    }

    public func exercise(_ id: String) -> Exercise? { byId[id] }

    public var bodyParts: [String] { Array(Set(exercises.map(\.bodyPart))).sorted() }
    public var equipment: [String] { Array(Set(exercises.map(\.equipment))).sorted() }

    /// All query words must appear in the name (order-free, spaces ignored within words).
    public func search(query: String, bodyPart: String? = nil, equipment: String? = nil) -> [Exercise] {
        let words = Self.key(query).split(separator: " ").map(String.init)
        return exercises.filter { ex in
            (bodyPart == nil || ex.bodyPart == bodyPart)
                && (equipment == nil || ex.equipment == equipment)
                && words.allSatisfy { word in
                    let key = searchKeys[ex.id] ?? ""
                    return key.contains(word) || key.replacingOccurrences(of: " ", with: "").contains(word)
                }
        }
    }

    static func key(_ s: String) -> String { ExerciseMatcher.normalize(s) }
}
```
Note: "pull down" must match "cable pulldown". The test covers it: the word "pull" matches directly, and "down"
matches through the space-stripped key. If `ExerciseMatcher.normalize` isn't `public`, make it `public` in GymCore
(a one-line change; commit it with this task).

`Seed/OwnerSeed.swift` (owner's real split; lb loads converted to kg):
```swift
import Foundation
import GymCore
import SwiftData

/// Owner's split for DEBUG builds and UI tests. Idempotent: does nothing if any routine exists.
@MainActor
public enum OwnerSeed {
    static func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }

    static func ex(_ id: String, _ sets: Int, _ reps: Int, _ repsMin: Int? = nil, lb w: Double?, sg: String? = nil) -> RoutineExercise {
        RoutineExercise(exerciseId: id, sets: sets, reps: reps, repsMin: repsMin, weightKg: w.map(lb), incKg: lb(5),
                        supersetGroup: sg)
    }

    public static func apply(to context: ModelContext, now: Date) throws {
        let routines = RoutineRepository(context: context, now: { now })
        guard try routines.all().isEmpty else { return }

        let push = Routine(name: "Push + Arms", exercises: [
            ex("0025", 3, 10, 8, lb: 140),                 // barbell bench press
            ex("0314", 3, 10, 8, lb: 45),                  // dumbbell incline bench press
            ex("0319", 3, 12, 10, lb: 27.5, sg: "A"),      // dumbbell incline fly
            ex("0155", 3, 12, 10, lb: 25, sg: "A"),        // cable cross-over variation
            ex("0194", 3, 10, 8, lb: 40),                  // cable overhead triceps extension (rope)
            ex("0313", 3, 10, 8, lb: 22.5),                // dumbbell hammer curl
            ex("0070", 3, 10, 8, lb: 55),                  // barbell preacher curl
        ])
        let pull = Routine(name: "Pull + Shoulders + Triceps", exercises: [
            ex("0198", 3, 10, 8, lb: 120),                 // cable pulldown
            ex("0861", 3, 12, 10, lb: 120),                // cable seated row
            ex("0541", 3, 12, 10, lb: 44),                 // kettlebell one arm row
            ex("0203", 3, 12, 10, lb: 30),                 // cable rear delt row (rope) — face pull
            ex("0603", 3, 10, 8, lb: 65),                  // lever shoulder press
            ex("0194", 3, 10, 8, lb: 35),                  // rope overhead extension
            ex("0201", 3, 10, 8, lb: 50),                  // cable pushdown
        ])
        let upper = Routine(name: "Upper weak points", exercises: [
            ex("0405", 3, 10, 8, lb: 30),                  // dumbbell seated shoulder press
            ex("0334", 4, 12, 10, lb: 10),                 // dumbbell lateral raise
            ex("0215", 3, 12, 10, lb: 10),                 // cable seated rear lateral raise
            ex("0030", 3, 8, 6, lb: 95),                   // barbell close-grip bench press
            ex("0251", 3, 10, 6, lb: nil),                 // chest dip
            ex("0070", 3, 10, 8, lb: 55),                  // barbell preacher curl
        ])
        let legs = Routine(name: "Legs", paused: true, exercises: [
            ex("0085", 3, 8, 8, lb: 135),                  // barbell romanian deadlift
            ex("0043", 4, 6, 6, lb: 135),                  // barbell full squat
            ex("0739", 3, 10, 8, lb: 170),                 // sled 45° leg press
            ex("0586", 3, 12, 10, lb: 100),                // lever lying leg curl
            ex("0585", 3, 10, 8, lb: 110),                 // lever leg extension
            ex("0594", 4, 15, 12, lb: 195),                // lever seated calf raise
        ])
        for r in [push, pull, upper, legs] { try routines.upsert(r) }
        for (weekday, routine) in [(1, push), (3, pull), (5, upper), (6, push)] {
            try routines.setSchedule(weekday: weekday, routineId: routine.id)
        }
        try ProfileRepository(context: context, now: { now }).save(Profile(
            unit: .lb, heightCm: 185, goalWeightKg: 85,
            goalDate: ISO8601DateFormatter().date(from: "2026-12-31T00:00:00Z"),
            trainingDays: 4, limits: "Knee: no leg loading until ~26 Oct 2026"))
    }
}
```
(`Routine(name:paused:exercises:)` uses the GymCore init's default arguments.)

Run `swift test` → Expected: PASS. **Commit:** `feat(data): exercise library search and owner seed`

---

### Task 5: Xcode project (XcodeGen), app entry, environment, test scripts

**Files:** Create `ios/project.yml`, `ios/Config/Base.xcconfig`, `ios/GymRollins/App/*.swift`,
`ios/GymRollins/Features/Placeholders/ComingSoonView.swift`, `ios/GymRollins/Resources/Assets.xcassets`,
`ios/GymRollinsTests/SmokeTests.swift`, `ios/GymRollinsUITests/ShellUITests.swift`, `scripts/ios-test.sh`;
modify `.gitignore`, `scripts/test-all.sh`, `README.md`.

- [ ] **Step 1: project.yml**

```yaml
name: GymRollins
options:
  bundleIdPrefix: com.rollins
  deploymentTarget: { iOS: "26.0" }
  createIntermediateGroups: true
  developmentLanguage: en
configFiles:
  Debug: Config/Base.xcconfig
  Release: Config/Base.xcconfig
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
packages:
  GymCore: { path: Packages/GymCore }
  GymData: { path: Packages/GymData }
targets:
  GymRollins:
    type: application
    platform: iOS
    sources: [GymRollins]
    dependencies:
      - package: GymCore
      - package: GymData
    info:
      path: GymRollins/Info.plist
      properties:
        CFBundleDisplayName: GymRollins
        UILaunchScreen: {}
        UIAppFonts: [BarlowCondensed-BoldItalic.ttf, BarlowCondensed-ExtraBoldItalic.ttf]
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
        UIUserInterfaceStyle: Dark
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.rollins.gymrollins
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ENABLE_PREVIEWS: YES
        TARGETED_DEVICE_FAMILY: "1"
  GymRollinsTests:
    type: bundle.unit-test
    platform: iOS
    sources: [GymRollinsTests]
    dependencies: [{ target: GymRollins }]
    settings: { base: { GENERATE_INFOPLIST_FILE: YES } }
  GymRollinsUITests:
    type: bundle.ui-testing
    platform: iOS
    sources: [GymRollinsUITests]
    dependencies: [{ target: GymRollins }]
    settings: { base: { GENERATE_INFOPLIST_FILE: YES } }
schemes:
  GymRollins:
    build: { targets: { GymRollins: all } }
    test:
      targets: [GymRollinsTests, GymRollinsUITests]
      gatherCoverageData: true
```

`ios/Config/Base.xcconfig`:
```
// Committed base settings. Put DEVELOPMENT_TEAM etc. in Local.xcconfig (gitignored).
#include? "Local.xcconfig"
CODE_SIGN_STYLE = Automatic
```
Create `ios/Config/Local.xcconfig` locally (NOT committed): `DEVELOPMENT_TEAM = <TEAM_ID>`.
Add to `app/.gitignore`: `ios/Config/Local.xcconfig` and `ios/GymRollins/Info.plist` (generated).

`Resources/Assets.xcassets`: `Contents.json` (`{"info":{"author":"xcode","version":1}}`), an `AccentColor.colorset`
with sRGB `#FF6B72`, and an empty `AppIcon.appiconset` with a single 1024 universal entry (image added later).

- [ ] **Step 2: Launch options** `App/LaunchOptions.swift`

```swift
import Foundation

/// Launch arguments used by UI tests and debug runs.
struct LaunchOptions {
    /// In-memory store (fresh every launch).
    let inMemory: Bool
    /// Seed the owner's split if the store is empty.
    let seedOwner: Bool
    /// Fixed "now" for deterministic UI tests (ISO 8601), e.g. -fixedNow 2026-09-26T09:00:00Z
    let fixedNow: Date?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        inMemory = arguments.contains("-uiTesting")
        #if DEBUG
        seedOwner = arguments.contains("-uiTesting") || arguments.contains("-seedOwner")
        #else
        seedOwner = false
        #endif
        fixedNow = arguments.firstIndex(of: "-fixedNow")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            .flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}
```

- [ ] **Step 3: Environment** `App/AppEnvironment.swift`

```swift
import Foundation
import GymCore
import GymData
import Observation
import SwiftData
import os

/// App-wide dependencies. Created once at launch; injected with `.environment(env)`.
@MainActor
@Observable
final class AppEnvironment {
    let container: ModelContainer
    let now: () -> Date
    let profiles: ProfileRepository
    let routines: RoutineRepository
    let workouts: WorkoutRepository
    let body: BodyRepository
    let customExercises: CustomExerciseRepository
    private let bundledLibrary: ExerciseLibrary
    private(set) var library: ExerciseLibrary
    private(set) var profile: Profile
    /// Bumps whenever routines/schedule change so screens reload.
    private(set) var planRevision = 0

    static let log = Logger(subsystem: "com.rollins.gymrollins", category: "app")

    init(options: LaunchOptions = LaunchOptions()) throws {
        let container = try GymStore.container(inMemory: options.inMemory)
        let fixed = options.fixedNow
        let now: () -> Date = { fixed ?? Date() }
        let context = container.mainContext
        if options.seedOwner { try OwnerSeed.apply(to: context, now: now()) }
        guard let url = Bundle.main.url(forResource: "exercises", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.container = container
        self.now = now
        self.profiles = ProfileRepository(context: context, now: now)
        self.routines = RoutineRepository(context: context, now: now)
        self.workouts = WorkoutRepository(context: context, now: now)
        self.body = BodyRepository(context: context, now: now)
        self.customExercises = CustomExerciseRepository(context: context, now: now)
        self.bundledLibrary = try ExerciseLibrary.load(from: url)
        self.library = bundledLibrary.merging(custom: try customExercises.all())
        self.profile = try profiles.load()
    }

    func reloadLibrary() {
        do { library = bundledLibrary.merging(custom: try customExercises.all()) }
        catch { Self.log.error("Reload library failed: \(error.localizedDescription, privacy: .public)") }
    }

    func reloadProfile() {
        do { profile = try profiles.load() }
        catch { Self.log.error("Reload profile failed: \(error.localizedDescription, privacy: .public)") }
    }

    func planChanged() { planRevision += 1 }
}
```

- [ ] **Step 4: App + root** `App/GymRollinsApp.swift`, `App/RootView.swift`

```swift
import SwiftUI

@main
struct GymRollinsApp: App {
    @State private var boot = Boot()

    var body: some Scene {
        WindowGroup {
            switch boot.state {
            case .ready(let env):
                RootView().environment(env)
            case .failed(let message):
                ContentUnavailableView("Can't open your data", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            }
        }
    }
}

@MainActor
@Observable
final class Boot {
    enum State { case ready(AppEnvironment), failed(String) }
    let state: State

    init() {
        do { state = .ready(try AppEnvironment()) }
        catch {
            AppEnvironment.log.fault("Boot failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("Restart the app. If it keeps happening, reinstall it; your synced data is safe.")
        }
    }
}
```

```swift
import SwiftUI

enum AppTab: Hashable { case today, body, library, log }

struct RootView: View {
    @State private var tab: AppTab = .today

    var body: some View {
        TabView(selection: $tab) {
            Tab("Today", systemImage: "dumbbell", value: .today) { TodayView() }
            Tab("Body", systemImage: "figure.stand", value: .body) {
                ComingSoonView(title: "Body", message: "Bodyweight and trends arrive in the next build.")
            }
            Tab("Library", systemImage: "books.vertical", value: .library) { LibraryView() }
            Tab("Log", systemImage: "calendar", value: .log) {
                ComingSoonView(title: "Log", message: "Your workout history arrives in the next build.")
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}
```

`Features/Placeholders/ComingSoonView.swift`:
```swift
import SwiftUI

struct ComingSoonView: View {
    let title: String
    let message: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: "hammer", description: Text(message))
                .navigationTitle(title)
                .background(Theme.background)
        }
    }
}
```
(Placeholders are replaced in plan 04; they exist so the tab shell ships now.)

- [ ] **Step 5: Test script** `scripts/ios-test.sh`

```bash
#!/usr/bin/env bash
# Generates the Xcode project and runs app unit + UI tests on the iOS 26 simulator.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${DEST:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2}"
cd "$ROOT/ios"
xcodegen generate --quiet
xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins -destination "$DEST" \
  -resultBundlePath "$ROOT/ios/build/TestResults-$(date +%s).xcresult" "$@" | xcbeautify 2>/dev/null || \
xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins -destination "$DEST" "$@"
```
Simpler alternative if `xcbeautify` isn't installed: drop the pipe. Use `set -o pipefail` semantics so failures
propagate. (Implementer: keep exactly one `xcodebuild test` invocation; add `-quiet` if `xcbeautify` is absent.)

Append to `scripts/test-all.sh`:
```bash
echo "==> GymData (swift test)"
(cd "$ROOT/ios/Packages/GymData" && swift test)

echo "==> iOS app unit + UI tests"
"$ROOT/scripts/ios-test.sh"
```

- [ ] **Step 6: Smoke tests**

`GymRollinsTests/SmokeTests.swift`:
```swift
import Testing
@testable import GymRollins

@MainActor
@Suite struct SmokeTests {
    @Test func environmentBootsInMemoryWithSeed() throws {
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]))
        #expect(env.library.exercises.count >= 1_324)
        #expect(try env.routines.all().count == 4)
        #expect(env.profile.unit == .lb)
    }
}
```

`GymRollinsUITests/ShellUITests.swift`:
```swift
import XCTest

final class ShellUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testFourTabsExist() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launch()
        for name in ["Today", "Body", "Library", "Log"] {
            XCTAssertTrue(app.tabBars.buttons[name].waitForExistence(timeout: 5), "missing tab \(name)")
        }
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
    }
}
```

Run: `scripts/ios-test.sh` → Expected: `** TEST SUCCEEDED **` (TodayView/LibraryView are compiled from Tasks 6–8; to
land Task 5 alone, create minimal `TodayView` and `LibraryView` stubs returning `NavigationStack { Text("…") .navigationTitle("Today"/"Library") }`
and replace them in Tasks 7–8).

- [ ] **Step 7: Commit** `feat(ios): XcodeGen project, app environment, Liquid Glass tab shell, test scripts`

---

### Task 6: Design system

**Files:** Create `DesignSystem/*.swift`; Test `GymRollinsTests/DisplayNameTests.swift`

- [ ] **Step 1: Failing test**

```swift
import Testing
@testable import GymRollins

@Suite struct DisplayNameTests {
    @Test(arguments: [
        ("barbell bench press", "Barbell Bench Press"),
        ("cable overhead triceps extension (rope attachment)", "Cable Overhead Triceps Extension (Rope Attachment)"),
        ("sled 45° leg press", "Sled 45° Leg Press"),
        ("ez-bar close-grip bench press", "EZ-Bar Close-Grip Bench Press"),
        ("dumbbell incline bench press v. 2", "Dumbbell Incline Bench Press V. 2"),
    ])
    func titleCases(input: String, expected: String) {
        #expect(DisplayName.of(input) == expected)
    }
}
```

- [ ] **Step 2: Implement**

`DesignSystem/Theme.swift`:
```swift
import SwiftUI

/// Tokens from docs/design/STYLE.md.
enum Theme {
    static let background = Color(hex: 0x0B0B10)
    static let card = Color(hex: 0x17171E)
    static let cardInner = Color(hex: 0x262631)
    static let divider = Color(hex: 0x25252E)
    static let textPrimary = Color(hex: 0xF2F2F5)
    static let textSecondary = Color(hex: 0xA9A9B5)
    static let textTertiary = Color(hex: 0x8E8E9A)
    static let accent = Color(hex: 0xFF6B72)
    static let primaryFill = Color(hex: 0xD63A46)
    static let success = Color(hex: 0x4FD1A5)
    static let successFill = Color(hex: 0x14342A)
    static let record = Color(hex: 0xF5B75A)
    static let destructive = Color(hex: 0xFF8A8F)

    static let cardRadius: CGFloat = 18
    static let gutter: CGFloat = 20

    /// Condensed italic display face for screen/sheet titles and big numbers.
    static func display(_ size: CGFloat, heavy: Bool = true) -> Font {
        .custom(heavy ? "BarlowCondensed-ExtraBoldItalic" : "BarlowCondensed-BoldItalic", size: size, relativeTo: .largeTitle)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
```

`DesignSystem/Glass.swift` (iOS 26 Liquid Glass wrappers so screens stay consistent):
```swift
import SwiftUI

extension View {
    /// Glass capsule for chips, pills and floating bars.
    func glassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: .capsule)
            .modifier(InteractiveGlass(enabled: interactive))
    }

    /// Glass circle for icon buttons (44 pt).
    func glassCircle() -> some View {
        frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: .circle)
    }
}

private struct InteractiveGlass: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View { content } // `.interactive()` is applied via the Glass value when needed
}

/// Full-width primary action (one per screen).
struct PrimaryGlassButton: View {
    let title: String
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.primaryFill)
        .accessibilityIdentifier(identifier ?? title)
    }
}

/// Secondary glass pill button.
struct GlassPillButton: View {
    let title: String
    var systemImage: String? = nil
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier(identifier ?? title)
    }
}
```
Implementation note: if `glassEffect(_:in:)` with an optional-mapped `Glass` doesn't type-check, split it into
`if let tint { content.glassEffect(.regular.tint(tint).interactive(), in: .capsule) } else { content.glassEffect(.regular.interactive(), in: .capsule) }`
using a `@ViewBuilder` helper, and delete `InteractiveGlass`. Keep the public API (`glassCapsule`, `glassCircle`,
`PrimaryGlassButton`, `GlassPillButton`) unchanged.

`DesignSystem/Components.swift`:
```swift
import SwiftUI

struct SolidCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .kerning(1)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// Small colored badge, e.g. "+5 lb" (success) or "Paused" (record/amber).
struct Badge: View {
    enum Kind { case success, record, neutral }
    let text: String
    let kind: Kind

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(foreground)
            .background(background, in: .rect(cornerRadius: 6))
    }

    private var foreground: Color {
        switch kind { case .success: Theme.success; case .record: Theme.record; case .neutral: Theme.textSecondary }
    }
    private var background: Color {
        switch kind {
        case .success: Theme.successFill
        case .record: Theme.record.opacity(0.14)
        case .neutral: Theme.cardInner
        }
    }
}

/// Screen title in the condensed italic display face.
struct DisplayTitle: View {
    let text: String
    var size: CGFloat = 44
    var body: some View {
        Text(text).font(Theme.display(size)).foregroundStyle(Theme.textPrimary)
    }
}
```

`DesignSystem/BodyPartIcon.swift` (stand-in for exercise media, which isn't licensed):
```swift
import SwiftUI

struct BodyPartIcon: View {
    let bodyPart: String
    var size: CGFloat = 52

    var body: some View {
        Image(systemName: Self.symbol(for: bodyPart))
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: size, height: size)
            .background(Theme.cardInner, in: .rect(cornerRadius: size * 0.23))
            .accessibilityHidden(true)
    }

    static func symbol(for bodyPart: String) -> String {
        switch bodyPart {
        case "chest": "figure.strengthtraining.traditional"
        case "back": "figure.rower"
        case "shoulders": "figure.arms.open"
        case "upper arms": "dumbbell"
        case "lower arms": "hand.raised"
        case "upper legs": "figure.step.training"
        case "lower legs": "figure.walk"
        case "waist": "figure.core.training"
        case "cardio": "heart"
        case "neck": "person.bust"
        default: "figure.mixed.cardio"
        }
    }
}
```

`DesignSystem/DisplayName.swift`:
```swift
import Foundation

enum DisplayName {
    private static let upper: Set<String> = ["ez", "db", "bb", "sz", "rdl"]

    /// "barbell bench press" -> "Barbell Bench Press"; keeps punctuation, uppercases known abbreviations.
    static func of(_ raw: String) -> String {
        raw.split(separator: " ", omittingEmptySubsequences: false).map { word in
            word.split(separator: "-", omittingEmptySubsequences: false).map { part -> String in
                let lower = part.lowercased()
                if upper.contains(lower) { return lower.uppercased() }
                if lower.hasPrefix("(") { return "(" + capitalizeFirst(String(lower.dropFirst())) }
                return capitalizeFirst(lower)
            }.joined(separator: "-")
        }.joined(separator: " ")
    }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
```

`DesignSystem/ExerciseRow.swift`:
```swift
import GymCore
import SwiftUI

/// Solid content row: icon, name, subtitle, optional trailing badge.
struct ExerciseRow: View {
    let exercise: Exercise?
    let fallbackName: String
    let subtitle: String
    var badge: Badge? = nil

    var body: some View {
        HStack(spacing: 12) {
            BodyPartIcon(bodyPart: exercise?.bodyPart ?? "")
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayName.of(exercise?.name ?? fallbackName))
                    .font(.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            if let badge { badge }
        }
        .padding(10)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .combine)
    }
}
```

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/DisplayNameTests` → PASS. **Commit:** `feat(ios): design system tokens, glass components, rows`

---

### Task 7: Library, exercise detail, custom exercise

**Files:** Create `Features/Library/LibraryView.swift`, `ExerciseDetailView.swift`, `CustomExerciseView.swift`;
UI test `GymRollinsUITests/LibraryUITests.swift`. Mockups: `docs/design/Library.dc.html`, `HowTo.dc.html`,
`CustomExercise.dc.html`.

Identifiers: search field `library.search`; body-part chips `library.filter.<bodyPart>` plus `library.filter.all`;
rows `library.row.<id>`; add button `library.add`; detail title `detail.title`; custom form fields `custom.name`,
`custom.save`.

- [ ] **Step 1: Failing UI test** `LibraryUITests.swift`

```swift
import XCTest

final class LibraryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launch()
        app.tabBars.buttons["Library"].tap()
    }

    func testSearchAndOpenDetail() {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("barbell bench press")
        let row = app.buttons["library.row.0025"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detail.title"].label, "Barbell Bench Press")
        XCTAssertTrue(app.staticTexts["Instructions"].exists)
    }

    func testFilterByBodyPart() {
        app.buttons["library.filter.back"].tap()
        XCTAssertTrue(app.buttons["library.row.0198"].waitForExistence(timeout: 5)) // cable pulldown
        XCTAssertFalse(app.buttons["library.row.0025"].exists)
    }

    func testCreateCustomExercise() {
        app.buttons["library.add"].tap()
        let name = app.textFields["custom.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Handle Band Squat to Press")
        app.buttons["custom.save"].tap()
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("handle band squat")
        XCTAssertTrue(app.staticTexts["Handle Band Squat To Press"].waitForExistence(timeout: 5))
    }
}
```

- [ ] **Step 2: Implement**

`LibraryView.swift`:
```swift
import GymCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var bodyPart: String? = nil
    @State private var showCreate = false

    private var results: [Exercise] {
        env.library.search(query: query, bodyPart: bodyPart)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    filterBar
                    Text("\(results.count) exercises")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                    ForEach(results.prefix(200)) { ex in
                        NavigationLink(value: ex.id) {
                            ExerciseRow(exercise: ex, fallbackName: ex.name,
                                        subtitle: "\(DisplayName.of(ex.bodyPart)) · \(DisplayName.of(ex.equipment))",
                                        badge: ex.isCustom ? Badge(text: "Custom", kind: .neutral) : nil)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.row.\(ex.id)")
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 100)
            }
            .background(Theme.background)
            .navigationTitle("Library")
            .searchable(text: $query, prompt: "Search exercises")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreate = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New exercise")
                        .accessibilityIdentifier("library.add")
                }
            }
            .navigationDestination(for: String.self) { id in ExerciseDetailView(exerciseId: id) }
            .sheet(isPresented: $showCreate) { CustomExerciseView() }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    chip(title: "All", id: "all", selected: bodyPart == nil) { bodyPart = nil }
                    ForEach(env.library.bodyParts, id: \.self) { part in
                        chip(title: DisplayName.of(part), id: part, selected: bodyPart == part) { bodyPart = part }
                    }
                }
            }
        }
    }

    private func chip(title: String, id: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(selected ? .bold : .semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(selected ? Theme.background : Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .glassCapsule(tint: selected ? Theme.textPrimary : nil)
        .accessibilityIdentifier("library.filter.\(id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
```

`ExerciseDetailView.swift`:
```swift
import GymCore
import SwiftUI

struct ExerciseDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let exerciseId: String
    @State private var tab = 0

    var body: some View {
        if let ex = env.library.exercise(exerciseId) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    BodyPartIcon(bodyPart: ex.bodyPart, size: 120)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .background(Theme.card, in: .rect(cornerRadius: 24))
                    Text(DisplayName.of(ex.name)).font(Theme.display(34))
                        .accessibilityIdentifier("detail.title")
                    Picker("Section", selection: $tab) {
                        Text("Instructions").tag(0)
                        Text("Muscles").tag(1)
                        Text("Equipment").tag(2)
                    }
                    .pickerStyle(.segmented)
                    content(ex)
                }
                .padding(Theme.gutter)
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Exercise not found", systemImage: "questionmark")
        }
    }

    @ViewBuilder
    private func content(_ ex: Exercise) -> some View {
        switch tab {
        case 0:
            SectionLabel(text: "Instructions")
            if ex.instructions.isEmpty {
                Text("No instructions for this exercise yet.").foregroundStyle(Theme.textSecondary)
            }
            ForEach(Array(ex.instructions.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)").font(Theme.display(22)).foregroundStyle(Theme.accent)
                    Text(step).foregroundStyle(Theme.textPrimary)
                }
            }
        case 1:
            SolidCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Target: \(DisplayName.of(ex.target))").font(.headline)
                    if !ex.secondary.isEmpty {
                        Text("Secondary: \(ex.secondary.map(DisplayName.of).joined(separator: ", "))")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        default:
            SolidCard { Text(DisplayName.of(ex.equipment)).font(.headline) }
        }
    }
}
```
(The instructions segment always renders `SectionLabel(text: "Instructions")`, whose accessibility label is
"INSTRUCTIONS". The UI test asserts `staticTexts["Instructions"]`, which is the segmented-picker item, and that also
exists.)

`CustomExerciseView.swift`:
```swift
import GymCore
import SwiftUI

struct CustomExerciseView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bodyPart = "chest"
    @State private var equipment = "dumbbell"
    @State private var mode: ExerciseMode = .reps
    @State private var bilateral = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name).accessibilityIdentifier("custom.name")
                Picker("Body part", selection: $bodyPart) {
                    ForEach(env.library.bodyParts, id: \.self) { Text(DisplayName.of($0)).tag($0) }
                }
                Picker("Equipment", selection: $equipment) {
                    ForEach(env.library.equipment, id: \.self) { Text(DisplayName.of($0)).tag($0) }
                }
                Picker("Logging", selection: $mode) {
                    Text("Weight × reps").tag(ExerciseMode.reps)
                    Text("Time").tag(ExerciseMode.time)
                    Text("Cardio").tag(ExerciseMode.cardio)
                }
                .pickerStyle(.segmented)
                Toggle("Uses both dumbbells (count weight × 2 for volume)", isOn: $bilateral)
                if let error { Text(error).foregroundStyle(Theme.destructive) }
            }
            .navigationTitle("New Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("custom.save")
                }
            }
        }
    }

    private func save() {
        do {
            try env.customExercises.create(name: name, bodyPart: bodyPart, equipment: equipment, target: bodyPart,
                                           mode: mode, bilateral: bilateral)
            env.reloadLibrary()
            dismiss()
        } catch {
            AppEnvironment.log.error("Create exercise failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save the exercise. Try again."
        }
    }
}
```

Run: `scripts/ios-test.sh -only-testing:GymRollinsUITests/LibraryUITests` → PASS. **Commit:** `feat(ios): library search, filters, exercise detail, custom exercises`

---

### Task 8: Today screen

**Files:** Create `Features/Today/TodayModel.swift`, `TodayView.swift`; Tests `GymRollinsTests/TodayModelTests.swift`,
`GymRollinsUITests/ShellUITests.swift` (add a test). Mockup: `docs/design/Main.dc.html`.

`TodayModel` is a pure function of (routine, profile, history, library), so it's unit-tested without UI.

- [ ] **Step 1: Failing tests** `TodayModelTests.swift`

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@Suite struct TodayModelTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private let library = ExerciseLibrary(exercises: [
        Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
    ])

    @Test func rowShowsPlanAndIncreaseBadge() {
        let routine = Routine(name: "Push + Arms", exercises: [
            RoutineExercise(exerciseId: "0025", sets: 3, reps: 10, repsMin: 8, weightKg: lb(130), incKg: lb(5))])
        let history = ["0025": [SessionResult(date: .now, weightKg: lb(130), reps: [10, 10, 10])]]
        let model = TodayModel.make(routine: routine, profile: Profile(), library: library,
                                    history: { history[$0] ?? [] })
        #expect(model.title == "Push + Arms")
        #expect(model.rows.count == 1)
        #expect(model.rows[0].name == "Barbell Bench Press")
        #expect(model.rows[0].subtitle == "3 × 8–10 · 135 lb (61.2 kg)")
        #expect(model.rows[0].badge == "+5 lb")
        #expect(model.summary == "1 exercise")
    }

    @Test func noBadgeOnFirstSession() {
        let routine = Routine(name: "Push", exercises: [
            RoutineExercise(exerciseId: "0025", sets: 3, reps: 8, weightKg: lb(140), incKg: lb(5))])
        let model = TodayModel.make(routine: routine, profile: Profile(), library: library, history: { _ in [] })
        #expect(model.rows[0].subtitle == "3 × 8 · 140 lb (63.5 kg)")
        #expect(model.rows[0].badge == nil)
    }

    @Test func restDay() {
        let model = TodayModel.make(routine: nil, profile: Profile(), library: library, history: { _ in [] })
        #expect(model.rows.isEmpty)
        #expect(model.title == "Rest day")
    }
}
```

- [ ] **Step 2: Implement** `TodayModel.swift`

```swift
import Foundation
import GymCore
import GymData

struct TodayModel: Equatable {
    struct Row: Equatable, Identifiable {
        let id: UUID
        let exerciseId: String
        let name: String
        let bodyPart: String
        let subtitle: String
        let badge: String?
        let suggestedKg: Double?
    }

    let routineId: UUID?
    let title: String
    let summary: String
    let rows: [Row]

    static func make(routine: Routine?, profile: Profile, library: ExerciseLibrary,
                     history: (String) -> [SessionResult]) -> TodayModel {
        guard let routine else { return TodayModel(routineId: nil, title: "Rest day", summary: "Recover and eat well", rows: []) }
        let engine = ProgressionEngine(rounder: profile.barbellRounder, deloadPct: profile.deloadPct)
        let rows = routine.exercises.map { item -> Row in
            let ex = library.exercise(item.exerciseId)
            let past = history(item.exerciseId)
            let target = ProgressionTarget(sets: item.sets, reps: item.reps, repsMin: item.repsMin, sec: item.sec,
                                           weightKg: item.weightKg ?? 0, incKg: item.incKg ?? UnitConverter.toKg(5, from: .lb),
                                           weightSetAt: item.weightSetAt)
            let suggestion = engine.suggest(policy: item.policy ?? routine.policy, target: target, history: past)
            let reps = item.repsMin.map { $0 < item.reps ? "\($0)–\(item.reps)" : "\(item.reps)" } ?? "\(item.reps)"
            let load = suggestion.weightKg > 0
                ? " · " + WeightFormatter.format(kg: suggestion.weightKg, unit: profile.unit)
                : ""
            let delta = past.first.map { suggestion.weightKg - $0.weightKg } ?? 0
            let badge = delta > 0.01
                ? "+\(WeightFormatter.format(kg: delta, unit: profile.unit, includeSecondary: false))"
                : nil
            return Row(id: item.id, exerciseId: item.exerciseId, name: DisplayName.of(ex?.name ?? item.exerciseId),
                       bodyPart: ex?.bodyPart ?? "", subtitle: "\(item.sets) × \(reps)\(load)", badge: badge,
                       suggestedKg: suggestion.weightKg > 0 ? suggestion.weightKg : nil)
        }
        let count = rows.count == 1 ? "1 exercise" : "\(rows.count) exercises"
        return TodayModel(routineId: routine.id, title: routine.name, summary: count, rows: rows)
    }
}
```
Note: the first test's routine weight is 130 lb and the history is 3 × 10 @ 130, so double progression suggests
135 lb. The subtitle shows the **suggested** load, and the badge shows the increase over the last session.
Prerequisite from plan 01's Codex fixes: `RoutineExercise.weightSetAt` and `ProgressionTarget(weightSetAt:)` exist
(the "planned" override applies only when the plan weight was set after the last session). The owner seed
leaves `weightSetAt` nil, so seeded weights act as first-session targets and history wins afterwards.

`TodayView.swift` (mockup Main.dc.html: header with avatar + "My Plan ›", italic "Today", summary, chips, solid rows,
floating prominent "Start Workout"):
```swift
import GymCore
import GymData
import SwiftUI

struct TodayView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = TodayModel(routineId: nil, title: "", summary: "", rows: [])
    @State private var showPlan = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    VStack(alignment: .leading, spacing: 4) {
                        DisplayTitle(text: "Today", size: 48)
                        Text("\(model.title) · \(model.summary)")
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityIdentifier("today.summary")
                    }
                    if !env.profile.limits.isEmpty {
                        Text(env.profile.limits).font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(Theme.record)
                            .glassCapsule(tint: Theme.record.opacity(0.25), interactive: false)
                    }
                    if let loadError { Text(loadError).foregroundStyle(Theme.destructive) }
                    ForEach(model.rows) { row in
                        ExerciseRow(exercise: env.library.exercise(row.exerciseId), fallbackName: row.name,
                                    subtitle: row.subtitle,
                                    badge: row.badge.map { Badge(text: $0, kind: .success) })
                            .accessibilityIdentifier("today.row.\(row.exerciseId)")
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 170)
            }
            .background(Theme.background)
            .safeAreaInset(edge: .bottom) {
                if !model.rows.isEmpty {
                    PrimaryGlassButton(title: "Start Workout", identifier: "today.start") {
                        // Workout flow lands in plan 03.
                    }
                    .padding(.horizontal, Theme.gutter).padding(.bottom, 8)
                }
            }
            .navigationDestination(isPresented: $showPlan) { PlanView() }
            .task(id: env.planRevision) { reload() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("R").font(.headline).glassCircle().accessibilityLabel("Profile")
            Button { showPlan = true } label: { Text("My Plan ›").font(.subheadline.weight(.semibold)) }
                .buttonStyle(.glass)
                .accessibilityIdentifier("today.myPlan")
            Spacer()
            Text(env.now().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(.footnote).foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 8)
    }

    private func reload() {
        do {
            let schedule = try env.routines.schedule()
            let routine = try schedule.routineId(on: env.now()).flatMap { try env.routines.routine($0) }
            model = TodayModel.make(routine: routine?.paused == true ? nil : routine, profile: env.profile,
                                    library: env.library,
                                    history: { (try? env.workouts.history(exerciseId: $0, limit: 5)) ?? [] })
            loadError = nil
        } catch {
            AppEnvironment.log.error("Today load failed: \(error.localizedDescription, privacy: .public)")
            loadError = "Couldn't load today's plan."
        }
    }
}
```

Add to `ShellUITests.swift`:
```swift
    func testTodayShowsSaturdayPushDay() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launch()
        XCTAssertTrue(app.staticTexts["today.summary"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["today.summary"].label, "Push + Arms · 7 exercises")
        XCTAssertTrue(app.buttons["today.start"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["today.row.0025"].exists)
    }
```

Run: `scripts/ios-test.sh` → PASS. **Commit:** `feat(ios): Today screen with schedule and progression suggestions`

---

### Task 9: My Plan and Edit Routine

**Files:** Create `Features/Plan/PlanView.swift`, `RoutineEditView.swift`, `ExercisePickerView.swift`;
UI test `GymRollinsUITests/PlanUITests.swift`. Mockups: `Plan.dc.html`, `RoutineEdit.dc.html`, `AddExercise.dc.html`.

Identifiers: week cells `plan.day.<1-7>`; routine rows `plan.routine.<name>`; add routine `plan.addRoutine`;
editor name field `edit.name`; editor rows `edit.row.<exerciseId>`; sets/reps/weight steppers
`edit.sets.<exerciseId>`, `edit.reps.<exerciseId>`, `edit.weight.<exerciseId>`; add exercise `edit.addExercise`;
save `edit.done`; picker search uses the system search field; picker rows `picker.row.<id>`; picker confirm
`picker.add`.

- [ ] **Step 1: Failing UI test** `PlanUITests.swift`

```swift
import XCTest

final class PlanUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]
        app.launch()
        app.buttons["today.myPlan"].tap()
    }

    func testPlanShowsWeekAndRoutines() {
        XCTAssertTrue(app.buttons["plan.routine.Push + Arms"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["plan.routine.Legs"].exists)
        XCTAssertTrue(app.staticTexts["Paused"].exists)
    }

    func testEditRoutineAddsExerciseAndChangesSets() {
        app.buttons["plan.routine.Push + Arms"].tap()
        let sets = app.steppers["edit.sets.0025"]
        XCTAssertTrue(sets.waitForExistence(timeout: 5))
        sets.buttons["Increment"].tap()
        app.buttons["edit.addExercise"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("chest dip")
        app.buttons["picker.row.0251"].tap()
        app.buttons["picker.add"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["edit.row.0251"].waitForExistence(timeout: 5))
        app.buttons["edit.done"].tap()
        app.buttons["plan.routine.Push + Arms"].tap()
        XCTAssertTrue(app.staticTexts["4 sets"].waitForExistence(timeout: 5))
    }
}
```

- [ ] **Step 2: Implement**

`PlanView.swift`:
```swift
import GymCore
import GymData
import SwiftUI

struct PlanView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var routines: [Routine] = []
    @State private var schedule = WeekSchedule(days: [:])
    @State private var editing: Routine?
    @State private var error: String?
    private let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DisplayTitle(text: "My Plan")
                SectionLabel(text: "This week")
                week
                SectionLabel(text: "Routines")
                ForEach(routines) { routine in
                    Button { editing = routine } label: { routineRow(routine) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("plan.routine.\(routine.name)")
                }
                GlassPillButton(title: "+ Routine", identifier: "plan.addRoutine") {
                    editing = Routine(name: "New routine")
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

    private var week: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { day in
                Menu {
                    Button("Rest") { assign(day, nil) }
                    ForEach(routines.filter { !$0.paused }) { r in Button(r.name) { assign(day, r.id) } }
                } label: {
                    VStack(spacing: 4) {
                        Text(dayNames[day - 1]).font(.caption2).foregroundStyle(Theme.textTertiary)
                        Text(shortName(schedule.days[day])).font(.caption.weight(.semibold))
                            .foregroundStyle(schedule.days[day] == nil ? Theme.textTertiary : Theme.textPrimary)
                            .lineLimit(2).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Theme.card, in: .rect(cornerRadius: 12))
                }
                .accessibilityIdentifier("plan.day.\(day)")
            }
        }
    }

    private func routineRow(_ r: Routine) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.headline).foregroundStyle(Theme.textPrimary)
                Text("\(r.exercises.count) exercises").font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if r.paused { Badge(text: "Paused", kind: .record) }
            Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary)
        }
        .padding(14)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        .opacity(r.paused ? 0.7 : 1)
    }

    private func shortName(_ id: UUID?) -> String {
        guard let id, let r = routines.first(where: { $0.id == id }) else { return "Rest" }
        return r.name.components(separatedBy: " + ").first ?? r.name
    }

    private func assign(_ day: Int, _ routineId: UUID?) {
        do { try env.routines.setSchedule(weekday: day, routineId: routineId); env.planChanged() }
        catch { self.error = "Couldn't update the schedule." }
    }

    private func reload() {
        do { routines = try env.routines.all(); schedule = try env.routines.schedule(); error = nil }
        catch { self.error = "Couldn't load your plan." }
    }
}
```

`RoutineEditView.swift`:
```swift
import GymCore
import SwiftUI

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
                    TextField("Routine name", text: $name).accessibilityIdentifier("edit.name")
                    Toggle("Paused", isOn: $paused)
                }
                Section("Exercises") {
                    ForEach(items) { item in row(item) }
                        .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { items.remove(atOffsets: $0) }
                    Button("+ Add exercise") { showPicker = true }.accessibilityIdentifier("edit.addExercise")
                }
                if let error { Text(error).foregroundStyle(Theme.destructive) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .environment(\.editMode, .constant(.active))
            .navigationTitle(name.isEmpty ? "Routine" : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save).buttonStyle(.glassProminent).tint(Theme.primaryFill)
                        .accessibilityIdentifier("edit.done")
                }
            }
            .sheet(isPresented: $showPicker) {
                ExercisePickerView(excluded: Set(items.map(\.exerciseId))) { ids in
                    items += ids.map { RoutineExercise(exerciseId: $0, sets: 3, reps: 10, repsMin: 8,
                                                       incKg: UnitConverter.toKg(5, from: .lb)) }
                }
            }
        }
    }

    private func row(_ item: RoutineExercise) -> some View {
        let ex = env.library.exercise(item.exerciseId)
        return VStack(alignment: .leading, spacing: 6) {
            Text(DisplayName.of(ex?.name ?? item.exerciseId)).font(.headline)
            Stepper("\(item.sets) sets", value: binding(item, \.sets, 1...10))
                .accessibilityIdentifier("edit.sets.\(item.exerciseId)")
            Stepper("\(item.repsMin.map { "\($0)–" } ?? "")\(item.reps) reps", value: binding(item, \.reps, 1...50))
                .accessibilityIdentifier("edit.reps.\(item.exerciseId)")
            Stepper(item.weightKg.map { WeightFormatter.format(kg: $0, unit: env.profile.unit) } ?? "Bodyweight",
                    value: weightBinding(item), step: 1)
                .accessibilityIdentifier("edit.weight.\(item.exerciseId)")
        }
        .accessibilityIdentifier("edit.row.\(item.exerciseId)")
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
        let rounder = env.profile.barbellRounder
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
                                       weightSetAt: weightChanged ? env.now() : item.weightSetAt,
                                       mode: item.mode, policy: item.policy, incKg: item.incKg,
                                       supersetGroup: item.supersetGroup)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { error = "Give the routine a name."; return }
        do {
            try env.routines.upsert(Routine(id: routine.id, name: trimmed, emoji: routine.emoji, policy: routine.policy,
                                            paused: paused, exercises: items))
            env.planChanged()
            dismiss()
        } catch {
            AppEnvironment.log.error("Save routine failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save the routine. Try again."
        }
    }
}
```
(`items` is `@State` view state: the array is replaced element-by-element with new immutable values; the domain values
stay immutable.)

`ExercisePickerView.swift`:
```swift
import GymCore
import SwiftUI

struct ExercisePickerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let excluded: Set<String>
    let onAdd: ([String]) -> Void
    @State private var query = ""
    @State private var selected: [String] = []

    var body: some View {
        NavigationStack {
            List(env.library.search(query: query).filter { !excluded.contains($0.id) }.prefix(150)) { ex in
                Button { toggle(ex.id) } label: {
                    HStack {
                        BodyPartIcon(bodyPart: ex.bodyPart, size: 36)
                        Text(DisplayName.of(ex.name)).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: selected.contains(ex.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(ex.id) ? Theme.success : Theme.textTertiary)
                    }
                }
                .accessibilityIdentifier("picker.row.\(ex.id)")
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
            .navigationTitle("Add Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.count <= 1 ? "Add" : "Add \(selected.count)") { onAdd(selected); dismiss() }
                        .disabled(selected.isEmpty)
                        .accessibilityIdentifier("picker.add")
                }
            }
        }
    }

    private func toggle(_ id: String) {
        selected = selected.contains(id) ? selected.filter { $0 != id } : selected + [id]
    }
}
```

Run: `scripts/ios-test.sh` → PASS (all unit + UI tests). **Commit:** `feat(ios): My Plan week schedule and routine editor`

---

### Task 10: Verify, review, merge

- [ ] **Step 1:** `scripts/test-all.sh` → all suites green (GymCore, GymData, iOS unit + UI).
- [ ] **Step 2:** `swiftlint lint --quiet ios` → no errors.
- [ ] **Step 3: Visual check.** Boot the simulator with the seed (`xcrun simctl launch booted com.rollins.gymrollins -seedOwner -fixedNow 2026-09-26T09:00:00Z`
  after `xcodebuild build`), and take screenshots of Today, Library, detail, Plan and Edit into
  `docs/screenshots/plan-02/` with `xcrun simctl io booted screenshot <file>`. Compare them against the mockups and
  fix obvious deviations (spacing, the glass controls actually rendering as glass, the dark background).
- [ ] **Step 4: Codex review** from `app/`:
  `codex review --base main "Review the iOS app shell, GymData SwiftData repositories and SwiftUI screens for correctness, SwiftData pitfalls (predicates, relationship cascade, main-actor use), Swift 6 concurrency, accessibility, and adherence to docs/specs. Report file:line with severity."`
  Fix CRITICAL/HIGH findings test-first.
- [ ] **Step 5: Merge** `git checkout main && git merge --no-ff plan-02-app-shell -m "merge: plan 02 app shell" && git branch -d plan-02-app-shell`
