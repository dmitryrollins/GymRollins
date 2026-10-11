import Foundation
import Testing
@testable import GymCore

/// The `today` change: a one-off routine for one date (validator window, paused routines, applier output).
@Suite struct PlanChangeTodayTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let pushId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let legsId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static var push: String { pushId.uuidString.lowercased() }
    static var legs: String { legsId.uuidString.lowercased() }

    static let plan = PlanState(routines: [
        Routine(id: pushId, name: "Push + Arms", exercises: [RoutineExercise(exerciseId: "bench", sets: 3, reps: 10)]),
        Routine(id: legsId, name: "Legs", paused: true,
                exercises: [RoutineExercise(exerciseId: "leg-extension", sets: 3, reps: 12)]),
    ], schedule: [6: pushId])

    private func violations(_ date: String?, routine: String = PlanChangeTodayTests.push, today: String? = "2026-10-03",
                            slack: Int = 0, before: [PlanChange] = []) -> [String] {
        let validator = PlanChangeValidator(plan: Self.plan.snapshot, exerciseExists: { _ in true }, today: today,
                                            daySlack: slack)
        let change = PlanChange(id: "t1", type: .today, routineId: routine, date: date)
        return validator.validate(PlanProposal(summary: "Today", changes: before + [change]))
            .map { "\($0.field): \($0.message)" }
    }

    // MARK: Validator

    @Test func todayUpToSevenDaysAheadIsValid() {
        #expect(violations("2026-10-03").isEmpty)
        #expect(violations("2026-10-10").isEmpty)
        #expect(violations("2026-10-02") == ["date: Date passed"])
        #expect(violations("2026-10-11") == ["date: At most 7 days ahead"])
    }

    @Test func slackWidensTheWindowBothWays() {
        #expect(violations("2026-10-02", slack: 1).isEmpty)
        #expect(violations("2026-10-11", slack: 1).isEmpty)
        #expect(violations("2026-10-01", slack: 1) == ["date: Date passed"])
    }

    @Test func dateFormatIsCheckedWithoutAReferenceDay() {
        #expect(violations("2020-01-01", today: nil).isEmpty)
        #expect(violations("2027-02-29", today: nil) == ["date: Must be a date like 2026-10-03"])
        #expect(violations("2028-02-29", today: nil).isEmpty)
        #expect(violations("3 Oct", today: nil) == ["date: Must be a date like 2026-10-03"])
        #expect(violations(nil) == ["date: Required for today"])
        #expect(violations("2027-01-02", today: "2026-12-31").isEmpty)
    }

    @Test func pausedRoutineIsRefusedUnlessResumedEarlier() {
        #expect(violations("2026-10-03", routine: Self.legs) == ["routineId: Routine is paused"])
        let resume = PlanChange(id: "r1", type: .pauseRoutine, routineId: Self.legs, paused: false)
        #expect(violations("2026-10-03", routine: Self.legs, before: [resume]).isEmpty)
        let pause = PlanChange(id: "p1", type: .pauseRoutine, routineId: Self.push, paused: true)
        #expect(violations("2026-10-03", before: [pause]) == ["routineId: Routine is paused"])
    }

    @Test func routineAddedEarlierInTheProposalCanBePicked() {
        let add = PlanChange(id: "a1", type: .addRoutine, routineId: "home-kb", name: "Home · KB Upper")
        #expect(violations("2026-10-03", routine: "home-kb", before: [add]).isEmpty)
        #expect(violations("2026-10-03", routine: "home-kb") == ["routineId: Unknown routine 'home-kb'"])
    }

    @Test func snapshotCarriesPaused() {
        #expect(Self.plan.snapshot.routines.map(\.paused) == [false, true])
    }

    @Test func dateAndTypeRoundTripJSON() throws {
        let change = PlanChange(id: "t1", type: .today, routineId: Self.push, date: "2026-10-03")
        let json = String(decoding: try JSONEncoder().encode(change), as: UTF8.self)
        #expect(json.contains("\"type\":\"today\"") && json.contains("\"date\":\"2026-10-03\""))
        #expect(try JSONDecoder().decode(PlanChange.self, from: Data(json.utf8)) == change)
    }

    // MARK: Applier

    @Test func applyLeavesThePlanAndScheduleUntouchedAndReportsTheDay() throws {
        let change = PlanChange(id: "t1", type: .today, routineId: Self.push.uppercased(), date: "2026-10-03")
        let result = try PlanChangeApplier.applyDetailed([change], to: Self.plan, now: Self.now)
        #expect(result.plan == Self.plan)
        #expect(result.days == [PlanDayRoutine(changeId: "t1", day: "2026-10-03", routineId: Self.pushId)])
        #expect(try PlanChangeApplier.apply([change], to: Self.plan, now: Self.now) == Self.plan)
    }

    @Test func applyResolvesARoutineAddedInTheSameBatch() throws {
        let newId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let changes = [
            PlanChange(id: "a1", type: .addRoutine, routineId: "home-kb", name: "Home · KB Upper"),
            PlanChange(id: "t1", type: .today, routineId: "home-kb", date: "2026-10-03"),
        ]
        let result = try PlanChangeApplier.applyDetailed(changes, to: Self.plan, now: Self.now, newID: { _ in newId })
        #expect(result.plan.routines.last?.name == "Home · KB Upper")
        #expect(result.plan.schedule == Self.plan.schedule)
        #expect(result.days.map(\.routineId) == [newId])
    }

    @Test func applyRefusesUnknownPausedOrUndatedChanges() {
        let bad = [
            PlanChange(id: "u1", type: .today, routineId: "nope", date: "2026-10-03"),
            PlanChange(id: "p1", type: .today, routineId: Self.legs, date: "2026-10-03"),
            PlanChange(id: "d1", type: .today, routineId: Self.push),
            PlanChange(id: "d2", type: .today, routineId: Self.push, date: "2026-13-40"),
        ]
        for change in bad {
            #expect(throws: PlanApplyError.invalid(change.id)) {
                try PlanChangeApplier.applyDetailed([change], to: Self.plan, now: Self.now)
            }
        }
    }

    // MARK: PlanDay

    @Test func planDayKeysAndArithmetic() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        // 2026-10-04 03:00 UTC is still the 3rd in Los Angeles.
        #expect(PlanDay.key(Date(timeIntervalSince1970: 1_791_082_800), calendar: calendar) == "2026-10-03")
        #expect(PlanDay.number("2026-10-03").map { $0 - (PlanDay.number("2026-09-26") ?? 0) } == 7)
        #expect(PlanDay.number("2026-02-30") == nil)
        #expect(PlanDay.number("1970-01-01") == 0)
    }
}
