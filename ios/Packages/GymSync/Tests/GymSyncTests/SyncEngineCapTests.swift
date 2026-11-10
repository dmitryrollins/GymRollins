import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymSync

/// A row past an account cap (server/migrations/0010_account_caps.sql) stays on this iPhone with the server's words,
/// isn't pushed again until it is edited, and doesn't hold back an edit pushed beside it.
@MainActor
@Suite struct SyncEngineCapTests {
    let f: EngineFixture
    init() throws { f = try EngineFixture() }

    @Test func aWeighInPastTheCapStaysOnThisIPhoneAndTheEditBesideItSyncs() async throws {
        defer { f.tearDown() }
        let stored = BodyweightEntry(date: f.clock.now, weightKg: 81)
        try f.body.add(stored)
        await f.engine.sync()
        #expect(await f.server.bodyweight.count == 1)

        await f.server.capBodyweight(at: 1)
        f.clock.advance()
        try f.body.upsert(BodyweightEntry(id: stored.id, date: stored.date, weightKg: 82))
        let refused = BodyweightEntry(date: f.clock.now, weightKg: 83)
        try f.body.add(refused)
        await f.engine.sync()

        #expect(f.engine.status == .idle)
        #expect(await f.server.bodyweight[stored.id]?.wKg == 82)
        #expect(await f.server.bodyweight[refused.id] == nil)
        let failures = f.store.syncFailures()
        #expect(failures.map(\.id) == [refused.id.uuidString])
        #expect(failures.map(\.message) == [FakeTransport.bodyweightCapWords])
        #expect(failures.map(\.code) == ["too_many_body_weights"])
        #expect(try f.store.dirtyBodyweight().map(\.value.id) == [refused.id])
        #expect(try f.body.hasRecord(id: refused.id))

        let calls = await f.server.pushCalls
        await f.engine.sync()
        #expect(await f.server.pushCalls == calls)
    }
}
