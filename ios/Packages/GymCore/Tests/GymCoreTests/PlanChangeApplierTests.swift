import Foundation
import Testing
@testable import GymCore

private struct KneeFixture: Decodable {
    struct Case: Decodable { let name: String; let proposal: PlanProposal }
    let cases: [Case]
}

@Suite struct PlanChangeApplierTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let pushId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let pullId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let legsId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static var push: String { pushId.uuidString.lowercased() }

    static let plan = PlanState(routines: [
        Routine(id: pushId, name: "Push + Arms", exercises: [
            RoutineExercise(exerciseId: "bench", sets: 3, reps: 10, repsMin: 8, weightKg: 59),
            RoutineExercise(exerciseId: "incline-db", sets: 3, reps: 10, weightKg: 20),
        ]),
        Routine(id: pullId, name: "Pull", exercises: [
            RoutineExercise(exerciseId: "machine-shoulder-press", sets: 3, reps: 10, weightKg: 30),
        ]),
        Routine(id: legsId, name: "Legs", exercises: [
            RoutineExercise(exerciseId: "leg-extension", sets: 3, reps: 12, weightKg: 50),
        ]),
    ], schedule: [1: pushId, 3: pullId, 6: legsId])

    private func apply(_ changes: [PlanChange], to plan: PlanState = PlanChangeApplierTests.plan,
                       modes: [String: ExerciseMode] = [:]) throws -> PlanState {
        try PlanChangeApplier.apply(changes, to: plan, now: Self.now, mode: { modes[$0] ?? .reps })
    }

    private func bench(_ state: PlanState) -> RoutineExercise? {
        state.routines.first { $0.id == Self.pushId }?.exercises.first { $0.exerciseId == "bench" }
    }

    private func push(_ state: PlanState) throws -> Routine {
        try #require(state.routines.first { $0.id == Self.pushId })
    }

    // MARK: Exercise edits

    @Test func addExerciseAppendsWithPlannedWeight() throws {
        let out = try apply([PlanChange(id: "c1", type: .addExercise, routineId: Self.push, exerciseId: "dips",
                                        sets: 3, reps: 10, repsMin: 8, weightKg: 10)])
        let added = try #require(try push(out).exercises.last)
        #expect(added.exerciseId == "dips")
        #expect(added.sets == 3 && added.reps == 10 && added.repsMin == 8 && added.weightKg == 10)
        #expect(added.weightSetAt == Self.now)
        #expect(try push(out).exercises.count == 3)
    }

    @Test func addExerciseAtPositionAndCardioDefaults() throws {
        let out = try apply([PlanChange(id: "c1", type: .addExercise, routineId: Self.push, exerciseId: "bike",
                                        sets: 1, reps: 1, position: 0)], modes: ["bike": .cardio])
        let first = try #require(try push(out).exercises.first)
        #expect(first.exerciseId == "bike" && first.mode == .cardio && first.sec == 1200)
        #expect(first.weightSetAt == nil)
    }

    @Test func removeExercise() throws {
        let out = try apply([PlanChange(id: "c1", type: .removeExercise, routineId: Self.push, exerciseId: "bench")])
        #expect(try push(out).exercises.map(\.exerciseId) == ["incline-db"])
    }

    @Test func swapExerciseKeepsSlotAndDropsOldWeight() throws {
        let out = try apply([PlanChange(id: "c1", type: .swapExercise, routineId: Self.push, exerciseId: "bench",
                                        toExerciseId: "dips")])
        let first = try #require(try push(out).exercises.first)
        #expect(first.exerciseId == "dips" && first.sets == 3 && first.reps == 10)
        #expect(first.weightKg == nil)
        let withWeight = try apply([PlanChange(id: "c1", type: .swapExercise, routineId: Self.push, exerciseId: "bench",
                                               toExerciseId: "dips", weightKg: 5)])
        #expect(try push(withWeight).exercises.first?.weightKg == 5)
        #expect(try push(withWeight).exercises.first?.weightSetAt == Self.now)
    }

    // MARK: Value edits

    @Test func setsRepsRepsMinSec() throws {
        let out = try apply([
            PlanChange(id: "c1", type: .sets, routineId: Self.push, exerciseId: "bench", sets: 5),
            PlanChange(id: "c2", type: .reps, routineId: Self.push, exerciseId: "bench", reps: 6, repsMin: 4),
            PlanChange(id: "c3", type: .repsMin, routineId: Self.push, exerciseId: "incline-db", repsMin: 7),
            PlanChange(id: "c4", type: .sec, routineId: Self.push, exerciseId: "incline-db", sec: 45),
        ])
        let b = try #require(bench(out))
        #expect(b.sets == 5 && b.reps == 6 && b.repsMin == 4)
        let incline = try #require(try push(out).exercises.last)
        #expect(incline.repsMin == 7 && incline.sec == 45)
    }

    @Test func weightSetsWeightSetAtNow() throws {
        let out = try apply([PlanChange(id: "c1", type: .weight, routineId: Self.push, exerciseId: "bench", weightKg: 63.5)])
        #expect(bench(out)?.weightKg == 63.5)
        #expect(bench(out)?.weightSetAt == Self.now)
        #expect(bench(Self.plan)?.weightSetAt == nil) // input untouched
    }

    @Test func cardioStoresMinutesAsSeconds() throws {
        let out = try apply([PlanChange(id: "c1", type: .cardio, routineId: Self.push, exerciseId: "incline-db",
                                        minutes: 20, speed: 6)])
        #expect(try push(out).exercises.last?.sec == 1200)
    }

    @Test func reorderMovesAndClamps() throws {
        let out = try apply([PlanChange(id: "c1", type: .reorder, routineId: Self.push, exerciseId: "incline-db", position: 0)])
        #expect(try push(out).exercises.map(\.exerciseId) == ["incline-db", "bench"])
        let clamped = try apply([PlanChange(id: "c1", type: .reorder, routineId: Self.push, exerciseId: "bench", position: 9)])
        #expect(try push(clamped).exercises.map(\.exerciseId) == ["incline-db", "bench"])
    }

    @Test func supersetGroupsBothExercises() throws {
        let out = try apply([PlanChange(id: "c1", type: .superset, routineId: Self.push, exerciseId: "bench",
                                        withExerciseId: "incline-db")])
        let groups = try push(out).exercises.map(\.supersetGroup)
        #expect(groups == ["A", "A"])
    }

    @Test func progressionPolicyAndIncrement() throws {
        let out = try apply([
            PlanChange(id: "c1", type: .routineProg, routineId: Self.push, policy: .linear),
            PlanChange(id: "c2", type: .exerciseProg, routineId: Self.push, exerciseId: "bench", policy: .greyskull),
            PlanChange(id: "c3", type: .inc, routineId: Self.push, exerciseId: "bench", incKg: 2.5),
        ])
        #expect(try push(out).policy == .linear)
        #expect(bench(out)?.policy == .greyskull && bench(out)?.incKg == 2.5)
    }

    // MARK: Routine edits

    @Test func addRoutineMapsIdForLaterChanges() throws {
        let fresh = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let out = try PlanChangeApplier.apply([
            PlanChange(id: "c1", type: .addRoutine, routineId: "upper", name: "  Upper  "),
            PlanChange(id: "c2", type: .addExercise, routineId: "upper", exerciseId: "dips", sets: 3, reps: 10),
            PlanChange(id: "c3", type: .week, routineId: "upper", weekday: 7),
        ], to: Self.plan, now: Self.now, newID: { _ in fresh })
        let upper = try #require(out.routines.last)
        #expect(upper.id == fresh && upper.name == "Upper" && upper.exercises.map(\.exerciseId) == ["dips"])
        #expect(out.schedule[7] == fresh)
    }

    /// Codex P2: two devices applying the same proposal generate the same id for an alias `add-routine`.
    @Test func addRoutineAliasIdIsStablePerProposalAndChange() throws {
        let proposal = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let changes = [
            PlanChange(id: "c1", type: .addRoutine, routineId: "upper", name: "Upper"),
            PlanChange(id: "c2", type: .addRoutine, routineId: "lower", name: "Lower"),
        ]
        let onPhone = try PlanChangeApplier.apply(changes, to: Self.plan, now: Self.now,
                                                  newID: StableUUID.generator(namespace: proposal))
        let onIpad = try PlanChangeApplier.apply(changes, to: Self.plan, now: Self.now,
                                                 newID: StableUUID.generator(namespace: proposal))
        let ids = onPhone.routines.suffix(2).map(\.id)
        #expect(ids == onIpad.routines.suffix(2).map(\.id))
        #expect(Set(ids).count == 2)
        let other = try PlanChangeApplier.apply(changes, to: Self.plan, now: Self.now,
                                                newID: StableUUID.generator(namespace: UUID()))
        #expect(Set(other.routines.suffix(2).map(\.id)).isDisjoint(with: ids))
    }

    @Test func stableUUIDIsDeterministicVersion5Shaped() {
        let ns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        let a = StableUUID.make(namespace: ns, name: "c1")
        #expect(a == StableUUID.make(namespace: ns, name: "c1"))
        #expect(a != StableUUID.make(namespace: ns, name: "c2"))
        let bytes = withUnsafeBytes(of: a.uuid) { Array($0) }
        #expect(bytes[6] >> 4 == 5)          // version nibble
        #expect(bytes[8] & 0xC0 == 0x80)     // RFC 4122 variant
    }

    @Test func addRoutineUsesGivenUUID() throws {
        let given = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let out = try apply([PlanChange(id: "c1", type: .addRoutine, routineId: given.uuidString.lowercased(), name: "New")])
        #expect(out.routines.last?.id == given)
    }

    @Test func removeRoutineClearsItsScheduleDays() throws {
        let out = try apply([PlanChange(id: "c1", type: .removeRoutine, routineId: Self.legsId.uuidString)])
        #expect(!out.routines.contains { $0.id == Self.legsId })
        #expect(out.schedule[6] == nil && out.schedule[1] == Self.pushId)
    }

    @Test func renameAndPause() throws {
        let out = try apply([
            PlanChange(id: "c1", type: .renameRoutine, routineId: Self.push, name: "Chest"),
            PlanChange(id: "c2", type: .pauseRoutine, routineId: Self.push, paused: true),
        ])
        #expect(try push(out).name == "Chest" && push(out).paused)
    }

    @Test func weekAssignsAndClearsDays() throws {
        let out = try apply([
            PlanChange(id: "c1", type: .week, routineId: Self.push, weekday: 6),
            PlanChange(id: "c2", type: .week, weekday: 3),
        ])
        #expect(out.schedule == [1: Self.pushId, 6: Self.pushId])
    }

    // MARK: Errors, fixture, subsets

    @Test func missingReferencesThrowWithTheChangeId() {
        #expect(throws: PlanApplyError.invalid("c9")) {
            try apply([PlanChange(id: "c9", type: .sets, routineId: "nope", exerciseId: "bench", sets: 3)])
        }
        #expect(throws: PlanApplyError.invalid("c8")) {
            try apply([PlanChange(id: "c8", type: .weight, routineId: Self.push, exerciseId: "dips", weightKg: 3)])
        }
        #expect(throws: PlanApplyError.invalid("c7")) {
            try apply([PlanChange(id: "c7", type: .weight, routineId: Self.push, exerciseId: "bench")])
        }
    }

    static func kneeBreak() throws -> PlanProposal {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/plan-changes.json")
        let fixture = try JSONDecoder().decode(KneeFixture.self, from: Data(contentsOf: url))
        return try #require(fixture.cases.first { $0.name == "valid knee-break proposal" }).proposal
    }

    static let aliases = ["push": pushId, "pull": pullId, "legs": legsId]

    @Test func fixtureKneeBreakProposal() throws {
        let proposal = try Self.kneeBreak()
        let out = try PlanChangeApplier.apply(proposal.changes, to: Self.plan, now: Self.now, aliases: Self.aliases)
        #expect(out.schedule == [1: Self.pushId, 3: Self.pullId, 6: Self.pushId])
        #expect(bench(out)?.weightKg == 63.5 && bench(out)?.weightSetAt == Self.now)
        let pull = try #require(out.routines.first { $0.id == Self.pullId })
        #expect(pull.exercises.map(\.exerciseId) == ["db-shoulder-press"])
        let legs = try #require(out.routines.first { $0.id == Self.legsId })
        #expect(legs.exercises.isEmpty && legs.paused)
        #expect(out.routines.map(\.id) == Self.plan.routines.map(\.id))
    }

    @Test func subsetOfFixtureChanges() throws {
        let proposal = try Self.kneeBreak()
        let chosen = proposal.changes.filter { ["c2", "c5"].contains($0.id) }
        let out = try PlanChangeApplier.apply(chosen, to: Self.plan, now: Self.now, aliases: Self.aliases)
        #expect(out.schedule == Self.plan.schedule)
        #expect(bench(out)?.weightKg == 63.5)
        let legs = try #require(out.routines.first { $0.id == Self.legsId })
        #expect(legs.paused && legs.exercises.count == 1)
    }

    @Test func snapshotUsesLowercasedIdsAndEffectiveReps() {
        let snap = Self.plan.snapshot
        #expect(snap.routines.first?.id == Self.push)
        #expect(snap.routines.first?.exerciseIds == ["bench", "incline-db"])
        #expect(snap.routines.first?.reps?["bench"] == 10 && snap.routines.first?.repsMin?["bench"] == 8)
    }

    @Test func planStateRoundTripsJSON() throws {
        let data = try JSONEncoder().encode(Self.plan)
        #expect(try JSONDecoder().decode(PlanState.self, from: data) == Self.plan)
    }
}
