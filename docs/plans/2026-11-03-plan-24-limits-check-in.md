# Plan 24: Injury note check-in

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An injury note can have an end date. On that date Today asks whether it's the right time to continue, and Yes
clears the note and offers to bring each paused routine back at 60% of its weights.

**Architecture:** `LimitsCheckIn` and `ReturnWeights` in GymCore hold the rules: when a date is due, which dates Not yet
allows, and what 60% means on a plate grid. `Profile.limitsUntil` is a calendar day stored and synced like `goalDate`, with
a new nullable `profiles.limits_until` column that `get_profile` returns. The app gets a shared `LimitsEditor` (Settings
and first-time setup), and `LimitsReminder` on Today, which shows the reminder or the check-in card.

**Tech stack:** Swift 6.2, SwiftUI, SwiftData, Swift Testing, XCUITest, Postgres + pgTAP, Deno (MCP).

**Spec:** `docs/specs/2026-11-03-limits-check-in-design.md`.

**Branch:** `feat-limits-checkin`, stacked on `feat-shared-workout`. No push. Supabase stays local.
Commit messages have no `Co-Authored-By`, `Generated with` or `Claude-Session` trailers: the owner forbids them.

---

## Decisions this plan makes

1. **Every full-profile builder must carry the date.** `ProfileRepository.save` writes every field, so a `Profile` built
   without `limitsUntil` erases it. The three builders are `Profile.with(...)` (all of Settings), `ProfileSetupView.save()`
   and `OwnerSeed.apply`. The first two pass it on, and the seed has none.
2. **`Profile.withLimits(_:until:)` is the only way the new screens change the note.** It trims the note, and an empty note
   gets no date. It lives in GymData next to the initializer, the one place that names every field.
3. **The server doesn't tie the date to the note.** No check constraint: the app ignores a date without a note
   (`LimitsCheckIn.isDue`), and a constraint would refuse a row an older build writes.
4. **60% of what Today would suggest now.** The base is `SessionPlanner.suggestion` from the person's history, without
   fitting to the gym, so it matches what Today would have shown. GymCore can't see `SessionPlanner` or the library, so
   `ReturnWeights.resume` takes the new weight as a closure and keeps the rules about what to skip.
5. **The floor is the empty bar** (`profile.barKg`) for barbell-loaded exercises, and the rounder's step for the rest.
6. **Today's reminder moves out of `TodayView`** (524 lines) into `LimitsReminder`, so `TodayView` gets shorter.
7. **The card keeps its own state after Yes.** Yes clears the note, so nothing is due any more, but the card stays up to
   offer the paused routines. `LimitsCheckInModel.showsCard(due:workoutRunning:)` decides.
8. **`-seedLimitsDue`** sets the seeded note to "Knee: no leg loading" ending yesterday, for tests and the walk. Plain
   `-seedOwner` keeps its note with no date, so no existing test sees the card.
9. **`AppEnvironment.swift` reaches 400 lines** with the one seed line. Accepted, rather than restructuring the seeds.
10. **Card copy uses the spec's words.** The resume button names the routine: "Resume Legs at 60%".

## File map

| File | Change |
|---|---|
| `ios/Packages/GymCore/Sources/GymCore/Limits/LimitsCheckIn.swift` | Create |
| `ios/Packages/GymCore/Sources/GymCore/Limits/ReturnWeights.swift` | Create |
| `ios/Packages/GymCore/Sources/GymCore/Model/Routine.swift` | `RoutineExercise.with(weightKg:setAt:)` |
| `ios/Packages/GymCore/Tests/GymCoreTests/Limits/LimitsCheckInTests.swift`, `ReturnWeightsTests.swift` | Create |
| `ios/Packages/GymData/Sources/GymData/Values/Profile.swift` | `limitsUntil`, `withLimits(_:until:)` |
| `ios/Packages/GymData/Sources/GymData/Records/ProfileRecord.swift` | `limitsUntil` |
| `ios/Packages/GymData/Sources/GymData/Repositories/ProfileRepository.swift` | load and save it |
| `ios/Packages/GymData/Sources/GymData/Sync/SyncModels.swift`, `SyncStore+Profile.swift` | snapshot and apply |
| `ios/Packages/GymData/Sources/GymData/Seed/OwnerSeed.swift` | `applyLimitsDue(to:now:calendar:)` |
| `ios/Packages/GymSync/Sources/GymSync/DTO/ProfileDTO.swift` | `limits_until` |
| `supabase/migrations/20261103000001_profile_limits_until.sql` | Create |
| `supabase/tests/database/limits_until.test.sql` | Create |
| `supabase/functions/mcp/db.ts`, `supabase_db.ts`, `tools/read.ts`, `tools/register.ts`, `tools/read_test.ts` | `get_profile` returns it |
| `ios/Packages/GymSync/Tests/GymSyncIntegrationTests/SyncRoundTripTests.swift` | carry the date |
| `ios/GymRollins/Features/Settings/SettingsPreferences.swift` | `with(...)` passes it on |
| `ios/GymRollins/App/LaunchOptions.swift`, `AppEnvironment.swift` | `-seedLimitsDue` |
| `ios/GymRollins/App/AppEnvironment+Limits.swift` | Create: due, save, clear, postpone, paused, resume |
| `ios/GymRollins/Features/Limits/LimitsEditor.swift` | Create |
| `ios/GymRollins/Features/Limits/LimitsSettingsView.swift`, `LimitsSettingsRow.swift` | Create |
| `ios/GymRollins/Features/Limits/LimitsCheckInModel.swift`, `LimitsCheckInCard.swift`, `LimitsReminder.swift` | Create |
| `ios/GymRollins/Features/Settings/SettingsView.swift` | one row |
| `ios/GymRollins/Features/Onboarding/ProfileSetupView.swift` | the editor |
| `ios/GymRollins/Features/Today/TodayView.swift` | `LimitsReminder` in place of the chip |
| `ios/GymRollinsTests/ProfileLimitsTests.swift`, `LimitsEnvironmentTests.swift`, `LimitsCheckInModelTests.swift` | Create |
| `ios/GymRollinsTests/ExportServiceTests.swift` | one test |
| `ios/GymRollinsUITests/LimitsCheckInUITests.swift` | Create |
| `ios/GymRollinsUITests/AccessibilityAuditUITests.swift`, `DynamicTypeUITests.swift` | Add tests |
| `README.md` | Feature sentence |

## How to run things

**GymCore:** `cd ios/Packages/GymCore && swift test --filter LimitsCheckInTests` (and `ReturnWeightsTests`), then
`scripts/coverage-gymcore.sh` from the repo root.

**GymData / GymSync:** `cd ios/Packages/GymData && swift test --filter RepositoryTests`, and
`cd ios/Packages/GymSync && swift test --filter GymSyncTests`.

**Database:** `scripts/test-db.sh` (it runs `db reset`, which also applies the new migration and wipes local accounts).
**MCP:** `scripts/test-mcp.sh`. **Sync against the stack:** `scripts/test-sync-integration.sh`.

**One app test class** (run from `ios/`, one `xcodebuild` at a time; the Mac runs short on memory, so if it sits at 0% CPU for
15 minutes, kill only your own and retry once):

```bash
xcodegen generate --quiet
xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' \
  -only-testing:GymRollinsTests/LimitsEnvironmentTests \
  -resultBundlePath build/TestResults-one-$(date +%s).xcresult -quiet
xcrun xcresulttool get test-results summary --path "$(ls -td build/TestResults-one-*.xcresult | head -1)"
```

Use only that destination: on the iOS 26.4 preview runtime, History and Swap sheets don't open, even on `main`. A new file
needs `xcodegen generate` first, because the project is generated.

---

### Task 1: The rules in GymCore

**Files:**
- Create: `ios/Packages/GymCore/Sources/GymCore/Limits/LimitsCheckIn.swift`
- Create: `ios/Packages/GymCore/Sources/GymCore/Limits/ReturnWeights.swift`
- Modify: `ios/Packages/GymCore/Sources/GymCore/Model/Routine.swift` (after `with(fixedWeightKg:)`, line 59)
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/Limits/LimitsCheckInTests.swift`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/Limits/ReturnWeightsTests.swift`

- [x] **Step 1: Write the failing tests**

`LimitsCheckInTests.swift`:

```swift
import Foundation
import Testing
@testable import GymCore

private func calendar(_ zone: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    return c
}

private func instant(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

@Suite struct LimitsCheckInTests {
    let utc = calendar("UTC")

    @Test func dueFromTheStartOfTheDayOn() {
        let until = instant("2026-10-26T00:00:00Z")
        #expect(!LimitsCheckIn.isDue(note: "Knee", until: until, now: instant("2026-10-25T23:59:59Z"), calendar: utc))
        #expect(LimitsCheckIn.isDue(note: "Knee", until: until, now: instant("2026-10-26T00:00:00Z"), calendar: utc))
        #expect(LimitsCheckIn.isDue(note: "Knee", until: until, now: instant("2026-11-01T09:00:00Z"), calendar: utc))
    }

    @Test func aDateSavedLateInTheDayAsksFromThatMorning() {
        let until = instant("2026-10-26T18:00:00Z")
        #expect(LimitsCheckIn.isDue(note: "Knee", until: until, now: instant("2026-10-26T08:00:00Z"), calendar: utc))
    }

    @Test func nothingIsDueWithoutANoteOrADate() {
        let past = instant("2026-10-01T00:00:00Z")
        let now = instant("2026-11-01T09:00:00Z")
        #expect(!LimitsCheckIn.isDue(note: "", until: past, now: now, calendar: utc))
        #expect(!LimitsCheckIn.isDue(note: "  \n", until: past, now: now, calendar: utc))
        #expect(!LimitsCheckIn.isDue(note: "Knee", until: nil, now: now, calendar: utc))
    }

    @Test func theDayIsReadInTheCalendarsTimeZone() {
        let auckland = calendar("Pacific/Auckland")
        // Midnight on 26 Oct in Auckland (NZDT, UTC+13) is 11:00 UTC on 25 Oct.
        let until = instant("2026-10-25T11:00:00Z")
        #expect(!LimitsCheckIn.isDue(note: "Knee", until: until, now: instant("2026-10-25T10:59:00Z"), calendar: auckland))
        #expect(LimitsCheckIn.isDue(note: "Knee", until: until, now: instant("2026-10-25T11:00:00Z"), calendar: auckland))
        #expect(LimitsCheckIn.isDue(note: "Knee", until: until, now: instant("2026-10-25T10:59:00Z"), calendar: utc))
    }

    @Test func laterIsTwoWeeksFromTodayAtMidnight() {
        #expect(LimitsCheckIn.laterDate(now: instant("2026-10-26T15:30:00Z"), calendar: utc)
                == instant("2026-11-09T00:00:00Z"))
    }

    @Test func allowedDatesRunFromTomorrowToAYearAhead() {
        let range = LimitsCheckIn.allowedDates(now: instant("2026-10-26T15:30:00Z"), calendar: utc)
        #expect(range.lowerBound == instant("2026-10-27T00:00:00Z"))
        #expect(range.upperBound == instant("2027-10-26T00:00:00Z"))
    }
}
```

