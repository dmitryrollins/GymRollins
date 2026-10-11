import Foundation
import GymCore
import GymData
import Testing
@testable import GymHealth

/// Codex review round 3 (plan 15).
@MainActor
@Suite struct HealthReviewFix3Tests {
    private let day: TimeInterval = 86_400

    @Test func revertingAnEditAfterAFailedReplaceStillReExports() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout(name: "Push")
        await sync.exportChanges()
        await fx.store.setFailSaves(true)
        try fx.workouts.save(Workout(id: workout.id, startedAt: workout.startedAt, endedAt: workout.endedAt,
                                     name: "Edited", entries: workout.entries))
        await sync.exportChanges() // the old copy is deleted, the new save fails
        try fx.workouts.save(workout) // edit reverted
        await fx.store.setFailSaves(false)
        await sync.exportChanges()
        #expect(await fx.store.workouts.map(\.name) == ["Push"])
    }

    @Test func replacedWeightGetsTheBodyFatFromTheSameBatch() async throws {
        let fx = try HealthFixture()
        let t = fx.now.addingTimeInterval(-day)
        let old = HealthBodySample(kind: .bodyMass, value: 81, date: t)
        fx.store = FakeHealthStore(seed: [old])
        let sync = fx.makeSync()
        _ = await sync.enable()
        await fx.store.deleteExternal(old.uuid)
        let replacement = HealthBodySample(kind: .bodyMass, value: 81.2, date: t)
        await fx.store.addExternal(replacement)
        await fx.store.addExternal(HealthBodySample(kind: .bodyFat, value: 15.5, date: t))
        await sync.importBody()
        let entries = try fx.body.entries(since: nil)
        #expect(entries.map(\.healthSampleId) == [replacement.uuid])
        #expect(entries.first?.bodyFatPct == 15.5)
    }
}
