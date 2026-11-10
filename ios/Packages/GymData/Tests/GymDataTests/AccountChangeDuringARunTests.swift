import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// The session can end while a request is on the wire. Whatever comes back then belongs to a session that is gone and
/// must not touch the rows (plan 21, decision 7: one account's share is never finished under another).
@MainActor
@Suite struct AccountChangeDuringARunTests {
    let f: SyncFixture
    let transport = GatedGymCatalogTransport()
    let user = UUID()
    init() throws { f = try SyncFixture() }

    private var repo: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }
    private var now: () -> Date { { [clock = f.clock] in clock.now } }

    private func box() -> ShareOutbox {
        ShareOutbox(repository: repo, transport: transport, photoData: { _ in Data("jpeg".utf8) }, now: now)
    }

    private func mapsGym() throws -> Gym {
        transport.inner.gym = RemoteGym(id: UUID(), name: "Server", address: nil, latitude: nil, longitude: nil,
                                        mapsPlaceId: "P1")
        return try repo.addMapsGym(placeId: "P1", name: "Apple Name", address: nil, latitude: 1, longitude: 2)
    }

    private func record(_ id: UUID) throws -> GymListingRecord? {
        try f.context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func remote(mine: Bool) -> RemoteListing {
        RemoteListing(id: UUID(), gymId: UUID(), itemId: UUID(), kindId: "cable-stack", brand: nil, model: nil,
                      photoPath: nil, loads: .none, quantity: 1, notes: nil, status: "active", confirmCount: 0,
                      isMine: mine, confirmedByMe: false)
    }

    private func catalogClient() -> GymCatalogClient {
        GymCatalogClient(repository: repo, transport: transport, knownKinds: ["cable-stack"], now: now)
    }

    @Test func signingOutDuringTheFirstShareStopsTheRun() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        let b = try repo.addListing(NewListing(gymId: gym.id, kindId: "dumbbells"))
        let outbox = box()
        try outbox.enqueueShare(listingId: a.id, ownerId: user)
        f.clock.advance()
        try outbox.enqueueShare(listingId: b.id, ownerId: user)
        transport.hold("share")
        let run = Task { await outbox.run(userId: user) }
        await transport.waitUntilSuspended("share")

        outbox.invalidate()
        _ = try f.store.resetAccountData()
        transport.release()
        await run.value

        #expect(transport.inner.requests.map(\.listingId) == [a.id], "the second share is never sent")
        for id in [a.id, b.id] {
            let row = try #require(try record(id))
            #expect(row.visibilityRaw == GymVisibility.device.rawValue)
            #expect(row.uploadStateRaw == UploadState.local.rawValue)
            #expect(row.remoteId == nil)
        }
        #expect(outbox.pendingCount == 0)
    }

    @Test func aSharePhotoUploadFinishingAfterTheSessionEndedIsNotRecorded() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", photoFile: "a.jpg"))
        let outbox = box()
        try outbox.enqueueShare(listingId: a.id, ownerId: user)
        transport.hold("uploadSharedPhoto")
        let run = Task { await outbox.run(userId: user) }
        await transport.waitUntilSuspended("uploadSharedPhoto")
        outbox.invalidate()
        _ = try f.store.resetAccountData()
        transport.release()
        await run.value
        #expect(transport.inner.requests.isEmpty, "the share itself is never sent")
        #expect(try record(a.id)?.remotePhotoPath == nil)
    }

    @Test func aRefreshDuringSignOutBringsNothingBack() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        try f.context.fetch(FetchDescriptor<GymRecord>()).first?.remoteId = UUID()
        let mine = remote(mine: true)
        transport.inner.listings = [mine]
        let client = catalogClient()
        transport.hold("publicListings")
        let refresh = Task { try await client.refresh(gymId: gym.id, force: true) }
        await transport.waitUntilSuspended("publicListings")

        client.invalidate()
        _ = try f.store.resetAccountData()
        transport.release()
        _ = try await refresh.value

        #expect(try record(mine.id) == nil, "the old account's listing, with its isOwn flag, isn't cached back")
        #expect(try f.context.fetch(FetchDescriptor<GymRecord>()).first?.catalogRefreshedAt == nil)
    }

    @Test func aRefreshDuringEraseAllLeavesNoOrphanListing() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        try f.context.fetch(FetchDescriptor<GymRecord>()).first?.remoteId = UUID()
        transport.inner.listings = [remote(mine: false)]
        let client = catalogClient()
        transport.hold("publicListings")
        let refresh = Task { try await client.refresh(gymId: gym.id, force: true) }
        await transport.waitUntilSuspended("publicListings")

        client.invalidate()
        try f.store.resetAll()
        transport.release()
        _ = try await refresh.value

        #expect(try f.context.fetchCount(FetchDescriptor<GymRecord>()) == 0)
        #expect(try f.context.fetchCount(FetchDescriptor<GymListingRecord>()) == 0)
    }

    @Test func aSecondRunWhileOneIsGoingSendsNothingTwice() async throws {
        defer { f.tearDown() }
        let a = try repo.addListing(NewListing(gymId: try mapsGym().id, kindId: "cable-stack"))
        let outbox = box()
        try outbox.enqueueShare(listingId: a.id, ownerId: user)
        transport.hold("share")
        let first = Task { await outbox.run(userId: user) }
        await transport.waitUntilSuspended("share")
        await outbox.run(userId: user) // what the next trigger does: returns at once
        transport.release()
        await first.value
        #expect(transport.inner.requests.count == 1)
        #expect(outbox.pendingCount == 0)
    }
}