`ReturnWeightsTests.swift`:

```swift
import Foundation
import Testing
@testable import GymCore

private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
private func inLb(_ kg: Double?) -> Double { UnitConverter.fromKg(kg ?? .nan, to: .lb) }
private let now = Date(timeIntervalSince1970: 1_793_000_000)

@Suite struct ReturnWeightsTests {
    @Test func sixtyPercentRoundsDownOnTheBarbellGrid() {
        let kg = ReturnWeights.weight(from: lb(135), rounder: .barbellLb, minimumKg: lb(45))
        #expect(abs(inLb(kg) - 80) < 0.001)
    }

    @Test func dumbbellAndMachineStepsRoundDownToo() {
        for (usual, light) in [(170.0, 100.0), (110, 65), (195, 115), (100, 60)] {
            let kg = ReturnWeights.weight(from: lb(usual), rounder: .dumbbellLb, minimumKg: lb(2.5))
            #expect(abs(inLb(kg) - light) < 0.001, "\(usual) lb")
        }
    }

    @Test func aGridWithAnOffsetStaysOnIt() {
        // A 45 lb bar with 5 lb the smallest plate loads 45, 55, 65 and so on.
        let rounder = LoadRounder(unit: .lb, step: 10, offset: 5)
        let kg = ReturnWeights.weight(from: lb(135), rounder: rounder, minimumKg: lb(45))
        #expect(abs(inLb(kg) - 75) < 0.001)
    }

    @Test func neverBelowTheEmptyBar() {
        let kg = ReturnWeights.weight(from: lb(55), rounder: .barbellLb, minimumKg: lb(45))
        #expect(abs(inLb(kg) - 45) < 0.001)
    }

    @Test func nothingToLowerIsNil() {
        #expect(ReturnWeights.weight(from: 0, rounder: .barbellLb, minimumKg: lb(45)) == nil)
        #expect(ReturnWeights.weight(from: -1, rounder: .barbellLb, minimumKg: lb(45)) == nil)
    }

    @Test func resumeUnpausesAndPlansWeightedRepExercisesFromNow() {
        let squat = RoutineExercise(exerciseId: "0043", sets: 4, reps: 6, repsMin: 6, weightKg: lb(135), incKg: lb(5))
        let plank = RoutineExercise(exerciseId: "plank", sets: 3, reps: 1, sec: 30, mode: .time)
        let bike = RoutineExercise(exerciseId: "bike", sets: 1, reps: 1, sec: 1200, mode: .cardio)
        let curl = RoutineExercise(exerciseId: "0586", sets: 3, reps: 12, weightKg: lb(100), policy: .off)
        let original = Routine(name: "Legs", emoji: "🦵", policy: .double, paused: true,
                               exercises: [squat, plank, bike, curl])
        let result = ReturnWeights.resume(original, now: now) { _ in lb(80) }
        #expect(!result.routine.paused)
        #expect(result.lowered == 1)
        #expect(result.routine.id == original.id)
        #expect(result.routine.name == "Legs")
        #expect(result.routine.emoji == "🦵")
        #expect(result.routine.policy == .double)
        #expect(result.routine.exercises.map(\.id) == original.exercises.map(\.id))
        let light = result.routine.exercises[0]
        #expect(light.weightKg == lb(80))
        #expect(light.weightSetAt == now)
        #expect(light.sets == 4 && light.reps == 6 && light.repsMin == 6 && light.incKg == lb(5))
        #expect(Array(result.routine.exercises.dropFirst()) == [plank, bike, curl])
    }

    @Test func aWeightTheCallerCantLowerStays() {
        let dip = RoutineExercise(exerciseId: "0251", sets: 3, reps: 10)
        let routine = Routine(name: "Core", paused: true, exercises: [dip])
        let result = ReturnWeights.resume(routine, now: now) { _ in nil }
        #expect(result.lowered == 0)
        #expect(result.routine.exercises == [dip])
        #expect(!result.routine.paused)
    }

    @Test func theRoutinesOffPolicyCountsUnlessTheItemOverridesIt() {
        let inherits = RoutineExercise(exerciseId: "0043", sets: 4, reps: 6, weightKg: lb(135))
        let overrides = RoutineExercise(exerciseId: "0085", sets: 3, reps: 8, weightKg: lb(135), policy: .linear)
        let routine = Routine(name: "Legs", policy: .off, paused: true, exercises: [inherits, overrides])
        let result = ReturnWeights.resume(routine, now: now) { _ in lb(80) }
        #expect(result.lowered == 1)
        #expect(result.routine.exercises[0] == inherits)
        #expect(result.routine.exercises[1].weightKg == lb(80))
        #expect(result.routine.exercises[1].weightSetAt == now)
    }
}
```

- [x] **Step 2: Run them and see them fail**

Run: `cd ios/Packages/GymCore && swift test --filter "LimitsCheckInTests|ReturnWeightsTests"`
Expected: build errors, "cannot find 'LimitsCheckIn' in scope" and "cannot find 'ReturnWeights' in scope".

- [x] **Step 3: Write the code**

`LimitsCheckIn.swift`:

```swift
import Foundation

/// When the injury note's end date has come, and the dates Not yet can move it to. Dates are calendar days in
/// `calendar`, the way the profile stores them.
public enum LimitsCheckIn {
    /// Not yet offers a date this many days from today.
    public static let laterDays = 14
    /// The furthest ahead an end date can be.
    public static let maxDaysAhead = 365

    /// On or after `until`'s day, when there's a note to ask about. A date with no note means nothing.
    public static func isDue(note: String, until: Date?, now: Date, calendar: Calendar) -> Bool {
        guard let until, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return calendar.startOfDay(for: now) >= calendar.startOfDay(for: until)
    }

    /// The date Not yet starts on: two weeks from today.
    public static func laterDate(now: Date, calendar: Calendar) -> Date {
        day(laterDays, from: now, calendar: calendar)
    }

    /// Tomorrow to a year ahead. An end date of today or earlier would ask straight away.
    public static func allowedDates(now: Date, calendar: Calendar) -> ClosedRange<Date> {
        day(1, from: now, calendar: calendar)...day(maxDaysAhead, from: now, calendar: calendar)
    }

    private static func day(_ offset: Int, from now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }
}
```

`ReturnWeights.swift`:

```swift
import Foundation

/// Coming back after an injury break: a paused routine restarts at 60% of what would have been planned, so the first
/// session is light and progression builds up again from what's logged.
public enum ReturnWeights {
    public static let fraction = 0.6

    /// 60% of `suggestedKg`, rounded down on `rounder`, and never below `minimumKg` (the empty bar, or the smallest
    /// step). Nil when there's no weight to lower.
    public static func weight(from suggestedKg: Double, rounder: LoadRounder, minimumKg: Double) -> Double? {
        guard suggestedKg > 0 else { return nil }
        return max(rounder.down(suggestedKg * fraction), minimumKg)
    }

    /// `routine` unpaused, with each weighted rep exercise planned at `newWeight(item)` from `now`. The engine prefers a
    /// weight planned after the last session, so the first session back uses it. Timed and cardio exercises, those whose
    /// progression is Off (the person sets those weights), and those `newWeight` returns nil for keep their weight.
    public static func resume(_ routine: Routine, now: Date,
                              newWeight: (RoutineExercise) -> Double?) -> (routine: Routine, lowered: Int) {
        let changes = routine.exercises.map { item -> RoutineExercise? in
            guard item.mode == .reps, (item.policy ?? routine.policy) != .off, let kg = newWeight(item) else { return nil }
            return item.with(weightKg: kg, setAt: now)
        }
        let items = zip(routine.exercises, changes).map { original, changed in changed ?? original }
        let resumed = Routine(id: routine.id, name: routine.name, emoji: routine.emoji, policy: routine.policy,
                              paused: false, exercises: items)
        return (resumed, changes.compactMap { $0 }.count)
    }
}
```

In `Routine.swift`, after `with(fixedWeightKg:)`:

```swift
    /// This item with a new planned weight, stamped `date` so progression uses it next session.
    public func with(weightKg: Double, setAt date: Date) -> RoutineExercise {
        RoutineExercise(id: id, exerciseId: exerciseId, sets: sets, reps: reps, repsMin: repsMin, sec: sec,
                        weightKg: weightKg, mode: mode, policy: policy, incKg: incKg, supersetGroup: supersetGroup,
                        weightSetAt: date, fixedWeightKg: fixedWeightKg)
    }
```

- [x] **Step 4: Run them and see them pass**

Run: `cd ios/Packages/GymCore && swift test --filter "LimitsCheckInTests|ReturnWeightsTests"`, then `swift test`, then
`scripts/coverage-gymcore.sh` from the repo root.
Expected: 14 tests pass, the whole package passes, and coverage stays at 90% or more.

- [x] **Step 5: Commit**

```bash
git add ios/Packages/GymCore
git commit -m "feat(core): when an injury note is due, and 60% weights for coming back"
```

---

### Task 2: The date on the profile, on the phone and in sync

