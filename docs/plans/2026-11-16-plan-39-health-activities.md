# Plan 39: Apple Health activities Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring two things from Apple Health into GymRollins, the cloud and the agents: workouts that other apps saved ("outside workouts": walks, runs, rides, Fitness+ and Strava sessions), and each day's steps, move kcal, exercise minutes and stand hours. Outside workouts of 10 minutes or more count toward the streak and the weekly goal. The contract is the approved spec `docs/specs/2026-11-16-health-activities-design.md`.

**Architecture:**
- **GymCore** gets two value types, `HealthActivity` and `ActivityDay`. It also gets the kind slugs (`OutsideWorkoutKind`) and the pure rules 6 and 7 (`ActivityRules.resolve`). The rules decide which outside workouts attach to a GymRollins workout and which copies are one session.
- **The rules are mirrored** in `server/src/shared/activity.ts`. Both sides run the shared fixture `fixtures/activity.json`, as `fixtures/insights.json` does today.
- **GymHealth** reads through the `HealthStore` seam. It has two new reads: an anchored workout query and per-day totals. `HealthSync+Activity` imports them into two SwiftData models through `ActivityRepository`.
- **Sync:** two new kinds go through the generic table sync, `health-activities` and `activity-days`. Server migration 0013 adds their tables.
- **The rules run at read time,** never stored:
  - in the app: Log, Today, workout detail, streak and weekly goal;
  - on the server: `get_activity` and `get_training_insights`.
- **Agents** read activity behind the new profile switch `mcp_read_activity`.

**Tech Stack:**
- App: Swift 6, SwiftUI (iOS 26), SwiftData (lightweight migration), HealthKit's async query descriptors.
- Tests: Swift Testing in the packages and in `ios/GymRollinsTests`; XCUITest in `ios/GymRollinsUITests`.
- Server: Cloudflare Workers with Hono and D1 (SQLite), and Zod v4 for MCP inputs. Tests: Vitest 4 with `@cloudflare/vitest-plugin` (in-memory D1, migrated per test file).

---

## Where this plan settles what the spec leaves open

These follow from reading the code. Each is marked where it lands in the tasks.

1. **Outside workouts are keyed by account and id.** The key is `PRIMARY KEY (user_id, id)` and the sync conflict is `['user_id', 'id']`.
   - Spec §5 says "`id` primary key". But `src/sync/table-sync.ts` refuses, with 403 `not_allowed`, any row id that another account already holds.
   - One iPhone's Health can feed two accounts: sign out of one, sign in to the other, and the import runs again with the same HealthKit UUIDs. Every one of those rows would then be refused. With the account in the key, both accounts store them.
   - Two devices of one account still write the same row. (Task 10)
2. **The caps are kept in a new counter table, `health_rows`, not in `account_rows`.**
   - `server/migrations/0010_account_caps.sql` has a CHECK on `account_rows.tbl` that lists its ten tables. SQLite can't change a CHECK without rebuilding the table.
   - Rebuilding means dropping and recreating the 26 triggers that write it. While a trigger names a missing table, `ALTER TABLE … RENAME` fails.
   - So `health_rows` gets the same pattern: a BEFORE INSERT cap, AFTER INSERT/DELETE counts, and `ON DELETE CASCADE`. It is tested the same way. (Task 10)
3. **Titles come from the kind alone.** A walk is "Walk", not "Outdoor Walk", because the spec's data (§3.1) has no indoor/outdoor field. (Task 1)
4. **`get_activity` lists attached outside workouts with `during_workout_id`,** as spec §5 asks. The per-day and per-week outside totals leave them out, because each is a GymRollins session that was also measured. The app's Log doesn't list them, as spec §4 asks. (Task 13)
5. **Days are re-read from 6 days before the last read's day, through today.** That is the spec's "last 7 days" when the app opens daily. It also covers a phone left closed for longer. A day is still written only when a value changed. (Task 9)
6. **A deletion can arrive before its row.** For example, the phone is signed out and the row comes back from the cloud later. Such deletions wait in `unmatchedActivityDeletions`, as weigh-ins do with `unmatchedDeletions`. (Task 8)
7. **The reading switches and the ask.**
   - The two "Reading from Health" switches hide their data whenever they're off.
   - Nothing is read before the activity types were asked for. Turning Health on (`enable()`) asks for every type, so it counts as asked.
   - The activity anchor isn't reset on an account switch, as the weigh-in anchor isn't today. (Tasks 8, 9, 16)
8. **The profile switch on older apps.** An app from before plan 39 pushes its profile without `mcp_read_activity`, so the server stores it as on, the column's default. This is the same accepted trade-off as plan 32's `mcp_log_workouts`: a build from before this one, pushing its profile, turns a switch that was off back on. Every device the owner uses gets build 4. (Task 10)
9. **Edit times.**
   - An imported outside workout's edit time is the workout's end, as a weigh-in's is the sample's date. That way a deletion stamped later on another device wins.
   - A deletion's edit time is now.
   - A day's edit time is when it was read. (Tasks 4, 8)
10. **Rule order and ties.**
    - Rule 6 runs first, for each outside workout. With several GymRollins workouts, the largest overlap wins.
    - Rule 7 then runs on the rest. The copy kept is the Apple Watch's, then the longer, then the earlier, then the lower id.
    - Ids compare lowercased on both sides, as D1 stores them. (Task 3)
11. **Stand hours are nil when the day's Activity summary has no stand goal.** That is the case with no Apple Watch. (Task 7)
12. **`get_activity` takes `time_zone` besides `days`.** It is optional and defaults to UTC, like `get_training_insights`. Days and weeks need one. (Task 13)
13. **When Health is on but the activity types were never asked for, nothing is read,** as the spec requires. On iOS, querying a type that was never asked for errors or answers nothing. (Task 8)
14. **Deploy order: the migration, then the Worker, then the phone.** The new profile entity writes `mcp_read_activity`. A Worker deployed before migration 0013 would fail every profile push. ("Owner steps")

## Rules for implementers

- **Commits:** use conventional messages with no attribution lines: no Co-Authored-By, no "Generated with", no Claude-Session.
- **Leave alone:**
  - don't run `scripts/test-db.sh`;
  - don't deploy or run remote D1 commands (`wrangler … --remote`);
  - don't print or edit `server/.dev.vars` or `ios/Config/Local.xcconfig`;
  - don't use `rm -rf`;
  - the owner does the steps under "Owner steps".
- **The repo is public:** examples and fixtures use made-up data only. That means no names, no real account ids and no `/Users/` paths.
- **Match the surrounding code:**
  - doc comments that say why;
  - small files and value types;
  - `Logger` for errors, never `print`, and no silently swallowed errors;
  - the `// MARK:` style of each file.
- **Test first:** each task's first step is a failing test.
- **Running tests** (from the repo root):
  - A package: `swift test --package-path ios/Packages/<Package> --filter '<Suite>'`. A filter with `|` must be quoted in zsh.
  - App unit tests: `scripts/ios-test.sh -only-testing:GymRollinsTests/<Suite>`. UI tests: `scripts/ios-test.sh -only-testing:GymRollinsUITests/<Class>/<test>`. The script regenerates the Xcode project, so new files are picked up, and writes `ios/build/TestResults-<time>.xcresult`.
  - To read the latest app result: `R=$(ls -td ios/build/TestResults-*.xcresult | head -1); xcrun xcresulttool get test-results summary --path "$R" | grep -E '"(result|passedTests|failedTests|skippedTests)"'`
  - The server: `cd server && npx vitest run test/<file>`, plus `npx tsc --noEmit`. Vitest runs a local in-memory D1 and touches no remote.
- **UI tests** launch with `-uiTesting -fixedNow 2026-09-26T09:00:00Z`, a Saturday.
  - `-fakeHealth` gives an in-memory Health store. From Task 16 it also has:
    - yesterday's Apple Watch walk (Fri 25 Sep, 07:00 UTC, 45 min, 180 kcal);
    - an Apple Watch strength recording during `-seedHistory`'s workout of Sat 19 Sep (18:02–18:55 UTC, 412 kcal);
    - seven days of steps, today's being 4,210.
  - `-healthBeforeActivity` starts with Health on, as a build from before this plan left it.

## File structure

New, iOS packages:
- `ios/Packages/GymCore/Sources/GymCore/Activity/HealthActivity.swift`: the outside workout value and the 10-minute floor.
- `ios/Packages/GymCore/Sources/GymCore/Activity/ActivityDay.swift`: a day of activity and its `YYYY-MM-DD` key.
- `ios/Packages/GymCore/Sources/GymCore/Activity/OutsideWorkoutKind.swift`: the kind slugs, titles and SF Symbols.
- `ios/Packages/GymCore/Sources/GymCore/Activity/ActivityRules.swift`: `WorkoutSpan`, `ResolvedActivities`, and rules 6 and 7.
- `fixtures/activity.json`: the cases GymCore and the server both run.
- `ios/Packages/GymData/Sources/GymData/Records/ActivityRecords.swift`: the `HealthActivityRecord` and `ActivityDayRecord` SwiftData models.
- `ios/Packages/GymData/Sources/GymData/Repositories/ActivityRepository.swift`: reads for the app, writes for the import.
- `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+Activity.swift`: dirty rows out, pulled rows in.
- `ios/Packages/GymSync/Sources/GymSync/DTO/HealthActivityDTO.swift` and `DTO/ActivityDayDTO.swift`: the wire rows.
- `ios/Packages/GymHealth/Sources/GymHealth/HealthSync+Activity.swift`: the import, the ask and the two switches.

New, app:
- `ios/GymRollins/App/AppEnvironment+Activity.swift`:
  - resolved outside workouts and the starts that count;
  - the measured recording for a GymRollins workout;
  - the last 7 days;
  - the switches and the ask.
- `ios/GymRollins/Features/Activity/ActivityText.swift`: every string the activity screens show.
- `ios/GymRollins/Features/Activity/TodayActivitySection.swift`: Today's card and Activity row.
- `ios/GymRollins/Features/Activity/ActivityPermissionCard.swift`: "Bring in your Apple Watch activity".
- `ios/GymRollins/Features/Activity/ActivityWeekSheet.swift`: the last 7 days.
- `ios/GymRollins/Features/Activity/OutsideWorkoutCard.swift`: the Log card and its navigation value `OutsideWorkoutLink`.
- `ios/GymRollins/Features/Activity/OutsideWorkoutDetailView.swift`: the read-only detail.
- `ios/GymRollins/Features/Log/LogTimeline.swift`: GymRollins workouts and outside workouts in one history.

New, server:
- `server/migrations/0013_health_activities.sql`: the two tables, their pull indexes, the caps in `health_rows`, and `profiles.mcp_read_activity`.
- `server/src/shared/activity.ts`: the TypeScript mirror of rules 6 and 7.
- `server/src/mcp/tools/activity.ts`: `get_activity`.

New tests:
- GymCore, in `ios/Packages/GymCore/Tests/GymCoreTests/Activity/`: `ActivityValuesTests.swift`, `ActivityLimitsTests.swift`, `ActivityRulesTests.swift`, `ActivityFixtureTests.swift`.
- GymData, in `ios/Packages/GymData/Tests/GymDataTests/`: `ActivityRepositoryTests.swift`, `SyncStoreActivityTests.swift`, `ProfileReadActivityTests.swift`.
- GymSync, in `ios/Packages/GymSync/Tests/GymSyncTests/`: `ActivitySyncTests.swift`, `ActivityTransportTests.swift`, `ProfileReadActivityDTOTests.swift`.
- GymHealth, in `ios/Packages/GymHealth/Tests/GymHealthTests/`: `HealthActivityStateTests.swift`, `FakeActivityStoreTests.swift`, `HealthActivityImportTests.swift`, `HealthActivityDaysTests.swift`.
- App, in `ios/GymRollinsTests/`: `SyncStatusTextActivityTests.swift`, `HealthKitKindTests.swift`, `HealthActivityEnvironmentTests.swift`, `ActivityTextTests.swift`, `LogTimelineTests.swift`, `ActivityStreakTests.swift`.
- UI: `ios/GymRollinsUITests/HealthActivityUITests.swift`.
- Server: `server/test/shared/activity.test.ts`, `server/test/sync-activity.test.ts`, `server/test/health-rows.test.ts`, `server/test/mcp/tools/activity.test.ts`.

Modified:
- GymCore: `DomainLimits.swift`.
- GymData:
  - `Store/GymStore.swift`;
  - `Repositories/WorkoutRepository+Insights.swift` (`finishedSpans`);
  - `Insights/WeekActivity.swift` (`outsideMinutes`);
  - `Sync/SyncModels.swift` (two `SyncEntity` cases and `ProfileSnapshot.mcpReadActivity`);
  - `Sync/SyncStore.swift`;
  - `Sync/SyncStore+Ownership.swift`;
  - `Sync/SyncStore+ServerMove.swift`;
  - `Sync/SyncStore+Profile.swift`;
  - `Values/Profile.swift`;
  - `Records/ProfileRecord.swift`;
  - `Repositories/ProfileRepository.swift`.
- GymSync:
  - `SyncTransport.swift`, `ApiSyncTransport.swift`, `SyncEngine+Rounds.swift` and `DTO/ProfileDTO.swift`;
  - the tests' `FakeTransport.swift`.
- GymHealth:
  - `HealthStore.swift`, `HealthKitStore.swift`, `FakeHealthStore.swift`, `HealthSyncState.swift` and `HealthSync.swift`;
  - `Tests/GymHealthTests/HealthSyncTests.swift` (`HealthFixture`).
- App:
  - `App/AppEnvironment.swift`, `App/AppEnvironment+Health.swift`, `App/AppEnvironment+Claude.swift`, `App/LaunchOptions.swift`;
  - `App/SyncCoordinator.swift` and `App/DebugSyncSupport.swift`;
  - `Features/Sync/SyncStatusText.swift`;
  - `Features/Settings/AppleHealthSettingsView.swift` and `Features/Settings/SettingsPreferences.swift`;
  - `Features/Onboarding/ProfileSetupView.swift`;
  - `Features/Claude/ClaudeConnectionView.swift` and `Features/Claude/ClaudePrompts.swift`;
  - `Features/Today/TodayView.swift`;
  - `Features/Log/LogView.swift` and `Features/Log/WorkoutDetailView.swift`;
  - `Features/Insights/AppEnvironment+Insights.swift` and `Features/Insights/StreakViews.swift`;
  - `ios/project.yml` and `ios/GymRollins/Info.plist`: the purpose string, and build 4 in Task 22.
- App tests:
  - `ios/GymRollinsTests/ClaudeEnvironmentTests.swift`, `SignOutAndDisconnectTests.swift`, `ClaudePromptsTests.swift`;
  - `ios/GymRollinsUITests/AgentsUITests.swift`;
  - `ios/Packages/GymData/Tests/GymDataTests/WeekActivityTests.swift`.
- Server:
  - `src/sync/entities.ts` and `src/sync/caps.ts`;
  - `src/shared/domain-limits.ts` and `src/shared/insights.ts` (`civilDay` exported);
  - `src/mcp/db.ts`, `src/mcp/d1-db.ts` and `src/mcp/instructions.ts`;
  - `src/mcp/tools/permissions.ts`, `read.ts`, `insights.ts`, `schemas.ts` and `register.ts`.
- Server tests:
  - `test/samples.ts`, `test/cap-fixtures.ts`, `test/account.test.ts`, `test/account-caps.test.ts`, `test/domain-limits-drift.test.ts` and `test/schema.test.ts`;
  - `test/mcp/fake-db.ts`, `test/mcp/d1-db.test.ts`, `test/mcp/app.test.ts`, `test/mcp/instructions.test.ts` and `test/mcp/agent-wording.test.ts`;
  - `test/mcp/tools/permissions.test.ts`, `read.test.ts` and `insights.test.ts`.
- Docs: `docs/release-readiness.md`, and this plan's outcome.

---

## Phase A: GymCore

### Task 1: An outside workout, a day of activity, and their kinds

**Files:**
- Create: `ios/Packages/GymCore/Sources/GymCore/Activity/HealthActivity.swift`
- Create: `ios/Packages/GymCore/Sources/GymCore/Activity/ActivityDay.swift`
- Create: `ios/Packages/GymCore/Sources/GymCore/Activity/OutsideWorkoutKind.swift`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/Activity/ActivityValuesTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/Packages/GymCore/Tests/GymCoreTests/Activity/ActivityValuesTests.swift`:

```swift
import Foundation
import Testing
@testable import GymCore

/// Plan 39: what an outside workout and a day of activity are, and how a kind slug reads.
@Suite struct ActivityValuesTests {
    private let start = ISO8601DateFormatter().date(from: "2026-09-25T07:00:00Z")!

    @Test func anOutsideWorkoutKnowsItsMinutesAndWhetherItCounts() {
        let walk = HealthActivity(id: UUID(), kind: "walking", startedAt: start,
                                  endedAt: start.addingTimeInterval(2_700), durationS: 2_700, sourceName: "Apple Watch",
                                  fromWatch: true)
        #expect(walk.minutes == 45)
        #expect(walk.countsAsWorkout)
        let paused = HealthActivity(id: UUID(), kind: "cooldown", startedAt: start,
                                    endedAt: start.addingTimeInterval(900), durationS: 599, sourceName: "Apple Watch")
        #expect(paused.minutes == 9)
        #expect(!paused.countsAsWorkout, "under 10 minutes of active time, whatever the span")
        #expect(!paused.fromWatch)
        #expect(paused.kcal == nil && paused.distanceM == nil && paused.avgHr == nil && paused.maxHr == nil)
    }

    @Test func aDayIsKeyedByItsLocalCalendarDay() throws {
        var warsaw = Calendar(identifier: .gregorian)
        warsaw.timeZone = try #require(TimeZone(identifier: "Europe/Warsaw"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let lateEvening = try #require(ISO8601DateFormatter().date(from: "2026-09-25T22:30:00Z")) // 00:30 in Warsaw
        #expect(ActivityDay.key(for: lateEvening, calendar: warsaw) == "2026-09-26")
        #expect(ActivityDay.key(for: lateEvening, calendar: utc) == "2026-09-25")

        let day = ActivityDay(day: "2026-09-26", steps: 4_210, moveKcal: 210, exerciseMin: 18, standH: nil)
        #expect(day.id == "2026-09-26")
        #expect(day.date(calendar: warsaw).map { ActivityDay.key(for: $0, calendar: warsaw) } == "2026-09-26")
        let notADay = ActivityDay(day: "2026-02-30", steps: 0, moveKcal: 0, exerciseMin: 0, standH: nil)
        #expect(notADay.date(calendar: utc) == nil)
    }

    @Test(arguments: [
        ("walking", "Walk", "figure.walk"), ("running", "Run", "figure.run"),
        ("traditional_strength", "Traditional Strength Training", "figure.strengthtraining.traditional"),
        ("hiit", "HIIT", "figure.highintensity.intervaltraining"), ("other", "Workout", "figure.mixed.cardio"),
    ])
    func aKnownSlugHasItsTitleAndSymbol(slug: String, title: String, symbol: String) {
        let kind = OutsideWorkoutKind(slug: slug)
        #expect(kind.rawValue == slug)
        #expect(kind.title == title)
        #expect(kind.symbol == symbol)
    }

    @Test func anUnknownSlugReadsAsOtherAndEverySlugFitsTheLimit() {
        #expect(OutsideWorkoutKind(slug: "underwater_hockey") == .other)
        #expect(OutsideWorkoutKind(slug: "") == .other)
        #expect(OutsideWorkoutKind.allCases.allSatisfy { (1...100).contains($0.rawValue.count) })
        #expect(Set(OutsideWorkoutKind.allCases.map(\.title)).count == OutsideWorkoutKind.allCases.count)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path ios/Packages/GymCore --filter ActivityValuesTests`
Expected: the build fails with `cannot find 'HealthActivity' in scope`, and the same for `ActivityDay` and `OutsideWorkoutKind`.

- [ ] **Step 3: Write the values**

Create `ios/Packages/GymCore/Sources/GymCore/Activity/HealthActivity.swift`:

```swift
import Foundation

/// A workout another app saved to Apple Health (plan 39): a walk, run, ride or class that the Apple Watch's Workout
/// app, Strava or Fitness+ recorded. Read-only in GymRollins, and never a `Workout`: it stays out of PRs, strength
/// summaries, `log_workout`'s overlap check and the workout cap. `id` is the HealthKit workout's UUID, so two devices
/// importing the same workout write the same row. A deletion lives on the record and the sync row, not here.
public struct HealthActivity: Codable, Sendable, Equatable, Identifiable {
    /// Active time this long or longer counts toward the streak and the weekly goal (decision 5).
    public static let countingMinimum: TimeInterval = 600

    public let id: UUID
    /// An `OutsideWorkoutKind` slug, kept as text so a kind a newer app knows survives an older one.
    public let kind: String
    public let startedAt: Date
    public let endedAt: Date
    /// HealthKit's duration: pauses excluded.
    public let durationS: Double
    /// The workout's active energy statistic.
    public let kcal: Double?
    /// Walking/running, cycling or swimming distance, whichever the workout has.
    public let distanceM: Double?
    public let avgHr: Int?
    public let maxHr: Int?
    /// The source as Health shows it ("Apple Watch", "Strava").
    public let sourceName: String
    /// Recorded on an Apple Watch: the copy kept when two apps saved one session (rule 7).
    public let fromWatch: Bool

    public init(id: UUID, kind: String, startedAt: Date, endedAt: Date, durationS: Double, kcal: Double? = nil,
                distanceM: Double? = nil, avgHr: Int? = nil, maxHr: Int? = nil, sourceName: String,
                fromWatch: Bool = false) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationS = durationS
        self.kcal = kcal
        self.distanceM = distanceM
        self.avgHr = avgHr
        self.maxHr = maxHr
        self.sourceName = sourceName
        self.fromWatch = fromWatch
    }

    /// Whole minutes of active time.
    public var minutes: Int { Int(max(0, durationS) / 60) }

    /// Long enough to count toward the streak and the weekly goal, when it isn't attached to a GymRollins workout.
    public var countsAsWorkout: Bool { durationS >= Self.countingMinimum }
}
```

Create `ios/Packages/GymCore/Sources/GymCore/Activity/ActivityDay.swift`:

```swift
import Foundation

/// One local calendar day of Apple Health activity (plan 39): steps from Health's merged statistics, and move, exercise
/// and stand from the day's Activity summary, never summed from raw samples (those double count iPhone + Watch). A day
/// with no data at all isn't stored.
public struct ActivityDay: Codable, Sendable, Equatable, Identifiable {
    /// `YYYY-MM-DD` in the calendar the day was recorded in.
    public let day: String
    public let steps: Int
    public let moveKcal: Double
    public let exerciseMin: Int
    /// Nil without an Apple Watch (no stand goal).
    public let standH: Int?

    public var id: String { day }

    public init(day: String, steps: Int, moveKcal: Double, exerciseMin: Int, standH: Int?) {
        self.day = day
        self.steps = steps
        self.moveKcal = moveKcal
        self.exerciseMin = exerciseMin
        self.standH = standH
    }

    /// `date`'s day in `calendar`, as `YYYY-MM-DD`.
    public static func key(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The start of this day in `calendar`; nil for a key that isn't a real day.
    public func date(calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              Self.key(for: date, calendar: calendar) == day else { return nil }
        return date
    }
}
```

Create `ios/Packages/GymCore/Sources/GymCore/Activity/OutsideWorkoutKind.swift`. `HealthKitStore` maps HealthKit's workout types onto these cases in Task 7, and Task 18 checks that every symbol exists in the iOS SDK:

```swift
/// The kinds of outside workout GymRollins names (plan 39). The slug is what's stored and synced; `HealthKitStore`
/// maps each `HKWorkoutActivityType` to one, and any other type is `other`.
public enum OutsideWorkoutKind: String, CaseIterable, Sendable {
    case walking, running, cycling, hiit, yoga, swimming
    case traditionalStrength = "traditional_strength", functionalStrength = "functional_strength"
    case elliptical, rowing, hiking, dance, core, pilates, cooldown, stairs
    case jumpRope = "jump_rope", mixedCardio = "mixed_cardio", crossTraining = "cross_training"
    case flexibility, mindAndBody = "mind_and_body", tennis, soccer, basketball, boxing, kickboxing
    case martialArts = "martial_arts", climbing, skiing, snowboarding, golf, other

    /// The kind a stored slug names; `other` for one this version doesn't know.
    public init(slug: String) {
        self = Self(rawValue: slug) ?? .other
    }

    public var title: String {
        switch self {
        case .walking: "Walk"
        case .running: "Run"
        case .cycling: "Cycling"
        case .hiit: "HIIT"
        case .yoga: "Yoga"
        case .swimming: "Swim"
        case .traditionalStrength: "Traditional Strength Training"
        case .functionalStrength: "Functional Strength Training"
        case .elliptical: "Elliptical"
        case .rowing: "Rowing"
        case .hiking: "Hike"
        case .dance: "Dance"
        case .core: "Core Training"
        case .pilates: "Pilates"
        case .cooldown: "Cooldown"
        case .stairs: "Stair Stepper"
        case .jumpRope: "Jump Rope"
        case .mixedCardio: "Mixed Cardio"
        case .crossTraining: "Cross Training"
        case .flexibility: "Flexibility"
        case .mindAndBody: "Mind and Body"
        case .tennis: "Tennis"
        case .soccer: "Soccer"
        case .basketball: "Basketball"
        case .boxing: "Boxing"
        case .kickboxing: "Kickboxing"
        case .martialArts: "Martial Arts"
        case .climbing: "Climbing"
        case .skiing: "Skiing"
        case .snowboarding: "Snowboarding"
        case .golf: "Golf"
        case .other: "Workout"
        }
    }

    /// The SF Symbol shown beside it.
    public var symbol: String {
        switch self {
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .cycling: "figure.outdoor.cycle"
        case .hiit: "figure.highintensity.intervaltraining"
        case .yoga: "figure.yoga"
        case .swimming: "figure.pool.swim"
        case .traditionalStrength: "figure.strengthtraining.traditional"
        case .functionalStrength: "figure.strengthtraining.functional"
        case .elliptical: "figure.elliptical"
        case .rowing: "figure.rower"
        case .hiking: "figure.hiking"
        case .dance: "figure.dance"
        case .core: "figure.core.training"
        case .pilates: "figure.pilates"
        case .cooldown: "figure.cooldown"
        case .stairs: "figure.stair.stepper"
        case .jumpRope: "figure.jumprope"
        case .mixedCardio, .other: "figure.mixed.cardio"
        case .crossTraining: "figure.cross.training"
        case .flexibility: "figure.flexibility"
        case .mindAndBody: "figure.mind.and.body"
        case .tennis: "figure.tennis"
        case .soccer: "figure.soccer"
        case .basketball: "figure.basketball"
        case .boxing: "figure.boxing"
        case .kickboxing: "figure.kickboxing"
        case .martialArts: "figure.martial.arts"
        case .climbing: "figure.climbing"
        case .skiing: "figure.skiing.downhill"
        case .snowboarding: "figure.snowboarding"
        case .golf: "figure.golf"
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path ios/Packages/GymCore --filter ActivityValuesTests`
Expected: 4 tests pass, one of them with 5 arguments.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/GymCore/Sources/GymCore/Activity ios/Packages/GymCore/Tests/GymCoreTests/Activity/ActivityValuesTests.swift
git commit -m "feat(core): outside workouts, days of activity and their kinds"
```

---

### Task 2: Limits for outside workouts and days, mirrored on the server

**Files:**
- Modify: `ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift`
- Modify: `server/src/shared/domain-limits.ts`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/Activity/ActivityLimitsTests.swift`
- Test (existing, unchanged here): `server/test/domain-limits-drift.test.ts`

- [ ] **Step 1: Write the failing tests**

Create `ios/Packages/GymCore/Tests/GymCoreTests/Activity/ActivityLimitsTests.swift`:

```swift
import Foundation
import Testing
@testable import GymCore

/// Plan 39: the limits an outside workout or a day must fit (server/migrations/0013_health_activities.sql CHECKs the
/// same numbers). The import skips one that doesn't fit; nothing is clamped.
@Suite struct ActivityLimitsTests {
    private let start = ISO8601DateFormatter().date(from: "2026-09-25T07:00:00Z")!

    private func walk(kind: String = "walking", minutes: Double = 45, durationS: Double? = nil, kcal: Double? = 180,
                      distanceM: Double? = 3_400, avgHr: Int? = 102, maxHr: Int? = 121,
                      source: String = "Apple Watch") -> HealthActivity {
        HealthActivity(id: UUID(), kind: kind, startedAt: start, endedAt: start.addingTimeInterval(minutes * 60),
                       durationS: durationS ?? minutes * 60, kcal: kcal, distanceM: distanceM, avgHr: avgHr,
                       maxHr: maxHr, sourceName: source, fromWatch: true)
    }

    @Test func aWalkFits() {
        #expect(DomainLimits.healthActivityViolation(walk()) == nil)
        #expect(DomainLimits.healthActivityViolation(walk(kcal: nil, distanceM: nil, avgHr: nil, maxHr: nil)) == nil)
    }

    @Test func anOutsideWorkoutOutsideALimitIsRefused() {
        #expect(DomainLimits.healthActivityViolation(walk(kind: "")) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(source: String(repeating: "s", count: 101))) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(minutes: -1)) != nil, "ends before it starts")
        #expect(DomainLimits.healthActivityViolation(walk(minutes: 1_500, durationS: 90_000)) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(durationS: .nan)) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(kcal: 20_001)) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(distanceM: 1_000_001)) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(avgHr: 19)) != nil)
        #expect(DomainLimits.healthActivityViolation(walk(maxHr: 251)) != nil)
    }

    @Test func aDayFitsUnlessAValueIsOutOfRange() {
        let day = ActivityDay(day: "2026-09-26", steps: 4_210, moveKcal: 210, exerciseMin: 18, standH: nil)
        #expect(DomainLimits.activityDayViolation(day) == nil)
        let tooMany = ActivityDay(day: "2026-09-26", steps: 200_001, moveKcal: 210, exerciseMin: 18, standH: 6)
        #expect(DomainLimits.activityDayViolation(tooMany) != nil)
        let longDay = ActivityDay(day: "2026-09-26", steps: 0, moveKcal: 0, exerciseMin: 1_441, standH: nil)
        #expect(DomainLimits.activityDayViolation(longDay) != nil)
        let standing = ActivityDay(day: "2026-09-26", steps: 0, moveKcal: 0, exerciseMin: 0, standH: 25)
        #expect(DomainLimits.activityDayViolation(standing) != nil)
        let burning = ActivityDay(day: "2026-09-26", steps: 0, moveKcal: 20_001, exerciseMin: 0, standH: nil)
        #expect(DomainLimits.activityDayViolation(burning) != nil)
    }

    @Test func theCapsAreTheSpecsNumbers() {
        #expect(DomainLimits.healthActivitiesMax == 20_000)
        #expect(DomainLimits.activityDaysMax == 5_000)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path ios/Packages/GymCore --filter ActivityLimitsTests`
Expected: the build fails with `type 'DomainLimits' has no member 'healthActivityViolation'`.

- [ ] **Step 3: Add the limits to `DomainLimits`**

In `ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift`, after `public static let gymActiveListingsMax = 300`, add:

```swift
    // Apple Health activities: outside workouts and days of activity (server/migrations/0013_health_activities.sql)
    public static let activityDurationS: ClosedRange<Double> = 0...86_400
    public static let activityKcal: ClosedRange<Double> = 0...20_000
    public static let activityDistanceM: ClosedRange<Double> = 0...1_000_000
    public static let heartRateBpm: ClosedRange<Int> = 20...250
    public static let daySteps: ClosedRange<Int> = 0...200_000
    public static let dayExerciseMin: ClosedRange<Int> = 0...1_440
    public static let dayStandH: ClosedRange<Int> = 0...24
    /// An outside workout's kind slug and source name.
    public static let activityTextMax = 100
```

After `public static let privateListingsTotalMax = 5_000`, add:

```swift
    // Kept in health_rows, not account_rows (server/migrations/0013_health_activities.sql)
    public static let healthActivitiesMax = 20_000
    public static let activityDaysMax = 5_000
```

Before `// swiftlint:disable:next function_parameter_count` (above `profileViolation`), add:

```swift
    /// Why an outside workout read from Health can't be stored, or nil. One that doesn't fit is skipped on import, never
    /// clamped.
    public static func healthActivityViolation(_ a: HealthActivity) -> String? {
        if !(1...activityTextMax).contains(a.kind.count) { return "Kind must be 1–\(activityTextMax) characters." }
        if !(1...activityTextMax).contains(a.sourceName.count) {
            return "Source names can be 1–\(activityTextMax) characters."
        }
        if a.endedAt < a.startedAt { return "A workout can't end before it starts." }
        if !activityDurationS.contains(a.durationS) { return "Duration must be 0–24 hours." }
        if let kcal = a.kcal, !activityKcal.contains(kcal) { return "Calories must be 0–20,000 kcal." }
        if let distance = a.distanceM, !activityDistanceM.contains(distance) { return "Distance must be 0–1,000 km." }
        if [a.avgHr, a.maxHr].contains(where: { $0.map { !heartRateBpm.contains($0) } ?? false }) {
            return "Heart rate must be 20–250 bpm."
        }
        return nil
    }

    /// Why a day of activity can't be stored, or nil. Like an outside workout, one that doesn't fit is skipped.
    public static func activityDayViolation(_ d: ActivityDay) -> String? {
        if !daySteps.contains(d.steps) { return "Steps must be 0–200,000." }
        if !activityKcal.contains(d.moveKcal) { return "Move must be 0–20,000 kcal." }
        if !dayExerciseMin.contains(d.exerciseMin) { return "Exercise must be 0–1,440 minutes." }
        if let stand = d.standH, !dayStandH.contains(stand) { return "Stand must be 0–24 hours." }
        return nil
    }
```

- [ ] **Step 4: Run the Swift tests**

Run: `swift test --package-path ios/Packages/GymCore --filter 'ActivityLimitsTests|DomainLimitsTests'`
Expected: all pass.

- [ ] **Step 5: See the drift test fail**

Run: `cd server && npx vitest run test/domain-limits-drift.test.ts`
Expected: FAIL in "has every Swift limit in the server, with the same value, and no others". The Swift side now has `activityDurationS`, `activityKcal`, `activityDistanceM`, `heartRateBpm`, `daySteps`, `dayExerciseMin`, `dayStandH`, `activityTextMax`, `healthActivitiesMax` and `activityDaysMax`, and the server doesn't.

- [ ] **Step 6: Mirror them on the server**

In `server/src/shared/domain-limits.ts`, after `gymActiveListingsMax: 300,`, add:

```ts
  // Apple Health activities: outside workouts and days of activity (migrations/0013_health_activities.sql)
  activityDurationS: { min: 0, max: 86_400 },
  activityKcal: { min: 0, max: 20_000 },
  activityDistanceM: { min: 0, max: 1_000_000 },
  heartRateBpm: { min: 20, max: 250 },
  daySteps: { min: 0, max: 200_000 },
  dayExerciseMin: { min: 0, max: 1_440 },
  dayStandH: { min: 0, max: 24 },
  activityTextMax: 100,
```

After `privateListingsTotalMax: 5_000,`, add:

```ts
  // Kept in health_rows, not account_rows (migrations/0013_health_activities.sql)
  healthActivitiesMax: 20_000,
  activityDaysMax: 5_000,
```

- [ ] **Step 7: Run the drift test and the type check**

Run: `cd server && npx vitest run test/domain-limits-drift.test.ts && npx tsc --noEmit`
Expected: PASS. The CHECKs that enforce these limits come with migration 0013 in Task 10, which also adds them to this test.

- [ ] **Step 8: Commit**

```bash
git add ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift ios/Packages/GymCore/Tests/GymCoreTests/Activity/ActivityLimitsTests.swift server/src/shared/domain-limits.ts
git commit -m "feat(core): limits for outside workouts and days of activity, mirrored on the server"
```

---

### Task 3: Rules 6 and 7 and the streak, on a fixture the server shares

**Files:**
- Create: `ios/Packages/GymCore/Sources/GymCore/Activity/ActivityRules.swift`
- Create: `fixtures/activity.json`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/Activity/ActivityRulesTests.swift`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/Activity/ActivityFixtureTests.swift`

The fixture covers:
- a walk on its own day;
- a 5-minute cooldown, which is shown but doesn't count;
- Apple's strength recording during a GymRollins workout, which attaches;
- a Strava copy of an Apple Watch run, kept once;
- same-kind sessions under 80% overlap, kept twice;
- the longer copy kept when neither is the Watch's;
- a paused 9-minute HIIT, which doesn't count;
- the larger of two overlaps winning the attachment;
- exactly half of the shorter attaching, and a minute less not;
- the week computed in Europe/Warsaw.

`StreakCalculator` itself doesn't change: its input becomes the GymRollins workouts' starts plus the counted outside workouts' starts.

- [ ] **Step 1: Write the fixture and the failing tests**

Create `fixtures/activity.json`. The data is made up, and the expectations were worked by hand from the rules:

```json
{
 "_comment": "Shared by GymCore (ActivityFixtureTests.swift) and the MCP server (server/test/shared/activity.test.ts): the same outside workouts and GymRollins workouts must give the same shown list (newest first), attachments (outside workout id -> GymRollins workout id), counted outside workouts and streak on both sides (plan 39, rules 6 and 7, decision 5). Made-up data.",
 "cases": [
  {
   "name": "a walk on its own day counts; a 5-minute cooldown is shown but doesn't",
   "now": "2026-09-26T09:00:00Z",
   "time_zone": "UTC",
   "goal": 2,
   "workouts": [
    { "id": "00000000-0000-4000-8000-0000000000f1", "started_at": "2026-09-21T17:00:00Z", "ended_at": "2026-09-21T18:00:00Z" }
   ],
   "activities": [
    { "id": "00000000-0000-4000-8000-0000000000a1", "kind": "walking", "started_at": "2026-09-23T07:00:00Z", "ended_at": "2026-09-23T07:45:00Z", "duration_s": 2700, "from_watch": true },
    { "id": "00000000-0000-4000-8000-0000000000a2", "kind": "cooldown", "started_at": "2026-09-24T07:00:00Z", "ended_at": "2026-09-24T07:05:00Z", "duration_s": 300, "from_watch": true }
   ],
   "expected": {
    "shown": ["00000000-0000-4000-8000-0000000000a2", "00000000-0000-4000-8000-0000000000a1"],
    "attached": {},
    "counted": ["00000000-0000-4000-8000-0000000000a1"],
    "streak": { "current": 1, "longest": 1, "this_week_days": 2, "this_week_met": true }
   }
  },
  {
   "name": "Apple's strength recording during a GymRollins workout is attached and adds no day",
   "now": "2026-09-26T09:00:00Z",
   "time_zone": "UTC",
   "goal": 2,
   "workouts": [
    { "id": "00000000-0000-4000-8000-0000000000f1", "started_at": "2026-09-22T17:00:00Z", "ended_at": "2026-09-22T18:00:00Z" }
   ],
   "activities": [
    { "id": "00000000-0000-4000-8000-0000000000a1", "kind": "traditional_strength", "started_at": "2026-09-22T17:05:00Z", "ended_at": "2026-09-22T17:55:00Z", "duration_s": 3000, "from_watch": true },
    { "id": "00000000-0000-4000-8000-0000000000a2", "kind": "walking", "started_at": "2026-09-22T18:30:00Z", "ended_at": "2026-09-22T19:10:00Z", "duration_s": 2400, "from_watch": true },
    { "id": "00000000-0000-4000-8000-0000000000a3", "kind": "functional_strength", "started_at": "2026-09-22T17:40:00Z", "ended_at": "2026-09-22T18:40:00Z", "duration_s": 3600, "from_watch": false }
   ],
   "expected": {
    "shown": ["00000000-0000-4000-8000-0000000000a2", "00000000-0000-4000-8000-0000000000a3"],
    "attached": { "00000000-0000-4000-8000-0000000000a1": "00000000-0000-4000-8000-0000000000f1" },
    "counted": ["00000000-0000-4000-8000-0000000000a2", "00000000-0000-4000-8000-0000000000a3"],
    "streak": { "current": 0, "longest": 0, "this_week_days": 1, "this_week_met": false }
   }
  },
  {
   "name": "a Strava copy of a Watch run is one session, and the week is the owner's time zone's",
   "now": "2026-09-26T09:00:00Z",
   "time_zone": "Europe/Warsaw",
   "goal": 1,
   "workouts": [],
   "activities": [
    { "id": "00000000-0000-4000-8000-0000000000a1", "kind": "running", "started_at": "2026-09-20T22:30:00Z", "ended_at": "2026-09-20T23:20:00Z", "duration_s": 3000, "from_watch": true },
    { "id": "00000000-0000-4000-8000-0000000000a2", "kind": "running", "started_at": "2026-09-20T22:31:00Z", "ended_at": "2026-09-20T23:21:00Z", "duration_s": 3000, "from_watch": false },
    { "id": "00000000-0000-4000-8000-0000000000a3", "kind": "running", "started_at": "2026-09-15T06:00:00Z", "ended_at": "2026-09-15T06:20:00Z", "duration_s": 1200, "from_watch": false }
   ],
   "expected": {
    "shown": ["00000000-0000-4000-8000-0000000000a1", "00000000-0000-4000-8000-0000000000a3"],
    "attached": {},
    "counted": ["00000000-0000-4000-8000-0000000000a1", "00000000-0000-4000-8000-0000000000a3"],
    "streak": { "current": 2, "longest": 2, "this_week_days": 1, "this_week_met": true }
   }
  },
  {
   "name": "same kind under 80% overlap stays two sessions; without a Watch copy the longer is kept",
   "now": "2026-09-26T09:00:00Z",
   "time_zone": "UTC",
   "goal": 3,
   "workouts": [],
   "activities": [
    { "id": "00000000-0000-4000-8000-0000000000a1", "kind": "cycling", "started_at": "2026-09-24T06:00:00Z", "ended_at": "2026-09-24T07:00:00Z", "duration_s": 3600, "from_watch": false },
    { "id": "00000000-0000-4000-8000-0000000000a2", "kind": "cycling", "started_at": "2026-09-24T06:00:00Z", "ended_at": "2026-09-24T06:40:00Z", "duration_s": 2400, "from_watch": false },
    { "id": "00000000-0000-4000-8000-0000000000a3", "kind": "cycling", "started_at": "2026-09-25T06:00:00Z", "ended_at": "2026-09-25T07:00:00Z", "duration_s": 3600, "from_watch": false },
    { "id": "00000000-0000-4000-8000-0000000000a4", "kind": "cycling", "started_at": "2026-09-25T06:30:00Z", "ended_at": "2026-09-25T07:30:00Z", "duration_s": 3600, "from_watch": false }
   ],
   "expected": {
    "shown": ["00000000-0000-4000-8000-0000000000a4", "00000000-0000-4000-8000-0000000000a3", "00000000-0000-4000-8000-0000000000a1"],
    "attached": {},
    "counted": ["00000000-0000-4000-8000-0000000000a4", "00000000-0000-4000-8000-0000000000a3", "00000000-0000-4000-8000-0000000000a1"],
    "streak": { "current": 0, "longest": 0, "this_week_days": 2, "this_week_met": false }
   }
  },
  {
   "name": "under 10 minutes of active time doesn't count; of two workouts the larger overlap takes the attachment",
   "now": "2026-09-26T09:00:00Z",
   "time_zone": "UTC",
   "goal": 1,
   "workouts": [
    { "id": "00000000-0000-4000-8000-0000000000f1", "started_at": "2026-09-23T10:00:00Z", "ended_at": "2026-09-23T11:00:00Z" },
    { "id": "00000000-0000-4000-8000-0000000000f2", "started_at": "2026-09-23T11:00:00Z", "ended_at": "2026-09-23T12:00:00Z" }
   ],
   "activities": [
    { "id": "00000000-0000-4000-8000-0000000000a1", "kind": "hiit", "started_at": "2026-09-25T18:00:00Z", "ended_at": "2026-09-25T18:20:00Z", "duration_s": 540, "from_watch": true },
    { "id": "00000000-0000-4000-8000-0000000000a2", "kind": "traditional_strength", "started_at": "2026-09-23T10:20:00Z", "ended_at": "2026-09-23T11:50:00Z", "duration_s": 5400, "from_watch": true }
   ],
   "expected": {
    "shown": ["00000000-0000-4000-8000-0000000000a1"],
    "attached": { "00000000-0000-4000-8000-0000000000a2": "00000000-0000-4000-8000-0000000000f2" },
    "counted": [],
    "streak": { "current": 1, "longest": 1, "this_week_days": 1, "this_week_met": true }
   }
  },
  {
   "name": "exactly half of the shorter attaches; a minute less doesn't",
   "now": "2026-09-26T09:00:00Z",
   "time_zone": "UTC",
   "goal": 7,
   "workouts": [
    { "id": "00000000-0000-4000-8000-0000000000f1", "started_at": "2026-09-24T17:00:00Z", "ended_at": "2026-09-24T18:00:00Z" }
   ],
   "activities": [
    { "id": "00000000-0000-4000-8000-0000000000a1", "kind": "walking", "started_at": "2026-09-24T17:30:00Z", "ended_at": "2026-09-24T18:30:00Z", "duration_s": 3600, "from_watch": true },
    { "id": "00000000-0000-4000-8000-0000000000a2", "kind": "walking", "started_at": "2026-09-24T17:31:00Z", "ended_at": "2026-09-24T18:31:00Z", "duration_s": 3600, "from_watch": false }
   ],
   "expected": {
    "shown": ["00000000-0000-4000-8000-0000000000a2"],
    "attached": { "00000000-0000-4000-8000-0000000000a1": "00000000-0000-4000-8000-0000000000f1" },
    "counted": ["00000000-0000-4000-8000-0000000000a2"],
    "streak": { "current": 0, "longest": 0, "this_week_days": 1, "this_week_met": false }
   }
  }
 ]
}
```

Create `ios/Packages/GymCore/Tests/GymCoreTests/Activity/ActivityFixtureTests.swift`. It loads the fixture the way `InsightsFixtureTests.swift` loads `fixtures/insights.json`:

```swift
import Foundation
import Testing
@testable import GymCore

/// Runs `fixtures/activity.json`, the cases the server's TypeScript mirror (`server/test/shared/activity.test.ts`) runs
/// too: rules 6 and 7, what counts, and the streak with outside workouts in it (plan 39).
struct ActivityFixtureTests {
    struct Doc: Decodable {
        let cases: [Case]
    }

    struct Case: Decodable {
        let name, now, timeZone: String
        let goal: Int
        let workouts: [WorkoutRow]
        let activities: [ActivityRow]
        let expected: Expected
        enum CodingKeys: String, CodingKey {
            case name, now, goal, workouts, activities, expected, timeZone = "time_zone"
        }
    }

    struct WorkoutRow: Decodable {
        let id, startedAt, endedAt: String
        enum CodingKeys: String, CodingKey { case id, startedAt = "started_at", endedAt = "ended_at" }
    }

    struct ActivityRow: Decodable {
        let id, kind, startedAt, endedAt: String
        let durationS: Double
        let fromWatch: Bool
        enum CodingKeys: String, CodingKey {
            case id, kind, startedAt = "started_at", endedAt = "ended_at", durationS = "duration_s"
            case fromWatch = "from_watch"
        }
    }

    struct Expected: Decodable {
        let shown: [String]
        let attached: [String: String]
        let counted: [String]
        let streak: StreakRow
    }

    struct StreakRow: Decodable {
        let current, longest, thisWeekDays: Int
        let thisWeekMet: Bool
        enum CodingKeys: String, CodingKey {
            case current, longest, thisWeekDays = "this_week_days", thisWeekMet = "this_week_met"
        }
    }

    static func load() throws -> Doc {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/activity.json")
        return try JSONDecoder().decode(Doc.self, from: Data(contentsOf: url))
    }

    static func date(_ iso: String) throws -> Date { try #require(ISO8601DateFormatter().date(from: iso)) }

    static func uuid(_ text: String) throws -> UUID { try #require(UUID(uuidString: text)) }

    @Test func everyCaseMatches() throws {
        let doc = try Self.load()
        #expect(doc.cases.count >= 6)
        for c in doc.cases {
            let workouts = try c.workouts.map {
                WorkoutSpan(id: try Self.uuid($0.id), start: try Self.date($0.startedAt),
                            end: try Self.date($0.endedAt))
            }
            let activities = try c.activities.map {
                HealthActivity(id: try Self.uuid($0.id), kind: $0.kind, startedAt: try Self.date($0.startedAt),
                               endedAt: try Self.date($0.endedAt), durationS: $0.durationS, sourceName: "Fixture",
                               fromWatch: $0.fromWatch)
            }
            let resolved = ActivityRules.resolve(activities, workouts: workouts)
            let ids = { (list: [HealthActivity]) in list.map { $0.id.uuidString.lowercased() } }
            #expect(ids(resolved.shown) == c.expected.shown, "\(c.name): shown")
            let attached = Dictionary(uniqueKeysWithValues: resolved.attachedTo.map {
                ($0.key.uuidString.lowercased(), $0.value.uuidString.lowercased())
            })
            #expect(attached == c.expected.attached, "\(c.name): attached")
            #expect(ids(resolved.counted) == c.expected.counted, "\(c.name): counted")

            let calendar = TrainingWeek.calendar(timeZone: try #require(TimeZone(identifier: c.timeZone)))
            let streak = StreakCalculator.compute(
                workoutDates: workouts.map(\.start) + resolved.counted.map(\.startedAt), goal: c.goal,
                now: try Self.date(c.now), calendar: calendar)
            #expect(streak.current == c.expected.streak.current, "\(c.name): current streak")
            #expect(streak.longest == c.expected.streak.longest, "\(c.name): longest streak")
            #expect(streak.thisWeekDays == c.expected.streak.thisWeekDays, "\(c.name): this week")
            #expect(streak.thisWeekMet == c.expected.streak.thisWeekMet, "\(c.name): this week met")
        }
    }
}
```

Create `ios/Packages/GymCore/Tests/GymCoreTests/Activity/ActivityRulesTests.swift`:

```swift
import Foundation
import Testing
@testable import GymCore

/// Plan 39's rules 6 and 7 beyond the shared fixture: which attached recording a GymRollins workout shows.
@Suite struct ActivityRulesTests {
    private let t0 = ISO8601DateFormatter().date(from: "2026-09-22T17:00:00Z")!

    private func activity(_ kind: String, from start: Double, minutes: Double, watch: Bool = false,
                          source: String = "Strava") -> HealthActivity {
        HealthActivity(id: UUID(), kind: kind, startedAt: t0.addingTimeInterval(start * 60),
                       endedAt: t0.addingTimeInterval((start + minutes) * 60), durationS: minutes * 60,
                       sourceName: source, fromWatch: watch)
    }

    @Test func theWatchsRecordingIsTheMeasuredOneOfASession() {
        let session = WorkoutSpan(id: UUID(), start: t0, end: t0.addingTimeInterval(3_600))
        let strava = activity("traditional_strength", from: 2, minutes: 56)
        let watch = activity("traditional_strength", from: 5, minutes: 50, watch: true, source: "Apple Watch")
        let resolved = ActivityRules.resolve([strava, watch], workouts: [session])
        #expect(resolved.shown.isEmpty)
        #expect(Set(resolved.attached(to: session.id).map(\.id)) == [strava.id, watch.id])
        #expect(resolved.measured(for: session.id) == watch)
        #expect(resolved.measured(for: UUID()) == nil)
    }

    @Test func withoutAWatchRecordingTheLongerIsMeasured() {
        let session = WorkoutSpan(id: UUID(), start: t0, end: t0.addingTimeInterval(3_600))
        let short = activity("functional_strength", from: 10, minutes: 40)
        let long = activity("functional_strength", from: 0, minutes: 58)
        #expect(ActivityRules.resolve([short, long], workouts: [session]).measured(for: session.id) == long)
    }

    @Test func aWorkoutThatSharesNoTimeAttachesNothing() {
        let instant = WorkoutSpan(id: UUID(), start: t0, end: t0)
        let walk = activity("walking", from: 0, minutes: 30)
        #expect(ActivityRules.resolve([walk], workouts: [instant]).shown == [walk])
        #expect(ResolvedActivities.none.counted.isEmpty)
        #expect(ResolvedActivities.none.attached.isEmpty)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path ios/Packages/GymCore --filter 'ActivityFixtureTests|ActivityRulesTests'`
Expected: the build fails with `cannot find 'WorkoutSpan' in scope` and `cannot find 'ActivityRules' in scope`.

- [ ] **Step 3: Write the rules**

Create `ios/Packages/GymCore/Sources/GymCore/Activity/ActivityRules.swift`:

```swift
import Foundation

/// A finished GymRollins workout's time span, for rule 6.
public struct WorkoutSpan: Sendable, Equatable {
    public let id: UUID
    public let start: Date
    public let end: Date

    public init(id: UUID, start: Date, end: Date) {
        self.id = id
        self.start = start
        self.end = end
    }
}

/// Outside workouts after rules 6 and 7 (plan 39, decisions 6–8). Computed when read and never stored: an attachment
/// can appear later (a GymRollins workout logged afterwards, an agent's `log_workout`).
public struct ResolvedActivities: Sendable, Equatable {
    /// Shown and counted on their own: not attached, one per session; newest first.
    public let shown: [HealthActivity]
    /// Attached to a GymRollins workout (the same session, measured); newest first.
    public let attached: [HealthActivity]
    /// Attached outside workout id → its GymRollins workout id.
    public let attachedTo: [UUID: UUID]

    public static let none = ResolvedActivities(shown: [], attached: [], attachedTo: [:])

    public init(shown: [HealthActivity], attached: [HealthActivity], attachedTo: [UUID: UUID]) {
        self.shown = shown
        self.attached = attached
        self.attachedTo = attachedTo
    }

    /// The ones that count toward the streak and the weekly goal (decision 5): shown, 10 minutes or more.
    public var counted: [HealthActivity] { shown.filter(\.countsAsWorkout) }

    /// The outside workouts attached to this GymRollins workout.
    public func attached(to workoutId: UUID) -> [HealthActivity] {
        attached.filter { attachedTo[$0.id] == workoutId }
    }

    /// What this GymRollins workout shows as measured: the Apple Watch's recording first, else the longest.
    public func measured(for workoutId: UUID) -> HealthActivity? {
        attached(to: workoutId).sorted(by: ActivityRules.preferred).first
    }
}

/// Rules 6 and 7 (plan 39): one pure function, mirrored by `server/src/shared/activity.ts` and run by both on the
/// shared fixture `fixtures/activity.json`. Keep the two in step by hand.
/// - Rule 6: an outside workout overlapping a GymRollins workout by at least half of the shorter of the two is
///   attached to it (the largest overlap wins).
/// - Rule 7: of the rest, two of the same kind overlapping by 80 % or more of the shorter are one session, shown
///   once: the Apple Watch's recording first, else the longer.
public enum ActivityRules {
    public static let attachShare = 0.5
    public static let sameSessionShare = 0.8

    public static func resolve(_ activities: [HealthActivity], workouts: [WorkoutSpan]) -> ResolvedActivities {
        var attachedTo: [UUID: UUID] = [:]
        var free: [HealthActivity] = []
        for activity in activities {
            if let workout = workout(for: activity, in: workouts) {
                attachedTo[activity.id] = workout.id
            } else {
                free.append(activity)
            }
        }
        var kept: [HealthActivity] = []
        for activity in free.sorted(by: preferred) where !kept.contains(where: { sameSession($0, activity) }) {
            kept.append(activity)
        }
        return ResolvedActivities(shown: kept.sorted(by: newestFirst),
                                  attached: activities.filter { attachedTo[$0.id] != nil }.sorted(by: newestFirst),
                                  attachedTo: attachedTo)
    }

    /// The copy kept of one session: the Apple Watch's, then the longer (active time), then the earlier start, then
    /// the lower id.
    public static func preferred(_ a: HealthActivity, _ b: HealthActivity) -> Bool {
        if a.fromWatch != b.fromWatch { return a.fromWatch }
        if a.durationS != b.durationS { return a.durationS > b.durationS }
        if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
        return key(a.id) < key(b.id)
    }

    /// Rule 6's workout: the largest overlap reaching `attachShare` of the shorter, then the earlier start, then the
    /// lower id.
    static func workout(for activity: HealthActivity, in workouts: [WorkoutSpan]) -> WorkoutSpan? {
        let candidates = workouts.compactMap { span -> (span: WorkoutSpan, shared: TimeInterval)? in
            let shared = overlap(activity.startedAt, activity.endedAt, span.start, span.end)
            let shorter = min(length(activity.startedAt, activity.endedAt), length(span.start, span.end))
            return shared > 0 && shared >= attachShare * shorter ? (span, shared) : nil
        }
        return candidates.min { a, b in
            if a.shared != b.shared { return a.shared > b.shared }
            if a.span.start != b.span.start { return a.span.start < b.span.start }
            return key(a.span.id) < key(b.span.id)
        }?.span
    }

    static func sameSession(_ a: HealthActivity, _ b: HealthActivity) -> Bool {
        guard a.kind == b.kind else { return false }
        let shared = overlap(a.startedAt, a.endedAt, b.startedAt, b.endedAt)
        let shorter = min(length(a.startedAt, a.endedAt), length(b.startedAt, b.endedAt))
        return shared > 0 && shared >= sameSessionShare * shorter
    }

    /// Seconds two spans share.
    static func overlap(_ aStart: Date, _ aEnd: Date, _ bStart: Date, _ bEnd: Date) -> TimeInterval {
        max(0, min(aEnd, bEnd).timeIntervalSince(max(aStart, bStart)))
    }

    private static func length(_ start: Date, _ end: Date) -> TimeInterval { max(0, end.timeIntervalSince(start)) }

    private static func newestFirst(_ a: HealthActivity, _ b: HealthActivity) -> Bool {
        if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
        return key(a.id) < key(b.id)
    }

    /// Ids compare as the server stores them: lowercase.
    private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }
}
```

- [ ] **Step 4: Run the tests, and the insights fixture beside them**

Run: `swift test --package-path ios/Packages/GymCore --filter 'Activity(Fixture|Rules|Values|Limits)Tests|InsightsFixtureTests'`
Expected: all pass. `everyCaseMatches` runs the 6 fixture cases.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/GymCore/Sources/GymCore/Activity/ActivityRules.swift fixtures/activity.json ios/Packages/GymCore/Tests/GymCoreTests/Activity/ActivityFixtureTests.swift ios/Packages/GymCore/Tests/GymCoreTests/Activity/ActivityRulesTests.swift
git commit -m "feat(core): rules 6 and 7 for outside workouts, on a fixture the server shares"
```

---

## Phase B: GymData and GymSync

### Task 4: Store outside workouts and days of activity

**Files:**
- Create: `ios/Packages/GymData/Sources/GymData/Records/ActivityRecords.swift`
- Create: `ios/Packages/GymData/Sources/GymData/Repositories/ActivityRepository.swift`
- Modify: `ios/Packages/GymData/Sources/GymData/Store/GymStore.swift`
- Modify: `ios/Packages/GymData/Sources/GymData/Repositories/WorkoutRepository+Insights.swift`
- Test: `ios/Packages/GymData/Tests/GymDataTests/ActivityRepositoryTests.swift`

The two models are new, with optional or defaulted fields only. SwiftData adds their tables as a lightweight migration, as for every model since plan 15; there is no `VersionedSchema`.

- [ ] **Step 1: Write the failing tests**

Create `ios/Packages/GymData/Tests/GymDataTests/ActivityRepositoryTests.swift`. `TestClock` is the test target's own, from `SyncStoreTests.swift`:

```swift
import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Plan 39: outside workouts and days of activity on this iPhone. Only the Health import writes them.
@MainActor
@Suite struct ActivityRepositoryTests {
    let container: ModelContainer
    let clock = TestClock()

    init() throws { container = try GymStore.container(inMemory: true) }

    private var repo: ActivityRepository {
        ActivityRepository(context: container.mainContext, now: { [clock] in clock.now })
    }
    private var workouts: WorkoutRepository {
        WorkoutRepository(context: container.mainContext, now: { [clock] in clock.now })
    }

    private func walk(id: UUID = UUID(), daysAgo: Double, minutes: Double = 45) -> HealthActivity {
        let start = clock.now.addingTimeInterval(-daysAgo * 86_400)
        return HealthActivity(id: id, kind: "walking", startedAt: start,
                              endedAt: start.addingTimeInterval(minutes * 60), durationS: minutes * 60, kcal: 180,
                              distanceM: 3_400, avgHr: 102, maxHr: 121, sourceName: "Apple Watch", fromWatch: true)
    }

    @Test func anOutsideWorkoutIsAddedOnceAndATombstoneNeverComesBack() throws {
        let walk = walk(daysAgo: 1)
        #expect(try repo.add(walk, editedAt: walk.endedAt))
        #expect(try !repo.add(walk, editedAt: clock.now), "already here")
        #expect(try repo.activity(walk.id) == walk)

        clock.advance()
        #expect(try repo.delete(walk.id))
        #expect(try repo.activity(walk.id) == nil)
        #expect(try repo.hasRecord(id: walk.id))
        #expect(try !repo.delete(walk.id), "already deleted")
        #expect(try !repo.add(walk, editedAt: clock.now), "a tombstone never comes back")
        #expect(try !repo.delete(UUID()), "nothing to delete")
    }

    @Test func activitiesAreLiveNewestFirstAndFromADate() throws {
        let old = walk(daysAgo: 10), recent = walk(daysAgo: 1), gone = walk(daysAgo: 2)
        for activity in [old, recent, gone] { try repo.add(activity, editedAt: activity.endedAt) }
        try repo.delete(gone.id)
        #expect(try repo.activities(since: nil) == [recent, old])
        #expect(try repo.activities(since: clock.now.addingTimeInterval(-3 * 86_400)) == [recent])
    }

    @Test func oneOutsideTheLimitsIsRefused() throws {
        let start = clock.now
        let tooLong = HealthActivity(id: UUID(), kind: "walking", startedAt: start,
                                     endedAt: start.addingTimeInterval(60), durationS: 90_000,
                                     sourceName: "Apple Watch")
        #expect(throws: GymDataError.self) { try repo.add(tooLong, editedAt: start) }
        #expect(try repo.activities(since: nil).isEmpty)
    }

    @Test func aDayIsWrittenOnlyWhenNewOrChanged() throws {
        let day = ActivityDay(day: "2026-09-21", steps: 8_532, moveKcal: 410, exerciseMin: 34, standH: 11)
        #expect(try repo.save(day: day))
        #expect(try !repo.save(day: day), "unchanged")
        let later = ActivityDay(day: "2026-09-21", steps: 9_001, moveKcal: 430, exerciseMin: 36, standH: 12)
        #expect(try repo.save(day: later))
        #expect(try repo.days(from: "2026-09-21", through: "2026-09-21") == [later])
        let tooMany = ActivityDay(day: "2026-09-22", steps: 200_001, moveKcal: 0, exerciseMin: 0, standH: nil)
        #expect(throws: GymDataError.self) { try repo.save(day: tooMany) }
    }

    @Test func daysComeOldestFirstWithinTheRange() throws {
        for key in ["2026-09-22", "2026-09-20", "2026-09-21", "2026-09-28"] {
            try repo.save(day: ActivityDay(day: key, steps: 1_000, moveKcal: 100, exerciseMin: 10, standH: nil))
        }
        #expect(try repo.days(from: "2026-09-20", through: "2026-09-22").map(\.day)
            == ["2026-09-20", "2026-09-21", "2026-09-22"])
    }

    @Test func finishedSpansSkipTheRunningAndTheDeleted() throws {
        let start = clock.now.addingTimeInterval(-86_400)
        let kept = Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "Push")
        let deleted = Workout(startedAt: start.addingTimeInterval(-86_400),
                              endedAt: start.addingTimeInterval(-82_800), name: "Pull")
        try workouts.save(kept)
        try workouts.save(deleted)
        try workouts.delete(deleted.id)
        try workouts.saveActive(Workout(startedAt: clock.now, name: "Legs"), pausedAt: nil)
        #expect(try workouts.finishedSpans(since: nil)
            == [WorkoutSpan(id: kept.id, start: start, end: start.addingTimeInterval(3_600))])
        #expect(try workouts.finishedSpans(since: clock.now).isEmpty)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path ios/Packages/GymData --filter ActivityRepositoryTests`
Expected: the build fails with `cannot find 'ActivityRepository' in scope` and `value of type 'WorkoutRepository' has no member 'finishedSpans'`.

- [ ] **Step 3: Write the records**

Create `ios/Packages/GymData/Sources/GymData/Records/ActivityRecords.swift`:

```swift
import Foundation
import GymCore
import SwiftData

/// An outside workout read from Apple Health (plan 39). The id is the HealthKit workout's UUID. A deletion in Health
/// leaves a tombstone, which keeps the import from bringing the workout back.
@Model
public final class HealthActivityRecord {
    @Attribute(.unique) public var id: UUID
    public var kind: String
    public var startedAt: Date
    public var endedAt: Date
    public var durationS: Double
    public var kcal: Double?
    public var distanceM: Double?
    public var avgHr: Int?
    public var maxHr: Int?
    public var sourceName: String
    public var fromWatch: Bool
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool
    public var deletedAt: Date?

    public init(_ activity: HealthActivity, now: Date) {
        self.id = activity.id
        self.kind = activity.kind
        self.startedAt = activity.startedAt
        self.endedAt = activity.endedAt
        self.durationS = activity.durationS
        self.kcal = activity.kcal
        self.distanceM = activity.distanceM
        self.avgHr = activity.avgHr
        self.maxHr = activity.maxHr
        self.sourceName = activity.sourceName
        self.fromWatch = activity.fromWatch
        self.updatedAt = now
        self.dirty = true
    }

    public var value: HealthActivity {
        HealthActivity(id: id, kind: kind, startedAt: startedAt, endedAt: endedAt, durationS: durationS, kcal: kcal,
                       distanceM: distanceM, avgHr: avgHr, maxHr: maxHr, sourceName: sourceName, fromWatch: fromWatch)
    }

    /// Takes every field of `activity` (the id stays).
    func apply(_ activity: HealthActivity) {
        kind = activity.kind
        startedAt = activity.startedAt
        endedAt = activity.endedAt
        durationS = activity.durationS
        kcal = activity.kcal
        distanceM = activity.distanceM
        avgHr = activity.avgHr
        maxHr = activity.maxHr
        sourceName = activity.sourceName
        fromWatch = activity.fromWatch
    }
}

/// One local day of activity read from Apple Health (plan 39), keyed by `YYYY-MM-DD`. Never deleted: a day stays as
/// it was last read.
@Model
public final class ActivityDayRecord {
    @Attribute(.unique) public var day: String
    public var steps: Int
    public var moveKcal: Double
    public var exerciseMin: Int
    public var standH: Int?
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool

    public init(_ activityDay: ActivityDay, now: Date) {
        self.day = activityDay.day
        self.steps = activityDay.steps
        self.moveKcal = activityDay.moveKcal
        self.exerciseMin = activityDay.exerciseMin
        self.standH = activityDay.standH
        self.updatedAt = now
        self.dirty = true
    }

    public var value: ActivityDay {
        ActivityDay(day: day, steps: steps, moveKcal: moveKcal, exerciseMin: exerciseMin, standH: standH)
    }

    /// Takes every value of `activityDay` (the day stays).
    func apply(_ activityDay: ActivityDay) {
        steps = activityDay.steps
        moveKcal = activityDay.moveKcal
        exerciseMin = activityDay.exerciseMin
        standH = activityDay.standH
    }
}
```

In `ios/Packages/GymData/Sources/GymData/Store/GymStore.swift`, replace:

```swift
        ShareOutboxRecord.self,
```

with:

```swift
        ShareOutboxRecord.self,
        HealthActivityRecord.self, ActivityDayRecord.self,
```

- [ ] **Step 4: Write the repository and the workout spans**

Create `ios/Packages/GymData/Sources/GymData/Repositories/ActivityRepository.swift`:

```swift
import Foundation
import GymCore
import SwiftData

/// Outside workouts and days of activity read from Apple Health (plan 39). Only the Health import writes them and the
/// app only reads them: Health is their source of truth, so nothing here edits one.
@MainActor
public final class ActivityRepository {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    // MARK: Outside workouts

    /// Live outside workouts that started at or after `since` (all when nil), newest first.
    public func activities(since: Date?) throws -> [HealthActivity] {
        let start = since ?? .distantPast
        let d = FetchDescriptor<HealthActivityRecord>(
            predicate: #Predicate { $0.deletedAt == nil && $0.startedAt >= start },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return try context.fetch(d).map(\.value)
    }

    /// The live outside workout with this id.
    public func activity(_ id: UUID) throws -> HealthActivity? {
        try record(id).flatMap { $0.deletedAt == nil ? $0.value : nil }
    }

    /// True when a row with this id exists, a tombstone included.
    public func hasRecord(id: UUID) throws -> Bool {
        try record(id) != nil
    }

    /// Stores a new outside workout with `editedAt` as its edit time. False when the id is already here, live or
    /// deleted: a tombstone never comes back. Throws for one outside `DomainLimits`.
    @discardableResult
    public func add(_ activity: HealthActivity, editedAt: Date) throws -> Bool {
        if let violation = DomainLimits.healthActivityViolation(activity) {
            throw GymDataError.invalidInput(violation)
        }
        guard try record(activity.id) == nil else { return false }
        context.insert(HealthActivityRecord(activity, now: editedAt))
        try context.save()
        return true
    }

    /// Health deleted it: the live row becomes a tombstone. False when there's no live row.
    @discardableResult
    public func delete(_ id: UUID) throws -> Bool {
        guard let r = try record(id), r.deletedAt == nil else { return false }
        let time = now()
        r.deletedAt = time
        // Never backwards: sync's last-write-wins compares edit times.
        r.updatedAt = max(time, r.updatedAt.addingTimeInterval(0.001))
        r.dirty = true
        try context.save()
        return true
    }

    // MARK: Days

    /// Days from `first` through `last` (`YYYY-MM-DD`, both included), oldest first.
    public func days(from first: String, through last: String) throws -> [ActivityDay] {
        let d = FetchDescriptor<ActivityDayRecord>(predicate: #Predicate { $0.day >= first && $0.day <= last },
                                                   sortBy: [SortDescriptor(\.day)])
        return try context.fetch(d).map(\.value)
    }

    /// Writes the day when it's new or a value changed, and says whether it wrote. Throws for one outside
    /// `DomainLimits`.
    @discardableResult
    public func save(day: ActivityDay) throws -> Bool {
        if let violation = DomainLimits.activityDayViolation(day) { throw GymDataError.invalidInput(violation) }
        let key = day.day
        let existing = try context.fetch(FetchDescriptor<ActivityDayRecord>(predicate: #Predicate { $0.day == key }))
        if let r = existing.first {
            guard r.value != day else { return false }
            r.apply(day)
            r.updatedAt = max(now(), r.updatedAt.addingTimeInterval(0.001))
            r.dirty = true
        } else {
            context.insert(ActivityDayRecord(day, now: now()))
        }
        try context.save()
        return true
    }

    private func record(_ id: UUID) throws -> HealthActivityRecord? {
        try context.fetch(FetchDescriptor<HealthActivityRecord>(predicate: #Predicate { $0.id == id })).first
    }
}
```

In `ios/Packages/GymData/Sources/GymData/Repositories/WorkoutRepository+Insights.swift`, add at the end of the extension, after `finishedStartDates()`:

```swift
    /// The spans of finished, non-deleted workouts that started at or after `since` (all when nil), for attaching
    /// outside workouts to them (plan 39, rule 6). Entries aren't read.
    public func finishedSpans(since: Date?) throws -> [WorkoutSpan] {
        let start = since ?? .distantPast
        var d = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.deletedAt == nil && !$0.isActive && $0.startedAt >= start })
        d.propertiesToFetch = [\.id, \.startedAt, \.endedAt]
        return try context.fetch(d).compactMap { r in
            r.endedAt.map { WorkoutSpan(id: r.id, start: r.startedAt, end: $0) }
        }
    }
```

- [ ] **Step 5: Run the tests, then the whole package**

Run: `swift test --package-path ios/Packages/GymData --filter ActivityRepositoryTests`
Expected: 6 tests pass.

Run: `swift test --package-path ios/Packages/GymData`
Expected: everything passes, so the store still opens with the two new models.

- [ ] **Step 6: Commit**

```bash
git add ios/Packages/GymData/Sources/GymData/Records/ActivityRecords.swift ios/Packages/GymData/Sources/GymData/Repositories/ActivityRepository.swift ios/Packages/GymData/Sources/GymData/Store/GymStore.swift ios/Packages/GymData/Sources/GymData/Repositories/WorkoutRepository+Insights.swift ios/Packages/GymData/Tests/GymDataTests/ActivityRepositoryTests.swift
git commit -m "feat(data): store outside workouts and days of activity"
```

---

### Task 5: Two new sync kinds in the sync store

**Files:**
- Modify: `ios/Packages/GymData/Sources/GymData/Sync/SyncModels.swift` (`SyncEntity`)
- Modify: `ios/Packages/GymData/Sources/GymData/Sync/SyncStore.swift`
- Modify: `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+Ownership.swift`
- Modify: `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+ServerMove.swift`
- Create: `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+Activity.swift`
- Modify: `ios/GymRollins/Features/Sync/SyncStatusText.swift`. Its switches over `SyncEntity` must stay exhaustive, or the app stops building.
- Test: `ios/Packages/GymData/Tests/GymDataTests/SyncStoreActivityTests.swift`
- Test: `ios/GymRollinsTests/SyncStatusTextActivityTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/Packages/GymData/Tests/GymDataTests/SyncStoreActivityTests.swift`:

```swift
import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Plan 39: outside workouts and days of activity as sync kinds: dirty after an import, clean after the ack, pulled by
/// last write wins, wiped with the account, and moved to another server.
@MainActor
@Suite struct SyncStoreActivityTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    private var activities: ActivityRepository {
        ActivityRepository(context: f.context, now: { [clock = f.clock] in clock.now })
    }

    private func walk(id: UUID = UUID()) -> HealthActivity {
        let start = f.clock.now.addingTimeInterval(-86_400)
        return HealthActivity(id: id, kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(2_700),
                              durationS: 2_700, sourceName: "Apple Watch", fromWatch: true)
    }

    private let day = ActivityDay(day: "2026-09-21", steps: 8_532, moveKcal: 410, exerciseMin: 34, standH: 11)

    @Test func importedRowsAreDirtyUntilTheServerTakesThem() throws {
        defer { f.tearDown() }
        let walk = walk()
        try activities.add(walk, editedAt: walk.endedAt)
        try activities.save(day: day)
        let rows = try f.store.dirtyHealthActivities()
        #expect(rows.map(\.value) == [walk])
        #expect(rows.first?.clientUpdatedAt == walk.endedAt)
        #expect(try f.store.dirtyActivityDays().map(\.value) == [day])

        try f.store.markSynced(.healthActivities, id: walk.id.uuidString.lowercased(),
                               clientUpdatedAt: walk.endedAt, serverUpdatedAt: f.clock.now)
        try f.store.markSynced(.activityDays, id: day.day, clientUpdatedAt: f.clock.now, serverUpdatedAt: f.clock.now)
        #expect(try f.store.dirtyHealthActivities().isEmpty)
        #expect(try f.store.dirtyActivityDays().isEmpty)
    }

    @Test func aPulledTombstoneIsKeptSoTheImportCantBringTheWorkoutBack() throws {
        defer { f.tearDown() }
        let walk = walk()
        try f.store.applyRemote(healthActivities: [SyncRow(value: walk, clientUpdatedAt: f.clock.now,
                                                           deletedAt: f.clock.now, serverUpdatedAt: f.clock.now)])
        #expect(try activities.activity(walk.id) == nil)
        #expect(try activities.hasRecord(id: walk.id))
        #expect(try !activities.add(walk, editedAt: walk.endedAt))
        #expect(try f.store.dirtyHealthActivities().isEmpty)
    }

    @Test func aNewerPulledRowWinsAndAnOlderOneDoesNot() throws {
        defer { f.tearDown() }
        try activities.save(day: day)
        let older = ActivityDay(day: day.day, steps: 1, moveKcal: 1, exerciseMin: 1, standH: nil)
        try f.store.applyRemote(activityDays: [SyncRow(value: older,
                                                       clientUpdatedAt: f.clock.now.addingTimeInterval(-60))])
        #expect(try activities.days(from: day.day, through: day.day) == [day])
        let newer = ActivityDay(day: day.day, steps: 9_000, moveKcal: 450, exerciseMin: 40, standH: 12)
        try f.store.applyRemote(activityDays: [SyncRow(value: newer,
                                                       clientUpdatedAt: f.clock.now.addingTimeInterval(60),
                                                       serverUpdatedAt: f.clock.now)])
        #expect(try activities.days(from: day.day, through: day.day) == [newer])
        #expect(try f.store.dirtyActivityDays().isEmpty)
    }

    @Test func theyAreAccountDataWipedOnSignOutAndMovedToAnotherServer() throws {
        defer { f.tearDown() }
        try activities.save(day: day)
        #expect(try f.store.hasLocalData())
        try f.store.markSynced(.activityDays, id: day.day, clientUpdatedAt: f.clock.now, serverUpdatedAt: f.clock.now)
        f.store.syncedServer = "https://old.example"
        #expect(try f.store.moveToServer("https://new.example"))
        #expect(try f.store.dirtyActivityDays().map(\.value) == [day])

        try f.store.resetAccountData()
        #expect(try activities.days(from: "2000-01-01", through: "2100-01-01").isEmpty)
        #expect(try !f.store.hasLocalData())
    }
}
```

Create `ios/GymRollinsTests/SyncStatusTextActivityTests.swift`:

```swift
import GymData
import Testing
@testable import GymRollins

/// Plan 39: the two new sync kinds have names wherever a refused row is listed (Account › "couldn't sync").
@Suite struct SyncStatusTextActivityTests {
    @Test func theNewKindsAreNamed() {
        #expect(SyncStatusText.entityName(.healthActivities) == "Outside workout")
        #expect(SyncStatusText.entityPlural(.healthActivities) == "outside workouts")
        #expect(SyncStatusText.entityName(.activityDays) == "Day of activity")
        #expect(SyncStatusText.entityPlural(.activityDays) == "days of activity")
    }
}
```

- [ ] **Step 2: Run the package tests to see them fail**

Run: `swift test --package-path ios/Packages/GymData --filter SyncStoreActivityTests`
Expected: the build fails with `type 'SyncEntity' has no member 'healthActivities'` and `value of type 'SyncStore' has no member 'dirtyHealthActivities'`.

- [ ] **Step 3: Register the kinds**

In `ios/Packages/GymData/Sources/GymData/Sync/SyncModels.swift`, replace:

```swift
public enum SyncEntity: String, CaseIterable, Sendable {
    case profile, customExercises, exercisePreferences, routines, weekSchedule, muscleTargets, gyms, gymListings,
        bodyweight, workouts, proposals
}
```

with this. The new kinds are pushed after workouts, as the spec says:

```swift
public enum SyncEntity: String, CaseIterable, Sendable {
    case profile, customExercises, exercisePreferences, routines, weekSchedule, muscleTargets, gyms, gymListings,
        bodyweight, workouts, healthActivities, activityDays, proposals
}
```

In `ios/Packages/GymData/Sources/GymData/Sync/SyncStore.swift`:
- After `extension GymListingRecord: SyncTracked {}`, add:

```swift
extension HealthActivityRecord: SyncTracked {}
extension ActivityDayRecord: SyncTracked {}
```

- In `trackedRecord(_:id:)`, after the `.gymListings` case, add:

```swift
        case .healthActivities: return try UUID(uuidString: id).flatMap { try healthActivityRecord($0) }
        case .activityDays: return try activityDayRecord(id)
```

- In `resetAccountData()`, after `try deleteAll(ProposalRecord.self)`, add:

```swift
        try deleteAll(HealthActivityRecord.self)
        try deleteAll(ActivityDayRecord.self)
```

In `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+Ownership.swift`, `hasLocalData()`: after `|| context.fetchCount(FetchDescriptor<WorkoutRecord>()) > 0`, add:

```swift
            || context.fetchCount(FetchDescriptor<HealthActivityRecord>()) > 0
            || context.fetchCount(FetchDescriptor<ActivityDayRecord>()) > 0
```

In `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+ServerMove.swift`, `accountRecords()`: after `records += try every(WorkoutRecord.self)`, add:

```swift
        records += try every(HealthActivityRecord.self)
        records += try every(ActivityDayRecord.self)
```

- [ ] **Step 4: Write the dirty rows and the pulled rows**

Create `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+Activity.swift`:

```swift
import Foundation
import GymCore
import SwiftData

// Outside workouts and days of activity (plan 39). Only the Apple Health import writes them, so a pulled row replaces
// the local one by plain last-write-wins. A pulled tombstone with no local row is kept: it tells the import that Health
// deleted that workout, which would otherwise come back with the next import and revive the row through sync.
extension SyncStore {
    public func dirtyHealthActivities() throws -> [SyncRow<HealthActivity>] {
        try context.fetch(FetchDescriptor<HealthActivityRecord>(predicate: #Predicate { $0.dirty }))
            .map { SyncRow(value: $0.value, clientUpdatedAt: $0.updatedAt, deletedAt: $0.deletedAt,
                           serverUpdatedAt: $0.serverUpdatedAt) }
    }

    public func applyRemote(healthActivities rows: [SyncRow<HealthActivity>]) throws {
        for row in rows {
            let existing = try healthActivityRecord(row.value.id)
            if let existing, !remoteWins(over: existing, remoteEdit: row.clientUpdatedAt) { continue }
            let r = existing ?? {
                let new = HealthActivityRecord(row.value, now: row.clientUpdatedAt)
                context.insert(new)
                return new
            }()
            r.apply(row.value)
            r.deletedAt = row.deletedAt
            markClean(r, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: row.serverUpdatedAt)
        }
        try context.save()
    }

    public func dirtyActivityDays() throws -> [SyncRow<ActivityDay>] {
        try context.fetch(FetchDescriptor<ActivityDayRecord>(predicate: #Predicate { $0.dirty },
                                                             sortBy: [SortDescriptor(\.day)]))
            .map { SyncRow(value: $0.value, clientUpdatedAt: $0.updatedAt, serverUpdatedAt: $0.serverUpdatedAt) }
    }

    /// Applies pulled days (last write wins against dirty local rows); one this app can't store is skipped.
    public func applyRemote(activityDays rows: [SyncRow<ActivityDay>]) throws {
        for row in rows where DomainLimits.activityDayViolation(row.value) == nil {
            let existing = try activityDayRecord(row.value.day)
            if let existing, !remoteWins(over: existing, remoteEdit: row.clientUpdatedAt) { continue }
            let r = existing ?? {
                let new = ActivityDayRecord(row.value, now: row.clientUpdatedAt)
                context.insert(new)
                return new
            }()
            r.apply(row.value)
            markClean(r, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: row.serverUpdatedAt)
        }
        try context.save()
    }

    func healthActivityRecord(_ id: UUID) throws -> HealthActivityRecord? {
        try context.fetch(FetchDescriptor<HealthActivityRecord>(predicate: #Predicate { $0.id == id })).first
    }

    func activityDayRecord(_ day: String) throws -> ActivityDayRecord? {
        try context.fetch(FetchDescriptor<ActivityDayRecord>(predicate: #Predicate { $0.day == day })).first
    }
}
```

- [ ] **Step 5: Name the kinds in the app**

In `ios/GymRollins/Features/Sync/SyncStatusText.swift`:
- In `entityName(_:)`, after `case .workouts: "Workout"`, add:

```swift
        case .healthActivities: "Outside workout"
        case .activityDays: "Day of activity"
```

- In `entityPlural(_:)`, after `case .workouts: "workouts"`, add:

```swift
        case .healthActivities: "outside workouts"
        case .activityDays: "days of activity"
```

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path ios/Packages/GymData --filter SyncStoreActivityTests`
Expected: 4 tests pass.

Run: `swift test --package-path ios/Packages/GymData`
Expected: everything passes, including `SyncStoreServerMoveTests`, which loops over `SyncEntity.allCases`.

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/SyncStatusTextActivityTests`
Expected: 1 test passes, and the app builds.

- [ ] **Step 7: Commit**

```bash
git add ios/Packages/GymData/Sources/GymData/Sync ios/Packages/GymData/Tests/GymDataTests/SyncStoreActivityTests.swift ios/GymRollins/Features/Sync/SyncStatusText.swift ios/GymRollinsTests/SyncStatusTextActivityTests.swift
git commit -m "feat(data): outside workouts and days of activity are sync kinds"
```

---

### Task 6: GymSync carries them: DTOs, transport and the sync round

**Files:**
- Create: `ios/Packages/GymSync/Sources/GymSync/DTO/HealthActivityDTO.swift`
- Create: `ios/Packages/GymSync/Sources/GymSync/DTO/ActivityDayDTO.swift`
- Modify: `ios/Packages/GymSync/Sources/GymSync/SyncTransport.swift`
- Modify: `ios/Packages/GymSync/Sources/GymSync/ApiSyncTransport.swift`
- Modify: `ios/Packages/GymSync/Sources/GymSync/SyncEngine+Rounds.swift`
- Modify: `ios/Packages/GymSync/Tests/GymSyncTests/FakeTransport.swift`
- Modify: `ios/GymRollins/App/SyncCoordinator.swift` (`refreshPending`)
- Modify: `ios/GymRollins/App/DebugSyncSupport.swift` (`OfflineTransport`, `SeededConflictTransport`)
- Test: `ios/Packages/GymSync/Tests/GymSyncTests/ActivitySyncTests.swift`
- Test: `ios/Packages/GymSync/Tests/GymSyncTests/ActivityTransportTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/Packages/GymSync/Tests/GymSyncTests/ActivitySyncTests.swift`. `t0` and `wire(_:)` come from `DTOTests.swift`, and `EngineFixture` from `SyncEngineTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymSync

/// Plan 39: outside workouts and days of activity on the wire and through a sync round.
@MainActor
@Suite struct ActivitySyncTests {
    let f: EngineFixture
    init() throws { f = try EngineFixture() }

    private var activities: ActivityRepository {
        ActivityRepository(context: f.container.mainContext, now: { [clock = f.clock] in clock.now })
    }

    private func walk(id: UUID = UUID(), kcal: Double? = 180) -> HealthActivity {
        let start = f.clock.now.addingTimeInterval(-86_400)
        return HealthActivity(id: id, kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(2_700),
                              durationS: 2_700, kcal: kcal, distanceM: 3_400, avgHr: 102, maxHr: 121,
                              sourceName: "Apple Watch", fromWatch: true)
    }

    private let day = ActivityDay(day: "2026-09-25", steps: 8_532, moveKcal: 410, exerciseMin: 34, standH: nil)

    @Test func anOutsideWorkoutTravelsSnakeCasedWithExplicitNulls() throws {
        defer { f.tearDown() }
        let row = SyncRow(value: walk(kcal: nil), clientUpdatedAt: t0, deletedAt: t0)
        let body = String(decoding: try SyncJSON.encoder.encode(HealthActivityDTO(row)), as: UTF8.self)
        for key in [#""kcal":null"#, #""source_name":"Apple Watch""#, #""from_watch":true"#, #""duration_s":2700"#,
                    #""deleted_at":"#] {
            #expect(body.contains(key), "\(key) in \(body)")
        }
        #expect(!body.contains(#""updated_at""#), "updated_at is the server's")
        let back = try wire(HealthActivityDTO(row)).toDomain()
        #expect(back.value == row.value)
        #expect(back.deletedAt == t0)
    }

    @Test func aDayTravelsWithItsKeyAndANullStand() throws {
        defer { f.tearDown() }
        let row = SyncRow(value: day, clientUpdatedAt: t0)
        let body = String(decoding: try SyncJSON.encoder.encode(ActivityDayDTO(row)), as: UTF8.self)
        #expect(body.contains(#""day":"2026-09-25""#) && body.contains(#""stand_h":null"#))
        #expect(try wire(ActivityDayDTO(row)).toDomain().value == day)
    }

    @Test func importedActivityIsPushedAndMarkedSynced() async throws {
        defer { f.tearDown() }
        let walk = walk()
        try activities.add(walk, editedAt: walk.endedAt)
        try activities.save(day: day)

        await f.engine.sync()

        #expect(await f.server.healthActivities[walk.id]?.kind == "walking")
        #expect(await f.server.activityDays[day.day]?.steps == 8_532)
        #expect(try f.store.dirtyHealthActivities().isEmpty)
        #expect(try f.store.dirtyActivityDays().isEmpty)
    }

    @Test func anotherDevicesRowsArePulledTombstonesIncluded() async throws {
        defer { f.tearDown() }
        let live = walk(), gone = walk()
        try await f.server.seed(healthActivity: HealthActivityDTO(SyncRow(value: live, clientUpdatedAt: f.clock.now)))
        try await f.server.seed(healthActivity: HealthActivityDTO(SyncRow(value: gone, clientUpdatedAt: f.clock.now,
                                                                          deletedAt: f.clock.now)))
        try await f.server.seed(activityDay: ActivityDayDTO(SyncRow(value: day, clientUpdatedAt: f.clock.now)))

        await f.engine.sync()

        #expect(try activities.activity(live.id) == live)
        #expect(try activities.activity(gone.id) == nil)
        #expect(try activities.hasRecord(id: gone.id))
        #expect(try activities.days(from: day.day, through: day.day) == [day])
        #expect(f.store.cursor(for: .healthActivities) != nil)
        #expect(f.store.cursor(for: .activityDays) != nil)
    }

    @Test func aRowTheServerRefusesIsRecordedAndTheRestSync() async throws {
        defer { f.tearDown() }
        let refused = walk(), fine = walk()
        try activities.add(refused, editedAt: refused.endedAt)
        try activities.add(fine, editedAt: fine.endedAt)
        await f.server.reject(ids: [refused.id.uuidString])

        await f.engine.sync()

        #expect(await f.server.healthActivities[fine.id] != nil)
        #expect(await f.server.healthActivities[refused.id] == nil)
        #expect(f.store.syncFailures().map(\.entity) == [.healthActivities])
    }
}
```

Create `ios/Packages/GymSync/Tests/GymSyncTests/ActivityTransportTests.swift`. `StubServer` comes from `StubURLProtocol.swift`:

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// Plan 39: the two activity tables on `/v1/sync` (server/src/sync/entities.ts, `health-activities` and
/// `activity-days`).
@Suite struct ActivityTransportTests {
    private let t0 = SyncDate.parse("2026-09-27T08:00:00.123456Z")!

    @Test func eachGoesUpAndComesDownOnItsOwnPath() async throws {
        let server = StubServer { request in
            request.method == "POST" ? .json(200, #"{"acks": []}"#) : .json(200, #"{"rows": []}"#)
        }
        let transport = ApiSyncTransport(api: server.client())
        let start = t0
        let walk = HealthActivity(id: UUID(), kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(600),
                                  durationS: 600, sourceName: "Apple Watch")
        _ = try await transport.push(healthActivities: [HealthActivityDTO(SyncRow(value: walk, clientUpdatedAt: t0))])
        let day = ActivityDay(day: "2026-09-27", steps: 10, moveKcal: 1, exerciseMin: 0, standH: nil)
        _ = try await transport.push(activityDays: [ActivityDayDTO(SyncRow(value: day, clientUpdatedAt: t0))])
        _ = try await transport.pullHealthActivities(since: nil)
        _ = try await transport.pullActivityDays(since: nil)
        #expect(server.requests.map { "\($0.method) \($0.path)" } == [
            "POST /v1/sync/health-activities", "POST /v1/sync/activity-days",
            "GET /v1/sync/health-activities", "GET /v1/sync/activity-days",
        ])
    }

    @Test func daysPageByTheirDay() async throws {
        let page = #"{"rows": [{"day": "2026-09-27", "steps": 10, "move_kcal": 1, "exercise_min": 0, "stand_h": null, "#
            + #""client_updated_at": "2026-09-27T08:00:00.000000Z", "updated_at": "2026-11-08T10:00:00.100000Z"}]}"#
        let server = StubServer { request in
            let first = request.query["after"] == nil && request.query["since"] == nil
            return first ? .json(200, page) : .json(200, #"{"rows": []}"#)
        }
        let days = try await ApiSyncTransport(api: server.client(), pageSize: 1).pullActivityDays(since: nil)
        #expect(days.map(\.day) == ["2026-09-27"])
        #expect(server.requests.last?.query["after"] == "2026-09-27")
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path ios/Packages/GymSync --filter 'ActivitySyncTests|ActivityTransportTests'`
Expected: the build fails with `cannot find 'HealthActivityDTO' in scope` and `cannot find 'ActivityDayDTO' in scope`.

- [ ] **Step 3: Write the DTOs**

Create `ios/Packages/GymSync/Sources/GymSync/DTO/HealthActivityDTO.swift`:

```swift
import Foundation
import GymCore
import GymData

/// `health_activities` (server/migrations/0013_health_activities.sql): an outside workout read from Apple Health
/// (plan 39). The key is the account plus the HealthKit workout's UUID.
public struct HealthActivityDTO: Codable, Sendable, Equatable, ServerStamped {
    public let id: UUID
    public let kind: String
    public let startedAt: Date
    public let endedAt: Date
    public let durationS: Double
    public let kcal: Double?
    public let distanceM: Double?
    public let avgHr: Int?
    public let maxHr: Int?
    public let sourceName: String
    public let fromWatch: Bool
    public let clientUpdatedAt: Date
    public let deletedAt: Date?
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, kind, kcal
        case startedAt = "started_at", endedAt = "ended_at", durationS = "duration_s", distanceM = "distance_m"
        case avgHr = "avg_hr", maxHr = "max_hr", sourceName = "source_name", fromWatch = "from_watch"
        case clientUpdatedAt = "client_updated_at", deletedAt = "deleted_at", updatedAt = "updated_at"
    }

    public init(_ row: SyncRow<HealthActivity>) {
        let a = row.value
        id = a.id
        kind = a.kind
        startedAt = a.startedAt
        endedAt = a.endedAt
        durationS = a.durationS
        kcal = a.kcal
        distanceM = a.distanceM
        avgHr = a.avgHr
        maxHr = a.maxHr
        sourceName = a.sourceName
        fromWatch = a.fromWatch
        clientUpdatedAt = row.clientUpdatedAt
        deletedAt = row.deletedAt
        updatedAt = row.serverUpdatedAt
    }

    public func toDomain() -> SyncRow<HealthActivity> {
        SyncRow(value: HealthActivity(id: id, kind: kind, startedAt: startedAt, endedAt: endedAt, durationS: durationS,
                                      kcal: kcal, distanceM: distanceM, avgHr: avgHr, maxHr: maxHr,
                                      sourceName: sourceName, fromWatch: fromWatch),
                clientUpdatedAt: clientUpdatedAt, deletedAt: deletedAt, serverUpdatedAt: updatedAt)
    }

    /// Nulls are written explicitly; `updated_at` is server-owned and never sent.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt)
        try c.encode(durationS, forKey: .durationS)
        try c.encode(kcal, forKey: .kcal)
        try c.encode(distanceM, forKey: .distanceM)
        try c.encode(avgHr, forKey: .avgHr)
        try c.encode(maxHr, forKey: .maxHr)
        try c.encode(sourceName, forKey: .sourceName)
        try c.encode(fromWatch, forKey: .fromWatch)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
    }
}
```

Create `ios/Packages/GymSync/Sources/GymSync/DTO/ActivityDayDTO.swift`:

```swift
import Foundation
import GymCore
import GymData

/// `activity_days` (server/migrations/0013_health_activities.sql, primary key `(user_id, day)`): one local day of
/// Apple Health activity (plan 39).
public struct ActivityDayDTO: Codable, Sendable, Equatable, ServerStamped {
    /// `YYYY-MM-DD`.
    public let day: String
    public let steps: Int
    public let moveKcal: Double
    public let exerciseMin: Int
    public let standH: Int?
    public let clientUpdatedAt: Date
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case day, steps
        case moveKcal = "move_kcal", exerciseMin = "exercise_min", standH = "stand_h"
        case clientUpdatedAt = "client_updated_at", updatedAt = "updated_at"
    }

    public init(_ row: SyncRow<ActivityDay>) {
        day = row.value.day
        steps = row.value.steps
        moveKcal = row.value.moveKcal
        exerciseMin = row.value.exerciseMin
        standH = row.value.standH
        clientUpdatedAt = row.clientUpdatedAt
        updatedAt = row.serverUpdatedAt
    }

    public func toDomain() -> SyncRow<ActivityDay> {
        SyncRow(value: ActivityDay(day: day, steps: steps, moveKcal: moveKcal, exerciseMin: exerciseMin,
                                   standH: standH),
                clientUpdatedAt: clientUpdatedAt, serverUpdatedAt: updatedAt)
    }

    /// Nulls are written explicitly; `updated_at` is server-owned and never sent.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(day, forKey: .day)
        try c.encode(steps, forKey: .steps)
        try c.encode(moveKcal, forKey: .moveKcal)
        try c.encode(exerciseMin, forKey: .exerciseMin)
        try c.encode(standH, forKey: .standH)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}
```

- [ ] **Step 4: Add them to the transport**

In `ios/Packages/GymSync/Sources/GymSync/SyncTransport.swift`, in `protocol SyncTransport`:
- after `func push(workout: WorkoutDTO) async throws -> WorkoutPushResult`, add:

```swift
    /// Outside workouts read from Apple Health (plan 39); acks use the row id.
    func push(healthActivities: [HealthActivityDTO]) async throws -> [RowAck]
    /// Days of activity; acks use the day (`YYYY-MM-DD`).
    func push(activityDays: [ActivityDayDTO]) async throws -> [RowAck]
```

- after `func pullWorkouts(since: Date?) async throws -> [WorkoutDTO]`, add:

```swift
    func pullHealthActivities(since: Date?) async throws -> [HealthActivityDTO]
    func pullActivityDays(since: Date?) async throws -> [ActivityDayDTO]
```

In the same file's `extension SyncTransport`, before `/// When Claude last called the MCP server…`, add the defaults that keep the older test doubles building:

```swift
    /// Test doubles that predate plan 39 store no activity (no acks, nothing to pull).
    public func push(healthActivities: [HealthActivityDTO]) async throws -> [RowAck] { [] }
    public func push(activityDays: [ActivityDayDTO]) async throws -> [RowAck] { [] }
    public func pullHealthActivities(since: Date?) async throws -> [HealthActivityDTO] { [] }
    public func pullActivityDays(since: Date?) async throws -> [ActivityDayDTO] { [] }
```

In `ios/Packages/GymSync/Sources/GymSync/ApiSyncTransport.swift`:
- after `push(workout:)`, add:

```swift
    public func push(healthActivities: [HealthActivityDTO]) async throws -> [RowAck] {
        try await push(healthActivities, to: "health-activities")
    }

    public func push(activityDays: [ActivityDayDTO]) async throws -> [RowAck] {
        try await push(activityDays, to: "activity-days")
    }
```

- before `fetchWorkout(id:)`, add:

```swift
    public func pullHealthActivities(since: Date?) async throws -> [HealthActivityDTO] {
        try await pull("health-activities", tiebreak: "id", since: since)
    }

    public func pullActivityDays(since: Date?) async throws -> [ActivityDayDTO] {
        try await pull("activity-days", tiebreak: "day", since: since)
    }
```

- [ ] **Step 5: Push and pull them in each round**

In `ios/Packages/GymSync/Sources/GymSync/SyncEngine+Rounds.swift`, replace the end of `pushAll()`:

```swift
        return try await pushWorkouts(only: nil, force: false)
    }
```

with:

```swift
        let stale = try await pushWorkouts(only: nil, force: false)
        try await pushActivity()
        return stale
    }

    /// Outside workouts and days of activity (plan 39), after the workouts.
    private func pushActivity() async throws {
        try await pushBatch(.healthActivities, rows: try store.dirtyHealthActivities(),
                            key: { $0.value.id.uuidString }, send: {
            try await self.transport.push(healthActivities: $0.map(HealthActivityDTO.init))
        })
        try await pushBatch(.activityDays, rows: try store.dirtyActivityDays(), key: { $0.value.day }, send: {
            try await self.transport.push(activityDays: $0.map(ActivityDayDTO.init))
        })
    }
```

In `pullAll()`, after the `pull(.workouts, …)` call, add:

```swift
        try await pull(.healthActivities, fetch: { try await self.transport.pullHealthActivities(since: $0) }, apply: {
            try self.store.applyRemote(healthActivities: $0.map { $0.toDomain() })
        })
        try await pull(.activityDays, fetch: { try await self.transport.pullActivityDays(since: $0) }, apply: {
            try self.store.applyRemote(activityDays: $0.map { $0.toDomain() })
        })
```

- [ ] **Step 6: Teach the fake server the two tables**

In `ios/Packages/GymSync/Tests/GymSyncTests/FakeTransport.swift`:
- after `private(set) var workouts: [UUID: WorkoutDTO] = [:]`, add:

```swift
    private(set) var healthActivities: [UUID: HealthActivityDTO] = [:]
    private(set) var activityDays: [String: ActivityDayDTO] = [:]
```

- after `func seed(bodyweight entry: BodyweightDTO) throws { _ = try accept(entry, into: &bodyweight, key: entry.id) }`, add:

```swift
    func seed(healthActivity dto: HealthActivityDTO) throws {
        _ = try accept(dto, into: &healthActivities, key: dto.id)
    }
    func seed(activityDay dto: ActivityDayDTO) throws { _ = try accept(dto, into: &activityDays, key: dto.day) }
```

- before `func push(gyms dtos: [GymDTO]) throws -> [RowAck] {`, add:

```swift
    func push(healthActivities dtos: [HealthActivityDTO]) throws -> [RowAck] {
        try gate()
        try checkRejected(dtos.map(\.id.uuidString))
        return try dtos.compactMap { dto in
            try accept(dto, into: &healthActivities, key: dto.id)
                .map { RowAck(id: $0.id.uuidString.lowercased(), updatedAt: $0.updatedAt!) }
        }
    }

    func push(activityDays dtos: [ActivityDayDTO]) throws -> [RowAck] {
        try gate()
        try checkRejected(dtos.map(\.day))
        return try dtos.compactMap { dto in
            try accept(dto, into: &activityDays, key: dto.day).map { RowAck(id: $0.day, updatedAt: $0.updatedAt!) }
        }
    }

```

- before `func fetchWorkout(id: UUID) throws -> WorkoutDTO? {`, add:

```swift
    func pullHealthActivities(since: Date?) async throws -> [HealthActivityDTO] {
        await waitIfHeld()
        return try pull(Array(healthActivities.values), since: since)
    }
    func pullActivityDays(since: Date?) async throws -> [ActivityDayDTO] {
        await waitIfHeld()
        return try pull(Array(activityDays.values), since: since)
    }

```

- after `extension GymListingDTO: ServerStampedDTO {}`, add:

```swift
extension HealthActivityDTO: ServerStampedDTO {}
extension ActivityDayDTO: ServerStampedDTO {}
```

- [ ] **Step 7: Register them in the app**

In `ios/GymRollins/App/SyncCoordinator.swift`, `refreshPending()`: after `+ waiting(.workouts, try store.dirtyWorkouts(), key: { $0.value.workout.id.uuidString })`, add:

```swift
                + waiting(.healthActivities, try store.dirtyHealthActivities(), key: { $0.value.id.uuidString })
                + waiting(.activityDays, try store.dirtyActivityDays(), key: { $0.value.day })
```

In `ios/GymRollins/App/DebugSyncSupport.swift`:
- in `OfflineTransport`, after `func push(workout: WorkoutDTO) async throws -> WorkoutPushResult { throw offline() }`, add:

```swift
    func push(healthActivities: [HealthActivityDTO]) async throws -> [RowAck] { throw offline() }
    func push(activityDays: [ActivityDayDTO]) async throws -> [RowAck] { throw offline() }
    func pullHealthActivities(since: Date?) async throws -> [HealthActivityDTO] { throw offline() }
    func pullActivityDays(since: Date?) async throws -> [ActivityDayDTO] { throw offline() }
```

- in `SeededConflictTransport`, after `func pullWorkouts(since: Date?) async throws -> [WorkoutDTO] { [] }`, add:

```swift
    func push(healthActivities: [HealthActivityDTO]) async throws -> [RowAck] {
        healthActivities.map { ack($0.id.uuidString.lowercased()) }
    }
    func push(activityDays: [ActivityDayDTO]) async throws -> [RowAck] { activityDays.map { ack($0.day) } }
    func pullHealthActivities(since: Date?) async throws -> [HealthActivityDTO] { [] }
    func pullActivityDays(since: Date?) async throws -> [ActivityDayDTO] { [] }
```

- [ ] **Step 8: Run the tests**

Run: `swift test --package-path ios/Packages/GymSync --filter 'ActivitySyncTests|ActivityTransportTests'`
Expected: 7 tests pass.

Run: `swift test --package-path ios/Packages/GymSync`
Expected: everything passes.

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/SyncAccountSafetyTests -only-testing:GymRollinsTests/SyncStatusTextActivityTests`
Expected: all pass, and the app builds with both debug transports.

- [ ] **Step 9: Commit**

```bash
git add ios/Packages/GymSync ios/GymRollins/App/SyncCoordinator.swift ios/GymRollins/App/DebugSyncSupport.swift
git commit -m "feat(sync): outside workouts and days of activity push after workouts and pull with them"
```

---

## Phase C: GymHealth

### Task 7: The HealthStore seam reads outside workouts and days of activity

**Files:**
- Modify: `ios/Packages/GymHealth/Sources/GymHealth/HealthStore.swift`
- Modify: `ios/Packages/GymHealth/Sources/GymHealth/FakeHealthStore.swift`
- Modify: `ios/Packages/GymHealth/Sources/GymHealth/HealthSyncState.swift`
- Modify: `ios/Packages/GymHealth/Sources/GymHealth/HealthKitStore.swift` (iOS/watchOS only: `swift test` on the Mac doesn't build it)
- Test: `ios/Packages/GymHealth/Tests/GymHealthTests/FakeActivityStoreTests.swift`
- Test: `ios/Packages/GymHealth/Tests/GymHealthTests/HealthActivityStateTests.swift`
- Test: `ios/GymRollinsTests/HealthKitKindTests.swift` (needs HealthKit, so it runs in the app's tests)

The read types are never added to `HealthDataType`. That enum is the write list, and `HealthPermissions.summary` would never say "Connected" again (spec §4).

The HealthKit calls below use the iOS 26 SDK's async descriptors:
- `HKAnchoredObjectQueryDescriptor` with `.workout(_:)`;
- `HKStatisticsCollectionQueryDescriptor` with `.cumulativeSum`, read through its `statistics()`;
- `HKActivitySummaryQueryDescriptor` with `HKQuery.predicate(forActivitySummariesBetweenStart:end:)`;
- `HKWorkout.statistics(for:)`, and `HKSourceRevision.productType`.

This plan's author type-checked these exact lines against `iPhoneOS26.2.sdk` in Swift 6 mode.

- [ ] **Step 1: Write the failing tests**

Create `ios/Packages/GymHealth/Tests/GymHealthTests/FakeActivityStoreTests.swift`:

```swift
import Foundation
import GymCore
import Testing
@testable import GymHealth

/// Plan 39: the fake Health reads outside workouts like HealthKit's anchored query (deletions only after an anchor)
/// and days by calendar day.
@Suite struct FakeActivityStoreTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func walk(daysAgo: Double) -> HealthOutsideWorkout {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return HealthOutsideWorkout(activity: HealthActivity(
            id: UUID(), kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(1_800), durationS: 1_800,
            sourceName: "Apple Watch", fromWatch: true))
    }

    @Test func outsideWorkoutsComeAnchoredWithTheirDeletions() async throws {
        let old = walk(daysAgo: 800), recent = walk(daysAgo: 3)
        let store = FakeHealthStore(outsideWorkouts: [old, recent])
        let first = try await store.outsideWorkoutChanges(since: now.addingTimeInterval(-730 * 86_400), anchor: nil)
        #expect(first.added == [recent])
        #expect(first.deleted.isEmpty)

        let later = walk(daysAgo: 1)
        await store.addOutsideWorkout(later)
        await store.deleteOutsideWorkout(recent.activity.id)
        let next = try await store.outsideWorkoutChanges(since: .distantPast, anchor: first.anchor)
        #expect(next.added == [later])
        #expect(next.deleted == [recent.activity.id])
    }

    @Test func daysComeByCalendarDayOldestFirst() async throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let days = FakeHealthStore.uiTestActivityDays(now: now, calendar: utc)
        #expect(days.count == 7)
        let store = FakeHealthStore(days: days)
        let read = try await store.activityDays(from: now.addingTimeInterval(-86_400), through: now, calendar: utc)
        #expect(read.map(\.steps) == [8_532, 4_210])
        #expect(await store.dayReads.count == 1)
    }

    @Test func theUITestSeedAttachesItsStrengthRecordingToSeedHistorysWorkout() throws {
        let fixedNow = try #require(ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z"))
        let seeded = FakeHealthStore.uiTestOutsideWorkouts(now: fixedNow).map(\.activity)
        let history = try #require(ISO8601DateFormatter().date(from: "2026-09-19T18:00:00Z")) // OwnerSeed.applyHistory
        let workout = WorkoutSpan(id: UUID(), start: history, end: history.addingTimeInterval(3_500))
        let resolved = ActivityRules.resolve(seeded, workouts: [workout])
        #expect(resolved.shown.map(\.id) == [FakeHealthStore.uiTestWalkId])
        #expect(resolved.measured(for: workout.id)?.id == FakeHealthStore.uiTestStrengthId)
    }
}
```

Create `ios/Packages/GymHealth/Tests/GymHealthTests/HealthActivityStateTests.swift`:

```swift
import Foundation
import Testing
@testable import GymHealth

/// Plan 39's new state fields: a state saved before them still decodes (a failure would turn Health off and drop the
/// export ledgers), and the switches read as on until turned off.
@Suite struct HealthActivityStateTests {
    @Test func aStateSavedBeforePlan39StillDecodesWithHealthOn() throws {
        let suite = "state-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = #"{"enabled":true,"enabledAt":780000000,"workouts":{"A":"f"},"weighIns":{},"lastImportCount":2,"#
            + #""pendingBodyFat":[],"unmatchedDeletions":[],"awaitingRestore":false}"#
        defaults.set(Data(saved.utf8), forKey: HealthSyncState.key)

        let state = HealthSyncState.load(from: defaults)
        #expect(state.enabled)
        #expect(state.workouts == ["A": "f"])
        #expect(state.readsOutsideWorkouts && state.readsActivityDays)
        #expect(!state.activityPermissionsAsked && !state.activityCardDismissed)
        #expect(state.activityAnchor == nil && state.activityDaysReadAt == nil)
        #expect(state.unmatchedActivityDeletions.isEmpty)
    }

    @Test func theNewFieldsRoundTripAndDefaultsArentStored() throws {
        var state = HealthSyncState()
        state.readsOutsideWorkouts = false
        state.activityPermissionsAsked = true
        state.activityAnchor = Data("7".utf8)
        state.unmatchedActivityDeletions = [UUID()]
        let back = try JSONDecoder().decode(HealthSyncState.self, from: JSONEncoder().encode(state))
        #expect(back == state)
        #expect(!back.readsOutsideWorkouts && back.readsActivityDays && back.activityPermissionsAsked)

        state.readsOutsideWorkouts = true
        state.unmatchedActivityDeletions = []
        #expect(state.readsOutsideWorkoutsStorage == nil && state.unmatchedActivityDeletionsStorage == nil)
    }
}
```

Create `ios/GymRollinsTests/HealthKitKindTests.swift`:

```swift
import GymCore
import GymHealth
import HealthKit
import Testing

/// Plan 39: HealthKit's workout types map to GymRollins' kind slugs (Workout app names), and anything else is "other".
@Suite struct HealthKitKindTests {
    @Test(arguments: [
        (HKWorkoutActivityType.walking, "walking"), (.running, "running"), (.cycling, "cycling"),
        (.highIntensityIntervalTraining, "hiit"), (.traditionalStrengthTraining, "traditional_strength"),
        (.functionalStrengthTraining, "functional_strength"), (.cooldown, "cooldown"), (.socialDance, "dance"),
        (.downhillSkiing, "skiing"), (.wheelchairRunPace, "running"), (.archery, "other"), (.other, "other"),
    ])
    func mapsToItsSlug(type: HKWorkoutActivityType, slug: String) {
        #expect(HealthKitStore.kindSlug(type) == slug)
    }

    @Test func everySlugItWritesIsAKnownKind() {
        let types: [HKWorkoutActivityType] = [
            .walking, .running, .cycling, .highIntensityIntervalTraining, .yoga, .swimming,
            .traditionalStrengthTraining, .functionalStrengthTraining, .elliptical, .rowing, .hiking, .cardioDance,
            .coreTraining, .pilates, .cooldown, .stairs, .jumpRope, .mixedCardio, .crossTraining, .flexibility,
            .mindAndBody, .tennis, .soccer, .basketball, .boxing, .kickboxing, .martialArts, .climbing,
            .snowboarding, .golf, .bowling,
        ]
        #expect(types.allSatisfy { OutsideWorkoutKind(rawValue: HealthKitStore.kindSlug($0)) != nil })
    }
}
```

- [ ] **Step 2: Run the package tests to see them fail**

Run: `swift test --package-path ios/Packages/GymHealth --filter 'FakeActivityStoreTests|HealthActivityStateTests'`
Expected: the build fails with errors like these:
- `cannot find 'HealthOutsideWorkout' in scope`;
- `extra arguments at positions … in call` for `FakeHealthStore(outsideWorkouts:)`;
- `value of type 'HealthSyncState' has no member 'readsOutsideWorkouts'`.

- [ ] **Step 3: Add the reads to the seam**

In `ios/Packages/GymHealth/Sources/GymHealth/HealthStore.swift`, before `/// The seam around HealthKit…` (above `public protocol HealthStore`), add:

```swift
/// A workout in Health from any source, as the activity import reads it (plan 39). The import keeps only outside
/// workouts: not `writtenByGymRollins`, and not carrying a GymRollins workout's id as its external id.
public struct HealthOutsideWorkout: Sendable, Equatable {
    public let activity: HealthActivity
    /// `HKMetadataKeyExternalUUID`, when the writer set one (GymRollins' own copies carry their workout's id).
    public let externalId: UUID?
    /// GymRollins wrote it: its export metadata (`GymRollinsExport`, `GymRollinsWriter`), or the app's or the watch
    /// app's bundle.
    public let writtenByGymRollins: Bool

    public init(activity: HealthActivity, externalId: UUID? = nil, writtenByGymRollins: Bool = false) {
        self.activity = activity
        self.externalId = externalId
        self.writtenByGymRollins = writtenByGymRollins
    }
}

/// One anchored read of Health's workouts (plan 39): added and deleted since `anchor`, and the anchor to resume from.
public struct HealthOutsideWorkoutChanges: Sendable, Equatable {
    public let added: [HealthOutsideWorkout]
    public let deleted: [UUID]
    public let anchor: Data?

    public init(added: [HealthOutsideWorkout], deleted: [UUID], anchor: Data?) {
        self.added = added
        self.deleted = deleted
        self.anchor = anchor
    }
}
```

At the end of `protocol HealthStore`, after `func bodyChanges(since start: Date, anchor: Data?) async throws -> HealthBodyChanges`, add:

```swift
    /// Workouts from every source that started on/after `start`, added or deleted since `anchor` (all when nil;
    /// deletions only with an anchor), each with its energy, distance and heart rate statistics (plan 39).
    func outsideWorkoutChanges(since start: Date, anchor: Data?) async throws -> HealthOutsideWorkoutChanges
    /// Each day of `calendar` from `start` through `end` that has any data: steps from Health's merged statistics,
    /// and move, exercise and stand from the day's Activity summary (plan 39). Oldest first.
    func activityDays(from start: Date, through end: Date, calendar: Calendar) async throws -> [ActivityDay]
```

- [ ] **Step 4: Give the fake store outside workouts and days**

In `ios/Packages/GymHealth/Sources/GymHealth/FakeHealthStore.swift`:
- Add `import GymCore` under `import Foundation`.
- Replace the stored `waiters` line and `init`:

```swift
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(isAvailable: Bool = true, grantOnRequest: [HealthDataType: HealthPermission]? = nil,
                seed: [HealthBodySample] = []) {
        self.isAvailable = isAvailable
        self.grantOnRequest = grantOnRequest
            ?? Dictionary(uniqueKeysWithValues: HealthDataType.allCases.map { ($0, .authorized) })
        for sample in seed {
            seq += 1
            samples.append((seq, sample))
        }
    }
```

with:

```swift
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Workouts in "Health" from any source, with the change sequence they were added at (plan 39).
    private var outside: [(seq: Int, workout: HealthOutsideWorkout)] = []
    private var outsideDeletions: [(seq: Int, uuid: UUID)] = []
    private var activity: [String: ActivityDay] = [:]
    /// Every `activityDays` call's range, in order.
    public private(set) var dayReads: [(from: Date, through: Date)] = []

    public init(isAvailable: Bool = true, grantOnRequest: [HealthDataType: HealthPermission]? = nil,
                seed: [HealthBodySample] = [], outsideWorkouts: [HealthOutsideWorkout] = [],
                days: [ActivityDay] = []) {
        self.isAvailable = isAvailable
        self.grantOnRequest = grantOnRequest
            ?? Dictionary(uniqueKeysWithValues: HealthDataType.allCases.map { ($0, .authorized) })
        for sample in seed {
            seq += 1
            samples.append((seq, sample))
        }
        for workout in outsideWorkouts {
            seq += 1
            outside.append((seq, workout))
        }
        for day in days { activity[day.day] = day }
    }
```

- Before `// MARK: Test controls`, add the UI-test seeds. Task 16 uses them for `-fakeHealth`. They're placed so that the strength recording falls inside `OwnerSeed.applyHistory`'s workout of 19 Sep, 18:00 UTC:

```swift
    /// Plan 39's UI-test activity: yesterday's Apple Watch walk, and an Apple Watch strength recording during
    /// `-seedHistory`'s workout a week before `now` (18:00 UTC, 58 minutes), which attaches to it.
    public static let uiTestWalkId = UUID(uuidString: "00000000-0000-4000-8000-00000000a001")!
    public static let uiTestStrengthId = UUID(uuidString: "00000000-0000-4000-8000-00000000a002")!

    public static func uiTestOutsideWorkouts(now: Date) -> [HealthOutsideWorkout] {
        let walk = now.addingTimeInterval(-26 * 3_600)
        let strength = now.addingTimeInterval(-7 * 86_400 + 9 * 3_600 + 120)
        return [
            HealthOutsideWorkout(activity: HealthActivity(
                id: uiTestWalkId, kind: "walking", startedAt: walk, endedAt: walk.addingTimeInterval(2_700),
                durationS: 2_700, kcal: 180, distanceM: 3_400, avgHr: 102, maxHr: 121, sourceName: "Apple Watch",
                fromWatch: true)),
            HealthOutsideWorkout(activity: HealthActivity(
                id: uiTestStrengthId, kind: "traditional_strength", startedAt: strength,
                endedAt: strength.addingTimeInterval(3_180), durationS: 3_180, kcal: 412, avgHr: 128, maxHr: 162,
                sourceName: "Apple Watch", fromWatch: true)),
        ]
    }

    /// Seven days of activity ending on `now`'s day in `calendar` (the first values are today's).
    public static func uiTestActivityDays(now: Date, calendar: Calendar) -> [ActivityDay] {
        let values: [(steps: Int, move: Double, exercise: Int, stand: Int)] = [
            (4_210, 210, 18, 6), (8_532, 410, 34, 11), (10_250, 520, 41, 12), (6_120, 300, 22, 10),
            (12_004, 610, 55, 12), (7_450, 350, 28, 11), (9_876, 480, 39, 12),
        ]
        return values.enumerated().compactMap { offset, value in
            calendar.date(byAdding: .day, value: -offset, to: now).map {
                ActivityDay(day: ActivityDay.key(for: $0, calendar: calendar), steps: value.steps,
                            moveKcal: value.move, exerciseMin: value.exercise, standH: value.stand)
            }
        }
    }
```

- After `public func bodySamples() -> [HealthBodySample] { samples.map(\.sample) }`, add:

```swift
    /// Another app (the Workout app, Strava) saves a workout.
    public func addOutsideWorkout(_ workout: HealthOutsideWorkout) {
        seq += 1
        outside.append((seq, workout))
    }

    /// The user deletes a workout in the Health app.
    public func deleteOutsideWorkout(_ id: UUID) {
        guard outside.contains(where: { $0.workout.activity.id == id }) else { return }
        outside.removeAll { $0.workout.activity.id == id }
        seq += 1
        outsideDeletions.append((seq, id))
    }

    /// Health's totals for a day (late Apple Watch data changes them).
    public func setDay(_ day: ActivityDay) { activity[day.day] = day }
```

- Before `// MARK: Private`, add:

```swift
    public func outsideWorkoutChanges(since start: Date, anchor: Data?) async throws -> HealthOutsideWorkoutChanges {
        await passGate()
        if failReads { throw Failure(message: "Reading failed") }
        let from = anchor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let added = outside.filter { $0.seq > from && $0.workout.activity.startedAt >= start }.map(\.workout)
        let deleted = anchor == nil ? [] : outsideDeletions.filter { $0.seq > from }.map(\.uuid)
        return HealthOutsideWorkoutChanges(added: added, deleted: deleted, anchor: Data("\(seq)".utf8))
    }

    public func activityDays(from start: Date, through end: Date, calendar: Calendar) async throws -> [ActivityDay] {
        await passGate()
        if failReads { throw Failure(message: "Reading failed") }
        dayReads.append((start, end))
        let first = ActivityDay.key(for: start, calendar: calendar)
        let last = ActivityDay.key(for: end, calendar: calendar)
        return activity.values.filter { $0.day >= first && $0.day <= last }.sorted { $0.day < $1.day }
    }
```

- [ ] **Step 5: Add the state fields**

In `ios/Packages/GymHealth/Sources/GymHealth/HealthSyncState.swift`, before `public init() {}`, add:

```swift
    // Plan 39: reading activity from Health. Plain optionals, or optional storage like `watchClaimsStorage`, so a state
    // saved before plan 39 still decodes: a decode failure resets the whole state, turning Health off and dropping the
    // export ledgers.

    /// Anchored-query position for outside workouts, and the start date that query uses.
    public var activityAnchor: Data?
    public var activityImportStart: Date?
    /// When days of activity were last read: the next read starts 6 days before that day (the first reads 2 years).
    public var activityDaysReadAt: Date?
    /// Outside workouts deleted in Health whose row wasn't on this iPhone yet (e.g. signed out): applied when the row
    /// comes back from the cloud. Capped like `unmatchedDeletions`; use `unmatchedActivityDeletions`.
    public var unmatchedActivityDeletionsStorage: [UUID]?
    /// Settings › Apple Health › "Workouts from other apps" and "Steps & activity", on unless turned off.
    public var readsOutsideWorkoutsStorage: Bool?
    public var readsActivityDaysStorage: Bool?
    /// Health was asked for the activity types (by `enable()` or `allowActivity()`); nothing is read before.
    public var activityPermissionsAskedStorage: Bool?
    /// Today's one-time card was answered "Not now".
    public var activityCardDismissedStorage: Bool?

    public var unmatchedActivityDeletions: [UUID] {
        get { unmatchedActivityDeletionsStorage ?? [] }
        set { unmatchedActivityDeletionsStorage = newValue.isEmpty ? nil : newValue }
    }

    public var readsOutsideWorkouts: Bool {
        get { readsOutsideWorkoutsStorage ?? true }
        set { readsOutsideWorkoutsStorage = newValue ? nil : false }
    }

    public var readsActivityDays: Bool {
        get { readsActivityDaysStorage ?? true }
        set { readsActivityDaysStorage = newValue ? nil : false }
    }

    public var activityPermissionsAsked: Bool {
        get { activityPermissionsAskedStorage ?? false }
        set { activityPermissionsAskedStorage = newValue ? true : nil }
    }

    public var activityCardDismissed: Bool {
        get { activityCardDismissedStorage ?? false }
        set { activityCardDismissedStorage = newValue ? true : nil }
    }
```

After `func save(to defaults: UserDefaults) throws { … }`, add:

```swift
    /// DEBUG `-healthBeforeActivity` (UI tests): what a build from before plan 39 saved with Health on, so Today
    /// offers the one-time activity card.
    public static func saveEnabledBeforeActivity(to defaults: UserDefaults, at date: Date) throws {
        var state = HealthSyncState()
        state.enabled = true
        state.enabledAt = date
        try state.save(to: defaults)
    }
```

- [ ] **Step 6: Read them from HealthKit**

In `ios/Packages/GymHealth/Sources/GymHealth/HealthKitStore.swift`, replace `requestAuthorization()`:

```swift
    public func requestAuthorization() async throws {
        let share = Set(HealthDataType.allCases.map(Self.sampleType))
        // Workouts are read only to find the Apple Watch's copy of a GymRollins workout (plan 17).
        let read: Set<HKObjectType> = [Self.bodyMass, Self.bodyFat, Self.workout]
        try await healthStore().requestAuthorization(toShare: share, read: read)
    }
```

with:

```swift
    public func requestAuthorization() async throws {
        let share = Set(HealthDataType.allCases.map(Self.sampleType))
        // Workouts are read to find the Apple Watch's copy of a GymRollins workout (plan 17) and, with the activity
        // types, to bring in what other apps record (plan 39). The system only asks for types never asked.
        var read: Set<HKObjectType> = [Self.bodyMass, Self.bodyFat, Self.workout]
        read.formUnion(Self.activityReadTypes)
        try await healthStore().requestAuthorization(toShare: share, read: read)
    }
```

Before `// MARK: Helpers`, add:

```swift
    // MARK: Activity (plan 39)

    private static let steps = HKQuantityType(.stepCount)
    private static let heartRate = HKQuantityType(.heartRate)
    private static let exerciseTime = HKQuantityType(.appleExerciseTime)
    /// Walking/running, cycling and swimming: a workout has the one that fits its kind.
    private static let distances = [HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling),
                                    HKQuantityType(.distanceSwimming)]

    /// What the activity import reads: step count, active energy and heart rate and distance (each workout's
    /// statistics), exercise time and Activity summaries. Never in `HealthDataType`, the write list.
    static var activityReadTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [steps, heartRate, exerciseTime, energy, HKObjectType.activitySummaryType()]
        for distance in distances { types.insert(distance) }
        return types
    }

    public func outsideWorkoutChanges(since start: Date, anchor: Data?) async throws -> HealthOutsideWorkoutChanges {
        let store = try healthStore()
        let previous = try anchor.flatMap {
            try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
        }
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: nil))], anchor: previous)
        let result = try await descriptor.result(for: store)
        let newAnchor = try NSKeyedArchiver.archivedData(withRootObject: result.newAnchor, requiringSecureCoding: true)
        return HealthOutsideWorkoutChanges(added: result.addedSamples.map(outsideWorkout),
                                           deleted: result.deletedObjects.map(\.uuid), anchor: newAnchor)
    }

    private func outsideWorkout(_ workout: HKWorkout) -> HealthOutsideWorkout {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let heart = workout.statistics(for: Self.heartRate)
        let distance = Self.distances.lazy
            .compactMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }.first
        let activity = HealthActivity(
            id: workout.uuid, kind: Self.kindSlug(workout.workoutActivityType), startedAt: workout.startDate,
            endedAt: workout.endDate, durationS: workout.duration,
            kcal: workout.statistics(for: Self.energy)?.sumQuantity()?.doubleValue(for: .kilocalorie()),
            distanceM: distance,
            avgHr: heart?.averageQuantity().map { Int($0.doubleValue(for: bpm).rounded()) },
            maxHr: heart?.maximumQuantity().map { Int($0.doubleValue(for: bpm).rounded()) },
            sourceName: workout.sourceRevision.source.name,
            fromWatch: workout.sourceRevision.productType?.hasPrefix("Watch") == true
                || workout.device?.model == "Watch")
        let external = (workout.metadata?[HKMetadataKeyExternalUUID] as? String).flatMap(UUID.init(uuidString:))
        return HealthOutsideWorkout(activity: activity, externalId: external, writtenByGymRollins: isOwn(workout))
    }

    /// Written by GymRollins: the export metadata (the phone's and the watch app's), or this app's or the watch app's
    /// bundle as the source.
    private func isOwn(_ workout: HKWorkout) -> Bool {
        if workout.metadata?[Self.exportMarkerKey] != nil || workout.metadata?[WatchHealthRules.writerKey] != nil {
            return true
        }
        guard let bundleId else { return false }
        let source = workout.sourceRevision.source.bundleIdentifier
        return source == bundleId || source == "\(bundleId).watchkitapp"
    }

    /// Steps from the merged daily statistics (never summed samples: those double count iPhone + Watch), move,
    /// exercise and stand from the Activity summary. Stand is nil on a day whose summary has no stand goal (no watch).
    public func activityDays(from start: Date, through end: Date, calendar: Calendar) async throws -> [ActivityDay] {
        let store = try healthStore()
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        guard first <= last, let after = calendar.date(byAdding: .day, value: 1, to: last) else { return [] }
        let stepsQuery = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: Self.steps,
                                       predicate: HKQuery.predicateForSamples(withStart: first, end: after)),
            options: .cumulativeSum, anchorDate: first, intervalComponents: DateComponents(day: 1))
        var steps: [String: Int] = [:]
        for statistics in try await stepsQuery.result(for: store).statistics() {
            guard let sum = statistics.sumQuantity() else { continue }
            steps[ActivityDay.key(for: statistics.startDate, calendar: calendar)] =
                Int(sum.doubleValue(for: .count()).rounded())
        }
        var from = calendar.dateComponents([.era, .year, .month, .day], from: first)
        var through = calendar.dateComponents([.era, .year, .month, .day], from: last)
        from.calendar = calendar
        through.calendar = calendar
        let summaries = try await HKActivitySummaryQueryDescriptor(
            predicate: HKQuery.predicate(forActivitySummariesBetweenStart: from, end: through)).result(for: store)
        var rings: [String: HKActivitySummary] = [:]
        for summary in summaries {
            guard let date = calendar.date(from: summary.dateComponents(for: calendar)) else { continue }
            rings[ActivityDay.key(for: date, calendar: calendar)] = summary
        }
        return Set(steps.keys).union(rings.keys).sorted().map { key in
            let ring = rings[key]
            let standGoal = ring?.standHoursGoal?.doubleValue(for: .count()) ?? 0
            return ActivityDay(day: key, steps: steps[key] ?? 0,
                               moveKcal: ring?.activeEnergyBurned.doubleValue(for: .kilocalorie()) ?? 0,
                               exerciseMin: Int((ring?.appleExerciseTime.doubleValue(for: .minute()) ?? 0).rounded()),
                               standH: standGoal > 0
                                   ? ring.map { Int($0.appleStandHours.doubleValue(for: .count()).rounded()) } : nil)
        }
    }

    /// The `OutsideWorkoutKind` slug of a HealthKit workout type (plan 39); `other` for a type GymRollins doesn't name.
    public static func kindSlug(_ type: HKWorkoutActivityType) -> String {
        let kind: OutsideWorkoutKind = switch type {
        case .walking, .wheelchairWalkPace: .walking
        case .running, .wheelchairRunPace: .running
        case .cycling, .handCycling: .cycling
        case .highIntensityIntervalTraining: .hiit
        case .yoga: .yoga
        case .swimming: .swimming
        case .traditionalStrengthTraining: .traditionalStrength
        case .functionalStrengthTraining: .functionalStrength
        case .elliptical: .elliptical
        case .rowing: .rowing
        case .hiking: .hiking
        case .cardioDance, .socialDance, .barre: .dance
        case .coreTraining: .core
        case .pilates: .pilates
        case .cooldown, .preparationAndRecovery: .cooldown
        case .stairClimbing, .stairs, .stepTraining: .stairs
        case .jumpRope: .jumpRope
        case .mixedCardio: .mixedCardio
        case .crossTraining: .crossTraining
        case .flexibility: .flexibility
        case .mindAndBody, .taiChi: .mindAndBody
        case .tennis: .tennis
        case .soccer: .soccer
        case .basketball: .basketball
        case .boxing: .boxing
        case .kickboxing: .kickboxing
        case .martialArts: .martialArts
        case .climbing: .climbing
        case .downhillSkiing, .crossCountrySkiing: .skiing
        case .snowboarding: .snowboarding
        case .golf: .golf
        default: .other
        }
        return kind.rawValue
    }

```

- [ ] **Step 7: Run the tests**

Run: `swift test --package-path ios/Packages/GymHealth --filter 'FakeActivityStoreTests|HealthActivityStateTests'`
Expected: 5 tests pass.

Run: `swift test --package-path ios/Packages/GymHealth`
Expected: everything passes. Nothing calls the new reads yet.

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/HealthKitKindTests`
Expected: both tests pass (the first with 12 arguments), and the app builds with the new `HealthKitStore`.

- [ ] **Step 8: Commit**

```bash
git add ios/Packages/GymHealth/Sources/GymHealth/HealthStore.swift ios/Packages/GymHealth/Sources/GymHealth/FakeHealthStore.swift ios/Packages/GymHealth/Sources/GymHealth/HealthSyncState.swift ios/Packages/GymHealth/Sources/GymHealth/HealthKitStore.swift ios/Packages/GymHealth/Tests/GymHealthTests/FakeActivityStoreTests.swift ios/Packages/GymHealth/Tests/GymHealthTests/HealthActivityStateTests.swift ios/GymRollinsTests/HealthKitKindTests.swift
git commit -m "feat(health): read outside workouts and days of activity through the HealthStore seam"
```

---

### Task 8: HealthSync imports outside workouts

**Files:**
- Modify: `ios/Packages/GymHealth/Sources/GymHealth/HealthSync.swift`
- Create: `ios/Packages/GymHealth/Sources/GymHealth/HealthSync+Activity.swift`
- Modify: `ios/Packages/GymHealth/Tests/GymHealthTests/HealthSyncTests.swift` (`HealthFixture`)
- Modify: `ios/GymRollins/App/AppEnvironment.swift` and `ios/GymRollins/App/AppEnvironment+Health.swift`. `HealthSync.init` takes the repository, so the app must pass it.
- Test: `ios/Packages/GymHealth/Tests/GymHealthTests/HealthActivityImportTests.swift`

- [ ] **Step 1: Give the fixture the repository**

In `ios/Packages/GymHealth/Tests/GymHealthTests/HealthSyncTests.swift`, `HealthFixture`:
- after `var bodyChanges = 0`, add `var activityChanges = 0`;
- replace `makeSync()`:

```swift
    func makeSync() -> HealthSync {
        HealthSync(store: store, workouts: workouts, body: body, defaults: defaults,
                   estimate: { workout in
                       CalorieEstimator.estimate(workout: workout, exercise: { _ in nil }, bodyWeightKg: 80,
                                                 table: HealthFixture.table)
                   },
                   now: { [unowned self] in now }, onBodyChanged: { [unowned self] in bodyChanges += 1 })
    }
```

with:

```swift
    var activities: ActivityRepository {
        ActivityRepository(context: container.mainContext, now: { [unowned self] in now })
    }

    func makeSync() -> HealthSync {
        let sync = HealthSync(store: store, workouts: workouts, body: body, activities: activities, defaults: defaults,
                              estimate: { workout in
                                  CalorieEstimator.estimate(workout: workout, exercise: { _ in nil }, bodyWeightKg: 80,
                                                            table: HealthFixture.table)
                              },
                              now: { [unowned self] in now }, onBodyChanged: { [unowned self] in bodyChanges += 1 })
        sync.onActivityChanged = { [unowned self] in activityChanges += 1 }
        return sync
    }
```

- [ ] **Step 2: Write the failing tests**

Create `ios/Packages/GymHealth/Tests/GymHealthTests/HealthActivityImportTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymHealth

/// Plan 39: outside workouts from Apple Health. Every workout GymRollins didn't write comes in (two years back the
/// first time), deletions in Health tombstone the row, and the switch and the cloud gate stop the import.
@MainActor
@Suite struct HealthActivityImportTests {
    private let day: TimeInterval = 86_400

    private func outside(_ fx: HealthFixture, daysAgo: Double, kind: String = "walking", externalId: UUID? = nil,
                         ours: Bool = false) -> HealthOutsideWorkout {
        let start = fx.now.addingTimeInterval(-daysAgo * day)
        return HealthOutsideWorkout(activity: HealthActivity(
            id: UUID(), kind: kind, startedAt: start, endedAt: start.addingTimeInterval(2_700), durationS: 2_700,
            kcal: 180, sourceName: "Apple Watch", fromWatch: true), externalId: externalId, writtenByGymRollins: ours)
    }

    @Test func enablingImportsTwoYearsOfOtherAppsWorkouts() async throws {
        let fx = try HealthFixture()
        let recent = outside(fx, daysAgo: 3), old = outside(fx, daysAgo: 800)
        fx.store = FakeHealthStore(outsideWorkouts: [recent, old])
        let sync = fx.makeSync()
        _ = await sync.enable()
        #expect(try fx.activities.activities(since: nil) == [recent.activity])
        #expect(fx.activityChanges == 1)
        #expect(sync.state.activityAnchor != nil)
        let rows = try SyncStore(context: fx.container.mainContext, defaults: fx.defaults).dirtyHealthActivities()
        #expect(rows.first?.clientUpdatedAt == recent.activity.endedAt, "the workout's own end is its edit time")
    }

    @Test func gymRollinsOwnWorkoutsNeverComeIn() async throws {
        let fx = try HealthFixture()
        let exported = try fx.finishWorkout(startOffset: -2 * day)
        let deleted = try fx.finishWorkout(startOffset: -4 * day)
        try fx.workouts.delete(deleted.id)
        let marked = outside(fx, daysAgo: 1, kind: "traditional_strength", ours: true)
        let byId = outside(fx, daysAgo: 2, kind: "traditional_strength", externalId: exported.id)
        let byDeletedId = outside(fx, daysAgo: 4, kind: "traditional_strength", externalId: deleted.id)
        let otherApps = outside(fx, daysAgo: 5, externalId: UUID()) // another app's own external id
        fx.store = FakeHealthStore(outsideWorkouts: [marked, byId, byDeletedId, otherApps])
        _ = await fx.makeSync().enable()
        #expect(try fx.activities.activities(since: nil).map(\.id) == [otherApps.activity.id])
    }

    @Test func aWorkoutOutsideTheLimitsIsSkipped() async throws {
        let fx = try HealthFixture()
        let start = fx.now.addingTimeInterval(-day)
        let broken = HealthOutsideWorkout(activity: HealthActivity(
            id: UUID(), kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(600), durationS: 600,
            avgHr: 300, sourceName: "Old App"))
        fx.store = FakeHealthStore(outsideWorkouts: [broken, outside(fx, daysAgo: 2)])
        _ = await fx.makeSync().enable()
        #expect(try fx.activities.activities(since: nil).count == 1)
    }

    @Test func aDeletionInHealthLeavesATombstoneThatSyncs() async throws {
        let fx = try HealthFixture()
        let walk = outside(fx, daysAgo: 1)
        fx.store = FakeHealthStore(outsideWorkouts: [walk])
        let sync = fx.makeSync()
        _ = await sync.enable()
        await fx.store.deleteOutsideWorkout(walk.activity.id)
        fx.advance()
        await sync.importActivity()
        #expect(try fx.activities.activity(walk.activity.id) == nil)
        #expect(try fx.activities.hasRecord(id: walk.activity.id))
        let rows = try SyncStore(context: fx.container.mainContext, defaults: fx.defaults).dirtyHealthActivities()
        #expect(rows.first?.deletedAt == fx.now)
        #expect(fx.activityChanges == 2)
    }

    @Test func aDeletionForARowNotHereYetWaitsForItToComeFromTheCloud() async throws {
        let fx = try HealthFixture()
        let walk = outside(fx, daysAgo: 1)
        fx.store = FakeHealthStore(outsideWorkouts: [walk])
        let sync = fx.makeSync()
        _ = await sync.enable()
        try fx.wipeLocalData() // signed out: the row is gone from this iPhone, not deleted
        await fx.store.deleteOutsideWorkout(walk.activity.id)
        await sync.importActivity()
        #expect(sync.state.unmatchedActivityDeletions == [walk.activity.id])

        let store = SyncStore(context: fx.container.mainContext, defaults: fx.defaults)
        try store.applyRemote(healthActivities: [SyncRow(value: walk.activity, clientUpdatedAt: walk.activity.endedAt,
                                                         serverUpdatedAt: fx.now)])
        fx.advance()
        await sync.importActivity()
        #expect(try fx.activities.activity(walk.activity.id) == nil, "deleted once it came back")
        #expect(sync.state.unmatchedActivityDeletions.isEmpty)
    }

    @Test func turningWorkoutsFromOtherAppsOffStopsTheImportAndOnResumesIt() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        sync.setReadsOutsideWorkouts(false)
        let walk = outside(fx, daysAgo: 1)
        await fx.store.addOutsideWorkout(walk)
        await sync.importActivity()
        #expect(try fx.activities.activities(since: nil).isEmpty)

        sync.setReadsOutsideWorkouts(true)
        await sync.importActivity()
        #expect(try fx.activities.activities(since: nil) == [walk.activity])
    }

    @Test func nothingIsReadWhileTheFirstCloudPullIsPending() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(outsideWorkouts: [outside(fx, daysAgo: 1)])
        let sync = fx.makeSync()
        var pulled = false
        sync.canImportActivity = { pulled }
        _ = await sync.enable()
        #expect(try fx.activities.activities(since: nil).isEmpty)
        #expect(sync.state.activityAnchor == nil)
        pulled = true
        await sync.importActivity()
        #expect(try fx.activities.activities(since: nil).count == 1)
    }

    @Test func aResetDuringTheReadWritesNothing() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        await fx.store.addOutsideWorkout(outside(fx, daysAgo: 1))
        await fx.store.setGate(true)
        let run = Task { await sync.importActivity() }
        while await fx.store.parkedCount == 0 { await Task.yield() }
        sync.reset()
        await fx.store.setGate(false)
        await run.value
        #expect(try fx.activities.activities(since: nil).isEmpty)
        #expect(sync.state.activityAnchor == nil)
    }

    @Test func aFailedReadSaysSoAndTheNextOneRecovers() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        await fx.store.addOutsideWorkout(outside(fx, daysAgo: 1))
        await fx.store.setFailReads(true)
        await sync.importActivity()
        #expect(sync.lastError == "Couldn't read your activity from Apple Health. We'll try again next time.")
        await fx.store.setFailReads(false)
        await sync.importActivity()
        #expect(try fx.activities.activities(since: nil).count == 1)
    }
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `swift test --package-path ios/Packages/GymHealth --filter HealthActivityImportTests`
Expected: the build fails with errors like these:
- `extra argument 'activities' in call`;
- `value of type 'HealthSync' has no member 'onActivityChanged'`;
- `… no member 'importActivity'`.

- [ ] **Step 4: Wire the repository and the run into `HealthSync`**

In `ios/Packages/GymHealth/Sources/GymHealth/HealthSync.swift`:
- After `@ObservationIgnored let body: BodyRepository`, add:

```swift
    @ObservationIgnored let activities: ActivityRepository
```

- After `@ObservationIgnored public var onBodyChanged: @MainActor () -> Void`, add:

```swift
    /// Outside workouts or days of activity were added, changed or deleted by an import (plan 39).
    @ObservationIgnored public var onActivityChanged: @MainActor () -> Void = {}
```

- Replace the start of `init`:

```swift
    public init(store: any HealthStore, workouts: WorkoutRepository, body: BodyRepository, defaults: UserDefaults,
                estimate: @escaping @MainActor (Workout) -> CalorieEstimate?, now: @escaping () -> Date = Date.init,
                calendar: Calendar = .current, onBodyChanged: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.workouts = workouts
        self.body = body
```

with:

```swift
    public init(store: any HealthStore, workouts: WorkoutRepository, body: BodyRepository,
                activities: ActivityRepository, defaults: UserDefaults,
                estimate: @escaping @MainActor (Workout) -> CalorieEstimate?, now: @escaping () -> Date = Date.init,
                calendar: Calendar = .current, onBodyChanged: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.workouts = workouts
        self.body = body
        self.activities = activities
```

- After `@ObservationIgnored public var canImport: @MainActor () -> Bool = { true }`, add:

```swift

    /// The same for outside workouts and days of activity (plan 39): false while their first cloud pull is pending.
    @ObservationIgnored public var canImportActivity: @MainActor () -> Bool = { true }
```

- In `enable()`, replace the `update { … }` block:

```swift
        update {
            $0.enabled = true
            $0.enabledAt = $0.enabledAt ?? now()
            $0.ledgerOwner = $0.ledgerOwner ?? owner
        }
```

with:

```swift
        update {
            $0.enabled = true
            $0.enabledAt = $0.enabledAt ?? now()
            $0.ledgerOwner = $0.ledgerOwner ?? owner
            $0.activityPermissionsAsked = true // the request covers the activity types (plan 39)
        }
```

- Replace `sync()`:

```swift
    public func sync() async {
        await serialized { [self] in
            await runImport()
            await runExport()
        }
    }
```

with:

```swift
    public func sync() async {
        await serialized { [self] in
            await runImport()
            await runActivityImport()
            await runExport()
        }
    }
```

- After `importBody()`, add:

```swift

    /// Outside workouts and days of activity only (plan 39), e.g. once the first cloud pull unblocks them.
    public func importActivity() async {
        await serialized { [self] in await runActivityImport() }
    }
```

- [ ] **Step 5: Write the import**

Create `ios/Packages/GymHealth/Sources/GymHealth/HealthSync+Activity.swift`. Task 9 adds days and the ask to this file:

```swift
import Foundation
import GymCore
import GymData

/// Import (plan 39): outside workouts, the workouts other apps saved to Health, incrementally from an anchored query,
/// deletions included. Nothing is read before the activity types were asked for (`activityPermissionsAsked`), while
/// `canImportActivity` says no, or while "Workouts from other apps" is off.
extension HealthSync {
    static let maxUnmatchedActivityDeletions = 1_000

    func runActivityImport() async {
        guard isEnabled, state.activityPermissionsAsked, canImportActivity() else { return }
        let run = generation
        isSyncing = true
        defer { isSyncing = false }
        var changed = false
        do {
            if state.readsOutsideWorkouts { changed = try await importOutsideWorkouts(run: run) }
        } catch {
            if run == generation {
                Self.log.error("Health activity import failed: \(error.localizedDescription, privacy: .public)")
                lastError = "Couldn't read your activity from Apple Health. We'll try again next time."
            }
        }
        if changed, run == generation { onActivityChanged() }
    }

    /// Applies one anchored batch: deletions first (earlier ones whose row has since come from the cloud too), then
    /// new outside workouts. True when a row changed.
    private func importOutsideWorkouts(run: Int) async throws -> Bool {
        let start = state.activityImportStart ?? now().addingTimeInterval(-Self.importWindow)
        let changes = try await store.outsideWorkoutChanges(since: start, anchor: state.activityAnchor)
        guard run == generation, isEnabled, state.readsOutsideWorkouts else { return false }
        var changed = false
        var unmatched: [UUID] = []
        for id in state.unmatchedActivityDeletions + changes.deleted {
            if try activities.delete(id) {
                changed = true
            } else if try !activities.hasRecord(id: id) {
                unmatched.append(id)
            }
        }
        for item in changes.added {
            guard try isOutside(item), DomainLimits.healthActivityViolation(item.activity) == nil else { continue }
            // The workout's own end as the edit time, so a newer deletion from another device still wins.
            if try activities.add(item.activity, editedAt: min(item.activity.endedAt, now())) { changed = true }
        }
        let kept = Array(unmatched.suffix(Self.maxUnmatchedActivityDeletions))
        update {
            $0.activityAnchor = changes.anchor
            $0.activityImportStart = start
            $0.unmatchedActivityDeletions = kept
        }
        return changed
    }

    /// Not GymRollins' own: no export metadata or GymRollins bundle (the store tells), and no external id that is a
    /// GymRollins workout here, live or deleted.
    private func isOutside(_ item: HealthOutsideWorkout) throws -> Bool {
        guard !item.writtenByGymRollins else { return false }
        guard let id = item.externalId else { return true }
        return try workouts.workout(id) == nil && !workouts.isDeleted(id)
    }

    /// "Workouts from other apps": off stops the import and hides them in the app; nothing stored is deleted.
    public func setReadsOutsideWorkouts(_ on: Bool) {
        update { $0.readsOutsideWorkouts = on }
    }
}
```

- [ ] **Step 6: Pass the repository from the app**

In `ios/GymRollins/App/AppEnvironment.swift`:
- After `let body: BodyRepository`, add:

```swift
    /// Outside workouts and days of activity read from Apple Health (plan 39).
    let activities: ActivityRepository
```

- After `self.body = BodyRepository(context: context, now: now)`, add:

```swift
        self.activities = ActivityRepository(context: context, now: now)
```

- Replace:

```swift
        self.health = Self.makeHealth(options: options, defaults: defaults, workouts: workouts, body: body,
                                      calories: calories, now: now)
```

with:

```swift
        self.health = Self.makeHealth(options: options, defaults: defaults, workouts: workouts, body: body,
                                      activities: activities, calories: calories, now: now)
```

In `ios/GymRollins/App/AppEnvironment+Health.swift`, replace `makeHealth`:

```swift
    static func makeHealth(options: LaunchOptions, defaults: UserDefaults, workouts: WorkoutRepository,
                           body: BodyRepository, calories: CalorieService, now: @escaping () -> Date) -> HealthSync {
        let (store, healthDefaults) = healthBackend(options: options, defaults: defaults, now: now)
        return HealthSync(store: store, workouts: workouts, body: body, defaults: healthDefaults,
                          estimate: { calories.estimate($0) }, now: now)
    }
```

with:

```swift
    static func makeHealth(options: LaunchOptions, defaults: UserDefaults, workouts: WorkoutRepository,
                           body: BodyRepository, activities: ActivityRepository, calories: CalorieService,
                           now: @escaping () -> Date) -> HealthSync {
        let (store, healthDefaults) = healthBackend(options: options, defaults: defaults, now: now)
        return HealthSync(store: store, workouts: workouts, body: body, activities: activities,
                          defaults: healthDefaults, estimate: { calories.estimate($0) }, now: now)
    }
```

- [ ] **Step 7: Run the tests**

Run: `swift test --package-path ios/Packages/GymHealth --filter HealthActivityImportTests`
Expected: 9 tests pass.

Run: `swift test --package-path ios/Packages/GymHealth`
Expected: everything passes. The existing export and weigh-in tests are untouched: their fake store has no outside workouts.

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/CaloriesAndHealthTests`
Expected: all pass, and the app builds.

- [ ] **Step 8: Commit**

```bash
git add ios/Packages/GymHealth ios/GymRollins/App/AppEnvironment.swift ios/GymRollins/App/AppEnvironment+Health.swift
git commit -m "feat(health): import workouts other apps saved to Apple Health"
```

---

### Task 9: Days of activity, and asking for the new types

**Files:**
- Modify: `ios/Packages/GymHealth/Sources/GymHealth/HealthSync+Activity.swift`
- Test: `ios/Packages/GymHealth/Tests/GymHealthTests/HealthActivityDaysTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/Packages/GymHealth/Tests/GymHealthTests/HealthActivityDaysTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymHealth

/// Plan 39: days of activity (two years the first time, then from 6 days before the last read, written only when a
/// value changed), and asking for the activity types when Health was turned on before plan 39.
@MainActor
@Suite struct HealthActivityDaysTests {
    private let calendar = Calendar.current

    private func key(_ fx: HealthFixture, daysAgo: Int) -> String {
        ActivityDay.key(for: calendar.date(byAdding: .day, value: -daysAgo, to: fx.now)!, calendar: calendar)
    }

    private func day(_ fx: HealthFixture, daysAgo: Int, steps: Int) -> ActivityDay {
        ActivityDay(day: key(fx, daysAgo: daysAgo), steps: steps, moveKcal: 300, exerciseMin: 30, standH: 10)
    }

    @Test func theFirstReadCoversTwoYearsAndLaterOnesTheLastWeek() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        let first = try #require(await fx.store.dayReads.first)
        #expect(first.from == calendar.startOfDay(for: fx.now.addingTimeInterval(-HealthSync.importWindow)))
        #expect(first.through == calendar.startOfDay(for: fx.now))

        let enabledAt = fx.now
        fx.advance(86_400)
        await sync.importActivity()
        let next = try #require(await fx.store.dayReads.last)
        #expect(next.from == calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: enabledAt)))
        #expect(next.through == calendar.startOfDay(for: fx.now))
    }

    @Test func onlyNewOrChangedDaysAreWrittenAgain() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(days: [day(fx, daysAgo: 1, steps: 8_000), day(fx, daysAgo: 20, steps: 5_000)])
        let sync = fx.makeSync()
        _ = await sync.enable()
        let store = SyncStore(context: fx.container.mainContext, defaults: fx.defaults)
        for row in try store.dirtyActivityDays() {
            try store.markSynced(.activityDays, id: row.value.day, clientUpdatedAt: row.clientUpdatedAt,
                                 serverUpdatedAt: fx.now)
        }

        await fx.store.setDay(day(fx, daysAgo: 1, steps: 9_000))   // late Apple Watch data
        await fx.store.setDay(day(fx, daysAgo: 20, steps: 6_000))  // too old for the weekly re-read
        await fx.store.setDay(day(fx, daysAgo: 0, steps: 1_200))   // today's first data
        fx.advance(3_600)
        await sync.importActivity()

        #expect(try store.dirtyActivityDays().map(\.value.day) == [key(fx, daysAgo: 1), key(fx, daysAgo: 0)])
        let old = try fx.activities.days(from: key(fx, daysAgo: 20), through: key(fx, daysAgo: 20))
        #expect(old.map(\.steps) == [5_000])
    }

    @Test func aDayOutsideTheLimitsIsSkipped() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(days: [day(fx, daysAgo: 1, steps: 250_000), day(fx, daysAgo: 2, steps: 4_000)])
        _ = await fx.makeSync().enable()
        #expect(try fx.activities.days(from: "2000-01-01", through: "2100-01-01").map(\.steps) == [4_000])
    }

    @Test func turningStepsOffStopsTheReadAndKeepsWhatIsStored() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(days: [day(fx, daysAgo: 1, steps: 4_000)])
        let sync = fx.makeSync()
        _ = await sync.enable()
        sync.setReadsActivityDays(false)
        let reads = await fx.store.dayReads.count
        await sync.importActivity()
        #expect(await fx.store.dayReads.count == reads)
        #expect(try fx.activities.days(from: "2000-01-01", through: "2100-01-01").count == 1)
    }

    @Test func enablingAsksForTheActivityTypesOnce() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        #expect(await fx.store.authorizationRequests == 1)
        #expect(sync.state.activityPermissionsAsked)
        #expect(!sync.needsActivityPermission && !sync.showsActivityCard)
    }

    @Test func healthTurnedOnBeforePlan39ReadsNoActivityUntilAllowed() async throws {
        let fx = try HealthFixture()
        try HealthSyncState.saveEnabledBeforeActivity(to: fx.defaults, at: fx.now)
        fx.store = FakeHealthStore(days: [day(fx, daysAgo: 1, steps: 4_000)])
        let sync = fx.makeSync()
        await sync.sync()
        #expect(sync.isEnabled)
        #expect(await fx.store.dayReads.isEmpty)
        #expect(sync.needsActivityPermission && sync.showsActivityCard)

        sync.dismissActivityCard()
        #expect(!sync.showsActivityCard && sync.needsActivityPermission, "Settings still asks")

        #expect(await sync.allowActivity())
        #expect(await fx.store.authorizationRequests == 1)
        #expect(!sync.needsActivityPermission)
        #expect(try fx.activities.days(from: "2000-01-01", through: "2100-01-01").count == 1)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path ios/Packages/GymHealth --filter HealthActivityDaysTests`
Expected: the build fails with `value of type 'HealthSync' has no member 'setReadsActivityDays'`, and the same for `needsActivityPermission`, `showsActivityCard`, `dismissActivityCard` and `allowActivity`.

- [ ] **Step 3: Read the days, ask, and add the second switch**

Replace the whole of `ios/Packages/GymHealth/Sources/GymHealth/HealthSync+Activity.swift` with:

```swift
import Foundation
import GymCore
import GymData

/// Import (plan 39): outside workouts (workouts other apps saved to Health) and days of activity. Outside workouts come
/// incrementally from an anchored query, deletions included; days are re-read from 6 days before the last read and
/// written only when a value changed. Nothing is read before the activity types were asked for
/// (`activityPermissionsAsked`), while `canImportActivity` says no, or for a kind whose switch is off.
extension HealthSync {
    /// Days re-read on every sync, counting today: Apple Watch data lands late.
    static let activityRefreshDays = 7
    static let maxUnmatchedActivityDeletions = 1_000

    func runActivityImport() async {
        guard isEnabled, state.activityPermissionsAsked, canImportActivity() else { return }
        let run = generation
        isSyncing = true
        defer { isSyncing = false }
        var changed = false
        do {
            if state.readsOutsideWorkouts { changed = try await importOutsideWorkouts(run: run) }
            guard run == generation, isEnabled else { return }
            if state.readsActivityDays { changed = try await importActivityDays(run: run) || changed }
        } catch {
            if run == generation {
                Self.log.error("Health activity import failed: \(error.localizedDescription, privacy: .public)")
                lastError = "Couldn't read your activity from Apple Health. We'll try again next time."
            }
        }
        if changed, run == generation { onActivityChanged() }
    }

    /// Applies one anchored batch: deletions first (earlier ones whose row has since come from the cloud too), then
    /// new outside workouts. True when a row changed.
    private func importOutsideWorkouts(run: Int) async throws -> Bool {
        let start = state.activityImportStart ?? now().addingTimeInterval(-Self.importWindow)
        let changes = try await store.outsideWorkoutChanges(since: start, anchor: state.activityAnchor)
        guard run == generation, isEnabled, state.readsOutsideWorkouts else { return false }
        var changed = false
        var unmatched: [UUID] = []
        for id in state.unmatchedActivityDeletions + changes.deleted {
            if try activities.delete(id) {
                changed = true
            } else if try !activities.hasRecord(id: id) {
                unmatched.append(id)
            }
        }
        for item in changes.added {
            guard try isOutside(item), DomainLimits.healthActivityViolation(item.activity) == nil else { continue }
            // The workout's own end as the edit time, so a newer deletion from another device still wins.
            if try activities.add(item.activity, editedAt: min(item.activity.endedAt, now())) { changed = true }
        }
        let kept = Array(unmatched.suffix(Self.maxUnmatchedActivityDeletions))
        update {
            $0.activityAnchor = changes.anchor
            $0.activityImportStart = start
            $0.unmatchedActivityDeletions = kept
        }
        return changed
    }

    /// Not GymRollins' own: no export metadata or GymRollins bundle (the store tells), and no external id that is a
    /// GymRollins workout here, live or deleted.
    private func isOutside(_ item: HealthOutsideWorkout) throws -> Bool {
        guard !item.writtenByGymRollins else { return false }
        guard let id = item.externalId else { return true }
        return try workouts.workout(id) == nil && !workouts.isDeleted(id)
    }

    /// Reads from 6 days before the last read's day (two years back the first time) through today, and writes the
    /// days that are new or changed. True when one was written.
    private func importActivityDays(run: Int) async throws -> Bool {
        let time = now()
        let today = calendar.startOfDay(for: time)
        let earliest = calendar.startOfDay(for: time.addingTimeInterval(-Self.importWindow))
        let resume = state.activityDaysReadAt.flatMap {
            calendar.date(byAdding: .day, value: -(Self.activityRefreshDays - 1), to: calendar.startOfDay(for: $0))
        }
        let days = try await store.activityDays(from: max(resume ?? earliest, earliest), through: today,
                                                calendar: calendar)
        guard run == generation, isEnabled, state.readsActivityDays else { return false }
        var changed = false
        for day in days where DomainLimits.activityDayViolation(day) == nil {
            if try activities.save(day: day) { changed = true }
        }
        update { $0.activityDaysReadAt = time }
        return changed
    }

    // MARK: Asking and the switches

    /// Health is on and the activity types were never asked for (Health was turned on by a build before plan 39).
    public var needsActivityPermission: Bool { isEnabled && !state.activityPermissionsAsked }

    /// Today's one-time "Bring in your Apple Watch activity" card.
    public var showsActivityCard: Bool { needsActivityPermission && !state.activityCardDismissed }

    /// Asks Health for the activity types (the system asks only for types never asked), then imports and exports.
    /// False (with `lastError`) when asking failed.
    @discardableResult
    public func allowActivity() async -> Bool {
        guard isEnabled else { return false }
        let started = generation
        do {
            try await store.requestAuthorization()
        } catch {
            Self.log.error("Health activity authorization failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't ask for Apple Health access. Try again."
            return false
        }
        guard started == generation else { return false }
        update { $0.activityPermissionsAsked = true }
        lastError = nil
        await sync()
        return true
    }

    /// "Not now" on Today's card: it doesn't come back (Settings › Apple Health still offers the ask).
    public func dismissActivityCard() {
        update { $0.activityCardDismissed = true }
    }

    /// "Workouts from other apps": off stops the import and hides them in the app; nothing stored is deleted.
    public func setReadsOutsideWorkouts(_ on: Bool) {
        update { $0.readsOutsideWorkouts = on }
    }

    /// "Steps & activity": the same for days of activity.
    public func setReadsActivityDays(_ on: Bool) {
        update { $0.readsActivityDays = on }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path ios/Packages/GymHealth --filter 'HealthActivityDaysTests|HealthActivityImportTests'`
Expected: 15 tests pass.

Run: `swift test --package-path ios/Packages/GymHealth`
Expected: everything passes.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/GymHealth/Sources/GymHealth/HealthSync+Activity.swift ios/Packages/GymHealth/Tests/GymHealthTests/HealthActivityDaysTests.swift
git commit -m "feat(health): read days of activity, and ask for the activity types once"
```

---

## Phase D: Server

### Task 10: Migration 0013: the two tables sync, with caps, and the profile switch

**Files:**
- Create: `server/migrations/0013_health_activities.sql`
- Modify: `server/src/sync/entities.ts`
- Modify: `server/src/sync/caps.ts`
- Modify (tests): `server/test/samples.ts`, `server/test/account.test.ts`, `server/test/cap-fixtures.ts`, `server/test/account-caps.test.ts`, `server/test/domain-limits-drift.test.ts`, `server/test/schema.test.ts`
- Create (tests): `server/test/sync-activity.test.ts`, `server/test/health-rows.test.ts`

`test/sync-rows.test.ts` runs its generic rules on every entity in `SAMPLES`. Adding the two samples puts both tables through:
- the round trip;
- last-write-wins;
- accounts kept apart (both conflicts include `user_id`, so two accounts may store the same HealthKit id);
- CHECK refusals;
- wrong types.

- [ ] **Step 1: Write the failing tests**

In `server/test/samples.ts`:
- In `SAMPLES.profile`, replace `sex: null, birth_year: null, client_updated_at: T1,` with:

```ts
    mcp_read_activity: false, sex: null, birth_year: null, client_updated_at: T1,
```

- After `export const SAMPLE_GYM_ID = …`, add:

```ts
/** A new day for each activity-days sample, so one test's samples never share a key: 2026-01-01, 2026-01-02, … */
let sampleDays = 0
const nextDay = (): string => new Date(Date.UTC(2026, 0, 1 + sampleDays++)).toISOString().slice(0, 10)
```

- In `SAMPLES`, after the `bodyweight` sample, add:

```ts
  // an outside workout and a day of activity as HealthActivityDTO and ActivityDayDTO encode them (plan 39)
  'health-activities': () => ({
    id: appUUID(), kind: 'walking', started_at: '2026-11-06T07:00:00.000000Z', ended_at: '2026-11-06T07:45:00.000000Z',
    duration_s: 2700, kcal: 180, distance_m: 3400, avg_hr: 102, max_hr: 121, source_name: 'Apple Watch',
    from_watch: true, client_updated_at: T1, deleted_at: null,
  }),
  'activity-days': () => ({
    day: nextDay(), steps: 8532, move_kcal: 410, exercise_min: 34, stand_h: null, client_updated_at: T1,
  }),
```

- In `BAD`, add `'health-activities': { avg_hr: 300 },` and `'activity-days': { steps: 200001 },`.
- In `KEY`, add:

```ts
  'health-activities': (row) => String(row.id).toLowerCase(),
  'activity-days': (row) => String(row.day),
```

In `server/test/account.test.ts`, `OWNED`: after `['gym_unblocks', 'user_id'], ['app_admins', 'user_id'],`, add:

```ts
  ['health_activities', 'user_id'], ['activity_days', 'user_id'], ['health_rows', 'user_id'],
```

In `server/test/cap-fixtures.ts`:
- After the `CountedTable` type, add:

```ts
/** Plan 39's tables, counted in health_rows (migrations/0013_health_activities.sql). */
export type HealthTable = 'health_activities' | 'activity_days'
```

- Change `FILL`'s type to `Readonly<Record<CappedTable | HealthTable, { readonly columns: string; readonly values: string }>>`. After its `gym_equipment` entry, add:

```ts
  health_activities: {
    columns: 'user_id, id, kind, started_at, ended_at, duration_s, source_name, from_watch, client_updated_at, ' +
      'updated_at, deleted_at',
    values: `?1, value, 'walking', ?3, ?3, 600, 'Seeded', 0, ?3, ?3, ${HALF_DELETED}`,
  },
  // One day per row from 2000-01-01, far from the samples' days (2026). Days are never deleted.
  activity_days: {
    columns: 'user_id, day, steps, move_kcal, exercise_min, client_updated_at, updated_at',
    values: "?1, date('2000-01-01', '+' || key || ' days'), 1000, 100, 10, ?3, ?3",
  },
```

- Change the three signatures:
  - `newKey(table: CappedTable)` becomes `newKey(table: CappedTable | HealthTable)`;
  - `seedRows(table: CappedTable, …)` becomes `seedRows(table: CappedTable | HealthTable, …)`;
  - `countOf(table: CountedTable, …)` becomes `countOf(table: CountedTable | HealthTable, …)`.
- In `countOf`, read the count from its own table. Replace:

```ts
      '(SELECT n FROM account_rows WHERE user_id = ?1 AND tbl = ?2) AS kept',
```

with:

```ts
      `(SELECT n FROM ${COUNTER[table] ?? 'account_rows'} WHERE user_id = ?1 AND tbl = ?2) AS kept`,
```

and, above `countOf`, next to `OWNER`, add:

```ts
/** The table that keeps each count: account_rows (plan 31), or health_rows for plan 39's tables. */
const COUNTER: Readonly<Record<string, string>> = { health_activities: 'health_rows', activity_days: 'health_rows' }
```

In `server/test/account-caps.test.ts`:
- Import `type HealthTable` from `./cap-fixtures.ts` next to `type CappedTable`.
- In "the words", replace the expected key list with:

```ts
    expect(Object.keys(ACCOUNT_CAPS).sort()).toEqual([
      'too_many_activity_days', 'too_many_body_weights', 'too_many_custom_exercises', 'too_many_exercise_prefs',
      'too_many_gyms_total', 'too_many_health_activities', 'too_many_listings_total', 'too_many_logged_exercises',
      'too_many_logged_sets', 'too_many_pending_proposals', 'too_many_proposals', 'too_many_routines',
      'too_many_workouts',
    ])
```

- Replace `interface Synced`, `SYNCED` and `storedEdit` with this. The day's key is its `day`, and every table is per account:

```ts
interface Synced {
  readonly entity: string
  readonly table: CappedTable | HealthTable
  /** The column KEY's value is in. */
  readonly key: 'id' | 'day'
  readonly max: number
  readonly code: string
}

const SYNCED: Synced[] = [
  {
    entity: 'bodyweight', table: 'bodyweight', key: 'id', max: DomainLimits.bodyweightsMax,
    code: 'too_many_body_weights',
  },
  { entity: 'routines', table: 'routines', key: 'id', max: DomainLimits.routinesMax, code: 'too_many_routines' },
  {
    entity: 'custom-exercises', table: 'custom_exercises', key: 'id', max: DomainLimits.customExercisesMax,
    code: 'too_many_custom_exercises',
  },
  {
    entity: 'health-activities', table: 'health_activities', key: 'id', max: DomainLimits.healthActivitiesMax,
    code: 'too_many_health_activities',
  },
  {
    entity: 'activity-days', table: 'activity_days', key: 'day', max: DomainLimits.activityDaysMax,
    code: 'too_many_activity_days',
  },
]

describe.each(SYNCED)('$entity', ({ entity, table, key, max, code }) => {
  const fresh = () => SAMPLES[entity]()

  /** The stored row's edit time, or undefined when the row isn't stored. */
  async function storedEdit(row: Row, userId: string): Promise<string | undefined> {
    const stored = await env.DB.prepare(`SELECT client_updated_at FROM ${table} WHERE ${key} = ?1 AND user_id = ?2`)
      .bind(KEY[entity](row, userId), userId).first<{ client_updated_at: string }>()
    return stored?.client_updated_at
  }
```

  The rest of that `describe.each` block stays as it is. On `activity-days`, its deletion and revival steps send a `deleted_at` that the table doesn't have, and the push ignores it. They still check that an edit at the cap goes through.

In `server/test/domain-limits-drift.test.ts`:
- Add `import activityMigration from '../migrations/0013_health_activities.sql?raw'` after the `accountCaps` import.
- After `SCHEMA_CHECKS`, add:

```ts
/** The CHECK text in 0013_health_activities.sql that enforces each activity limit. */
const ACTIVITY_CHECKS = [
  `length(kind) BETWEEN 1 AND ${L.activityTextMax}`, `length(source_name) BETWEEN 1 AND ${L.activityTextMax}`,
  between('duration_s', L.activityDurationS), between('(kcal', L.activityKcal),
  between('distance_m', L.activityDistanceM),
  between('avg_hr', L.heartRateBpm), between('max_hr', L.heartRateBpm), between('steps', L.daySteps),
  between('move_kcal', L.activityKcal), between('exercise_min', L.dayExerciseMin), between('stand_h', L.dayStandH),
]
```

- Inside `describe('domain limits', …)`, after "keeps the account caps in their triggers at the same numbers", add:

```ts
  it("keeps the activity tables' CHECKs and caps at the same numbers", () => {
    for (const check of ACTIVITY_CHECKS) expect(activityMigration, check).toContain(check)
    const caps = [
      ['health_activities', DomainLimits.healthActivitiesMax, 'too_many_health_activities'],
      ['activity_days', DomainLimits.activityDaysMax, 'too_many_activity_days'],
    ] as const
    for (const [table, max, code] of caps) {
      const trigger = `tbl = '${table}'), 0) >= ${max}\nBEGIN\n  SELECT RAISE(ABORT, '${code}');`
      expect(activityMigration.split(trigger).length - 1, code).toBe(1)
    }
  })
```

(`'(kcal'` keeps its opening parenthesis, so it can't match inside `(move_kcal`.)

In `server/test/schema.test.ts`, add `'health_activities_cap', 'activity_days_cap'` to the list of the test "%s finds the row and the account's count through primary keys, never by counting". This plan's author checked both triggers' lookups with SQLite's `EXPLAIN QUERY PLAN`: they search `sqlite_autoindex_health_activities_1`, `sqlite_autoindex_activity_days_1` and `sqlite_autoindex_health_rows_1`, as that test expects.

Create `server/test/sync-activity.test.ts`:

```ts
import { describe, expect, it } from 'vitest'
import { request, signUp } from './helpers.ts'
import { type Row, SAMPLES, T1, T2 } from './samples.ts'

// Plan 39: outside workouts and days of activity sync like the other tables (test/sync-rows.test.ts runs the generic
// rules on both). These are the parts of their own.

const push = (token: string, entity: string, rows: Row[]) =>
  request('POST', `/v1/sync/${entity}`, { token, body: { rows } })

async function pulled(token: string, entity: string): Promise<Row[]> {
  const res = await request('GET', `/v1/sync/${entity}`, { token })
  expect(res.status).toBe(200)
  return (await res.json<{ rows: Row[] }>()).rows
}

describe('outside workouts', () => {
  it("keep Health's deletion against an older live copy", async () => {
    const { token } = await signUp()
    const row = SAMPLES['health-activities']()
    expect((await push(token, 'health-activities', [{ ...row, client_updated_at: T1 }])).status).toBe(200)
    expect((await push(token, 'health-activities', [{ ...row, client_updated_at: T2, deleted_at: T2 }])).status)
      .toBe(200)
    const stale = await push(token, 'health-activities', [{ ...row, client_updated_at: T1, deleted_at: null }])
    expect((await stale.json<{ acks: unknown[] }>()).acks).toEqual([])
    expect((await pulled(token, 'health-activities'))[0]?.deleted_at).toBe(T2)
  })

  it('refuse one that ends before it starts', async () => {
    const { token } = await signUp()
    const res = await push(token, 'health-activities', [
      { ...SAMPLES['health-activities'](), ended_at: '2026-11-06T06:59:59.000000Z' },
    ])
    expect(res.status).toBe(422)
    expect((await res.json<{ error: { code: string } }>()).error.code).toBe('row_rejected')
  })
})

describe('days of activity', () => {
  it('keep one row per day, the newer edit winning, stand hours optional', async () => {
    const { token } = await signUp()
    const day = SAMPLES['activity-days']()
    await push(token, 'activity-days', [day])
    await push(token, 'activity-days', [{ ...day, steps: 9001, stand_h: 11, client_updated_at: T2 }])
    await push(token, 'activity-days', [{ ...day, steps: 1, client_updated_at: T1 }])
    const rows = await pulled(token, 'activity-days')
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({ day: day.day, steps: 9001, stand_h: 11, client_updated_at: T2 })
  })
})
```

Create `server/test/health-rows.test.ts`:

```ts
import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { DomainLimits } from '../src/shared/domain-limits.ts'
import { countOf, type HealthTable, seedRows } from './cap-fixtures.ts'
import { insertUser } from './gym-fixtures.ts'
import { request, signUp } from './helpers.ts'
import { SAMPLES } from './samples.ts'

// The counts in health_rows (plan 39, migrations/0013_health_activities.sql), kept like account_rows' (plan 31): a
// deleted row lowers its count, and an account at both caps is deleted whole, its counts with it.

describe('health_rows', () => {
  const TABLES: HealthTable[] = ['health_activities', 'activity_days']

  it.each(TABLES)('a deleted row lowers the count of %s', async (table) => {
    const userId = await insertUser()
    await seedRows(table, userId, 3)
    expect(await countOf(table, userId)).toBe(3)
    await env.DB.prepare(
      `DELETE FROM ${table} WHERE rowid IN (SELECT rowid FROM ${table} WHERE user_id = ?1 LIMIT 1)`,
    ).bind(userId).run()
    expect(await countOf(table, userId)).toBe(2)
  })

  it('an account at both caps refuses one more and is deleted whole, with no count left', async () => {
    const { token, userId } = await signUp()
    await seedRows('health_activities', userId, DomainLimits.healthActivitiesMax)
    await seedRows('activity_days', userId, DomainLimits.activityDaysMax)
    const oneMore = await request('POST', '/v1/sync/activity-days', {
      token, body: { rows: [SAMPLES['activity-days']()] },
    })
    expect(oneMore.status).toBe(422)

    expect((await request('DELETE', '/v1/account', { token })).status).toBe(204)
    expect(await countOf('health_activities', userId)).toBe(0)
    expect(await countOf('activity_days', userId)).toBe(0)
    const left = await env.DB.prepare('SELECT count(*) AS n FROM health_rows WHERE user_id = ?1').bind(userId)
      .first<{ n: number }>()
    expect(left!.n).toBe(0)
  }, 120_000)
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/sync-rows.test.ts test/sync-activity.test.ts test/health-rows.test.ts test/account.test.ts test/account-caps.test.ts test/domain-limits-drift.test.ts`
Expected: failures like these:
- `health-activities` and `activity-days` answer 404 `No synced table …`;
- `no such table: health_activities` from `seedRows`;
- the drift test can't import `0013_health_activities.sql`;
- the profile round trip lacks `mcp_read_activity`.

- [ ] **Step 3: Write the migration**

Create `server/migrations/0013_health_activities.sql`. The timestamp CHECKs are 0002's, word for word. This plan's author applied the file with SQLite on top of migrations 0001–0012 and checked:
- the CHECK refusals;
- the cap at 20,000;
- an upsert of a stored row at the cap;
- two accounts holding the same id;
- the cascade.

```sql
-- Plan 39 (docs/specs/2026-11-16-health-activities-design.md, section 5): Apple Health activities, read on the phone
-- and synced like the other tables (src/sync/entities.ts, health-activities and activity-days). The numbers are
-- DomainLimits' (ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift); test/domain-limits-drift.test.ts checks
-- each one here. Conventions as in 0002_app_schema.sql: text timestamps in the stored form, 0/1 booleans, no defaults
-- for ids or times.

-- Outside workouts: workouts other apps saved to Health. The id is the HealthKit workout's UUID, so two devices of one
-- account importing the same workout write the same row. The account is part of the key: one iPhone's Health can be
-- read into two accounts (signing out of one and into another), and neither may refuse the other's rows.
CREATE TABLE health_activities (
  id TEXT NOT NULL CHECK (length(id) = 36),
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  kind TEXT NOT NULL CHECK (length(kind) BETWEEN 1 AND 100),
  started_at TEXT NOT NULL CHECK (substr(started_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(started_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(started_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  ended_at TEXT NOT NULL CHECK (substr(ended_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(ended_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(ended_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  duration_s REAL NOT NULL CHECK (duration_s BETWEEN 0 AND 86400),
  kcal REAL CHECK (kcal BETWEEN 0 AND 20000),
  distance_m REAL CHECK (distance_m BETWEEN 0 AND 1000000),
  avg_hr INTEGER CHECK (avg_hr BETWEEN 20 AND 250),
  max_hr INTEGER CHECK (max_hr BETWEEN 20 AND 250),
  source_name TEXT NOT NULL CHECK (length(source_name) BETWEEN 1 AND 100),
  from_watch INTEGER NOT NULL CHECK (from_watch IN (0,1)),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  deleted_at TEXT CHECK (substr(deleted_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(deleted_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(deleted_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  CHECK (ended_at >= started_at),
  PRIMARY KEY (user_id, id)
);
-- The pull's keyset order, and the MCP reads by start time (get_activity, get_training_insights).
CREATE INDEX health_activities_user_updated ON health_activities (user_id, updated_at, id);
CREATE INDEX health_activities_user_started ON health_activities (user_id, started_at);

-- Days of activity: one local calendar day's steps, move, exercise and stand (stand is null without an Apple Watch).
-- Never deleted: a day stays as it was last read.
CREATE TABLE activity_days (
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  day TEXT NOT NULL CHECK (day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  steps INTEGER NOT NULL CHECK (steps BETWEEN 0 AND 200000),
  move_kcal REAL NOT NULL CHECK (move_kcal BETWEEN 0 AND 20000),
  exercise_min INTEGER NOT NULL CHECK (exercise_min BETWEEN 0 AND 1440),
  stand_h INTEGER CHECK (stand_h BETWEEN 0 AND 24),
  client_updated_at TEXT NOT NULL CHECK (substr(client_updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(client_updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(client_updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  updated_at TEXT NOT NULL CHECK (substr(updated_at,1,10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(updated_at,11,9) GLOB 'T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' AND substr(updated_at,20) GLOB '.[0-9][0-9][0-9][0-9][0-9][0-9]Z'),
  PRIMARY KEY (user_id, day)
);
CREATE INDEX activity_days_user_updated ON activity_days (user_id, updated_at, day);

-- The storage caps, kept like plan 31's (0010_account_caps.sql) but in a table of their own: account_rows' tbl CHECK
-- lists the tables plan 31 capped, and SQLite can't change a CHECK without rebuilding that table and every trigger
-- that writes it. Deleted rows count; only an account's deletion removes these rows (ON DELETE CASCADE).
CREATE TABLE health_rows (
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE CHECK (length(user_id) = 36),
  tbl TEXT NOT NULL CHECK (tbl IN ('health_activities','activity_days')),
  n INTEGER NOT NULL,
  PRIMARY KEY (user_id, tbl)
);
CREATE TRIGGER health_activities_cap BEFORE INSERT ON health_activities
  WHEN NOT EXISTS (SELECT 1 FROM health_activities WHERE user_id = NEW.user_id AND id = NEW.id)
    AND coalesce((SELECT n FROM health_rows WHERE user_id = NEW.user_id AND tbl = 'health_activities'), 0) >= 20000
BEGIN
  SELECT RAISE(ABORT, 'too_many_health_activities');
END;
CREATE TRIGGER health_activities_counted AFTER INSERT ON health_activities
BEGIN
  INSERT INTO health_rows (user_id, tbl, n) VALUES (NEW.user_id, 'health_activities', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER health_activities_uncounted AFTER DELETE ON health_activities
BEGIN
  UPDATE health_rows SET n = n - 1 WHERE user_id = OLD.user_id AND tbl = 'health_activities';
END;
CREATE TRIGGER activity_days_cap BEFORE INSERT ON activity_days
  WHEN NOT EXISTS (SELECT 1 FROM activity_days WHERE user_id = NEW.user_id AND day = NEW.day)
    AND coalesce((SELECT n FROM health_rows WHERE user_id = NEW.user_id AND tbl = 'activity_days'), 0) >= 5000
BEGIN
  SELECT RAISE(ABORT, 'too_many_activity_days');
END;
CREATE TRIGGER activity_days_counted AFTER INSERT ON activity_days
BEGIN
  INSERT INTO health_rows (user_id, tbl, n) VALUES (NEW.user_id, 'activity_days', 1)
    ON CONFLICT (user_id, tbl) DO UPDATE SET n = n + 1;
END;
CREATE TRIGGER activity_days_uncounted AFTER DELETE ON activity_days
BEGIN
  UPDATE health_rows SET n = n - 1 WHERE user_id = OLD.user_id AND tbl = 'activity_days';
END;

-- "Read activity from Apple Health" for agents (get_activity, the streak in get_training_insights): on by default,
-- synced with the profile like the other mcp_* switches. Rows already stored are valid as they are.
ALTER TABLE profiles ADD COLUMN mcp_read_activity INTEGER NOT NULL DEFAULT 1 CHECK (mcp_read_activity IN (0,1));
```

- [ ] **Step 4: Sync the tables and the switch**

In `server/src/sync/entities.ts`:
- After the `logWorkouts` constant, add:

```ts
/**
 * Plan 39's "Read activity from Apple Health" switch, on by default. An app from before it sends none, and the Worker
 * is deployed first, so a missing value is stored as on, the column's default, instead of refusing the profile.
 */
const readActivity: Column = { name: 'mcp_read_activity', kind: 'bool', fallback: true }
```

- In the profile's columns, replace `col('mcp_propose', 'bool'), col('mcp_auto_apply', 'bool'), logWorkouts, opt('sex', 'text'),` with:

```ts
      col('mcp_propose', 'bool'), col('mcp_auto_apply', 'bool'), logWorkouts, readActivity, opt('sex', 'text'),
```

- In `ENTITIES`, after the `bodyweight` entry, add:

```ts
  // Plan 39: read from Apple Health on the phone; only its import writes them, so plain last-write-wins. Keyed by the
  // account too (migrations/0013_health_activities.sql): one iPhone's Health may be read into two accounts.
  'health-activities': {
    table: 'health_activities',
    conflict: ['user_id', 'id'],
    ackKey: 'id',
    tiebreak: { column: 'id', kind: 'text' },
    columns: [
      col('id', 'uuid'), col('kind', 'text'), col('started_at', 'ts'), col('ended_at', 'ts'), col('duration_s', 'real'),
      opt('kcal', 'real'), opt('distance_m', 'real'), opt('avg_hr', 'int'), opt('max_hr', 'int'),
      col('source_name', 'text'), col('from_watch', 'bool'), edited, deleted,
    ],
  },
  'activity-days': {
    table: 'activity_days',
    conflict: ['user_id', 'day'],
    ackKey: 'day',
    tiebreak: { column: 'day', kind: 'text' },
    columns: [
      col('day', 'date'), col('steps', 'int'), col('move_kcal', 'real'), col('exercise_min', 'int'),
      opt('stand_h', 'int'), edited,
    ],
  },
```

In `server/src/sync/caps.ts`, `ACCOUNT_CAPS`, after `too_many_listings_total: …,`, add:

```ts
  too_many_health_activities: full(DomainLimits.healthActivitiesMax, 'outside workouts'),
  too_many_activity_days: `You've reached the limit of ${grouped(DomainLimits.activityDaysMax)} days of activity on ` +
    'one account. This one stays on this iPhone.',
```

`src/http/errors.ts` already answers every `ACCOUNT_CAPS` code with 422 and these words.

- [ ] **Step 5: Run the tests**

Run: `cd server && npx vitest run test/sync-rows.test.ts test/sync-activity.test.ts test/health-rows.test.ts test/account.test.ts test/account-caps.test.ts test/account-rows.test.ts test/domain-limits-drift.test.ts test/schema.test.ts`
Expected: all pass. `schema.test.ts`'s 50-byte GLOB check covers the new patterns.

Run: `cd server && npm test && npx tsc --noEmit`
Expected: everything passes, and the type check is clean.

- [ ] **Step 6: Commit**

```bash
git add server/migrations/0013_health_activities.sql server/src/sync/entities.ts server/src/sync/caps.ts server/test/samples.ts server/test/account.test.ts server/test/cap-fixtures.ts server/test/account-caps.test.ts server/test/domain-limits-drift.test.ts server/test/schema.test.ts server/test/sync-activity.test.ts server/test/health-rows.test.ts
git commit -m "feat(server): outside workouts and days of activity sync, with caps (migration 0013)"
```

---

### Task 11: Rules 6 and 7 in TypeScript, on the shared fixture

**Files:**
- Create: `server/src/shared/activity.ts`
- Test: `server/test/shared/activity.test.ts`

- [ ] **Step 1: Write the failing test**

Create `server/test/shared/activity.test.ts`:

```ts
// Runs fixtures/activity.json, the cases GymCore's ActivityFixtureTests.swift runs too, through the TypeScript mirror.
import activityJson from '../../../fixtures/activity.json?raw'
import { test } from 'vitest'
import { assert, assertEquals } from '../assert.ts'
import { type ActivitySpan, counted, resolveActivities, type WorkoutSpan } from '../../src/shared/activity.ts'
import { streak } from '../../src/shared/insights.ts'

interface Fixture {
  cases: {
    name: string
    now: string
    time_zone: string
    goal: number
    workouts: WorkoutSpan[]
    activities: ActivitySpan[]
    expected: {
      shown: string[]
      attached: Record<string, string>
      counted: string[]
      streak: { current: number; longest: number; this_week_days: number; this_week_met: boolean }
    }
  }[]
}

const fixture = JSON.parse(activityJson) as Fixture

test('the fixture has its cases', () => {
  assert(fixture.cases.length >= 6, String(fixture.cases.length))
})

for (const c of fixture.cases) {
  test(`activity fixture: ${c.name}`, () => {
    const resolved = resolveActivities(c.activities, c.workouts)
    assertEquals(resolved.shown.map((a) => a.id), c.expected.shown, 'shown')
    assertEquals(Object.fromEntries(resolved.attached.map((x) => [x.activity.id, x.workout_id])), c.expected.attached,
      'attached')
    const kept = counted(resolved)
    assertEquals(kept.map((a) => a.id), c.expected.counted, 'counted')
    const s = streak([...c.workouts.map((w) => w.started_at), ...kept.map((a) => a.started_at)], c.goal,
      new Date(c.now), c.time_zone)
    assertEquals(
      { current: s.current, longest: s.longest, this_week_days: s.this_week_days, this_week_met: s.this_week_met },
      c.expected.streak,
      'streak',
    )
  })
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd server && npx vitest run test/shared/activity.test.ts`
Expected: FAIL, with `Failed to load url ../../src/shared/activity.ts` (module not found).

- [ ] **Step 3: Write the mirror**

Create `server/src/shared/activity.ts`. This plan's author ran it on the fixture with Node, and all 6 cases matched:

```ts
// Rules 6 and 7 for outside workouts (plan 39; docs/specs/2026-11-16-health-activities-design.md, decisions 5–8): a
// hand-maintained TypeScript port of GymCore's ActivityRules.swift, the source of truth. Both run the shared fixture
// fixtures/activity.json, so a change on one side only fails a test suite. Pure: no I/O.

/** What the rules read of an outside workout (a health_activities row has more). */
export interface ActivitySpan {
  id: string
  kind: string
  started_at: string
  ended_at: string
  duration_s: number
  from_watch: boolean
}

/** A finished GymRollins workout's time span. */
export interface WorkoutSpan {
  id: string
  started_at: string
  ended_at: string
}

export interface Resolved<T extends ActivitySpan> {
  /** Shown and counted on their own: not attached, one per session; newest first. */
  shown: T[]
  /** Attached to a GymRollins workout (the same session, measured), newest first, with that workout's id. */
  attached: { activity: T; workout_id: string }[]
}

/** Rule 6: overlapping a GymRollins workout by this share of the shorter of the two attaches it. */
export const ATTACH_SHARE = 0.5
/** Rule 7: two of the same kind overlapping by this share of the shorter are one session. */
export const SAME_SESSION_SHARE = 0.8
/** Active seconds an outside workout needs to count toward the streak and the weekly goal (decision 5). */
export const COUNTING_MINIMUM_S = 600

const ms = (iso: string): number => Date.parse(iso)
const length = (start: string, end: string): number => Math.max(0, ms(end) - ms(start))

/** Milliseconds two spans share. */
function overlap(aStart: string, aEnd: string, bStart: string, bEnd: string): number {
  return Math.max(0, Math.min(ms(aEnd), ms(bEnd)) - Math.max(ms(aStart), ms(bStart)))
}

const byId = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0)

/** Rule 6's workout: the largest overlap reaching ATTACH_SHARE of the shorter, then the earliest, the lowest id. */
function workoutFor(a: ActivitySpan, workouts: readonly WorkoutSpan[]): WorkoutSpan | null {
  let best: { span: WorkoutSpan; shared: number } | null = null
  for (const span of workouts) {
    const shared = overlap(a.started_at, a.ended_at, span.started_at, span.ended_at)
    const shorter = Math.min(length(a.started_at, a.ended_at), length(span.started_at, span.ended_at))
    if (shared <= 0 || shared < ATTACH_SHARE * shorter) continue
    const better = best === null || shared > best.shared ||
      (shared === best.shared && (ms(span.started_at) < ms(best.span.started_at) ||
        (ms(span.started_at) === ms(best.span.started_at) && byId(span.id, best.span.id) < 0)))
    if (better) best = { span, shared }
  }
  return best?.span ?? null
}

function sameSession(a: ActivitySpan, b: ActivitySpan): boolean {
  if (a.kind !== b.kind) return false
  const shared = overlap(a.started_at, a.ended_at, b.started_at, b.ended_at)
  const shorter = Math.min(length(a.started_at, a.ended_at), length(b.started_at, b.ended_at))
  return shared > 0 && shared >= SAME_SESSION_SHARE * shorter
}

/** The copy kept of a session: the Apple Watch's, then the longer (active time), the earlier start, the lower id. */
export function preferred(a: ActivitySpan, b: ActivitySpan): number {
  if (a.from_watch !== b.from_watch) return a.from_watch ? -1 : 1
  if (a.duration_s !== b.duration_s) return b.duration_s - a.duration_s
  if (ms(a.started_at) !== ms(b.started_at)) return ms(a.started_at) - ms(b.started_at)
  return byId(a.id, b.id)
}

/** Newest first, then the lower id. */
export function newestFirst(a: ActivitySpan, b: ActivitySpan): number {
  if (ms(a.started_at) !== ms(b.started_at)) return ms(b.started_at) - ms(a.started_at)
  return byId(a.id, b.id)
}

/** Rules 6 and 7 (ActivityRules.resolve): attach to GymRollins workouts, then keep one copy per session. */
export function resolveActivities<T extends ActivitySpan>(
  activities: readonly T[],
  workouts: readonly WorkoutSpan[],
): Resolved<T> {
  const attached: { activity: T; workout_id: string }[] = []
  const free: T[] = []
  for (const activity of activities) {
    const span = workoutFor(activity, workouts)
    if (span === null) {
      free.push(activity)
    } else {
      attached.push({ activity, workout_id: span.id })
    }
  }
  const kept: T[] = []
  for (const activity of [...free].sort(preferred)) {
    if (!kept.some((k) => sameSession(k, activity))) kept.push(activity)
  }
  return {
    shown: kept.sort(newestFirst),
    attached: attached.sort((x, y) => newestFirst(x.activity, y.activity)),
  }
}

/** Shown outside workouts that count toward the streak and the weekly goal (ResolvedActivities.counted). */
export function counted<T extends ActivitySpan>(resolved: Resolved<T>): T[] {
  return resolved.shown.filter((a) => a.duration_s >= COUNTING_MINIMUM_S)
}
```

- [ ] **Step 4: Run it**

Run: `cd server && npx vitest run test/shared/activity.test.ts test/shared/insights.test.ts && npx tsc --noEmit`
Expected: 7 activity tests pass (the 6 cases and the count check), the insights fixture still passes, and the type check is clean.

- [ ] **Step 5: Commit**

```bash
git add server/src/shared/activity.ts server/test/shared/activity.test.ts
git commit -m "feat(server): rules 6 and 7 in TypeScript, on the fixture GymCore runs"
```

---

### Task 12: MCP reads activity, behind its own switch

**Files:**
- Modify: `server/src/mcp/db.ts`
- Modify: `server/src/mcp/d1-db.ts`
- Modify: `server/src/mcp/tools/permissions.ts`
- Modify: `server/test/mcp/fake-db.ts`
- Test: `server/test/mcp/d1-db.test.ts`, `server/test/mcp/tools/permissions.test.ts`

- [ ] **Step 1: Write the failing tests**

In `server/test/mcp/d1-db.test.ts`:
- Add `'mcp_read_activity'` to the `Toggle` type.
- In `seedOwner`, after the `INSERT INTO bodyweight` call, add:

```ts
  await run(
    'INSERT INTO health_activities (id, user_id, kind, started_at, ended_at, duration_s, source_name, from_watch, ' +
      "client_updated_at, updated_at) VALUES (?1, ?2, 'walking', '2026-11-05T07:00:00.000000Z', " +
      "'2026-11-05T07:45:00.000000Z', 2700, 'Apple Watch', 1, ?3, ?3)",
    crypto.randomUUID(),
    userId,
    T,
  )
  await run(
    'INSERT INTO activity_days (user_id, day, steps, move_kcal, exercise_min, client_updated_at, updated_at) ' +
      "VALUES (?1, '2026-11-05', 8532, 410, 34, ?2, ?2)",
    userId,
    T,
  )
```

- In `snapshot`, after `latestBodyweight: …,`, add:

```ts
    healthActivities: await db.healthActivities(),
    activityDays: await db.activityDays('2026-11-01'),
```

- In `HIDES`, add `mcp_read_activity: ['activityDays', 'healthActivities'],`.
- After the `it.each(Object.entries(HIDES))` test, add:

```ts
  it("reads the owner's outside workouts and days, and the switch, while activity reading is on", async () => {
    const owner = await seedOwner()
    const db = new D1Db(DB, owner.userId, 'claude')
    expect(await db.healthActivities()).toMatchObject([
      { kind: 'walking', duration_s: 2700, from_watch: true, kcal: null, source_name: 'Apple Watch' },
    ])
    expect(await db.healthActivities('2026-11-06T00:00:00.000Z')).toEqual([])
    expect(await db.activityDays('2026-11-05')).toEqual([
      { day: '2026-11-05', steps: 8532, move_kcal: 410, exercise_min: 34, stand_h: null },
    ])
    expect(await db.activityDays('2026-11-06')).toEqual([])
    expect((await db.readPermissions()).activity).toBe(true)
  })

  it("reads finished workouts' spans whatever the workouts switch says: rule 6 only learns a session was there",
    async () => {
      const owner = await seedOwner()
      const finished = crypto.randomUUID()
      await run(
        'INSERT INTO workouts (id, user_id, started_at, ended_at, name, client_updated_at, updated_at) ' +
          "VALUES (?1, ?2, '2026-11-05T17:00:00.000000Z', '2026-11-05T18:00:00.000000Z', 'Pull', ?3, ?3)",
        finished,
        owner.userId,
        T,
      )
      await toggle(owner.userId, 'mcp_read_workouts', false)
      expect(await new D1Db(DB, owner.userId, 'claude').workoutSpans()).toEqual([
        { id: finished, started_at: '2026-11-05T17:00:00.000000Z', ended_at: '2026-11-05T18:00:00.000000Z' },
      ])
    })
```

  `seedOwner`'s own workout has no `ended_at`, so `workoutSpans` leaves it out.

In `server/test/mcp/tools/permissions.test.ts`, in "the words" test, add:

```ts
    expect(notAllowed(['activity'])).toContain('“Read activity from Apple Health”')
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/mcp/d1-db.test.ts test/mcp/tools/permissions.test.ts`
Expected: FAIL, with `db.healthActivities is not a function` in the snapshot and in the new tests. "mcp_read_activity off hides exactly its data" fails, and so does the words test, because the switch's name is `undefined`.

- [ ] **Step 3: Declare the rows and the reads**

In `server/src/mcp/db.ts`:
- In `Profile`, after `mcp_log_workouts?: boolean`, add:

```ts
  /** Read activity from Apple Health (plan 39); absent counts as on, its default. */
  mcp_read_activity?: boolean
```

- Before `export interface ExerciseRow {`, add:

```ts
/** `health_activities` (plan 39): a workout another app saved to Apple Health, as the phone imported it. */
export interface HealthActivityRow {
  id: string
  kind: string
  started_at: string
  ended_at: string
  duration_s: number
  kcal: number | null
  distance_m: number | null
  avg_hr: number | null
  max_hr: number | null
  source_name: string
  from_watch: boolean
}

/** `activity_days` (plan 39): one local day's steps, move, exercise and stand (null without an Apple Watch). */
export interface ActivityDayRow {
  day: string
  steps: number
  move_kcal: number
  exercise_min: number
  stand_h: number | null
}

/** A finished workout's span, for rule 6 (src/shared/activity.ts). */
export interface WorkoutSpanRow {
  id: string
  started_at: string
  ended_at: string
}

/** The owner's read switches for agents (Settings › AI agents). */
export interface ReadPermissions {
  plan: boolean
  workouts: boolean
  body: boolean
  gyms: boolean
  /** Read activity from Apple Health (plan 39). */
  activity: boolean
}
```

- In `Db`, replace `readPermissions(): Promise<{ plan: boolean; workouts: boolean; body: boolean; gyms: boolean }>` with `readPermissions(): Promise<ReadPermissions>`.
- In `Db`, before `/** The owner's stored weekly targets (groups without a row use the defaults). */`, add:

```ts
  /**
   * Outside workouts (plan 39) that aren't deleted and started at or after `since` (all when absent), oldest first, at
   * most the account's cap; empty while mcp_read_activity is off.
   */
  healthActivities(since?: string): Promise<HealthActivityRow[]>
  /** Days of activity on or after `fromDay` (YYYY-MM-DD), oldest first; empty while mcp_read_activity is off. */
  activityDays(fromDay: string): Promise<ActivityDayRow[]>
  /**
   * The spans of finished workouts that aren't deleted and started at or after `since` (all when absent), whatever
   * mcp_read_workouts says: rule 6 only learns that a GymRollins session was there.
   */
  workoutSpans(since?: string): Promise<WorkoutSpanRow[]>
```

In `server/src/mcp/tools/permissions.ts`:
- replace `export type ReadSwitch = 'workouts' | 'body' | 'plan' | 'gyms'` with `export type ReadSwitch = 'workouts' | 'body' | 'plan' | 'gyms' | 'activity'`;
- in `SWITCH_NAMES`, add `activity: 'Read activity from Apple Health',` after `gyms: 'Gyms',`.

- [ ] **Step 4: Read them from D1**

In `server/src/mcp/d1-db.ts`:
- Add `import { DomainLimits } from '../shared/domain-limits.ts'` above `import { AGENT_WORKOUT_CAPS, CLAUDE_CAPS } from '../sync/caps.ts'`.
- Add `ActivityDayRow`, `HealthActivityRow`, `ReadPermissions` and `WorkoutSpanRow` to the type import from `./db.ts`, in alphabetical order.
- In `Permissions`, after `logWorkouts: boolean`, add:

```ts
  /** Read activity from Apple Health (plan 39): on by default, so on without a profile too. */
  activity: boolean
```

- In `allowed()`, replace `'mcp_log_workouts ' +` with `'mcp_log_workouts, mcp_read_activity ' +`. After `logWorkouts: p ? bool(p.mcp_log_workouts) : false,`, add:

```ts
      activity: p ? bool(p.mcp_read_activity) : true,
```

- Replace `readPermissions()`:

```ts
  async readPermissions(): Promise<ReadPermissions> {
    const { plan, workouts, body, gyms, activity } = await this.allowed()
    return { plan, workouts, body, gyms, activity }
  }
```

- In `profile()`:
  - replace `'mcp_auto_apply, mcp_log_workouts, sex, birth_year FROM profiles WHERE user_id = ?1',` with `'mcp_auto_apply, mcp_log_workouts, mcp_read_activity, sex, birth_year FROM profiles WHERE user_id = ?1',`;
  - after `mcp_log_workouts: bool(p.mcp_log_workouts),`, add `mcp_read_activity: bool(p.mcp_read_activity),`.
- After `workoutDates()`, add:

```ts

  /** Through health_activities_user_started. At most the account's cap (DomainLimits.healthActivitiesMax). */
  async healthActivities(since?: string): Promise<HealthActivityRow[]> {
    if (!(await this.allowed()).activity) return []
    const binds: unknown[] = [this.userId, DomainLimits.healthActivitiesMax]
    const after = since ? ` AND started_at >= ?${binds.push(stamp(since))}` : ''
    const rows = await this.all(
      'SELECT id, kind, started_at, ended_at, duration_s, kcal, distance_m, avg_hr, max_hr, source_name, from_watch ' +
        `FROM health_activities WHERE user_id = ?1 AND deleted_at IS NULL${after} ORDER BY started_at, id LIMIT ?2`,
      ...binds,
    )
    return rows.map((r) => ({ ...r, from_watch: bool(r.from_watch) }) as HealthActivityRow)
  }

  /** Through the primary key (user_id, day). At most the account's cap (DomainLimits.activityDaysMax). */
  async activityDays(fromDay: string): Promise<ActivityDayRow[]> {
    if (!(await this.allowed()).activity) return []
    return await this.all<ActivityDayRow>(
      'SELECT day, steps, move_kcal, exercise_min, stand_h FROM activity_days WHERE user_id = ?1 AND day >= ?2 ' +
        'ORDER BY day LIMIT ?3',
      this.userId,
      fromDay,
      DomainLimits.activityDaysMax,
    )
  }

  /** Through workouts_user_started. At most the account's 10,000 workouts (DomainLimits.workoutsMax). */
  async workoutSpans(since?: string): Promise<WorkoutSpanRow[]> {
    const binds: unknown[] = [this.userId, DomainLimits.workoutsMax]
    const after = since ? ` AND started_at >= ?${binds.push(stamp(since))}` : ''
    return await this.all<WorkoutSpanRow>(
      'SELECT id, started_at, ended_at FROM workouts WHERE user_id = ?1 AND deleted_at IS NULL ' +
        `AND ended_at IS NOT NULL${after} ORDER BY started_at, id LIMIT ?2`,
      ...binds,
    )
  }
```

In `server/test/mcp/fake-db.ts`:
- Add `ActivityDayRow`, `HealthActivityRow`, `ReadPermissions` and `WorkoutSpanRow` to the type import from `../../src/mcp/db.ts`.
- In `FakeData`, add:

```ts
  /** Outside workouts and days of activity (plan 39). */
  activities?: HealthActivityRow[]
  days?: ActivityDayRow[]
```

- Replace `readPermissions()`:

```ts
  readPermissions(): Promise<ReadPermissions> {
    const p = this.data.profile
    return Promise.resolve({
      plan: p?.mcp_read_plan ?? true,
      workouts: p?.mcp_read_workouts ?? true,
      body: p?.mcp_read_body ?? true,
      gyms: p?.mcp_read_gyms ?? true,
      activity: p?.mcp_read_activity ?? true,
    })
  }
```

- After `workoutDates()`, add:

```ts

  /** Like D1Db: hidden while mcp_read_activity is off; oldest first. */
  healthActivities(since?: string): Promise<HealthActivityRow[]> {
    if (this.data.profile?.mcp_read_activity === false) return Promise.resolve([])
    const rows = (this.data.activities ?? [])
      .filter((a) => (since ? time(a.started_at) >= time(since) : true))
      .sort((a, b) => time(a.started_at) - time(b.started_at))
    return Promise.resolve(rows)
  }

  activityDays(fromDay: string): Promise<ActivityDayRow[]> {
    if (this.data.profile?.mcp_read_activity === false) return Promise.resolve([])
    const rows = (this.data.days ?? []).filter((d) => d.day >= fromDay).sort((a, b) => a.day.localeCompare(b.day))
    return Promise.resolve(rows)
  }

  /** Like D1Db: finished workouts whatever mcp_read_workouts says. */
  workoutSpans(since?: string): Promise<WorkoutSpanRow[]> {
    const rows = this.data.workouts
      .filter((w) => w.ended_at !== null && (since ? time(w.started_at) >= time(since) : true))
      .sort((a, b) => time(a.started_at) - time(b.started_at))
      .map((w) => ({ id: w.id, started_at: w.started_at, ended_at: w.ended_at ?? w.started_at }))
    return Promise.resolve(rows)
  }
```

- [ ] **Step 5: Run the tests**

Run: `cd server && npx vitest run test/mcp/d1-db.test.ts test/mcp/tools/permissions.test.ts && npx tsc --noEmit`
Expected: all pass. "mcp_read_activity off hides exactly its data" sees `activityDays` and `healthActivities` change, and no other toggle touches them. The type check is clean.

- [ ] **Step 6: Commit**

```bash
git add server/src/mcp/db.ts server/src/mcp/d1-db.ts server/src/mcp/tools/permissions.ts server/test/mcp/fake-db.ts server/test/mcp/d1-db.test.ts server/test/mcp/tools/permissions.test.ts
git commit -m "feat(mcp): read outside workouts and days of activity behind their own switch"
```

---

### Task 13: The `get_activity` tool

**Files:**
- Modify: `server/src/shared/insights.ts`: export `civilDay`.
- Create: `server/src/mcp/tools/activity.ts`
- Modify: `server/src/mcp/tools/schemas.ts`, `server/src/mcp/tools/register.ts`
- Modify: `server/src/mcp/tools/read.ts`: `get_profile` names the new permission.
- Test: `server/test/mcp/tools/activity.test.ts` (new)
- Test: `server/test/mcp/app.test.ts`, `server/test/mcp/agent-wording.test.ts`, `server/test/mcp/tools/read.test.ts`, `server/test/mcp/tools/permissions.test.ts`

- [ ] **Step 1: Write the failing tests**

Create `server/test/mcp/tools/activity.test.ts`:

```ts
// get_activity (plan 39): outside workouts after rules 6 and 7, the per-day and per-week totals, the window and its time
// zone, and the switch.
import { describe, expect, it } from 'vitest'
import type { HealthActivityRow, WorkoutRow } from '../../../src/mcp/db.ts'
import { getActivity } from '../../../src/mcp/tools/activity.ts'
import { notAllowed } from '../../../src/mcp/tools/permissions.ts'
import { ToolError, type ToolResult } from '../../../src/mcp/tools/result.ts'
import { FakeDb, type FakeData, loadOwnerData } from '../fake-db.ts'

const NOW = new Date('2026-09-26T09:00:00Z') // Saturday

function outside(id: string, kind: string, start: string, minutes: number,
  extra: Partial<HealthActivityRow> = {}): HealthActivityRow {
  return {
    id, kind, started_at: start, ended_at: new Date(Date.parse(start) + minutes * 60_000).toISOString(),
    duration_s: minutes * 60, kcal: null, distance_m: null, avg_hr: null, max_hr: null, source_name: 'Strava',
    from_watch: false, ...extra,
  }
}

const workout = (id: string, start: string): WorkoutRow => ({
  id, started_at: start, ended_at: new Date(Date.parse(start) + 3_600_000).toISOString(), paused_sec: 0,
  routine_id: null, name: 'Push', workout_entries: [],
})

async function ctx(mutate?: (d: FakeData) => void) {
  const data = await loadOwnerData()
  data.workouts = [workout('w1', '2026-09-22T17:00:00Z')]
  data.activities = [
    outside('a1', 'walking', '2026-09-25T07:00:00.000000Z', 45,
      { kcal: 180, distance_m: 3400, avg_hr: 102, max_hr: 121, source_name: 'Apple Watch', from_watch: true }),
    outside('a2', 'traditional_strength', '2026-09-22T17:05:00.000000Z', 50,
      { kcal: 412, avg_hr: 128, max_hr: 162, source_name: 'Apple Watch', from_watch: true }), // during w1
    outside('a3', 'walking', '2026-09-25T07:01:00.000000Z', 44, { kcal: 175 }), // Strava's copy of a1
    outside('a4', 'running', '2026-09-20T08:00:00.000000Z', 30),
    outside('a5', 'running', '2026-08-01T08:00:00.000000Z', 30), // before the 28 days
  ]
  data.days = [
    { day: '2026-08-01', steps: 9000, move_kcal: 450, exercise_min: 40, stand_h: 12 },
    { day: '2026-09-20', steps: 6000, move_kcal: 300, exercise_min: 25, stand_h: 10 },
    { day: '2026-09-25', steps: 8532, move_kcal: 410, exercise_min: 34, stand_h: 11 },
    { day: '2026-09-26', steps: 4210, move_kcal: 210, exercise_min: 18, stand_h: null },
  ]
  mutate?.(data)
  return { db: new FakeDb(data), now: NOW }
}

const json = (r: ToolResult) => {
  expect(r.isError).toBeFalsy()
  return JSON.parse(r.content[0]!.text)
}

describe('get_activity', () => {
  it('lists outside workouts newest first: an attached one says during which workout, copies once', async () => {
    const out = json(await getActivity(await ctx(), {}))
    expect(out.days).toBe(28)
    expect(out.first_day).toBe('2026-08-30')
    expect(out.outside_workouts).toEqual([
      {
        kind: 'walking', started_at: '2026-09-25T07:00:00.000000Z', duration_min: 45, distance_km: 3.4, kcal: 180,
        avg_hr: 102, max_hr: 121, source: 'Apple Watch',
      },
      {
        kind: 'traditional_strength', started_at: '2026-09-22T17:05:00.000000Z', duration_min: 50, kcal: 412,
        avg_hr: 128, max_hr: 162, source: 'Apple Watch', during_workout_id: 'w1',
      },
      { kind: 'running', started_at: '2026-09-20T08:00:00.000000Z', duration_min: 30, source: 'Strava' },
    ])
    expect(out.outside_workouts_total).toBe(3)
    expect(out.method).toContain('never add the two')
  })

  it('totals each day and each Monday–Sunday week, leaving attached workouts out', async () => {
    const out = json(await getActivity(await ctx(), {}))
    expect(out.days_of_activity).toEqual([
      { day: '2026-09-26', steps: 4210, move_kcal: 210, exercise_min: 18, outside_workouts: 0, outside_minutes: 0 },
      {
        day: '2026-09-25', steps: 8532, move_kcal: 410, exercise_min: 34, stand_h: 11, outside_workouts: 1,
        outside_minutes: 45,
      },
      {
        day: '2026-09-20', steps: 6000, move_kcal: 300, exercise_min: 25, stand_h: 10, outside_workouts: 1,
        outside_minutes: 30,
      },
    ])
    expect(out.weeks).toEqual([
      {
        week_start: '2026-09-21', days_with_data: 2, steps: 12742, move_kcal: 620, exercise_min: 52,
        outside_workouts: 1, outside_minutes: 45,
      },
      {
        week_start: '2026-09-14', days_with_data: 1, steps: 6000, move_kcal: 300, exercise_min: 25,
        outside_workouts: 1, outside_minutes: 30,
      },
    ])
  })

  it('takes the last `days` days, in the time zone it is given', async () => {
    const today = json(await getActivity(await ctx(), { days: 1 }))
    expect(today.outside_workouts).toEqual([])
    expect(today.days_of_activity.map((d: { day: string }) => d.day)).toEqual(['2026-09-26'])

    const lateEvening = await ctx((d) => {
      d.activities = [outside('a6', 'walking', '2026-09-26T06:00:00.000000Z', 30)] // 23:00 on the 25th in Los Angeles
    })
    expect(json(await getActivity(lateEvening, { days: 1 })).outside_workouts).toHaveLength(1)
    expect(json(await getActivity(lateEvening, { days: 1, time_zone: 'America/Los_Angeles' })).outside_workouts)
      .toEqual([])
  })

  it('lists at most 60 and says how many there were', async () => {
    const many = await ctx((d) => {
      d.activities = Array.from({ length: 70 }, (_, i) =>
        outside(`m${i}`, 'walking', new Date(Date.UTC(2026, 8, 1) + i * 3 * 3_600_000).toISOString(), 60))
    })
    const out = json(await getActivity(many, {}))
    expect(out.outside_workouts).toHaveLength(60)
    expect(out.outside_workouts_total).toBe(70)
  })

  it('refuses while the owner keeps activity from agents, and for an unknown time zone', async () => {
    const off = await ctx((d) => {
      d.profile = { ...d.profile!, mcp_read_activity: false }
    })
    await expect(getActivity(off, {})).rejects.toThrow(notAllowed(['activity']))
    await expect(getActivity(await ctx(), { time_zone: 'Mars/Olympus' })).rejects.toThrow(ToolError)
  })
})
```

In `server/test/mcp/app.test.ts`, rename the test to `'initialize and tools/list: 17 tools with titles and annotations'`, and replace `assertEquals(tools.length, 16)` with `assertEquals(tools.length, 17)`.

In `server/test/mcp/agent-wording.test.ts`, add `'get_activity'` to the list in `for (const name of ['get_training_insights', 'get_strength_levels', 'list_gyms', 'get_gym_equipment'])`.

In `server/test/mcp/tools/read.test.ts`, "get_profile: unit, goal with display, limits, permissions": add `read_activity: true,` after `read_gyms: true,`.

In `server/test/mcp/tools/permissions.test.ts`:
- add `import { getActivity } from '../../../src/mcp/tools/activity.ts'`;
- add `'mcp_read_activity'` to the `Switch` type;
- in "get_profile gives the permissions and says the profile is withheld…", replace the expected permissions with `{ read_plan: false, read_workouts: true, read_body: false, read_gyms: true, read_activity: true, auto_apply: false }`;
- in `describe('a tool whose switch is off', …)`, add:

```ts
  it('get_activity refuses while reading activity is off', async () => {
    await expect(getActivity(await ctx('mcp_read_activity'), {})).rejects.toThrow(notAllowed(['activity']))
  })
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/mcp/tools/activity.test.ts test/mcp/app.test.ts test/mcp/agent-wording.test.ts test/mcp/tools/read.test.ts test/mcp/tools/permissions.test.ts`
Expected: FAIL:
- `activity.ts` can't be loaded;
- `tools.length` is 16;
- `read_activity` is missing from `get_profile`.

- [ ] **Step 3: Export the civil day**

In `server/src/shared/insights.ts`, replace `function civilDay(t: number, tz: string): number {` with `export function civilDay(t: number, tz: string): number {`.

- [ ] **Step 4: Write the tool**

Create `server/src/mcp/tools/activity.ts`. This plan's author ran this file with Node on the test's data: it gave the output the test expects:

```ts
// get_activity (plan 39; docs/specs/2026-11-16-health-activities-design.md, section 5): what the owner did outside
// GymRollins, from Apple Health. Outside workouts after rules 6 and 7 (src/shared/activity.ts), newest first, and
// steps, move, exercise and stand per day and per Monday–Sunday week, in the agent's time zone.
import { resolveActivities } from '../../shared/activity.ts'
import { assertTimeZone, civilDay, isoDay, weekKey } from '../../shared/insights.ts'
import type { HealthActivityRow } from '../db.ts'
import { clamp, daysBefore, round } from './format.ts'
import { requireReads } from './permissions.ts'
import { compact, ok, type ToolCtx, ToolError, type ToolResult } from './result.ts'

export const ACTIVITY_DAYS = { min: 1, max: 84, default: 28 }
/** At most this many outside workouts in one answer; `outside_workouts_total` says how many there were. */
export const ACTIVITY_LIST_MAX = 60
const DAY_MS = 86_400_000

const METHOD =
  'Outside workouts are workouts other apps or the Apple Watch saved to Apple Health. One recorded during a ' +
  'GymRollins workout (overlapping at least half of the shorter of the two) is that session, measured: it carries ' +
  'during_workout_id and stays out of the day and week totals. Copies of one session from two apps (same kind, 80% ' +
  'overlap) are listed once, the Apple Watch copy first. move_kcal already includes the GymRollins workouts the app ' +
  'saved to Health: never add the two.'

interface Totals {
  steps: number
  move_kcal: number
  exercise_min: number
  stand_h: number | null
  outside_workouts: number
  outside_minutes: number
}

const empty = (): Totals => ({
  steps: 0, move_kcal: 0, exercise_min: 0, stand_h: null, outside_workouts: 0, outside_minutes: 0,
})

/** A `YYYY-MM-DD` day as a civil-date epoch (UTC midnight), like insights.ts' civilDay. */
const civil = (day: string): number => Date.parse(`${day}T00:00:00Z`)

function listed(a: HealthActivityRow, duringWorkoutId: string | undefined): Record<string, unknown> {
  return compact({
    kind: a.kind,
    started_at: a.started_at,
    duration_min: Math.round(a.duration_s / 60),
    distance_km: a.distance_m === null ? null : round(a.distance_m / 1000, 2),
    kcal: a.kcal === null ? null : Math.round(a.kcal),
    avg_hr: a.avg_hr,
    max_hr: a.max_hr,
    source: a.source_name,
    during_workout_id: duringWorkoutId ?? null,
  })
}

export async function getActivity(
  { db, now }: ToolCtx,
  args: { days?: number; time_zone?: string },
): Promise<ToolResult> {
  const tz = args.time_zone ?? 'UTC'
  try {
    assertTimeZone(tz)
  } catch {
    throw new ToolError(`Unknown time zone "${tz}". Use an IANA name such as Europe/Warsaw.`)
  }
  await requireReads(db, 'activity')
  const days = clamp(Math.trunc(args.days ?? ACTIVITY_DAYS.default), ACTIVITY_DAYS.min, ACTIVITY_DAYS.max)
  const today = civilDay(now.getTime(), tz)
  const first = today - (days - 1) * DAY_MS
  // A day of margin for the time zone, and one more for a GymRollins workout that started before the window.
  const [rows, spans, dayRows] = await Promise.all([
    db.healthActivities(daysBefore(now, days + 1).toISOString()),
    db.workoutSpans(daysBefore(now, days + 2).toISOString()),
    db.activityDays(isoDay(first)),
  ])
  const resolved = resolveActivities(rows.filter((a) => civilDay(Date.parse(a.started_at), tz) >= first), spans)
  const during = new Map(resolved.attached.map((x) => [x.activity.id, x.workout_id]))
  const all = [...resolved.shown, ...resolved.attached.map((x) => x.activity)]
    .sort((a, b) => Date.parse(b.started_at) - Date.parse(a.started_at) || (a.id < b.id ? -1 : 1))

  const byDay = new Map<number, Totals>()
  const totals = (day: number): Totals => {
    const known = byDay.get(day)
    if (known) return known
    const fresh = empty()
    byDay.set(day, fresh)
    return fresh
  }
  for (const d of dayRows) {
    const t = totals(civil(d.day))
    t.steps = d.steps
    t.move_kcal = d.move_kcal
    t.exercise_min = d.exercise_min
    t.stand_h = d.stand_h
  }
  // An attached outside workout is a GymRollins session, measured: it stays out of the totals.
  for (const a of resolved.shown) {
    const t = totals(civilDay(Date.parse(a.started_at), tz))
    t.outside_workouts += 1
    t.outside_minutes += Math.round(a.duration_s / 60)
  }
  const perDay = [...byDay.entries()].sort(([a], [b]) => b - a)
  const byWeek = new Map<number, Totals & { days_with_data: number }>()
  for (const [day, t] of perDay) {
    const week = weekKey(day, 'UTC')
    const w = byWeek.get(week) ?? { ...empty(), days_with_data: 0 }
    byWeek.set(week, {
      ...w,
      steps: w.steps + t.steps,
      move_kcal: w.move_kcal + t.move_kcal,
      exercise_min: w.exercise_min + t.exercise_min,
      outside_workouts: w.outside_workouts + t.outside_workouts,
      outside_minutes: w.outside_minutes + t.outside_minutes,
      days_with_data: w.days_with_data + 1,
    })
  }

  return ok({
    time_zone: tz,
    days,
    first_day: isoDay(first),
    outside_workouts: all.slice(0, ACTIVITY_LIST_MAX).map((a) => listed(a, during.get(a.id))),
    outside_workouts_total: all.length,
    days_of_activity: perDay.map(([day, t]) =>
      compact({
        day: isoDay(day),
        steps: t.steps,
        move_kcal: Math.round(t.move_kcal),
        exercise_min: t.exercise_min,
        stand_h: t.stand_h,
        outside_workouts: t.outside_workouts,
        outside_minutes: t.outside_minutes,
      })
    ),
    weeks: [...byWeek.entries()].sort(([a], [b]) => b - a).map(([week, w]) => ({
      week_start: isoDay(week),
      days_with_data: w.days_with_data,
      steps: w.steps,
      move_kcal: Math.round(w.move_kcal),
      exercise_min: w.exercise_min,
      outside_workouts: w.outside_workouts,
      outside_minutes: w.outside_minutes,
    })),
    method: METHOD,
  })
}
```

In `server/src/mcp/tools/schemas.ts`, `schemas`, after `bodyweight: …,`, add:

```ts
  activity: z.object({
    days: z.number().int().min(1).max(84).optional().describe('1–84, default 28'),
    time_zone: z.string().min(1).max(64).optional().describe(
      'IANA time zone for the days and the Monday–Sunday weeks, e.g. Europe/Warsaw. Default: UTC',
    ),
  }),
```

In `server/src/mcp/tools/register.ts`:
- add `import { getActivity } from './activity.ts'` beside the other tool imports;
- in `TOOL_SPECS`, after the `get_bodyweight` spec, add:

```ts
  spec({
    name: 'get_activity',
    title: 'Get activity from Apple Health',
    description:
      "The owner's activity outside GymRollins, from Apple Health, for the last `days` days (1–84, default 28): " +
      'workouts other apps or the Apple Watch recorded (walks, runs, rides, classes), newest first and at most 60, ' +
      'and steps, move kcal, exercise minutes and stand hours per day and per Monday–Sunday week in time_zone ' +
      '(default UTC). A workout recorded during a GymRollins workout carries during_workout_id: it is that session, ' +
      'measured. Copies of one session from two apps are listed once. Check it before planning hard leg or ' +
      'conditioning days. Only works if the owner allowed agents to read activity from Apple Health.',
    input: schemas.activity,
    annotations: READ,
    run: (ctx, a) => getActivity(ctx, a),
  }),
```

- [ ] **Step 5: `get_profile` names the permission**

In `server/src/mcp/tools/read.ts`, `getProfile`, replace the withheld branch's first lines:

```ts
    const [{ plan, workouts, body, gyms }, autoApply] = await Promise.all([db.readPermissions(), db.autoApply()])
    return ok({
      profile: withheld(['plan'], 'The profile'),
      permissions: {
        read_plan: plan,
        read_workouts: workouts,
        read_body: body,
        read_gyms: gyms,
        auto_apply: autoApply,
      },
    })
```

with:

```ts
    const [{ plan, workouts, body, gyms, activity }, autoApply] = await Promise.all([
      db.readPermissions(),
      db.autoApply(),
    ])
    return ok({
      profile: withheld(['plan'], 'The profile'),
      permissions: {
        read_plan: plan,
        read_workouts: workouts,
        read_body: body,
        read_gyms: gyms,
        read_activity: activity,
        auto_apply: autoApply,
      },
    })
```

In the saved profile's `permissions`, after `read_gyms: p.mcp_read_gyms,`, add:

```ts
      read_activity: p.mcp_read_activity ?? true,
```

- [ ] **Step 6: Run the tests**

Run: `cd server && npx vitest run test/mcp && npx tsc --noEmit`
Expected: everything in `test/mcp` passes, and the type check is clean.

- [ ] **Step 7: Commit**

```bash
git add server/src/shared/insights.ts server/src/mcp/tools/activity.ts server/src/mcp/tools/schemas.ts server/src/mcp/tools/register.ts server/src/mcp/tools/read.ts server/test/mcp
git commit -m "feat(mcp): get_activity: outside workouts and days of activity for agents"
```

---

### Task 14: The streak counts outside workouts, and agents are told to check activity

**Files:**
- Modify: `server/src/mcp/tools/insights.ts`
- Modify: `server/src/mcp/tools/register.ts`: the `get_training_insights` description.
- Modify: `server/src/mcp/instructions.ts`
- Test: `server/test/mcp/tools/insights.test.ts`, `server/test/mcp/instructions.test.ts`

- [ ] **Step 1: Write the failing tests**

In `server/test/mcp/tools/insights.test.ts`:
- Change the type import to `import type { HealthActivityRow, WorkoutRow } from '../../../src/mcp/db.ts'`.
- Add `import { withheld } from '../../../src/mcp/tools/permissions.ts'`.
- After `bench(…)`, add:

```ts
function outside(id: string, start: string, minutes: number, kind = 'walking'): HealthActivityRow {
  return {
    id, kind, started_at: start, ended_at: new Date(Date.parse(start) + minutes * 60_000).toISOString(),
    duration_s: minutes * 60, kcal: null, distance_m: null, avg_hr: null, max_hr: null, source_name: 'Apple Watch',
    from_watch: true,
  }
}
```

- At the end of the file, add:

```ts
test('get_training_insights: outside workouts of 10 minutes or more count as workout days (plan 39)', async () => {
  const out = json(
    await getTrainingInsights(
      await ctx((d) => {
        d.activities = [
          outside('a1', '2026-09-23T07:00:00.000Z', 45), // Wed: a day of its own
          outside('a2', '2026-09-24T07:00:00.000Z', 5), // Thu: too short to count
          outside('a3', '2026-09-21T17:05:00.000Z', 50, 'traditional_strength'), // during w1 on Mon: that session
        ]
      }),
      {},
    ),
  )
  assertEquals(out.streak.this_week_days, 3)
  assertEquals(out.withheld, undefined)
})

test('get_training_insights: with activity reading off, the streak counts GymRollins workouts and says so', async () => {
  const out = json(
    await getTrainingInsights(
      await ctx((d) => {
        d.profile = { ...d.profile!, mcp_read_activity: false }
        d.activities = [outside('a1', '2026-09-23T07:00:00.000Z', 45)]
      }),
      {},
    ),
  )
  assertEquals(out.streak.this_week_days, 2)
  assertEquals(out.withheld, [withheld(['activity'], 'Outside workouts in the streak')])
})
```

In `server/test/mcp/instructions.test.ts`:
- in "instructions name only registered tools", replace `assertEquals(named.length, 8, named.join(', '))` with `assertEquals(named.length, 9, named.join(', '))`;
- in "instructions start with the profile and end with the data rule", replace `assertEquals(lines.length, 9)` with `assertEquals(lines.length, 10)`;
- add:

```ts
test('instructions send agents to get_activity before hard leg or conditioning days', () => {
  assert(SERVER_INSTRUCTIONS.includes('Before planning hard leg or conditioning days, check get_activity'))
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd server && npx vitest run test/mcp/tools/insights.test.ts test/mcp/instructions.test.ts`
Expected: FAIL:
- `this_week_days` is 2, not 3;
- `withheld` is missing;
- the instructions have 8 tools and 9 lines.

- [ ] **Step 3: Count outside workouts in the streak**

In `server/src/mcp/tools/insights.ts`:
- Add imports:

```ts
import { counted, resolveActivities } from '../../shared/activity.ts'
```

  and change `import { requireReads } from './permissions.ts'` to `import { requireReads, switchedOff, withheld } from './permissions.ts'`.
- Replace:

```ts
  await requireReads(db, 'workouts', 'plan')
  const profile = await db.profile()
  const since = new Date(now.getTime() - WINDOW_DAYS * 86_400_000).toISOString()
  const [workouts, dates, targetRows] = await Promise.all([
    db.workouts({ since, limit: MAX_WORKOUTS }),
    db.workoutDates(),
    db.muscleTargets(),
  ])
```

with:

```ts
  await requireReads(db, 'workouts', 'plan')
  // Outside workouts count toward the streak (plan 39, decision 5) while the owner lets agents read activity.
  const activityOff = await switchedOff(db, 'activity')
  const profile = await db.profile()
  const since = new Date(now.getTime() - WINDOW_DAYS * 86_400_000).toISOString()
  const [workouts, dates, targetRows, outside, spans] = await Promise.all([
    db.workouts({ since, limit: MAX_WORKOUTS }),
    db.workoutDates(),
    db.muscleTargets(),
    activityOff.length > 0 ? [] : db.healthActivities(),
    activityOff.length > 0 ? [] : db.workoutSpans(),
  ])
  const outsideDates = counted(resolveActivities(outside, spans)).map((a) => a.started_at)
```

- Replace `const s = streak(dates, goal, now, tz)` with `const s = streak([...dates, ...outsideDates], goal, now, tz)`.
- In the `ok({ … })` result, add as its first entry:

```ts
    ...(activityOff.length > 0 ? { withheld: [withheld(activityOff, 'Outside workouts in the streak')] } : {}),
```

- In `method`, replace `'at least goal_days_per_week distinct days with a workout; the current week never breaks it. ' +` with:

```ts
      'at least goal_days_per_week distinct days with a workout, an outside workout from Apple Health of 10 minutes ' +
      "or more that isn't part of a GymRollins workout included; the current week never breaks it. " +
```

In `server/src/mcp/tools/register.ts`, `get_training_insights`, replace `'target ranges, and the weekly workout streak. Use it to pick muscles to train or to judge weekly volume. ' +` with:

```ts
      'target ranges, and the weekly workout streak (outside workouts from Apple Health count while the owner lets ' +
      'agents read activity). Use it to pick muscles to train or to judge weekly volume. ' +
```

- [ ] **Step 4: Tell agents to check activity**

In `server/src/mcp/instructions.ts`, after the line `'- Before planning a session for a gym or for home, check its equipment with list_gyms and get_gym_equipment.',`, add:

```ts
  "- Before planning hard leg or conditioning days, check get_activity: the owner's walks, runs, rides and classes " +
  'from Apple Health, and their daily steps.',
```

- [ ] **Step 5: Run the tests**

Run: `cd server && npx vitest run test/mcp && npx tsc --noEmit`
Expected: everything passes, the earlier insights tests included. Their owner data has no outside workouts, and its switch is on.

- [ ] **Step 6: Commit**

```bash
git add server/src/mcp/tools/insights.ts server/src/mcp/tools/register.ts server/src/mcp/instructions.ts server/test/mcp/tools/insights.test.ts server/test/mcp/instructions.test.ts
git commit -m "feat(mcp): outside workouts count in the streak; agents check get_activity before hard leg days"
```

---

## Phase E: The app

### Task 15: The "Read activity from Apple Health" switch, and the coach prompt

**Files:**
- Modify (GymData): `Values/Profile.swift`, `Records/ProfileRecord.swift`, `Repositories/ProfileRepository.swift`, `Sync/SyncModels.swift` (`ProfileSnapshot`), `Sync/SyncStore+Profile.swift`
- Modify (GymSync): `DTO/ProfileDTO.swift`
- Modify (app):
  - `Features/Settings/SettingsPreferences.swift` and `Features/Onboarding/ProfileSetupView.swift`;
  - `App/AppEnvironment+Claude.swift`;
  - `Features/Claude/ClaudeConnectionView.swift` and `Features/Claude/ClaudePrompts.swift`.
- Test:
  - `ios/Packages/GymData/Tests/GymDataTests/ProfileReadActivityTests.swift` (new);
  - `ios/Packages/GymSync/Tests/GymSyncTests/ProfileReadActivityDTOTests.swift` (new);
  - `ios/GymRollinsTests/ClaudeEnvironmentTests.swift`, `ios/GymRollinsTests/SignOutAndDisconnectTests.swift`, `ios/GymRollinsTests/ClaudePromptsTests.swift`;
  - `ios/GymRollinsUITests/AgentsUITests.swift`.

The server side is already in place: the profile column (Task 10) and the reads (Tasks 12 to 14). This task follows the path of plan 32's `mcpLogWorkouts` through the app, with the opposite default: on.

- [ ] **Step 1: Write the failing tests**

Create `ios/Packages/GymData/Tests/GymDataTests/ProfileReadActivityTests.swift`:

```swift
import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Plan 39: "Read activity from Apple Health" is on until the owner turns it off, survives every profile save, and
/// travels with the synced profile.
@MainActor
@Suite struct ProfileReadActivityTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    @Test func itIsOnByDefaultAndSurvivesSaves() throws {
        defer { f.tearDown() }
        #expect(try f.profiles.load().mcpReadActivity)
        try f.profiles.setMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true,
                                         propose: true, autoApply: false, logWorkouts: false, readActivity: false)
        #expect(try !f.profiles.load().mcpReadActivity)
        try f.profiles.save(try f.profiles.load().withLimits("left knee", until: nil))
        #expect(try !f.profiles.load().mcpReadActivity, "saving the whole profile keeps it")
        try f.profiles.setMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true,
                                         propose: true, autoApply: false, logWorkouts: true)
        #expect(try !f.profiles.load().mcpReadActivity, "a change that doesn't name it keeps it")
    }

    @Test func itTravelsWithTheSyncedProfile() throws {
        defer { f.tearDown() }
        try f.profiles.setMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true,
                                         propose: true, autoApply: false, logWorkouts: false, readActivity: false)
        #expect(try f.store.dirtyProfile()?.value.mcpReadActivity == false)
        var remote = ProfileSnapshot()
        remote.mcpReadActivity = true
        try f.store.applyRemote(profile: SyncRow(value: remote, clientUpdatedAt: f.clock.now.addingTimeInterval(60)))
        #expect(try f.profiles.load().mcpReadActivity)
    }
}
```

Create `ios/Packages/GymSync/Tests/GymSyncTests/ProfileReadActivityDTOTests.swift`:

```swift
import Foundation
import GymData
import Testing
@testable import GymSync

/// Plan 39: "Read activity from Apple Health" travels as `mcp_read_activity`, a JSON boolean like the other switches. A
/// row from before the column existed reads as on, its default.
@Suite struct ProfileReadActivityDTOTests {
    @Test func theSwitchRoundTripsAndAnOldRowReadsAsOn() throws {
        var p = ProfileSnapshot()
        #expect(p.mcpReadActivity)
        p.mcpReadActivity = false
        let row = SyncRow(value: p, clientUpdatedAt: t0)
        let body = try SyncJSON.encoder.encode(ProfileDTO(row))
        #expect(String(decoding: body, as: UTF8.self).contains(#""mcp_read_activity":false"#))
        #expect(try !wire(ProfileDTO(row)).toDomain().value.mcpReadActivity)

        var json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        json.removeValue(forKey: "mcp_read_activity")
        let old = try SyncJSON.decoder.decode(ProfileDTO.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.mcpReadActivity)
        #expect(old.toDomain().value.mcpReadActivity)
    }
}
```

In `ios/GymRollinsTests/ClaudeEnvironmentTests.swift`, after `addWorkoutsIsOffUntilTurnedOnAndDisconnectTurnsItOff`, add:

```swift
    /// Plan 39: "Read activity from Apple Health" is on until the owner turns it off; a save that doesn't name it keeps
    /// it, and Disconnect all turns it off.
    @Test func readActivityIsOnUntilTurnedOffAndDisconnectTurnsItOff() async throws {
        let env = try makeEnv()
        #expect(env.profile.mcpReadActivity)
        try env.saveMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true, propose: true,
                                   autoApply: false, logWorkouts: false, readActivity: false)
        #expect(!env.profile.mcpReadActivity)
        try env.saveMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true, propose: true,
                                   autoApply: false, logWorkouts: true)
        #expect(!env.profile.mcpReadActivity && env.profile.mcpLogWorkouts)
        try env.saveMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true, propose: true,
                                   autoApply: false, logWorkouts: false, readActivity: true)
        #expect(try await env.disconnectClaude() == 0)
        #expect(!env.profile.mcpReadActivity)
    }
```

In `ios/GymRollinsTests/SignOutAndDisconnectTests.swift`, `successPushesTheFlagsBeforeRevoking`: after `#expect(await transport.storedProfile?.mcpLogWorkouts == false)`, add:

```swift
        #expect(await transport.storedProfile?.mcpReadActivity == false)
```

In `ios/GymRollinsTests/ClaudePromptsTests.swift`:
- rename `theCoachPromptIsEightLinesWithNoPersonalDetails` to `theCoachPromptIsNineLinesWithNoPersonalDetails`, and change `#expect(lines.count == 8)` to `#expect(lines.count == 9)`;
- add:

```swift
    @Test func itChecksActivityBeforeHardLegDays() {
        #expect(ClaudePrompts.coach.contains(
            "Before planning hard leg or conditioning days, check my activity from Apple Health (get_activity)."))
    }
```

In `ios/GymRollinsUITests/AgentsUITests.swift`, add:

```swift
    /// Plan 39: agents read the activity from Apple Health unless the owner turns it off here.
    func testReadActivityIsOnUntilTurnedOff() {
        openAgents([])
        let toggle = app.switches["agents.perm.readActivity"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        scrollTo(toggle)
        XCTAssertTrue(toggle.label.contains("Read activity from Apple Health"), toggle.label)
        XCTAssertEqual(toggle.value as? String, "1")
        flip(toggle)
        XCTAssertEqual(toggle.value as? String, "0")
    }
```

- [ ] **Step 2: Run the package tests to see them fail**

Run: `swift test --package-path ios/Packages/GymData --filter ProfileReadActivityTests` and `swift test --package-path ios/Packages/GymSync --filter ProfileReadActivityDTOTests`
Expected: the builds fail with `value of type 'Profile' has no member 'mcpReadActivity'` and `extra argument 'readActivity' in call`.

- [ ] **Step 3: Carry the switch through GymData**

In `ios/Packages/GymData/Sources/GymData/Values/Profile.swift`:
- After `public let mcpLogWorkouts: Bool`, add:

```swift
    /// Agents may read what was read from Apple Health (`get_activity` and the streak, plan 39); on by default.
    public let mcpReadActivity: Bool
```

- In `init`, replace `mcpAutoApply: Bool = false, mcpLogWorkouts: Bool = false, sex: ProfileSex? = nil,` with `mcpAutoApply: Bool = false, mcpLogWorkouts: Bool = false, mcpReadActivity: Bool = true, sex: ProfileSex? = nil,`. After `self.mcpLogWorkouts = mcpLogWorkouts`, add `self.mcpReadActivity = mcpReadActivity`.
- In `withLimits(_:until:)`, replace `mcpAutoApply: mcpAutoApply, mcpLogWorkouts: mcpLogWorkouts, sex: sex, birthYear: birthYear)` with:

```swift
                       mcpAutoApply: mcpAutoApply, mcpLogWorkouts: mcpLogWorkouts, mcpReadActivity: mcpReadActivity,
                       sex: sex, birthYear: birthYear)
```

In `ios/Packages/GymData/Sources/GymData/Records/ProfileRecord.swift`, after `public var mcpLogWorkouts: Bool = false`, add:

```swift
    /// Plan 39's "Read activity from Apple Health" for agents. A store from before it opens with the default, on.
    public var mcpReadActivity: Bool = true
```

In `ios/Packages/GymData/Sources/GymData/Repositories/ProfileRepository.swift`:
- In `load()`, replace `mcpAutoApply: r.mcpAutoApply, mcpLogWorkouts: r.mcpLogWorkouts,` with:

```swift
                       mcpAutoApply: r.mcpAutoApply, mcpLogWorkouts: r.mcpLogWorkouts,
                       mcpReadActivity: r.mcpReadActivity,
```

- In `save(_:)`, after `r.mcpLogWorkouts = p.mcpLogWorkouts`, add `r.mcpReadActivity = p.mcpReadActivity`.
- Replace the doc comment and signature of `setMcpPermissions`:

```swift
    /// Updates only what agents may do (no other field is rewritten), creating the profile if needed.
    public func setMcpPermissions(readWorkouts: Bool, readBody: Bool, readPlan: Bool, readGyms: Bool,
                                  propose: Bool, autoApply: Bool, logWorkouts: Bool) throws {
```

with:

```swift
    /// Updates only what agents may do (no other field is rewritten), creating the profile if needed. `readActivity`
    /// (plan 39) stays as it is when nil.
    public func setMcpPermissions(readWorkouts: Bool, readBody: Bool, readPlan: Bool, readGyms: Bool,
                                  propose: Bool, autoApply: Bool, logWorkouts: Bool,
                                  readActivity: Bool? = nil) throws {
```

  and after `r.mcpLogWorkouts = logWorkouts`, add `if let readActivity { r.mcpReadActivity = readActivity }`.

In `ios/Packages/GymData/Sources/GymData/Sync/SyncModels.swift`, `ProfileSnapshot`: after `public var mcpLogWorkouts = false`, add `public var mcpReadActivity = true`.

In `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+Profile.swift`:
- in `snapshot`, after `s.mcpLogWorkouts = mcpLogWorkouts`, add `s.mcpReadActivity = mcpReadActivity`;
- in `apply(_:)`, after `mcpLogWorkouts = s.mcpLogWorkouts`, add `mcpReadActivity = s.mcpReadActivity`.

- [ ] **Step 4: Carry it on the wire**

In `ios/Packages/GymSync/Sources/GymSync/DTO/ProfileDTO.swift`:
- After `public let mcpLogWorkouts: Bool`, add:

```swift
    /// Plan 39's "Read activity from Apple Health" (`mcp_read_activity`).
    public let mcpReadActivity: Bool
```

- In `CodingKeys`, after `case mcpLogWorkouts = "mcp_log_workouts"`, add `case mcpReadActivity = "mcp_read_activity"`.
- Replace the doc comment above `init(from:)` with:

```swift
    /// Synthesized decoding, except that a row without `mcp_read_gyms` or `mcp_read_activity` reads as on and one
    /// without `mcp_log_workouts` as off, each column's default.
```

- In `init(from:)`, after the `mcpLogWorkouts` line, add:

```swift
        mcpReadActivity = try c.decodeIfPresent(Bool.self, forKey: .mcpReadActivity) ?? true
```

- In `init(_ row:)`, after `mcpLogWorkouts = p.mcpLogWorkouts`, add `mcpReadActivity = p.mcpReadActivity`.
- In `toDomain()`, after `p.mcpLogWorkouts = mcpLogWorkouts`, add `p.mcpReadActivity = mcpReadActivity`.
- In `encode(to:)`, after `try c.encode(mcpLogWorkouts, forKey: .mcpLogWorkouts)`, add `try c.encode(mcpReadActivity, forKey: .mcpReadActivity)`.

- [ ] **Step 5: Run the package tests**

Run: `swift test --package-path ios/Packages/GymData --filter ProfileReadActivityTests && swift test --package-path ios/Packages/GymSync --filter 'ProfileReadActivityDTOTests|DTOTests'`
Expected: all pass.

- [ ] **Step 6: Show and save it in the app**

In `ios/GymRollins/Features/Settings/SettingsPreferences.swift`, `Profile.with(…)`:
- replace `mcpLogWorkouts: Bool? = nil) -> Profile {` with `mcpLogWorkouts: Bool? = nil, mcpReadActivity: Bool? = nil) -> Profile {`;
- replace the last line, `mcpAutoApply: mcpAutoApply ?? self.mcpAutoApply, mcpLogWorkouts: mcpLogWorkouts ?? self.mcpLogWorkouts)`, with:

```swift
               mcpAutoApply: mcpAutoApply ?? self.mcpAutoApply, mcpLogWorkouts: mcpLogWorkouts ?? self.mcpLogWorkouts,
               mcpReadActivity: mcpReadActivity ?? self.mcpReadActivity)
```

In `ios/GymRollins/Features/Onboarding/ProfileSetupView.swift`, replace `mcpLogWorkouts: current.mcpLogWorkouts)` with `mcpLogWorkouts: current.mcpLogWorkouts, mcpReadActivity: current.mcpReadActivity)`.

In `ios/GymRollins/App/AppEnvironment+Claude.swift`:
- Replace `saveMcpPermissions`:

```swift
    /// Saves what agents may do (synced with the profile); turning auto-apply on applies what's pending now.
    /// `readActivity` (plan 39) stays as it is when nil.
    func saveMcpPermissions(readWorkouts: Bool, readBody: Bool, readPlan: Bool, readGyms: Bool, propose: Bool,
                            autoApply: Bool, logWorkouts: Bool, readActivity: Bool? = nil) throws {
        try profiles.setMcpPermissions(readWorkouts: readWorkouts, readBody: readBody, readPlan: readPlan,
                                       readGyms: readGyms, propose: propose, autoApply: autoApply,
                                       logWorkouts: logWorkouts, readActivity: readActivity)
        reloadProfile()
        sync.localDataChanged()
        if autoApply { autoApplyProposals() }
    }
```

- In `disconnectClaude()`, replace `autoApply: false, logWorkouts: false)` with `autoApply: false, logWorkouts: false, readActivity: false)`.

In `ios/GymRollins/Features/Claude/ClaudeConnectionView.swift`:
- In `Permissions`, after `var logWorkouts = false`, add `var readActivity = true`. Replace `.none` with:

```swift
        static let none = Permissions(readWorkouts: false, readBody: false, readPlan: false, readGyms: false,
                                      propose: false, autoApply: false, logWorkouts: false, readActivity: false)
```

- In `permissionsSection`, after the `Toggle("Gyms", …)` line, add:

```swift
            Toggle("Read activity from Apple Health", isOn: $permissions.readActivity)
                .accessibilityIdentifier("agents.perm.readActivity")
```

  and in its footer, after the `claude.gymsNote` text, add:

```swift
                Text("Activity is what GymRollins reads from Apple Health: workouts from other apps and your daily "
                     + "steps, move, exercise and stand.")
                    .accessibilityIdentifier("agents.readActivityNote")
```

- In `permissions(_:)`, replace `logWorkouts: p.mcpLogWorkouts)` with `logWorkouts: p.mcpLogWorkouts, readActivity: p.mcpReadActivity)`.
- In `save(_:)`, replace `logWorkouts: new.logWorkouts)` with `logWorkouts: new.logWorkouts, readActivity: new.readActivity)`.

In `ios/GymRollins/Features/Claude/ClaudePrompts.swift`, after the line `- Before advising, read my profile, plan and recent workouts. Tell me briefly what you looked at.`, add:

```
        - Before planning hard leg or conditioning days, check my activity from Apple Health (get_activity).
```

(Keep the prompt free of digits: a test checks it.)

- [ ] **Step 7: Run the app tests**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/ClaudeEnvironmentTests -only-testing:GymRollinsTests/ClaudeDisconnectTests -only-testing:GymRollinsTests/ClaudePromptsTests -only-testing:GymRollinsTests/ProfileLimitsTests -only-testing:GymRollinsUITests/AgentsUITests/testReadActivityIsOnUntilTurnedOff`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add ios/Packages/GymData ios/Packages/GymSync ios/GymRollins/Features/Settings/SettingsPreferences.swift ios/GymRollins/Features/Onboarding/ProfileSetupView.swift ios/GymRollins/App/AppEnvironment+Claude.swift ios/GymRollins/Features/Claude ios/GymRollinsTests/ClaudeEnvironmentTests.swift ios/GymRollinsTests/SignOutAndDisconnectTests.swift ios/GymRollinsTests/ClaudePromptsTests.swift ios/GymRollinsUITests/AgentsUITests.swift
git commit -m "feat(app): \"Read activity from Apple Health\" for agents, on by default; the coach prompt checks activity"
```

---

### Task 16: The app reads activity: providers, Health wiring, purpose string, test seeds

**Files:**
- Create: `ios/GymRollins/App/AppEnvironment+Activity.swift`
- Modify: `ios/GymRollins/App/AppEnvironment+Health.swift`
- Modify: `ios/GymRollins/App/LaunchOptions.swift` (`-healthBeforeActivity`)
- Modify: `ios/project.yml` and `ios/GymRollins/Info.plist` (`NSHealthShareUsageDescription`)
- Test: `ios/GymRollinsTests/HealthActivityEnvironmentTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/GymRollinsTests/HealthActivityEnvironmentTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import GymHealth
import Testing
@testable import GymRollins

/// Plan 39 in the app. With `-fakeHealth`, the walk, the strength recording and the 7 days come in when Health is
/// turned on. The rules resolve them against the workouts on this iPhone, and the two switches hide what they read.
@MainActor
@Suite struct HealthActivityEnvironmentTests {
    private func makeEnv(_ extra: [String] = []) throws -> AppEnvironment {
        try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fakeHealth", "-fixedNow",
                                                             "2026-09-26T09:00:00Z"] + extra))
    }

    @Test func turningHealthOnBringsInTheWalkAndSevenDays() async throws {
        let env = try makeEnv()
        let revision = env.dataRevision
        #expect(await env.health.enable())
        #expect(env.resolvedActivities().shown.map(\.id).contains(FakeHealthStore.uiTestWalkId))
        #expect(env.recentActivityDays().count == 7)
        #expect(env.dataRevision > revision, "screens reload")
        #expect(try env.syncStore.dirtyHealthActivities().count == 2, "both go to the cloud")
    }

    @Test func theStrengthRecordingAttachesToSeedHistorysWorkout() async throws {
        let env = try makeEnv(["-seedHistory"])
        _ = await env.health.enable()
        let workout = try #require(try env.workouts.recent(limit: 1).first) // 19 Sep, 18:00 UTC
        #expect(env.measuredActivity(for: workout)?.id == FakeHealthStore.uiTestStrengthId)
        #expect(!env.resolvedActivities().shown.map(\.id).contains(FakeHealthStore.uiTestStrengthId))
        #expect(env.countedActivityStarts().count == 1, "the walk counts; the attached recording doesn't")
    }

    @Test func theSwitchesHideWhatTheyRead() async throws {
        let env = try makeEnv()
        _ = await env.health.enable()
        env.setReadsOutsideWorkouts(false)
        #expect(env.resolvedActivities().shown.isEmpty)
        #expect(env.countedActivityStarts().isEmpty)
        env.setReadsActivityDays(false)
        #expect(env.recentActivityDays().isEmpty)
        #expect(try env.activities.activities(since: nil).count == 2, "nothing stored is deleted")
    }

    @Test func healthTurnedOnBeforePlan39WaitsForTheAsk() async throws {
        let env = try makeEnv(["-healthBeforeActivity"])
        #expect(env.health.isEnabled)
        #expect(env.health.showsActivityCard)
        await env.syncHealth()
        #expect(env.recentActivityDays().isEmpty, "nothing is read before the ask")
        await env.allowHealthActivity()
        #expect(!env.health.needsActivityPermission)
        #expect(env.recentActivityDays().count == 7)
    }

    @Test func aSignedOutLaunchMayImportActivity() throws {
        #expect(try makeEnv().health.canImportActivity())
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/HealthActivityEnvironmentTests`
Expected: the build fails with `value of type 'AppEnvironment' has no member 'resolvedActivities'` (and `recentActivityDays`, `measuredActivity`, `countedActivityStarts`, `setReadsOutsideWorkouts`, `setReadsActivityDays`, `allowHealthActivity`).

- [ ] **Step 3: Write the providers**

Create `ios/GymRollins/App/AppEnvironment+Activity.swift`:

```swift
import Foundation
import GymCore
import GymData
import GymHealth

/// Apple Health activities in the app (plan 39):
/// - outside workouts after rules 6 and 7;
/// - days of activity;
/// - what counts toward the streak and the weekly goal;
/// - the two reading switches and the one-time ask.
///
/// A switch that's off only hides its data here: what is stored stays, on this iPhone and in the cloud.
extension AppEnvironment {
    /// Outside workouts that started at or after `since` (all when nil), resolved against the GymRollins workouts
    /// around them; none while "Workouts from other apps" is off. Falls back to none (logged) if the store fails.
    func resolvedActivities(since: Date? = nil) -> ResolvedActivities {
        guard health.state.readsOutsideWorkouts else { return .none }
        do {
            // A GymRollins workout that started up to a day earlier can still overlap the first outside workout.
            let spans = try workouts.finishedSpans(since: since?.addingTimeInterval(-86_400))
            return ActivityRules.resolve(try activities.activities(since: since), workouts: spans)
        } catch {
            Self.log.error("Load outside workouts failed: \(error.localizedDescription, privacy: .public)")
            return .none
        }
    }

    /// Start times of the outside workouts that count toward the streak and the weekly goal (decision 5).
    func countedActivityStarts() -> [Date] {
        resolvedActivities().counted.map(\.startedAt)
    }

    /// What Health measured during this GymRollins workout (rule 6): the Apple Watch's recording first.
    func measuredActivity(for workout: Workout) -> HealthActivity? {
        resolvedActivities(since: workout.startedAt.addingTimeInterval(-86_400)).measured(for: workout.id)
    }

    /// The days of activity among the last `count` days ending today, oldest first (a day without data isn't there);
    /// none while "Steps & activity" is off.
    func recentActivityDays(_ count: Int = 7) -> [ActivityDay] {
        guard health.state.readsActivityDays else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now())
        guard let first = calendar.date(byAdding: .day, value: -(count - 1), to: today) else { return [] }
        do {
            return try activities.days(from: ActivityDay.key(for: first, calendar: calendar),
                                       through: ActivityDay.key(for: today, calendar: calendar))
        } catch {
            Self.log.error("Load days of activity failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Settings › Apple Health › "Workouts from other apps": screens reload at once; turned on, Health is read now.
    func setReadsOutsideWorkouts(_ on: Bool) {
        health.setReadsOutsideWorkouts(on)
        bumpDataRevision()
        if on { Task { await health.importActivity() } }
    }

    /// Settings › Apple Health › "Steps & activity", the same way.
    func setReadsActivityDays(_ on: Bool) {
        health.setReadsActivityDays(on)
        bumpDataRevision()
        if on { Task { await health.importActivity() } }
    }

    /// The one-time ask (Today's card, Settings › Apple Health): asks Health for the activity types, then imports.
    func allowHealthActivity() async {
        await health.allowActivity()
        bumpDataRevision()
    }
}
```

- [ ] **Step 4: Wire Health: the fake's activity, the callback, the gate and the first pull**

Replace the whole of `ios/GymRollins/App/AppEnvironment+Health.swift` with this. Next to Task 8's version it has:
- the fake store's activity and the `-healthBeforeActivity` seed;
- `onActivityChanged`;
- `canImportActivity`, gated on its own cursor;
- the activity import after a round, while no anchor exists yet:

```swift
import Foundation
import GymCore
import GymData
import GymHealth
import GymSync

/// Apple Health wiring (plan 15; activity in plan 39): which store backs `health`, and when it syncs.
extension AppEnvironment {
    /// The real HealthKit store, or (DEBUG `-fakeHealth`) a seeded fake. UI-test launches keep Health's state in a
    /// throwaway defaults suite, so a previous run's "enabled" never leaks into the next.
    static func makeHealth(options: LaunchOptions, defaults: UserDefaults, workouts: WorkoutRepository,
                           body: BodyRepository, activities: ActivityRepository, calories: CalorieService,
                           now: @escaping () -> Date) -> HealthSync {
        let (store, healthDefaults) = healthBackend(options: options, defaults: defaults, now: now)
        return HealthSync(store: store, workouts: workouts, body: body, activities: activities,
                          defaults: healthDefaults, estimate: { calories.estimate($0) }, now: now)
    }

    private static func healthBackend(options: LaunchOptions, defaults: UserDefaults,
                                      now: () -> Date) -> (any HealthStore, UserDefaults) {
        #if DEBUG
        let store: any HealthStore = options.fakeHealth
            ? FakeHealthStore(seed: FakeHealthStore.uiTestSeed(now: now()),
                              outsideWorkouts: FakeHealthStore.uiTestOutsideWorkouts(now: now()),
                              days: FakeHealthStore.uiTestActivityDays(now: now(), calendar: .current))
            : HealthKitStore()
        if options.uiTesting, let suite = UserDefaults(suiteName: "uitest.health") {
            suite.removePersistentDomain(forName: "uitest.health")
            if options.healthBeforeActivity { seedHealthBeforeActivity(in: suite, now: now()) }
            return (store, suite)
        }
        return (store, defaults)
        #else
        return (HealthKitStore(), defaults)
        #endif
    }

    #if DEBUG
    /// `-healthBeforeActivity`: Health on, as a build from before plan 39 left it (the activity types never asked).
    private static func seedHealthBeforeActivity(in suite: UserDefaults, now: Date) {
        do { try HealthSyncState.saveEnabledBeforeActivity(to: suite, at: now) } catch {
            log.error("Seed Health state failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif

    /// Called once from `init`, after every stored property is set.
    func wireHealth() {
        calories.library = { [weak self] in self?.library ?? ExerciseLibrary(exercises: []) }
        health.onBodyChanged = { [weak self] in self?.healthImportedWeighIns() }
        health.onActivityChanged = { [weak self] in self?.healthImportedActivity() }
        // Signed in: import only once a sync round (with its pull) has finished, so the import sees what other devices
        // already imported (or deleted) instead of re-creating it.
        health.canImport = { [weak self] in
            guard let self, sync.hasRestoredSession else { return false } // signed-out may just mean "not yet"
            return sync.authState == .signedOut || sync.lastSyncedAt != nil
                || syncStore.cursor(for: .bodyweight) != nil
        }
        // The same for outside workouts and days of activity, by their own cursor (plan 39).
        health.canImportActivity = { [weak self] in
            guard let self, sync.hasRestoredSession else { return false }
            return sync.authState == .signedOut || sync.lastSyncedAt != nil
                || syncStore.cursor(for: .healthActivities) != nil
        }
        health.owner = { [weak self] in self?.syncStore.ownerUserId?.uuidString ?? "local" }
        sync.onRoundFinished = { [weak self] in
            guard let self else { return }
            health.localDataRestored(lastPull: sync.lastSyncedAt) // no-op unless a pull succeeded after a wipe
            guard health.isEnabled else { return }
            if health.state.anchor == nil { Task { await self.health.importBody() } }
            if health.state.activityAnchor == nil { Task { await self.health.importActivity() } }
        }
    }

    /// Workouts/weigh-ins changed locally: bring Health up to date (no-op while it's off).
    func exportToHealth() {
        guard health.isEnabled else { return }
        Task { await health.exportChanges() }
    }

    /// Rows arrived from the cloud (possibly the first pull, which unblocks the import): import + export.
    func syncHealthAfterPull() {
        guard health.isEnabled else { return }
        Task { await health.sync() }
    }

    /// App launch / foreground: refresh the permission status, then import + export.
    func syncHealth() async {
        await health.refreshPermissions()
        await health.sync()
    }

    /// New weigh-ins came from Health: screens reload and they sync to the cloud like manual ones.
    private func healthImportedWeighIns() {
        bumpDataRevision()
        calories.invalidate()
        sync.localDataChanged()
    }

    /// Outside workouts or days of activity came from Health: screens reload and they sync to the cloud.
    private func healthImportedActivity() {
        bumpDataRevision()
        sync.localDataChanged()
    }

    /// DEBUG `-workoutStartedMinutesAgo`: moves a new workout's start back so fixed-clock UI tests get a duration.
    func debugStartOffset(_ workout: Workout) -> Workout {
        #if DEBUG
        if let minutes = options.workoutStartedMinutesAgo, minutes > 0 {
            let start = workout.startedAt.addingTimeInterval(-minutes * 60)
            return Workout(id: workout.id, startedAt: start, endedAt: workout.endedAt,
                           pausedSeconds: workout.pausedSeconds, routineId: workout.routineId, name: workout.name,
                           entries: workout.entries, source: workout.source, note: workout.note,
                           gymId: workout.gymId)
        }
        #endif
        return workout
    }
}
```

In `ios/GymRollins/App/LaunchOptions.swift`:
- Replace `fakeHealth`'s doc comment with:

```swift
    /// DEBUG/UI-test only (`-fakeHealth`): Apple Health is an in-memory `FakeHealthStore` seeded with three Withings
    /// weigh-ins and plan 39's walk, strength recording and seven days of activity, so the Health flows can be tested
    /// on the simulator without HealthKit.
```

- After `let fakeHealth: Bool`, add:

```swift
    /// DEBUG/UI-test only (`-healthBeforeActivity`): Health starts on, as a build from before plan 39 left it, so Today
    /// offers the one-time "Bring in your Apple Watch activity" card.
    let healthBeforeActivity: Bool
```

- In the `#if DEBUG` branch of `init`, after `fakeHealth = arguments.contains("-fakeHealth")`, add `healthBeforeActivity = arguments.contains("-healthBeforeActivity")`. In the `#else` branch, after `fakeHealth = false`, add `healthBeforeActivity = false`.

- [ ] **Step 5: Say what is read, in the purpose string**

In `ios/project.yml`, the app target's `NSHealthShareUsageDescription` (the first one, not the watch's), replace:

```yaml
        NSHealthShareUsageDescription: >-
          GymRollins reads your weight and body fat from Apple Health to show them on the Body tab.
```

with:

```yaml
        NSHealthShareUsageDescription: >-
          GymRollins reads your weight and body fat for the Body tab, and the workouts other apps save, your steps,
          Activity rings and heart rate for the Log and Today.
```

In `ios/GymRollins/Info.plist`, replace the string after `<key>NSHealthShareUsageDescription</key>` with:

```xml
	<string>GymRollins reads your weight and body fat for the Body tab, and the workouts other apps save, your steps, Activity rings and heart rate for the Log and Today.</string>
```

- [ ] **Step 6: Run the tests**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/HealthActivityEnvironmentTests -only-testing:GymRollinsTests/CaloriesAndHealthTests`
Expected: all pass.

Run: `/usr/libexec/PlistBuddy -c 'Print :NSHealthShareUsageDescription' ios/GymRollins/Info.plist`
Expected: the new sentence. XcodeGen rewrites the plist from `ios/project.yml`, so the two must match.

- [ ] **Step 7: Commit**

```bash
git add ios/GymRollins/App/AppEnvironment+Activity.swift ios/GymRollins/App/AppEnvironment+Health.swift ios/GymRollins/App/LaunchOptions.swift ios/project.yml ios/GymRollins/Info.plist ios/GymRollinsTests/HealthActivityEnvironmentTests.swift
git commit -m "feat(app): resolve outside workouts and days of activity; wire the Health import and its test seeds"
```

---

### Task 17: Settings › Apple Health: "Reading from Health"

**Files:**
- Modify: `ios/GymRollins/Features/Settings/AppleHealthSettingsView.swift`
- Test: `ios/GymRollinsUITests/HealthActivityUITests.swift` (new; Tasks 18 to 20 add to it)

- [ ] **Step 1: Write the failing UI tests**

Create `ios/GymRollinsUITests/HealthActivityUITests.swift`:

```swift
import XCTest

/// Plan 39: Apple Health activities on the in-memory fake store. `-fakeHealth` also seeds:
/// - yesterday's Apple Watch walk (Fri 25 Sep, 07:00 UTC, 45 min, 180 kcal);
/// - an Apple Watch strength recording during `-seedHistory`'s workout of Sat 19 Sep;
/// - seven days of steps, today's being 4,210.
///
/// `-healthBeforeActivity` starts with Health on, as a build from before plan 39 left it.
@MainActor
final class HealthActivityUITests: XCTestCase {
    private let walk = "00000000-0000-4000-8000-00000000A001"
    private let strength = "00000000-0000-4000-8000-00000000A002"

    override func setUp() { continueAfterFailure = false }

    /// Log › Settings › Apple Health, scrolled clear of the floating tab bar (as in AppleHealthUITests).
    private func openHealthSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tapCenter()
        let row = app.buttons["settings.health"]
        let tabBar = app.tabBars.firstMatch
        func clearOfTabBar() -> Bool {
            row.exists && row.isHittable && (!tabBar.exists || row.frame.maxY < tabBar.frame.minY)
        }
        var swipes = 0
        while !clearOfTabBar() && swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        row.tapCenter()
        XCTAssertTrue(app.switches["health.toggle"].waitForExistence(timeout: 5))
    }

    /// Turns Health on there, which asks for every type, the activity ones included, and reads them.
    private func enableHealth(_ app: XCUIApplication) {
        openHealthSettings(app)
        let toggle = app.switches["health.toggle"]
        let inner = toggle.switches.firstMatch
        if inner.exists { inner.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let status = app.descendants(matching: .any)["health.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Connected")
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    /// Flips a SwiftUI `Toggle` and waits for its value to change (as in AgentsUITests).
    private func flip(_ toggle: XCUIElement, in app: XCUIApplication) {
        scrollTo(toggle, in: app)
        let before = toggle.value as? String
        let inner = toggle.switches.firstMatch
        if inner.exists { inner.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let changed = NSPredicate(format: "value != %@", before ?? "")
        wait(for: [expectation(for: changed, evaluatedWith: toggle)], timeout: 3)
    }

    /// The Log tab's root (it may still show Settings).
    private func openLog(_ app: XCUIApplication) {
        app.tabBars.buttons["Log"].tap()
        if !app.buttons["log.settings"].waitForExistence(timeout: 2) { app.tabBars.buttons["Log"].tap() }
        XCTAssertTrue(app.buttons["log.settings"].waitForExistence(timeout: 5))
    }

    // MARK: Settings

    func testSettingsReadsFromHealthWithTwoSwitches() {
        let app = XCUIApplication.launchReady(["-fakeHealth"])
        enableHealth(app)
        let workouts = app.switches["health.read.workouts"]
        scrollTo(workouts, in: app)
        XCTAssertEqual(workouts.value as? String, "1")
        XCTAssertEqual(app.switches["health.read.days"].value as? String, "1")
        XCTAssertFalse(app.buttons["health.activity.allow"].exists, "turning Health on asked for every type")
        flip(workouts, in: app)
        XCTAssertEqual(workouts.value as? String, "0")
    }

    func testSettingsAsksForActivityWhenHealthWasOnBefore() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-healthBeforeActivity"])
        openHealthSettings(app)
        let allow = app.buttons["health.activity.allow"]
        scrollTo(allow, in: app)
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        allow.tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: allow)], timeout: 10)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `scripts/ios-test.sh -only-testing:GymRollinsUITests/HealthActivityUITests`
Expected: both fail. `health.read.workouts` and `health.activity.allow` never appear.

- [ ] **Step 3: Add the section**

Replace the whole of `ios/GymRollins/Features/Settings/AppleHealthSettingsView.swift` with this. It adds the doc comment, the `readingSection` while Health is on, the toggle footer's new sentence and `allowActivity()`. `HealthStatusText` is unchanged:

```swift
import GymHealth
import SwiftUI
import UIKit

/// Settings → Apple Health: the opt-in toggle, what is shared, per-type write permission and "Open Settings". Since
/// plan 39 also what is read from Health: workouts from other apps and steps & activity, each with its switch, and the
/// ask for those types when Health was turned on before the app read them.
struct AppleHealthSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @State private var working = false

    private var health: HealthSync { env.health }

    var body: some View {
        Form {
            if health.isAvailable {
                toggleSection
                if health.isEnabled {
                    permissionsSection
                    readingSection
                }
                aboutSection
            } else {
                Section {
                    Text("Apple Health isn't available on this device.")
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("health.unavailable")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        .task { await health.refreshPermissions() }
    }

    private var toggleSection: some View {
        Section {
            Toggle("Sync with Apple Health", isOn: enabledBinding)
                .disabled(working)
                .accessibilityIdentifier("health.toggle")
            if working { ProgressView().accessibilityIdentifier("health.working") }
            if let error = health.lastError {
                Text(error).font(.footnote).foregroundStyle(Theme.destructive).accessibilityIdentifier("health.error")
            }
        } footer: {
            Text("Saves each finished workout with its estimated calories and the weigh-ins you log here. Reads your "
                 + "weight and body fat into the Body tab, and the workouts other apps record and your daily activity "
                 + "into the Log and Today.")
        }
    }

    private var permissionsSection: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                Badge(text: HealthStatusText.summary(health.permissions.summary),
                      kind: health.permissions.summary == .allowed ? .success : .record)
                    .accessibilityIdentifier("health.status")
            }
            ForEach(HealthDataType.allCases, id: \.self) { type in
                HStack {
                    Text(type.title)
                    Spacer()
                    Text(HealthStatusText.permission(health.permissions.permission(type)))
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("health.permission.\(type.rawValue)")
            }
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .accessibilityIdentifier("health.openSettings")
        } header: {
            Text("Saving to Health")
        } footer: {
            Text("Change these in Settings \u{2192} Health \u{2192} Data Access & Devices \u{2192} GymRollins. Apple "
                 + "Health doesn't tell apps whether they may read, so if your weight doesn't appear, turn on "
                 + "Weight and Body Fat Percentage there.")
        }
    }

    /// What the app reads from Health besides weight (plan 39). Off stops that import and hides it in the app; nothing
    /// already in the cloud is deleted.
    private var readingSection: some View {
        Section {
            if health.needsActivityPermission {
                Button("Allow Reading Your Activity") { allowActivity() }
                    .disabled(working)
                    .accessibilityIdentifier("health.activity.allow")
            }
            Toggle("Workouts from other apps", isOn: Binding(get: { health.state.readsOutsideWorkouts },
                                                            set: { env.setReadsOutsideWorkouts($0) }))
                .accessibilityIdentifier("health.read.workouts")
            Toggle("Steps & activity", isOn: Binding(get: { health.state.readsActivityDays },
                                                    set: { env.setReadsActivityDays($0) }))
                .accessibilityIdentifier("health.read.days")
        } header: {
            Text("Reading from Health")
        } footer: {
            Text("Walks, runs and classes your Apple Watch or other apps record show in the Log and count toward your "
                 + "streak. Steps, move, exercise and stand show on Today. Turning one off hides it here; nothing "
                 + "already in the cloud is deleted.")
        }
    }

    private var aboutSection: some View {
        Section {
            if let date = health.state.lastImportAt {
                Text("Last read \(date.formatted(.relative(presentation: .named))) \u{00B7} "
                     + "\(health.state.lastImportCount) weigh-in\(health.state.lastImportCount == 1 ? "" : "s") "
                     + "added last time")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("health.lastImport")
            }
            Text("Turning this off stops syncing; what's already in Health stays there.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { health.isEnabled }, set: { on in
            if on {
                working = true
                Task {
                    await health.enable()
                    working = false
                }
            } else {
                health.disable()
            }
        })
    }

    /// Asks Health for the activity types (the sheet lists only those never asked), then reads them.
    private func allowActivity() {
        working = true
        Task {
            await env.allowHealthActivity()
            working = false
        }
    }
}

enum HealthStatusText {
    static func summary(_ summary: HealthPermissions.Summary) -> String {
        switch summary {
        case .allowed: "Connected"
        case .partial: "Partially allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not asked yet"
        }
    }

    static func permission(_ permission: HealthPermission) -> String {
        switch permission {
        case .authorized: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not asked yet"
        }
    }

    /// The Settings row's badge.
    @MainActor
    static func badge(_ health: HealthSync) -> String {
        guard health.isAvailable else { return "Unavailable" }
        guard health.isEnabled else { return "Off" }
        return summary(health.permissions.summary)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/ios-test.sh -only-testing:GymRollinsUITests/HealthActivityUITests -only-testing:GymRollinsUITests/AppleHealthUITests`
Expected: all pass. The earlier Health tests are unchanged.

- [ ] **Step 5: Commit**

```bash
git add ios/GymRollins/Features/Settings/AppleHealthSettingsView.swift ios/GymRollinsUITests/HealthActivityUITests.swift
git commit -m "feat(app): Settings › Apple Health reads workouts from other apps and steps & activity, each with a switch"
```

---

### Task 18: Today: the one-time card and the Activity row

**Files:**
- Create: `ios/GymRollins/Features/Activity/ActivityText.swift`
- Create: `ios/GymRollins/Features/Activity/TodayActivitySection.swift`
- Create: `ios/GymRollins/Features/Activity/ActivityPermissionCard.swift`
- Create: `ios/GymRollins/Features/Activity/ActivityWeekSheet.swift`
- Modify: `ios/GymRollins/Features/Today/TodayView.swift`
- Test: `ios/GymRollinsTests/ActivityTextTests.swift`
- Test: `ios/GymRollinsUITests/HealthActivityUITests.swift`

`ActivityText` holds every string of Tasks 18 to 20, so it's written and tested whole here.

- [ ] **Step 1: Write the failing tests**

Create `ios/GymRollinsTests/ActivityTextTests.swift`:

```swift
import Foundation
import GymCore
import Testing
import UIKit
@testable import GymRollins

/// Plan 39: the words for outside workouts and days of activity, and every kind's SF Symbol.
@Suite struct ActivityTextTests {
    private let start = ISO8601DateFormatter().date(from: "2026-09-25T07:00:00Z")!

    private func walk(start: Date? = nil, kcal: Double? = 180, distanceM: Double? = 3_400, avgHr: Int? = 102,
                      maxHr: Int? = 121) -> HealthActivity {
        let begin = start ?? self.start
        return HealthActivity(id: UUID(), kind: "walking", startedAt: begin, endedAt: begin.addingTimeInterval(2_700),
                              durationS: 2_700, kcal: kcal, distanceM: distanceM, avgHr: avgHr, maxHr: maxHr,
                              sourceName: "Apple Watch", fromWatch: true)
    }

    @Test func factsAreTheDistanceInTheOwnersUnitThenCaloriesThenTheSource() {
        #expect(ActivityText.facts(walk(), unit: .kg) == "3.4 km \u{00B7} 180 kcal \u{00B7} Apple Watch")
        #expect(ActivityText.facts(walk(), unit: .lb) == "2.1 mi \u{00B7} 180 kcal \u{00B7} Apple Watch")
        #expect(ActivityText.facts(walk(kcal: nil, distanceM: nil), unit: .kg) == "Apple Watch")
        #expect(ActivityText.title(walk()) == "Walk")
        #expect(ActivityText.dateAndDuration(walk()).hasSuffix("\u{00B7} 45 min"))
    }

    @Test func theMeasuredLineSaysWhatWasMeasured() {
        #expect(ActivityText.measuredLine(walk(kcal: 412, avgHr: 128, maxHr: 162))
            == "Apple Watch measured 412 kcal \u{00B7} avg 128 bpm \u{00B7} max 162 bpm")
        #expect(ActivityText.measuredLine(walk(kcal: nil, maxHr: nil)) == "Apple Watch measured avg 102 bpm")
        #expect(ActivityText.measuredLine(walk(kcal: nil, avgHr: nil, maxHr: nil)) == nil)
    }

    @Test func theWeeksMeasuredCaloriesCountOnlyThisWeek() {
        let lastWeek = walk(start: start.addingTimeInterval(-8 * 86_400), kcal: 300)
        #expect(ActivityText.weekKcal([walk(), lastWeek], containing: start.addingTimeInterval(86_400)) == 180)
        #expect(ActivityText.otherKcalLine(1_240) == "+ \(1_240.formatted()) kcal from other activities (measured)")
    }

    @Test func todaysLineHasZerosBeforeAnyData() {
        let day = ActivityDay(day: "2026-09-26", steps: 4_210, moveKcal: 210.4, exerciseMin: 18, standH: 6)
        #expect(ActivityText.todayLine(day) == "\(4_210.formatted()) steps \u{00B7} 210 kcal \u{00B7} 18 min exercise")
        #expect(ActivityText.todayLine(nil) == "0 steps \u{00B7} 0 kcal \u{00B7} 0 min exercise")
        #expect(ActivityText.dayLine(day) == ActivityText.todayLine(day) + " \u{00B7} 6 h stand")
    }

    @Test func everySymbolExists() {
        for kind in OutsideWorkoutKind.allCases { #expect(UIImage(systemName: kind.symbol) != nil, "\(kind)") }
        #expect(UIImage(systemName: "figure.walk.motion") != nil)
        #expect(UIImage(systemName: "applewatch") != nil)
    }
}
```

In `ios/GymRollinsUITests/HealthActivityUITests.swift`, add before the closing brace:

```swift
    // MARK: Today

    func testTodayShowsTodaysStepsAndTheLastSevenDays() {
        let app = XCUIApplication.launchReady(["-fakeHealth"])
        enableHealth(app)
        app.tabBars.buttons["Today"].tap()
        let row = app.buttons["today.activity"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        scrollTo(row, in: app)
        XCTAssertTrue(row.label.contains("4,210 steps"), row.label)
        row.tap()
        let days = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'activity.day.'"))
        XCTAssertTrue(days.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(days.count, 7)
        app.buttons["activity.week.done"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    func testTheOneTimeCardAsksThenGoes() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-healthBeforeActivity"])
        let allow = app.buttons["today.activityCard.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["today.activity"].exists, "nothing is read before the ask")
        scrollTo(allow, in: app)
        allow.tap()
        XCTAssertTrue(app.buttons["today.activity"].waitForExistence(timeout: 10))
        XCTAssertFalse(allow.exists)
    }

    func testNotNowHidesTheCardForGood() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-healthBeforeActivity"])
        let notNow = app.buttons["today.activityCard.notNow"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 10))
        scrollTo(notNow, in: app)
        notNow.tap()
        XCTAssertFalse(app.buttons["today.activityCard.allow"].waitForExistence(timeout: 2))
        app.tabBars.buttons["Log"].tap()
        app.tabBars.buttons["Today"].tap()
        XCTAssertFalse(app.buttons["today.activityCard.allow"].waitForExistence(timeout: 2))
    }

    func testTurningStepsOffHidesTheRow() {
        let app = XCUIApplication.launchReady(["-fakeHealth"])
        enableHealth(app)
        flip(app.switches["health.read.days"], in: app)
        app.tabBars.buttons["Today"].tap()
        XCTAssertFalse(app.buttons["today.activity"].waitForExistence(timeout: 3))
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/ActivityTextTests`
Expected: the build fails with `cannot find 'ActivityText' in scope`.

- [ ] **Step 3: Write the words**

Create `ios/GymRollins/Features/Activity/ActivityText.swift`:

```swift
import Foundation
import GymCore

/// Every string the activity screens show (plan 39):
/// - outside workouts in the Log and their detail;
/// - the measured line on a GymRollins workout;
/// - the week's measured calories;
/// - Today's days of activity.
enum ActivityText {
    static func title(_ activity: HealthActivity) -> String { OutsideWorkoutKind(slug: activity.kind).title }

    static func symbol(_ activity: HealthActivity) -> String { OutsideWorkoutKind(slug: activity.kind).symbol }

    /// "Fri 25 Sep · 45 min" (active time).
    static func dateAndDuration(_ activity: HealthActivity) -> String {
        let date = activity.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(date) \u{00B7} \(DurationFormatter.hoursMinutes(activity.durationS))"
    }

    /// "3.4 km", or "2.1 mi" for a profile in lb (the distance unit of cardio sets); nil without a distance.
    static func distance(_ activity: HealthActivity, unit: WeightUnit) -> String? {
        guard let meters = activity.distanceM, meters > 0 else { return nil }
        let value = WeightFormatter.number(meters / SetFieldFormat.metersPerDistanceUnit(unit))
        return "\(value) \(SetFieldFormat.distanceUnit(unit))"
    }

    /// "3.4 km · 180 kcal · Apple Watch": what Health measured, then where it came from.
    static func facts(_ activity: HealthActivity, unit: WeightUnit) -> String {
        [distance(activity, unit: unit), activity.kcal.map(kcalText), activity.sourceName]
            .compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// "Apple Watch measured 412 kcal · avg 128 bpm · max 162 bpm", under a GymRollins workout's calories; nil when
    /// nothing was measured.
    static func measuredLine(_ activity: HealthActivity) -> String? {
        let parts = [activity.kcal.map(kcalText), activity.avgHr.map { "avg \($0) bpm" },
                     activity.maxHr.map { "max \($0) bpm" }].compactMap { $0 }
        return parts.isEmpty ? nil : "\(activity.sourceName) measured " + parts.joined(separator: " \u{00B7} ")
    }

    /// The measured kcal of the `shown` outside workouts that started in the ISO week (Mon–Sun) containing `date`: the
    /// week `CalorieService.weekTotal` sums.
    static func weekKcal(_ shown: [HealthActivity], containing date: Date,
                         calendar: Calendar = Calendar(identifier: .iso8601)) -> Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return 0 }
        return Int(shown.filter { week.contains($0.startedAt) }.compactMap(\.kcal).reduce(0, +).rounded())
    }

    /// "+ 640 kcal from other activities (measured)": under the week's estimate and never added to it (decision 10).
    static func otherKcalLine(_ kcal: Int) -> String { "+ \(kcal.formatted()) kcal from other activities (measured)" }

    /// Today's Activity row: "4,210 steps · 210 kcal · 18 min exercise", zeros before today's first data.
    static func todayLine(_ day: ActivityDay?) -> String {
        let move = Int((day?.moveKcal ?? 0).rounded())
        return "\((day?.steps ?? 0).formatted()) steps \u{00B7} \(move.formatted()) kcal \u{00B7} "
            + "\(day?.exerciseMin ?? 0) min exercise"
    }

    /// A day in the 7-day sheet: today's line, then the stand hours when an Apple Watch counted them.
    static func dayLine(_ day: ActivityDay) -> String {
        todayLine(day) + (day.standH.map { " \u{00B7} \($0) h stand" } ?? "")
    }

    private static func kcalText(_ value: Double) -> String { "\(Int(value.rounded()).formatted()) kcal" }
}
```

- [ ] **Step 4: Write the card, the row and the sheet**

Create `ios/GymRollins/Features/Activity/ActivityPermissionCard.swift`:

```swift
import SwiftUI

/// Today's one-time ask (plan 39), for people who turned Apple Health on before the app read activity. Allow asks
/// Health for the new types and reads them. Not now hides the card for good, and Settings › Apple Health still asks.
struct ActivityPermissionCard: View {
    let asking: Bool
    let allow: () -> Void
    let notNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Bring in your Apple Watch activity", systemImage: "applewatch")
                .font(.headline).foregroundStyle(Theme.textPrimary)
            Text("Walks, runs and classes from your Apple Watch and other apps show in the Log and count toward your "
                 + "streak. Your steps and Activity rings show here.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecondaryGlassButton(title: "Not now", identifier: "today.activityCard.notNow", action: notNow)
                SecondaryGlassButton(title: asking ? "Asking\u{2026}" : "Allow", identifier: "today.activityCard.allow",
                                     action: allow)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.activityCard")
    }
}
```

Create `ios/GymRollins/Features/Activity/ActivityWeekSheet.swift`:

```swift
import GymCore
import SwiftUI

/// The last 7 days of activity (plan 39), newest first, from Today's Activity row. Days without data aren't listed.
struct ActivityWeekSheet: View {
    /// Oldest first, as `AppEnvironment.recentActivityDays` gives them.
    let days: [ActivityDay]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(days.reversed()) { day in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(day)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    Text(ActivityText.dayLine(day)).font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("activity.day.\(day.day)")
                .listRowBackground(Theme.card)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Last 7 days")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("activity.week.done")
                }
            }
        }
        .presentationDetents([.large])
    }

    /// "Saturday 26 Sep".
    private static func title(_ day: ActivityDay) -> String {
        day.date(calendar: .current)?.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)) ?? day.day
    }
}
```

Create `ios/GymRollins/Features/Activity/TodayActivitySection.swift`:

```swift
import GymCore
import SwiftUI

/// Today's activity (plan 39):
/// - the one-time "Bring in your Apple Watch activity" card, while Health is on and the activity types were never
///   asked for;
/// - the Activity row with today's steps, move and exercise. A tap shows the last 7 days.
///
/// The row hides while "Steps & activity" is off or the last 7 days have no data.
struct TodayActivitySection: View {
    /// The last 7 days, oldest first (`AppEnvironment.recentActivityDays`).
    let days: [ActivityDay]
    @Environment(AppEnvironment.self) private var env
    @State private var showWeek = false
    @State private var asking = false

    var body: some View {
        Group {
            if env.health.showsActivityCard {
                ActivityPermissionCard(asking: asking, allow: allow, notNow: { env.health.dismissActivityCard() })
            }
            if !days.isEmpty { row }
        }
    }

    private var today: ActivityDay? {
        days.first { $0.day == ActivityDay.key(for: env.now(), calendar: .current) }
    }

    private var row: some View {
        Button { showWeek = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "figure.walk.motion").font(.title3).foregroundStyle(Theme.success)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity").font(.caption).foregroundStyle(Theme.textSecondary)
                    Text(ActivityText.todayLine(today)).font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("today.activity")
        .sheet(isPresented: $showWeek) { ActivityWeekSheet(days: days) }
    }

    private func allow() {
        guard !asking else { return }
        asking = true
        Task {
            await env.allowHealthActivity()
            asking = false
        }
    }
}
```

- [ ] **Step 5: Put them on Today**

In `ios/GymRollins/Features/Today/TodayView.swift`:
- After `@State private var savingShared: [Int] = []`, add:

```swift
    /// The last 7 days of activity (plan 39), read with each reload and whenever the data changes.
    @State private var activityDays: [ActivityDay] = []
```

- In `todayStatus`, after `RecoveryCard(identifier: "today.recovery")`, add:

```swift
        TodayActivitySection(days: activityDays)
```

- In the `.onChange(of: env.dataRevision)` handler, after `refreshModel()`, add `activityDays = env.recentActivityDays()`.
- In `reload()`, after its first line `historyCache = [:]`, add `activityDays = env.recentActivityDays()`.

- [ ] **Step 6: Run the tests**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/ActivityTextTests -only-testing:GymRollinsUITests/HealthActivityUITests`
Expected: all pass: 5 unit tests, and 6 UI tests so far.

Run: `scripts/ios-test.sh -only-testing:GymRollinsUITests/TodayPlanScreenUITests -only-testing:GymRollinsUITests/TodayDaysUITests`
Expected: all pass. Today's other content is unchanged, and the section is empty without Health.

- [ ] **Step 7: Commit**

```bash
git add ios/GymRollins/Features/Activity ios/GymRollins/Features/Today/TodayView.swift ios/GymRollinsTests/ActivityTextTests.swift ios/GymRollinsUITests/HealthActivityUITests.swift
git commit -m "feat(app): Today asks once for Apple Watch activity and shows today's steps, with the last 7 days"
```

---

### Task 19: Log: outside workouts in the history, the week strip and the measured kcal line

**Files:**
- Create: `ios/GymRollins/Features/Log/LogTimeline.swift`
- Create: `ios/GymRollins/Features/Activity/OutsideWorkoutCard.swift`
- Create: `ios/GymRollins/Features/Activity/OutsideWorkoutDetailView.swift`
- Modify: `ios/GymRollins/Features/Log/LogView.swift`
- Modify: `ios/Packages/GymData/Sources/GymData/Insights/WeekActivity.swift`
- Test: `ios/GymRollinsTests/LogTimelineTests.swift` (new), `ios/Packages/GymData/Tests/GymDataTests/WeekActivityTests.swift`, `ios/GymRollinsUITests/HealthActivityUITests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/GymRollinsTests/LogTimelineTests.swift`:

```swift
import Foundation
import GymCore
import Testing
@testable import GymRollins

/// Plan 39: the Log's history puts outside workouts between GymRollins workouts by start, newest first.
@Suite struct LogTimelineTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z")!

    private func workout(daysAgo: Double) -> Workout {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "Push")
    }

    private func walk(daysAgo: Double) -> HealthActivity {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return HealthActivity(id: UUID(), kind: "walking", startedAt: start, endedAt: start.addingTimeInterval(1_800),
                              durationS: 1_800, sourceName: "Apple Watch", fromWatch: true)
    }

    @Test func outsideWorkoutsSitBetweenWorkoutsNewestFirst() {
        let w1 = workout(daysAgo: 1), w3 = workout(daysAgo: 3)
        let recent = walk(daysAgo: 0.5), between = walk(daysAgo: 2)
        let items = LogTimeline.merge(workouts: [w1, w3], outside: [recent, between], complete: true)
        #expect(items.map(\.id) == [recent.id, w1.id, between.id, w3.id])
    }

    @Test func olderOutsideWorkoutsWaitForTheNextPage() {
        let w1 = workout(daysAgo: 1), w3 = workout(daysAgo: 3)
        let between = walk(daysAgo: 2), older = walk(daysAgo: 5)
        let page = LogTimeline.merge(workouts: [w1, w3], outside: [between, older], complete: false)
        #expect(page.map(\.id) == [w1.id, between.id, w3.id])
        let all = LogTimeline.merge(workouts: [w1, w3], outside: [between, older], complete: true)
        #expect(all.last?.id == older.id)
    }

    @Test func withoutWorkoutsEveryOutsideWorkoutShows() {
        let a = walk(daysAgo: 1), b = walk(daysAgo: 4)
        #expect(LogTimeline.merge(workouts: [], outside: [a, b], complete: true).map(\.id) == [a.id, b.id])
    }
}
```

In `ios/Packages/GymData/Tests/GymDataTests/WeekActivityTests.swift`, add inside the suite:

```swift
    /// Plan 39: an outside workout's active minutes are counted apart, so the strip can show them in a lighter shade.
    @Test func outsideWorkoutMinutesAreCountedApart() {
        let tue = ISO8601DateFormatter().date(from: "2026-09-22T07:00:00Z")!
        let walk = HealthActivity(id: UUID(), kind: "walking", startedAt: tue, endedAt: tue.addingTimeInterval(3_000),
                                  durationS: 2_700, sourceName: "Apple Watch", fromWatch: true)
        let lastWeek = HealthActivity(id: UUID(), kind: "running", startedAt: tue.addingTimeInterval(-7 * 86_400),
                                      endedAt: tue.addingTimeInterval(-7 * 86_400 + 1_800), durationS: 1_800,
                                      sourceName: "Strava")
        let sat = ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z")!
        let week = WeekActivity(workouts: [], outside: [walk, lastWeek], containing: sat, calendar: cal)
        #expect(week.days[1].minutes == 0)
        #expect(week.days[1].outsideMinutes == 45, "active time, pauses left out")
        #expect(week.days.map(\.outsideMinutes).reduce(0, +) == 45)
    }
```

In `ios/GymRollinsUITests/HealthActivityUITests.swift`, add before the closing brace:

```swift
    // MARK: Log

    func testAWalkShowsInTheLogAndOpensItsDetail() {
        let app = XCUIApplication.launchReady(["-fakeHealth"])
        enableHealth(app)
        openLog(app)
        let other = app.staticTexts["log.week.otherKcal"]
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        XCTAssertEqual(other.label, "+ 180 kcal from other activities (measured)")
        let card = app.buttons["log.outside.\(walk)"]
        scrollTo(card, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.label.contains("Walk") && card.label.contains("Apple Watch"), card.label)
        card.tap()
        let title = app.staticTexts["outside.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Walk")
        XCTAssertEqual(app.staticTexts["outside.avgHr"].label, "102 bpm")
        XCTAssertEqual(app.staticTexts["outside.healthNote"].label, "Change or delete it in the Health app.")
        app.buttons["outside.back"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    func testTurningWorkoutsFromOtherAppsOffHidesThem() {
        let app = XCUIApplication.launchReady(["-fakeHealth"])
        enableHealth(app)
        flip(app.switches["health.read.workouts"], in: app)
        openLog(app)
        XCTAssertFalse(app.buttons["log.outside.\(walk)"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["log.week.otherKcal"].exists)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path ios/Packages/GymData --filter WeekActivityTests`
Expected: the build fails with `extra argument 'outside' in call`.

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/LogTimelineTests`
Expected: the build fails with `cannot find 'LogTimeline' in scope`.

- [ ] **Step 3: Count outside minutes apart in the week**

Replace the whole of `ios/Packages/GymData/Sources/GymData/Insights/WeekActivity.swift` with:

```swift
import Foundation
import GymCore

/// Minutes of training per day for the ISO week containing a given date: GymRollins workouts' active time, and apart
/// from it the outside workouts' (plan 39). Pure; used by the Log tab's week strip.
public struct WeekActivity: Sendable, Equatable {
    public struct Day: Sendable, Equatable, Identifiable {
        public var id: Int { weekday }
        public let weekday: Int      // ISO 1 = Mon … 7 = Sun
        public let date: Date
        public let minutes: Int
        /// Outside workouts' active minutes that day; the Log shows them in a lighter shade.
        public let outsideMinutes: Int
        public let isToday: Bool
    }

    public let start: Date
    public let days: [Day]

    /// `outside` are the outside workouts shown on their own: an attached one is part of a GymRollins workout already.
    public init(workouts: [Workout], outside: [HealthActivity] = [], containing date: Date,
                calendar: Calendar = Calendar(identifier: .iso8601)) {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        self.start = start
        self.days = (0..<7).map { offset in
            let dayStart = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            let minutes = workouts
                .filter { calendar.isDate($0.startedAt, inSameDayAs: dayStart) }
                .reduce(0.0) { total, w in
                    total + max(0, (w.endedAt ?? w.startedAt).timeIntervalSince(w.startedAt) - w.pausedSeconds) / 60
                }
            let outsideMinutes = outside
                .filter { calendar.isDate($0.startedAt, inSameDayAs: dayStart) }
                .reduce(0.0) { total, activity in total + max(0, activity.durationS) / 60 }
            return Day(weekday: offset + 1, date: dayStart, minutes: Int(minutes), outsideMinutes: Int(outsideMinutes),
                       isToday: calendar.isDate(date, inSameDayAs: dayStart))
        }
    }
}
```

- [ ] **Step 4: Write the history, the card and the detail**

Create `ios/GymRollins/Features/Log/LogTimeline.swift`:

```swift
import Foundation
import GymCore

/// One row of the Log's history (plan 39): a GymRollins workout or an outside workout from Apple Health.
enum LogItem: Identifiable, Equatable {
    case workout(Workout)
    case outside(HealthActivity)

    var id: UUID {
        switch self {
        case .workout(let workout): workout.id
        case .outside(let activity): activity.id
        }
    }

    var startedAt: Date {
        switch self {
        case .workout(let workout): workout.startedAt
        case .outside(let activity): activity.startedAt
        }
    }
}

/// GymRollins workouts and outside workouts in one history, newest first.
enum LogTimeline {
    /// `workouts` is a page, newest first. While more may follow (`complete` false), an outside workout older than the
    /// page's last workout waits for the next page, so the list doesn't reshuffle when a page loads.
    static func merge(workouts: [Workout], outside: [HealthActivity], complete: Bool) -> [LogItem] {
        let oldest = complete ? nil : workouts.last?.startedAt
        let shown = outside.filter { activity in oldest.map { activity.startedAt >= $0 } ?? true }
        return (workouts.map(LogItem.workout) + shown.map(LogItem.outside)).sorted { a, b in
            a.startedAt != b.startedAt ? a.startedAt > b.startedAt : a.id.uuidString < b.id.uuidString
        }
    }
}
```

Create `ios/GymRollins/Features/Activity/OutsideWorkoutCard.swift`:

```swift
import GymCore
import SwiftUI

/// The navigation value of an outside workout's detail (a `UUID` already opens a GymRollins workout's).
struct OutsideWorkoutLink: Hashable {
    let id: UUID
}

/// An outside workout in the Log's history (plan 39), read-only. It shows the kind's icon, the name, the date and
/// duration, and what was measured with where it came from. The outline sets it apart from a GymRollins workout.
struct OutsideWorkoutCard: View {
    let activity: HealthActivity
    let unit: WeightUnit

    var body: some View {
        NavigationLink(value: OutsideWorkoutLink(id: activity.id)) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: ActivityText.symbol(activity))
                    .font(.title3).foregroundStyle(Theme.success)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ActivityText.dateAndDuration(activity)).font(.caption).foregroundStyle(Theme.textSecondary)
                    Text(ActivityText.title(activity)).font(.headline).foregroundStyle(Theme.textPrimary)
                    Text(ActivityText.facts(activity, unit: unit)).font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.divider, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("log.outside.\(activity.id.uuidString)")
    }
}
```

Create `ios/GymRollins/Features/Activity/OutsideWorkoutDetailView.swift`:

```swift
import GymCore
import SwiftUI

/// An outside workout (plan 39), pushed from its Log card. It shows what Health measured, with average and maximum
/// heart rate. Nothing can be edited here: Health is the source of truth, so it says where to change it.
struct OutsideWorkoutDetailView: View {
    let activityId: UUID
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var activity: HealthActivity?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }
                        .glassCircle()
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("outside.back")
                    Spacer()
                }
                if let activity { content(activity) }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: activityId) { load() }
    }

    @ViewBuilder
    private func content(_ activity: HealthActivity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(activity.startedAt.formatted(
                .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                Image(systemName: ActivityText.symbol(activity)).font(.title2).foregroundStyle(Theme.success)
                    .accessibilityHidden(true)
                Text(ActivityText.title(activity)).font(Theme.display(34)).foregroundStyle(Theme.textPrimary)
                    .accessibilityIdentifier("outside.title")
            }
            Text("From \(activity.sourceName)").font(.footnote).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("outside.source")
        }
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            stat("Duration", DurationFormatter.hoursMinutes(activity.durationS), identifier: "outside.duration")
            if let distance = ActivityText.distance(activity, unit: env.profile.unit) {
                stat("Distance", distance, identifier: "outside.distance")
            }
            if let kcal = activity.kcal {
                stat("Active calories", "\(Int(kcal.rounded()).formatted()) kcal", identifier: "outside.kcal")
            }
            if let avg = activity.avgHr { stat("Avg heart rate", "\(avg) bpm", identifier: "outside.avgHr") }
            if let max = activity.maxHr { stat("Max heart rate", "\(max) bpm", identifier: "outside.maxHr") }
        }
        Text("Change or delete it in the Health app.")
            .font(.footnote).foregroundStyle(Theme.textSecondary)
            .accessibilityIdentifier("outside.healthNote")
    }

    private func stat(_ label: String, _ value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.display(22)).foregroundStyle(Theme.textPrimary).accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.card, in: .rect(cornerRadius: 14))
    }

    private func load() {
        do { activity = try env.activities.activity(activityId) } catch {
            AppEnvironment.log.error("Load outside workout failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

- [ ] **Step 5: Show them in the Log**

Replace the whole of `ios/GymRollins/Features/Log/LogView.swift` with this. Next to today's file it adds:
- the outside workouts and the merged items;
- the lighter shade and its spoken minutes;
- the measured kcal line;
- the outside card in the list, and its destination:

```swift
import GymCore
import GymData
import SwiftUI

/// Log tab: a solid week-activity strip (minutes per day, outside workouts' in a lighter shade), the week's calories,
/// and the history: GymRollins workouts lazily paged 50 at a time, with the outside workouts from Apple Health between
/// them (plan 39). Tapping a card pushes `WorkoutDetailView` or `OutsideWorkoutDetailView`; the gear button pushes the
/// account screen (Settings in plan 07). Pull to refresh syncs.
struct LogView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var workouts: [Workout] = []
    /// Outside workouts shown on their own (rules 6 and 7), newest first.
    @State private var outside: [HealthActivity] = []
    /// The history: `workouts` with `outside` between them.
    @State private var items: [LogItem] = []
    @State private var recordCounts: [UUID: Int] = [:]
    @State private var limit = 50
    @State private var showSettings = false
    @State private var isLoadingMore = false
    @State private var showWorkout = false
    @State private var showImport = false
    @State private var showCalorieInfo = false

    private static let dayLetters = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
    private static let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    private static func spokenDay(_ day: WeekActivity.Day) -> String {
        let trained = day.minutes > 0 ? "\(day.minutes) minutes trained" : nil
        let other = day.outsideMinutes > 0 ? "\(day.outsideMinutes) minutes of other activity" : nil
        let none = trained == nil && other == nil ? "no workout" : nil
        return [dayNames[day.weekday - 1], day.isToday ? "today" : nil, trained, other, none].compactMap { $0 }
            .joined(separator: ", ")
    }

    /// A day with a GymRollins workout is the solid accent; a day with only outside workouts a lighter shade of it.
    private static func fill(_ day: WeekActivity.Day) -> Color {
        if day.minutes > 0 { return Theme.accent.opacity(0.85) }
        return day.outsideMinutes > 0 ? Theme.accent.opacity(0.35) : Theme.cardInner
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    SyncStatusBanner()
                    weekStrip
                    weekCalories
                    StreakCard()
                    SectionLabel(text: "Past workouts")
                    pastWorkouts
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 8)
                .padding(.bottom, 130)
            }
            .background(Theme.background)
            .refreshable { await env.sync.syncNow() }
            .navigationDestination(for: UUID.self) { WorkoutDetailView(workoutId: $0) }
            .navigationDestination(for: OutsideWorkoutLink.self) { OutsideWorkoutDetailView(activityId: $0.id) }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .navigationDestination(isPresented: $showImport) {
                ImportCSVView(onBack: { showImport = false }, onDone: { showImport = false })
            }
            .fullScreenCover(isPresented: $showWorkout) {
                if let session = env.session { WorkoutFlowView(session: session) }
            }
            .task(id: env.dataRevision) { reload() }
        }
    }

    private var header: some View {
        HStack {
            DisplayTitle(text: "Log", size: 44)
            Spacer()
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .glassCircle()
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("log.settings")
        }
        .padding(.top, 8)
    }

    private var weekStrip: some View {
        let week = WeekActivity(workouts: workouts, outside: outside, containing: env.now())
        return SolidCard {
            HStack(spacing: 4) {
                ForEach(week.days) { day in
                    VStack(spacing: 4) {
                        Text(Self.dayLetters[day.weekday - 1]).font(.caption2)
                            .foregroundStyle(day.isToday ? Theme.textPrimary : Theme.textSecondary)
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Self.fill(day))
                            if day.isToday {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [3]))
                            }
                            if day.minutes + day.outsideMinutes > 0 {
                                Text(DurationFormatter.minutes(TimeInterval((day.minutes + day.outsideMinutes) * 60)))
                                    .font(.caption2.weight(.bold))
                                    // Dark on the solid accent: white on it measured below 4.5:1 (audit: contrast).
                                    // The lighter shade is dark enough for the light text.
                                    .foregroundStyle(day.minutes > 0 ? Theme.background : Theme.textPrimary)
                                    .minimumScaleFactor(0.7)
                                    .lineLimit(1)
                            }
                        }
                        .frame(minHeight: 30)
                    }
                    .frame(maxWidth: .infinity)
                    // One spoken element per day ("Monday, 45 minutes trained") laid over the letter + tile, which
                    // are hidden: combined, the audit measured the tile fill as low-contrast text, and a label on the
                    // two-letter text itself reads as clipped.
                    .accessibilityHidden(true)
                    .overlay {
                        Color.clear
                            .accessibilityElement()
                            .accessibilityLabel(Self.spokenDay(day))
                            .accessibilityIdentifier("log.week.\(day.weekday)")
                    }
                }
            }
        }
    }

    /// "≈ 1,240 kcal this week (estimated)" under the strip, with the method sheet, and apart from it what Health
    /// measured for the week's outside workouts (decision 10: never added to the estimate).
    @ViewBuilder
    private var weekCalories: some View {
        let total = env.calories.weekTotal(of: workouts, containing: env.now())
        let other = ActivityText.weekKcal(outside, containing: env.now())
        if total > 0 {
            HStack {
                Text("\(CalorieText.kcal(total)) this week (estimated)")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("log.week.kcal")
                Spacer()
                Button { showCalorieInfo = true } label: { Image(systemName: "info.circle") }
                    .glassCircle()
                    .accessibilityLabel("How calories are estimated")
                    .accessibilityIdentifier("log.week.kcal.info")
            }
            .sheet(isPresented: $showCalorieInfo) { CalorieInfoSheet(estimate: nil) }
        }
        if other > 0 {
            Text(ActivityText.otherKcalLine(other))
                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("log.week.otherKcal")
        }
    }

    @ViewBuilder
    private var pastWorkouts: some View {
        if items.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: 8) {
                ForEach(items) { item in
                    Group {
                        switch item {
                        case .workout(let workout):
                            WorkoutCard(workout: workout, recordCount: recordCounts[workout.id] ?? 0,
                                        unit: env.profile.unit, library: env.library)
                        case .outside(let activity):
                            OutsideWorkoutCard(activity: activity, unit: env.profile.unit)
                        }
                    }
                    .onAppear {
                        if item.id == items.last?.id { loadMore() }
                    }
                }
            }
        }
    }

    /// First-run: no workouts logged or imported yet.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No workouts yet").font(.headline).accessibilityIdentifier("log.empty.title")
            Text("Start your first workout or import a CSV")
                .font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            if env.session != nil {
                SecondaryGlassButton(title: "Resume Workout", identifier: "log.empty.resumeWorkout") {
                    showWorkout = true
                }
            } else {
                SecondaryGlassButton(title: "Start a Workout", identifier: "log.empty.startWorkout") {
                    env.startSession(routine: nil)
                    showWorkout = true
                }
            }
            SecondaryGlassButton(title: "Import a CSV", identifier: "log.empty.importCSV") { showImport = true }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func reload() {
        workouts = (try? env.workouts.recent(limit: limit)) ?? []
        recordCounts = (try? env.workouts.recordCounts(ids: workouts.map(\.id))) ?? [:]
        outside = env.resolvedActivities().shown
        items = LogTimeline.merge(workouts: workouts, outside: outside, complete: workouts.count < limit)
    }

    /// `LazyVStack` still calls `onAppear` for the last row on every reload pass while it's the
    /// bottom row; `isLoadingMore` keeps a re-trigger during that pass from stacking another
    /// `limit` bump before the fetched page has replaced it.
    private func loadMore() {
        guard !isLoadingMore, workouts.count >= limit else { return }
        isLoadingMore = true
        limit += 50
        reload()
        isLoadingMore = false
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path ios/Packages/GymData --filter WeekActivityTests`
Expected: 2 tests pass.

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/LogTimelineTests -only-testing:GymRollinsUITests/HealthActivityUITests -only-testing:GymRollinsUITests/AppleHealthUITests`
Expected: all pass.

Run: `scripts/ios-test.sh -only-testing:GymRollinsUITests/AccessibilityAuditUITests`
Expected: all pass. The lighter tile uses the light text, which measures above 4.5:1 on it. If the audit flags a contrast issue on the strip, raise the shade's opacity to 0.45 and rerun.

- [ ] **Step 7: Commit**

```bash
git add ios/GymRollins/Features/Log ios/GymRollins/Features/Activity ios/Packages/GymData/Sources/GymData/Insights/WeekActivity.swift ios/Packages/GymData/Tests/GymDataTests/WeekActivityTests.swift ios/GymRollinsTests/LogTimelineTests.swift ios/GymRollinsUITests/HealthActivityUITests.swift
git commit -m "feat(app): outside workouts in the Log, with their detail, their minutes on the strip and their measured kcal"
```

---

### Task 20: A GymRollins workout shows what Health measured during it

**Files:**
- Modify: `ios/GymRollins/Features/Log/WorkoutDetailView.swift`
- Test: `ios/GymRollinsUITests/HealthActivityUITests.swift`

- [ ] **Step 1: Write the failing UI test**

In `ios/GymRollinsUITests/HealthActivityUITests.swift`, add before the closing brace:

```swift
    // MARK: Workout detail

    func testAnAppleWatchRecordingDuringAWorkoutShowsOnItAndNotOnItsOwn() {
        let app = XCUIApplication.launchReady(["-fakeHealth", "-seedHistory"])
        enableHealth(app)
        openLog(app)
        let workouts = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(workouts.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["log.outside.\(strength)"].exists, "attached: not listed on its own")
        workouts.firstMatch.tap() // Sat 19 Sep, the newest seeded workout
        let measured = app.staticTexts["detail.measured"]
        XCTAssertTrue(measured.waitForExistence(timeout: 5))
        XCTAssertEqual(measured.label, "Apple Watch measured 412 kcal \u{00B7} avg 128 bpm \u{00B7} max 162 bpm")
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `scripts/ios-test.sh -only-testing:GymRollinsUITests/HealthActivityUITests/testAnAppleWatchRecordingDuringAWorkoutShowsOnItAndNotOnItsOwn`
Expected: FAIL: `detail.measured` never appears.

- [ ] **Step 3: Show the measured line under the calorie card**

In `ios/GymRollins/Features/Log/WorkoutDetailView.swift`:
- After `@State private var addedBy: String?`, add:

```swift
    /// What Apple Health measured during this workout (plan 39, rule 6), read with it; nil when nothing is attached.
    @State private var measured: HealthActivity?
```

- In `scrollContent(_:)`, after the `CalorieCard(…)` call (the two lines ending `prefix: "detail")`), add:

```swift
                if let measured, let line = ActivityText.measuredLine(measured) {
                    HStack(spacing: 6) {
                        Image(systemName: "applewatch").accessibilityHidden(true)
                        Text(line).accessibilityIdentifier("detail.measured")
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                }
```

- In `load()`, after `addedBy = try? env.workouts.addedBy(workoutId)`, add:

```swift
        measured = workout.flatMap { env.measuredActivity(for: $0) }
```

- [ ] **Step 4: Run the tests**

Run: `scripts/ios-test.sh -only-testing:GymRollinsUITests/HealthActivityUITests -only-testing:GymRollinsUITests/AppleHealthUITests/testCaloriesShowWithoutHealthAndHealthLineStaysHidden`
Expected: all pass. Without Health, no measured line shows.

- [ ] **Step 5: Commit**

```bash
git add ios/GymRollins/Features/Log/WorkoutDetailView.swift ios/GymRollinsUITests/HealthActivityUITests.swift
git commit -m "feat(app): a workout shows what the Apple Watch measured during it"
```

---

### Task 21: The streak and the weekly goal count outside workouts

**Files:**
- Modify: `ios/GymRollins/Features/Insights/AppEnvironment+Insights.swift`
- Modify: `ios/GymRollins/Features/Insights/StreakViews.swift` (`SummaryInsightsSection.load()`)
- Test: `ios/GymRollinsTests/ActivityStreakTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ios/GymRollinsTests/ActivityStreakTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Plan 39, decision 5: an outside workout counts as a workout day for the streak and the weekly goal when both hold:
/// - it lasts 10 minutes or more;
/// - it isn't part of a GymRollins workout.
///
/// Turning "Workouts from other apps" off takes it out again.
@MainActor
@Suite struct ActivityStreakTests {
    private let iso = ISO8601DateFormatter()

    private func makeEnv() throws -> AppEnvironment {
        try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fakeHealth", "-fixedNow",
                                                             "2026-09-26T09:00:00Z"]))
    }

    private func date(_ text: String) throws -> Date { try #require(iso.date(from: text)) }

    private func outside(_ start: Date, minutes: Double, kind: String = "walking") -> HealthActivity {
        HealthActivity(id: UUID(), kind: kind, startedAt: start, endedAt: start.addingTimeInterval(minutes * 60),
                       durationS: minutes * 60, sourceName: "Apple Watch", fromWatch: true)
    }

    @Test func aWalkOnAnotherDayCountsButNotOneDuringAWorkoutOrUnderTenMinutes() throws {
        let env = try makeEnv()
        let monday = try date("2026-09-21T17:00:00Z")
        try env.workouts.save(Workout(startedAt: monday, endedAt: monday.addingTimeInterval(3_600), name: "Push"))
        let before = env.insights().streak.thisWeekDays
        try env.activities.add(outside(try date("2026-09-23T07:00:00Z"), minutes: 45), editedAt: env.now())
        try env.activities.add(outside(monday.addingTimeInterval(300), minutes: 50, kind: "traditional_strength"),
                               editedAt: env.now())
        try env.activities.add(outside(try date("2026-09-24T07:00:00Z"), minutes: 5, kind: "cooldown"),
                               editedAt: env.now())
        #expect(env.insights().streak.thisWeekDays == before + 1)
    }

    @Test func turningWorkoutsFromOtherAppsOffStopsThemCounting() throws {
        let env = try makeEnv()
        try env.activities.add(outside(try date("2026-09-23T07:00:00Z"), minutes: 45), editedAt: env.now())
        let counted = env.insights().streak.thisWeekDays
        env.setReadsOutsideWorkouts(false)
        #expect(env.insights().streak.thisWeekDays == counted - 1)
    }

    @Test func aWalkCanBeTheDayThatCompletesTheWeek() throws {
        let env = try makeEnv()
        let goal = env.profile.trainingDays
        try #require((2...6).contains(goal), "the seeded profile trains 2 to 6 days")
        let days = try (21...26).map { try date("2026-09-\($0)T12:00:00Z") } // Mon 21 … Sat 26, midday UTC
        for day in days.prefix(goal - 2) {
            try env.workouts.save(Workout(startedAt: day, endedAt: day.addingTimeInterval(3_600), name: "Push"))
        }
        let finished = Workout(startedAt: days[5], endedAt: days[5].addingTimeInterval(1_800), name: "Pull")
        try env.workouts.save(finished)
        #expect(try !env.completesWeeklyGoal(finished), "a workout day short")

        try env.activities.add(outside(days[goal - 2].addingTimeInterval(7_200), minutes: 40), editedAt: env.now())
        #expect(try env.completesWeeklyGoal(finished))
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/ActivityStreakTests`
Expected: the build fails with `value of type 'AppEnvironment' has no member 'completesWeeklyGoal'`.

- [ ] **Step 3: Count them**

In `ios/GymRollins/Features/Insights/AppEnvironment+Insights.swift`:
- Replace the doc comment of `insights()` with:

```swift
    /// Recovery, weekly sets and streak as of now; the streak counts the outside workouts that count (plan 39). Falls
    /// back to an empty snapshot (logged) if the store fails.
```

- Replace `startDates: try workouts.finishedStartDates(),` with:

```swift
                                         startDates: try workouts.finishedStartDates() + countedActivityStarts(),
```

- After `recentWorkouts()`, add:

```swift
    /// True when finishing `workout` brought its week to the weekly goal. The outside workouts that count are workout
    /// days of that week too (plan 39, decision 5).
    func completesWeeklyGoal(_ workout: Workout) throws -> Bool {
        let week = TrainingWeek.interval(containing: workout.startedAt, calendar: insightsCalendar)
        let others = try workouts.finished(since: week.start).filter { $0.id != workout.id }.map(\.startedAt)
        return StreakCalculator.completesWeeklyGoal(otherDates: others + countedActivityStarts(),
                                                    finished: workout.startedAt, goal: profile.trainingDays,
                                                    calendar: insightsCalendar)
    }
```

In `ios/GymRollins/Features/Insights/StreakViews.swift`, `SummaryInsightsSection.load()`, replace:

```swift
        let week = TrainingWeek.interval(containing: workout.startedAt, calendar: env.insightsCalendar)
        do {
            let others = try env.workouts.finished(since: week.start).filter { $0.id != workout.id }
            completedWeek = StreakCalculator.completesWeeklyGoal(otherDates: others.map(\.startedAt),
                                                                 finished: workout.startedAt,
                                                                 goal: env.profile.trainingDays,
                                                                 calendar: env.insightsCalendar)
        } catch {
```

with:

```swift
        do {
            completedWeek = try env.completesWeeklyGoal(workout)
        } catch {
```

- [ ] **Step 4: Run the tests**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/ActivityStreakTests -only-testing:GymRollinsTests/InsightsSnapshotTests -only-testing:GymRollinsUITests/InsightsUITests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add ios/GymRollins/Features/Insights/AppEnvironment+Insights.swift ios/GymRollins/Features/Insights/StreakViews.swift ios/GymRollinsTests/ActivityStreakTests.swift
git commit -m "feat(app): outside workouts of 10 minutes or more count toward the streak and the weekly goal"
```

---

### Task 22: Whole suites, review, screenshots, docs, build 4, outcome

**Files:**
- Modify: `ios/project.yml` (`CURRENT_PROJECT_VERSION`)
- Modify: `docs/release-readiness.md`
- Modify: this plan: append `## Outcome`.

- [ ] **Step 1: Run every suite**

Run, one by one, and write down the counts:
- `swift test --package-path ios/Packages/GymCore`
- `swift test --package-path ios/Packages/GymData`
- `swift test --package-path ios/Packages/GymSync`
- `swift test --package-path ios/Packages/GymHealth`
- `swift test --package-path ios/Packages/GymWatchLink`
- `cd server && npm test && npx tsc --noEmit`
- `scripts/ios-test.sh` (the whole app suite; read the result with the `xcresulttool` line under "Rules for implementers")

Expected: everything passes, apart from the known flake `AccessibilityAuditUITests/testUnblockEveryoneAudit`. If it fails, run it alone twice and write down both results. Any other failure is a bug: fix it test-first and rerun.

- [ ] **Step 2: Review the diff**

Have a reviewer agent read `git diff main...HEAD`. Ask it to check these hardest:
- the own-workout filter: no GymRollins workout, from the phone or the watch, may come back as an outside workout;
- every `await` in `HealthSync+Activity` is followed by a generation check;
- a decode of an old `HealthSyncState` can never fail;
- migration 0013 is safe on the live D1: it only adds tables, indexes, triggers and one defaulted column;
- `get_activity` and the streak read nothing while the switch is off.

Fix CRITICAL and HIGH findings test-first. Write the rest down in the outcome.

- [ ] **Step 3: Screenshots**

Use a temporary UI test kept outside the repo, in the session's scratchpad, launched with `-fakeHealth -seedHistory`. Capture these in the simulator's light and dark appearances (the app is dark-only, but a system-colour slip shows up):
- Today with the Activity row;
- Today with the one-time card (`-healthBeforeActivity`);
- the 7-day sheet;
- the Log with the walk card, the lighter strip tile and the measured kcal line;
- the walk's detail;
- the 19 Sep workout's detail with the measured line;
- Settings › Apple Health › Reading from Health;
- Settings › AI agents with the new switch.

Export them with `xcrun xcresulttool export attachments --path "$R" --output-path <scratchpad>/p39-shots`. Put them on one contact sheet and look at every screen: nothing cut off, no text one letter per line, and the strip's lighter tile readable. Fix what isn't, and rerun Step 1's affected classes.

- [ ] **Step 4: Privacy scan**

`git diff main...HEAD` and `git log main..HEAD --format=%B` must contain none of these:
- the Mac user name or surname;
- a Cloudflare account ID or a 32-hex id;
- secret-like values;
- `/Users/` paths;
- real people's names (the repo is public).

All fixture and test data here is made up. Fix and amend anything found.

- [ ] **Step 5: Docs and build 4**

In `docs/release-readiness.md`, replace the "Privacy policy text review" bullet with:

```markdown
- **Privacy policy text review** — Settings already has a Privacy/About section
  (`03ed477`), but the actual policy copy (what's collected, Claude's access scope, data
  deletion) needs the owner's sign-off before it's user-facing/App-Store-facing. Since plan 39 it must also say that
  Apple Health activity (workouts other apps saved, steps, move, exercise and stand, and those workouts' heart rate)
  is stored in the cloud with the account, and that connected agents can read it while "Read activity from Apple
  Health" is on. The App Store privacy answers change the same way: Health & Fitness data, linked to the user, not
  used for tracking.
```

In `ios/project.yml`, change `CURRENT_PROJECT_VERSION: "3"` to `CURRENT_PROJECT_VERSION: "4"`.

```bash
git add docs/release-readiness.md ios/project.yml
git commit -m "chore(app): build 1.0 (4); release notes for Health activity in the cloud"
```

- [ ] **Step 6: Write the outcome**

Append `## Outcome` to this plan. Include:
- the commits;
- the counts from Step 1;
- what the review, the screenshots and the privacy scan found and fixed;
- any deviation from this plan, with its reason;
- what wasn't verified: the real HealthKit reads on a device, and the owner steps below.

Commit it as `docs: plan 39 outcome`.

---

## Self-review

**Spec coverage**

| Spec | Where |
|---|---|
| §1–2 D1: two new kinds; outside workouts are not `Workout`s | Tasks 1, 4 (`HealthActivity`, `ActivityDay` and their records; nothing touches `WorkoutRecord`, PRs, `log_workout` or the workout cap) |
| D2: every workout GymRollins didn't write, plus steps, move, exercise and stand per day | Tasks 7 (reads), 8 (own-workout filter), 9 (days) |
| D3: both sync; agents read them with `get_activity` | Tasks 5, 6 (sync kinds), 10 (tables), 12 and 13 (MCP) |
| D4: "Read activity from Apple Health", on by default | Task 10 (column, profile entity), 12 (switch on every read), 15 (app switch, Disconnect all) |
| D5: ≥ 10 min and not attached count toward the streak and goal, in app and MCP | Task 3 (`counted`, fixture streak), 11 (TS), 14 (MCP insights), 21 (app streak and goal) |
| D6: ≥ half of the shorter attaches; the workout shows measured kcal and heart rate | Task 3 (rule 6), 11 (mirror), 20 (detail line), 19 (not listed) |
| D7: same kind ≥ 80 % is one session, Watch first then longer, both stored | Task 3 (rule 7), 11 (mirror), 4 (both rows stored) |
| D8: computed when read, one Swift function and a TS mirror on the same fixtures | Task 3 (`fixtures/activity.json`, `ActivityFixtureTests`), 11 (`activity.test.ts`) |
| D9: read-only; a Health deletion deletes here and in the cloud | Tasks 4 (no edit API), 8 (tombstones, unmatched deletions), 19 ("Change or delete it in the Health app.") |
| D10: estimated line GymRollins-only; "+ M kcal from other activities (measured)"; move kcal never added | Task 19 (`weekKcal` of shown outside workouts only); `get_activity`'s method says so (Task 13) |
| D11: merged statistics and Activity summaries, never summed samples | Task 7 (`HKStatisticsCollectionQueryDescriptor`, `HKActivitySummaryQueryDescriptor`) |
| D12: 2-year first import; anchored workouts with deletions; days re-read for the last week, written only when changed | Tasks 8, 9 (and decision 5 above) |
| D13: no background delivery: launch, foreground, enable, after a pull | Task 8 (`sync()` runs it), 16 (`onRoundFinished`; `syncHealthAfterPull` already calls `sync()`) |
| D14: out of scope | Nothing is added: no routes, no exports, no writes to Health |
| §3.1 fields; own-workout exclusions (metadata, bundles, external id) | Tasks 1, 7 (`isOwn`, `externalId`), 8 (`isOutside`) |
| §3.2 day keyed by the local day; no row without data | Tasks 1 (`ActivityDay.key`), 7 (only days with stats or a summary) |
| §3.3 limits mirrored and CHECKed; skipped, not clamped | Tasks 2, 8 and 9 (skip), 10 (CHECKs and drift test) |
| §4 read methods; read types not in `HealthDataType` | Task 7 |
| §4 state fields with optional storage; old state decodes | Task 7 (`HealthActivityStateTests`) |
| §4 one-time Today card; Settings has the same ask | Tasks 9 (`showsActivityCard`, `allowActivity`), 17, 18 |
| §4 Settings "Reading from Health", two switches on while Health is on; off stops and hides, cloud kept | Tasks 9, 16, 17 |
| §4 storage, two sync kinds after workouts, every registration point | Tasks 4, 5 (store tracking, reset, ownership, server move, status names), 6 (transport, engine, debug transports, pending count) |
| §4 Log cards, detail, lighter week strip, kcal line | Task 19 |
| §4 GymRollins workout detail measured line | Task 20 |
| §4 Today Activity row and 7-day sheet, hidden when off or empty | Task 18 |
| §4 streak and weekly goal | Task 21 |
| §4 purpose string | Task 16 (`project.yml` and `Info.plist`) |
| §5 migration 0013: tables, CHECKs, pull indexes, cascade, caps 20,000 and 5,000, `mcp_read_activity` default 1 | Task 10 (caps in `health_rows`, decision 2 above; key `(user_id, id)`, decision 1) |
| §5 generic sync, last write wins, `OWNED`, per-entity tests | Task 10 |
| §5 `get_activity` (days 1–84, default 28; ≤ 60; fields; `during_workout_id`; per-day and per-week totals) | Task 13 |
| §5 insights streak; `SERVER_INSTRUCTIONS` and the coach prompt; 16 → 17 tools | Tasks 14, 15, 13 |
| §6 rollout | "Owner steps" below; build 4 in Task 22 |
| §7 testing: GymCore, GymHealth, GymSync, server, UI | Tasks 1–3, 7–9, 6, 10–14, 15 and 17–20 |

**Placeholder scan.** No step says "TBD", "add error handling" or "similar to". Every code step gives the code. Where an edit is small, it names the exact text it goes after or replaces.

**Names used across tasks:**
- GymCore: `HealthActivity`, `ActivityDay.key(for:calendar:)`, `OutsideWorkoutKind(slug:)`, `WorkoutSpan`, `ResolvedActivities` (`shown`, `attached`, `attachedTo`, `counted`, `attached(to:)`, `measured(for:)`, `.none`) and `ActivityRules.resolve(_:workouts:)`.
- GymData: `ActivityRepository` (`activities(since:)`, `activity(_:)`, `hasRecord(id:)`, `add(_:editedAt:)`, `delete(_:)`, `days(from:through:)`, `save(day:)`), `WorkoutRepository.finishedSpans(since:)`, and `SyncStore.dirtyHealthActivities()` / `applyRemote(healthActivities:)` / `dirtyActivityDays()` / `applyRemote(activityDays:)`.
- GymHealth:
  - `HealthStore.outsideWorkoutChanges(since:anchor:)` and `activityDays(from:through:calendar:)`;
  - `HealthSync` (`activities`, `onActivityChanged`, `canImportActivity`, `importActivity()`, `needsActivityPermission`, `showsActivityCard`, `allowActivity()`, `dismissActivityCard()`, `setReadsOutsideWorkouts(_:)`, `setReadsActivityDays(_:)`);
  - `HealthSyncState.saveEnabledBeforeActivity(to:at:)`;
  - `FakeHealthStore` (`uiTestWalkId`, `uiTestStrengthId`, `uiTestOutsideWorkouts(now:)`, `uiTestActivityDays(now:calendar:)`).
- App: `AppEnvironment` (`activities`, `resolvedActivities(since:)`, `countedActivityStarts()`, `measuredActivity(for:)`, `recentActivityDays(_:)`, `setReadsOutsideWorkouts(_:)`, `setReadsActivityDays(_:)`, `allowHealthActivity()`, `completesWeeklyGoal(_:)`).
- Server: `resolveActivities`, `counted`, `Db.healthActivities` / `activityDays` / `workoutSpans`, `ReadSwitch` `'activity'` and `getActivity`.

All of these are defined in the tasks named above.

## Owner steps

Each of these needs the owner's go-ahead. The implementing agent doesn't run them.

1. **Server: migration first, then the Worker.** A Worker deployed first would fail every profile push, because the profile entity writes `mcp_read_activity`.
   - `cd server && npx wrangler d1 time-travel info gymrollins --remote`. Write down the bookmark it prints, the point to restore to.
   - `npx wrangler d1 migrations list gymrollins --remote`. It should list `0013_health_activities.sql` alone.
   - `npx wrangler d1 migrations apply gymrollins --remote`. It only adds tables, indexes, triggers and a defaulted column.
   - `npx wrangler deploy`.
   - Check that `/mcp` answers 401 without a token, and that the MCP tool list has 17 tools.
   - If anything goes wrong: `npx wrangler d1 time-travel restore gymrollins --bookmark=<bookmark> --remote`, then redeploy the previous Worker.
2. **App: TestFlight build 4.**
   - Build 1.0 (4) from the merged branch and upload it to TestFlight. Task 22 sets `CURRENT_PROJECT_VERSION: "4"`.
   - On the owner's phone: back up the Library first, install, open Today, tap **Allow** on the card, and check that the Log shows the week's outside workouts.
   - Builds before 4 ignore the new tables and the new profile column.
3. **Release notes.** Update the website privacy policy and the App Store privacy answers (the text in `docs/release-readiness.md`): Health activity is stored in the cloud and is readable by connected agents while "Read activity from Apple Health" is on.

## Outcome (2026-11-16)

**Commits** on `feat-health-activities`, from main 6ce667a:

| Commits | What |
| --- | --- |
| c192d78 | Spec and plan |
| c0acc8d, 9f556a3, 7bf385f | Tasks 1–3: the GymCore kinds, their limits mirrored on the server, rules 6 and 7 on the shared fixture |
| cdc721c, b47fc73, 07b4325 | Tasks 4–6: storage, the two sync kinds, GymSync's push and pull |
| f57b9da, cf5fd6b, 715f507 | Tasks 7–9: the HealthStore reads, the outside-workout import, days of activity and the one-time ask |
| d831a9a, 99cb11c, 70264b4, da4cd91, 48ceeaa, 65e83bc | Tasks 10–14: migration 0013, rules 6 and 7 in TypeScript, the MCP read switch, `get_activity`, the streak and the agents' instructions |
| 2260083, 27781b7, 3351e93, 88206b2 | Tasks 15–18: the agents' switch and coach prompt, the app wiring and test seeds, Settings, Today |
| 6599ddd, 1047c2f, d318a99, 55ed479 | Fixes from the Health import review: an empty first read (access denied, granted later) isn't remembered; another account re-imports; Health replacing GymRollins' own workout is neither a deletion nor an outside workout |
| 6e82b9a, b8d8e20, e7a5241 | Tasks 19–21: the Log, the measured block, the streak and the weekly goal |
| 9d53fed | Task 22: release notes, build 1.0 (4) |
| e7f224d, bc956be, f9c4697, 3c512c0, dd49445, 35fc006, 154c9c7 | Slow taps on Today and Library (the owner's report, below) |
| 52c5e0b, 3913575, 8dc1eae, 7f1890f, 697ffeb | Fixes from the whole-branch review: M4, L2, M3, M2, L1 |
| 4f31c83 | Average power, average cadence and total calories (the owner's pick) |
| babb42c, e805630 | The Apple Fitness look, and spec §4.1 |

**Review of the whole branch** (a reviewer agent read `git diff main...HEAD`). No CRITICAL or HIGH findings. Fixed:
- **M1:** every insights and Log reload fetched and resolved the whole outside-workout history on the main actor. Now `InsightsMemo` keeps the insights and the resolved activities until the data, the reading switches, the row counts, the time zone or the minute change (35fc006).
- **M2:** with Apple Health off, Settings hid the two reading switches, so what was already read couldn't be hidden. They now stay, with a footer sentence saying so (7f1890f).
- **M3:** the import saved once per row. A first import of 40 workouts and 30 days went from 70 saves to 2, with ids fetched in groups of 500 (8dc1eae).
- **M4:** the server resolved rules 6 and 7 with `Date.parse` inside a nested loop. It now parses each time once and skips spans that can't overlap (52c5e0b).
- **L1:** an outside workout's detail didn't reload. It now reloads with the data and says "This workout was removed from Health." when Health deleted it (697ffeb).
- **L2:** one out-of-range optional value (a heart rate, say) dropped the whole outside workout. Now only that value is left out (`DomainLimits.fitting(_:)`, 3913575).

Accepted as they are:
- **L3:** the days are re-read while no outside workout exists. It's one small statistics query per run.
- **L4:** an error in the outside-workout read skips the days read in the same run. The next run reads both.

**Added at the owner's request during the build:**
- **Power, cadence, total calories.** Outside workouts keep `avgPowerW` (cycling power, else running power), `avgCadenceRpm` (cycling cadence) and `totalKcal` (active plus resting energy; empty when active energy is missing). They're in GymCore, GymData, GymSync, migration 0013 (edited in place: it had never been applied), the server limits with their drift test, and `get_activity`. Workouts imported before this change don't gain them, because the anchored query doesn't re-read them; no plan 39 build had shipped.
- **The Apple Fitness look** for the activity screens only (spec §4.1): values coloured by metric in SF Pro Rounded with the unit in uppercase after them ("1.40MI", "138W"), the detail's big faint symbol and "Workout Details" grid in Fitness' order, the Log card's round icon. All colours keep 4.5:1 on the card and the background. The new `testHealthActivityAudit` found two clipping bugs, both fixed.
- **Slow taps on Today and Library** (Debug build, simulator; `docs/testing/performance.md`):

  | What | Before | After |
  | --- | --- | --- |
  | Today's reload after a sync | 394 ms | 103 ms |
  | Today's reload on returning to the app | ~190 ms | 33 ms |
  | 10 muscle badges | 54 ms | 1.5 ms |
  | Insights, reused | 86 ms | 0.1 ms |

  The causes were the muscle badge building its paths on every row, Today reading each exercise's whole history on every reload, the Library computing its search results three times per pass, and each insights card computing the insights again. The Log has no badges, which is why it stayed fast.

**Deviations from the plan:**
- The detail's title is the Health kind ("Cycling"), not Fitness' "Indoor Cycle": `OutsideWorkoutKind` has no indoor flag.
- Digits are proportional, not monospaced: these values don't tick, and tabular digits left a gap after every 1.
- The detail's date and source are on two lines, and the Log card's kind name wraps, because the audit found them clipped at large sizes.
- The ride with power and cadence is seeded in the app (`AppEnvironment.uiTestRide`), not in GymHealth's fake store.
- The insights memo is keyed by the minute, not the day, and `countedActivityStarts` isn't bounded to the import window: a bound would drop old outside workouts from the longest streak.
- `ActivityRules.resolve` is unchanged. It takes about 80 ms in Debug with 500 made-up outside workouts, once per data change, and it must keep matching the server's fixture.

**Tests:**
- GymCore 630, GymData 418, GymSync 291, GymHealth 117, GymWatchLink 63: all passed.
- Server `npx vitest run`: 853 passed in 62 files. `npx tsc --noEmit` is clean.
- Whole app suite on the code of e7a5241, before the speed fixes and the restyle: 1384 tests, 1359 passed, 19 skipped, 6 failed. The 5 `SharedWorkoutUITests` link tests fail the same way on main; the sixth was the `AccessibilityAuditUITests` flake below.
- After the restyle: the app unit target and the UI suites HealthActivity, Log, TodayDays, TodayFlex, TodayPlanScreen, TodayScope, Settings, AppleHealth, AccessibilityAudit and WorkoutScreens: 1209 passed, 5 skipped, 1 failed (`testAgentsAudit`; alone it passed once and failed once).
- `testAgentsAudit` is the known contrast flake on a glass edge. The new "Read activity from Apple Health" row is a plain `Toggle` like its neighbours, but its label and footer aren't on the audit's measured-label list (`agentSwitchLabels`), so the audit samples them. Adding them is a two-line change, not made here.
- Privacy scan of `git diff main...HEAD` and its commit messages: no surname, no account id, no `/Users/` paths beyond this plan's own rule text, no 32-hex ids, no secret-like values, no symlinks, no attribution trailers. gitleaks found no leaks in the 43 commits.

**Owner steps done:**
- 2026-11-16, on the owner's "Server, then upload": D1 bookmark saved (kept locally), migration 0013 applied remote (14 statements), Worker deployed as version df0ec800 (previous 0b30adbf). D1 before and after: 1 user, 159 workouts, 2927 sets, 6 routines, 30 weigh-ins; the new tables empty, `mcp_read_activity` on. `/mcp` 401, well-known 200, the two new sync routes 401 (404 before).
- Builds before 4 work against this server: they don't call the new routes, and a profile they push without `mcp_read_activity` keeps it on (the column's fallback is true).

**Not verified:**
- Real HealthKit reads on a device, including power and cadence from a gym bike through the Watch.
- The live MCP tool list (17 tools) and `get_activity` with a real agent's token.
- Build 4 isn't uploaded yet.
