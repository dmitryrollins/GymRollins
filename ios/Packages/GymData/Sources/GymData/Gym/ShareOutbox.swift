import Foundation
import GymCore
import SwiftData

/// The persisted queue of shares and confirmations, run for the signed-in user. A row stays until the server has
/// answered, so a lost connection or a quit app never loses a share.
@MainActor
public final class ShareOutbox {
    static let gymUnderReview = "This gym is under review. Try again later."
    static let dailyLimit = "You've shared a lot today. Try again tomorrow."
    static let couldNotShare = "Couldn't share this one. Try again later."

    private let repository: GymRepository
    private let transport: GymCatalogTransport
    private let photoData: (String) -> Data?
    private let now: () -> Date
    private var running = false

    /// The last error from reading or saving the queue itself, for the caller to log.
    public private(set) var storageError: Error?

    public init(repository: GymRepository, transport: GymCatalogTransport, photoData: @escaping (String) -> Data?,
                now: @escaping () -> Date) {
        self.repository = repository
        self.transport = transport
        self.photoData = photoData
        self.now = now
    }

    private var context: ModelContext { repository.context }

    public var pendingCount: Int { (try? context.fetchCount(FetchDescriptor<ShareOutboxRecord>())) ?? 0 }

    // MARK: - Queueing

    /// Queues the share. Only a listing at a Maps gym can be shared; a private gym's can never leave the account.
    public func enqueueShare(listingId: UUID, ownerId: UUID, forceNew: Bool = false) throws {
        guard let listing = try repository.listingRecord(listingId) else {
            throw GymDataError.invalidInput("Unknown listing.")
        }
        guard let gym = try repository.gymRecord(listing.gymId), gym.mapsPlaceId != nil else {
            throw GymDataError.invalidInput("A private gym can't be shared.")
        }
        guard !(listing.visibilityRaw == GymVisibility.shared.rawValue
                && listing.uploadStateRaw == UploadState.uploaded.rawValue) else {
            throw GymDataError.invalidInput("This listing is already shared.")
        }
        try removeRows(kind: .share, target: listingId)
        context.insert(ShareOutboxRecord(kind: .share, targetId: listingId, ownerId: ownerId, forceNew: forceNew,
                                         now: now()))
        listing.visibilityRaw = GymVisibility.shared.rawValue
        listing.uploadStateRaw = UploadState.queued.rawValue
        listing.uploadError = nil
        listing.duplicatesData = nil
        listing.updatedAt = now()
        try context.save()
    }

    /// Queues a confirmation. Asking twice queues it once.
    public func enqueueConfirm(listingId: UUID, ownerId: UUID) throws {
        if try rows().contains(where: { $0.kindRaw == Kind.confirm.rawValue && $0.targetId == listingId }) { return }
        context.insert(ShareOutboxRecord(kind: .confirm, targetId: listingId, ownerId: ownerId, now: now()))
        if let listing = try repository.listingRecord(listingId) { listing.confirmedByMe = true }
        try context.save()
    }

    /// Puts a failed share back in the queue.
    public func retry(listingId: UUID, ownerId: UUID) throws {
        guard let listing = try repository.listingRecord(listingId),
              listing.uploadStateRaw == UploadState.failed.rawValue else {
            throw GymDataError.invalidInput("Nothing to retry.")
        }
        try enqueueShare(listingId: listingId, ownerId: ownerId)
    }

    /// The user chose the listing that was already there: mine goes, theirs is confirmed. Returns my photo file,
    /// for the caller to delete.
    public func keepExisting(listingId: UUID, existingId: UUID, ownerId: UUID) throws -> String? {
        let photo = try repository.removeListing(listingId)
        try removeRows(kind: .share, target: listingId)
        try enqueueConfirm(listingId: existingId, ownerId: ownerId)
        return photo
    }

    /// The listings the server returned while the share waits for a choice.
    public func duplicates(listingId: UUID) throws -> [RemoteListing] {
        guard let data = try repository.listingRecord(listingId)?.duplicatesData else { return [] }
        return try JSONDecoder().decode([RemoteListing].self, from: data)
    }

    // MARK: - Running

    /// Runs the signed-in user's rows oldest first. Stops at the first offline error; other errors are per row.
    public func run(userId: UUID?) async {
        guard let userId, !running else { return }
        running = true
        defer { running = false }
        do {
            for row in try rows() where row.ownerId == userId {
                if try await process(row) == .stop { return }
            }
        } catch {
            storageError = error
        }
    }

    private enum Outcome { case next, stop }

