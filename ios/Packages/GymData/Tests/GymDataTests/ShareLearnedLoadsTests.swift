import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// A learned weight list is only "seen so far": a share goes without it (owner, 2026-11-22).
@MainActor
@Suite struct ShareLearnedLoadsTests {
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

    private func learnedListing(fromWorkouts: Bool = true) throws -> GymListing {
        transport.gym = RemoteGym(id: serverGymId, name: "Server", address: nil, latitude: nil, longitude: nil,
                                  mapsPlaceId: "P1")
        let gym = try repo.addMapsGym(placeId: "P1", name: "Test Gym", address: nil, latitude: 1, longitude: 2)
        return try repo.addListing(NewListing(gymId: gym.id, kindId: "dumbbells", loads: .fixed(kg: [10, 12]),
                                              loadsFromWorkouts: fromWorkouts, photoFile: "mine.jpg"))
    }

    @Test func aLearnedListIsSharedWithoutWeightsAndTheListingShowsWhatIsPublic() async throws {
        defer { f.tearDown() }
        let listing = try learnedListing()
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        await box.run(userId: user)
        #expect(try #require(transport.requests.first).loads == ListingLoads.none)
        let after = try #require(try repo.listing(listing.id))
        #expect(after.visibility == .shared && after.loads == ListingLoads.none && !after.loadsFromWorkouts)
    }

    @Test func aListTheUserMadeIsSharedAsItIs() async throws {
        defer { f.tearDown() }
        let listing = try learnedListing(fromWorkouts: false)
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        await box.run(userId: user)
        #expect(try #require(transport.requests.first).loads == .fixed(kg: [10, 12]))
        #expect(try repo.listing(listing.id)?.loads == .fixed(kg: [10, 12]))
    }

    @Test func duplicatesLeaveTheFlagAndWeightsAlone() async throws {
        defer { f.tearDown() }
        let listing = try learnedListing()
        let other = RemoteListing(id: UUID(), gymId: serverGymId, itemId: UUID(), kindId: "dumbbells", brand: nil,
                                  model: nil, photoPath: nil, loads: .fixed(kg: [5]), quantity: 1, notes: nil,
                                  status: "active", confirmCount: 2, isMine: false, confirmedByMe: false)
        transport.shareScript = [.success(.duplicates([other]))]
        let box = outbox
        try box.enqueueShare(listingId: listing.id, ownerId: user)
        await box.run(userId: user)
        let after = try #require(try repo.listing(listing.id))
        #expect(after.uploadState == .waitingForChoice)
        #expect(after.loads == .fixed(kg: [10, 12]) && after.loadsFromWorkouts)
    }
}
