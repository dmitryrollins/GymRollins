import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Plan + one pending proposal (the shared fixture's knee-break shape, on real UUID routine ids).
@MainActor
struct ProposalFixture {
    let container: ModelContainer
    let clock = TestClock()
    let push = Routine(name: "Push + Arms", exercises: [
        RoutineExercise(exerciseId: "bench", sets: 3, reps: 10, repsMin: 8, weightKg: 59),
    ])
    let pull = Routine(name: "Pull", exercises: [RoutineExercise(exerciseId: "machine-shoulder-press", sets: 3, reps: 10)])
    let legs = Routine(name: "Legs", exercises: [RoutineExercise(exerciseId: "leg-extension", sets: 3, reps: 12)])
    let library: Set<String> = ["bench", "db-shoulder-press", "machine-shoulder-press", "leg-extension", "dips"]

    init() throws {
        container = try GymStore.container(inMemory: true)
        for r in [push, pull, legs] { try routines.upsert(r) }
        try routines.setSchedule(weekday: 1, routineId: push.id)
        try routines.setSchedule(weekday: 6, routineId: legs.id)
    }

    var context: ModelContext { container.mainContext }
    var routines: RoutineRepository { RoutineRepository(context: context, now: { [clock] in clock.now }) }
    var proposals: ProposalRepository { ProposalRepository(context: context, now: { [clock] in clock.now }) }
    var profiles: ProfileRepository { ProfileRepository(context: context, now: { [clock] in clock.now }) }
    var service: ProposalService {
        let library = library
        return ProposalService(context: context, exerciseExists: { library.contains($0) }, now: { [clock] in clock.now })
    }

    func id(_ r: Routine) -> String { r.id.uuidString.lowercased() }

    func kneeBreak(id: UUID = UUID(), extra: [PlanChange] = []) -> Proposal {
        Proposal(id: id, createdAt: clock.now.addingTimeInterval(-3600),
                 summary: "Knee break: replace Legs with upper work for 4 weeks", changes: [
                    PlanChange(id: "c1", type: .week, routineId: self.id(push), weekday: 6),
                    PlanChange(id: "c2", type: .weight, routineId: self.id(push), exerciseId: "bench", weightKg: 63.5),
                    PlanChange(id: "c3", type: .swapExercise, routineId: self.id(pull), exerciseId: "machine-shoulder-press",
                               toExerciseId: "db-shoulder-press"),
                    PlanChange(id: "c4", type: .removeExercise, routineId: self.id(legs), exerciseId: "leg-extension"),
                    PlanChange(id: "c5", type: .pauseRoutine, routineId: self.id(legs), paused: true),
                 ] + extra)
    }

    func bench() throws -> RoutineExercise? { try routines.routine(push.id)?.exercises.first }
}

@MainActor
@Suite struct ProposalRepositoryTests {
    let f: ProposalFixture
    init() throws { f = try ProposalFixture() }

    @Test func upsertRemoteStoresPendingOnceAndKeepsLocalResolution() throws {
        let p = f.kneeBreak()
        try f.proposals.upsertRemote([p])
        try f.proposals.upsertRemote([p])
        #expect(try f.proposals.pending().map(\.id) == [p.id])
        #expect(try f.proposals.pending().first?.changes.count == 5)
        #expect(try f.proposals.dirty().isEmpty) // remote rows never become dirty

        try f.proposals.dismiss(p.id)
        try f.proposals.upsertRemote([p]) // stale echo before the push: the local resolution wins
        #expect(try f.proposals.pending().isEmpty)
        #expect(try f.proposals.proposal(p.id)?.status == .dismissed)
    }

    @Test func pendingProposalsResolvedElsewhereAreDropped() throws {
        let a = f.kneeBreak()
        let b = f.kneeBreak()
        try f.proposals.upsertRemote([a, b])
        try f.proposals.upsertRemote([b]) // the full pending list no longer has `a`
        #expect(try f.proposals.pending().map(\.id) == [b.id])
    }

    @Test func markAppliedStoresSnapshotAndGoesDirty() throws {
        let p = f.kneeBreak()
        try f.proposals.upsertRemote([p])
        let before = try f.routines.planState()
        try f.proposals.markApplied(p.id, changeIds: ["c2"], total: 5, snapshot: before)
        let stored = try #require(try f.proposals.proposal(p.id))
        #expect(stored.status == .partial && stored.appliedChangeIds == ["c2"] && stored.resolvedAt == f.clock.now)
        #expect(try f.proposals.dirty().map(\.id) == [p.id])
        try f.proposals.markApplied(p.id, changeIds: ["c1", "c2", "c3", "c4", "c5"], total: 5, snapshot: before)
        #expect(try f.proposals.proposal(p.id)?.status == .applied)
    }

    @Test func undoOnlyWithinSevenDays() throws {
        let p = f.kneeBreak()
        try f.proposals.upsertRemote([p])
        let before = try f.routines.planState()
        try f.proposals.markApplied(p.id, changeIds: ["c2"], total: 5, snapshot: before)
        #expect(try f.proposals.proposal(p.id)?.canUndo(at: f.clock.now) == true)
        f.clock.advance(7 * 86_400 + 1)
        #expect(try f.proposals.undo(p.id) == nil)
        f.clock.advance(-2)
        #expect(try f.proposals.undo(p.id) == before)
        let stored = try #require(try f.proposals.proposal(p.id))
        #expect(stored.status == .dismissed && stored.appliedChangeIds.isEmpty && !stored.canUndo(at: f.clock.now))
        #expect(try f.proposals.undo(p.id) == nil) // only once
    }

    @Test func markSyncedClearsDirtyOnlyForThePushedEdit() throws {
        let p = f.kneeBreak()
        try f.proposals.upsertRemote([p])
        try f.proposals.dismiss(p.id)
        let row = try #require(try f.proposals.dirty().first)
        f.clock.advance()
        try f.proposals.markApplied(p.id, changeIds: ["c1"], total: 5, snapshot: try f.routines.planState())
        try f.proposals.markSynced(p.id, clientUpdatedAt: row.updatedAt)
        #expect(try f.proposals.dirty().count == 1)
        let newer = try #require(try f.proposals.dirty().first)
        try f.proposals.markSynced(p.id, clientUpdatedAt: newer.updatedAt)
        #expect(try f.proposals.dirty().isEmpty)
    }

    @Test func recentListsResolvedNewestFirst() throws {
        let a = f.kneeBreak()
        let b = f.kneeBreak()
        try f.proposals.upsertRemote([a, b])
        try f.proposals.dismiss(a.id)
        f.clock.advance()
        try f.proposals.markApplied(b.id, changeIds: ["c1"], total: 5, snapshot: try f.routines.planState())
        #expect(try f.proposals.recent(limit: 5).map(\.id) == [b.id, a.id])
        #expect(try f.proposals.recent(limit: 1).map(\.id) == [b.id])
    }

    @Test func mcpPermissionsUpdateOnlyThoseFields() throws {
        try f.profiles.save(Profile(unit: .kg, restSec: 90))
        #expect(try f.profiles.load().mcpReadPlan) // default on
        try f.profiles.setMcpPermissions(readWorkouts: false, readBody: true, readPlan: false, propose: false,
                                         autoApply: true)
        let p = try f.profiles.load()
        #expect(!p.mcpReadWorkouts && p.mcpReadBody && !p.mcpReadPlan && !p.mcpPropose && p.mcpAutoApply)
        #expect(p.unit == .kg && p.restSec == 90)
    }

    @Test func resetAllRemovesProposals() throws {
        try f.proposals.upsertRemote([f.kneeBreak()])
        try SyncStore(context: f.context, defaults: UserDefaults(suiteName: "t-\(UUID())")!).resetAll()
        #expect(try f.proposals.pending().isEmpty)
    }
}

@MainActor
@Suite struct ProposalServiceTests {
    let f: ProposalFixture
    init() throws { f = try ProposalFixture() }

    @Test func planStateRoundTripsThroughTheRepository() throws {
        let plan = try f.routines.planState()
        #expect(plan.routines.map(\.id) == [f.push.id, f.pull.id, f.legs.id])
        #expect(plan.schedule == [1: f.push.id, 6: f.legs.id])
    }

    @Test func applySubsetChangesPlanAndRecordsSnapshot() throws {
        let p = f.kneeBreak()
        try f.proposals.upsertRemote([p])
        let before = try f.routines.planState()
        let outcome = try f.service.apply(p.id, changeIds: ["c1", "c2", "c5"])
        #expect(outcome.applied == ["c1", "c2", "c5"] && outcome.skipped.isEmpty)
        #expect(try f.bench()?.weightKg == 63.5 && f.bench()?.weightSetAt == f.clock.now)
        #expect(try f.routines.schedule().days[6] == f.push.id)
        #expect(try f.routines.routine(f.legs.id)?.paused == true)
        #expect(try f.routines.routine(f.pull.id)?.exercises.first?.exerciseId == "machine-shoulder-press")
        let stored = try #require(try f.proposals.proposal(p.id))
        #expect(stored.status == .partial && stored.appliedChangeIds == ["c1", "c2", "c5"])

        #expect(try f.service.undo(p.id))
        #expect(try f.routines.planState() == before)
        #expect(try f.routines.routine(f.legs.id)?.paused == false)
        #expect(try f.proposals.proposal(p.id)?.status == .dismissed)
    }

    /// Codex P1: apply is one transaction. A failure while resolving the proposal (after the plan changes were
    /// staged) leaves the plan exactly as it was, the proposal pending and nothing dirty to sync.
    @Test func applyFailingAtResolutionLeavesPlanAndProposalUntouched() throws {
        let p = f.kneeBreak()
        try f.proposals.upsertRemote([p])
        let before = try f.routines.planState()
        let dirtyBefore = try SyncStore(context: f.context).dirtyRoutines().count
        let service = f.service
        service.fault = { step in if step == .resolve { throw FaultInjected() } }

        #expect(throws: FaultInjected.self) { try service.apply(p.id, changeIds: ["c1", "c2", "c3", "c4", "c5"]) }

        #expect(!f.context.hasChanges)
        #expect(try f.routines.planState() == before)
        #expect(try f.proposals.proposal(p.id)?.status == .pending)
        #expect(try f.proposals.proposal(p.id)?.hasSnapshot == false)
        #expect(try f.proposals.dirty().isEmpty)
        #expect(try SyncStore(context: f.context).dirtyRoutines().count == dirtyBefore)
        // The same proposal still applies afterwards.
        #expect(try f.service.apply(p.id, changeIds: ["c2"]).applied == ["c2"])
    }

    /// Two devices applying the same proposal's alias `add-routine` create the same routine id.
    @Test func addRoutineAliasGetsTheSameIdOnEveryDevice() throws {
        let other = try ProposalFixture()
        let p = Proposal(id: UUID(), createdAt: f.clock.now, summary: "Upper day", changes: [
            PlanChange(id: "c1", type: .addRoutine, routineId: "upper", name: "Upper"),
        ])
        var ids: [UUID] = []
        for device in [f, other] {
            try device.proposals.upsertRemote([p])
            try device.service.apply(p.id, changeIds: ["c1"])
            ids.append(try #require(try device.routines.all().first { $0.name == "Upper" }).id)
        }
        #expect(ids[0] == ids[1])
    }

    @Test func undoFailingAfterRestoringLeavesTheAppliedPlan() throws {
        let p = f.kneeBreak()
        try f.proposals.upsertRemote([p])
        try f.service.apply(p.id, changeIds: ["c1", "c2", "c5"])
        let applied = try f.routines.planState()
        let service = f.service
        service.fault = { step in if step == .commit { throw FaultInjected() } }

        #expect(throws: FaultInjected.self) { try service.undo(p.id) }

        #expect(!f.context.hasChanges)
        #expect(try f.routines.planState() == applied)
        let stored = try #require(try f.proposals.proposal(p.id))
        #expect(stored.status == .partial && stored.hasSnapshot)
        #expect(try f.service.undo(p.id))
    }

    @Test func invalidChangesAreSkippedWithTheirReasons() throws {
        let p = f.kneeBreak(extra: [PlanChange(id: "c6", type: .addExercise, routineId: f.id(f.push),
                                               exerciseId: "unknown", sets: 3, reps: 10)])
        try f.proposals.upsertRemote([p])
        let review = try f.service.violations(for: p)
        #expect(review.keys.sorted() == ["c6"])
        let outcome = try f.service.apply(p.id, changeIds: ["c2", "c6"])
        #expect(outcome.applied == ["c2"] && outcome.skipped.map(\.changeId) == ["c6"])
        #expect(try f.proposals.proposal(p.id)?.status == .partial)
    }

    @Test func applyingNothingValidThrowsAndChangesNothing() throws {
        let p = f.kneeBreak()
        try f.proposals.upsertRemote([p])
        #expect(throws: ProposalError.nothingToApply) { try f.service.apply(p.id, changeIds: []) }
        #expect(try f.proposals.pending().count == 1)
    }

    @Test func dismissResolvesWithoutTouchingThePlan() throws {
        let p = f.kneeBreak()
        try f.proposals.upsertRemote([p])
        let before = try f.routines.planState()
        try f.service.dismiss(p.id)
        #expect(try f.routines.planState() == before)
        #expect(try f.proposals.proposal(p.id)?.status == .dismissed)
    }

    @Test func autoApplyOnlyWhenTheProfileAllowsIt() throws {
        let p = f.kneeBreak()
        try f.proposals.upsertRemote([p])
        #expect(try f.service.autoApplyPending() == 0)
        #expect(try f.proposals.pending().count == 1)

        try f.profiles.save(Profile(mcpAutoApply: true))
        #expect(try f.service.autoApplyPending() == 1)
        let stored = try #require(try f.proposals.proposal(p.id))
        #expect(stored.status == .applied && stored.autoApplied && stored.canUndo(at: f.clock.now))
        #expect(try f.bench()?.weightKg == 63.5)
        #expect(try f.routines.routine(f.pull.id)?.exercises.first?.exerciseId == "db-shoulder-press")
    }

    @Test func autoApplySkipsAndRecordsInvalidChanges() throws {
        try f.profiles.save(Profile(mcpAutoApply: true))
        let p = f.kneeBreak(extra: [PlanChange(id: "c6", type: .sets, routineId: f.id(f.push), exerciseId: "dips", sets: 3)])
        try f.proposals.upsertRemote([p])
        #expect(try f.service.autoApplyPending() == 1)
        let stored = try #require(try f.proposals.proposal(p.id))
        #expect(stored.status == .partial && stored.skipped.map(\.changeId) == ["c6"])
    }

    @Test func autoApplyLeavesAllInvalidProposalsPending() throws {
        try f.profiles.save(Profile(mcpAutoApply: true))
        let p = Proposal(id: UUID(), createdAt: f.clock.now, summary: "Bad", changes: [
            PlanChange(id: "c1", type: .sets, routineId: "nope", exerciseId: "bench", sets: 3),
        ])
        try f.proposals.upsertRemote([p])
        #expect(try f.service.autoApplyPending() == 0)
        #expect(try f.proposals.pending().first?.skipped.map(\.changeId) == ["c1"])
    }
}

struct FaultInjected: Error {}
