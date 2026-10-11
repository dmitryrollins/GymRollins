import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

@MainActor
@Suite struct MuscleTargetTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    var targets: MuscleTargetRepository { MuscleTargetRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }

    @Test func defaultsWhenNothingStored() throws {
        #expect(try targets.all() == MuscleGroup.defaultTargets)
        #expect(try targets.customized().isEmpty)
    }

    @Test func setStoresAndOverridesTheDefault() throws {
        try targets.set(.chest, SetTargetRange(min: 12, max: 18))
        #expect(try targets.all()[.chest] == SetTargetRange(min: 12, max: 18))
        #expect(try targets.all()[.biceps] == MuscleGroup.biceps.defaultTarget)
        #expect(try targets.customized() == [.chest])
        f.clock.advance()
        try targets.set(.chest, SetTargetRange(min: 8, max: 16))
        #expect(try targets.all()[.chest] == SetTargetRange(min: 8, max: 16))
        #expect(try f.context.fetchCount(FetchDescriptor<MuscleTargetRecord>()) == 1)
    }

    @Test func invalidRangesAreRejected() throws {
        #expect(throws: GymDataError.self) { try targets.set(.chest, SetTargetRange(min: 12, max: 10)) }
        #expect(throws: GymDataError.self) { try targets.set(.chest, SetTargetRange(min: 0, max: 51)) }
        #expect(try targets.customized().isEmpty)
    }

    @Test func resetWritesDefaultsSoTheResetSyncs() throws {
        try targets.set(.chest, SetTargetRange(min: 12, max: 18))
        try targets.set(.lats, SetTargetRange(min: 4, max: 8))
        try f.store.dirtyMuscleTargets().forEach {
            try f.store.markSynced(.muscleTargets, id: $0.value.group.rawValue, clientUpdatedAt: $0.clientUpdatedAt,
                                   serverUpdatedAt: f.clock.now)
        }
        f.clock.advance()
        try targets.resetAll()
        #expect(try targets.all() == MuscleGroup.defaultTargets)
        let dirty = try f.store.dirtyMuscleTargets()
        #expect(Set(dirty.map(\.value.group)) == [.chest, .lats])
        #expect(dirty.allSatisfy { $0.value.range == $0.value.group.defaultTarget })
    }

    // MARK: Sync

    @Test func dirtyRowsAreMarkedSyncedOnlyForThePushedEdit() throws {
        try targets.set(.chest, SetTargetRange(min: 12, max: 18))
        let row = try #require(try f.store.dirtyMuscleTargets().first)
        #expect(row.value == MuscleTargetValue(group: .chest, range: SetTargetRange(min: 12, max: 18)))
        f.clock.advance()
        try targets.set(.chest, SetTargetRange(min: 12, max: 20)) // edited while the push was in flight
        try f.store.markSynced(.muscleTargets, id: "chest", clientUpdatedAt: row.clientUpdatedAt,
                               serverUpdatedAt: f.clock.now)
        #expect(try f.store.dirtyMuscleTargets().count == 1)
        let again = try #require(try f.store.dirtyMuscleTargets().first)
        try f.store.markSynced(.muscleTargets, id: "chest", clientUpdatedAt: again.clientUpdatedAt,
                               serverUpdatedAt: f.clock.now)
        #expect(try f.store.dirtyMuscleTargets().isEmpty)
    }

    @Test func applyRemoteInsertsUpdatesAndKeepsNewerLocalEdits() throws {
        let t0 = f.clock.now
        try f.store.applyRemote(muscleTargets: [
            SyncRow(value: MuscleTargetValue(group: .chest, range: SetTargetRange(min: 14, max: 22)),
                    clientUpdatedAt: t0, serverUpdatedAt: t0),
        ])
        #expect(try targets.all()[.chest] == SetTargetRange(min: 14, max: 22))
        #expect(try f.store.dirtyMuscleTargets().isEmpty)

        f.clock.advance(120)
        try targets.set(.chest, SetTargetRange(min: 10, max: 12)) // local, newer than the next remote row
        try f.store.applyRemote(muscleTargets: [
            SyncRow(value: MuscleTargetValue(group: .chest, range: SetTargetRange(min: 1, max: 2)),
                    clientUpdatedAt: t0.addingTimeInterval(60), serverUpdatedAt: t0.addingTimeInterval(60)),
        ])
        #expect(try targets.all()[.chest] == SetTargetRange(min: 10, max: 12))

        try f.store.applyRemote(muscleTargets: [
            SyncRow(value: MuscleTargetValue(group: .chest, range: SetTargetRange(min: 3, max: 4)),
                    clientUpdatedAt: f.clock.now.addingTimeInterval(60), serverUpdatedAt: f.clock.now),
        ])
        #expect(try targets.all()[.chest] == SetTargetRange(min: 3, max: 4))
    }

    @Test func applyRemoteSkipsInvalidRows() throws {
        try f.store.applyRemote(muscleTargets: [
            SyncRow(value: MuscleTargetValue(group: .chest, range: SetTargetRange(min: 9, max: 3)),
                    clientUpdatedAt: f.clock.now),
        ])
        #expect(try targets.customized().isEmpty)
    }

    @Test func resetAllAndHasLocalDataIncludeTargets() throws {
        try targets.set(.chest, SetTargetRange(min: 12, max: 18))
        #expect(try f.store.hasLocalData())
        try f.store.resetAll()
        #expect(try targets.customized().isEmpty)
        #expect(try !f.store.hasLocalData())
    }
}

@MainActor
@Suite struct InsightsQueryTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    @Test func finishedWorkoutsSinceAndStartDates() throws {
        let base = f.clock.now
        for day in [10, 5, 1] {
            let start = base.addingTimeInterval(-Double(day) * 86_400)
            try f.workouts.save(Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "D\(day)"))
        }
        try f.workouts.saveActive(Workout(startedAt: base, name: "Active"), pausedAt: nil)
        let deleted = Workout(startedAt: base.addingTimeInterval(-2 * 86_400), name: "Gone")
        try f.workouts.save(deleted)
        try f.workouts.delete(deleted.id)

        let recent = try f.workouts.finished(since: base.addingTimeInterval(-6 * 86_400))
        #expect(recent.map(\.name) == ["D1", "D5"])
        #expect(try f.workouts.finishedStartDates().count == 3)
    }
}
