# Plan 01: Repo scaffold + GymCore domain

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure-Swift `GymCore` package: units, 1RM, plates, load rounding, domain models, warm-ups,
progression engine, workout clock, metrics and PRs, the Fitbod CSV importer, the exercise matcher and the plan-change
validator. Everything is test-driven and runs with `swift test` on the Mac.

**Architecture:** GymCore is a Swift package with no I/O and no UI. Every type is a `Sendable` value type with `let`
properties (immutable; changes return new values). Later plans import it from the iOS app (plan 02) and mirror
the plan-change validator in TypeScript (plan 05) using the shared fixture `app/fixtures/plan-changes.json`.

**Tech Stack:** Swift 6.2, Swift Package Manager, Swift Testing (`import Testing`), Foundation, CryptoKit.

**Spec:** `app/docs/specs/2026-09-26-gymrollins-ios-design.md` (sections 4, 5, 9).

**Roadmap (later plans are written just before they run):** 02 app shell + design system + library + local store ·
03 workout flow · 04 log/body/history · 05 Supabase schema/RLS/auth/sync · 06 MCP server + OAuth consent + proposals
UI · 07 onboarding/import/settings/system states · 08 E2E suites + review + polish.

**Conventions for every task**
- Work on branch `plan-01-gymcore` (created in Task 1). Commit after each task with a conventional message and these
  trailer lines:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01LD8UaVzMa2mmiCXaEUujBN
  ```
- Run tests from `app/ios/Packages/GymCore`: `swift test` (all) or `swift test --filter <SuiteName>`.
- Public structs need explicit `public init` (Swift doesn't synthesize public memberwise inits).
- No `print` in library code.

---

## File structure

```
app/
  README.md                                   how to build/test (grows each plan)
  scripts/test-all.sh                         runs every test suite that exists
  scripts/coverage-gymcore.sh                 GymCore line coverage report
  fixtures/plan-changes.json                  shared Swift/TS validator fixture
  ios/Packages/GymCore/
    Package.swift
    Sources/GymCore/
      Units/WeightUnit.swift                  WeightUnit, UnitConverter
      Units/WeightFormatter.swift             "140 lb (63.5 kg)"
      Units/LoadRounder.swift                 round to loadable increments
      Strength/OneRepMax.swift                Epley/Brzycki/Lombardi
      Strength/PlateCalculator.swift          PlateInventory, PlateLoad, PlateCalculator
      Model/Exercise.swift                    Exercise, ExerciseMode
      Model/Routine.swift                     Routine, RoutineExercise, ProgressionPolicy
      Model/Workout.swift                     Workout, WorkoutEntry, WorkoutSet, WorkoutSource
      Session/WarmupGenerator.swift
      Session/WorkoutClock.swift              WorkoutClock, DurationFormatter
      Progression/ProgressionEngine.swift     SessionResult, ProgressionTarget, Suggestion
      Metrics/WorkoutMetrics.swift            volume, best e1RM
      Metrics/RecordDetector.swift            ExerciseBests, PersonalRecord
      Import/CSVParser.swift
      Import/FitbodImporter.swift
      Import/ExerciseMatcher.swift
      Plan/PlanChange.swift                   PlanChangeType, PlanChange, PlanProposal, PlanSnapshot
      Plan/PlanChangeValidator.swift
    Tests/GymCoreTests/                       one test file per source file
```

---

### Task 1: Scaffold the branch, package and scripts

**Files:**
- Create: `app/ios/Packages/GymCore/Package.swift`
- Create: `app/ios/Packages/GymCore/Sources/GymCore/GymCore.swift`
- Create: `app/ios/Packages/GymCore/Tests/GymCoreTests/GymCoreTests.swift`
- Create: `app/scripts/test-all.sh`, `app/scripts/coverage-gymcore.sh`, `app/README.md`

- [ ] **Step 1: Create the branch**

```bash
cd <repo> && git checkout -b plan-01-gymcore
```

- [ ] **Step 2: Write `Package.swift`**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GymCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "GymCore", targets: ["GymCore"])],
    targets: [
        .target(name: "GymCore"),
        .testTarget(name: "GymCoreTests", dependencies: ["GymCore"]),
    ]
)
```

- [ ] **Step 3: Write the smoke test (fails: no symbol yet)**

`Tests/GymCoreTests/GymCoreTests.swift`:
```swift
import Testing
@testable import GymCore

@Suite struct GymCoreSmokeTests {
    @Test func versionIsSet() {
        #expect(GymCore.version == "0.1.0")
    }
}
```

Run: `cd app/ios/Packages/GymCore && swift test`
Expected: FAIL, `cannot find 'GymCore' in scope`.

- [ ] **Step 4: Add the symbol**

`Sources/GymCore/GymCore.swift`:
```swift
/// GymCore: pure domain logic for GymRollins (no I/O, no UI).
public enum GymCore {
    public static let version = "0.1.0"
}
```

Run: `swift test` → Expected: PASS (1 test).

- [ ] **Step 5: Scripts and README**

`app/scripts/test-all.sh`:
```bash
#!/usr/bin/env bash
# Runs every test suite that exists in the repo. Later plans append suites here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> GymCore (swift test)"
(cd "$ROOT/ios/Packages/GymCore" && swift test)
```

`app/scripts/coverage-gymcore.sh`:
```bash
#!/usr/bin/env bash
# Prints GymCore line coverage. Fails if below the threshold (default 90%).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THRESHOLD="${1:-90}"
cd "$ROOT/ios/Packages/GymCore"
swift test --enable-code-coverage >/dev/null
PROF="$(swift test --show-codecov-path)"
BIN="$(find .build/debug -maxdepth 1 -name 'GymCorePackageTests.xctest')/Contents/MacOS/GymCorePackageTests"
REPORT="$(xcrun llvm-cov report "$BIN" -instr-profile "$(dirname "$PROF")/default.profdata" -ignore-filename-regex='Tests|\.build')"
echo "$REPORT"
PCT="$(echo "$REPORT" | awk '/^TOTAL/ {gsub("%","",$10); print $10}')"
echo "Line coverage: ${PCT}% (threshold ${THRESHOLD}%)"
awk -v p="$PCT" -v t="$THRESHOLD" 'BEGIN { exit (p+0 >= t+0) ? 0 : 1 }'
```

`app/README.md`:
```markdown
# GymRollins app

Native SwiftUI iOS app + Supabase backend + remote MCP server so Claude can read training data and propose plans.

- Spec: `docs/specs/2026-09-26-gymrollins-ios-design.md`
- Plans: `docs/plans/`
- Mockups: `docs/design/` (canvas: https://claude.ai/artifact/49XbqyeLuXR35ABhvFpbzK)

## Test

| Suite | Command |
|---|---|
| Everything | `scripts/test-all.sh` |
| GymCore unit tests | `cd ios/Packages/GymCore && swift test` |
| GymCore coverage (≥ 90%) | `scripts/coverage-gymcore.sh` |
```

Run: `chmod +x app/scripts/*.sh && app/scripts/test-all.sh` → Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "chore: scaffold GymCore package, scripts and README"
```

---

### Task 2: Weight units and formatting

**Files:**
- Create: `Sources/GymCore/Units/WeightUnit.swift`, `Sources/GymCore/Units/WeightFormatter.swift`
- Test: `Tests/GymCoreTests/WeightFormatterTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
@testable import GymCore

@Suite struct WeightFormatterTests {
    @Test func convertsBothWays() {
        #expect(abs(UnitConverter.toKg(140, from: .lb) - 63.5029318) < 0.0001)
        #expect(abs(UnitConverter.fromKg(63.5029318, to: .lb) - 140) < 0.0001)
        #expect(UnitConverter.toKg(20, from: .kg) == 20)
    }

    @Test func formatsPrimaryAndSecondary() {
        #expect(WeightFormatter.format(kg: 63.5029318, unit: .lb) == "140 lb (63.5 kg)")
        #expect(WeightFormatter.format(kg: 20, unit: .kg) == "20 kg (44.1 lb)")
        #expect(WeightFormatter.format(kg: 12.4737954, unit: .lb) == "27.5 lb (12.5 kg)")
    }

    @Test func formatsPrimaryOnly() {
        #expect(WeightFormatter.format(kg: 63.5029318, unit: .lb, includeSecondary: false) == "140 lb")
    }

    @Test func numberTrimsTrailingZero() {
        #expect(WeightFormatter.number(81.0) == "81")
        #expect(WeightFormatter.number(81.04) == "81")
        #expect(WeightFormatter.number(81.06) == "81.1")
    }
}
```

Run: `swift test --filter WeightFormatterTests` → Expected: FAIL (types missing).

- [ ] **Step 2: Implement**

`Units/WeightUnit.swift`:
```swift
public enum WeightUnit: String, Codable, Sendable, CaseIterable {
    case kg
    case lb
}

public enum UnitConverter {
    public static let kgPerLb = 0.45359237

    public static func toKg(_ value: Double, from unit: WeightUnit) -> Double {
        unit == .kg ? value : value * kgPerLb
    }

    public static func fromKg(_ kg: Double, to unit: WeightUnit) -> Double {
        unit == .kg ? kg : kg / kgPerLb
    }
}
```

`Units/WeightFormatter.swift`:
```swift
import Foundation

public enum WeightFormatter {
    /// "140 lb (63.5 kg)" when `unit` is lb; "20 kg (44.1 lb)" when kg.
    public static func format(kg: Double, unit: WeightUnit, includeSecondary: Bool = true) -> String {
        let other: WeightUnit = unit == .kg ? .lb : .kg
        let primary = "\(number(UnitConverter.fromKg(kg, to: unit))) \(unit.rawValue)"
        guard includeSecondary else { return primary }
        return "\(primary) (\(number(UnitConverter.fromKg(kg, to: other))) \(other.rawValue))"
    }

    /// At most one decimal, trailing ".0" removed.
    public static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }
}
```

Run: `swift test --filter WeightFormatterTests` → Expected: PASS.

- [ ] **Step 3: Commit** — `git add -A && git commit -m "feat(core): weight units and formatter"`

---

### Task 3: One-rep max

**Files:** Create `Sources/GymCore/Strength/OneRepMax.swift`; Test `Tests/GymCoreTests/OneRepMaxTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
@testable import GymCore

@Suite struct OneRepMaxTests {
    @Test func epleyMatchesOwnersBench() throws {
        // 19 Sep: 10 reps @ 130 lb (58.967 kg) -> 78.6 kg
        let e1rm = try #require(OneRepMax.estimate(weightKg: 58.967, reps: 10))
        #expect(abs(e1rm - 78.62) < 0.01)
        let prior = try #require(OneRepMax.estimate(weightKg: 58.967, reps: 6))
        #expect(abs(prior - 70.76) < 0.01)
    }

