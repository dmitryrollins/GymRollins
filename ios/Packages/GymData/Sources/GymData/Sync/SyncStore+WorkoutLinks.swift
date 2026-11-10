import Foundation
import GymCore
import SwiftData

// A workout's gym and each entry's listing are local row ids. The server knows a gym or listing under its own id, and
// only when the row is one the account can see, so ids are translated on the way out and back in.
extension SyncStore {
    /// The workout as the server should get it: links the server can't know about are left out.
    func sendable(_ workout: Workout) throws -> Workout {
        let entries = try workout.entries.map { try $0.with(gymListingId: serverListingId($0.gymListingId)) }
        return try workout.with(gymId: serverGymId(workout.gymId)).with(entries: entries)
    }

    /// A pulled workout with its server ids turned into local ones. A link this phone has no row for, or the server
    /// has dropped, keeps what the local copy had: the server can't know about a "This phone only" gym.
    func resolved(_ workout: Workout, keeping existing: Workout?) throws -> Workout {
        let kept = Dictionary((existing?.entries ?? []).map { ($0.id, $0.gymListingId) }, uniquingKeysWith: { first, _ in first })
        let entries = try workout.entries.map {
            try $0.with(gymListingId: localListingId(serverId: $0.gymListingId) ?? kept[$0.id] ?? nil)
        }
        return try workout.with(gymId: localGymId(serverId: workout.gymId) ?? existing?.gymId).with(entries: entries)
    }

    private func serverGymId(_ id: UUID?) throws -> UUID? {
        guard let id, let gym = try anyGymRecord(id), gym.deletedAt == nil else { return nil }
        if gym.mapsPlaceId != nil { return gym.remoteId }
        guard gym.visibilityRaw == GymVisibility.synced.rawValue, gym.serverUpdatedAt != nil else { return nil }
        return gym.id
    }

    private func serverListingId(_ id: UUID?) throws -> UUID? {
        guard let id, let listing = try anyListingRecord(id), listing.deletedAt == nil else { return nil }
        switch GymVisibility(rawValue: listing.visibilityRaw) {
        case .shared: return listing.remoteId
        case .synced: return listing.serverUpdatedAt == nil ? nil : listing.id
        default: return nil
        }
    }

    private func localGymId(serverId: UUID?) throws -> UUID? {
        guard let serverId else { return nil }
        let synced = GymVisibility.synced.rawValue
        let rows = try context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate {
            $0.deletedAt == nil && ($0.remoteId == serverId || ($0.id == serverId && $0.visibilityRaw == synced))
        }))
        return rows.first?.id
    }

    private func localListingId(serverId: UUID?) throws -> UUID? {
        guard let serverId else { return nil }
        let synced = GymVisibility.synced.rawValue
        let rows = try context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate {
            $0.deletedAt == nil && ($0.remoteId == serverId || ($0.id == serverId && $0.visibilityRaw == synced))
        }))
        return rows.first?.id
    }
}
