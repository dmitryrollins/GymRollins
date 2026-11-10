import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// What the queue leaves behind or loses: photos in the public bucket, the chosen duplicate, a refused row.
@MainActor
@Suite struct ShareOutboxCleanupTests {
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

    private func newListing(_ gym: Gym, kind: String = "cable-stack", photo: String? = "mine.jpg") throws -> GymListing {
        try repo.addListing(NewListing(gymId: gym.id, kindId: kind, brand: "Hammer",
                                       loads: .stack(maxKg: 90, stepKg: 5), photoFile: photo))
    }

    private func record(_ id: UUID) throws -> GymListingRecord? { try repo.listingRecord(id) }

    private func remote(id: UUID = UUID(), photo: String? = nil) -> RemoteListing {
        RemoteListing(id: id, gymId: serverGymId, itemId: id, kindId: "cable-stack", brand: "Hammer", model: nil,
                      photoPath: photo, loads: .stack(maxKg: 90, stepKg: 5), quantity: 1, notes: "by the door",
                      status: "active", confirmCount: 2, isMine: false, confirmedByMe: false)
    }

    // MARK: A refused row doesn't stop the queue

    @Test func aRowTheServerRefusesForGoodIsSettledAndTheNextOneGoesOut() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = try newListing(gym), b = try newListing(gym, kind: "dumbbells", photo: nil)
        let box = outbox
        try box.enqueueShare(listingId: a.id, ownerId: user)
        f.clock.advance()
        try box.enqueueShare(listingId: b.id, ownerId: user)
        transport.shareScript = [.failure(.notAllowed)]
        await box.run(userId: user)
        let refused = try #require(try record(a.id))
        #expect(refused.uploadStateRaw == UploadState.failed.rawValue)
        #expect(refused.uploadError == "This one can't be shared from this account.")
        #expect(try record(b.id)?.uploadStateRaw == UploadState.uploaded.rawValue)
        #expect(box.pendingCount == 0)
    }

    @Test func eachRefusalShowsAReadableMessage() async throws {
        defer { f.tearDown() }
        let cases: [(GymCatalogError, String)] = [
            (.gymFull, "This gym's list is full."),
            (.photoRefused, "Couldn't upload this photo. Try again tomorrow, or delete this item."),
            (.photoInUse, "Couldn't upload this photo. Try again tomorrow, or delete this item."),
        ]
        let gym = try mapsGym()
        for (error, text) in cases {
            let listing = try newListing(gym, photo: nil)
            let box = outbox
            try box.enqueueShare(listingId: listing.id, ownerId: user)
            transport.shareScript = [.failure(error)]
            await box.run(userId: user)
            #expect(try record(listing.id)?.uploadError == text, "\(error)")
            f.clock.advance()
        }
    }

    @Test func aBusyServerKeepsEveryRowQueued() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let share = try newListing(gym, photo: nil)
        let other = try newListing(gym, kind: "dumbbells", photo: nil)
        let box = outbox
        try box.enqueueShare(listingId: share.id, ownerId: user)
        try box.enqueueConfirm(listingId: other.id, ownerId: user)
        transport.failure = .offline // what a 503 or a 429 is mapped to
        await box.run(userId: user)
        #expect(box.pendingCount == 2)
        #expect(try record(share.id)?.uploadStateRaw == UploadState.queued.rawValue)
        #expect(try record(other.id)?.confirmedByMe == true)
    }

    @Test func aConfirmationRefusedForGoodIsUndoneOnTheListing() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let cached = try newListing(gym, photo: nil)
        let row = try #require(try record(cached.id))
        row.visibilityRaw = GymVisibility.shared.rawValue
        row.uploadStateRaw = UploadState.uploaded.rawValue
        row.isOwn = false
        let box = outbox
        try box.enqueueConfirm(listingId: cached.id, ownerId: user)
        #expect(row.confirmedByMe)
        transport.failure = .notAllowed
        await box.run(userId: user)
        #expect(!row.confirmedByMe)
        #expect(box.pendingCount == 0)
    }

    // MARK: Photos in the public bucket

    @Test(arguments: [GymCatalogError.dailyLimit, .gymNotShareable, .notAllowed, .gymFull])
    func aShareRefusedForGoodDeletesItsUploadedPhotoAndAllowsAFreshUpload(_ error: GymCatalogError) async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        transport.shareScript = [.failure(error)]
        await box.run(userId: user)
        #expect(transport.deletedPhotos == transport.uploads)
        #expect(transport.uploads.count == 1)
        #expect(try record(listing.id)?.remotePhotoPath == nil)

        try box.retry(listingId: listing.id, ownerId: user)
        await box.run(userId: user)
        #expect(transport.uploads.count == 2, "a retry uploads again")
        #expect(transport.requests.last?.photoPath == transport.uploads[1])
    }

    @Test func aPhotoAListingAlreadyUsesIsNeverDeleted() async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        transport.shareScript = [.failure(.photoInUse)]
        await box.run(userId: user)
        #expect(transport.deletedPhotos.isEmpty)
        #expect(try record(listing.id)?.remotePhotoPath == nil, "but the retry takes a new name")
    }

    @Test func offlineKeepsThePhotoForTheRetry() async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        transport.shareScript = [.failure(.offline)]
        await box.run(userId: user)
        #expect(transport.deletedPhotos.isEmpty)
        #expect(try record(listing.id)?.remotePhotoPath != nil)
    }

    @Test func aFailedDeleteIsLoggedAndTheListingStillShowsWhyItStopped() async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        transport.shareScript = [.failure(.dailyLimit)]
        transport.failingCalls = ["deleteSharedPhoto"]
        await box.run(userId: user)
        let row = try #require(try record(listing.id))
        #expect(row.uploadStateRaw == UploadState.failed.rawValue)
        #expect(row.remotePhotoPath == nil)
        #expect(transport.deletedPhotos.isEmpty)
    }

    @Test func yesThatsItDeletesMyUploadedPhoto() async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        let existing = remote()
        transport.shareScript = [.success(.duplicates([existing]))]
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        await box.run(userId: user)
        let uploaded = try #require(transport.uploads.first)
        _ = try box.keepExisting(listingId: listing.id, existingId: existing.id, ownerId: user)
        await box.finishCleanups()
        #expect(transport.deletedPhotos == [uploaded])
    }

    @Test func cancellingAQueuedShareRemovesItAndReturnsThePhotoFile() async throws {
        defer { f.tearDown() }
        let listing = try newListing(try mapsGym())
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        transport.shareScript = [.failure(.offline)] // the photo went up, the share didn't
        await box.run(userId: user)
        let uploaded = try #require(transport.uploads.first)

        let file = try box.cancelShare(listingId: listing.id)
        #expect(file == "mine.jpg")
        #expect(box.pendingCount == 0)
        #expect(try record(listing.id) == nil)
        await box.finishCleanups()
        #expect(transport.deletedPhotos == [uploaded])
    }

    @Test func signingOutDeletesThePhotosOfQueuedShares() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let queued = try newListing(gym)
        let waiting = try newListing(gym, kind: "dumbbells", photo: nil)
        let theirs = try newListing(gym, kind: "kettlebell")
        let box = outbox
        try box.enqueueShare(listingId: queued.id, ownerId: user)
        try box.enqueueShare(listingId: waiting.id, ownerId: user)
        transport.shareScript = [.failure(.offline)]
        await box.run(userId: user)
        let uploaded = try #require(try record(queued.id)?.remotePhotoPath)
        try record(theirs.id)?.remotePhotoPath = "x.jpg"
        try box.enqueueShare(listingId: theirs.id, ownerId: UUID())

        await box.discardQueuedPhotos(userId: user)
        #expect(transport.deletedPhotos == [uploaded], "only this user's queued shares, and only ones that uploaded")
        #expect(try record(queued.id)?.remotePhotoPath == nil)
    }

    @Test func offlineAtSignOutLeavesTheObjectAndSaysNothingFails() async throws {
        defer { f.tearDown() }
        let queued = try newListing(try mapsGym())
        let box = outbox
        try box.enqueueShare(listingId: queued.id, ownerId: user)
        transport.shareScript = [.failure(.offline)]
        await box.run(userId: user)
        transport.failingCalls = ["deleteSharedPhoto"]
        await box.discardQueuedPhotos(userId: user)
        #expect(transport.deletedPhotos.isEmpty)
    }

    // MARK: The duplicate the user chose

    @Test func yesThatsItWithTheDuplicateNotCachedLeavesItAtTheGym() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let mine = try newListing(gym, photo: nil)
        let existing = remote(photo: "\(UUID().uuidString.lowercased()).jpg")
        let box = outbox
        transport.shareScript = [.success(.duplicates([existing]))]
        try box.enqueueShare(listingId: mine.id, ownerId: user)
        await box.run(userId: user)

        _ = try box.keepExisting(listingId: mine.id, existingId: existing.id, ownerId: user)
        let shown = try repo.listings(gymId: gym.id)
        #expect(shown.map(\.id) == [existing.id], "the gym keeps the equipment while the confirm waits")
        let row = try #require(try record(existing.id))
        #expect(row.visibilityRaw == GymVisibility.shared.rawValue)
        #expect(row.uploadStateRaw == UploadState.uploaded.rawValue)
        #expect(row.gymId == gym.id, "the phone's gym, not the server's")
        #expect(!row.isOwn && row.confirmedByMe && row.confirmCount == 2)
        #expect(row.remotePhotoPath == existing.photoPath)
        #expect(box.pendingCount == 1)
        #expect(try repo.inventory(gymId: gym.id).listings.count == 1)
    }

    @Test func yesThatsItWithTheDuplicateAlreadyCachedChangesNothingThere() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let mine = try newListing(gym, photo: "mine.jpg")
        let cached = try newListing(gym, kind: "dumbbells", photo: nil)
        let cachedRow = try #require(try record(cached.id))
        cachedRow.visibilityRaw = GymVisibility.shared.rawValue
        cachedRow.uploadStateRaw = UploadState.uploaded.rawValue
        cachedRow.confirmCount = 9
        let existing = remote(id: cached.id)
        let box = outbox
        transport.shareScript = [.success(.duplicates([existing]))]
        try box.enqueueShare(listingId: mine.id, ownerId: user)
        await box.run(userId: user)

        let file = try box.keepExisting(listingId: mine.id, existingId: existing.id, ownerId: user)
        #expect(file == "mine.jpg")
        #expect(cachedRow.confirmCount == 9, "the cached row is left as the refresh wrote it")
        #expect(try repo.listings(gymId: gym.id).map(\.id) == [cached.id])
    }
}