    @Test func otherFormulas() throws {
        #expect(abs(try #require(OneRepMax.estimate(weightKg: 100, reps: 5, formula: .brzycki)) - 112.5) < 0.01)
        #expect(abs(try #require(OneRepMax.estimate(weightKg: 100, reps: 10, formula: .lombardi)) - 125.89) < 0.01)
    }

    @Test func singleRepIsTheWeight() {
        #expect(OneRepMax.estimate(weightKg: 100, reps: 1) == 100)
    }

    @Test(arguments: [0, 13, 50])
    func rejectsRepsOutsideRange(reps: Int) {
        #expect(OneRepMax.estimate(weightKg: 100, reps: reps) == nil)
    }

    @Test func rejectsNonPositiveWeight() {
        #expect(OneRepMax.estimate(weightKg: 0, reps: 5) == nil)
    }
}
```

Run: `swift test --filter OneRepMaxTests` → FAIL.

- [ ] **Step 2: Implement**

```swift
import Foundation

public enum OneRepMaxFormula: String, Codable, Sendable, CaseIterable {
    case epley, brzycki, lombardi
}

public enum OneRepMax {
    /// Estimates above this rep count are unreliable and are not reported.
    public static let maxReps = 12

    public static func estimate(weightKg: Double, reps: Int, formula: OneRepMaxFormula = .epley) -> Double? {
        guard weightKg > 0, (1...maxReps).contains(reps) else { return nil }
        if reps == 1 { return weightKg }
        let r = Double(reps)
        switch formula {
        case .epley: return weightKg * (1 + r / 30)
        case .brzycki: return weightKg * 36 / (37 - r)
        case .lombardi: return weightKg * pow(r, 0.10)
        }
    }
}
```

Run → PASS. **Commit:** `feat(core): one-rep max estimates`

---

### Task 4: Load rounding and plate calculator

**Files:** Create `Units/LoadRounder.swift`, `Strength/PlateCalculator.swift`; Tests `LoadRounderTests.swift`, `PlateCalculatorTests.swift`

- [ ] **Step 1: Failing tests**

`LoadRounderTests.swift`:
```swift
import Testing
@testable import GymCore

@Suite struct LoadRounderTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private func inLb(_ kg: Double) -> Double { (UnitConverter.fromKg(kg, to: .lb) * 1000).rounded() / 1000 }

    @Test func nearestBarbellStep() {
        #expect(inLb(LoadRounder.barbellLb.nearest(lb(133))) == 135)
        #expect(inLb(LoadRounder.barbellLb.nearest(lb(132))) == 130)
    }

    @Test func downIsStableForExactValues() {
        // 140 lb round-trips through kg without dropping to 135
        #expect(inLb(LoadRounder.barbellLb.down(lb(140))) == 140)
        #expect(inLb(LoadRounder.barbellLb.down(lb(66.5))) == 65)
    }

    @Test func dumbbellStep() {
        #expect(inLb(LoadRounder.dumbbellLb.nearest(lb(26.4))) == 27.5)
    }

    @Test func kilogramStep() {
        #expect(LoadRounder.barbellKg.down(61.2) == 60)
    }
}
```

`PlateCalculatorTests.swift`:
```swift
import Testing
@testable import GymCore

@Suite struct PlateCalculatorTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }

    @Test func ownersBenchLoad() {
        let load = PlateCalculator.load(targetKg: lb(140), inventory: .standardLb)
        #expect(load.perSide == [45, 2.5])
        #expect(load.total == 140)
        #expect(load.remainder == 0)
    }

    @Test func exactPlates() {
        #expect(PlateCalculator.load(targetKg: lb(135), inventory: .standardLb).perSide == [45])
        #expect(PlateCalculator.load(targetKg: lb(225), inventory: .standardLb).perSide == [45, 45])
    }

    @Test func barOnly() {
        let load = PlateCalculator.load(targetKg: lb(45), inventory: .standardLb)
        #expect(load.perSide.isEmpty)
        #expect(load.total == 45)
    }

    @Test func belowBarGivesBar() {
        let load = PlateCalculator.load(targetKg: lb(30), inventory: .standardLb)
        #expect(load.perSide.isEmpty)
        #expect(load.total == 45)
        #expect(load.remainder == 0)
    }

    @Test func unreachableRemainder() {
        let load = PlateCalculator.load(targetKg: lb(142), inventory: .standardLb)
        #expect(load.perSide == [45, 2.5])
        #expect(load.remainder == 2)
    }

    @Test func kilogramInventory() {
        #expect(PlateCalculator.load(targetKg: 100, inventory: .standardKg).perSide == [25, 15])
    }
}
```

Run: `swift test --filter "LoadRounderTests|PlateCalculatorTests"` → FAIL.

- [ ] **Step 2: Implement**

`Units/LoadRounder.swift`:
```swift
/// Rounds a load (kg) to what can actually be loaded, in the user's unit.
public struct LoadRounder: Sendable, Equatable, Codable {
    public let unit: WeightUnit
    /// Smallest change of the total load, in `unit` (barbell with 2.5 lb plates = 5 lb).
    public let step: Double

    public init(unit: WeightUnit, step: Double) {
        self.unit = unit
        self.step = step
    }

    public static let barbellLb = LoadRounder(unit: .lb, step: 5)
    public static let dumbbellLb = LoadRounder(unit: .lb, step: 2.5)
    public static let barbellKg = LoadRounder(unit: .kg, step: 2.5)

    public func nearest(_ kg: Double) -> Double { round(kg, .toNearestOrAwayFromZero) }
    public func down(_ kg: Double) -> Double { round(kg, .down) }

    private func round(_ kg: Double, _ rule: FloatingPointRoundingRule) -> Double {
        guard step > 0 else { return kg }
        let value = UnitConverter.fromKg(kg, to: unit)
        // Guard against 139.99999 -> 135 when rounding down values that are already loadable.
        let quotient = value / step + (rule == .down ? 1e-6 : 0)
        return UnitConverter.toKg(quotient.rounded(rule) * step, from: unit)
    }
}
```

`Strength/PlateCalculator.swift`:
```swift
public struct PlateInventory: Codable, Sendable, Equatable {
    public let unit: WeightUnit
    /// Bar weight in `unit`.
    public let bar: Double
    /// Plate sizes available per side, in `unit` (unlimited count of each).
    public let plates: [Double]

    public init(unit: WeightUnit, bar: Double, plates: [Double]) {
        self.unit = unit
        self.bar = bar
        self.plates = plates
    }

    public static let standardLb = PlateInventory(unit: .lb, bar: 45, plates: [45, 35, 25, 10, 5, 2.5])
    public static let standardKg = PlateInventory(unit: .kg, bar: 20, plates: [25, 20, 15, 10, 5, 2.5, 1.25])
}

public struct PlateLoad: Sendable, Equatable {
    /// Plates for ONE side, heaviest first, in the inventory unit.
    public let perSide: [Double]
    /// Achieved total (bar + both sides), in the inventory unit.
    public let total: Double
    /// Target minus achieved total (never negative), in the inventory unit.
    public let remainder: Double
}

public enum PlateCalculator {
    public static func load(targetKg: Double, inventory: PlateInventory) -> PlateLoad {
        // Work in hundredths of the unit to avoid floating-point drift.
        func cents(_ v: Double) -> Int { Int((v * 100).rounded()) }
        let target = cents(UnitConverter.fromKg(targetKg, to: inventory.unit))
        let bar = cents(inventory.bar)
        guard target > bar else {
            return PlateLoad(perSide: [], total: inventory.bar, remainder: 0)
        }
        let (perSide, used) = inventory.plates
            .filter { $0 > 0 }
            .sorted(by: >)
            .reduce(into: ([Double](), 0)) { acc, plate in
                let size = cents(plate)
                let perSideLeft = (target - bar) / 2 - acc.1
                let count = perSideLeft / size
                acc.0 += Array(repeating: plate, count: count)
                acc.1 += count * size
            }
        let total = bar + 2 * used
        return PlateLoad(perSide: perSide, total: Double(total) / 100, remainder: Double(target - total) / 100)
    }
}
```

Run → PASS. **Commit:** `feat(core): load rounding and plate calculator`

---

### Task 5: Domain models

**Files:** Create `Model/Exercise.swift`, `Model/Routine.swift`, `Model/Workout.swift`; Test `ModelCodingTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Foundation
import Testing
@testable import GymCore

@Suite struct ModelCodingTests {
    @Test func decodesOpengymExerciseShape() throws {
        let json = """
        {"id":"0025","n":"barbell bench press","bp":"chest","eq":"barbell","tg":"pectorals",
         "sm":["triceps","shoulders"],"st":["Lie on the bench."],"img":"0025.jpg","gif":"0025.gif"}
        """
        let ex = try JSONDecoder().decode(Exercise.self, from: Data(json.utf8))
        #expect(ex.name == "barbell bench press")
        #expect(ex.bodyPart == "chest")
        #expect(ex.secondary == ["triceps", "shoulders"])
        #expect(ex.aliases.isEmpty)
        #expect(ex.isCustom == false)
        #expect(ex.mode == .reps)
    }

    @Test func infersCardioModeFromBodyPart() throws {
        let json = #"{"id":"c1","n":"walking","bp":"cardio","eq":"body weight","tg":"cardiovascular system"}"#
        let ex = try JSONDecoder().decode(Exercise.self, from: Data(json.utf8))
        #expect(ex.mode == .cardio)
    }

    @Test func workoutRoundTrips() throws {
        let set = WorkoutSet(weightKg: 58.967, reps: 10, done: true)
        let entry = WorkoutEntry(exerciseId: "0025", sets: [set])
        let workout = Workout(startedAt: Date(timeIntervalSince1970: 1_790_000_000), name: "Push + Biceps", entries: [entry])
        let data = try JSONEncoder().encode(workout)
        #expect(try JSONDecoder().decode(Workout.self, from: data) == workout)
        #expect(workout.source == .app)
        #expect(set.multiplier == 1)
        #expect(set.warmup == false)
    }

    @Test func settingDoneReturnsNewValue() {
        let set = WorkoutSet(weightKg: 20, reps: 10)
        let done = set.completing(at: Date(timeIntervalSince1970: 10))
        #expect(set.done == false)
        #expect(done.done == true)
        #expect(done.completedAt == Date(timeIntervalSince1970: 10))
        #expect(done.id == set.id)
    }
}
```

Run → FAIL.

- [ ] **Step 2: Implement**

`Model/Exercise.swift`:
```swift
public enum ExerciseMode: String, Codable, Sendable, CaseIterable {
    case reps, time, cardio
}

