import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Criterion 6: what is marked "This phone only" is never sent anywhere.
@MainActor
@Suite struct StaysOnThePhoneTests {
    let f: SyncFixture
    let transport = FakeGymCatalogTransport()
    init() throws { f = try SyncFixture() }

    private var repo: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }
    private var client: GymCatalogClient {
        GymCatalogClient(repository: repo, transport: transport, knownKinds: ["cable-stack"],
                         now: { [clock = f.clock] in clock.now })
    }
    private var outbox: ShareOutbox {
        ShareOutbox(repository: repo, transport: transport, photoData: { _ in Data("jpeg".utf8) },
                    now: { [clock = f.clock] in clock.now })
    }

    private func fill(_ gym: Gym) throws {
        try repo.addListing(NewListing(gymId: gym.id, kindId: "cable-stack", brand: "Secret", notes: "private note",
                                       photoFile: "a.jpg"))
    }

    @Test func browsingAPrivateGymMakesNoCalls() async throws {
        defer { f.tearDown() }
        let gym = try repo.addPrivateGym(name: "Home", address: nil)
        try fill(gym)
        _ = try await client.refresh(gymId: gym.id, force: true)
        #expect(transport.calls.isEmpty)
    }

    @Test func browsingAMapsGymOnlyReadsPublicRows() async throws {
        defer { f.tearDown() }
        let gym = try repo.addMapsGym(placeId: "P1", name: "Gym", address: nil, latitude: 1, longitude: 2)
        try fill(gym)
        transport.gym = RemoteGym(id: UUID(), name: "Gym", address: nil, latitude: nil, longitude: nil,
                                  mapsPlaceId: "P1")
        _ = try await client.refresh(gymId: gym.id, force: true)
        #expect(transport.calls == ["publicGym", "publicListings"])
        #expect(transport.requests.isEmpty)
        #expect(transport.uploads.isEmpty)
    }

    @Test func signedInWithAnEmptyQueueMakesNoCalls() async throws {
        defer { f.tearDown() }
        let gym = try repo.addMapsGym(placeId: "P1", name: "Gym", address: nil, latitude: 1, longitude: 2)
        try fill(gym)
        await outbox.run(userId: UUID())
        #expect(transport.calls.isEmpty)
    }
}
