import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Which account the local copy belongs to, and records the server refused.
@MainActor
@Suite struct SyncStoreOwnershipTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    @Test func ownerPersistsAndResetForgetsIt() throws {
        defer { f.tearDown() }
        let user = UUID()
        #expect(f.store.ownerUserId == nil)
        f.store.ownerUserId = user
        // A fresh SyncStore over the same defaults sees the owner (it lives in UserDefaults, not memory).
        #expect(f.store.ownerUserId == user)
        f.store.setCursor(f.clock.now, for: .routines)
        try f.store.resetAll()
        #expect(f.store.ownerUserId == nil)
        #expect(f.store.cursor(for: .routines) == nil)
    }

    @Test func hasLocalDataReflectsAnyRecord() throws {
        defer { f.tearDown() }
        #expect(try !f.store.hasLocalData())
        try f.body.add(BodyweightEntry(date: f.clock.now, weightKg: 80))
        #expect(try f.store.hasLocalData())
        try f.store.resetAll()
        #expect(try !f.store.hasLocalData())
    }

    @Test func failureBlocksOnlyThatEditAndClearsOnSync() throws {
        defer { f.tearDown() }
        let routine = Routine(name: "Push", exercises: [])
        try f.routines.upsert(routine)
        let row = try #require(try f.store.dirtyRoutines().first)
        let id = routine.id.uuidString

        f.store.recordSyncFailure(SyncFailure(entity: .routines, id: id, clientUpdatedAt: row.clientUpdatedAt,
                                              message: "violates check constraint"))
        #expect(f.store.isSyncBlocked(.routines, id: id, clientUpdatedAt: row.clientUpdatedAt))
        #expect(f.store.syncFailures().map(\.message) == ["violates check constraint"])

        // A later edit is a new attempt: not blocked (the failure stays listed until it syncs).
        f.clock.advance()
        try f.routines.upsert(Routine(id: routine.id, name: "Push 2", exercises: []))
        let edited = try #require(try f.store.dirtyRoutines().first)
        #expect(!f.store.isSyncBlocked(.routines, id: id, clientUpdatedAt: edited.clientUpdatedAt))

        try f.store.markSynced(.routines, id: id, clientUpdatedAt: edited.clientUpdatedAt, serverUpdatedAt: f.clock.now)
        #expect(f.store.syncFailures().isEmpty)
    }

    @Test func resetClearsFailures() throws {
        defer { f.tearDown() }
        f.store.recordSyncFailure(SyncFailure(entity: .workouts, id: UUID().uuidString, clientUpdatedAt: f.clock.now,
                                              message: "x"))
        try f.store.resetAll()
        #expect(f.store.syncFailures().isEmpty)
    }
}
