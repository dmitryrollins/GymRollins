# Plan 04: Log, workout detail, Body (weigh-ins, goal, trends)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Body and Log placeholders. **Log** has a week strip with minutes per day and past workouts
(date · duration, name, top sets, records), plus workout detail (edit sets, delete, share). **Body** has the
81 → 85 kg goal card, weigh-ins (add/delete), a bodyweight chart with ranges, the weekly trend and projected date,
and strength trends for the most-logged lifts.

**Architecture:** Pure calculations (`WeekActivity`, `BodyTrend`) live in GymData with unit tests. Records are
computed at finish time (plan 03) and now **persisted** on the workout, so the Log doesn't have to recompute PRs.
Views are thin; they reload on `env.dataRevision`, which bumps after any write.

**Tech Stack:** SwiftUI iOS 26, Swift Charts, SwiftData (GymData), Swift Testing, XCUITest.

**Depends on:** Plans 02 and 03 merged. **Spec:** §1 (body tracking), §6. **Mockups:** `docs/design/Log`,
`WorkoutDetail`, `Body`, `AddWeighIn`, `ExerciseHistory`.

**Conventions:** Branch `plan-04-log-body`. Commit per task with the trailer lines. Never `git add -A`. The owner's
goal: 81 → 85 kg by 2026-12-31.

---

### Task 1: Persist records on workouts

**Files:** Modify `GymData/Records/WorkoutRecords.swift` (add `recordsData: Data?`),
`GymData/Repositories/WorkoutRepository.swift`, `GymRollins/Features/Workout/WorkoutSession.swift`,
`GymRollins/App/AppEnvironment.swift`; Tests in `GymDataTests/RepositoryTests.swift`, `GymRollinsTests/WorkoutSessionTests.swift`.