**Files:**
- Modify: `ios/Packages/GymData/Sources/GymData/Values/Profile.swift`
- Modify: `ios/Packages/GymData/Sources/GymData/Records/ProfileRecord.swift:16`
- Modify: `ios/Packages/GymData/Sources/GymData/Repositories/ProfileRepository.swift:20,50`
- Modify: `ios/Packages/GymData/Sources/GymData/Sync/SyncModels.swift:76` (`ProfileSnapshot`)
- Modify: `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+Profile.swift:135,160`
- Modify: `ios/Packages/GymSync/Sources/GymSync/DTO/ProfileDTO.swift`
- Modify: `ios/GymRollins/Features/Settings/SettingsPreferences.swift:34`
- Modify: `ios/GymRollins/Features/Onboarding/ProfileSetupView.swift:161`
- Test: `ios/Packages/GymData/Tests/GymDataTests/RepositoryTests.swift`, `SyncStoreTests.swift`
- Test: `ios/Packages/GymSync/Tests/GymSyncTests/DTOTests.swift`
- Test: `ios/GymRollinsTests/ProfileLimitsTests.swift` (create), `ios/GymRollinsTests/ExportServiceTests.swift`

- [x] **Step 1: Write the failing tests**

In `RepositoryTests.swift`, next to `profileDefaultsAndSave`:

```swift
    @Test func theNotesEndDateSavesAndLoads() throws {
        let repo = ProfileRepository(context: container.mainContext, now: clock)
        let until = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 26))
        try repo.save(Profile(limits: "Knee: no leg loading", limitsUntil: until))
        #expect(try repo.load().limitsUntil == until)
        try repo.save(try repo.load().withLimits("", until: until))
        #expect(try repo.load().limits == "")
        #expect(try repo.load().limitsUntil == nil)
    }

    @Test func withLimitsTrimsTheNoteAndKeepsEverythingElse() {
        let until = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 26))
        let p = Profile(unit: .kg, restSec: 150, heightCm: 181, goalWeightKg: 85, trainingDays: 5, experience: "advanced",
                        limits: "old", deloadPct: 0.1, mcpAutoApply: true, sex: .male, birthYear: 1990)
        let changed = p.withLimits("  Knee: no leg loading \n", until: until)
        #expect(changed.limits == "Knee: no leg loading")
        #expect(changed.limitsUntil == until)
        #expect(changed.withLimits("old", until: nil) == p)
    }
```

In `SyncStoreTests.swift`, next to `strengthProfileMarksDirtyAndAppliesFromRemote`:

```swift
    @Test func theNotesEndDateMarksDirtyAndAppliesFromRemote() throws {
        defer { f.tearDown() }
        let until = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 26))
        try f.profiles.save(Profile(limits: "Knee", limitsUntil: until))
        let row = try #require(try f.store.dirtyProfile())
        #expect(row.value.limitsUntil == until)

        var remote = row.value
        remote.limitsUntil = nil
        f.clock.advance(60)
        try f.store.applyRemote(profile: SyncRow(value: remote, clientUpdatedAt: f.clock.now,
                                                 serverUpdatedAt: f.clock.now))
        #expect(try f.profiles.load().limitsUntil == nil)
    }
```

In `DTOTests.swift`:
- In `profileRoundTrip`, add `p.limitsUntil = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 26))`
  before `let row`, and after `let dto` add `#expect(dto.limitsUntil == "2026-10-26")`.
- In `profileEncodesSnakeCaseAndExplicitNulls`, add `#expect(keys.contains("limits_until"))` and
  `#expect(json?["limits_until"] is NSNull)`.
- Add `profileWithoutLimitsUntilReadsAsNone`, built the way `profileGymsFlagRoundTripsAndAnOldRowReadsAsOn` (line 71)
  builds its old row: encode a `ProfileDTO` whose snapshot has a date, remove the `limits_until` key from the JSON object,
  decode it, and `#expect(dto.toDomain().value.limitsUntil == nil)`.

Create `ios/GymRollinsTests/ProfileLimitsTests.swift`:

```swift
import Foundation
import GymData
import Testing
@testable import GymRollins

@Suite struct ProfileLimitsTests {
    @Test func settingsUpdatesKeepTheNotesEndDate() {
        let until = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 26))
        let p = Profile(limits: "Knee", limitsUntil: until)
        #expect(p.with(deloadPct: 0.1).limitsUntil == until)
        #expect(p.with(restSec: 90, warmupRestSec: 45).limitsUntil == until)
        #expect(p.withStandardEquipment(for: .kg).limitsUntil == until)
    }
}
```

In `ExportServiceTests.swift`, add `jsonBackupKeepsTheNotesEndDate`, set up the way `jsonBackupRoundTripsCounts` (line 56) is:
save `Profile(limits: "Knee", limitsUntil: until)` with the suite's profile repository before the backup, decode it with
`JSONDecoder.gymRollinsISO8601()`, and `#expect(decoded.profile.limitsUntil == until)`.

- [x] **Step 2: Run them and see them fail**

Run `swift test --filter RepositoryTests` and `--filter SyncStoreTests` in `ios/Packages/GymData`, and `--filter DTOTests` in
`ios/Packages/GymSync`.
Expected: build errors, "extra argument 'limitsUntil' in call" and "value of type 'Profile' has no member 'withLimits'".

- [x] **Step 3: Write the code**

`Profile.swift`: after `public let limits: String`, add

```swift
    /// The day the injury note is meant to end, a calendar day like `goalDate`; nil for none. Only counts with a note.
    public let limitsUntil: Date?
```

Add `limitsUntil: Date? = nil` to the initializer straight after `limits: String = ""`, and `self.limitsUntil = limitsUntil`
straight after `self.limits = limits`. After the initializer, add

```swift
    /// A copy with the injury note and its end date replaced. The note is trimmed, and an empty note has no date.
    public func withLimits(_ note: String, until: Date?) -> Profile {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return Profile(unit: unit, restSec: restSec, warmupRestSec: warmupRestSec, heightCm: heightCm,
                       goalWeightKg: goalWeightKg, goalDate: goalDate, trainingDays: trainingDays,
                       experience: experience, limits: trimmed, limitsUntil: trimmed.isEmpty ? nil : until,
                       deloadPct: deloadPct, barKg: barKg, plateInventory: plateInventory,
                       dumbbellStepKg: dumbbellStepKg, mcpReadWorkouts: mcpReadWorkouts, mcpReadBody: mcpReadBody,
                       mcpReadPlan: mcpReadPlan, mcpReadGyms: mcpReadGyms, mcpPropose: mcpPropose,
                       mcpAutoApply: mcpAutoApply, sex: sex, birthYear: birthYear)
    }
```

`ProfileRecord.swift`: after `public var limits: String`, add `public var limitsUntil: Date?`. It stays out of `init`, so
SwiftData's lightweight migration opens an old store with it nil.

`ProfileRepository.swift`: in `load()`, add `limitsUntil: r.limitsUntil,` straight after `limits: r.limits,`. In `save(_:)`,
add `r.limitsUntil = p.limitsUntil` straight after `r.limits = p.limits`.

`SyncModels.swift` (`ProfileSnapshot`): after `public var limits = ""`, add `public var limitsUntil: Date?`.

`SyncStore+Profile.swift`: in `snapshot`, add `s.limitsUntil = limitsUntil` after `s.limits = limits`. In `apply(_:)`, add
`limitsUntil = s.limitsUntil` after `limits = s.limits`.

`ProfileDTO.swift`:
- After `public let limits: String`, add
  ```swift
      /// Postgres `date`, `yyyy-MM-dd`: the injury note's end date.
      public let limitsUntil: String?
  ```
- In `CodingKeys`, add a line `case limitsUntil = "limits_until"`.
- In `init(from:)`, after `limits = ...`: `limitsUntil = try c.decodeIfPresent(String.self, forKey: .limitsUntil)`.
- In `init(_ row:)`, after `limits = p.limits`: `limitsUntil = p.limitsUntil.map { SyncDay.format($0) }`.
- In `toDomain()`, after `p.limits = limits`: `p.limitsUntil = limitsUntil.flatMap { SyncDay.parse($0) }`.
- In `encode(to:)`, after the `limits` line: `try c.encode(limitsUntil, forKey: .limitsUntil)`, which writes an explicit
  null, so clearing the date on the phone clears it on the server.

`SettingsPreferences.swift`, in `Profile.with(...)`: change `limits: limits,` to `limits: limits, limitsUntil: limitsUntil,`.

`ProfileSetupView.swift`, in `save()`: change `limits: limits,` to `limits: limits, limitsUntil: env.profile.limitsUntil,`.
Task 5 replaces this with the editor's own date.

- [x] **Step 4: Run them and see them pass**

Run `swift test` in `ios/Packages/GymData`, `swift test --filter GymSyncTests` in `ios/Packages/GymSync`, then the app's
`GymRollinsTests/ProfileLimitsTests` and `GymRollinsTests/ExportServiceTests`.
Expected: every suite passes, including the new tests.

- [x] **Step 5: Commit**

```bash
git add ios/Packages/GymData ios/Packages/GymSync ios/GymRollins ios/GymRollinsTests
git commit -m "feat(data): the injury note's end date on the profile, saved and synced"
```

---

### Task 3: The server column and Claude's read

**Files:**
- Create: `supabase/migrations/20261103000001_profile_limits_until.sql`
- Create: `supabase/tests/database/limits_until.test.sql`
- Modify: `supabase/functions/mcp/db.ts:13`, `supabase/functions/mcp/supabase_db.ts:26`
- Modify: `supabase/functions/mcp/tools/read.ts:44`, `supabase/functions/mcp/tools/register.ts:68-70`
- Test: `supabase/functions/mcp/tools/read_test.ts`
- Test: `ios/Packages/GymSync/Tests/GymSyncIntegrationTests/SyncRoundTripTests.swift:17-19`

- [x] **Step 1: Write the failing tests**

`supabase/tests/database/limits_until.test.sql`:

```sql
-- Plan 24: profiles.limits_until, the injury note's optional end date.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email, aud, role) values
  ('24242424-1111-1111-1111-242424242424', 'limits-until@test.local', 'authenticated', 'authenticated');

set local role authenticated;
set local request.jwt.claims = '{"sub":"24242424-1111-1111-1111-242424242424","role":"authenticated"}';

select lives_ok($$ insert into public.profiles (limits) values ('Knee: no leg loading') $$,
  'a profile needs no end date');
select is((select limits_until from public.profiles), null::date, 'the end date is empty by default');
select lives_ok($$ update public.profiles set limits_until = '2026-10-26',
  client_updated_at = now() + interval '1 second' $$, 'an end date can be set');
select is((select limits_until from public.profiles), '2026-10-26'::date, 'the end date reads back as a day');

select * from finish();
rollback;
```