/// Library or custom exercise. JSON keys follow opengym's compact shape (n, bp, eq, tg, sm, st).
public struct Exercise: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let bodyPart: String
    public let equipment: String
    public let target: String
    public let secondary: [String]
    public let instructions: [String]
    public let image: String?
    public let gif: String?
    public let aliases: [String]
    public let isCustom: Bool
    public let mode: ExerciseMode

    public init(id: String, name: String, bodyPart: String, equipment: String, target: String,
                secondary: [String] = [], instructions: [String] = [], image: String? = nil, gif: String? = nil,
                aliases: [String] = [], isCustom: Bool = false, mode: ExerciseMode? = nil) {
        self.id = id
        self.name = name
        self.bodyPart = bodyPart
        self.equipment = equipment
        self.target = target
        self.secondary = secondary
        self.instructions = instructions
        self.image = image
        self.gif = gif
        self.aliases = aliases
        self.isCustom = isCustom
        self.mode = mode ?? (bodyPart == "cardio" ? .cardio : .reps)
    }

    enum CodingKeys: String, CodingKey {
        case id, n, bp, eq, tg, sm, st, img, gif, aliases, custom, mode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .n),
            bodyPart: try c.decode(String.self, forKey: .bp),
            equipment: try c.decode(String.self, forKey: .eq),
            target: try c.decode(String.self, forKey: .tg),
            secondary: try c.decodeIfPresent([String].self, forKey: .sm) ?? [],
            instructions: try c.decodeIfPresent([String].self, forKey: .st) ?? [],
            image: try c.decodeIfPresent(String.self, forKey: .img),
            gif: try c.decodeIfPresent(String.self, forKey: .gif),
            aliases: try c.decodeIfPresent([String].self, forKey: .aliases) ?? [],
            isCustom: try c.decodeIfPresent(Bool.self, forKey: .custom) ?? false,
            mode: try c.decodeIfPresent(ExerciseMode.self, forKey: .mode)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .n)
        try c.encode(bodyPart, forKey: .bp)
        try c.encode(equipment, forKey: .eq)
        try c.encode(target, forKey: .tg)
        try c.encode(secondary, forKey: .sm)
        try c.encode(instructions, forKey: .st)
        try c.encodeIfPresent(image, forKey: .img)
        try c.encodeIfPresent(gif, forKey: .gif)
        try c.encode(aliases, forKey: .aliases)
        try c.encode(isCustom, forKey: .custom)
        try c.encode(mode, forKey: .mode)
    }
}
```

`Model/Routine.swift`:
```swift
import Foundation

public enum ProgressionPolicy: String, Codable, Sendable, CaseIterable {
    case off, linear, greyskull, double, time
}

public struct RoutineExercise: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let exerciseId: String
    public let sets: Int
    public let reps: Int
    public let repsMin: Int?
    public let sec: Int?
    public let weightKg: Double?
    public let mode: ExerciseMode
    public let policy: ProgressionPolicy?
    public let incKg: Double?
    public let supersetGroup: String?

    public init(id: UUID = UUID(), exerciseId: String, sets: Int, reps: Int, repsMin: Int? = nil, sec: Int? = nil,
                weightKg: Double? = nil, mode: ExerciseMode = .reps, policy: ProgressionPolicy? = nil,
                incKg: Double? = nil, supersetGroup: String? = nil) {
        self.id = id
        self.exerciseId = exerciseId
        self.sets = sets
        self.reps = reps
        self.repsMin = repsMin
        self.sec = sec
        self.weightKg = weightKg
        self.mode = mode
        self.policy = policy
        self.incKg = incKg
        self.supersetGroup = supersetGroup
    }
}

public struct Routine: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let emoji: String?
    public let policy: ProgressionPolicy
    public let paused: Bool
    public let exercises: [RoutineExercise]

    public init(id: UUID = UUID(), name: String, emoji: String? = nil, policy: ProgressionPolicy = .double,
                paused: Bool = false, exercises: [RoutineExercise] = []) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.policy = policy
        self.paused = paused
        self.exercises = exercises
    }
}
```

`Model/Workout.swift`:
```swift
import Foundation

public enum WorkoutSource: String, Codable, Sendable {
    case app, `import`
}

public struct WorkoutSet: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let weightKg: Double
    public let reps: Int
    public let sec: Int?
    public let minutes: Double?
    public let distanceM: Double?
    public let done: Bool
    public let warmup: Bool
    public let rir: Double?
    public let rpe: Double?
    /// Volume multiplier (2 for a pair of dumbbells logged per hand).
    public let multiplier: Double
    public let completedAt: Date?

    public init(id: UUID = UUID(), weightKg: Double, reps: Int, sec: Int? = nil, minutes: Double? = nil,
                distanceM: Double? = nil, done: Bool = false, warmup: Bool = false, rir: Double? = nil,
                rpe: Double? = nil, multiplier: Double = 1, completedAt: Date? = nil) {
        self.id = id
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

    /// Returns a copy marked done at `date`.
    public func completing(at date: Date) -> WorkoutSet {
        WorkoutSet(id: id, weightKg: weightKg, reps: reps, sec: sec, minutes: minutes, distanceM: distanceM,
                   done: true, warmup: warmup, rir: rir, rpe: rpe, multiplier: multiplier, completedAt: date)
    }
}

public struct WorkoutEntry: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let exerciseId: String
    public let sets: [WorkoutSet]
    public let note: String?
    public let supersetGroup: String?

    public init(id: UUID = UUID(), exerciseId: String, sets: [WorkoutSet] = [], note: String? = nil,
                supersetGroup: String? = nil) {
        self.id = id
        self.exerciseId = exerciseId
        self.sets = sets
        self.note = note
        self.supersetGroup = supersetGroup
    }
}

public struct Workout: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let pausedSeconds: TimeInterval
    public let routineId: UUID?
    public let name: String
    public let entries: [WorkoutEntry]
    public let source: WorkoutSource
    public let note: String?

    public init(id: UUID = UUID(), startedAt: Date, endedAt: Date? = nil, pausedSeconds: TimeInterval = 0,
                routineId: UUID? = nil, name: String, entries: [WorkoutEntry] = [], source: WorkoutSource = .app,
                note: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pausedSeconds = pausedSeconds
        self.routineId = routineId
        self.name = name
        self.entries = entries
        self.source = source
        self.note = note
    }
}
```

Run → PASS. **Commit:** `feat(core): exercise, routine and workout models`

---

### Task 6: Warm-up generator

**Files:** Create `Session/WarmupGenerator.swift`; Test `WarmupGeneratorTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
@testable import GymCore

@Suite struct WarmupGeneratorTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private func inLb(_ kg: Double) -> Double { (UnitConverter.fromKg(kg, to: .lb) * 100).rounded() / 100 }

    @Test func heavyWorkingSetGetsTwoWarmups() {
        // Mockup: 140 lb working -> bar x10, 105 x5
        let sets = WarmupGenerator.sets(workingKg: lb(140), barKg: lb(45), rounder: .barbellLb)
        #expect(sets.map { inLb($0.weightKg) } == [45, 105])
        #expect(sets.map(\.reps) == [10, 5])
        #expect(sets.allSatisfy { $0.warmup && !$0.done })
    }

    @Test func lightWorkingSetGetsBarOnly() {
        let sets = WarmupGenerator.sets(workingKg: lb(60), barKg: lb(45), rounder: .barbellLb)
        #expect(sets.map { inLb($0.weightKg) } == [45])
    }

    @Test func workingAtOrBelowBarGetsNone() {
        #expect(WarmupGenerator.sets(workingKg: lb(45), barKg: lb(45), rounder: .barbellLb).isEmpty)
    }
}
```

Run → FAIL.

- [ ] **Step 2: Implement**

```swift
public enum WarmupGenerator {
    /// Bar x10, then ~75% x5 when the working weight is well above the bar.
    public static func sets(workingKg: Double, barKg: Double, rounder: LoadRounder) -> [WorkoutSet] {
        guard workingKg > barKg + 0.01 else { return [] }
        let bar = WorkoutSet(weightKg: barKg, reps: 10, warmup: true)
        guard workingKg > barKg * 1.5 else { return [bar] }
        let ramp = WorkoutSet(weightKg: rounder.nearest(workingKg * 0.75), reps: 5, warmup: true)
        return [bar, ramp]
    }
}
```

Run → PASS. **Commit:** `feat(core): warm-up set generator`

---

### Task 7: Progression engine

**Files:** Create `Progression/ProgressionEngine.swift`; Test `ProgressionEngineTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Foundation
import Testing
@testable import GymCore

