import Foundation
import GymCore
import GymData
import Testing
@testable import GymHealth

@MainActor
@Suite struct HealthImportTests {
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    private func mass(_ kg: Double, _ date: Date, fromThisApp: Bool = false) -> HealthBodySample {
        HealthBodySample(kind: .bodyMass, value: kg, date: date, fromThisApp: fromThisApp, sourceName: "Withings")
    }

    @Test func enablingImportsTheLastTwoYears() async throws {
        let fx = try HealthFixture()
        let recent = mass(81.2, fx.now.addingTimeInterval(-3 * day))
        let old = mass(75, fx.now.addingTimeInterval(-800 * day))
        fx.store = FakeHealthStore(seed: [recent, old])
        let sync = fx.makeSync()
        _ = await sync.enable()
        let entries = try fx.body.entries(since: nil)
        #expect(entries.map(\.weightKg) == [81.2])
        #expect(entries.first?.healthSampleId == recent.uuid)
        #expect(entries.first?.source == .appleHealth)
        #expect(sync.state.lastImportCount == 1)
        #expect(fx.bodyChanges == 1)
    }

    @Test func importIsIncrementalAndAnchorPersists() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(seed: [mass(81, fx.now.addingTimeInterval(-day))])
        _ = await fx.makeSync().enable()
        #expect(HealthSyncState.load(from: fx.defaults).anchor != nil)

        await fx.store.addExternal(mass(81.5, fx.now))
        let relaunched = fx.makeSync()
        await relaunched.importBody()
        await relaunched.importBody()
        #expect(try fx.body.entries(since: nil).map(\.weightKg) == [81, 81.5])
    }

    @Test func ownSamplesAreSkipped() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(seed: [mass(81, fx.now.addingTimeInterval(-day), fromThisApp: true)])
        _ = await fx.makeSync().enable()
        #expect(try fx.body.entries(since: nil).isEmpty)
    }

    @Test func exportedWeighInsDoNotComeBackAsImports() async throws {
        let fx = try HealthFixture()
        let sync = fx.makeSync()
        _ = await sync.enable()
        try fx.body.add(BodyweightEntry(date: fx.now, weightKg: 81.4))
        await sync.sync()
        await sync.sync()
        let entries = try fx.body.entries(since: nil)
        #expect(entries.count == 1)
        #expect(entries.first?.source == .app)
    }

    @Test func sameDayManualEntryWithTheSameWeightIsNotDoubleCounted() async throws {
        let fx = try HealthFixture()
        try fx.body.add(BodyweightEntry(date: fx.now.addingTimeInterval(-2 * hour), weightKg: 81.4))
        fx.store = FakeHealthStore(seed: [mass(81.45, fx.now.addingTimeInterval(-hour)),
                                          mass(81.9, fx.now.addingTimeInterval(-hour / 2))])
        _ = await fx.makeSync().enable()
        let entries = try fx.body.entries(since: nil)
        #expect(entries.map(\.weightKg) == [81.4, 81.9])
    }

    @Test func weighInsDeletedInTheAppStayDeleted() async throws {
        let fx = try HealthFixture()
        let sample = mass(81, fx.now.addingTimeInterval(-day))
        fx.store = FakeHealthStore(seed: [sample])
        _ = await fx.makeSync().enable()
        try fx.body.delete(try #require(try fx.body.entry(healthSampleId: sample.uuid)).id)
        var state = HealthSyncState.load(from: fx.defaults)
        state.anchor = nil // e.g. Health re-delivers everything
        try state.save(to: fx.defaults)
        await fx.makeSync().importBody()
        #expect(try fx.body.entries(since: nil).isEmpty)
    }

    @Test func implausibleValuesAreSkipped() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(seed: [mass(12, fx.now.addingTimeInterval(-day)), mass(81, fx.now)])
        _ = await fx.makeSync().enable()
        #expect(try fx.body.entries(since: nil).map(\.weightKg) == [81])
    }

    @Test func bodyFatAttachesToTheMatchingWeighIn() async throws {
        let fx = try HealthFixture()
        let t = fx.now.addingTimeInterval(-day)
        fx.store = FakeHealthStore(seed: [
            HealthBodySample(kind: .bodyFat, value: 15.2, date: t.addingTimeInterval(60)),
            mass(81, t),
            HealthBodySample(kind: .bodyFat, value: 30, date: t.addingTimeInterval(6 * hour)), // no weigh-in near it
        ])
        _ = await fx.makeSync().enable()
        let entries = try fx.body.entries(since: nil)
        #expect(entries.count == 1)
        #expect(entries.first?.bodyFatPct == 15.2)
    }

    @Test func bodyFatArrivingLaterUpdatesTheWeighIn() async throws {
        let fx = try HealthFixture()
        let t = fx.now.addingTimeInterval(-day)
        fx.store = FakeHealthStore(seed: [mass(81, t)])
        let sync = fx.makeSync()
        _ = await sync.enable()
        await fx.store.addExternal(HealthBodySample(kind: .bodyFat, value: 14.8, date: t))
        await sync.importBody()
        #expect(try fx.body.entries(since: nil).first?.bodyFatPct == 14.8)
    }

    @Test func samplesDeletedInHealthAreRemoved() async throws {
        let fx = try HealthFixture()
        let sample = mass(81, fx.now.addingTimeInterval(-day))
        let manual = BodyweightEntry(date: fx.now.addingTimeInterval(-3 * day), weightKg: 80)
        try fx.body.add(manual)
        fx.store = FakeHealthStore(seed: [sample])
        let sync = fx.makeSync()
        _ = await sync.enable()
        await fx.store.deleteExternal(sample.uuid)
        await sync.importBody()
        #expect(try fx.body.entries(since: nil).map(\.id) == [manual.id])
    }

    @Test func importRecordsItsAnchorAndTime() async throws {
        let fx = try HealthFixture()
        fx.store = FakeHealthStore(seed: [mass(81, fx.now.addingTimeInterval(-day))])
        let sync = fx.makeSync()
        _ = await sync.enable()
        let anchor = sync.state.anchor
        #expect(anchor != nil)
        #expect(sync.state.lastImportAt == fx.now)
    }
}
