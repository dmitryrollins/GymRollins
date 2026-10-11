import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Plan 15: weigh-in source (manual vs Apple Health) and the repository queries the Health sync uses.
@MainActor
@Suite struct HealthSupportTests {
    let fx: SyncFixture

    init() throws { fx = try SyncFixture() }

    @Test func weighInSourceDefaultsToAppAndRoundTrips() throws {
        let manual = BodyweightEntry(date: fx.clock.now, weightKg: 81)
        let imported = BodyweightEntry(date: fx.clock.now.addingTimeInterval(60), weightKg: 82, source: .appleHealth)
        #expect(manual.source == .app)
        try fx.body.add(manual)
        try fx.body.add(imported)
        let loaded = try fx.body.entries(since: nil)
        #expect(loaded.map(\.source) == [.app, .appleHealth])
    }

    @Test func upsertKeepsTheSource() throws {
        let entry = BodyweightEntry(date: fx.clock.now, weightKg: 81, source: .appleHealth)
        try fx.body.add(entry)
        try fx.body.upsert(BodyweightEntry(id: entry.id, date: entry.date, weightKg: 81.5, source: .appleHealth))
        #expect(try fx.body.entries(since: nil).first?.source == .appleHealth)
    }

    @Test func entryDecodesWithoutSourceAsApp() throws {
        let json = #"{"id":"6F1D1F0E-2C47-4E36-9D0A-000000000001","date":0,"weightKg":80}"#
        let entry = try JSONDecoder().decode(BodyweightEntry.self, from: Data(json.utf8))
        #expect(entry.source == .app)
    }

    @Test func hasRecordSeesTombstones() throws {
        let entry = BodyweightEntry(date: fx.clock.now, weightKg: 81)
        #expect(try !fx.body.hasRecord(id: entry.id))
        try fx.body.add(entry)
        try fx.body.delete(entry.id)
        #expect(try fx.body.hasRecord(id: entry.id))
        #expect(try fx.body.entries(since: nil).isEmpty)
    }

    @Test func syncCarriesTheSource() throws {
        let entry = BodyweightEntry(date: fx.clock.now, weightKg: 81, source: .appleHealth)
        try fx.body.add(entry)
        #expect(try fx.store.dirtyBodyweight().first?.value.source == .appleHealth)

        let remote = BodyweightEntry(date: fx.clock.now, weightKg: 83, source: .appleHealth)
        try fx.store.applyRemote(bodyweight: [SyncRow(value: remote, clientUpdatedAt: fx.clock.now)])
        #expect(try fx.body.entries(since: nil).first { $0.id == remote.id }?.source == .appleHealth)
    }

    @Test func finishedWorkoutsEndedSinceADate() throws {
        let t0 = fx.clock.now
        let old = Workout(startedAt: t0.addingTimeInterval(-7_200), endedAt: t0.addingTimeInterval(-3_600), name: "Old")
        let new = Workout(startedAt: t0, endedAt: t0.addingTimeInterval(3_600), name: "New")
        let gone = Workout(startedAt: t0, endedAt: t0.addingTimeInterval(1_800), name: "Gone")
        try fx.workouts.save(old)
        try fx.workouts.save(new)
        try fx.workouts.save(gone)
        try fx.workouts.delete(gone.id)
        try fx.workouts.saveActive(Workout(startedAt: t0, name: "Active"), pausedAt: nil)
        #expect(try fx.workouts.finished(endedSince: t0).map(\.name) == ["New"])
    }
}

/// Codex round 3: a Health weigh-in deleted on another device must stay deleted on a fresh one (the Health import
/// would otherwise re-create it from the same sample id and sync would resurrect it).
@MainActor
@Suite struct HealthTombstoneTests {
    @Test func remoteHealthTombstoneIsKeptWithoutALocalRow() throws {
        let fx = try SyncFixture()
        let entry = BodyweightEntry(date: fx.clock.now, weightKg: 81, source: .appleHealth)
        try fx.store.applyRemote(bodyweight: [SyncRow(value: entry, clientUpdatedAt: fx.clock.now,
                                                      deletedAt: fx.clock.now)])
        #expect(try fx.body.hasRecord(id: entry.id))
        #expect(try fx.body.entries(since: nil).isEmpty)
        #expect(try fx.store.dirtyBodyweight().isEmpty)

        let manual = BodyweightEntry(date: fx.clock.now, weightKg: 80)
        try fx.store.applyRemote(bodyweight: [SyncRow(value: manual, clientUpdatedAt: fx.clock.now,
                                                      deletedAt: fx.clock.now)])
        #expect(try !fx.body.hasRecord(id: manual.id)) // app tombstones are still skipped
    }
}

