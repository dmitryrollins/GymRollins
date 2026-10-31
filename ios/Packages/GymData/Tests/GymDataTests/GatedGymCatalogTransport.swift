import Foundation
import GymCore
@testable import GymData

/// A catalogue transport whose named calls suspend until `release()`, so a test can change the session while a request
/// is "on the wire". `FakeGymCatalogTransport` never suspends, which is why mid-run changes went untested.
final class GatedGymCatalogTransport: GymCatalogTransport, @unchecked Sendable {
    let inner = FakeGymCatalogTransport()
    private let lock = NSLock()
    private var held: Set<String> = []
    private var suspended: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var arrivals: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// The calls that suspend when they are made.
    func hold(_ names: String...) { lock.withLock { held.formUnion(names) } }

    /// Lets every suspended call go on, and stops holding any.
    func release() {
        let waiting = lock.withLock {
            held = []
            defer { suspended = [:] }
            return suspended.values.flatMap { $0 }
        }
        waiting.forEach { $0.resume() }
    }

    /// Returns once a call of this name is suspended.
    func waitUntilSuspended(_ name: String) async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let alreadyThere = lock.withLock {
                if suspended[name]?.isEmpty == false { return true }
                arrivals[name, default: []].append(waiter)
                return false
            }
            if alreadyThere { waiter.resume() }
        }
    }

    private func gate(_ name: String) async {
        guard lock.withLock({ held.contains(name) }) else { return }
        await withCheckedContinuation { (call: CheckedContinuation<Void, Never>) in
            let waiters = lock.withLock {
                suspended[name, default: []].append(call)
                defer { arrivals[name] = nil }
                return arrivals[name] ?? []
            }
            waiters.forEach { $0.resume() }
        }
    }

    func publicGym(mapsPlaceId: String) async throws -> RemoteGym? {
        await gate("publicGym")
        return try await inner.publicGym(mapsPlaceId: mapsPlaceId)
    }

    func publicListings(gymId: UUID) async throws -> PublicListings {
        await gate("publicListings")
        return try await inner.publicListings(gymId: gymId)
    }

    func publicItems(kindId: String) async throws -> [RemoteItem] {
        await gate("publicItems")
        return try await inner.publicItems(kindId: kindId)
    }

    func findOrCreateGym(mapsPlaceId: String, name: String, address: String?, latitude: Double?,
                         longitude: Double?) async throws -> UUID {
        await gate("findOrCreateGym")
        return try await inner.findOrCreateGym(mapsPlaceId: mapsPlaceId, name: name, address: address,
                                               latitude: latitude, longitude: longitude)
    }

    func share(_ request: ShareRequest) async throws -> ShareResult {
        await gate("share")
        return try await inner.share(request)
    }

    func confirm(listingId: UUID) async throws -> Int {
        await gate("confirm")
        return try await inner.confirm(listingId: listingId)
    }

    func uploadSharedPhoto(_ data: Data, name: String) async throws -> String {
        await gate("uploadSharedPhoto")
        return try await inner.uploadSharedPhoto(data, name: name)
    }

    func deleteSharedPhoto(path: String) async throws {
        await gate("deleteSharedPhoto")
        try await inner.deleteSharedPhoto(path: path)
    }

    func report(targetType: GymTargetType, targetId: UUID, reason: ReportReason, note: String?) async throws {
        await gate("report")
        try await inner.report(targetType: targetType, targetId: targetId, reason: reason, note: note)
    }

    func blockAuthor(targetType: GymTargetType, targetId: UUID) async throws {
        await gate("blockAuthor")
        try await inner.blockAuthor(targetType: targetType, targetId: targetId)
    }

    func unblockAll() async throws -> Int {
        await gate("unblockAll")
        return try await inner.unblockAll()
    }

    func publicPhotoURL(path: String) -> URL? { inner.publicPhotoURL(path: path) }
}