In `read_test.ts`, add `assertEquals(out.limits_until, null)` to `get_profile: unit, goal with display, limits, permissions`,
and add:

```ts
Deno.test("get_profile: the injury note's end date", async () => {
  const out = json(await getProfile(await ctx((d) => {
    d.profile!.limits_until = '2026-10-26'
  })))
  assertEquals(out.limits, 'left knee: no deep knee flexion')
  assertEquals(out.limits_until, '2026-10-26')
})
```

In `SyncRoundTripTests.secondDevicePullsEverythingTheFirstPushed`, add `limitsUntil: SyncDay.parse("2026-10-26"),` straight
after `limits: "left shoulder",`. The test already checks that the second device loads the same profile.

- [x] **Step 2: Run them and see them fail**

Run `scripts/test-db.sh` and `scripts/test-mcp.sh`.
Expected: pgTAP fails on `column "limits_until" does not exist`, and the Deno test fails because `limits_until` is
`undefined`, and with the type error on `d.profile!.limits_until`.

- [x] **Step 3: Write the code**

`supabase/migrations/20261103000001_profile_limits_until.sql`:

```sql
-- Plan 24: the injury note's optional end date. On or after it, Today asks whether it's the right time to continue. A
-- calendar day like goal_date, synced like the rest of the profile (last write wins). Nullable and not tied to
-- `limits` by a check: the app ignores a date without a note, and older builds don't send the column. RLS is unchanged.
alter table public.profiles add column limits_until date;
```

`db.ts`, in `Profile` after `limits: string`:

```ts
  /** The injury note's end date, yyyy-MM-dd; null or absent for none. */
  limits_until?: string | null
```

`supabase_db.ts`: in `PROFILE_COLS`, change `limits, deload_pct` to `limits, limits_until, deload_pct`.

`read.ts`, in `getProfile` after `limits: p.limits,`: `limits_until: p.limits_until ?? null,`.

`register.ts`: change the description's `'injury limits, deload %, and which permissions Claude has.'` to
`'injury limits and the day they end, deload %, and which permissions Claude has.'`.

- [x] **Step 4: Run them and see them pass**

Run `scripts/test-db.sh`, `scripts/test-mcp.sh` and `scripts/test-sync-integration.sh`.
Expected: all pass, with the 4 new pgTAP assertions, the new Deno test and the round trip carrying the date. `db reset`
wipes local accounts. That's expected, and the final task recreates the owner's two test logins.

- [x] **Step 5: Commit**

```bash
git add supabase ios/Packages/GymSync/Tests
git commit -m "feat(server): profiles.limits_until, returned by get_profile"
```

---

### Task 4: The app's actions

**Files:**
- Create: `ios/GymRollins/App/AppEnvironment+Limits.swift`
- Modify: `ios/Packages/GymData/Sources/GymData/Seed/OwnerSeed.swift` (after `apply`)
- Modify: `ios/GymRollins/App/LaunchOptions.swift`
- Modify: `ios/GymRollins/App/AppEnvironment.swift:98-106` (the `seedOwner` block)
- Test: `ios/GymRollinsTests/LimitsEnvironmentTests.swift` (create)

- [x] **Step 1: Write the failing tests**

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@MainActor
@Suite struct LimitsEnvironmentTests {
    private func makeEnv(_ extra: [String] = []) throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: "LimitsEnvironmentTests.\(UUID())"))
        return try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow", "2026-11-01T09:00:00Z"]
                                                         + extra), defaults: defaults)
    }

    private func lb(_ kg: Double?) -> Double { UnitConverter.fromKg(kg ?? .nan, to: .lb) }

    private func legsRoutine(_ env: AppEnvironment) throws -> Routine {
        try #require(try env.routines.all().first { $0.name == "Legs" })
    }

    @Test func theSeededNoteHasNoDateSoNothingIsDue() throws {
        let env = try makeEnv()
        #expect(env.profile.limitsUntil == nil)
        #expect(!env.limitsCheckInDue)
    }

    @Test func seedLimitsDueEndsTheNoteYesterday() throws {
        let env = try makeEnv(["-seedLimitsDue"])
        let today = Calendar.current.startOfDay(for: env.now())
        #expect(env.profile.limits == "Knee: no leg loading")
        #expect(env.profile.limitsUntil == Calendar.current.date(byAdding: .day, value: -1, to: today))
        #expect(env.limitsCheckInDue)
    }

    @Test func notYetMovesTheDateAndStopsAsking() throws {
        let env = try makeEnv(["-seedLimitsDue"])
        let later = LimitsCheckIn.laterDate(now: env.now(), calendar: .current)
        try env.postponeLimits(to: later)
        #expect(env.profile.limits == "Knee: no leg loading")
        #expect(env.profile.limitsUntil == later)
        #expect(!env.limitsCheckInDue)
    }

    @Test func yesClearsTheNoteAndItsDate() throws {
        let env = try makeEnv(["-seedLimitsDue"])
        try env.clearLimits()
        #expect(env.profile.limits == "")
        #expect(env.profile.limitsUntil == nil)
        #expect(!env.limitsCheckInDue)
    }

    @Test func anEmptyNoteKeepsNoDate() throws {
        let env = try makeEnv()
        try env.saveLimits("   ", until: LimitsCheckIn.laterDate(now: env.now(), calendar: .current))
        #expect(env.profile.limits == "")
        #expect(env.profile.limitsUntil == nil)
    }

    @Test func thePausedRoutinesAreTheOnesToOffer() throws {
        let env = try makeEnv()
        #expect(try env.pausedRoutines().map(\.name) == ["Legs"])
    }

    @Test func resumeBringsLegsBackAtSixtyPercent() throws {
        let env = try makeEnv()
        let result = try #require(try env.resumeAtReturnWeights(try legsRoutine(env).id))
        #expect(result.name == "Legs")
        #expect(result.lowered == 6)
        let legs = try legsRoutine(env)
        #expect(!legs.paused)
        let weights = Dictionary(uniqueKeysWithValues: legs.exercises.map { ($0.exerciseId, lb($0.weightKg)) })
        let expected: [String: Double] = ["0085": 80, "0043": 80, "0739": 100, "0586": 60, "0585": 65, "0594": 115]
        for (id, light) in expected { #expect(abs((weights[id] ?? 0) - light) < 0.01, "\(id)") }
        #expect(legs.exercises.allSatisfy { $0.weightSetAt == env.now() })
        #expect(try env.pausedRoutines().isEmpty)
    }

    @Test func theFirstSessionBackIsLightAndProgressionCarriesOnFromIt() throws {
        let env = try makeEnv()
        _ = try env.resumeAtReturnWeights(try legsRoutine(env).id)
        let legs = try legsRoutine(env)
        let squat = try #require(legs.exercises.first { $0.exerciseId == "0043" })
        let suggest = { (history: [SessionResult]) in
            SessionPlanner.suggestion(for: squat, policy: squat.policy ?? legs.policy, profile: env.profile,
                                      exercise: env.library.exercise("0043"), history: history)
        }
        let first = suggest(try env.workouts.history(exerciseId: "0043", limit: 5))
        #expect(abs(lb(first.weightKg) - 80) < 0.01)

        let start = env.now().addingTimeInterval(3_600)
        try env.workouts.save(Workout(startedAt: start, endedAt: start.addingTimeInterval(3_000), name: "Legs", entries: [
            WorkoutEntry(exerciseId: "0043", sets: (0..<4).map { _ in
                WorkoutSet(weightKg: first.weightKg, reps: 6, done: true, completedAt: start) }),
        ]))
        let next = suggest(try env.workouts.history(exerciseId: "0043", limit: 5))
        #expect(abs(lb(next.weightKg) - 85) < 0.01)
    }

    @Test func timedOffAndBodyweightExercisesKeepTheirWeights() throws {
        let env = try makeEnv()
        let plank = RoutineExercise(exerciseId: "0464", sets: 3, reps: 1, sec: 30, mode: .time)
        let fixedCurl = RoutineExercise(exerciseId: "0586", sets: 3, reps: 12, weightKg: UnitConverter.toKg(100, from: .lb),
                                        policy: .off)
        let dip = RoutineExercise(exerciseId: "0251", sets: 3, reps: 10)
        let core = Routine(name: "Core", paused: true, exercises: [plank, fixedCurl, dip])
        try env.routines.upsert(core)
        let result = try #require(try env.resumeAtReturnWeights(core.id))
        #expect(result.lowered == 0)
        let saved = try #require(try env.routines.routine(core.id))
        #expect(!saved.paused)
        #expect(saved.exercises == core.exercises)
    }

    @Test func onlyAPausedRoutineCanBeResumed() throws {
        let env = try makeEnv()
        #expect(try env.resumeAtReturnWeights(UUID()) == nil)
        let push = try #require(try env.routines.all().first { !$0.paused })
        #expect(try env.resumeAtReturnWeights(push.id) == nil)
        let legs = try legsRoutine(env)
        #expect(try env.resumeAtReturnWeights(legs.id) != nil)
        #expect(try env.resumeAtReturnWeights(legs.id) == nil)
    }
}
```

- [x] **Step 2: Run them and see them fail**

Run: the app's `GymRollinsTests/LimitsEnvironmentTests`.
Expected: build errors, "value of type 'AppEnvironment' has no member 'limitsCheckInDue'" and the like.

- [x] **Step 3: Write the code**

`OwnerSeed.swift`, after `apply(to:now:)`:

```swift
    /// `-seedLimitsDue`: the knee note ended yesterday, so Today asks about it (check-in tests and QA).
    public static func applyLimitsDue(to context: ModelContext, now: Date, calendar: Calendar = .current) throws {
        let profiles = ProfileRepository(context: context, now: { now })
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        try profiles.save(try profiles.load().withLimits("Knee: no leg loading", until: yesterday))
    }