@Suite struct ProgressionEngineTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private func inLb(_ kg: Double) -> Double { (UnitConverter.fromKg(kg, to: .lb) * 100).rounded() / 100 }
    private let engine = ProgressionEngine(rounder: .barbellLb, deloadPct: 0.05)
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }
    private func session(_ n: Int, _ w: Double, _ reps: [Int]) -> SessionResult {
        SessionResult(date: day(n), weightKg: lb(w), reps: reps)
    }
    private var bench: ProgressionTarget {
        ProgressionTarget(sets: 3, reps: 10, repsMin: 8, weightKg: lb(130), incKg: lb(5))
    }

    @Test func firstSessionUsesTarget() {
        let s = engine.suggest(policy: .double, target: bench, history: [])
        #expect(inLb(s.weightKg) == 130)
        #expect(s.reps == 8)
        #expect(s.reason == .firstSession)
    }

    @Test func doubleProgressionTopOfRangeAddsIncrement() {
        let s = engine.suggest(policy: .double, target: bench, history: [session(2, 130, [10, 10, 10])])
        #expect(inLb(s.weightKg) == 135)
        #expect(s.reps == 8)
        #expect(s.reason == .topOfRange)
    }

    @Test func doubleProgressionNotYetKeepsWeight() {
        let s = engine.suggest(policy: .double, target: bench, history: [session(2, 130, [10, 9, 8])])
        #expect(inLb(s.weightKg) == 130)
        #expect(s.reps == 10)
        #expect(s.reason == .keepGoing)
    }

    @Test func twoMissesAtSameWeightDeloadFivePercent() {
        // Owner's shoulder press: stuck at 70 lb -> 65 lb
        let press = ProgressionTarget(sets: 3, reps: 12, repsMin: 10, weightKg: lb(70), incKg: lb(5))
        let s = engine.suggest(policy: .double, target: press,
                               history: [session(5, 70, [8, 10, 8]), session(2, 70, [10, 10, 9])])
        #expect(inLb(s.weightKg) == 65)
        #expect(s.reps == 10)
        #expect(s.reason == .deload)
    }

    @Test func missesAtDifferentWeightsDoNotDeload() {
        let press = ProgressionTarget(sets: 3, reps: 12, repsMin: 10, weightKg: lb(70), incKg: lb(5))
        let s = engine.suggest(policy: .double, target: press,
                               history: [session(5, 70, [8, 10, 8]), session(2, 65, [9, 10, 9])])
        #expect(s.reason == .keepGoing)
    }

    @Test func linearSuccessAddsIncrementKeepsReps() {
        let t = ProgressionTarget(sets: 3, reps: 5, weightKg: lb(135), incKg: lb(5))
        let s = engine.suggest(policy: .linear, target: t, history: [session(2, 135, [5, 5, 5])])
        #expect(inLb(s.weightKg) == 140)
        #expect(s.reps == 5)
        #expect(s.reason == .success)
    }

    @Test func greyskullDoubleJumpOnBigAmrap() {
        let t = ProgressionTarget(sets: 3, reps: 5, weightKg: lb(135), incKg: lb(5))
        let s = engine.suggest(policy: .greyskull, target: t, history: [session(2, 135, [5, 5, 10])])
        #expect(inLb(s.weightKg) == 145)
        #expect(s.reason == .doubleJump)
    }

    @Test func timePolicyAddsFiveSeconds() {
        let t = ProgressionTarget(sets: 3, reps: 1, sec: 30, weightKg: 0, incKg: 0)
        let hit = engine.suggest(policy: .time, target: t,
                                 history: [SessionResult(date: day(1), weightKg: 0, reps: [], secs: [30, 31, 30])])
        #expect(hit.sec == 35)
        #expect(hit.reason == .addTime)
        let miss = engine.suggest(policy: .time, target: t,
                                  history: [SessionResult(date: day(1), weightKg: 0, reps: [], secs: [30, 20])])
        #expect(miss.sec == 30)
        #expect(miss.reason == .keepGoing)
    }

    @Test func offRepeatsLastWeight() {
        let s = engine.suggest(policy: .off, target: bench, history: [session(2, 125, [10, 10, 10])])
        #expect(inLb(s.weightKg) == 125)
        #expect(s.reason == .noChange)
    }

    @Test func plannedWeightAboveLastWins() {
        // Claude raised the plan to 140 lb; last session was 130 lb
        let t = ProgressionTarget(sets: 3, reps: 8, repsMin: 8, weightKg: lb(140), incKg: lb(5))
        let s = engine.suggest(policy: .double, target: t, history: [session(2, 130, [10, 10, 10])])
        #expect(inLb(s.weightKg) == 140)
        #expect(s.reason == .planned)
    }
}
```

Run → FAIL.

- [ ] **Step 2: Implement**

```swift
import Foundation

/// One past session of an exercise: working sets only.
public struct SessionResult: Sendable, Equatable {
    public let date: Date
    public let weightKg: Double
    public let reps: [Int]
    public let secs: [Int]

    public init(date: Date, weightKg: Double, reps: [Int], secs: [Int] = []) {
        self.date = date
        self.weightKg = weightKg
        self.reps = reps
        self.secs = secs
    }
}

public struct ProgressionTarget: Sendable, Equatable {
    public let sets: Int
    /// Top of the rep range.
    public let reps: Int
    /// Bottom of the rep range (double progression); nil means `reps`.
    public let repsMin: Int?
    public let sec: Int?
    public let weightKg: Double
    public let incKg: Double

    public init(sets: Int, reps: Int, repsMin: Int? = nil, sec: Int? = nil, weightKg: Double, incKg: Double) {
        self.sets = sets
        self.reps = reps
        self.repsMin = repsMin
        self.sec = sec
        self.weightKg = weightKg
        self.incKg = incKg
    }

    var low: Int { repsMin ?? reps }
}

public enum SuggestionReason: String, Sendable, Codable {
    case firstSession, planned, noChange, keepGoing, topOfRange, success, doubleJump, deload, addTime
}

public struct Suggestion: Sendable, Equatable {
    public let weightKg: Double
    public let reps: Int
    public let sec: Int?
    public let reason: SuggestionReason
}

public struct ProgressionEngine: Sendable {
    public let rounder: LoadRounder
    public let deloadPct: Double
    public let missesBeforeDeload: Int

    public init(rounder: LoadRounder, deloadPct: Double = 0.05, missesBeforeDeload: Int = 2) {
        self.rounder = rounder
        self.deloadPct = deloadPct
        self.missesBeforeDeload = missesBeforeDeload
    }

    /// - Parameter history: past sessions of this exercise, newest first.
    public func suggest(policy: ProgressionPolicy, target: ProgressionTarget, history: [SessionResult]) -> Suggestion {
        guard let last = history.first else {
            return Suggestion(weightKg: target.weightKg, reps: target.low, sec: target.sec, reason: .firstSession)
        }
        if policy != .off, target.weightKg > last.weightKg + 0.01 {
            return Suggestion(weightKg: target.weightKg, reps: target.low, sec: target.sec, reason: .planned)
        }
        switch policy {
        case .off:
            return Suggestion(weightKg: last.weightKg, reps: target.reps, sec: target.sec, reason: .noChange)
        case .time:
            return suggestTime(target: target, last: last)
        case .linear, .double, .greyskull:
            return suggestLoad(policy: policy, target: target, history: history, last: last)
        }
    }

    private func suggestTime(target: ProgressionTarget, last: SessionResult) -> Suggestion {
        let goal = target.sec ?? 30
        let hit = last.secs.count >= target.sets && last.secs.allSatisfy { $0 >= goal }
        return hit
            ? Suggestion(weightKg: last.weightKg, reps: target.reps, sec: goal + 5, reason: .addTime)
            : Suggestion(weightKg: last.weightKg, reps: target.reps, sec: goal, reason: .keepGoing)
    }

    private func suggestLoad(policy: ProgressionPolicy, target: ProgressionTarget, history: [SessionResult],
                             last: SessionResult) -> Suggestion {
        if deloadDue(target: target, history: history) {
            let weight = rounder.down(last.weightKg * (1 - deloadPct))
            return Suggestion(weightKg: weight, reps: target.low, sec: nil, reason: .deload)
        }
        let hitTop = last.reps.count >= target.sets && last.reps.allSatisfy { $0 >= target.reps }
        if policy == .greyskull, hitTop, let amrap = last.reps.last, amrap >= target.reps * 2 {
            let weight = rounder.nearest(last.weightKg + 2 * target.incKg)
            return Suggestion(weightKg: weight, reps: target.reps, sec: nil, reason: .doubleJump)
        }
        if hitTop {
            let weight = rounder.nearest(last.weightKg + target.incKg)
            return policy == .double
                ? Suggestion(weightKg: weight, reps: target.low, sec: nil, reason: .topOfRange)
                : Suggestion(weightKg: weight, reps: target.reps, sec: nil, reason: .success)
        }
        return Suggestion(weightKg: last.weightKg, reps: target.reps, sec: nil, reason: .keepGoing)
    }

    private func deloadDue(target: ProgressionTarget, history: [SessionResult]) -> Bool {
        let recent = history.prefix(missesBeforeDeload)
        guard recent.count == missesBeforeDeload, let weight = recent.first?.weightKg else { return false }
        return recent.allSatisfy { session in
            abs(session.weightKg - weight) < 0.01
                && (session.reps.count < target.sets || session.reps.contains { $0 < target.low })
        }
    }
}
```

Run → PASS. **Commit:** `feat(core): progression engine (off/linear/double/greyskull/time, deload)`

---

### Task 8: Workout clock and duration formatting

**Files:** Create `Session/WorkoutClock.swift`; Test `WorkoutClockTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Foundation
import Testing
@testable import GymCore

@Suite struct WorkoutClockTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func elapsedExcludesPauses() {
        let clock = WorkoutClock(startedAt: t0)
            .pausing(at: t0.addingTimeInterval(600))
            .resuming(at: t0.addingTimeInterval(900))
        #expect(clock.elapsed(at: t0.addingTimeInterval(1_200)) == 900)
        #expect(clock.pausedSeconds == 300)
    }

    @Test func pausedClockStops() {
        let clock = WorkoutClock(startedAt: t0).pausing(at: t0.addingTimeInterval(60))
        #expect(clock.isPaused)
        #expect(clock.elapsed(at: t0.addingTimeInterval(500)) == 60)
    }

    @Test func pauseAndResumeAreIdempotent() {
        let paused = WorkoutClock(startedAt: t0).pausing(at: t0.addingTimeInterval(10))
        #expect(paused.pausing(at: t0.addingTimeInterval(20)) == paused)
        let running = WorkoutClock(startedAt: t0)
        #expect(running.resuming(at: t0.addingTimeInterval(20)) == running)
    }

    @Test func neverNegative() {
        #expect(WorkoutClock(startedAt: t0).elapsed(at: t0.addingTimeInterval(-5)) == 0)
    }

    @Test func formatsClock() {
        #expect(DurationFormatter.clock(1_452) == "24:12")
        #expect(DurationFormatter.clock(3_957) == "1:05:57")
        #expect(DurationFormatter.clock(5) == "0:05")
    }

    @Test func formatsMinutes() {
        #expect(DurationFormatter.minutes(3_957) == "65m")
        #expect(DurationFormatter.minutes(29) == "0m")
    }
}
```

Run → FAIL.

- [ ] **Step 2: Implement**

```swift
import Foundation

/// Elapsed workout time with pauses. Immutable: pausing/resuming return new clocks.
public struct WorkoutClock: Codable, Sendable, Equatable {
    public let startedAt: Date
    public let pausedAt: Date?
    public let pausedSeconds: TimeInterval

    public init(startedAt: Date, pausedAt: Date? = nil, pausedSeconds: TimeInterval = 0) {
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.pausedSeconds = pausedSeconds
    }

    public var isPaused: Bool { pausedAt != nil }

    public func elapsed(at now: Date) -> TimeInterval {
        let end = pausedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - pausedSeconds)
    }

    public func pausing(at now: Date) -> WorkoutClock {
        guard !isPaused else { return self }
        return WorkoutClock(startedAt: startedAt, pausedAt: now, pausedSeconds: pausedSeconds)
    }

    public func resuming(at now: Date) -> WorkoutClock {
        guard let pausedAt else { return self }
        return WorkoutClock(startedAt: startedAt, pausedAt: nil,
                            pausedSeconds: pausedSeconds + max(0, now.timeIntervalSince(pausedAt)))
    }
}

