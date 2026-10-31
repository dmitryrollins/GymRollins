import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Reports and blocks through the queue: hiding is immediate on the phone, the server hears about it when it can.
@MainActor
@Suite struct ShareOutboxReportsTests {
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
    private var client: GymCatalogClient {
        GymCatalogClient(repository: repo, transport: transport, knownKinds: ["cable-stack", "kettlebell"],
                         now: { [clock = f.clock] in clock.now })
    }

    private func mapsGym() throws -> Gym {
        transport.gym = RemoteGym(id: serverGymId, name: "Server", address: nil, latitude: nil, longitude: nil,
                                  mapsPlaceId: "P1")
        let gym = try repo.addMapsGym(placeId: "P1", name: "Apple Name", address: "1 Main", latitude: 1, longitude: 2)
        try #require(try repo.gymRecord(gym.id)).remoteId = serverGymId
        return gym
    }

    private func remote(_ id: UUID = UUID(), mine: Bool = false) -> RemoteListing {
        RemoteListing(id: id, gymId: serverGymId, itemId: UUID(), kindId: "cable-stack", brand: nil, model: nil,
                      photoPath: nil, loads: .stack(maxKg: 90, stepKg: 5), quantity: 1, notes: nil, status: "active",
                      confirmCount: 1, isMine: mine, confirmedByMe: false)
    }

    /// Fills the cache the way a refresh does.
    private func cache(_ gym: Gym, _ listings: [RemoteListing]) async throws {
        transport.listings = listings
        _ = try await client.refresh(gymId: gym.id, force: true)
    }

    private func shown(_ gym: Gym) throws -> Set<UUID> {
        Set(try repo.listings(gymId: gym.id, includingUnsupported: true).map(\.id))
    }