/// Codex round 5: weigh-ins read from Health remember their Health sample ids (synced), so any device can dedupe
/// imports and apply Health deletions without relying on the row id.
@MainActor
@Suite struct HealthSampleIdTests {
    @Test func sampleIdsRoundTripAndAreFound() throws {
        let fx = try SyncFixture()
        let mass = UUID(), fat = UUID()
        let entry = BodyweightEntry(date: fx.clock.now, weightKg: 81, bodyFatPct: 15, source: .appleHealth,
                                    healthSampleId: mass, healthFatSampleId: fat)
        try fx.body.add(entry, editedAt: fx.clock.now.addingTimeInterval(-3_600))
        #expect(try fx.body.entry(healthSampleId: mass)?.id == entry.id)
        #expect(try fx.body.entry(healthFatSampleId: fat)?.id == entry.id)
        #expect(try fx.body.hasRecord(healthSampleId: mass))
        let row = try #require(try fx.store.dirtyBodyweight().first)
        #expect(row.value.healthSampleId == mass && row.value.healthFatSampleId == fat)
        #expect(row.clientUpdatedAt == fx.clock.now.addingTimeInterval(-3_600))

        try fx.body.delete(entry.id)
        #expect(try fx.body.entry(healthSampleId: mass) == nil)
        #expect(try fx.body.hasRecord(healthSampleId: mass)) // tombstones count
    }

    @Test func upsertCanKeepAnEarlierEditTime() throws {
        let fx = try SyncFixture()
        let entry = BodyweightEntry(date: fx.clock.now, weightKg: 81, source: .appleHealth, healthSampleId: UUID())
        let t = fx.clock.now.addingTimeInterval(-7_200)
        try fx.body.add(entry, editedAt: t)
        try fx.body.upsert(BodyweightEntry(id: entry.id, date: entry.date, weightKg: 81, bodyFatPct: 14,
                                           source: .appleHealth, healthSampleId: entry.healthSampleId), editedAt: t)
        let edited = try #require(try fx.store.dirtyBodyweight().first?.clientUpdatedAt)
        #expect(edited > t && edited.timeIntervalSince(t) < 0.01) // stays at the sample time, just past the add
    }
}

/// Codex round 6.
@MainActor
@Suite struct HealthSyncRound6Tests {
    @Test func upsertNeverMovesTheEditTimeBackwards() throws {
        let fx = try SyncFixture()
        let entry = BodyweightEntry(date: fx.clock.now, weightKg: 81, source: .appleHealth, healthSampleId: UUID())
        try fx.body.add(entry) // edited "now"
        try fx.body.upsert(BodyweightEntry(id: entry.id, date: entry.date, weightKg: 81, bodyFatPct: 14,
                                           source: .appleHealth, healthSampleId: entry.healthSampleId),
                           editedAt: fx.clock.now.addingTimeInterval(-86_400))
        let row = try #require(try fx.store.dirtyBodyweight().first)
        #expect(row.clientUpdatedAt > fx.clock.now)
    }

    /// Two devices imported the same Health sample under different row ids: both converge on the smaller id.
    @Test func duplicateHealthImportsConvergeOnTheSmallerId() throws {
        let fx = try SyncFixture()
        let sample = UUID()
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        func row(_ id: UUID) -> BodyweightEntry {
            BodyweightEntry(id: id, date: fx.clock.now, weightKg: 81, source: .appleHealth, healthSampleId: sample)
        }
        // This device has the higher id; the remote copy has the lower one → local copy is tombstoned.
        try fx.body.add(row(high))
        try fx.store.applyRemote(bodyweight: [SyncRow(value: row(low), clientUpdatedAt: fx.clock.now)])
        #expect(try fx.body.entries(since: nil).map(\.id) == [low])
        #expect(try fx.store.dirtyBodyweight().contains { $0.value.id == high && $0.deletedAt != nil })

        // The other device (lower id locally) ignores the higher copy; it deletes itself over there.
        let other = try SyncFixture()
        try other.body.add(row(low))
        try other.store.applyRemote(bodyweight: [SyncRow(value: row(high), clientUpdatedAt: other.clock.now)])
        #expect(try other.body.entries(since: nil).map(\.id) == [low])
    }
}