    private func process(_ row: ShareOutboxRecord) async throws -> Outcome {
        do {
            switch Kind(rawValue: row.kindRaw) {
            case .share: try await share(row)
            case .confirm: try await confirm(row)
            case nil: context.delete(row); try context.save()
            }
            return .next
        } catch GymCatalogError.offline, GymCatalogError.signedOut {
            return .stop
        } catch {
            try settle(row, error)
            return .next
        }
    }

    private func share(_ row: ShareOutboxRecord) async throws {
        guard let listing = try repository.listingRecord(row.targetId),
              let gym = try repository.gymRecord(listing.gymId) else {
            context.delete(row)
            try context.save()
            return
        }
        let gymId = try await serverId(of: gym)
        let photo = try await uploadedPhoto(of: listing)
        let item = try itemRecord(listing.itemId)
        let loads = try JSONDecoder().decode(ListingLoads.self, from: listing.loadsData)
        let request = ShareRequest(listingId: listing.id, gymId: gymId, kindId: listing.kindId, brand: item?.brand,
                                   model: item?.model, loads: loads, quantity: listing.quantity,
                                   notes: listing.notes, photoPath: photo, forceNew: row.forceNew)
        switch try await transport.share(request) {
        case let .created(id):
            listing.visibilityRaw = GymVisibility.shared.rawValue
            listing.uploadStateRaw = UploadState.uploaded.rawValue
            listing.uploadError = nil
            listing.duplicatesData = nil
            listing.remoteId = id
        case let .duplicates(found):
            listing.uploadStateRaw = UploadState.waitingForChoice.rawValue
            listing.duplicatesData = try JSONEncoder().encode(found)
        }
        listing.updatedAt = now()
        context.delete(row)
        try context.save()
    }

    private func confirm(_ row: ShareOutboxRecord) async throws {
        let count = try await transport.confirm(listingId: row.targetId)
        if let listing = try repository.listingRecord(row.targetId) {
            listing.confirmCount = count
            listing.confirmedByMe = true
        }
        context.delete(row)
        try context.save()
    }

    /// The server's id for the gym, asking the server to create the gym the first time.
    private func serverId(of gym: GymRecord) async throws -> UUID {
        if let known = gym.remoteId { return known }
        let id = try await transport.findOrCreateGym(mapsPlaceId: gym.mapsPlaceId ?? "", name: gym.name,
                                                     address: gym.address, latitude: gym.latitude,
                                                     longitude: gym.longitude)
        gym.remoteId = id
        try context.save()
        return id
    }

    /// The name of the photo on the server. A name already stored means the upload happened: the retry skips it.
    private func uploadedPhoto(of listing: GymListingRecord) async throws -> String? {
        if let known = listing.remotePhotoPath { return known }
        guard let file = listing.photoFile, let data = photoData(file) else { return nil }
        let name = "\(UUID().uuidString.lowercased()).jpg"
        let stored = try await transport.uploadSharedPhoto(data, name: name)
        listing.remotePhotoPath = stored
        try context.save()
        return stored
    }

    /// An answer that isn't "done": the row either waits for another try or the listing shows why it stopped.
    private func settle(_ row: ShareOutboxRecord, _ error: Error) throws {
        if case GymCatalogError.photoMissing = error {
            try repository.listingRecord(row.targetId)?.remotePhotoPath = nil
            try context.save()
            return
        }
        let listing = try repository.listingRecord(row.targetId)
        if Kind(rawValue: row.kindRaw) == .confirm {
            listing?.confirmedByMe = false
        } else {
            listing?.visibilityRaw = GymVisibility.device.rawValue
            listing?.uploadStateRaw = UploadState.failed.rawValue
            listing?.uploadError = Self.message(for: error)
            listing?.updatedAt = now()
        }
        context.delete(row)
        try context.save()
    }

    private static func message(for error: Error) -> String {
        switch error as? GymCatalogError {
        case .gymNotShareable: gymUnderReview
        case .dailyLimit: dailyLimit
        default: couldNotShare
        }
    }

    // MARK: - Helpers

    private typealias Kind = ShareOutboxRecord.Kind

    private func rows() throws -> [ShareOutboxRecord] {
        try context.fetch(FetchDescriptor<ShareOutboxRecord>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    private func removeRows(kind: Kind, target: UUID) throws {
        try rows().filter { $0.kindRaw == kind.rawValue && $0.targetId == target }.forEach(context.delete)
    }

    private func itemRecord(_ id: UUID) throws -> EquipmentItemRecord? {
        try context.fetch(FetchDescriptor<EquipmentItemRecord>(predicate: #Predicate { $0.id == id })).first
    }
}
