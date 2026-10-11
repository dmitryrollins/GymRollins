import Foundation
import GymCore
import GymData
import GymWatchLink
import Testing
@testable import GymRollins

/// Codex review of plan 17: today-only plan changes (switch, add, delete) reach the watch, and the watch's "Start
/// today" starts exactly the plan Today shows.
@MainActor
@Suite struct WatchTodaySyncTests {
    final class Transport: PhoneWatchTransport {
        var onCommand: ((WatchCommand) -> Void)?
        var onReady: (() -> Void)?
        private(set) var pushed: [WatchState] = []

        func activate() {}
        func push(_ state: WatchState) { pushed.append(state) }
        func launchWatchWorkout() {}
    }

    let defaults: UserDefaults
    let env: AppEnvironment
    let transport = Transport()
    let controller: WatchSyncController

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "WatchTodaySyncTests.\(UUID())"))
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow",
                                                                       "2026-09-28T09:00:00Z"]),
                                     defaults: defaults)
        self.env = env
        controller = WatchSyncController(transport: transport, defaults: defaults, now: env.now,
                                         handler: WatchCommandHandler(defaults: defaults, hooks: env.watchCommandHooks),
                                         resolveEnded: { env.endedWatchWorkout($0) })
        controller.observe { env.watchSnapshot }
    }

    /// Lets the observation's re-track task run.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// Today's editor, the way TodayView sets it up.
    private func todayEditor() throws -> TodayPlanEditor {
        let editor = TodayPlanEditor(store: env.todayPlanStore, defaultRestSec: env.profile.restSec)
        editor.load(try env.todaysPlan().plan)
        return editor
    }

    private var shownToday: WatchToday? { transport.pushed.last?.today }

    @Test func switchingTodaysRoutineUpdatesTheWatch() async throws {
        let editor = try todayEditor()
        let plan = try #require(editor.plan)
        let other = try #require(try env.routines.all().first { $0.id != plan.base?.id && !$0.exercises.isEmpty })
        editor.apply(plan.switched(to: other))
        await settle()
        #expect(shownToday == WatchToday(title: other.name, canStart: true))
    }

    @Test func deletingAndAddingTodaysExercisesUpdatesCanStart() async throws {
        let editor = try todayEditor()
        let routine = try #require(try env.routines.all().first { !$0.exercises.isEmpty })
        editor.apply(try #require(editor.plan).switched(to: routine))
        await settle()
        for item in try #require(editor.plan).exercises { editor.delete(item.id) }
        await settle()
        #expect(shownToday == WatchToday(title: routine.name, canStart: false))
        editor.apply(try #require(editor.plan).adding([RoutineExercise(exerciseId: "0025", sets: 3, reps: 8)]))
        await settle()
        #expect(shownToday == WatchToday(title: routine.name, canStart: true))
    }

    /// Claude's `today` change takes the same path as Switch, so the watch is re-sent today's routine.
    @Test func applyingClaudesTodayChangeUpdatesTheWatch() async throws {
        let scheduled = try env.todaysPlan().plan
        let other = try #require(try env.routines.all().first { $0.id != scheduled.base?.id && !$0.exercises.isEmpty })
        await settle()
        let proposal = Proposal(id: UUID(), createdAt: env.now(), summary: "Switch today", changes: [
            PlanChange(id: "c1", type: .today, routineId: other.id.uuidString.lowercased(),
                       date: TodayPlan.dayKey(env.now())),
        ])
        try env.proposals.upsertRemote([proposal])
        try env.applyProposal(proposal.id, changeIds: ["c1"])
        await settle()
        #expect(shownToday == WatchToday(title: other.name, canStart: true))
    }

    @Test func switchingBackToTheScheduledPlanUpdatesTheWatch() async throws {
        let editor = try todayEditor()
        let scheduled = try #require(editor.plan)
        let other = try #require(try env.routines.all().first { $0.id != scheduled.base?.id && !$0.exercises.isEmpty })
        editor.apply(scheduled.switched(to: other))
        await settle()
        // Today's "back to the scheduled routine": the stored plan is cleared, not saved.
        env.todayPlanStore.clear()
        editor.load(scheduled)
        await settle()
        #expect(shownToday?.title == scheduled.title)
    }

    @Test func startTodayFromTheWatchStartsThePlanShown() async throws {
        let editor = try todayEditor()
        let plan = try #require(editor.plan)
        let other = try #require(try env.routines.all().first { $0.id != plan.base?.id && $0.exercises.count > 1 })
        let switched = plan.switched(to: other)
        editor.apply(switched)
        let shown = try #require(editor.plan)
        editor.delete(try #require(shown.exercises.first).id) // and drop one exercise for today
        await settle()
        let expected = try #require(editor.plan)
        #expect(shownToday?.title == other.name)
        controller.receive(WatchCommand(issuedAt: env.now(), action: .startToday))
        let workout = try #require(env.session?.workout)
        #expect(workout.routineId == other.id)
        #expect(workout.entries.map(\.exerciseId) == expected.exercises.map(\.exerciseId))
    }
}