```

`LaunchOptions.swift`: after `seedStrength`'s declaration, add

```swift
    /// DEBUG/UI-test only (`-seedLimitsDue`): the seeded injury note ended yesterday, so Today shows the check-in card.
    let seedLimitsDue: Bool
```

In the DEBUG branch of `init`, after `seedStrength = ...`: `seedLimitsDue = arguments.contains("-seedLimitsDue")`. In the
`#else` branch, after `seedStrength = false`: `seedLimitsDue = false`.

`AppEnvironment.swift`, inside `if options.seedOwner {` after the `seedPlank` line:

```swift
            if options.seedLimitsDue { try OwnerSeed.applyLimitsDue(to: context, now: now()) }
```

`AppEnvironment+Limits.swift`:

```swift
import Foundation
import GymCore
import GymData

extension AppEnvironment {
    /// Whether Today asks about the injury note: its end date has come.
    var limitsCheckInDue: Bool {
        LimitsCheckIn.isDue(note: profile.limits, until: profile.limitsUntil, now: now(), calendar: .current)
    }

    /// Saves the injury note and its end date. An empty note keeps no date (`Profile.withLimits`).
    func saveLimits(_ note: String, until: Date?) throws {
        try profiles.save(profile.withLimits(note, until: until))
        reloadProfile()
        planChanged()
    }

    /// The check-in's Yes: the note and its date go.
    func clearLimits() throws { try saveLimits("", until: nil) }

    /// The check-in's Not yet: ask again on `date`.
    func postponeLimits(to date: Date) throws { try saveLimits(profile.limits, until: date) }

    func pausedRoutines() throws -> [Routine] { try routines.all().filter(\.paused) }

    /// Resume at 60%: the routine unpaused with its weighted exercises lowered, in one save, so a failure leaves it as it
    /// was. Nil when it's gone or already back.
    func resumeAtReturnWeights(_ routineId: UUID) throws -> (name: String, lowered: Int)? {
        guard let routine = try routines.routine(routineId), routine.paused else { return nil }
        let result = ReturnWeights.resume(routine, now: now()) { returnWeight(for: $0, in: routine) }
        try routines.upsert(result.routine)
        planChanged()
        return (routine.name, result.lowered)
    }

    /// 60% of what Today would suggest for `item` now, from this person's history, with no gym fitting.
    private func returnWeight(for item: RoutineExercise, in routine: Routine) -> Double? {
        let exercise = library.exercise(item.exerciseId)
        let history = (try? workouts.history(exerciseId: item.exerciseId, limit: 5)) ?? []
        let suggested = SessionPlanner.suggestion(for: item, policy: item.policy ?? routine.policy, profile: profile,
                                                  exercise: exercise, history: history).weightKg
        let rounder = LoadRounding.rounder(for: exercise, profile: profile)
        let smallest = (exercise?.isBarbellLoaded ?? false)
            ? profile.barKg : UnitConverter.toKg(rounder.step, from: rounder.unit)
        return ReturnWeights.weight(from: suggested, rounder: rounder, minimumKg: smallest)
    }
}
```

- [x] **Step 4: Run them and see them pass**

Run: the app's `GymRollinsTests/LimitsEnvironmentTests`, then `GymRollinsTests` as a whole.
Expected: 10 new tests pass and nothing else breaks. If one weight differs, check the exercise's rounder before changing an
expected number, and report it.

- [x] **Step 5: Commit**

```bash
git add ios/GymRollins ios/GymRollinsTests ios/Packages/GymData
git commit -m "feat(limits): save, postpone and clear the note, and resume a routine at 60%"
```

---

### Task 5: The editor in Settings and first-time setup

**Files:**
- Create: `ios/GymRollins/Features/Limits/LimitsEditor.swift`
- Create: `ios/GymRollins/Features/Limits/LimitsSettingsView.swift`
- Create: `ios/GymRollins/Features/Limits/LimitsSettingsRow.swift`
- Modify: `ios/GymRollins/Features/Settings/SettingsView.swift:116-117` (after Weekly targets)
- Modify: `ios/GymRollins/Features/Onboarding/ProfileSetupView.swift:23,97-104,121-135,157-165`
- Test: `ios/GymRollinsUITests/LimitsCheckInUITests.swift` (create)

- [x] **Step 1: Write the failing UI tests**

```swift
import XCTest

/// The injury note's end date: editing it in Settings, and the check-in card on Today.
@MainActor
final class LimitsCheckInUITests: XCTestCase {
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

    private func openLimitsSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        scrollAndTap(app, app.buttons["settings.limits"])
        XCTAssertTrue(element(app, "limits.edit.note").waitForExistence(timeout: 5))
    }

    private func replaceNote(_ app: XCUIApplication, with text: String) {
        let field = element(app, "limits.edit.note")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80) + text)
    }

    func testANoteWithNoDateShowsAsBefore() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        XCTAssertEqual(element(app, "today.limits").label, "Knee: no leg loading until ~26 Oct 2026")
        XCTAssertFalse(element(app, "limits.card").exists)
    }

    func testEditAndClearInSettings() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        openLimitsSettings(app)
        replaceNote(app, with: "Shoulder: no overhead pressing")
        app.switches["limits.edit.note.hasDate"].tap()
        XCTAssertTrue(element(app, "limits.edit.note.until").waitForExistence(timeout: 5))
        scrollAndTap(app, app.buttons["limits.edit.save"])
        XCTAssertTrue(app.buttons["settings.limits"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Today"].tap()
        let chip = element(app, "today.limits")
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(chip.label.hasPrefix("Shoulder: no overhead pressing"), chip.label)

        app.tabBars.buttons["Log"].tap()
        scrollAndTap(app, app.buttons["settings.limits"])
        scrollAndTap(app, app.buttons["limits.edit.clear"])
        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "today.limits").exists)
    }
}
```

Task 6 adds the card tests to this file.

- [x] **Step 2: Run them and see them fail**

Run: `GymRollinsUITests/LimitsCheckInUITests` (regenerate the project first).
Expected: `testANoteWithNoDateShowsAsBefore` fails because `today.limits` is missing (the chip has no identifier yet), and
`testEditAndClearInSettings` fails because `settings.limits` is missing.

- [x] **Step 3: Write the code**

`LimitsEditor.swift`:

```swift
import SwiftUI

/// The injury note and its optional end date, in first-time setup and Settings.
struct LimitsEditor: View {
    @Binding var note: String
    @Binding var hasDate: Bool
    @Binding var until: Date
    let dates: ClosedRange<Date>
    /// The note field's identifier; the toggle and the picker add `.hasDate` and `.until`.
    let identifier: String

    private var noteIsEmpty: Bool { note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldLabel(text: "Injuries / limits")
            TextField("e.g. knee \u{2014} no leg loading", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .padding(10)
                .background(Theme.card, in: .rect(cornerRadius: 12))
                .accessibilityIdentifier(identifier)
            Toggle("Until", isOn: $hasDate)
                .disabled(noteIsEmpty)
                .tint(Theme.accent)
                .frame(minHeight: Theme.minTapSize)
                .accessibilityIdentifier("\(identifier).hasDate")
            if hasDate && !noteIsEmpty {
                DatePicker("End date", selection: $until, in: dates, displayedComponents: .date)
                    .tint(Theme.accent)
                    .frame(minHeight: Theme.minTapSize)
                    .accessibilityIdentifier("\(identifier).until")
            }
        }
        .onChange(of: noteIsEmpty) { _, empty in if empty { hasDate = false } }
    }
}
```

`LimitsSettingsView.swift`:

```swift
import GymCore
import GymData
import SwiftUI

/// Settings > Injuries / limits: change the note, set or clear its end date, or clear the note.
struct LimitsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var hasDate = false
    @State private var until = Date()
    @State private var savedUntil: Date?
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LimitsEditor(note: $note, hasDate: $hasDate, until: $until, dates: dates, identifier: "limits.edit.note")
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.destructive)
                        .accessibilityIdentifier("limits.edit.error")
                }
                PrimaryGlassButton(title: "Save", identifier: "limits.edit.save") {
                    persist(note: note, until: hasDate ? until : nil)
                }
                if !env.profile.limits.isEmpty {
                    SecondaryGlassButton(title: "Clear note", identifier: "limits.edit.clear") {
                        persist(note: "", until: nil)
                    }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 16)
        }
        .background(Theme.background)
        .navigationTitle("Injuries / Limits")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    /// Tomorrow to a year ahead, reaching back to a saved date that has passed, so the picker can still show it.
    private var dates: ClosedRange<Date> {
        let allowed = LimitsCheckIn.allowedDates(now: env.now(), calendar: .current)
        return min(savedUntil ?? allowed.lowerBound, allowed.lowerBound)...allowed.upperBound
    }

    private func load() {
        guard !loaded else { return }
        note = env.profile.limits
        savedUntil = env.profile.limitsUntil
        hasDate = savedUntil != nil
        until = savedUntil ?? LimitsCheckIn.laterDate(now: env.now(), calendar: .current)
        loaded = true
    }

    private func persist(note: String, until: Date?) {
        do {
            try env.saveLimits(note, until: until.map { GoalDate.normalized($0) })
            error = nil
            dismiss()
        } catch GymDataError.invalidInput(let message) {
            error = message
        } catch {
            AppEnvironment.log.error("Save limits failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save. Try again."
        }
    }
}
```

`LimitsSettingsRow.swift`:

```swift
import SwiftUI

/// Settings' "Injuries / limits" row: the note, or None.
struct LimitsSettingsRow: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationLink { LimitsSettingsView() } label: {
            HStack {
                Text("Injuries / limits")
                Spacer()
                Text(env.profile.limits.isEmpty ? "None" : env.profile.limits)
                    .lineLimit(1)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityIdentifier("settings.limits")
    }
}
```

`SettingsView.swift`, in `trainingSection` after the Weekly targets link: `LimitsSettingsRow()`.

`ProfileSetupView.swift`:
- After `@State private var limits = ""`, add `@State private var hasLimitsDate = false` and
  `@State private var limitsUntil = Date()`.
- Replace the "Injuries / limits" `VStack` (lines 97-104) with
  ```swift
              LimitsEditor(note: $limits, hasDate: $hasLimitsDate, until: $limitsUntil,
                           dates: LimitsCheckIn.allowedDates(now: env.now(), calendar: .current), identifier: "setup.limits")
  ```
