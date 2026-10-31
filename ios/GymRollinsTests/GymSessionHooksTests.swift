import Foundation
import GymCore
import GymData
import GymSync
import Testing
@testable import GymRollins

/// A transport that parks `share` and `publicListings` until the test lets them go, so a session can end while a
/// request is on the wire.
private final class GatedTransport: GymCatalogTransport, @unchecked Sendable {
    let inner = StubCatalogTransport()
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private var isParked = false
    var parked: Bool { lock.withLock { isParked } }

    private func park() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if isOpen { continuation.resume() } else { waiting = continuation; isParked = true }
            }
        }
    }

    func release() {
        lock.withLock {
            isOpen = true
            waiting?.resume()
            waiting = nil
        }
    }

    func publicGym(mapsPlaceId: String) async throws -> RemoteGym? { try await inner.publicGym(mapsPlaceId: mapsPlaceId) }
    func publicListings(gymId: UUID) async throws -> PublicListings {
        await park()
        return try await inner.publicListings(gymId: gymId)
    }
    func publicItems(kindId: String) async throws -> [RemoteItem] { try await inner.publicItems(kindId: kindId) }
    func findOrCreateGym(mapsPlaceId: String, name: String, address: String?, latitude: Double?,
                         longitude: Double?) async throws -> UUID {
        try await inner.findOrCreateGym(mapsPlaceId: mapsPlaceId, name: name, address: address, latitude: latitude,
                                        longitude: longitude)
    }
    func share(_ request: ShareRequest) async throws -> ShareResult {
        await park()
        return try await inner.share(request)
    }
    func confirm(listingId: UUID) async throws -> Int { try await inner.confirm(listingId: listingId) }
    func uploadSharedPhoto(_ data: Data, name: String) async throws -> String {
        try await inner.uploadSharedPhoto(data, name: name)
    }
    func deleteSharedPhoto(path: String) async throws { try await inner.deleteSharedPhoto(path: path) }
    func report(targetType: GymTargetType, targetId: UUID, reason: ReportReason, note: String?) async throws {
        try await inner.report(targetType: targetType, targetId: targetId, reason: reason, note: note)
    }
    func blockAuthor(targetType: GymTargetType, targetId: UUID) async throws {
        try await inner.blockAuthor(targetType: targetType, targetId: targetId)
    }
    func unblockAll() async throws -> Int { try await inner.unblockAll() }
    func publicPhotoURL(path: String) -> URL? { inner.publicPhotoURL(path: path) }
}

/// What the app does when the sync coordinator calls its hooks: sign-out, a session ending, gyms moving to new ids.
@MainActor
@Suite struct GymSessionHooksTests {
    private let user = UUID()

    private func rig(gated: GatedTransport) throws -> GymTestRig {
        let rig = try GymTestRig.make()
        gated.inner.gym = RemoteGym(id: UUID(), name: "Server", address: nil, latitude: nil, longitude: nil,
                                    mapsPlaceId: "P1")
        rig.env.gymSharing = GymSharing(
            repository: rig.env.gyms, transport: gated, knownKinds: ["lat-pulldown", "flat-bench"],
            photos: GymPhotoCache(store: rig.photos) { _, _ in Data() }, photoData: { rig.photos.data(file: $0) },
            now: rig.env.now)
        rig.env.wireGymSharing()
        return rig
    }

    private func mapsGym(_ rig: GymTestRig) throws -> Gym {
        try rig.env.gyms.addMapsGym(placeId: "P1", name: "Iron", address: nil, latitude: 1, longitude: 2)
    }

    @Test func signOutRunsTheHooksInOrderBeforeTheWipeFinishes() async throws {
        let rig = try rig(gated: GatedTransport())
        let sync = rig.env.sync
        var order: [String] = []
        let will = sync.onWillSignOut, ending = sync.onSessionEnding, reset = sync.onLocalDataReset
        sync.onWillSignOut = {
            order.append("willSignOut")
            await will()
        }
        sync.onSessionEnding = {
            order.append("sessionEnding")
            ending()
        }
        sync.onLocalDataReset = {
            order.append("wiped")
            reset()
        }
        try await sync.signOutAndRemoveLocalData()
        // The wipe ends the session once more itself, which is harmless: the queue and client only count generations.
        #expect(order.first == "willSignOut")
        #expect(order.dropFirst().first == "sessionEnding", "invalidated before anything is wiped")
        #expect(order.last == "wiped")
        #expect(order.filter { $0 == "wiped" }.count == 1)
    }

    @Test func aSessionEndingWhileAShareIsOnTheWireLeavesTheRowAlone() async throws {
        let gated = GatedTransport()
        let rig = try rig(gated: gated)
        let gym = try mapsGym(rig)
        let own = try rig.env.gyms.addListing(NewListing(gymId: gym.id, kindId: "flat-bench"))
        try rig.env.gymSharing.outbox.enqueueShare(listingId: own.id, ownerId: user)
        let run = Task { await rig.env.gymSharing.outbox.run(userId: user) }
        try await waitUntil { gated.parked }

        rig.env.sync.onSessionEnding()
        gated.release()
        await run.value

        #expect(try rig.env.gyms.listing(own.id)?.uploadState == .queued, "the answer belongs to a session that is gone")
        #expect(rig.env.gymSharing.outbox.pendingCount == 1)
    }

    @Test func aSessionEndingWhileARefreshIsOnTheWireCachesNothing() async throws {
        let gated = GatedTransport()
        let rig = try rig(gated: gated)
        let gym = try mapsGym(rig)
        gated.inner.listings = [RemoteListing(id: UUID(), gymId: UUID(), itemId: UUID(), kindId: "lat-pulldown",
                                              brand: nil, model: nil, photoPath: nil, loads: .stack(maxKg: 90, stepKg: 5),
                                              quantity: 1, notes: nil, status: "active", confirmCount: 1,
                                              isMine: false, confirmedByMe: false)]
        let refresh = Task { await rig.env.gymCatalogRefresh(gymId: gym.id, force: true) }
        try await waitUntil { gated.parked }

        rig.env.sync.onSessionEnding()
        gated.release()
        await refresh.value

        #expect(try rig.env.gyms.listings(gymId: gym.id).isEmpty)
    }

    @Test func aGymThatMovedToANewIdTakesTheCurrentGymDefaultWithIt() throws {
        let rig = try GymTestRig.make()
        let old = try rig.gym("Home")
        let new = try rig.gym("Moved")
        rig.env.setCurrentGym(old.id)

        rig.env.sync.onGymIdsMoved([old.id: new.id])

        #expect(rig.defaults.string(forKey: AppEnvironment.currentGymKey) == new.id.uuidString)
        #expect(rig.env.currentGym?.id == new.id)
    }

    @Test func aMoveOfAnotherGymLeavesTheCurrentGymAlone() throws {
        let rig = try GymTestRig.make()
        let current = try rig.gym("Home")
        let other = try rig.gym("Other")
        rig.env.setCurrentGym(current.id)
        let revision = rig.env.gymRevision

        rig.env.sync.onGymIdsMoved([other.id: UUID()])

        #expect(rig.env.currentGym?.id == current.id)
        #expect(rig.env.gymRevision > revision, "the screens still reload")
    }
}