/// Codex round 7.
@MainActor
@Suite struct HealthSyncRound7Tests {
    private func row(_ fx: SyncFixture, _ id: UUID, sample: UUID, fat: Double? = nil, fatId: UUID? = nil)
        -> BodyweightEntry {
        BodyweightEntry(id: id, date: fx.clock.now, weightKg: 81, bodyFatPct: fat, source: .appleHealth,
                        healthSampleId: sample, healthFatSampleId: fatId)
    }

    private let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!

    @Test func discardedDuplicateGivesItsBodyFatToTheKeptRow() throws {
        let fx = try SyncFixture()
        let sample = UUID(), fatId = UUID()
        try fx.body.add(row(fx, high, sample: sample, fat: 15, fatId: fatId))
        // The remote copy is older than this one's body fat.
        try fx.store.applyRemote(bodyweight: [SyncRow(value: row(fx, low, sample: sample),
                                                      clientUpdatedAt: fx.clock.now.addingTimeInterval(-60))])
        let kept = try #require(try fx.body.entries(since: nil).first)
        #expect(kept.id == low && kept.bodyFatPct == 15 && kept.healthFatSampleId == fatId)
        #expect(try fx.store.dirtyBodyweight().contains { $0.value.id == low }) // merged value goes up
    }

    @Test func ignoredRemoteDuplicateGivesItsBodyFatToTheLocalRow() throws {
        let fx = try SyncFixture()
        let sample = UUID()
        try fx.body.add(row(fx, low, sample: sample))
        fx.clock.advance() // the remote copy (with body fat) is newer
        try fx.store.applyRemote(bodyweight: [SyncRow(value: row(fx, high, sample: sample, fat: 16, fatId: UUID()),
                                                      clientUpdatedAt: fx.clock.now)])
        #expect(try fx.body.entries(since: nil).map(\.bodyFatPct) == [16])
    }

    @Test func discardedDuplicateTombstoneCarriesNoSampleId() throws {
        let fx = try SyncFixture()
        let sample = UUID()
        try fx.body.add(row(fx, high, sample: sample))
        try fx.store.applyRemote(bodyweight: [SyncRow(value: row(fx, low, sample: sample), clientUpdatedAt: fx.clock.now)])
        let tombstone = try #require(try fx.store.dirtyBodyweight().first { $0.value.id == high })
        #expect(tombstone.deletedAt != nil && tombstone.value.healthSampleId == nil)
    }

    @Test func aUserDeletionOfOneCopyDeletesItsTwins() throws {
        let fx = try SyncFixture()
        let sample = UUID()
        try fx.body.add(row(fx, low, sample: sample))
        fx.clock.advance()
        try fx.store.applyRemote(bodyweight: [SyncRow(value: row(fx, high, sample: sample),
                                                      clientUpdatedAt: fx.clock.now, deletedAt: fx.clock.now)])
        #expect(try fx.body.entries(since: nil).isEmpty)
    }
}

/// Codex round 8.
@MainActor
@Suite struct HealthSyncRound8Tests {
    private let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!

    private func row(_ fx: SyncFixture, _ id: UUID, sample: UUID?) -> BodyweightEntry {
        BodyweightEntry(id: id, date: fx.clock.now, weightKg: 81, source: .appleHealth, healthSampleId: sample)
    }

    @Test func aDeletedSampleStaysDeletedWhenATwinArrives() throws {
        let fx = try SyncFixture()
        let sample = UUID()
        try fx.body.add(row(fx, low, sample: sample))
        try fx.body.delete(low) // the user deleted it here
        fx.clock.advance()
        try fx.store.applyRemote(bodyweight: [SyncRow(value: row(fx, high, sample: sample), clientUpdatedAt: fx.clock.now)])
        #expect(try fx.body.entries(since: nil).isEmpty)
        let pushed = try #require(try fx.store.dirtyBodyweight().first { $0.value.id == high })
        #expect(pushed.deletedAt != nil) // the twin is deleted on the server too
    }