- In `load()`, after `limits = p.limits`:
  ```swift
          hasLimitsDate = p.limitsUntil != nil
          limitsUntil = p.limitsUntil ?? LimitsCheckIn.laterDate(now: env.now(), calendar: .current)
  ```
- In `save()`, change `limits: limits, limitsUntil: env.profile.limitsUntil,` back to `limits: limits,`, and end the
  `Profile(...)` expression with
  `.withLimits(limits, until: hasLimitsDate ? GoalDate.normalized(limitsUntil) : nil)`.

`TodayView.swift`: give the existing chip `Text` an `.accessibilityIdentifier("today.limits")`. Task 6 replaces the chip.

- [x] **Step 4: Run them and see them pass**

Run: `GymRollinsUITests/LimitsCheckInUITests`, then `GymRollinsUITests/SettingsUITests` and the onboarding UI tests
(`grep -l "setup\." ios/GymRollinsUITests/*.swift`).
Expected: all pass. If the toggle's tap lands on its label and doesn't switch it, tap the switch's right edge with
`coordinate(withNormalizedOffset:)`, as other Settings UI tests do, and say so.

- [x] **Step 5: Commit**

```bash
git add ios/GymRollins ios/GymRollinsUITests
git commit -m "feat(limits): edit the injury note and its end date in Settings and setup"
```

---

### Task 6: The check-in card on Today

**Files:**
- Create: `ios/GymRollins/Features/Limits/LimitsCheckInModel.swift`
- Create: `ios/GymRollins/Features/Limits/LimitsCheckInCard.swift`
- Create: `ios/GymRollins/Features/Limits/LimitsReminder.swift`
- Modify: `ios/GymRollins/Features/Today/TodayView.swift:64-69`
- Test: `ios/GymRollinsTests/LimitsCheckInModelTests.swift` (create)
- Test: `ios/GymRollinsUITests/LimitsCheckInUITests.swift`

- [x] **Step 1: Write the failing tests**

`LimitsCheckInModelTests.swift`:

```swift
import Foundation
import Testing
@testable import GymRollins

private func instant(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

@Suite struct LimitsCheckInModelTests {
    let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    let until = instant("2026-10-26T00:00:00Z")
    let legs = LimitsCheckInModel.PausedRoutine(id: UUID(), name: "Legs")
    let core = LimitsCheckInModel.PausedRoutine(id: UUID(), name: "Core")

    @Test func theReminderAddsTheDateWhenThereIsOne() {
        #expect(LimitsCheckInModel.reminder(note: "Knee", until: nil, calendar: utc) == "Knee")
        #expect(LimitsCheckInModel.reminder(note: "Knee", until: until, calendar: utc)
                == "Knee \u{00B7} until \(GoalDate.dayMonth(until, calendar: utc))")
    }

    @Test func theQuestionNamesTheDate() {
        #expect(LimitsCheckInModel.question(until: until, calendar: utc)
                == "You planned this until \(GoalDate.dayMonth(until, calendar: utc)). Is it the right time to continue?")
    }

    @Test func theResumedMessageCountsWhatWasLowered() {
        #expect(LimitsCheckInModel.resumedMessage(name: "Legs", lowered: 6)
                == "Legs is back, with 6 exercises at 60%. Pick its day in My Plan.")
        #expect(LimitsCheckInModel.resumedMessage(name: "Legs", lowered: 1)
                == "Legs is back, with 1 exercise at 60%. Pick its day in My Plan.")
        #expect(LimitsCheckInModel.resumedMessage(name: "Legs", lowered: 0) == "Legs is back. Pick its day in My Plan.")
    }

    @Test func notYetOffersTwoWeeksAndCancelGoesBack() {
        var model = LimitsCheckInModel()
        model.askLater(now: instant("2026-11-01T09:00:00Z"), calendar: utc)
        #expect(model.step == .choosingDate)
        #expect(model.nextDate == instant("2026-11-15T00:00:00Z"))
        model.cancelLater()
        #expect(model.step == .asking)
    }

    @Test func yesWithNoPausedRoutineCloses() {
        var model = LimitsCheckInModel()
        model.cleared(paused: [])
        #expect(model.step == .done)
    }

    @Test func yesListsThePausedRoutinesAndResumingOneSaysSo() {
        var model = LimitsCheckInModel()
        model.cleared(paused: [legs, core])
        #expect(model.step == .resuming)
        #expect(model.paused == [legs, core])
        model.resumed(legs.id, name: "Legs", lowered: 6)
        #expect(model.step == .resumed("Legs is back, with 6 exercises at 60%. Pick its day in My Plan."))
        #expect(model.paused == [core])
    }

    @Test func aRoutineThatsGoneLeavesTheList() {
        var model = LimitsCheckInModel()
        model.cleared(paused: [legs])
        model.dropped(legs.id)
        #expect(model.paused.isEmpty)
        #expect(model.step == .done)
    }

    @Test func aFailureKeepsTheStepAndShowsTheMessage() {
        var model = LimitsCheckInModel()
        model.cleared(paused: [legs])
        model.failed(LimitsCheckInModel.resumeFailed("Legs"))
        #expect(model.step == .resuming)
        #expect(model.error == "Couldn't bring Legs back. Try again.")
        model.resumed(legs.id, name: "Legs", lowered: 6)
        #expect(model.error == nil)
    }

    @Test func theCardShowsWhenDueWithNoWorkoutAndStaysAfterYes() {
        var model = LimitsCheckInModel()
        #expect(model.showsCard(due: true, workoutRunning: false))
        #expect(!model.showsCard(due: true, workoutRunning: true))
        #expect(!model.showsCard(due: false, workoutRunning: false))
        model.cleared(paused: [legs])
        #expect(model.showsCard(due: false, workoutRunning: false))
        model.close()
        #expect(!model.showsCard(due: true, workoutRunning: false))
    }
}
```

In `LimitsCheckInUITests.testEditAndClearInSettings`, tighten the chip check to
`chip.label.hasPrefix("Shoulder: no overhead pressing \u{00B7} until ")`: the reminder now carries the date. Then add:

```swift
    func testNotYetMovesTheDate() {
        let app = XCUIApplication.launchReady(["-seedLimitsDue"]) { $0.buttons["today.start"] }
        let question = element(app, "limits.question")
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        XCTAssertTrue(question.label.hasPrefix("You planned this until "), question.label)
        XCTAssertFalse(element(app, "today.limits").exists)
        scrollAndTap(app, app.buttons["limits.notYet"])
        XCTAssertTrue(element(app, "limits.nextDate").waitForExistence(timeout: 5))
        scrollAndTap(app, app.buttons["limits.saveDate"])
        let chip = element(app, "today.limits")
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(chip.label.hasPrefix("Knee: no leg loading \u{00B7} until "), chip.label)
        XCTAssertFalse(element(app, "limits.card").exists)
    }

    func testYesThenResumeLegsThenOpenMyPlan() {
        let app = XCUIApplication.launchReady(["-seedLimitsDue"]) { $0.buttons["today.start"] }
        scrollAndTap(app, app.buttons["limits.yes"])
        let resume = app.buttons["limits.resume.0"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertEqual(resume.label, "Resume Legs at 60%")
        XCTAssertFalse(element(app, "today.limits").exists)
        scrollAndTap(app, resume)
        let message = element(app, "limits.resumed")
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(message.label, "Legs is back, with 6 exercises at 60%. Pick its day in My Plan.")
        scrollAndTap(app, app.buttons["limits.openPlan"])
        XCTAssertTrue(element(app, "plan.routine.Legs").waitForExistence(timeout: 5))
    }

    func testNotNowClosesTheCardAndLeavesTheNoteCleared() {
        let app = XCUIApplication.launchReady(["-seedLimitsDue"]) { $0.buttons["today.start"] }
        scrollAndTap(app, app.buttons["limits.yes"])
        scrollAndTap(app, app.buttons["limits.notNow"])
        XCTAssertFalse(element(app, "limits.card").waitForExistence(timeout: 2))
        XCTAssertFalse(element(app, "today.limits").exists)
    }

    func testNoCardDuringAWorkout() {
        let app = XCUIApplication.launchReady(["-seedLimitsDue"]) { $0.buttons["today.start"] }
        app.startWorkout()
        XCTAssertTrue(app.buttons["workout.close"].waitForExistence(timeout: 5))
        app.buttons["workout.close"].tap()
        XCTAssertTrue(element(app, "today.resumeBanner").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "limits.card").exists)
        XCTAssertTrue(element(app, "today.limits").exists)
    }
```

- [x] **Step 2: Run them and see them fail**

Run: `GymRollinsTests/LimitsCheckInModelTests` and `GymRollinsUITests/LimitsCheckInUITests`.
Expected: the unit tests don't build ("cannot find 'LimitsCheckInModel' in scope"). Once they build, the four new UI tests
fail on `limits.question`, `limits.yes` and `limits.card`, because Today only shows the chip.

- [x] **Step 3: Write the code**

`LimitsCheckInModel.swift`:

