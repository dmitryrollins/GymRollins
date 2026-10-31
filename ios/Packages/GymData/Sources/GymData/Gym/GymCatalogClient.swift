import Foundation
import GymCore
import SwiftData

/// A picture the phone still has to download for a cached listing.
public struct PhotoFetch: Sendable, Equatable {
    public let listingId: UUID
    public let path: String
}

public struct CatalogRefresh: Sendable, Equatable {
    public let photosToFetch: [PhotoFetch], filesToDelete: [String]
    public static let empty = CatalogRefresh(photosToFetch: [], filesToDelete: [])
}

/// Keeps a gym's public listings as ordinary local rows, so the rules keep reading `GymRepository.inventory`.
@MainActor
public final class GymCatalogClient {
    static let refreshInterval: TimeInterval = 6 * 3_600
    /// Pictures handed out per refresh; the rest come on the next open, so a gym of hundreds never fetches them all at once.
    static let photosPerRefresh = 100

    private let repository: GymRepository
    private let transport: GymCatalogTransport
    private let knownKinds: Set<String>
    private let now: () -> Date
    private var generation = 0

    public init(repository: GymRepository, transport: GymCatalogTransport, knownKinds: Set<String>,
                now: @escaping () -> Date) {
        self.repository = repository
        self.transport = transport
        self.knownKinds = knownKinds
        self.now = now
    }

    /// Called when the session ends or changes, before the rows are wiped. A refresh waiting on the server returns
    /// without touching any row: what it was told is about a session that is gone.
    public func invalidate() { generation += 1 }

    /// Returns the photo paths to download and the local files to delete. Offline leaves the cache as it is. The
    /// pictures still missing are worked out from the local rows on every call, inside the six hours too, so a
    /// download that was interrupted doesn't wait for the next full refresh.
    public func refresh(gymId: UUID, force: Bool) async throws -> CatalogRefresh {
        guard let gym = try repository.gymRecord(gymId) else { throw GymDataError.invalidInput("Unknown gym.") }
        guard let placeId = gym.mapsPlaceId else { return .empty }
        if !force, let last = gym.catalogRefreshedAt, now().timeIntervalSince(last) < Self.refreshInterval {
            return CatalogRefresh(photosToFetch: try missingPhotos(gymId: gymId), filesToDelete: [])
        }
        let token = generation
        do {
            let hadId = gym.remoteId != nil
            let known = try await serverGymId(gym, placeId: placeId, token: token)
            guard token == generation else { return .empty }
            guard var serverId = known else {
                try stamp(gym)
                return .empty
            }
            var remote = try await transport.publicListings(gymId: serverId)
            guard token == generation else { return .empty }
            if hadId, remote.listings.isEmpty, remote.isComplete {
                // A moderator may have removed that gym and someone recreated the place under a new id.
                switch try await currentGym(gym, placeId: placeId, was: serverId, token: token) {
                case .stale: return .empty
                case .same: break
                case let .moved(id):
                    serverId = id
                    remote = try await transport.publicListings(gymId: id)
                    guard token == generation else { return .empty }
                case .gone: break
                }
            }
            let result = try apply(remote.listings, to: gym, complete: remote.isComplete && !knownKinds.isEmpty)
            try await refreshCataloguePhotos(gymId: gym.id, token: token)
            return result
        } catch GymCatalogError.offline {
            return .empty
        }
    }

