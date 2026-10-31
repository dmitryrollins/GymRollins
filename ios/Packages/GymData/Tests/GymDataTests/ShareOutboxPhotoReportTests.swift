import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Reporting the picture a listing borrows from another gym's listing.
@MainActor
@Suite struct ShareOutboxPhotoReportTests: ReportsTestRig {
    let f: SyncFixture
    let transport = FakeGymCatalogTransport()
    let serverGymId = UUID()
    let user = UUID()
    init() throws { f = try SyncFixture() }

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

    @Test func aReportedPhotoStaysOffAfterItsReportIsSent() async throws {
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
        try box.enqueueCataloguePhotoReport(listingId: mine.id, reason: .personInPhoto, note: nil, ownerId: user)
        await box.run(userId: user)
        transport.items = [RemoteItem(id: item.id, kindId: "cable-stack", brand: nil, model: nil, gymCount: 2,
                                      photoPath: "\(UUID()).jpg", photoListingId: source)]
        try await cache(gym, [remote()])
        #expect(item.catalogPhotoPath == nil, "the user who reported a picture isn't shown it again")

        let another = "\(UUID()).jpg"
        transport.items = [RemoteItem(id: item.id, kindId: "cable-stack", brand: nil, model: nil, gymCount: 2,
                                      photoPath: another, photoListingId: UUID())]
        try await cache(gym, [remote()])
        #expect(item.catalogPhotoPath == another, "another listing's picture of the item is fine")
    }

    @Test func aRefusedPhotoReportLetsThePictureBack() async throws {
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
        transport.failure = .notAllowed
        try box.enqueueCataloguePhotoReport(listingId: mine.id, reason: .personInPhoto, note: nil, ownerId: user)
        await box.run(userId: user)
        transport.failure = nil
        let path = "\(UUID()).jpg"
        transport.items = [RemoteItem(id: item.id, kindId: "cable-stack", brand: nil, model: nil, gymCount: 2,
                                      photoPath: path, photoListingId: source)]
        try await cache(gym, [remote()])
        #expect(item.catalogPhotoPath == path, "the report didn't go, so nothing stands against the picture")
    }

    @Test func upsertItemDoesNotBringTheReportedPictureBack() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let source = UUID()
        let (mine, item) = try borrowed(gym, source: source)
        let box = outbox
        try box.enqueueCataloguePhotoReport(listingId: mine.id, reason: .personInPhoto, note: nil, ownerId: user)
        await box.run(userId: user)
        _ = try client.upsertItem(RemoteItem(id: item.id, kindId: item.kindId, brand: nil, model: nil, gymCount: 1,
                                             photoPath: "\(UUID()).jpg", photoListingId: source))
        #expect(item.catalogPhotoPath == nil && item.catalogPhotoListingId == nil)
        let other = "\(UUID()).jpg"
        _ = try client.upsertItem(RemoteItem(id: item.id, kindId: item.kindId, brand: nil, model: nil, gymCount: 1,
                                             photoPath: other, photoListingId: UUID()))
        #expect(item.catalogPhotoPath == other, "another listing's picture is fine")
    }

    /// A source listing this phone has cached, with its picture already downloaded.
    private func cachedSource(_ gym: Gym, _ source: UUID) async throws -> GymListingRecord {
        try await cache(gym, [remote(source, photo: "\(UUID()).jpg")])
        let row = try #require(try repo.listingRecord(source))
        row.photoFile = "source.jpg"
        try f.context.save()
        return row
    }

    @Test func theSourceListingOnThisPhoneLosesItsPictureAndKeepsItsTile() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let source = UUID()
        let row = try await cachedSource(gym, source)
        let (mine, _) = try borrowed(gym, source: source)
        let files = try outbox.enqueueCataloguePhotoReport(listingId: mine.id, reason: .personInPhoto, note: nil,
                                                           ownerId: user)
        #expect(files == ["source.jpg"], "the caller deletes the file")
        #expect(row.photoFile == nil && row.photoHiddenLocally)
        #expect(try shown(gym).contains(source), "the tile stays")
        #expect(try client.missingPhotos(gymId: gym.id).isEmpty, "and its picture is not downloaded again")
    }

    @Test func aSourceRowThatArrivesLaterIsBornWithoutItsPicture() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let source = UUID()
        _ = try await cachedSource(gym, source)
        let (mine, _) = try borrowed(gym, source: source)
        let box = outbox
        transport.failingCalls = ["report"]
        try box.enqueueCataloguePhotoReport(listingId: mine.id, reason: .personInPhoto, note: nil, ownerId: user)
        await box.run(userId: user)
        try await cache(gym, []) // the row leaves the cache...
        let refreshed = try await client.refresh(gymId: gym.id, force: true)
        _ = refreshed
        try await cache(gym, [remote(source, photo: "\(UUID()).jpg")]) // ...and comes back from a refresh
        #expect(try #require(try repo.listingRecord(source)).photoHiddenLocally)
        #expect(try client.missingPhotos(gymId: gym.id).isEmpty)
        // After the report went, the reported item still names the source.
        transport.failingCalls = []
        await box.run(userId: user)
        try await cache(gym, [])
        try await cache(gym, [remote(source, photo: "\(UUID()).jpg")])
        #expect(try #require(try repo.listingRecord(source)).photoHiddenLocally)
        #expect(try client.missingPhotos(gymId: gym.id).isEmpty)
    }

    @Test func aRefusedPhotoReportLetsTheSourcePictureBack() async throws {
        defer { f.tearDown() }
        let gym = try mapsGym()
        let source = UUID()
        _ = try await cachedSource(gym, source)
        let (mine, _) = try borrowed(gym, source: source)
        let box = outbox
        transport.failure = .notAllowed
        try box.enqueueCataloguePhotoReport(listingId: mine.id, reason: .personInPhoto, note: nil, ownerId: user)
        await box.run(userId: user)
        transport.failure = nil
        #expect(try #require(try repo.listingRecord(source)).photoHiddenLocally == false)
        try await cache(gym, [remote(source, photo: "\(UUID()).jpg")])
        #expect(try client.missingPhotos(gymId: gym.id).map(\.listingId) == [source])
    }
}
