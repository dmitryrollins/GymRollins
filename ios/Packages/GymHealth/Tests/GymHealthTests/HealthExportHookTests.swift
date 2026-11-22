import Foundation
import GymCore
import Testing
@testable import GymHealth

@MainActor
private final class ExportedIds { var ids: [UUID] = [] }

/// Plan 40: the app re-reads a workout's Health data once the phone's export wrote its copy. Only a copy actually
/// written is reported.
@MainActor
@Suite struct HealthExportHookTests {
    private func makeSync(_ fx: HealthFixture) -> (HealthSync, ExportedIds) {
        let sync = fx.makeSync()
        let exported = ExportedIds()
        sync.onWorkoutExported = { exported.ids.append($0) }
        return (sync, exported)
    }

    @Test func aCopyThePhoneWroteIsReportedOnce() async throws {
        let fx = try HealthFixture()
        let (sync, exported) = makeSync(fx)
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        await sync.exportChanges()
        await sync.exportChanges() // unchanged: not written again
        #expect(exported.ids == [workout.id])
    }

    @Test func aFailedSaveIsNotReported() async throws {
        let fx = try HealthFixture()
        let (sync, exported) = makeSync(fx)
        _ = await sync.enable()
        fx.advance()
        try fx.finishWorkout()
        await fx.store.setFailSaves(true)
        await sync.exportChanges()
        #expect(exported.ids.isEmpty)
    }

    @Test func theWatchsCopyIsNotThePhonesExport() async throws {
        let fx = try HealthFixture()
        let (sync, exported) = makeSync(fx)
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        sync.markRecordedByWatch(workout.id)
        await sync.exportChanges()
        #expect(exported.ids.isEmpty, "the watch's own hook reads it")
        #expect(await fx.store.workouts.isEmpty)
    }
}