- [ ] **Step 1: Failing test** (GymData):
```swift
@Test func recordsRoundTrip() throws {
    let repo = WorkoutRepository(context: container.mainContext, now: clock)
    let w = Workout(startedAt: clock(), endedAt: clock().addingTimeInterval(3_600), name: "Push")
    let pr = PersonalRecord(exerciseId: "0025", kind: .e1RM, valueKg: 78.6, reps: nil, weightKg: nil, previousKg: 70.8)
    try repo.save(w, records: [pr])
    #expect(try repo.records(for: w.id) == [pr])
    #expect(try repo.recordCounts(ids: [w.id]) == [w.id: 1])
}
```
(`PersonalRecord` needs a `public init` in GymCore if one doesn't exist yet. Add it with a GymCore test.)

- [ ] **Step 2: Implement**
- `WorkoutRecord.recordsData: Data?` stores JSON-encoded `[PersonalRecord]`.
- `WorkoutRepository.save(_ workout: Workout, records: [PersonalRecord] = [])` sets `recordsData` when records is
  non-empty, otherwise leaves the existing value (so editing a workout later doesn't erase them).
- `records(for id: UUID) throws -> [PersonalRecord]` and `recordCounts(ids: [UUID]) throws -> [UUID: Int]`.
- `WorkoutSession` init param `saveFinished: (Workout, [PersonalRecord]) throws -> Void`. In `finish`, compute the
  summary first, then call `saveFinished(finished, summary.records)`. Update `AppEnvironment.makeSession` and the
  existing session tests (the spy captures records).
- Add `AppEnvironment.dataRevision` (Int) and `func dataChanged()`. Call it after finishing a workout, adding or
  deleting a weigh-in, and editing or deleting a workout.

Run all tests → PASS. **Commit:** `feat(data): persist personal records with finished workouts`

---

### Task 2: WeekActivity and BodyTrend (pure)

**Files:** Create `GymData/Sources/GymData/Insights/WeekActivity.swift`, `Insights/BodyTrend.swift`; Tests
`GymDataTests/WeekActivityTests.swift`, `BodyTrendTests.swift`.

- [ ] **Step 1: Failing tests**

`WeekActivityTests.swift`:
```swift
import Foundation
import GymCore
import Testing
@testable import GymData

@Suite struct WeekActivityTests {
    var cal: Calendar { var c = Calendar(identifier: .iso8601); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    @Test func minutesPerIsoDayForTheWeekOfDate() {
        let tue = ISO8601DateFormatter().date(from: "2026-09-22T22:38:41Z")!
        let workouts = [
            Workout(startedAt: tue, endedAt: tue.addingTimeInterval(3_957), name: "Pull"),
            Workout(startedAt: tue.addingTimeInterval(-7 * 86_400), endedAt: tue.addingTimeInterval(-7 * 86_400 + 600), name: "Old"),
        ]
        let sat = ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z")!
        let week = WeekActivity(workouts: workouts, containing: sat, calendar: cal)
        #expect(week.days.map(\.weekday) == [1, 2, 3, 4, 5, 6, 7])
        #expect(week.days[1].minutes == 65)
        #expect(week.days.filter { $0.minutes > 0 }.count == 1)
        #expect(week.days[5].isToday)
        #expect(week.start == ISO8601DateFormatter().date(from: "2026-09-21T00:00:00Z"))
    }
}
```

`BodyTrendTests.swift`:
```swift
import Foundation
import Testing
@testable import GymData

@Suite struct BodyTrendTests {
    let day: TimeInterval = 86_400
    let t0 = ISO8601DateFormatter().date(from: "2026-09-01T07:00:00Z")!

    @Test func emptyHasNoTrend() {
        let trend = BodyTrend(entries: [], goalKg: 85, goalDate: nil, now: t0)
        #expect(trend.currentKg == nil)
        #expect(trend.progress == 0)
        #expect(trend.weeklyChangeKg == nil)
    }

    @Test func progressAndWeeklySlope() throws {
        // +0.2 kg per week over 4 weeks, starting 81.0
        let entries = (0...4).map { BodyweightEntry(date: t0.addingTimeInterval(Double($0) * 7 * day), weightKg: 81 + 0.2 * Double($0)) }
        let trend = BodyTrend(entries: entries, goalKg: 85, goalDate: nil, now: t0.addingTimeInterval(28 * day))
        #expect(trend.startKg == 81)
        #expect(trend.currentKg == 81.8)
        #expect(abs(try #require(trend.weeklyChangeKg) - 0.2) < 0.001)
        #expect(abs(trend.progress - 0.2) < 0.001)          // 0.8 of 4 kg
        let projected = try #require(trend.projectedGoalDate)  // 3.2 kg at 0.2/week = 16 weeks
        #expect(abs(projected.timeIntervalSince(t0.addingTimeInterval(28 * day)) - 16 * 7 * day) < day)
    }

    @Test func losingWeightHasNoProjection() {
        let entries = [BodyweightEntry(date: t0, weightKg: 82), BodyweightEntry(date: t0.addingTimeInterval(14 * day), weightKg: 81.5)]
        let trend = BodyTrend(entries: entries, goalKg: 85, goalDate: nil, now: t0.addingTimeInterval(14 * day))
        #expect(trend.projectedGoalDate == nil)
        #expect(trend.progress == 0) // below start -> clamped
    }

    @Test func requiredWeeklyRateToHitGoalDate() throws {
        let goalDate = t0.addingTimeInterval(20 * 7 * day)
        let trend = BodyTrend(entries: [BodyweightEntry(date: t0, weightKg: 81)], goalKg: 85, goalDate: goalDate, now: t0)
        #expect(abs(try #require(trend.requiredWeeklyKg) - 0.2) < 0.001)
    }
}
```

- [ ] **Step 2: Implement**

`Insights/WeekActivity.swift`:
```swift
import Foundation
import GymCore

public struct WeekActivity: Sendable, Equatable {
    public struct Day: Sendable, Equatable, Identifiable {
        public var id: Int { weekday }
        public let weekday: Int      // ISO 1 = Mon … 7 = Sun
        public let date: Date
        public let minutes: Int
        public let isToday: Bool
    }

    public let start: Date
    public let days: [Day]

    public init(workouts: [Workout], containing date: Date, calendar: Calendar = Calendar(identifier: .iso8601)) {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        self.start = start
        self.days = (0..<7).map { offset in
            let dayStart = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            let minutes = workouts
                .filter { calendar.isDate($0.startedAt, inSameDayAs: dayStart) }
                .reduce(0.0) { total, w in
                    total + max(0, (w.endedAt ?? w.startedAt).timeIntervalSince(w.startedAt) - w.pausedSeconds) / 60
                }
            return Day(weekday: offset + 1, date: dayStart, minutes: Int(minutes),
                       isToday: calendar.isDate(date, inSameDayAs: dayStart))
        }
    }
}
```

`Insights/BodyTrend.swift`:
```swift
import Foundation

/// Goal progress and trend from bodyweight entries (kg). Pure; entries in any order.
public struct BodyTrend: Sendable, Equatable {
    public let startKg: Double?
    public let currentKg: Double?
    public let goalKg: Double?
    /// 0…1 of the way from start to goal (clamped).
    public let progress: Double
    /// Least-squares slope over the last 8 weeks, in kg/week (nil with fewer than 2 entries spanning at least 6 days).
    public let weeklyChangeKg: Double?
    /// When the goal is reached at the current slope (nil if not trending toward the goal).
    public let projectedGoalDate: Date?
    /// kg/week needed to reach the goal by the goal date (nil without a goal date or current weight).
    public let requiredWeeklyKg: Double?

    public init(entries: [BodyweightEntry], goalKg: Double?, goalDate: Date?, now: Date) {
        let sorted = entries.sorted { $0.date < $1.date }
        startKg = sorted.first?.weightKg
        currentKg = sorted.last?.weightKg
        self.goalKg = goalKg
        progress = Self.progress(start: startKg, current: currentKg, goal: goalKg)
        let recent = sorted.filter { $0.date >= now.addingTimeInterval(-56 * 86_400) }
        weeklyChangeKg = Self.slopePerWeek(recent)
        projectedGoalDate = Self.projection(current: currentKg, goal: goalKg, slope: weeklyChangeKg, now: now)
        requiredWeeklyKg = Self.required(current: currentKg, goal: goalKg, goalDate: goalDate, now: now)
    }

    static func progress(start: Double?, current: Double?, goal: Double?) -> Double {
        guard let start, let current, let goal, goal != start else { return 0 }
        return min(1, max(0, (current - start) / (goal - start)))
    }

    static func slopePerWeek(_ entries: [BodyweightEntry]) -> Double? {
        guard entries.count >= 2, let first = entries.first?.date, let last = entries.last?.date,
              last.timeIntervalSince(first) >= 6 * 86_400 else { return nil }
        let xs = entries.map { $0.date.timeIntervalSince(first) / (7 * 86_400) }
        let ys = entries.map(\.weightKg)
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        let num = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let den = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        return den == 0 ? nil : num / den
    }

    static func projection(current: Double?, goal: Double?, slope: Double?, now: Date) -> Date? {
        guard let current, let goal, let slope, slope != 0 else { return nil }
        let weeks = (goal - current) / slope
        guard weeks > 0 else { return nil }
        return now.addingTimeInterval(weeks * 7 * 86_400)
    }

    static func required(current: Double?, goal: Double?, goalDate: Date?, now: Date) -> Double? {
        guard let current, let goal, let goalDate else { return nil }
        let weeks = goalDate.timeIntervalSince(now) / (7 * 86_400)
        return weeks > 0 ? (goal - current) / weeks : nil
    }
}
```

Run `swift test` in GymData → PASS. **Commit:** `feat(data): week activity and body trend insights`

---

### Task 3: Log tab and workout detail

**Files:** Create `Features/Log/LogView.swift`, `Features/Log/WorkoutCard.swift`, `Features/Log/WorkoutDetailView.swift`;
modify `App/RootView.swift` (the Log tab uses `LogView`); UI test `GymRollinsUITests/LogUITests.swift`.
**Mockups:** `Log.dc.html`, `WorkoutDetail.dc.html`.

Behavior and identifiers:
- **LogView**: title "Log" (display font) and a trailing gear toolbar button `log.settings` that pushes
  `ComingSoonView(title: "Settings", …)` (plan 07 replaces it with `SettingsView`). Solid week strip (`WeekActivity`
  for `env.now()`): day letters, a cell per day with minutes ("65m") under days with training, today outlined with a
  dashed accent (`log.week.<weekday>`). "PAST WORKOUTS" list of `WorkoutCard`s for `env.workouts.recent(limit: 50)`,
  with lazy paging (load 50 more at the end).
- **WorkoutCard** (`log.workout.<id>`): top row "Tue 22 Sep · 1:05:57" (`DurationFormatter.clock`), and an amber
  "N records" badge when `recordCounts[id] > 0`. Name (headline). Summary of the first two exercises: "Lat Pulldown
  3 × 10 @ 120 lb · Cable Row 3 × 12 @ 120 lb" (working sets: "count × reps @ weight" when all equal, otherwise
  "10, 10, 12 @ 44 lb"). Tapping pushes `WorkoutDetailView`. Put the formatting in a pure helper
  `WorkoutText.setsSummary(_ entry: WorkoutEntry, unit:) -> String` with unit tests in
  `GymRollinsTests/WorkoutTextTests.swift` (cases: equal sets, varying reps, varying weights "25–27.5 lb",
  bodyweight "3 × 10").
- **WorkoutDetailView(workoutId:)**: glass back button, a glass "•••" menu (`detail.menu`) with "Edit"
  (`detail.edit`) and "Delete workout" (`detail.delete`, confirmation dialog, then `env.workouts.delete(id)`,
  `env.dataChanged()`, pop). Header stats in solid tiles: Duration `detail.duration`, Exercises, Volume (t or kg),
  Records. Then a section per exercise with each set row ("W 10 × 45 lb", "1 10 × 130 lb"; warm-ups labelled W).
  **Edit mode**: the set rows become editable reps/weight fields (`detail.set.<entryIndex>.<setIndex>.reps` and
  `.weight`). "Save" `detail.save` writes via `env.workouts.save(updated)` (records kept) and calls `dataChanged()`.
  A `ShareLink` (`detail.share`) shares a plain-text summary ("Push + Biceps — Sat 19 Sep, 58 min\nBench Press
  3 × 10 @ 130 lb\n…").

- [ ] **Step 1: Failing unit tests** `WorkoutTextTests.swift`:
```swift
import GymCore
import Testing
@testable import GymRollins

@Suite struct WorkoutTextTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private func entry(_ sets: [(Double, Int)], warmup: Bool = false) -> WorkoutEntry {
        WorkoutEntry(exerciseId: "x", sets: sets.map { WorkoutSet(weightKg: lb($0.0), reps: $0.1, done: true) })
    }

    @Test func equalSets() { #expect(WorkoutText.setsSummary(entry([(130, 10), (130, 10), (130, 10)]), unit: .lb) == "3 × 10 @ 130 lb") }
    @Test func varyingReps() { #expect(WorkoutText.setsSummary(entry([(44, 10), (44, 10), (44, 12)]), unit: .lb) == "10, 10, 12 @ 44 lb") }
    @Test func varyingWeights() { #expect(WorkoutText.setsSummary(entry([(25, 12), (27.5, 12)]), unit: .lb) == "12, 12 @ 25–27.5 lb") }
    @Test func bodyweight() { #expect(WorkoutText.setsSummary(entry([(0, 10), (0, 10), (0, 8)]), unit: .lb) == "10, 10, 8") }
    @Test func warmupsExcluded() {
        let e = WorkoutEntry(exerciseId: "x", sets: [WorkoutSet(weightKg: lb(45), reps: 10, done: true, warmup: true),
                                                      WorkoutSet(weightKg: lb(130), reps: 8, done: true)])
        #expect(WorkoutText.setsSummary(e, unit: .lb) == "1 × 8 @ 130 lb")
    }
}
```
- [ ] **Step 2:** Implement `WorkoutText` (in `Features/Log/WorkoutText.swift`), then the views.
- [ ] **Step 3: UI test** `LogUITests.swift` (launch with `-uiTesting -seedHistory -fixedNow 2026-09-26T09:00:00Z`):
  - `testLogShowsSeededWorkoutsWithDuration`: tap Log; `log.workout.*` cells exist (predicate on the identifier
    prefix, count ≥ 2); the first card contains "58:20" (the seed's 3,500 s duration). Assert with
    `staticTexts.containing(NSPredicate(format: "label CONTAINS '58:20'"))`.
  - `testDeleteWorkout`: open the first card, `detail.menu` → `detail.delete` → confirm "Delete" → back on Log with
    one fewer card.
  - `testEditWorkoutSet`: open a card, Edit, change `detail.set.0.0.reps` to 11, Save, and verify the row shows
    "11 × 130 lb".
- [ ] **Step 4:** `scripts/ios-test.sh` → PASS. **Commit:** `feat(log): week activity strip, past workouts, workout detail with edit/delete/share`

---

### Task 4: Body tab and weigh-ins

**Files:** Create `Features/Body/BodyView.swift`, `Features/Body/AddWeighInSheet.swift`,
`Features/Body/BodyweightChart.swift`; modify `App/RootView.swift` (the Body tab uses `BodyView`); UI test
`GymRollinsUITests/BodyUITests.swift`. **Mockups:** `Body.dc.html`, `AddWeighIn.dc.html`.

Behavior and identifiers:
- **Goal card** (solid): "BODYWEIGHT GOAL", "by 31 Dec", "81 → 85 kg" (current or start → goal; the display face).
  A progress bar (`body.progress`, value = `BodyTrend.progress`, accessibility value "20 percent"). A weekly change
  line "+0.2 kg / week · on track for 20 Jan" (`body.trend`), "Need +0.3 kg / week to hit 31 Dec" when
  `requiredWeeklyKg` is set, or the empty state "No weigh-ins yet. Weigh in on the same morning each week."
  (`body.empty`). A prominent glass "Add weigh-in" button `body.addWeighIn`.
- **Range picker**: glass segmented control Week/Month/6 Months/Year (`body.range`) filters the chart.
- **BodyweightChart**: Swift Charts `LineMark` + `PointMark` of entries in the range, with a dashed `RuleMark` at the
  goal (`body.chart`). Weights are always shown in kg on the Body tab (the goal is set in kg).
- **Weigh-in list** below the chart: rows "Sat 26 Sep · 81.4 kg" with swipe-to-delete (`body.entry.<index>`),
  calling `env.body.delete` and `dataChanged()`.
- **Strength trends**: the "EST. 1RM" card for the 3 most-logged exercises (count via `recent(limit: 200)`). Each row
  shows the name, the latest e1RM in kg and an up/down arrow versus the session before (`body.lift.<exerciseId>`).
  Tapping pushes `ExerciseHistoryView` (plan 03).
- **AddWeighInSheet** (glass sheet): big number field `weighin.value` (decimal pad, kg, default = latest or profile
  start 81.0), glass −/+ circles `weighin.minus`/`weighin.plus` (±0.1 kg), a `DatePicker` defaulting to
  `env.now()`, an optional body-fat field `weighin.bodyFat`, a "Morning" toggle stored as `timeOfDay = "morning"`, a
  disabled "Also save to Apple Health" row captioned "Coming later", and "Save" `weighin.save`. Validation: 30–300
  kg, body fat 3–60%. Invalid input shows an inline message and doesn't save.

- [ ] **Step 1: UI test** `BodyUITests.swift`:
  - `testEmptyStateThenAddWeighIn`: launch `-uiTesting -fixedNow 2026-09-26T09:00:00Z` (no history seed), tap Body,
    and `body.empty` exists. Tap `body.addWeighIn`, set `weighin.value` to "81.4", tap `weighin.save`. `body.empty`
    is gone and a `body.entry.0` containing "81.4 kg" exists.
  - `testInvalidWeighInRejected`: enter "900" and save; the sheet stays and the text "Enter a weight between 30 and
    300 kg" exists.
- [ ] **Step 2:** Implement the views.
- [ ] **Step 3:** `scripts/ios-test.sh` → PASS. Screenshots of Log, detail, Body (empty and with 5 entries) to
  `docs/screenshots/plan-04/`. **Commit:** `feat(body): goal progress, weigh-ins, bodyweight chart, strength trends`

---

### Task 5: Verify, review, merge

- [ ] `scripts/test-all.sh` green; `swiftlint lint --quiet` has 0 errors.
- [ ] `codex review --base main > <scratch>/codex-plan04.txt`; fix P0–P2 findings test-first.
- [ ] Merge to `main` with `--no-ff`, then delete the branch.