public enum DurationFormatter {
    /// "24:12", "1:05:57", "0:05".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3_600, (total % 3_600) / 60, total % 60)
        return h > 0
            ? String(format: "%ld:%02ld:%02ld", h, m, s)
            : String(format: "%ld:%02ld", m, s)
    }

    /// Whole minutes: "65m".
    public static func minutes(_ seconds: TimeInterval) -> String {
        "\(max(0, Int(seconds)) / 60)m"
    }
}
```

Run → PASS. **Commit:** `feat(core): workout clock and duration formatting`

---

### Task 9: Workout metrics and personal records

**Files:** Create `Metrics/WorkoutMetrics.swift`, `Metrics/RecordDetector.swift`; Tests `WorkoutMetricsTests.swift`, `RecordDetectorTests.swift`

- [ ] **Step 1: Failing tests**

`WorkoutMetricsTests.swift`:
```swift
import Foundation
import Testing
@testable import GymCore

@Suite struct WorkoutMetricsTests {
    private let entry = WorkoutEntry(exerciseId: "bench", sets: [
        WorkoutSet(weightKg: 20, reps: 10, done: true, warmup: true),
        WorkoutSet(weightKg: 60, reps: 10, done: true),
        WorkoutSet(weightKg: 60, reps: 8, done: true),
        WorkoutSet(weightKg: 60, reps: 8, done: false),
    ])
    private let dumbbells = WorkoutEntry(exerciseId: "hammer", sets: [
        WorkoutSet(weightKg: 10, reps: 10, done: true, multiplier: 2),
    ])

    @Test func workingSetsExcludeWarmupsAndUndone() {
        #expect(WorkoutMetrics.workingSets(entry).count == 2)
    }

    @Test func volumeUsesMultiplier() {
        let w = Workout(startedAt: .now, name: "Push", entries: [entry, dumbbells])
        #expect(WorkoutMetrics.volumeKg(w) == 60 * 10 + 60 * 8 + 10 * 10 * 2)
    }

    @Test func bestE1RMPicksHighest() throws {
        let best = try #require(WorkoutMetrics.bestE1RM(entry))
        #expect(abs(best - 80) < 0.001) // 60 x 10 epley = 80
    }

    @Test func completedSetCount() {
        let w = Workout(startedAt: .now, name: "Push", entries: [entry, dumbbells])
        #expect(WorkoutMetrics.workingSetCount(w) == 3)
    }
}
```

`RecordDetectorTests.swift`:
```swift
import Foundation
import Testing
@testable import GymCore

@Suite struct RecordDetectorTests {
    private let benchSession = Workout(startedAt: .now, name: "Push + Biceps", entries: [
        WorkoutEntry(exerciseId: "bench", sets: [
            WorkoutSet(weightKg: 58.967, reps: 10, done: true),
            WorkoutSet(weightKg: 58.967, reps: 10, done: true),
            WorkoutSet(weightKg: 58.967, reps: 10, done: true),
        ]),
    ])

    @Test func ownersBenchSessionBeatsPriorWeek() throws {
        // 12 Sep: 3 x 6 @ 58.967 kg (e1RM 70.76, volume 1061)
        let previous = ["bench": ExerciseBests(e1RMKg: 70.76, repsAtWeight: [58_967: 6], volumeKg: 1_061.4)]
        let records = RecordDetector.records(for: benchSession, previous: previous)
        #expect(Set(records.map(\.kind)) == [.e1RM, .repsAtWeight, .volume])
        let reps = try #require(records.first { $0.kind == .repsAtWeight })
        #expect(reps.reps == 10)
    }

    @Test func noRecordsWithoutHistory() {
        #expect(RecordDetector.records(for: benchSession, previous: [:]).isEmpty)
    }

    @Test func noRecordWhenNotBeaten() {
        let previous = ["bench": ExerciseBests(e1RMKg: 90, repsAtWeight: [58_967: 12], volumeKg: 5_000)]
        #expect(RecordDetector.records(for: benchSession, previous: previous).isEmpty)
    }

    @Test func bestsMergeKeepsMaxima() {
        let a = ExerciseBests(e1RMKg: 70, repsAtWeight: [60_000: 6], volumeKg: 1_000)
        let b = ExerciseBests(e1RMKg: 75, repsAtWeight: [60_000: 5, 62_500: 4], volumeKg: 900)
        let merged = a.merging(b)
        #expect(merged == ExerciseBests(e1RMKg: 75, repsAtWeight: [60_000: 6, 62_500: 4], volumeKg: 1_000))
    }

    @Test func bestsFromEntry() {
        let bests = ExerciseBests(entry: benchSession.entries[0])
        #expect(bests.repsAtWeight == [58_967: 10])
        #expect(abs(bests.volumeKg - 1_769.01) < 0.01)
    }
}
```

Run → FAIL.

- [ ] **Step 2: Implement**

`Metrics/WorkoutMetrics.swift`:
```swift
public enum WorkoutMetrics {
    public static func workingSets(_ entry: WorkoutEntry) -> [WorkoutSet] {
        entry.sets.filter { $0.done && !$0.warmup }
    }

    public static func volumeKg(_ entry: WorkoutEntry) -> Double {
        workingSets(entry).reduce(0) { $0 + $1.weightKg * Double($1.reps) * $1.multiplier }
    }

    public static func volumeKg(_ workout: Workout) -> Double {
        workout.entries.reduce(0) { $0 + volumeKg($1) }
    }

    public static func workingSetCount(_ workout: Workout) -> Int {
        workout.entries.reduce(0) { $0 + workingSets($1).count }
    }

    public static func bestE1RM(_ entry: WorkoutEntry, formula: OneRepMaxFormula = .epley) -> Double? {
        workingSets(entry).compactMap { OneRepMax.estimate(weightKg: $0.weightKg, reps: $0.reps, formula: formula) }.max()
    }
}
```

`Metrics/RecordDetector.swift`:
```swift
/// Weight key in grams, so float weights compare exactly.
public typealias WeightKey = Int

public func weightKey(_ kg: Double) -> WeightKey { Int((kg * 1_000).rounded()) }

public struct ExerciseBests: Sendable, Equatable, Codable {
    public let e1RMKg: Double?
    public let repsAtWeight: [WeightKey: Int]
    public let volumeKg: Double

    public init(e1RMKg: Double?, repsAtWeight: [WeightKey: Int], volumeKg: Double) {
        self.e1RMKg = e1RMKg
        self.repsAtWeight = repsAtWeight
        self.volumeKg = volumeKg
    }

    public init(entry: WorkoutEntry) {
        let sets = WorkoutMetrics.workingSets(entry)
        self.init(
            e1RMKg: WorkoutMetrics.bestE1RM(entry),
            repsAtWeight: sets.reduce(into: [:]) { acc, s in
                acc[weightKey(s.weightKg)] = max(acc[weightKey(s.weightKg)] ?? 0, s.reps)
            },
            volumeKg: WorkoutMetrics.volumeKg(entry)
        )
    }

    public func merging(_ other: ExerciseBests) -> ExerciseBests {
        let e1RM = [e1RMKg, other.e1RMKg].compactMap { $0 }.max()
        return ExerciseBests(e1RMKg: e1RM,
                             repsAtWeight: repsAtWeight.merging(other.repsAtWeight, uniquingKeysWith: max),
                             volumeKg: max(volumeKg, other.volumeKg))
    }
}

public enum RecordKind: String, Sendable, Codable {
    case e1RM, repsAtWeight, volume
}

public struct PersonalRecord: Sendable, Equatable, Codable {
    public let exerciseId: String
    public let kind: RecordKind
    public let valueKg: Double?
    public let reps: Int?
    public let weightKg: Double?
    public let previousKg: Double?
}

public enum RecordDetector {
    /// Records only count against existing history; a first-ever session sets bests silently.
    public static func records(for workout: Workout, previous: [String: ExerciseBests]) -> [PersonalRecord] {
        workout.entries.flatMap { entry -> [PersonalRecord] in
            guard let prior = previous[entry.exerciseId] else { return [] }
            let now = ExerciseBests(entry: entry)
            var found: [PersonalRecord] = []
            if let e1RM = now.e1RMKg, e1RM > (prior.e1RMKg ?? 0) + 0.01 {
                found.append(PersonalRecord(exerciseId: entry.exerciseId, kind: .e1RM, valueKg: e1RM, reps: nil,
                                            weightKg: nil, previousKg: prior.e1RMKg))
            }
            if let best = now.repsAtWeight
                .filter({ key, reps in reps > (prior.repsAtWeight[key] ?? Int.max) })
                .max(by: { $0.key < $1.key }) {
                found.append(PersonalRecord(exerciseId: entry.exerciseId, kind: .repsAtWeight, valueKg: nil,
                                            reps: best.value, weightKg: Double(best.key) / 1_000, previousKg: nil))
            }
            if now.volumeKg > prior.volumeKg + 0.01 {
                found.append(PersonalRecord(exerciseId: entry.exerciseId, kind: .volume, valueKg: now.volumeKg,
                                            reps: nil, weightKg: nil, previousKg: prior.volumeKg))
            }
            return found
        }
    }
}
```
(`found` is a local accumulator inside one function; the returned values are immutable.)

Run → PASS. **Commit:** `feat(core): workout metrics and PR detection`

---

### Task 10: CSV parser

**Files:** Create `Import/CSVParser.swift`; Test `CSVParserTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
@testable import GymCore

@Suite struct CSVParserTests {
    @Test func simpleRows() {
        #expect(CSVParser.parse("a,b,c\n1,2,3\n") == [["a", "b", "c"], ["1", "2", "3"]])
    }

    @Test func quotedFieldsWithCommasQuotesAndNewlines() {
        let text = "name,note\n\"Bench, flat\",\"said \"\"easy\"\"\"\nx,\"two\nlines\"\n"
        #expect(CSVParser.parse(text) == [["name", "note"], ["Bench, flat", "said \"easy\""], ["x", "two\nlines"]])
    }

    @Test func crlfAndMissingTrailingNewline() {
        #expect(CSVParser.parse("a,b\r\n1,2") == [["a", "b"], ["1", "2"]])
    }

    @Test func emptyFieldsKept() {
        #expect(CSVParser.parse("a,,c\n") == [["a", "", "c"]])
    }

