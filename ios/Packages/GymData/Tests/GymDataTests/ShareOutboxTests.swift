import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

@MainActor
@Suite struct ShareOutboxTests {
    let f: SyncFixture
    let transport = FakeGymCatalogTransport()
    let serverGymId = UUID()
    let user = UUID()
    init() throws { f = try SyncFixture() }

    private var repo: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }
    private var outbox: ShareOutbox {
        ShareOutbox(repository: repo, transport: transport, photoData: { _ in Data("jpeg".utf8) },
                    now: { [clock = f.clock] in clock.now })
    }

    private func mapsGym() throws -> Gym {
        transport.gym = RemoteGym(id: serverGymId, name: "Server", address: nil, latitude: nil, longitude: nil,
                                  mapsPlaceId: "P1")
        return try repo.addMapsGym(placeId: "P1", name: "Apple Name", address: "1 Main", latitude: 1, longitude: 2)
    }

    private func newListing(_ gym: Gym, photo: String? = "mine.jpg") throws -> GymListing {
        try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", brand: "Hammer",
                                       loads: .stack(maxKg: 90, stepKg: 5), photoFile: photo))
    }

    private func record(_ id: UUID) throws -> GymListingRecord {
        try #require(try repo.listingRecord(id))
    }

    private func duplicate() -> RemoteListing {
        RemoteListing(id: UUID(), gymId: serverGymId, itemId: UUID(), kindId: "cable-stack", brand: "Hammer",
                      model: nil, photoPath: nil, loads: .stack(maxKg: 90, stepKg: 5), quantity: 1, notes: nil,
                      status: "active", confirmCount: 2, isMine: false, confirmedByMe: false)
    }

    @Test func sharingCreatesTheGymThenUploadsThePhotoThenCallsTheFunction() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let listing = try newListing(gym)
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        #expect(try record(listing.id).uploadStateRaw == UploadState.queued.rawValue)
        await box.run(userId: user)
        #expect(transport.calls == ["findOrCreateGym", "uploadSharedPhoto", "share"])
        let name = try #require(transport.uploads.first)
        let stem = try #require(name.split(separator: ".").first.map(String.init))
        #expect(name.hasSuffix(".jpg"))
        #expect(UUID(uuidString: stem) != nil)
        #expect(stem == stem.lowercased())
        #expect(!name.contains("/"))
        #expect(!name.contains(user.uuidString.lowercased()))
        let row = try record(listing.id)
        #expect(row.visibilityRaw == GymVisibility.shared.rawValue)
        #expect(row.uploadStateRaw == UploadState.uploaded.rawValue)
        #expect(row.remotePhotoPath == name)
        #expect(row.remoteId == listing.id)
        let request = try #require(transport.requests.first)
        #expect(request.photoPath == name)
        #expect(request.gymId == serverGymId)
        #expect(request.brand == "Hammer")
        #expect(request.forceNew == false)
        #expect(try #require(try repo.gym(gym.id)).remoteId == serverGymId)
        #expect(box.pendingCount == 0)
    }

    @Test func aRetryAfterALostResponseDoesNotShareTwice() async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        transport.loseNextShareResponse = true // the server stores the row, the answer never arrives
        await box.run(userId: user)
        #expect(box.pendingCount == 1)
        #expect(transport.serverShares.count == 1, "the first try did reach the server")
        #expect(try record(listing.id).remotePhotoPath != nil)
        await box.run(userId: user)
        #expect(transport.serverShares.count == 1, "the retry finds the same row by its id")
        #expect(transport.uploads.count == 1)
        #expect(transport.requests.count == 2)
        #expect(transport.requests[0].photoPath == transport.requests[1].photoPath)
        #expect(transport.requests[0].listingId == transport.requests[1].listingId)
        #expect(box.pendingCount == 0)
        #expect(try record(listing.id).uploadStateRaw == UploadState.uploaded.rawValue)
    }

    @Test func aMissingPhotoOnTheServerIsUploadedAgainInTheSameRun() async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        transport.shareScript = [.failure(.photoMissing)]
        await box.run(userId: user)
        #expect(transport.uploads.count == 2)
        #expect(transport.uploads[0] != transport.uploads[1])
        #expect(try record(listing.id).remotePhotoPath == transport.uploads[1])
        #expect(try record(listing.id).uploadStateRaw == UploadState.uploaded.rawValue)
        #expect(box.pendingCount == 0)
    }

    @Test func aPhotoTheServerKeepsLosingIsTriedTwiceAndThenLeftForTheNextRun() async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        transport.shareScript = Array(repeating: .failure(.photoMissing), count: 4)
        await box.run(userId: user)
        #expect(transport.requests.count == 2, "it must not spin on a row it can't send")
        #expect(box.pendingCount == 1)
        #expect(try record(listing.id).uploadStateRaw == UploadState.queued.rawValue)
        await box.run(userId: user)
        #expect(box.pendingCount == 1, "the next run tries again, twice")
        #expect(transport.requests.count == 4)
    }

    @Test func aShareQueuedWhileARunIsGoingIsSentByThatRun() async throws {
        defer { f.tearDown() }
        let gated = GatedGymCatalogTransport()
        gated.inner.gym = RemoteGym(id: serverGymId, name: "S", address: nil, latitude: nil, longitude: nil,
                                    mapsPlaceId: "P1")
        let gym = try repo.addMapsGym(placeId: "P1", name: "G", address: nil, latitude: 1, longitude: 2)
        let first = try newListing(gym), second = try repo.addListing(NewListing(gymId: gym.id, kindId: "dumbbells"))
        let box = ShareOutbox(repository: repo, transport: gated, photoData: { _ in Data("j".utf8) },
                              now: { [clock = f.clock] in clock.now })
        try box.enqueueShare(listingId: first.id, ownerId: user)
        gated.hold("share")
        let run = Task { await box.run(userId: user) }
        await gated.waitUntilSuspended("share")
        f.clock.advance()
        try box.enqueueShare(listingId: second.id, ownerId: user)
        gated.release()
        await run.value
        #expect(gated.inner.requests.map(\.listingId) == [first.id, second.id])
        #expect(box.pendingCount == 0)
    }

    @Test func aGymUnderReviewShowsAMessage() async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        transport.shareScript = [.failure(.gymNotShareable)]
        await box.run(userId: user)
        let row = try record(listing.id)
        #expect(row.visibilityRaw == GymVisibility.device.rawValue)
        #expect(row.uploadStateRaw == UploadState.failed.rawValue)
        #expect(row.uploadError == "This gym is under review. Try again later.")
        #expect(box.pendingCount == 0)
    }

    @Test func offlineKeepsTheItemQueued() async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        transport.failure = .offline
        await box.run(userId: user)
        let row = try record(listing.id)
        #expect(row.uploadStateRaw == UploadState.queued.rawValue)
        #expect(row.uploadError == nil)
        #expect(box.pendingCount == 1)
    }

    @Test func offlineStopsTheWholeRun() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let first = try newListing(gym), second = try newListing(gym, photo: nil)
        let box = outbox
        try box.enqueueShare(listingId: first.id, ownerId: user)
        f.clock.advance(1)
        try box.enqueueShare(listingId: second.id, ownerId: user)
        transport.shareScript = [.failure(.offline)]
        await box.run(userId: user)
        #expect(transport.requests.count == 1)
        #expect(box.pendingCount == 2)
    }

    @Test func dailyLimitLeavesItLocalWithTheMessage() async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        transport.shareScript = [.failure(.dailyLimit)]
        await box.run(userId: user)
        let row = try record(listing.id)
        #expect(row.visibilityRaw == GymVisibility.device.rawValue)
        #expect(row.uploadStateRaw == UploadState.failed.rawValue)
        #expect(row.uploadError == "You've shared a lot today. Try again tomorrow.")
        #expect(box.pendingCount == 0)
    }

    @Test func duplicatesWaitForTheUsersChoice() async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        let other = duplicate()
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        transport.shareScript = [.success(.duplicates([other]))]
        await box.run(userId: user)
        let row = try record(listing.id)
        #expect(row.uploadStateRaw == UploadState.waitingForChoice.rawValue)
        #expect(try box.duplicates(listingId: listing.id) == [other])
        #expect(box.pendingCount == 0)
    }

    @Test func keepingTheExistingOneConfirmsItAndRemovesMine() async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        let other = duplicate()
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        transport.shareScript = [.success(.duplicates([other]))]
        await box.run(userId: user)
        let file = try box.keepExisting(listingId: listing.id, existingId: other.id, ownerId: user)
        #expect(file == "mine.jpg")
        #expect(try repo.listingRecord(listing.id) == nil)
        #expect(box.pendingCount == 1)
        await box.run(userId: user)
        #expect(transport.confirmed == [other.id])
        #expect(box.pendingCount == 0)
    }

    @Test func sharingAnywaySendsForceNew() async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        transport.shareScript = [.success(.duplicates([duplicate()]))]
        await box.run(userId: user)
        try box.enqueueShare(listingId: listing.id, ownerId: user, forceNew: true)
        await box.run(userId: user)
        #expect(transport.requests.map(\.forceNew) == [false, true])
        #expect(try record(listing.id).uploadStateRaw == UploadState.uploaded.rawValue)
    }

    @Test func aRowOfAnotherUserIsLeftAlone() async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        await box.run(userId: UUID())
        await box.run(userId: nil)
        #expect(transport.calls.isEmpty)
        #expect(box.pendingCount == 1)
        await box.run(userId: user)
        #expect(box.pendingCount == 0)
    }

    @Test func confirmIsIdempotentAndUpdatesTheCount() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let cached = try newListing(gym, photo: nil)
        let row = try record(cached.id)
        row.visibilityRaw = GymVisibility.shared.rawValue
        row.uploadStateRaw = UploadState.uploaded.rawValue
        row.isOwn = false
        row.confirmCount = 3
        let box = outbox
        transport.setConfirmCount(3, for: cached.id) // the fake counts like the server: once per listing
        try box.enqueueConfirm(listingId: cached.id, ownerId: user)
        try box.enqueueConfirm(listingId: cached.id, ownerId: user)
        #expect(box.pendingCount == 1)
        await box.run(userId: user)
        #expect(row.confirmCount == 4)
        #expect(row.confirmedByMe)
        try box.enqueueConfirm(listingId: cached.id, ownerId: user)
        await box.run(userId: user)
        #expect(row.confirmCount == 4, "confirming again adds nothing")
        #expect(transport.confirmed == [cached.id, cached.id])
    }

    @Test func retryRequeuesAFailedItem() async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        transport.shareScript = [.failure(.dailyLimit)]
        await box.run(userId: user)
        try box.retry(listingId: listing.id, ownerId: user)
        let row = try record(listing.id)
        #expect(row.uploadStateRaw == UploadState.queued.rawValue)
        #expect(row.uploadError == nil)
        #expect(box.pendingCount == 1)
        await box.run(userId: user)
        #expect(try record(listing.id).uploadStateRaw == UploadState.uploaded.rawValue)
    }

    @Test func aPrivateGymCanNeverBeShared() throws {
        defer { f.tearDown() }
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        let listing = try newListing(gym)
        let box = outbox
        #expect(throws: GymDataError.self) { try box.enqueueShare(listingId: listing.id, ownerId: user) }
        #expect(box.pendingCount == 0)
        let row = try record(listing.id)
        #expect(row.visibilityRaw == GymVisibility.device.rawValue)
        #expect(row.uploadStateRaw == UploadState.local.rawValue)
    }

    @Test func resetAllRemovesTheQueue() throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        try box.enqueueConfirm(listingId: UUID(), ownerId: user)
        #expect(box.pendingCount == 2)
        try f.store.resetAll()
        #expect(box.pendingCount == 0)
    }
}
