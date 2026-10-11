import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Claude's `today` change applied on the phone: Today shows the routine on that date only, exactly like Switch
/// (stored in `TodayPlanStore`, so the watch follows); the week is untouched, a live workout is never altered, a
/// passed date is skipped, and undo takes the switch back. 26 Sep 2026 is a Saturday (Push + Arms).
@MainActor
@Suite struct TodayRoutineProposalTests {
    let env: AppEnvironment
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "TodayRoutineProposalTests.\(UUID())"))
        env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow", "2026-09-26T12:00:00Z"]),
                                 defaults: defaults)
    }

    private var today: String { TodayPlan.dayKey(env.now()) }
    private func day(_ offset: Int) -> String { TodayPlan.dayKey(env.now().addingTimeInterval(Double(offset) * 86_400)) }

    private func routine(_ name: String) throws -> Routine {
        try #require(try env.routines.all().first { $0.name == name })
    }

    private func ref(_ routine: Routine) -> String { routine.id.uuidString.lowercased() }

    @discardableResult
    private func propose(_ changes: [PlanChange]) throws -> Proposal {
        let p = Proposal(id: UUID(), createdAt: env.now().addingTimeInterval(-60), summary: "One-off", changes: changes)
        try env.proposals.upsertRemote([p])
        return p
    }

    private func todayChange(_ routine: String, on date: String, id: String = "c1") -> PlanChange {
        PlanChange(id: id, type: .today, routineId: routine, date: date, reason: "Home today")
    }

    // MARK: Applying

    @Test func applyingSwitchesTodayOnlyAndKeepsTheWeek() throws {
        let pull = try routine("Pull + Shoulders + Triceps")
        let push = try routine("Push + Arms")
        #expect(try env.todaysPlan().plan.base?.id == push.id)
        let week = try env.routines.schedule().days
        let revision = env.todayPlanRevision

        let p = try propose([todayChange(ref(pull), on: today)])
        let outcome = try env.applyProposal(p.id, changeIds: ["c1"])

        #expect(outcome.applied == ["c1"])
        let shown = try env.todaysPlan()
        #expect(shown.plan.kind == .switched && shown.plan.base?.id == pull.id && shown.plan.day == today)
        #expect(shown.scheduled?.id == push.id)
        #expect(try env.routines.schedule().days == week)
        #expect(env.todayPlanRevision > revision) // the watch is re-sent today's plan
        // The next day is back to normal: the switch belongs to today only.
        #expect(try env.todaysPlan(at: env.now().addingTimeInterval(86_400)).plan.kind != .switched)
    }

    @Test func routineAddedInTheSameProposalShowsOnToday() throws {
        let p = try propose([
            PlanChange(id: "c1", type: .addRoutine, routineId: "home-kb", name: "Home \u{00B7} KB Upper"),
            PlanChange(id: "c2", type: .addExercise, routineId: "home-kb", exerciseId: "0025", sets: 3, reps: 10),
            todayChange("home-kb", on: today, id: "c3"),
        ])
        try env.applyProposal(p.id, changeIds: ["c1", "c2", "c3"])
        let plan = try env.todaysPlan().plan
        #expect(plan.title == "Home \u{00B7} KB Upper" && plan.kind == .switched)
        #expect(plan.exercises.map(\.exerciseId) == ["0025"])
    }

    @Test func aLaterDateWaitsForItsDayAndLastsThatDayOnly() throws {
        let pull = try routine("Pull + Shoulders + Triceps")
        let p = try propose([todayChange(ref(pull), on: day(2))])
        try env.applyProposal(p.id, changeIds: ["c1"])

        #expect(try env.todaysPlan().plan.kind == .scheduled) // today is untouched
        let monday = env.now().addingTimeInterval(2 * 86_400)
        let then = try env.todaysPlan(at: monday).plan
        #expect(then.kind == .switched && then.base?.id == pull.id && then.day == day(2))
        #expect(try env.todaysPlan(at: monday).plan.base?.id == pull.id) // still there on a second look that day
        #expect(try env.todaysPlan(at: monday.addingTimeInterval(86_400)).plan.kind != .switched)
    }

    @Test func passedDateIsSkippedWithAClearMessage() throws {
        let pull = try routine("Pull + Shoulders + Triceps")
        let push = try routine("Push + Arms")
        let p = try propose([
            todayChange(ref(pull), on: day(-1), id: "c1"),
            PlanChange(id: "c2", type: .sets, routineId: ref(push), exerciseId: "0025", sets: 4),
        ])
        #expect(try env.proposalService().violations(for: p) == ["c1": "Date passed"])
        let outcome = try env.applyProposal(p.id, changeIds: ["c1", "c2"])
        #expect(outcome.applied == ["c2"] && outcome.skipped.map(\.message) == ["Date passed"])
        #expect(try env.todaysPlan().plan.base?.id == push.id)
    }

    @Test func autoApplyDoesTheSame() throws {
        try env.profiles.setMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, propose: true,
                                           autoApply: true)
        let pull = try routine("Pull + Shoulders + Triceps")
        try propose([todayChange(ref(pull), on: today)])
        #expect(try env.sync.autoApply() == 1)
        #expect(try env.todaysPlan().plan.base?.id == pull.id)
        #expect(env.pendingProposals().isEmpty)
    }

    @Test func pickingTheScheduledRoutineIsTheScheduledPlan() throws {
        let push = try routine("Push + Arms")
        let pull = try routine("Pull + Shoulders + Triceps")
        env.todayPlanStore.save(try env.todaysPlan().plan.switched(to: pull)) // the owner had switched by hand
        let p = try propose([todayChange(ref(push), on: today)])
        try env.applyProposal(p.id, changeIds: ["c1"])
        let plan = try env.todaysPlan().plan
        #expect(plan.kind == .scheduled && plan.base?.id == push.id)
    }

    @Test func undoTakesTheSwitchBack() throws {
        let pull = try routine("Pull + Shoulders + Triceps")
        let p = try propose([todayChange(ref(pull), on: today, id: "c1"), todayChange(ref(pull), on: day(1), id: "c2")])
        try env.applyProposal(p.id, changeIds: ["c1", "c2"])
        #expect(try env.undoProposal(p.id))
        #expect(try env.todaysPlan().plan.kind == .scheduled)
        #expect(try env.todaysPlan(at: env.now().addingTimeInterval(86_400)).plan.kind != .switched)
    }

    // MARK: Live workout safety

    /// A workout in progress is never touched: it keeps its routine, entries and logged sets. The switch only
    /// changes what Today offers once that workout is over.
    @Test func applyingDuringALiveWorkoutLeavesItAlone() throws {
        let push = try routine("Push + Arms")
        let pull = try routine("Pull + Shoulders + Triceps")
        env.startSession(routine: push)
        let session = try #require(env.session)
        let before = session.workout

        let p = try propose([todayChange(ref(pull), on: today)])
        try env.applyProposal(p.id, changeIds: ["c1"])

        #expect(env.session === session)
        #expect(session.workout == before)
        #expect(session.workout.routineId == push.id)
        #expect(try env.workouts.active()?.id == before.id)
        #expect(try env.todaysPlan().plan.base?.id == pull.id) // what Today shows next
    }

    // MARK: Review text

    @Test func reviewLineNamesTheDayAndWhatItReplaces() throws {
        let pull = try routine("Pull + Shoulders + Triceps")
        let plan = try env.routines.planState()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        func text(_ changes: [PlanChange]) -> [String] {
            ProposalModel.rows(for: changes, plan: plan, library: env.library, unit: .lb, now: env.now(),
                               violations: [:], calendar: utc).map(\.text)
        }
        let home = PlanChange(id: "a1", type: .addRoutine, routineId: "home-kb", name: "Home \u{00B7} KB Upper")
        #expect(text([home, todayChange("home-kb", on: "2026-09-26", id: "c1")]).last
            == "Today (Sat 26 Sep): Home \u{00B7} KB Upper instead of Push + Arms")
        #expect(text([todayChange(ref(pull), on: "2026-09-27")]).first
            == "Tomorrow (Sun 27 Sep): Pull + Shoulders + Triceps instead of a rest day")
        #expect(text([todayChange(ref(pull), on: "2026-10-02")]).first
            == "Fri 2 Oct: Pull + Shoulders + Triceps instead of Upper weak points")
        #expect(ProposalModel.rows(for: [todayChange(ref(pull), on: "2026-09-26")], plan: plan, library: env.library,
                                   unit: .lb, now: env.now(), violations: [:]).first?.label == "Switch")
    }
}