    @Test func blankLinesSkipped() {
        #expect(CSVParser.parse("a\n\nb\n") == [["a"], ["b"]])
    }
}
```

Run → FAIL.

- [ ] **Step 2: Implement**

```swift
/// Minimal RFC 4180 parser: commas, double quotes with "" escapes, LF or CRLF, quoted newlines.
public enum CSVParser {
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = nil

        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let ch = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if ch == "\"" {
                    let next = iterator.next()
                    if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                } else {
                    field.append(ch)
                }
                continue
            }
            switch ch {
            case "\"": inQuotes = true
            case ",": endField()
            case "\n", "\r\n": endRow()
            case "\r": break
            default: field.append(ch)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
```
(Note: Swift treats `"\r\n"` as a single `Character`, so the `"\r\n"` case handles CRLF.)

Run → PASS. **Commit:** `feat(core): RFC 4180 CSV parser`

---

### Task 11: Fitbod CSV importer

**Files:** Create `Import/FitbodImporter.swift`; Test `FitbodImporterTests.swift`

- [ ] **Step 1: Failing tests** (fixture rows are real lines from the owner's export)

```swift
import Foundation
import Testing
@testable import GymCore

@Suite struct FitbodImporterTests {
    static let header = "Date,Exercise,Reps,Weight(kg),Duration(s),Distance(m),Incline,Resistance,isWarmup,Note,multiplier"
    static let sample = """
    \(header)
    2026-09-19 18:02:11 +0000,Barbell Bench Press, 10,58.96707822663317,0.0,0.0,0.0,0.0,false,, 1.0
    2026-09-19 18:02:11 +0000,Barbell Bench Press, 10,58.96707822663317,0.0,0.0,0.0,0.0,false,, 1.0
    2026-09-19 18:02:11 +0000,Hammer Curls, 10,9.071858188712795,0.0,0.0,0.0,0.0,false,, 2.0
    2026-09-22 22:38:41 +0000,Lat Pulldown, 10,31.75150366049478,0.0,0.0,0.0,0.0,true,, 1.0
    2026-09-22 22:38:41 +0000,Lat Pulldown, 10,54.431084445645396,0.0,0.0,0.0,0.0,false,felt strong, 1.0
    2026-09-22 22:38:41 +0000,Walking, 0,0.0,1800.0,2400.0,0.0,0.0,false,, 1.0
    not-a-date,Lat Pulldown, 10,54.4,0.0,0.0,0.0,0.0,false,, 1.0
    2026-09-22 22:38:41 +0000,Lat Pulldown, ten,54.4,0.0,0.0,0.0,0.0,false,, 1.0
    2026-09-22 22:38:41 +0000,Lat Pulldown
    """

    @Test func groupsRowsIntoWorkoutsByTimestamp() throws {
        let result = try FitbodImporter.parse(Self.sample)
        #expect(result.workouts.count == 2)
        #expect(result.workouts.map(\.entries.count) == [2, 2])
        #expect(result.workouts[0].entries[0].exerciseName == "Barbell Bench Press")
        #expect(result.workouts[0].entries[0].sets.count == 2)
        #expect(result.rowCount == 9)
    }

    @Test func mapsFields() throws {
        let result = try FitbodImporter.parse(Self.sample)
        let hammer = result.workouts[0].entries[1].sets[0]
        #expect(hammer.reps == 10)
        #expect(abs(hammer.weightKg - 9.0719) < 0.001)
        #expect(hammer.multiplier == 2)
        let pulldown = result.workouts[1].entries[0].sets
        #expect(pulldown[0].warmup == true)
        #expect(pulldown[1].note == "felt strong")
        let walking = result.workouts[1].entries[1].sets[0]
        #expect(walking.durationSec == 1_800)
        #expect(walking.distanceM == 2_400)
        #expect(result.warmupSetCount == 1)
    }

    @Test func reportsBadRowsWithLineNumbers() throws {
        let result = try FitbodImporter.parse(Self.sample)
        #expect(result.rowErrors.map(\.line) == [8, 9, 10])
    }

    @Test func idsAreDeterministic() throws {
        let a = try FitbodImporter.parse(Self.sample)
        let b = try FitbodImporter.parse(Self.sample)
        #expect(a.workouts.map(\.id) == b.workouts.map(\.id))
        #expect(a.workouts[0].id != a.workouts[1].id)
    }

    @Test func parsesTimestamp() throws {
        let result = try FitbodImporter.parse(Self.sample)
        #expect(result.workouts[1].startedAt == Date(timeIntervalSince1970: 1_790_116_721))
    }

    @Test func rejectsUnknownHeader() {
        #expect(throws: FitbodImportError.unrecognizedHeader(["Date", "Lift"])) {
            try FitbodImporter.parse("Date,Lift\n1,2\n")
        }
    }

    @Test func rejectsEmptyFile() {
        #expect(throws: FitbodImportError.emptyFile) { try FitbodImporter.parse("") }
    }
}
```

Run → FAIL.

- [ ] **Step 2: Implement**

```swift
import CryptoKit
import Foundation

public struct ImportedSet: Sendable, Equatable {
    public let weightKg: Double
    public let reps: Int
    public let durationSec: Int?
    public let distanceM: Double?
    public let warmup: Bool
    public let multiplier: Double
    public let note: String?
}

public struct ImportedEntry: Sendable, Equatable {
    public let exerciseName: String
    public let sets: [ImportedSet]
}

public struct ImportedWorkout: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let entries: [ImportedEntry]
}

public struct ImportRowError: Sendable, Equatable {
    public let line: Int
    public let message: String
}

public struct FitbodImportResult: Sendable, Equatable {
    public let workouts: [ImportedWorkout]
    public let rowErrors: [ImportRowError]
    public let warmupSetCount: Int
    public let rowCount: Int
}

public enum FitbodImportError: Error, Equatable {
    case emptyFile
    case unrecognizedHeader([String])
}

public enum FitbodImporter {
    public static let expectedHeader = ["Date", "Exercise", "Reps", "Weight(kg)", "Duration(s)", "Distance(m)",
                                        "Incline", "Resistance", "isWarmup", "Note", "multiplier"]

    private struct Row {
        let dateKey: String
        let date: Date
        let exercise: String
        let set: ImportedSet
    }

    public static func parse(_ text: String) throws -> FitbodImportResult {
        let rows = CSVParser.parse(text)
        guard let header = rows.first else { throw FitbodImportError.emptyFile }
        let trimmedHeader = header.map { $0.trimmingCharacters(in: .whitespaces) }
        guard trimmedHeader == expectedHeader else { throw FitbodImportError.unrecognizedHeader(trimmedHeader) }

        let parsed = rows.dropFirst().enumerated().map { index, fields in parseRow(fields, line: index + 2) }
        let good = parsed.compactMap { try? $0.get() }
        let errors = parsed.compactMap { result -> ImportRowError? in
            if case .failure(let error) = result { return error }
            return nil
        }
        return FitbodImportResult(workouts: group(good), rowErrors: errors,
                                  warmupSetCount: good.filter(\.set.warmup).count, rowCount: rows.count - 1)
    }

    private static func parseRow(_ f: [String], line: Int) -> Result<Row, ImportRowError> {
        guard f.count == expectedHeader.count else {
            return .failure(ImportRowError(line: line, message: "Expected 11 columns, found \(f.count)"))
        }
        let v = f.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let date = dateFormatter.date(from: v[0]) else {
            return .failure(ImportRowError(line: line, message: "Unreadable date '\(v[0])'"))
        }
        guard !v[1].isEmpty else { return .failure(ImportRowError(line: line, message: "Missing exercise name")) }
        guard let reps = Double(v[2]), let weight = Double(v[3]), let duration = Double(v[4]),
              let distance = Double(v[5]), let multiplier = Double(v[10]) else {
            return .failure(ImportRowError(line: line, message: "Unreadable number in row"))
        }
        let set = ImportedSet(weightKg: weight, reps: Int(reps), durationSec: duration > 0 ? Int(duration) : nil,
                              distanceM: distance > 0 ? distance : nil, warmup: v[8].lowercased() == "true",
                              multiplier: multiplier > 0 ? multiplier : 1, note: v[9].isEmpty ? nil : v[9])
        return .success(Row(dateKey: v[0], date: date, exercise: v[1], set: set))
    }

    private static func group(_ rows: [Row]) -> [ImportedWorkout] {
        let byDate = Dictionary(grouping: rows, by: \.dateKey)
        return byDate.values.compactMap { dayRows -> ImportedWorkout? in
            guard let first = dayRows.first else { return nil }
            let names = dayRows.map(\.exercise).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let entries = names.map { name in
                ImportedEntry(exerciseName: name, sets: dayRows.filter { $0.exercise == name }.map(\.set))
            }
            return ImportedWorkout(id: stableID(first.dateKey, names), startedAt: first.date, entries: entries)
        }
        .sorted { $0.startedAt < $1.startedAt }
    }