    @Test func anIgnoredRemoteDuplicateIsDeletedOnTheServer() throws {
        let fx = try SyncFixture()
        let sample = UUID()
        try fx.body.add(row(fx, low, sample: sample))
        try fx.store.applyRemote(bodyweight: [SyncRow(value: row(fx, high, sample: sample), clientUpdatedAt: fx.clock.now)])
        #expect(try fx.body.entries(since: nil).map(\.id) == [low])
        let pushed = try #require(try fx.store.dirtyBodyweight().first { $0.value.id == high })
        #expect(pushed.deletedAt != nil && pushed.value.healthSampleId == nil)
        #expect(pushed.clientUpdatedAt > fx.clock.now)
    }
}

/// Codex round 12.
@MainActor
@Suite struct HealthSyncRound12Tests {
    @Test func aHealthMeasurementDeletionBeatsANewerAutomaticMerge() throws {
        let fx = try SyncFixture()
        let sample = UUID()
        let entry = BodyweightEntry(date: fx.clock.now, weightKg: 81, source: .appleHealth, healthSampleId: sample)
        try fx.store.applyRemote(bodyweight: [SyncRow(value: entry, clientUpdatedAt: fx.clock.now)])
        fx.clock.advance(120)
        try fx.body.upsert(BodyweightEntry(id: entry.id, date: entry.date, weightKg: 81, bodyFatPct: 15,
                                           source: .appleHealth, healthSampleId: sample)) // e.g. a body fat merge
        try fx.store.applyRemote(bodyweight: [SyncRow(value: entry, clientUpdatedAt: fx.clock.now.addingTimeInterval(-60),
                                                      deletedAt: fx.clock.now.addingTimeInterval(-60))])
        #expect(try fx.body.entries(since: nil).isEmpty)
    }

    @Test func duplicateCleanupTombstonesKeepAMinimalEditTime() throws {
        let fx = try SyncFixture()
        let sample = UUID()
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        let t0 = fx.clock.now
        try fx.body.add(BodyweightEntry(id: high, date: t0, weightKg: 81, source: .appleHealth, healthSampleId: sample),
                        editedAt: t0)
        fx.clock.advance(3_600)
        try fx.store.applyRemote(bodyweight: [SyncRow(value: BodyweightEntry(id: low, date: t0, weightKg: 81,
                                                                             source: .appleHealth, healthSampleId: sample),
                                                      clientUpdatedAt: t0)])
        let tombstone = try #require(try fx.store.dirtyBodyweight().first { $0.value.id == high })
        #expect(tombstone.clientUpdatedAt < t0.addingTimeInterval(1)) // a later user deletion elsewhere still wins
    }
}

/// Codex round 13.
@MainActor
@Suite struct HealthSyncRound13Tests {
    private let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!

    @Test func anOlderDuplicateDoesNotBringBackDeletedBodyFat() throws {
        let fx = try SyncFixture()
        let sample = UUID()
        let t0 = fx.clock.now
        try fx.body.add(BodyweightEntry(id: low, date: t0, weightKg: 81, source: .appleHealth, healthSampleId: sample))
        // (its body fat was just deleted in Health: the row has none, edited now)
        try fx.store.applyRemote(bodyweight: [SyncRow(value: BodyweightEntry(id: high, date: t0, weightKg: 81,
                                                                             bodyFatPct: 15, source: .appleHealth,
                                                                             healthSampleId: sample, healthFatSampleId: UUID()),
                                                      clientUpdatedAt: t0.addingTimeInterval(-3_600))])
        #expect(try fx.body.entries(since: nil).map(\.bodyFatPct) == [nil])
    }
}

/// Codex round 14: when duplicates merge, the most recently edited copy's body fat wins — including "none".
@MainActor
@Suite struct HealthSyncRound14Tests {
    private let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!