/// A server gym id the phone stored can go stale; and a confirmation still queued must survive a refresh.
@MainActor
@Suite struct StaleGymAndQueuedConfirmTests {
    let f: SyncFixture
    let transport = FakeGymCatalogTransport()
    let user = UUID()
    init() throws { f = try SyncFixture() }

    private var repo: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }
    private var now: () -> Date { { [clock = f.clock] in clock.now } }

    private func gymRecord(_ id: UUID) throws -> GymRecord {
        try #require(try repo.gymRecord(id))
    }

    @Test func aShareToAGymTheServerReplacedGoesToTheNewOne() async throws {
        defer { f.tearDown() }
        let old = UUID(), new = UUID()
        let gym = try repo.addMapsGym(placeId: "P1", name: "G", address: nil, latitude: 1, longitude: 2)
        try gymRecord(gym.id).remoteId = old
        let listing = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        transport.unshareableGyms = [old]
        transport.gym = RemoteGym(id: new, name: "G", address: nil, latitude: nil, longitude: nil, mapsPlaceId: "P1")
        let box = ShareOutbox(repository: repo, transport: transport, photoData: { _ in nil }, now: now)
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        await box.run(userId: user)
        #expect(transport.requests.map(\.gymId) == [old, new])
        #expect(try gymRecord(gym.id).remoteId == new)
        #expect(try repo.listingRecord(listing.id)?.uploadStateRaw == UploadState.uploaded.rawValue)
    }

    @Test func aGymReallyUnderReviewKeepsItsIdAndTheListingSaysSo() async throws {
        defer { f.tearDown() }
        let id = UUID()
        let gym = try repo.addMapsGym(placeId: "P1", name: "G", address: nil, latitude: 1, longitude: 2)
        try gymRecord(gym.id).remoteId = id
        let listing = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        transport.unshareableGyms = [id]
        transport.gym = RemoteGym(id: id, name: "G", address: nil, latitude: nil, longitude: nil, mapsPlaceId: "P1")
        let box = ShareOutbox(repository: repo, transport: transport, photoData: { _ in nil }, now: now)
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        await box.run(userId: user)
        #expect(transport.requests.count == 1)
        #expect(try gymRecord(gym.id).remoteId == id)
        #expect(try repo.listingRecord(listing.id)?.uploadError == ShareOutbox.gymUnderReview)
    }

    @Test func aGymTheServerHasNoMoreClearsTheStoredIdAndTheShareWaitsForALaterTry() async throws {
        defer { f.tearDown() }
        let id = UUID()
        let gym = try repo.addMapsGym(placeId: "P1", name: "G", address: nil, latitude: 1, longitude: 2)
        try gymRecord(gym.id).remoteId = id
        let listing = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        transport.unshareableGyms = [id]
        transport.gym = nil
        let box = ShareOutbox(repository: repo, transport: transport, photoData: { _ in nil }, now: now)
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        await box.run(userId: user)
        #expect(try gymRecord(gym.id).remoteId == nil)
        #expect(try repo.listingRecord(listing.id)?.uploadError == ShareOutbox.gymUnderReview)
        // Retrying asks the server for the place again, which finds or creates its gym.
        transport.unshareableGyms = []
        try box.retry(listingId: listing.id, ownerId: user)
        await box.run(userId: user)
        #expect(try repo.listingRecord(listing.id)?.uploadStateRaw == UploadState.uploaded.rawValue)
    }

    @Test func aRefreshKeepsMyQueuedConfirmationAndTappingAgainSetsItBack() async throws {
        defer { f.tearDown() }
        let serverGym = UUID()
        let gym = try repo.addMapsGym(placeId: "P1", name: "G", address: nil, latitude: 1, longitude: 2)
        try gymRecord(gym.id).remoteId = serverGym
        let theirs = RemoteListing(id: UUID(), gymId: serverGym, itemId: UUID(), kindId: "cable-stack", brand: nil,
                                   model: nil, photoPath: nil, loads: .none, quantity: 1, notes: nil,
                                   status: "active", confirmCount: 2, isMine: false, confirmedByMe: false)
        transport.listings = [theirs]
        let client = GymCatalogClient(repository: repo, transport: transport, knownKinds: ["cable-stack"], now: now)
        _ = try await client.refresh(gymId: gym.id, force: true)
        let box = ShareOutbox(repository: repo, transport: transport, photoData: { _ in nil }, now: now)
        try box.enqueueConfirm(listingId: theirs.id, ownerId: user)
        let row = try #require(try repo.listingRecord(theirs.id))
        #expect(row.confirmedByMe)

        _ = try await client.refresh(gymId: gym.id, force: true) // the server hasn't heard of it yet
        #expect(row.confirmedByMe, "a refresh must not undo a confirmation that is still queued")
        row.confirmedByMe = false
        try box.enqueueConfirm(listingId: theirs.id, ownerId: user)
        #expect(row.confirmedByMe)
        #expect(box.pendingCount == 1)
    }
}