    private static func stableID(_ key: String, _ names: [String]) -> UUID {
        let digest = SHA256.hash(data: Data(([key] + names).joined(separator: "|").utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()
}
```
Note: `DateFormatter` isn't `Sendable`. If Swift 6 complains about the static, mark it `nonisolated(unsafe) private static let` (it's only read after init). The expected epoch 1790116721 was checked with `date -j -u -f "%Y-%m-%d %H:%M:%S" "2026-09-22 22:38:41" +%s`.

Run → PASS. **Commit:** `feat(core): Fitbod CSV importer`

---

### Task 12: Exercise matcher

**Files:** Create `Import/ExerciseMatcher.swift`; Test `ExerciseMatcherTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
@testable import GymCore

@Suite struct ExerciseMatcherTests {
    private let library = [
        Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
        Exercise(id: "0313", name: "dumbbell hammer curl", bodyPart: "upper arms", equipment: "dumbbell", target: "biceps"),
        Exercise(id: "0150", name: "cable pulldown", bodyPart: "back", equipment: "cable", target: "lats",
                 aliases: ["Lat Pulldown"]),
        Exercise(id: "0600", name: "dumbbell incline bench press", bodyPart: "chest", equipment: "dumbbell",
                 target: "pectorals"),
    ]

    @Test func exactIgnoresCaseAndPunctuation() {
        #expect(ExerciseMatcher(library: library).match("Barbell Bench-Press") ==
                ExerciseMatch(exerciseId: "0025", kind: .exact, score: 1))
    }

    @Test func aliasMatch() {
        #expect(ExerciseMatcher(library: library).match("Lat Pulldown")?.kind == .alias)
        #expect(ExerciseMatcher(library: library).match("Lat Pulldown")?.exerciseId == "0150")
    }

    @Test func fuzzyMatchHandlesPlurals() throws {
        let m = try #require(ExerciseMatcher(library: library).match("Hammer Curls"))
        #expect(m.exerciseId == "0313")
        #expect(m.kind == .fuzzy)
        #expect(m.score >= 0.6)
    }

    @Test func fuzzyPrefersBestScore() throws {
        let m = try #require(ExerciseMatcher(library: library).match("Dumbbell Incline Bench Press"))
        #expect(m.exerciseId == "0600")
        #expect(m.kind == .exact)
    }

    @Test func noMatchBelowThreshold() {
        #expect(ExerciseMatcher(library: library).match("Glute Ham Raise") == nil)
    }

    @Test func normalize() {
        #expect(ExerciseMatcher.normalize("  Cable  Rope-Overhead (Triceps) ") == "cable rope overhead triceps")
    }
}
```

Run → FAIL.

- [ ] **Step 2: Implement**

```swift
public enum MatchKind: String, Sendable, Codable {
    case exact, alias, fuzzy
}

public struct ExerciseMatch: Sendable, Equatable {
    public let exerciseId: String
    public let kind: MatchKind
    public let score: Double
}

public struct ExerciseMatcher: Sendable {
    private let entries: [(id: String, name: String, tokens: Set<String>, aliases: Set<String>, length: Int)]
    public let minimumScore: Double

    public init(library: [Exercise], minimumScore: Double = 0.6) {
        self.minimumScore = minimumScore
        self.entries = library.map { ex in
            let name = Self.normalize(ex.name)
            return (ex.id, name, Self.tokens(name), Set(ex.aliases.map(Self.normalize)), name.count)
        }
    }

    public func match(_ raw: String) -> ExerciseMatch? {
        let name = Self.normalize(raw)
        if let hit = entries.first(where: { $0.name == name }) {
            return ExerciseMatch(exerciseId: hit.id, kind: .exact, score: 1)
        }
        if let hit = entries.first(where: { $0.aliases.contains(name) }) {
            return ExerciseMatch(exerciseId: hit.id, kind: .alias, score: 1)
        }
        let query = Self.tokens(name)
        let best = entries
            .map { (entry: $0, score: Self.jaccard(query, $0.tokens)) }
            .filter { $0.score >= minimumScore }
            .max { lhs, rhs in
                lhs.score == rhs.score ? lhs.entry.length > rhs.entry.length : lhs.score < rhs.score
            }
        return best.map { ExerciseMatch(exerciseId: $0.entry.id, kind: .fuzzy, score: $0.score) }
    }

    public static func normalize(_ s: String) -> String {
        s.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }

    static func tokens(_ normalized: String) -> Set<String> {
        Set(normalized.split(separator: " ").map { token in
            token.count > 3 && token.hasSuffix("s") ? String(token.dropLast()) : String(token)
        })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }
}
```

Run → PASS. **Commit:** `feat(core): exercise name matcher (exact, alias, fuzzy)`

---

### Task 13: Plan changes, validator and shared fixture

**Files:**
- Create: `Plan/PlanChange.swift`, `Plan/PlanChangeValidator.swift`
- Create: `app/fixtures/plan-changes.json`
- Test: `Tests/GymCoreTests/PlanChangeValidatorTests.swift`

- [ ] **Step 1: Write the shared fixture** `app/fixtures/plan-changes.json`

```json
{
  "library": ["bench", "incline-db", "db-shoulder-press", "machine-shoulder-press", "leg-extension", "dips"],
  "plan": {
    "routines": [
      { "id": "push", "name": "Push + Arms", "exerciseIds": ["bench", "incline-db"] },
      { "id": "pull", "name": "Pull + Shoulders + Triceps", "exerciseIds": ["machine-shoulder-press"] },
      { "id": "legs", "name": "Legs", "exerciseIds": ["leg-extension"] }
    ]
  },
  "cases": [
    {
      "name": "valid knee-break proposal",
      "proposal": {
        "summary": "Knee break: replace Legs with upper work for 4 weeks",
        "changes": [
          { "id": "c1", "type": "week", "weekday": 6, "routineId": "push" },
          { "id": "c2", "type": "weight", "routineId": "push", "exerciseId": "bench", "weightKg": 63.5 },
          { "id": "c3", "type": "swap-exercise", "routineId": "pull", "exerciseId": "machine-shoulder-press", "toExerciseId": "db-shoulder-press" },
          { "id": "c4", "type": "remove-exercise", "routineId": "legs", "exerciseId": "leg-extension" },
          { "id": "c5", "type": "pause-routine", "routineId": "legs", "paused": true }
        ]
      },
      "violations": []
    },
    {
      "name": "unknown routine and exercise",
      "proposal": {
        "summary": "Bad refs",
        "changes": [
          { "id": "c1", "type": "sets", "routineId": "nope", "exerciseId": "bench", "sets": 3 },
          { "id": "c2", "type": "sets", "routineId": "push", "exerciseId": "dips", "sets": 3 }
        ]
      },
      "violations": [ { "changeId": "c1", "field": "routineId" }, { "changeId": "c2", "field": "exerciseId" } ]
    },
    {
      "name": "out of range values",
      "proposal": {
        "summary": "Ranges",
        "changes": [
          { "id": "c1", "type": "sets", "routineId": "push", "exerciseId": "bench", "sets": 0 },
          { "id": "c2", "type": "reps", "routineId": "push", "exerciseId": "bench", "reps": 8, "repsMin": 10 },
          { "id": "c3", "type": "weight", "routineId": "push", "exerciseId": "bench", "weightKg": 900 },
          { "id": "c4", "type": "week", "weekday": 8 }
        ]
      },
      "violations": [
        { "changeId": "c1", "field": "sets" }, { "changeId": "c2", "field": "repsMin" },
        { "changeId": "c3", "field": "weightKg" }, { "changeId": "c4", "field": "weekday" }
      ]
    },
    {
      "name": "add routine then add exercise to it",
      "proposal": {
        "summary": "New upper day",
        "changes": [
          { "id": "c1", "type": "add-routine", "routineId": "upper", "name": "Upper weak points" },
          { "id": "c2", "type": "add-exercise", "routineId": "upper", "exerciseId": "dips", "sets": 3, "reps": 10 }
        ]
      },
      "violations": []
    },
    {
      "name": "proposal-level problems",
      "proposal": {
        "summary": "",
        "changes": [
          { "id": "c1", "type": "rename-routine", "routineId": "push", "name": "" },
          { "id": "c1", "type": "swap-exercise", "routineId": "push", "exerciseId": "bench", "toExerciseId": "incline-db" },
          { "id": "c3", "type": "superset", "routineId": "push", "exerciseId": "bench", "withExerciseId": "bench" }
        ]
      },
      "violations": [
        { "changeId": null, "field": "summary" }, { "changeId": "c1", "field": "id" },
        { "changeId": "c1", "field": "name" }, { "changeId": "c1", "field": "toExerciseId" },
        { "changeId": "c3", "field": "withExerciseId" }
      ]
    },
    {
      "name": "missing required field",
      "proposal": {
        "summary": "Missing",
        "changes": [
          { "id": "c1", "type": "exercise-prog", "routineId": "push", "exerciseId": "bench" },
          { "id": "c2", "type": "add-exercise", "routineId": "push", "exerciseId": "dips", "sets": 3 }
        ]
      },
      "violations": [ { "changeId": "c1", "field": "policy" }, { "changeId": "c2", "field": "reps" } ]
    }
  ]
}
```

- [ ] **Step 2: Failing tests** `PlanChangeValidatorTests.swift`

```swift
import Foundation
import Testing
@testable import GymCore

private struct Fixture: Decodable {
    struct Case: Decodable {
        struct V: Decodable, Hashable { let changeId: String?; let field: String }
        let name: String
        let proposal: PlanProposal
        let violations: [V]
    }
    let library: [String]
    let plan: PlanSnapshot
    let cases: [Case]
}

@Suite struct PlanChangeValidatorTests {
    fileprivate static let fixture: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // GymCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // GymCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // app
            .appendingPathComponent("fixtures/plan-changes.json")
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    @Test(arguments: PlanChangeValidatorTests.fixture.cases.map(\.name))
    func sharedFixture(caseName: String) throws {
        let fx = Self.fixture
        let testCase = try #require(fx.cases.first { $0.name == caseName })
        let library = Set(fx.library)
        let validator = PlanChangeValidator(plan: fx.plan, exerciseExists: { library.contains($0) })
        let got = Set(validator.validate(testCase.proposal).map { Fixture.Case.V(changeId: $0.changeId, field: $0.field) })
        #expect(got == Set(testCase.violations))
    }

    @Test func tooManyChanges() {
        let changes = (0..<26).map { PlanChange(id: "c\($0)", type: .sets, routineId: "push", exerciseId: "bench", sets: 3) }
        let validator = PlanChangeValidator(plan: Self.fixture.plan, exerciseExists: { _ in true })
        let got = validator.validate(PlanProposal(summary: "Many", changes: changes))
        #expect(got.contains { $0.field == "changes" })
    }

    @Test func routineLimit() {
        let adds = (0..<5).map { PlanChange(id: "a\($0)", type: .addRoutine, routineId: "r\($0)", name: "R\($0)") }
        let validator = PlanChangeValidator(plan: Self.fixture.plan, exerciseExists: { _ in true })
        let got = validator.validate(PlanProposal(summary: "Lots", changes: adds))
        #expect(got.contains { $0.changeId == "a4" && $0.field == "routineId" })
    }

    @Test func changeTypeJSONNames() throws {
        let data = try JSONEncoder().encode(PlanChangeType.swapExercise)
        #expect(String(decoding: data, as: UTF8.self) == "\"swap-exercise\"")
    }
}
```

Run → FAIL.

- [ ] **Step 3: Implement** `Plan/PlanChange.swift`

```swift
public enum PlanChangeType: String, Codable, Sendable, CaseIterable {
    case addExercise = "add-exercise"
    case removeExercise = "remove-exercise"
    case swapExercise = "swap-exercise"
    case sets, reps, repsMin, sec, weight, cardio, reorder, superset
    case routineProg = "routine-prog"
    case exerciseProg = "exercise-prog"
    case inc
    case addRoutine = "add-routine"
    case removeRoutine = "remove-routine"
    case renameRoutine = "rename-routine"
    case pauseRoutine = "pause-routine"
    case week
}

/// One proposed plan edit. Field names are the JSON contract shared with the MCP server.
public struct PlanChange: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let type: PlanChangeType
    public let routineId: String?
    public let exerciseId: String?
    public let toExerciseId: String?
    public let withExerciseId: String?
    public let sets: Int?
    public let reps: Int?
    public let repsMin: Int?
    public let sec: Int?
    public let weightKg: Double?
    public let minutes: Double?
    public let speed: Double?
    public let incKg: Double?
    public let policy: ProgressionPolicy?
    public let position: Int?
    public let name: String?
    public let weekday: Int?
    public let paused: Bool?
    public let reason: String?

    public init(id: String, type: PlanChangeType, routineId: String? = nil, exerciseId: String? = nil,
                toExerciseId: String? = nil, withExerciseId: String? = nil, sets: Int? = nil, reps: Int? = nil,
                repsMin: Int? = nil, sec: Int? = nil, weightKg: Double? = nil, minutes: Double? = nil,
                speed: Double? = nil, incKg: Double? = nil, policy: ProgressionPolicy? = nil, position: Int? = nil,
                name: String? = nil, weekday: Int? = nil, paused: Bool? = nil, reason: String? = nil) {
        self.id = id
        self.type = type
        self.routineId = routineId
        self.exerciseId = exerciseId
        self.toExerciseId = toExerciseId
        self.withExerciseId = withExerciseId
        self.sets = sets
        self.reps = reps
        self.repsMin = repsMin
        self.sec = sec
        self.weightKg = weightKg
        self.minutes = minutes
        self.speed = speed
        self.incKg = incKg
        self.policy = policy
        self.position = position
        self.name = name
        self.weekday = weekday
        self.paused = paused
        self.reason = reason
    }
}

public struct PlanProposal: Codable, Sendable, Equatable {
    public let summary: String
    public let changes: [PlanChange]