    /// The pictures of cached shared listings that this phone hasn't downloaded yet, oldest first.
    public func missingPhotos(gymId: UUID) throws -> [PhotoFetch] {
        let shared = GymVisibility.shared.rawValue
        let rows = try repository.context.fetch(FetchDescriptor<GymListingRecord>(
            predicate: #Predicate { $0.gymId == gymId && $0.visibilityRaw == shared && $0.photoFile == nil },
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]))
        return rows.filter { !$0.hiddenLocally }.compactMap { row in row.remotePhotoPath.map { PhotoFetch(listingId: row.id, path: $0) } }
            .prefix(Self.photosPerRefresh).map { $0 }
    }

    private enum CurrentGym { case same, moved(UUID), gone, stale }

    /// Asks which server gym the place has now. A different id replaces the stored one; no gym clears it.
    private func currentGym(_ gym: GymRecord, placeId: String, was old: UUID, token: Int) async throws -> CurrentGym {
        let found = try await transport.publicGym(mapsPlaceId: placeId)
        guard token == generation else { return .stale }
        guard let found else {
            gym.remoteId = nil
            return .gone
        }
        guard found.id != old else { return .same }
        gym.remoteId = found.id
        return .moved(found.id)
    }

    /// Branded items of a kind: the server's, merged with the ones My gyms list. Offline, the local list alone.
    public func items(kindId: String) async -> [CatalogueItem] {
        let local = (try? repository.catalogueItems(kindId: kindId)) ?? []
        guard let remote = try? await transport.publicItems(kindId: kindId) else { return local }
        var merged: [String: CatalogueItem] = [:]
        for entry in local + remote.compactMap(Self.catalogueItem) {
            let key = Self.key(entry.item)
            if merged[key] == nil || entry.gymCount > merged[key]!.gymCount { merged[key] = entry }
        }
        return merged.values.sorted {
            if $0.gymCount != $1.gymCount { return $0.gymCount > $1.gymCount }
            return ($0.item.brand ?? "", $0.item.model ?? "") < ($1.item.brand ?? "", $1.item.model ?? "")
        }
    }

    /// Writes the item as the server has it. The id decides: an item the phone already has is updated, not copied.
    @discardableResult
    public func upsertItem(_ remote: RemoteItem) throws -> EquipmentItem {
        let context = repository.context
        let id = remote.id
        let record = try context.fetch(FetchDescriptor<EquipmentItemRecord>(predicate: #Predicate { $0.id == id })).first
            ?? EquipmentItemRecord(id: id, kindId: remote.kindId, brand: remote.brand, model: remote.model,
                                   now: now())
        record.brand = remote.brand
        record.model = remote.model
        record.catalogPhotoPath = remote.photoPath
        record.catalogPhotoListingId = remote.photoListingId
        if record.modelContext == nil { context.insert(record) }
        try context.save()
        return GymRepository.item(record)
    }

    // MARK: - Helpers

    /// One `publicItems` call per kind that has a listing here without its own picture. A failed call keeps the
    /// pictures already cached: the next refresh asks again.
    private func refreshCataloguePhotos(gymId: UUID, token: Int) async throws {
        let context = repository.context
        let rows = (try? context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.gymId == gymId }))) ?? []
        let kinds = Set(rows.filter { $0.photoFile == nil }.map(\.kindId))
        let reported = try QueuedModeration(context: context).reportedPhotos
        for kind in kinds.sorted() {
            guard let items = try? await transport.publicItems(kindId: kind) else { continue }
            guard token == generation else { return }
            for remote in items {
                let id = remote.id
                guard let record = try? context.fetch(
                    FetchDescriptor<EquipmentItemRecord>(predicate: #Predicate { $0.id == id })).first else { continue }
                // A picture the user reported keeps off until the report is sent.
                if let source = remote.photoListingId, reported.contains(source) { continue }
                record.catalogPhotoPath = remote.photoPath
                record.catalogPhotoListingId = remote.photoListingId
            }
        }
        try context.save()
    }

    private func serverGymId(_ gym: GymRecord, placeId: String, token: Int) async throws -> UUID? {
        if let known = gym.remoteId { return known }
        guard let found = try await transport.publicGym(mapsPlaceId: placeId), token == generation else { return nil }
        // Only the id comes from the server: the first sharer set its name, and Apple Maps' name is the one shown here.
        gym.remoteId = found.id
        return found.id
    }

    private func stamp(_ gym: GymRecord) throws {
        gym.catalogRefreshedAt = now()
        try repository.context.save()
    }

    /// An incomplete read (rows this version couldn't read, a capped read, or no known kinds to tell usable rows by)
    /// adds and updates what it did see but removes nothing and leaves the gym unstamped, so the next open tries
    /// again: a listing missing from it may only be one this phone couldn't read.
    private func apply(_ remote: [RemoteListing], to gym: GymRecord, complete: Bool) throws -> CatalogRefresh {
        let context = repository.context
        let gymId = gym.id
        let usable = remote.filter { knownKinds.contains($0.kindId) }
        var locals = Dictionary(
            try context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.gymId == gymId }))
                .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let confirming = Set(try context.fetch(FetchDescriptor<ShareOutboxRecord>()).filter {
            $0.kindRaw == ShareOutboxRecord.Kind.confirm.rawValue
        }.map(\.targetId))
        let hiding = try QueuedModeration(context: context).hiding
        for entry in usable {
            let item = try itemRecord(for: entry)
            if let row = locals[entry.id] {
                if row.visibilityRaw == GymVisibility.device.rawValue { continue }
                cache.update(row, from: entry, itemId: item.id)
            } else {
                let row = cache.insert(entry, itemId: item.id, gymId: gymId)
                locals[entry.id] = row
            }
            // `update` leaves `hiddenLocally` alone: a reported row stays hidden while the server still returns it.
            if hiding.contains(entry.id) { locals[entry.id]?.hiddenLocally = true }
            // The server doesn't know about a confirmation that is still queued.
            if confirming.contains(entry.id) { locals[entry.id]?.confirmedByMe = true }
        }
        let present = Set(remote.map(\.id))
        var files: [String] = []
        for row in locals.values where complete && isGone(row, present: present) {
            if let file = row.photoFile { files.append(file) }
            context.delete(row)
        }
        if complete { gym.catalogRefreshedAt = now() }
        try context.save()
        return CatalogRefresh(photosToFetch: try missingPhotos(gymId: gymId), filesToDelete: files)
    }

    private func isGone(_ row: GymListingRecord, present: Set<UUID>) -> Bool {
        row.visibilityRaw == GymVisibility.shared.rawValue && row.uploadStateRaw == UploadState.uploaded.rawValue
            && !present.contains(row.id)
    }

    private func itemRecord(for entry: RemoteListing) throws -> EquipmentItemRecord {
        let id = entry.itemId
        if let existing = try repository.context.fetch(
            FetchDescriptor<EquipmentItemRecord>(predicate: #Predicate { $0.id == id })).first {
            return existing
        }
        let record = EquipmentItemRecord(id: id, kindId: entry.kindId, brand: entry.brand, model: entry.model, now: now())
        repository.context.insert(record)
        return record
    }

    private var cache: RemoteListingCache { RemoteListingCache(context: repository.context, now: now) }

    private static func catalogueItem(_ remote: RemoteItem) -> CatalogueItem? {
        guard remote.brand != nil || remote.model != nil else { return nil }
        return CatalogueItem(item: EquipmentItem(id: remote.id, kindId: remote.kindId, brand: remote.brand,
                                                 model: remote.model, catalogPhotoPath: remote.photoPath,
                                                 catalogPhotoListingId: remote.photoListingId),
                             gymCount: remote.gymCount)
    }

    private static func key(_ item: EquipmentItem) -> String {
        "\(item.brand ?? "")|\(item.model ?? "")".lowercased()
    }
}
