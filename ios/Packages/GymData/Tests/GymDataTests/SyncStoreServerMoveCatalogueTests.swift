import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// The server move and the shared catalogue's cache (plan 28): the old server's gym ids, cached listings, borrowed
/// pictures and outbox go; the user's own listings stay on the phone, as "This phone only".
@MainActor
@Suite struct SyncStoreServerMoveCatalogueTests {
    let f: SyncFixture
    let transport = FakeGymCatalogTransport()
    init() throws { f = try SyncFixture() }

    private let new = "http://127.0.0.1:8787"
    private var repo: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }

    private func listing(_ id: UUID) throws -> GymListingRecord? {
        try f.context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func gymRecord(_ id: UUID) throws -> GymRecord {
        try #require(try f.context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.id == id })).first)
    }

    private func item(_ id: UUID) throws -> EquipmentItemRecord {
        let items = try f.context.fetch(FetchDescriptor<EquipmentItemRecord>(predicate: #Predicate { $0.id == id }))
        return try #require(items.first)
    }

    private struct OldCatalogue {
        let gym: UUID, own: UUID, waiting: UUID, theirs: UUID, item: UUID
    }

    /// What a phone that used the old server's catalogue holds: a maps gym with the old id, the user's own shared
    /// listing, one still waiting to be shared, someone else's cached listing, an item's borrowed picture, and an
    /// outbox row.
    private func oldCatalogue() throws -> OldCatalogue {
        let gym = try repo.addMapsGym(placeId: "P1", name: "Iron Works", address: nil, latitude: 1, longitude: 2)
        let gymRow = try gymRecord(gym.id)
        gymRow.remoteId = UUID()
        gymRow.catalogRefreshedAt = f.clock.now
        let own = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", photoFile: "mine.jpg"))
        let waiting = try repo.addListing(NewListing(gymId: gym.id, kindId: "kettlebell"))
        let theirs = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", photoFile: "theirs.jpg"))
        let states: [(UUID, UploadState, Bool)] = [(own.id, .uploaded, true), (waiting.id, .queued, true),
                                                   (theirs.id, .uploaded, false)]
        for (id, state, isOwn) in states {
            let row = try #require(try listing(id))
            row.visibilityRaw = GymVisibility.shared.rawValue
            row.uploadStateRaw = state.rawValue
            row.isOwn = isOwn
            row.remoteId = state == .uploaded ? id : nil
            row.remotePhotoPath = "\(UUID().uuidString.lowercased()).jpg"
            row.confirmCount = 3
        }
        let itemId = try #require(try listing(theirs.id)).itemId
        let itemRow = try item(itemId)
        itemRow.catalogPhotoPath = "\(UUID().uuidString.lowercased()).jpg"
        itemRow.catalogPhotoListingId = theirs.id
        f.context.insert(ShareOutboxRecord(kind: .share, targetId: waiting.id, ownerId: UUID(), now: f.clock.now))
        try f.context.save()
        f.store.ownerUserId = UUID()
        f.store.syncedServer = "http://127.0.0.1:55421"
        return OldCatalogue(gym: gym.id, own: own.id, waiting: waiting.id, theirs: theirs.id, item: itemId)
    }

    @Test func theUsersOwnSharedListingsStayOnThePhoneAndTheOldCatalogueIsForgotten() throws {
        defer { f.tearDown() }
        let old = try oldCatalogue()

        #expect(try f.store.moveToServer(new))

        for id in [old.own, old.waiting] {
            let row = try #require(try listing(id))
            #expect(row.visibilityRaw == GymVisibility.device.rawValue)
            #expect(row.uploadStateRaw == UploadState.local.rawValue)
            #expect(row.remoteId == nil && row.remotePhotoPath == nil && row.confirmCount == 0)
        }
        #expect(try listing(old.own)?.photoFile == "mine.jpg", "the picture stays on the phone")
        #expect(try listing(old.theirs)?.visibilityRaw == GymVisibility.shared.rawValue,
                "someone else's listing waits for the next refresh, which drops it with its picture")
        let gym = try gymRecord(old.gym)
        #expect(gym.remoteId != nil && gym.catalogRefreshedAt == nil)
        let borrowed = try item(old.item)
        #expect(borrowed.catalogPhotoPath == nil && borrowed.catalogPhotoListingId == nil)
        #expect(try f.context.fetch(FetchDescriptor<ShareOutboxRecord>()).isEmpty)
    }

    @Test func theNextOpenAsksTheNewServerAndDropsTheOldServersListingsAndPictures() async throws {
        defer { f.tearDown() }
        let old = try oldCatalogue()
        try f.store.moveToServer(new)
        let client = GymCatalogClient(repository: repo, transport: transport, knownKinds: ["cable-stack", "kettlebell"],
                                      now: { [clock = f.clock] in clock.now })

        let refresh = try await client.refresh(gymId: old.gym, force: false)

        #expect(try listing(old.theirs) == nil)
        #expect(refresh.filesToDelete == ["theirs.jpg"])
        #expect(try listing(old.own) != nil)
        #expect(try listing(old.waiting) != nil)
        #expect(try gymRecord(old.gym).remoteId == nil, "the new server has no gym at this place yet")
    }
}