    public init(summary: String, changes: [PlanChange]) {
        self.summary = summary
        self.changes = changes
    }
}

public struct PlanSnapshot: Codable, Sendable, Equatable {
    public struct RoutineRef: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let exerciseIds: [String]

        public init(id: String, name: String, exerciseIds: [String]) {
            self.id = id
            self.name = name
            self.exerciseIds = exerciseIds
        }
    }

    public let routines: [RoutineRef]

    public init(routines: [RoutineRef]) { self.routines = routines }
}

public struct PlanViolation: Codable, Sendable, Equatable {
    public let changeId: String?
    public let field: String
    public let message: String
}
```

- [ ] **Step 4: Implement** `Plan/PlanChangeValidator.swift`

```swift
/// Validates Claude's proposals against the closed change list, value ranges and the current plan.
/// Mirrored in TypeScript (supabase/functions/_shared/plan-validation.ts) using app/fixtures/plan-changes.json.
public struct PlanChangeValidator: Sendable {
    public static let maxChanges = 25
    public static let maxRoutines = 7
    public static let maxExercisesPerRoutine = 20
    public static let maxSummary = 500
    public static let maxReason = 300
    public static let maxName = 40

    private let plan: PlanSnapshot
    private let exerciseExists: @Sendable (String) -> Bool

    public init(plan: PlanSnapshot, exerciseExists: @escaping @Sendable (String) -> Bool) {
        self.plan = plan
        self.exerciseExists = exerciseExists
    }

    public func validate(_ proposal: PlanProposal) -> [PlanViolation] {
        var out: [PlanViolation] = []
        let summary = proposal.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty || summary.count > Self.maxSummary {
            out.append(PlanViolation(changeId: nil, field: "summary", message: "Summary must be 1–\(Self.maxSummary) characters"))
        }
        if proposal.changes.isEmpty || proposal.changes.count > Self.maxChanges {
            out.append(PlanViolation(changeId: nil, field: "changes", message: "1–\(Self.maxChanges) changes allowed"))
        }
        var seen = Set<String>()
        var routines = Dictionary(uniqueKeysWithValues: plan.routines.map { ($0.id, $0.exerciseIds) })
        for change in proposal.changes {
            if !seen.insert(change.id).inserted {
                out.append(PlanViolation(changeId: change.id, field: "id", message: "Duplicate change id"))
            }
            if let reason = change.reason, reason.count > Self.maxReason {
                out.append(PlanViolation(changeId: change.id, field: "reason", message: "Reason too long"))
            }
            let (violations, updated) = check(change, routines: routines)
            out.append(contentsOf: violations)
            routines = updated
        }
        return out
    }

    // Returns violations for one change and the routine state after applying it (when valid).
    private func check(_ c: PlanChange, routines: [String: [String]]) -> ([PlanViolation], [String: [String]]) {
        var v: [PlanViolation] = []
        func fail(_ field: String, _ message: String) {
            v.append(PlanViolation(changeId: c.id, field: field, message: message))
        }
        func require<T>(_ value: T?, _ field: String) -> T? {
            if value == nil { fail(field, "Required for \(c.type.rawValue)") }
            return value
        }
        func range<T: Comparable>(_ value: T?, _ field: String, _ bounds: ClosedRange<T>, required: Bool = true) {
            guard let value = required ? require(value, field) : value else { return }
            if !bounds.contains(value) { fail(field, "Must be \(bounds.lowerBound)–\(bounds.upperBound)") }
        }
        func name(_ value: String?) {
            guard let value = require(value, "name") else { return }
            let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.count > Self.maxName { fail("name", "Name must be 1–\(Self.maxName) characters") }
        }

        var next = routines
        func resolveRoutine() -> [String]? {
            if c.type == .addRoutine || c.type == .week { return nil }
            guard let id = require(c.routineId, "routineId") else { return nil }
            guard let list = routines[id] else { fail("routineId", "Unknown routine '\(id)'"); return nil }
            return list
        }
        let routineExercises = resolveRoutine()
        func inRoutine(_ id: String?, _ field: String) -> String? {
            guard let id = require(id, field), let list = routineExercises else { return nil }
            if !list.contains(id) { fail(field, "'\(id)' is not in this routine"); return nil }
            return id
        }
        func inLibrary(_ id: String?, _ field: String) -> String? {
            guard let id = require(id, field) else { return nil }
            if !exerciseExists(id) { fail(field, "Unknown exercise '\(id)'"); return nil }
            return id
        }

        switch c.type {
        case .addExercise:
            let id = inLibrary(c.exerciseId, "exerciseId")
            range(c.sets, "sets", 1...10)
            range(c.reps, "reps", 1...100)
            range(c.weightKg, "weightKg", 0...500, required: false)
            if let id, let list = routineExercises, let rid = c.routineId {
                if list.contains(id) { fail("exerciseId", "Already in routine") }
                else if list.count >= Self.maxExercisesPerRoutine { fail("exerciseId", "Routine is full") }
                else if v.isEmpty { next[rid] = list + [id] }
            }
        case .removeExercise:
            if let id = inRoutine(c.exerciseId, "exerciseId"), let rid = c.routineId, let list = routineExercises {
                next[rid] = list.filter { $0 != id }
            }
        case .swapExercise:
            let from = inRoutine(c.exerciseId, "exerciseId")
            let to = inLibrary(c.toExerciseId, "toExerciseId")
            if let to, let list = routineExercises, list.contains(to) { fail("toExerciseId", "Already in routine") }
            if v.isEmpty, let from, let to, let rid = c.routineId, let list = routineExercises {
                next[rid] = list.map { $0 == from ? to : $0 }
            }
        case .sets:
            _ = inRoutine(c.exerciseId, "exerciseId"); range(c.sets, "sets", 1...10)
        case .reps:
            _ = inRoutine(c.exerciseId, "exerciseId"); range(c.reps, "reps", 1...100)
            if let min = c.repsMin, let max = c.reps, min < 1 || min > max { fail("repsMin", "Must be 1–reps") }
        case .repsMin:
            _ = inRoutine(c.exerciseId, "exerciseId"); range(c.repsMin, "repsMin", 1...100)
        case .sec:
            _ = inRoutine(c.exerciseId, "exerciseId"); range(c.sec, "sec", 5...3600)
        case .weight:
            _ = inRoutine(c.exerciseId, "exerciseId"); range(c.weightKg, "weightKg", 0...500)
        case .cardio:
            _ = inRoutine(c.exerciseId, "exerciseId"); range(c.minutes, "minutes", 1...300)
            range(c.speed, "speed", 0...50, required: false)
        case .reorder:
            _ = inRoutine(c.exerciseId, "exerciseId"); range(c.position, "position", 0...(Self.maxExercisesPerRoutine - 1))
        case .superset:
            let a = inRoutine(c.exerciseId, "exerciseId")
            let b = inRoutine(c.withExerciseId, "withExerciseId")
            if let a, let b, a == b { fail("withExerciseId", "Can't superset an exercise with itself") }
        case .routineProg:
            _ = require(c.policy, "policy")
        case .exerciseProg:
            _ = inRoutine(c.exerciseId, "exerciseId"); _ = require(c.policy, "policy")
        case .inc:
            _ = inRoutine(c.exerciseId, "exerciseId"); range(c.incKg, "incKg", 0.1...20)
        case .addRoutine:
            name(c.name)
            if let id = require(c.routineId, "routineId") {
                if routines[id] != nil { fail("routineId", "Routine id already exists") }
                else if routines.count >= Self.maxRoutines { fail("routineId", "At most \(Self.maxRoutines) routines") }
                else if v.isEmpty { next[id] = [] }
            }
        case .removeRoutine:
            if routineExercises != nil, let rid = c.routineId { next[rid] = nil }
        case .renameRoutine:
            name(c.name)
        case .pauseRoutine:
            _ = require(c.paused, "paused")
        case .week:
            range(c.weekday, "weekday", 1...7)
            if let rid = c.routineId, routines[rid] == nil { fail("routineId", "Unknown routine '\(rid)'") }
        }
        return (v, v.isEmpty ? next : routines)
    }
}
```
(Local `var` accumulators live only inside this function; inputs and outputs are immutable values. If this file
passes 400 lines when later plans add rules, split `check` into one function per change family.)

Run: `swift test --filter PlanChangeValidatorTests` → Expected: PASS (6 fixture cases + 3 tests).

- [ ] **Step 5: Commit** — `feat(core): plan change model and validator with shared fixture`

---

### Task 14: Coverage gate, lint and review

- [ ] **Step 1: Coverage**

Run: `app/scripts/coverage-gymcore.sh 90`
Expected: `Line coverage: NN%` with NN ≥ 90 and exit 0. If it's below 90, add tests for the uncovered lines the
report lists (don't lower the threshold).

- [ ] **Step 2: Lint**

Run: `cd app/ios/Packages/GymCore && swiftlint lint --quiet Sources`
Expected: no errors. Fix warnings for force unwraps, line length > 140 and function length > 60.

- [ ] **Step 3: Full suite**

Run: `app/scripts/test-all.sh` → Expected: all pass.

- [ ] **Step 4: Codex review**

Run from `app/`: `codex review --base main "Review the GymCore Swift package for correctness bugs, edge cases in progression/plates/CSV import/validator, Swift 6 concurrency issues, and immutability. Report findings with file:line and severity."`
Fix every CRITICAL/HIGH finding with a failing test first, rerun `scripts/test-all.sh`, then commit
`fix(core): address review findings`.

- [ ] **Step 5: Merge**

```bash
git checkout main && git merge --no-ff plan-01-gymcore -m "merge: plan 01 GymCore domain" && git branch -d plan-01-gymcore
```