    @Test func reportingQueuesAndHidesTheListingAtOnce() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = remote(), b = remote()
        try await cache(gym, [a, b])
        let box = outbox
        try box.enqueueReport(listingId: a.id, reason: .spam, note: "ads", ownerId: user)
        #expect(try shown(gym) == [b.id])
        #expect(try repo.inventory(gymId: gym.id).listings.map(\.id) == [b.id])
        #expect(try repo.listing(a.id) == nil)
        #expect(box.pendingCount == 1)
        #expect(!transport.calls.contains("report"), "nothing is sent before the run")
        await box.run(userId: user)
        #expect(transport.reports == [.init(type: .listing, id: a.id, reason: .spam, note: "ads")])
        #expect(box.pendingCount == 0)
        #expect(try shown(gym) == [b.id])
    }

    @Test func aReportSurvivesOfflineAndIsSentLater() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = remote()
        try await cache(gym, [a])
        let box = outbox
        try box.enqueueReport(listingId: a.id, reason: .wrongInfo, note: nil, ownerId: user)
        transport.failingCalls = ["report"]
        await box.run(userId: user)
        #expect(box.pendingCount == 1)
        #expect(try shown(gym).isEmpty, "still hidden while it waits")
        transport.failingCalls = []
        await box.run(userId: user)
        #expect(transport.reports.count == 1, "the offline try never reached the server")
        #expect(box.pendingCount == 0)
        #expect(try shown(gym).isEmpty)
    }

    @Test func reportingTwiceQueuesItOnce() throws {
        defer { f.tearDown() }
        let box = outbox
        let id = UUID()
        _ = try cachedSync(id)
        try box.enqueueReport(listingId: id, reason: .spam, note: nil, ownerId: user)
        try box.enqueueReport(listingId: id, reason: .spam, note: nil, ownerId: user)
        #expect(box.pendingCount == 1)
    }

    /// A shared row without a refresh, for tests of the queue alone.
    private func cachedSync(_ id: UUID) throws -> Gym {
        let gym = try mapsGym()
        let item = try repo.itemRecord(kindId: "cable-stack", brand: nil, model: nil)
        let row = RemoteListingCache(context: f.context, now: { [clock = f.clock] in clock.now })
            .insert(remote(id), itemId: item.id, gymId: gym.id)
        try f.context.save()
        _ = row
        return gym
    }

    @Test func blockingHidesThisListingAtOnceAndTheNextRefreshDropsTheRest() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = remote(), sameAuthor = remote(), other = remote()
        try await cache(gym, [a, sameAuthor, other])
        let box = outbox
        try box.enqueueBlock(listingId: a.id, ownerId: user)
        #expect(try shown(gym) == [sameAuthor.id, other.id], "the phone doesn't know the author")
        await box.run(userId: user)
        #expect(transport.blocks == [.init(type: .listing, id: a.id)])
        // The server now leaves out everything the blocked author wrote.
        try await cache(gym, [other])
        #expect(try shown(gym) == [other.id])
        #expect(try repo.listingRecord(sameAuthor.id) == nil, "the refresh deletes rows the server no longer returns")
    }

    @Test func aRefreshDoesNotBringBackAReportedListingWhileItsReportIsQueued() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = remote(), b = remote()
        try await cache(gym, [a, b])
        let box = outbox
        transport.failingCalls = ["report"]
        try box.enqueueReport(listingId: a.id, reason: .duplicate, note: nil, ownerId: user)
        await box.run(userId: user)
        try await cache(gym, [a, b])
        #expect(try shown(gym) == [b.id], "a row the server still returns stays hidden")
        try await cache(gym, [b])
        try await cache(gym, [a, b])
        #expect(try shown(gym) == [b.id], "a row that came back is hidden again while its report waits")
        #expect(try repo.inventory(gymId: gym.id).listings.map(\.id) == [b.id])
    }

    @Test func aReportedListingStaysHiddenAfterTheReportIsSent() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = remote(), b = remote()
        try await cache(gym, [a, b])
        let box = outbox
        try box.enqueueReport(listingId: a.id, reason: .spam, note: nil, ownerId: user)
        await box.run(userId: user)
        #expect(box.pendingCount == 0)
        try await cache(gym, [a, b]) // the first or second reporter: the server still returns it
        #expect(try shown(gym) == [b.id])
    }

    @Test func theDailyLimitOnReportsShowsTheMessageAndDropsTheRow() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = remote()
        try await cache(gym, [a])
        let box = outbox
        transport.reportScript = [.dailyLimit]
        try box.enqueueReport(listingId: a.id, reason: .spam, note: nil, ownerId: user)
        await box.run(userId: user)
        #expect(box.pendingCount == 0)
        #expect(box.reportNotice == ShareOutbox.reportDailyLimit)
        #expect(ShareOutbox.reportDailyLimit == "You've sent a lot of reports today. Try again tomorrow.")
        #expect(try shown(gym) == [a.id], "a report the server refused doesn't hide the listing")
    }

    @Test func unblockAllForcesARefresh() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        try await cache(gym, [remote()])
        #expect(try #require(try repo.gymRecord(gym.id)).catalogRefreshedAt != nil)
        transport.unblockResult = 2
        let count = try await outbox.unblockAll()
        #expect(count == 2)
        #expect(try #require(try repo.gymRecord(gym.id)).catalogRefreshedAt == nil)
        let before = transport.calls.filter { $0 == "publicListings" }.count
        _ = try await client.refresh(gymId: gym.id, force: false)
        #expect(transport.calls.filter { $0 == "publicListings" }.count == before + 1)
    }

    @Test func aDeviceListingCannotBeReported() throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let mine = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        let box = outbox
        #expect(throws: GymDataError.self) {
            try box.enqueueReport(listingId: mine.id, reason: .spam, note: nil, ownerId: user)
        }
        #expect(throws: GymDataError.self) { try box.enqueueBlock(listingId: mine.id, ownerId: user) }
        #expect(box.pendingCount == 0)
    }

    @Test func reportingYourOwnListingIsNotOffered() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let mine = remote(mine: true)
        try await cache(gym, [mine])
        let box = outbox
        // The server answers `own`, which is done: nothing is hidden on the phone.
        try box.enqueueReport(listingId: mine.id, reason: .spam, note: nil, ownerId: user)
        #expect(try shown(gym) == [mine.id])
        await box.run(userId: user)
        #expect(box.pendingCount == 0)
        #expect(try shown(gym) == [mine.id])
    }

    @Test func aGymReportHidesNothingLocally() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let box = outbox
        try box.enqueueGymReport(gymId: gym.id, reason: .notHereAnymore, note: nil, ownerId: user)
        #expect(try repo.gyms().map(\.id) == [gym.id])
        await box.run(userId: user)
        #expect(transport.reports == [.init(type: .gym, id: serverGymId, reason: .notHereAnymore, note: nil)])
        #expect(try repo.gyms().map(\.id) == [gym.id])
    }

    @Test func aGymTheServerDoesNotKnowCannotBeReported() throws {
        defer { f.tearDown() }
        let gym = try repo.addMapsGym(placeId: "P2", name: "New", address: nil, latitude: 1, longitude: 2)
        let priv = try repo.addPrivateGym(name: "Home", address: nil)
        let box = outbox
        for id in [gym.id, priv.id] {
            #expect(throws: GymDataError.self) {
                try box.enqueueGymReport(gymId: id, reason: .spam, note: nil, ownerId: user)
            }
        }
        #expect(box.pendingCount == 0)
    }

    @Test func reportingABorrowedPhotoReportsItsSourceAndKeepsTheListing() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let source = UUID()
        let mine = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", brand: "Hammer"))
        let item = try #require(try f.context.fetch(FetchDescriptor<EquipmentItemRecord>()).first {
            $0.id == mine.item.id
        })
        item.catalogPhotoPath = "\(UUID()).jpg"
        item.catalogPhotoListingId = source
        try f.context.save()
        let box = outbox
        try box.enqueueCataloguePhotoReport(listingId: mine.id, reason: .inappropriatePhoto, note: nil, ownerId: user)
        #expect(item.catalogPhotoPath == nil && item.catalogPhotoListingId == nil)
        #expect(try shown(gym) == [mine.id], "the listing stays")
        await box.run(userId: user)
        #expect(transport.reports == [.init(type: .listing, id: source, reason: .inappropriatePhoto, note: nil)])
        #expect(try shown(gym) == [mine.id])
        #expect(throws: GymDataError.self) {
            try box.enqueueCataloguePhotoReport(listingId: mine.id, reason: .spam, note: nil, ownerId: user)
        }
    }

    @Test func aRefreshKeepsTheBorrowedPhotoOffWhileItsReportIsQueued() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let source = UUID()
        let mine = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        let item = try #require(try f.context.fetch(FetchDescriptor<EquipmentItemRecord>()).first {
            $0.id == mine.item.id
        })
        item.catalogPhotoPath = "\(UUID()).jpg"
        item.catalogPhotoListingId = source
        try f.context.save()
        let box = outbox
        transport.failingCalls = ["report"]
        try box.enqueueCataloguePhotoReport(listingId: mine.id, reason: .personInPhoto, note: nil, ownerId: user)
        await box.run(userId: user)
        transport.items = [RemoteItem(id: item.id, kindId: "cable-stack", brand: nil, model: nil, gymCount: 2,
                                      photoPath: "\(UUID()).jpg", photoListingId: source)]
        try await cache(gym, [remote()])
        #expect(item.catalogPhotoPath == nil, "the photo stays off until the report is sent")
    }

    @Test func aRejectedNoteIsSentAgainWithoutIt() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = remote()
        try await cache(gym, [a])
        let box = outbox
        transport.reportScript = [.noteRefused]
        try box.enqueueReport(listingId: a.id, reason: .other, note: "bad\u{200B}note", ownerId: user)
        await box.run(userId: user)
        #expect(transport.reports.map(\.note) == ["bad\u{200B}note", nil])
        #expect(box.pendingCount == 0)
        #expect(try shown(gym).isEmpty)
    }

    @Test func aListingTheServerNoLongerKnowsIsDoneAndStaysHidden() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = remote()
        try await cache(gym, [a])
        let box = outbox
        transport.reportScript = [.unknownTarget]
        try box.enqueueReport(listingId: a.id, reason: .spam, note: nil, ownerId: user)
        await box.run(userId: user)
        #expect(box.pendingCount == 0)
        #expect(box.reportNotice == nil)
        #expect(try shown(gym).isEmpty)
    }

    @Test func aRefusedReportOtherThanTheLimitSaysSoAndShowsTheListingAgain() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = remote()
        try await cache(gym, [a])
        let box = outbox
        transport.reportScript = [.rejected("nope")]
        try box.enqueueReport(listingId: a.id, reason: .spam, note: nil, ownerId: user)
        await box.run(userId: user)
        #expect(box.pendingCount == 0)
        #expect(box.reportNotice == ShareOutbox.couldNotReport)
        #expect(try shown(gym) == [a.id])
    }

    @Test func aRowOfAnotherUserWaits() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = remote()
        try await cache(gym, [a])
        let box = outbox
        try box.enqueueReport(listingId: a.id, reason: .spam, note: nil, ownerId: user)
        await box.run(userId: UUID())
        #expect(!transport.calls.contains("report"))
        #expect(box.pendingCount == 1)
    }

    @Test func anAnswerAfterTheSessionChangedTouchesNothing() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let a = remote()
        try await cache(gym, [a])
        let gated = GatedGymCatalogTransport()
        let box = ShareOutbox(repository: repo, transport: gated, photoData: { _ in nil },
                              now: { [clock = f.clock] in clock.now })
        gated.inner.reportScript = [.dailyLimit]
        gated.hold("report")
        try box.enqueueReport(listingId: a.id, reason: .spam, note: nil, ownerId: user)
        let run = Task { await box.run(userId: user) }
        await gated.waitUntilSuspended("report")
        box.invalidate()
        gated.release()
        await run.value
        #expect(box.pendingCount == 1, "the row is untouched")
        #expect(box.reportNotice == nil)
        #expect(try shown(gym).isEmpty, "and still hidden")
    }
}
