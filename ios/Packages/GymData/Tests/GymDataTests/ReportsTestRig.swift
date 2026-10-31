import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// What the report, block and moderation suites share: a Maps gym the server knows, a cache filled the way a refresh
/// fills it, and an outbox over the fake server.
@MainActor
protocol ReportsTestRig {
    var f: SyncFixture { get }
    var transport: FakeGymCatalogTransport { get }
    var serverGymId: UUID { get }
    var user: UUID { get }
}

@MainActor
extension ReportsTestRig {
    var repo: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }
    var outbox: ShareOutbox {
        ShareOutbox(repository: repo, transport: transport, photoData: { _ in Data("jpeg".utf8) },
                    now: { [clock = f.clock] in clock.now })
    }
    var client: GymCatalogClient {
        GymCatalogClient(repository: repo, transport: transport, knownKinds: ["cable-stack", "kettlebell"],
                         now: { [clock = f.clock] in clock.now })
    }

    func mapsGym() throws -> Gym {
        transport.gym = RemoteGym(id: serverGymId, name: "Server", address: nil, latitude: nil, longitude: nil,
                                  mapsPlaceId: "P1")
        let gym = try repo.addMapsGym(placeId: "P1", name: "Apple Name", address: "1 Main", latitude: 1, longitude: 2)
        try #require(try repo.gymRecord(gym.id)).remoteId = serverGymId
        return gym
    }

    func remote(_ id: UUID = UUID(), mine: Bool = false, photo: String? = nil) -> RemoteListing {
        RemoteListing(id: id, gymId: serverGymId, itemId: UUID(), kindId: "cable-stack", brand: nil, model: nil,
                      photoPath: photo, loads: .stack(maxKg: 90, stepKg: 5), quantity: 1, notes: nil,
                      status: "active", confirmCount: 1, isMine: mine, confirmedByMe: false)
    }

    /// Fills the cache the way a refresh does.
    func cache(_ gym: Gym, _ listings: [RemoteListing], force: Bool = true) async throws {
        transport.listings = listings
        _ = try await client.refresh(gymId: gym.id, force: force)
    }

    func shown(_ gym: Gym) throws -> Set<UUID> {
        Set(try repo.listings(gymId: gym.id, includingUnsupported: true).map(\.id))
    }

    /// A listing of the user's own whose item borrows a picture from `source`.
    func borrowed(_ gym: Gym, source: UUID) throws -> (GymListing, EquipmentItemRecord) {
        let mine = try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack"))
        let item = try #require(try f.context.fetch(FetchDescriptor<EquipmentItemRecord>()).first {
            $0.id == mine.item.id
        })
        item.catalogPhotoPath = "\(UUID()).jpg"
        item.catalogPhotoListingId = source
        try f.context.save()
        return (mine, item)
    }
}