```swift
import Foundation
import GymCore

/// The check-in card's steps and copy. A value: `LimitsReminder` runs the actions and reports what happened.
struct LimitsCheckInModel: Equatable {
    struct PausedRoutine: Equatable, Identifiable {
        let id: UUID
        let name: String
    }

    enum Step: Equatable {
        /// "Is it the right time to continue?"
        case asking
        /// Not yet: a new date to ask again on.
        case choosingDate
        /// Yes was saved: the paused routines that can come back.
        case resuming
        /// A routine came back; the text says how many exercises were lowered.
        case resumed(String)
        /// Answered and closed.
        case done
    }

    private(set) var step: Step = .asking
    /// The Not yet picker's date.
    var nextDate = Date.distantPast
    private(set) var paused: [PausedRoutine] = []
    private(set) var error: String?

    static let saveFailed = "Couldn't save. Try again."

    static func resumeFailed(_ name: String) -> String { "Couldn't bring \(name) back. Try again." }

    /// Today's reminder: the note, and its end date when it has one.
    static func reminder(note: String, until: Date?, calendar: Calendar = .current) -> String {
        guard let until else { return note }
        return "\(note) \u{00B7} until \(GoalDate.dayMonth(until, calendar: calendar))"
    }

    static func question(until: Date, calendar: Calendar = .current) -> String {
        "You planned this until \(GoalDate.dayMonth(until, calendar: calendar)). Is it the right time to continue?"
    }

    static func resumedMessage(name: String, lowered: Int) -> String {
        switch lowered {
        case 0: "\(name) is back. Pick its day in My Plan."
        case 1: "\(name) is back, with 1 exercise at 60%. Pick its day in My Plan."
        default: "\(name) is back, with \(lowered) exercises at 60%. Pick its day in My Plan."
        }
    }

    /// Whether the card shows. After Yes it stays until it's closed, though nothing is due any more.
    func showsCard(due: Bool, workoutRunning: Bool) -> Bool {
        switch step {
        case .resuming, .resumed: true
        case .asking, .choosingDate: due && !workoutRunning
        case .done: false
        }
    }

    mutating func askLater(now: Date, calendar: Calendar = .current) {
        nextDate = LimitsCheckIn.laterDate(now: now, calendar: calendar)
        step = .choosingDate
        error = nil
    }

    mutating func cancelLater() {
        step = .asking
        error = nil
    }

    /// Yes was saved: offer the paused routines, or close when there are none.
    mutating func cleared(paused routines: [PausedRoutine]) {
        paused = routines
        step = routines.isEmpty ? .done : .resuming
        error = nil
    }

    mutating func resumed(_ id: UUID, name: String, lowered: Int) {
        paused.removeAll { $0.id == id }
        step = .resumed(Self.resumedMessage(name: name, lowered: lowered))
        error = nil
    }

    /// A routine that was deleted or resumed elsewhere leaves the list.
    mutating func dropped(_ id: UUID) {
        paused.removeAll { $0.id == id }
        if paused.isEmpty, step == .resuming { step = .done }
    }

    mutating func close() {
        step = .done
        error = nil
    }

    mutating func failed(_ message: String) { error = message }
}
```

`LimitsCheckInCard.swift`:

```swift
import SwiftUI

/// The check-in card on Today. `LimitsReminder` owns the model and runs the actions.
struct LimitsCheckInCard: View {
    @Binding var model: LimitsCheckInModel
    let note: String
    let until: Date?
    let dates: ClosedRange<Date>
    let yes: () -> Void
    let notYet: () -> Void
    let saveDate: () -> Void
    let resume: (LimitsCheckInModel.PausedRoutine) -> Void
    let openPlan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
            if let error = model.error {
                Text(error).font(.footnote).foregroundStyle(Theme.destructive)
                    .accessibilityIdentifier("limits.error")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("limits.card")
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .asking: asking
        case .choosingDate: choosingDate
        case .resuming: resuming(message: nil)
        case .resumed(let message): resuming(message: message)
        case .done: EmptyView()
        }
    }

    private var asking: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note).font(.headline).foregroundStyle(Theme.textPrimary)
                .accessibilityIdentifier("limits.card.note")
            if let until {
                Text(LimitsCheckInModel.question(until: until)).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("limits.question")
            }
            PrimaryGlassButton(title: "Yes, continue", identifier: "limits.yes", action: yes)
            SecondaryGlassButton(title: "Not yet", identifier: "limits.notYet", action: notYet)
        }
    }

    private var choosingDate: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask me again on").font(.headline).foregroundStyle(Theme.textPrimary)
            DatePicker("Ask me again on", selection: $model.nextDate, in: dates, displayedComponents: .date)
                .labelsHidden()
                .tint(Theme.accent)
                .frame(minHeight: Theme.minTapSize)
                .accessibilityIdentifier("limits.nextDate")
            PrimaryGlassButton(title: "Save", identifier: "limits.saveDate", action: saveDate)
            SecondaryGlassButton(title: "Cancel", identifier: "limits.cancelDate") { model.cancelLater() }
        }
    }

    private func resuming(message: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message {
                Text(message).font(.subheadline).foregroundStyle(Theme.textPrimary)
                    .accessibilityIdentifier("limits.resumed")
                PrimaryGlassButton(title: "Open My Plan", identifier: "limits.openPlan", action: openPlan)
            } else {
                Text("Start light: bring a paused routine back at 60% of its weights.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("limits.resumeIntro")
            }
            ForEach(Array(model.paused.enumerated()), id: \.element.id) { index, routine in
                SecondaryGlassButton(title: "Resume \(routine.name) at 60%", identifier: "limits.resume.\(index)") {
                    resume(routine)
                }
            }
            SecondaryGlassButton(title: message == nil ? "Not now" : "Done",
                                 identifier: message == nil ? "limits.notNow" : "limits.done") { model.close() }
        }
    }
}
```

`LimitsReminder.swift`:

```swift
import GymCore
import GymData
import SwiftUI

/// Today's injury note: the reminder before its end date, and the check-in card on or after it.
struct LimitsReminder: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    let openPlan: () -> Void
    @State private var model = LimitsCheckInModel()
    /// When the date was last checked: refreshed at midnight and when the app comes back, so the card appears on its
    /// day without a reload.
    @State private var checkedAt: Date?

    private var due: Bool {
        LimitsCheckIn.isDue(note: env.profile.limits, until: env.profile.limitsUntil, now: checkedAt ?? env.now(),
                            calendar: .current)
    }

    var body: some View {
        Group {
            if model.showsCard(due: due, workoutRunning: env.session != nil) {
                LimitsCheckInCard(model: $model, note: env.profile.limits, until: env.profile.limitsUntil,
                                  dates: LimitsCheckIn.allowedDates(now: env.now(), calendar: .current),
                                  yes: yes, notYet: { model.askLater(now: env.now()) }, saveDate: saveDate,
                                  resume: resume, openPlan: { model.close(); openPlan() })
            } else if !env.profile.limits.isEmpty {
                Text(LimitsCheckInModel.reminder(note: env.profile.limits, until: env.profile.limitsUntil))
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .foregroundStyle(Theme.record)
                    .glassCapsule(tint: Theme.record.opacity(0.25), interactive: false)
                    .accessibilityIdentifier("today.limits")
            }
        }
        // A new date that's already due (set elsewhere, or synced in) asks again from the start.
        .onChange(of: due) { _, isDue in if isDue { model = LimitsCheckInModel() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in checkedAt = env.now() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { checkedAt = env.now() } }
    }

    private func yes() {
        do {
            let paused = try env.pausedRoutines().map { LimitsCheckInModel.PausedRoutine(id: $0.id, name: $0.name) }
            try env.clearLimits()
            model.cleared(paused: paused)
        } catch {
            AppEnvironment.log.error("Clear limits failed: \(error.localizedDescription, privacy: .public)")
            model.failed(LimitsCheckInModel.saveFailed)
        }
    }

    private func saveDate() {
        do {
            try env.postponeLimits(to: GoalDate.normalized(model.nextDate))
            model = LimitsCheckInModel()
        } catch {
            AppEnvironment.log.error("Postpone limits failed: \(error.localizedDescription, privacy: .public)")
            model.failed(LimitsCheckInModel.saveFailed)
        }
    }

    private func resume(_ routine: LimitsCheckInModel.PausedRoutine) {
        do {
            if let result = try env.resumeAtReturnWeights(routine.id) {
                model.resumed(routine.id, name: result.name, lowered: result.lowered)
            } else {
                model.dropped(routine.id)
            }
        } catch {
            AppEnvironment.log.error("Resume routine failed: \(error.localizedDescription, privacy: .public)")
            model.failed(LimitsCheckInModel.resumeFailed(routine.name))
        }
    }
}
```

Match `TodayView`'s own `.NSCalendarDayChanged` handler (it's in the block at lines 131-156): if it adds
`.receive(on: RunLoop.main)` or similar, do the same here.

`TodayView.swift`: replace the chip (lines 64-69, the `if !env.profile.limits.isEmpty { ... }` block, including the
identifier Task 5 added) with

```swift
                    LimitsReminder(openPlan: { showPlan = true })
```

- [x] **Step 4: Run them and see them pass**

Run: `GymRollinsTests/LimitsCheckInModelTests`, `GymRollinsUITests/LimitsCheckInUITests`, then `GymRollinsUITests/TodayUITests`,
`GymRollinsUITests/InsightsUITests` and `GymRollinsUITests/SharedWorkoutUITests` (they read Today).
Expected: 9 unit tests and 6 UI tests pass, and the other suites still pass.

- [x] **Step 5: Commit**

```bash
git add ios/GymRollins ios/GymRollinsTests ios/GymRollinsUITests
git commit -m "feat(limits): Today asks on the note's end date, and Yes offers paused routines at 60%"
```

---

### Task 7: Accessibility

**Files:**
- Modify: `ios/GymRollinsUITests/AccessibilityAuditUITests.swift`
- Modify: `ios/GymRollinsUITests/DynamicTypeUITests.swift`

- [x] **Step 1: Write the tests**

`AccessibilityAuditUITests.swift`, next to `testTodayAudit`:

```swift
    func testLimitsCheckInAudit() {
        let app = launch(["-seedHistory", "-seedLimitsDue"])
        XCTAssertTrue(app.buttons["limits.yes"].waitForExistence(timeout: 5))
        audit(app, "Limits check-in")
        app.buttons["limits.yes"].tap()
        XCTAssertTrue(app.buttons["limits.resume.0"].waitForExistence(timeout: 5))
        audit(app, "Limits resume")
    }

    func testLimitsSettingsAudit() {
        let app = launch()
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.limits"]
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.buttons["limits.edit.save"].waitForExistence(timeout: 5))
        audit(app, "Limits settings")
    }
```

`DynamicTypeUITests.swift`, next to `testClaudeGymsToggleAtAccessibilityXL`:

```swift
    func testLimitsCheckInAtAccessibilityXL() {
        let app = launch(extra: ["-seedHistory", "-seedLimitsDue"])
        for id in ["limits.yes", "limits.notYet"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            for _ in 0..<6 where !button.isHittable { app.swipeUp() }
            XCTAssertTrue(button.isHittable, id)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, id)
        }
        screenshot("limits-check-in-ax-xl")
    }

    func testLimitsSettingsAtAccessibilityXL() {
        let app = launch()
        app.tabBars.buttons["Log"].tap()
        app.buttons["log.settings"].tap()
        let row = app.buttons["settings.limits"]
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        row.tapCenter()
        let save = app.buttons["limits.edit.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        for _ in 0..<6 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable)
        XCTAssertGreaterThanOrEqual(save.frame.height, 44)
        screenshot("limits-settings-ax-xl")
    }
```

