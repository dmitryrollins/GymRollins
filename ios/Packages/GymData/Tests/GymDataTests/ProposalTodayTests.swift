import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// The `today` change through `ProposalService`: checked against the owner's local date when applied, reported in
/// the outcome (the app shows it on Today), never touching the plan; a passed date is skipped, not fatal.
@MainActor
@Suite struct ProposalTodayTests {
    let f: ProposalFixture
    /// The owner is in Los Angeles: 2026-10-04 03:00 UTC is still Saturday 3 Oct there.
    static let la: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return calendar
    }()
    static let now = Date(timeIntervalSince1970: 1_791_082_800)

    init() throws {
        f = try ProposalFixture()
        f.clock.now = Self.now
    }

    private var service: ProposalService {
        let library = f.library
        return ProposalService(context: f.context, exerciseExists: { library.contains($0) },
                               now: { [clock = f.clock] in clock.now }, calendar: Self.la)
    }

    private func proposal(_ changes: [PlanChange]) throws -> Proposal {
        let p = Proposal(id: UUID(), createdAt: f.clock.now.addingTimeInterval(-60), summary: "One-off", changes: changes)
        try f.proposals.upsertRemote([p])
        return p
    }

    private func today(_ id: String, _ routine: String, _ date: String) -> PlanChange {
        PlanChange(id: id, type: .today, routineId: routine, date: date, reason: "Home today")
    }

    @Test func appliedTodayChangeIsReportedAndLeavesThePlanAlone() throws {
        let p = try proposal([today("c1", f.id(f.pull), "2026-10-03")])
        let before = try f.routines.planState()
        let outcome = try service.apply(p.id, changeIds: ["c1"])
        #expect(outcome.applied == ["c1"] && outcome.skipped.isEmpty)
        #expect(outcome.days == [PlanDayRoutine(changeId: "c1", day: "2026-10-03", routineId: f.pull.id)])
        #expect(try f.routines.planState() == before)
        let stored = try #require(try f.proposals.proposal(p.id))
        #expect(stored.status == .applied && stored.appliedChangeIds == ["c1"])
    }

    @Test func routineAddedInTheSameProposalResolvesToItsNewId() throws {
        let p = try proposal([
            PlanChange(id: "c1", type: .addRoutine, routineId: "home-kb", name: "Home · KB Upper"),
            PlanChange(id: "c2", type: .addExercise, routineId: "home-kb", exerciseId: "dips", sets: 3, reps: 10),
            today("c3", "home-kb", "2026-10-03"),
        ])
        let outcome = try service.apply(p.id, changeIds: ["c1", "c2", "c3"])
        let added = try #require(try f.routines.all().first { $0.name == "Home · KB Upper" })
        #expect(outcome.days.map(\.routineId) == [added.id])
        #expect(try f.routines.schedule().days == [1: f.push.id, 6: f.legs.id]) // the week is untouched
    }

    @Test func passedDateIsSkippedWhileTheRestApplies() throws {
        let p = try proposal([
            PlanChange(id: "c1", type: .weight, routineId: f.id(f.push), exerciseId: "bench", weightKg: 63.5),
            today("c2", f.id(f.pull), "2026-10-02"),
        ])
        #expect(try service.violations(for: p) == ["c2": "Date passed"])
        let outcome = try service.apply(p.id, changeIds: ["c1", "c2"])
        #expect(outcome.applied == ["c1"] && outcome.days.isEmpty)
        #expect(outcome.skipped.map(\.message) == ["Date passed"])
        #expect(try f.bench()?.weightKg == 63.5)
        #expect(try f.proposals.proposal(p.id)?.status == .partial)
    }

    @Test func onlyAPassedDateLeavesNothingToApply() throws {
        let p = try proposal([today("c1", f.id(f.pull), "2026-10-02")])
        #expect(throws: ProposalError.nothingToApply) { try service.apply(p.id, changeIds: ["c1"]) }
        #expect(try f.proposals.proposal(p.id)?.status == .pending)
    }

    /// The UTC date is already the 4th, but the owner's date (the calendar's) is the 3rd: the 3rd applies and
    /// "7 days ahead" counts from the 3rd.
    @Test func windowUsesTheOwnersLocalDate() throws {
        #expect(try service.violations(for: proposal([today("c1", f.id(f.pull), "2026-10-03")])).isEmpty)
        #expect(try service.violations(for: proposal([today("c1", f.id(f.pull), "2026-10-10")])).isEmpty)
        #expect(try service.violations(for: proposal([today("c1", f.id(f.pull), "2026-10-11")]))
            == ["c1": "At most 7 days ahead"])
    }

    @Test func pausedRoutineIsSkipped() throws {
        var legs = f.legs
        legs = Routine(id: legs.id, name: legs.name, paused: true, exercises: legs.exercises)
        try f.routines.upsert(legs)
        let p = try proposal([today("c1", f.id(f.legs), "2026-10-03")])
        #expect(try service.violations(for: p) == ["c1": "Routine is paused"])
    }

    @Test func autoApplyHandsEachOutcomeToTheCaller() throws {
        try f.profiles.save(Profile(mcpAutoApply: true))
        let p = try proposal([today("c1", f.id(f.pull), "2026-10-03")])
        var outcomes: [(UUID, ProposalApplyOutcome)] = []
        #expect(try service.autoApplyPending { outcomes.append(($0, $1)) } == 1)
        #expect(outcomes.map(\.0) == [p.id])
        #expect(outcomes.first?.1.days.map(\.routineId) == [f.pull.id])
        #expect(try f.proposals.proposal(p.id)?.status == .applied)
    }
}