    @Test func aNewerCopyWithoutBodyFatClearsItOnTheKeptRow() throws {
        let fx = try SyncFixture()
        let sample = UUID()
        let t0 = fx.clock.now
        try fx.body.add(BodyweightEntry(id: low, date: t0, weightKg: 81, bodyFatPct: 15, source: .appleHealth,
                                        healthSampleId: sample, healthFatSampleId: UUID()), editedAt: t0)
        try fx.store.applyRemote(bodyweight: [SyncRow(value: BodyweightEntry(id: high, date: t0, weightKg: 81,
                                                                             source: .appleHealth, healthSampleId: sample),
                                                      clientUpdatedAt: t0.addingTimeInterval(600))])
        #expect(try fx.body.entries(since: nil).map(\.bodyFatPct) == [nil])
    }

    @Test func aNewerDiscardedCopyWithoutBodyFatWins() throws {
        let fx = try SyncFixture()
        let sample = UUID()
        let t0 = fx.clock.now
        try fx.body.add(BodyweightEntry(id: high, date: t0, weightKg: 81, source: .appleHealth, healthSampleId: sample),
                        editedAt: t0.addingTimeInterval(600))
        try fx.store.applyRemote(bodyweight: [SyncRow(value: BodyweightEntry(id: low, date: t0, weightKg: 81,
                                                                             bodyFatPct: 15, source: .appleHealth,
                                                                             healthSampleId: sample,
                                                                             healthFatSampleId: UUID()),
                                                      clientUpdatedAt: t0)])
        #expect(try fx.body.entries(since: nil).map(\.bodyFatPct) == [nil])
    }
}

/// Codex round 15: the body fat sample id travels with the newest copy even when the percentage is the same.
@MainActor
@Suite struct HealthSyncRound15Tests {
    @Test func theNewerBodyFatSampleIdIsKept() throws {
        let fx = try SyncFixture()
        let sample = UUID(), oldFat = UUID(), newFat = UUID()
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        let t0 = fx.clock.now
        try fx.body.add(BodyweightEntry(id: low, date: t0, weightKg: 81, bodyFatPct: 15, source: .appleHealth,
                                        healthSampleId: sample, healthFatSampleId: oldFat), editedAt: t0)
        try fx.store.applyRemote(bodyweight: [SyncRow(value: BodyweightEntry(id: high, date: t0, weightKg: 81,
                                                                             bodyFatPct: 15, source: .appleHealth,
                                                                             healthSampleId: sample,
                                                                             healthFatSampleId: newFat),
                                                      clientUpdatedAt: t0.addingTimeInterval(600))])
        #expect(try fx.body.entry(healthFatSampleId: newFat)?.id == low)

        let other = try SyncFixture()
        try other.body.add(BodyweightEntry(id: high, date: t0, weightKg: 81, bodyFatPct: 15, source: .appleHealth,
                                           healthSampleId: sample, healthFatSampleId: newFat),
                           editedAt: t0.addingTimeInterval(600))
        try other.store.applyRemote(bodyweight: [SyncRow(value: BodyweightEntry(id: low, date: t0, weightKg: 81,
                                                                                bodyFatPct: 15, source: .appleHealth,
                                                                                healthSampleId: sample,
                                                                                healthFatSampleId: oldFat),
                                                         clientUpdatedAt: t0)])
        #expect(try other.body.entry(healthFatSampleId: newFat)?.id == low)
    }
}

/// Codex round 16: a local deletion of a Health weigh-in isn't undone by a newer live copy of the same row.
@MainActor
@Suite struct HealthSyncRound16Tests {
    @Test func aLocalHealthTombstoneSurvivesANewerLiveRow() throws {
        let fx = try SyncFixture()
        let entry = BodyweightEntry(date: fx.clock.now, weightKg: 81, source: .appleHealth, healthSampleId: UUID())
        try fx.body.add(entry)
        try fx.body.delete(entry.id)
        try fx.store.applyRemote(bodyweight: [SyncRow(value: BodyweightEntry(id: entry.id, date: entry.date, weightKg: 81,
                                                                             bodyFatPct: 15, source: .appleHealth,
                                                                             healthSampleId: entry.healthSampleId),
                                                      clientUpdatedAt: fx.clock.now.addingTimeInterval(3_600))])
        #expect(try fx.body.entries(since: nil).isEmpty)
        #expect(try fx.store.dirtyBodyweight().first { $0.value.id == entry.id }?.deletedAt != nil) // still pushed
    }
}