- [x] **Step 2: Run them**

Run: `GymRollinsUITests/AccessibilityAuditUITests` with `-only-testing` on the two new tests, then the two new
`DynamicTypeUITests`.
Expected: they pass. If an audit fails, read its screenshot first and fix the screen, not the audit: don't add an
exclusion. Report what you found either way.

- [x] **Step 3: Commit**

```bash
git add ios/GymRollinsUITests ios/GymRollins
git commit -m "test(limits): accessibility audits and large text for the check-in and Settings"
```

---

### Task 8: Finish

- [x] **Step 1: Run every suite**

The app suite takes about an hour. Run one `xcodebuild` at a time.

```bash
scripts/coverage-gymcore.sh
(cd ios/Packages/GymData && swift test)
(cd ios/Packages/GymSync && swift test --filter GymSyncTests)
scripts/test-db.sh
scripts/test-sync-integration.sh
scripts/test-mcp.sh
scripts/test-gym-e2e.sh
node --test scripts/*.test.mjs
scripts/watch-build.sh
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' scripts/ios-test.sh
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' scripts/ios-test-sync.sh
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' scripts/test-photo-hosting.sh
```

Read each app bundle with `xcrun xcresulttool get test-results summary --path <bundle>`. Expected: coverage at least 90%,
every suite passing, and no app failures. If an audit fails, read its screenshot first. Report every failure with what you
found.

- [x] **Step 2: Walk it on the simulator**

On `iPhone 17 Pro Max`, iOS 26.2. Leave the iPhone 16 Pro on iOS 18.2 alone. Install the new build, then:

1. **An old store opens.** Launch with `-diskStore -seedOwner -skipOnboarding` and no `-resetStore`, on the store the
   plan 23 build left. The app opens, the data is there, and the note reads as before with no date.
2. **The card.** Relaunch with `-seedLimitsDue` added. Screenshot the card. Tap Not yet, screenshot the picker, Save, and
   screenshot the reminder with its date.
3. **Yes and Resume.** Relaunch with `-resetStore -seedOwner -seedLimitsDue -skipOnboarding`. Tap Yes, screenshot the list,
   tap Resume Legs at 60%, screenshot the message, and Open My Plan. Open Legs and read the weights: RDL and squat 80 lb,
   leg press 100 lb, leg curl 60 lb, leg extension 65 lb, calf raise 115 lb. The note is gone from Today and Settings, and
   Strength no longer shows squat and deadlift as paused.
4. **Settings.** Set a note with a date, Save, and check Today. Clear it, and check Today.
5. **The server.** Sign in from Settings as a fresh `ui-walk-limits@test.local` account on the local stack. Set a note with
   a date in Settings and wait for sync. SQL: `select limits, limits_until from public.profiles` for that user shows the
   note and the day. Clear it, sync, and the row shows `''` and null. Delete the account afterwards.

Save the screenshots to the scratchpad, not the repo. List anything that looks wrong, including unclear copy and layout
problems.

- [x] **Step 3: Docs and finish**

Add one bullet to `README.md`'s feature list, after "Train with a partner":
"**Injury notes with an end date.** On the date, Today asks if it's time to continue, and brings a paused routine back at
60% of its weights."

Tick the boxes here and add `## Outcome` with the real numbers and the walk's results, in the form plan 23's uses. Update
the spec if anything changed.

```bash
git add README.md docs/plans/2026-11-03-plan-24-limits-check-in.md docs/specs/2026-11-03-limits-check-in-design.md
git commit -m "docs: plan 24 outcome"
```

## Outcome

Done on 2026-11-03, branch `feat-limits-checkin`, stacked on `feat-shared-workout`, not pushed. Supabase stays local. Final run at `31cf53d`:

| Suite | Result |
|---|---|
| App, unit and UI, iPhone 17 Pro Max, iOS 26.2, `PerformanceUITests` excluded | 1119 tests: 1102 passed, 2 failed, 15 skipped. The failures are below |
| `scripts/ios-test-sync.sh`, the app against the real local stack | 5 tests, all passed (5 of the 15 skips above) |
| `scripts/test-photo-hosting.sh` | 1 test, passed (1 of the 15 skips above) |
| GymCore (`scripts/coverage-gymcore.sh`) | 96.35% line coverage, threshold 90% |
| GymData | 355 tests in 48 suites |
| GymHealth | 85 tests in 17 suites |
| GymWatchLink | 63 tests in 8 suites |
| GymSync, `--filter GymSyncTests` | 143 tests in 20 suites |
| `scripts/test-db.sh` | 574 pgTAP tests in 18 files |
| `scripts/test-sync-integration.sh` | 39 tests in 11 suites |
| `scripts/test-mcp.sh` | 156 Deno tests, and 18 consent tests (`server.test.mjs`'s 17 plus the one in `e2e.test.mjs`) |
| `scripts/test-gym-e2e.sh` | 5 tests |
| `web/share/share.test.mjs` | 17 tests |
| `web/consent/server.test.mjs` | 17 tests |
| `node --test scripts/*.test.mjs` | 148 tests |
| `scripts/watch-build.sh` | watchOS build OK |

**The two app failures.** Neither test, nor the screen it covers, changed in this plan, and both passed in plan 23's run.
- `AccessibilityAuditUITests/testReportSheetAndBlockCardAudit` (plan 22) flagged contrast on Send report. Run alone it failed 3 times in 9. Its screenshot measures 7.14:1, white on #A72431: the same button as the add flow's Save, already listed for the same false reading. Waiting for the sheet to settle didn't help (it failed 1 run of 5). `ed9ee4d` lists `report.send` beside `addEquipment.save`, and the test then passed 5 runs of 5. The full app suite wasn't run again after it.
- `IdleFinishUITests/testFinishLongAfterTheLastSetEndsAtTheLastSet`: the idle message didn't appear within 5 s of tapping Finish. It passed the 3 times it ran alone, and it hasn't changed since the first release. Left as flaky.

**Skips left:** `ReadmeScreenshotsUITests` (8) only runs when regenerating the README's screenshots. `RealExportImportTests` (1) needs the owner's export file.

**The walk.** The real app on the iPhone 17 Pro Max simulator, without `-uiTesting`, at `31cf53d`.
1. **An old store opens**, on real data in place of a plan 23 store. The owner's phone store, last written by a September build from before plan 19, opened with this branch on the simulator, then on the phone itself (iPhone 14 Pro Max, iOS 26.5), installed over the old app. Every workout, set, routine and weigh-in and the profile were counted in the store before and after, and none was lost. `ZLIMITSUNTIL` was added. On the phone, Apple Health then added the weigh-ins logged since.
2. **The card** read "Knee: no leg loading" and "You planned this until 2 Nov. Is it the right time to continue?", with Yes, continue and Not yet. Not yet showed "Ask me again on" with Save and Cancel. After Save, Today read "Knee: no leg loading · until 17 Nov", two weeks from 3 Nov.
3. **Yes and Resume.** Yes showed "Start light: bring a paused routine back at 60% of its weights.", Resume Legs at 60% and Not now. Resume said "Legs is back, with 6 exercises at 60%. Pick its day in My Plan." Open My Plan › Legs read RDL 80 lb, squat 80 lb, leg press 100 lb, leg curl 60 lb, leg extension 65 lb and calf raise 115 lb, with Paused off. Today had no reminder or card, Settings read None, and Strength showed no Paused on squat or deadlift.
4. **Settings.** A note with Until on saved, and Today showed it with "· until 17 Nov". Clear note removed it from Today.
5. **The server.** Signed in from Settings as a fresh `ui-walk-limits@test.local`, set a note with a date and pulled to sync: `Shoulder: no overhead pressing|2026-11-17`. Cleared and synced: `limits` was `''` and `limits_until` null. The account and its rows were deleted afterwards.

**Changed from the plan**
- Task 5's Settings row is a `VStack`, the title above the note, in place of the plan's `HStack`.
- The UI tests' `replaceNote` taps the field's right edge first. A plain tap put the caret at the start, so the old text stayed.
- The audits: `waitUntilSettled` replaced Task 5's exclusions of two Settings headers, which were sampled mid-scroll at a different place on every run. The bottom band went from 150 to 165 pt to cover the whole Start Workout bar, and a 120 pt top band covers rows under the navigation bar.
- The review fixes were written before their tests. Each test was seen failing by turning its fix off, not first.
- Walk step 1 used the owner's real store, as above.

**Added after this plan's review.** The code review's one high, five mediums and one low are fixed (`fe9746a`, `31cf53d`).
- Resume at 60% leaves alone an exercise with a fixed weight, and one where 60% isn't below the suggestion or lands on the last logged weight after the floor. The card counts only weights that take effect. The spec says so now.
- Today's reminder and card use one due check at one time, so they can't disagree around midnight.
- Turning Until back on after its date has passed starts two weeks ahead.
- `get_profile` returns no date when the note is empty.

**Not tested**
- A lift going from Paused to levelled in Strength on screen. `-seedOwner` has no squat or deadlift sets, so the walk only saw Paused gone.
- Criterion 7 on two devices: answering on one phone and the card leaving the other. The sync integration suite writes and reads the column.
- The date picked in first-time setup has no UI test.

**Known and left**
- The Settings row shows the note without its date, while Today shows "· until 17 Nov".
- First-time setup reopened on a passed date keeps it.
- The resume offer is lost if Today is rebuilt after Yes. Paused routines can still be resumed in My Plan.
- At a gym with coarse steps, Today may round the 60% weight up.
- Time zones follow the `goalDate` convention: the date is a day, not an instant.
- An old build that leaves out `limits_until` could bring back a stale date. No build has been released.
- The migration must deploy before the app and Claude's server, which both name the column.
- The `IdleFinishUITests` flake above.
- "Add Exercise" at the bottom of Today has marginal contrast, as before this plan.
- The audits' edge bands apply to every screen.
