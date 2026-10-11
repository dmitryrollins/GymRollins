import Foundation
import GymCore
import GymData
import Testing
@testable import GymHealth

/// Codex review round 2 (plan 15).
@MainActor
@Suite struct HealthReviewFix2Tests {
    private let day: TimeInterval = 86_400
    private let allAllowed = Dictionary(uniqueKeysWithValues: HealthDataType.allCases.map { ($0, HealthPermission.authorized) })

    private func waitUntilParked(_ store: FakeHealthStore) async {
        for _ in 0..<1_000 where await store.parkedCount == 0 { await Task.yield() }
    }

    @Test func disablingMidRunSkipsTheWeighInPhase() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        try fx.finishWorkout()
        try fx.body.add(BodyweightEntry(date: fx.now, weightKg: 81))
        await fx.store.setGate(true)
        async let run: Void = sync.exportChanges()
        await waitUntilParked(fx.store)
        sync.disable()
        await fx.store.setGate(false)
        await run
        #expect(await fx.store.weighIns.isEmpty)
    }

    @Test func replacedBodyFatSurvivesDeletingTheOldSample() async throws {
        let fx = try HealthFixture()
        let t = fx.now.addingTimeInterval(-day)
        let old = HealthBodySample(kind: .bodyFat, value: 15, date: t)
        fx.store = FakeHealthStore(seed: [HealthBodySample(kind: .bodyMass, value: 81, date: t), old])
        let sync = fx.makeSync()
        _ = await sync.enable()
        await fx.store.addExternal(HealthBodySample(kind: .bodyFat, value: 14.5, date: t))
        await fx.store.deleteExternal(old.uuid)
        await sync.importBody()
        #expect(try fx.body.entries(since: nil).first?.bodyFatPct == 14.5)
    }

    @Test func grantingEnergyLaterReExportsWithCalories() async throws {
        var grant = allAllowed
        grant[.activeEnergy] = .denied
        let store = FakeHealthStore(grantOnRequest: grant)
        let fx = try HealthFixture(store: store)
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        try fx.finishWorkout()
        await sync.exportChanges()
        #expect(await store.workouts.first?.kcal == nil)
        await store.setPermissions(allAllowed)
        await sync.exportChanges()
        #expect(await store.workouts.count == 1)
        #expect(await store.workouts.first?.kcal == 320) // active: (5 − 1) MET × 80 kg × 1 h
    }

    @Test func grantingBodyFatLaterReExportsTheWeighIn() async throws {
        var grant = allAllowed
        grant[.bodyFat] = .denied
        let store = FakeHealthStore(grantOnRequest: grant)
        let fx = try HealthFixture(store: store)
        let sync = fx.makeSync()
        _ = await sync.enable()
        try fx.body.add(BodyweightEntry(date: fx.now, weightKg: 81, bodyFatPct: 15))
        await sync.exportChanges()
        await store.setPermissions(allAllowed)
        await sync.exportChanges()
        #expect(await store.bodySamples().filter { $0.kind == .bodyFat }.map(\.value) == [15])
        #expect(await store.weighIns.count == 1)
    }

    @Test func deletionBlockedByPermissionIsRetriedLater() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        fx.advance()
        let workout = try fx.finishWorkout()
        await sync.exportChanges()
        var revoked = allAllowed
        revoked[.workouts] = .denied
        await fx.store.setPermissions(revoked)
        try fx.workouts.delete(workout.id)
        await sync.exportChanges()
        #expect(sync.state.workouts[workout.id.uuidString] != nil)
        await fx.store.setPermissions(allAllowed)
        await sync.exportChanges()
        #expect(await fx.store.workouts.isEmpty)
        #expect(sync.state.workouts.isEmpty)
    }
}
