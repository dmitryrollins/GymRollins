import Foundation
import GymCore
import SwiftData
import os

/// The persisted queue of shares and confirmations, run for the signed-in user. A row stays until the server has
/// answered, so a lost connection or a quit app never loses a share.
@MainActor
public final class ShareOutbox {
    static let gymUnderReview = "This gym is under review. Try again later."
    static let dailyLimit = "You've shared a lot today. Try again tomorrow."
    static let couldNotShare = "Couldn't share this one. Try again later."
    static let gymFull = "This gym's list is full."
    static let photoRefused = "Couldn't upload this photo. Try again tomorrow, or delete this item."
    static let notAllowed = "This one can't be shared from this account."
    static let reportDailyLimit = "You've sent a lot of reports today. Try again tomorrow."
    static let couldNotReport = "Couldn't send that report. Try again later."
    static let couldNotBlock = "Couldn't hide that user's equipment. Try again later."
    static let blockDailyLimit = "You've hidden a lot of people today. Try again tomorrow."
    static let log = Logger(subsystem: "com.rollins.gymrollins", category: "share-outbox")

    let repository: GymRepository
    let transport: GymCatalogTransport
    private let photoData: (String) -> Data?
    let now: () -> Date
    var running = false
    private var runAgainFor: UUID?
    private(set) var generation = 0
    /// An unblock is on the wire: a queued block must not go out meanwhile, or it would undo the unblock.
    var unblocking = false
    var cleanups: [Task<Void, Never>] = []

    /// The last error from reading or saving the queue itself, for the caller to log.
    public private(set) var storageError: Error?

    /// Why the last report or block the server refused was dropped, for the screen to show once. Cleared by
    /// `takeReportNotice()`.
    public internal(set) var reportNotice: String?

    /// A block went out, or an unblock was done: what the server returns for the gyms has changed, and the one on
    /// screen should read it again. Cleared by `takeRefreshRequest()`.
    var refreshRequested = false

    public init(repository: GymRepository, transport: GymCatalogTransport, photoData: @escaping (String) -> Data?,
                now: @escaping () -> Date) {
        self.repository = repository
        self.transport = transport
        self.photoData = photoData
        self.now = now
    }

    var context: ModelContext { repository.context }

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
        let queued = try rows().contains { $0.kindRaw == Kind.confirm.rawValue && $0.targetId == listingId }
        if !queued { context.insert(ShareOutboxRecord(kind: .confirm, targetId: listingId, ownerId: ownerId, now: now())) }
        // Tapping again shows it as confirmed again, though a refresh or a failed try had cleared it.
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
    /// for the caller to delete. The chosen listing is put in the cache in the same save when this phone doesn't have
    /// it yet, so the gym never shows less than it did while the confirmation waits. The photo I uploaded for the
    /// share is deleted from the bucket in the background.
    public func keepExisting(listingId: UUID, existingId: UUID, ownerId: UUID) throws -> String? {
        let mine = try repository.listingRecord(listingId)
        let uploaded = mine?.remotePhotoPath
        if let mine { try cacheChosen(existingId, at: mine.gymId, from: listingId) }
        let photo = try repository.removeListing(listingId)
        try removeRows(kind: .share, target: listingId)
        try showAgain(existingId)
        try enqueueConfirm(listingId: existingId, ownerId: ownerId)
        if let uploaded { deleteInBackground(uploaded) }
        return photo
    }

    /// Drops a share that hasn't reached the server (or whose answer hasn't come back): its queue row, the listing and
    /// the photo already uploaded for it. Returns the local photo file, for the caller to delete. A share whose
    /// request is out right now may still land; the next refresh then shows it as the user's own listing.
    public func cancelShare(listingId: UUID) throws -> String? {
        let uploaded = try repository.listingRecord(listingId)?.remotePhotoPath
        let photo = try repository.removeListing(listingId)
        try removeRows(kind: .share, target: listingId)
        try context.save()
        if let uploaded { deleteInBackground(uploaded) }
        return photo
    }

    /// The listings the server returned while the share waits for a choice.
    public func duplicates(listingId: UUID) throws -> [RemoteListing] {
        guard let data = try repository.listingRecord(listingId)?.duplicatesData else { return [] }
        return try JSONDecoder().decode([RemoteListing].self, from: data)
    }

    // MARK: - Running

    /// Called when the session ends or changes (sign-out, account switch, Erase All), before the rows are wiped.
    /// A run that is waiting on the server stops when the answer comes back, without touching any row: the answer
    /// belongs to a session that is gone. For the same account that is safe, because the server's side of a share
    /// or a confirmation is idempotent (the listing id is the phone's own), so the share just happens again later.
    public func invalidate() { generation += 1 }

    /// Runs the signed-in user's rows, oldest first, until a pass finds nothing left to send: a share queued while
    /// the run was going is sent by it too. Stops at the first offline or signed-out answer; other errors settle
    /// their row. A call made while a run is going returns at once, and the run makes sure it was heard.
    public func run(userId: UUID?) async { await run(userId: userId, only: nil) }

    /// `only` limits the run to those kinds (sign-out sends nothing else).
    func run(userId: UUID?, only kinds: Set<Kind>?) async {
        guard let userId else { return }
        guard !running else {
            runAgainFor = userId
            return
        }
        running = true
        defer { running = false }
        var next: UUID? = userId
        while let user = next {
            runAgainFor = nil
            await drain(userId: user, only: kinds)
            next = runAgainFor
        }
    }

    private enum Outcome { case next, stop }

    /// A row that stays queued after being tried (a photo the server lost) is tried twice in a run, then left for
    /// the next one, so a row that can't go through never keeps the run spinning.
    private static let attemptsPerRun = 2

    private func drain(userId: UUID, only kinds: Set<Kind>?) async {
        let token = generation
        var attempts: [UUID: Int] = [:]
        do {
            while token == generation, let row = try nextRow(for: userId, attempts: attempts, only: kinds) {
                attempts[row.id, default: 0] += 1
                if try await process(row, token: token) == .stop { return }
            }
        } catch {
            storageError = error
        }
    }

    private func nextRow(for userId: UUID, attempts: [UUID: Int], only kinds: Set<Kind>?) throws -> ShareOutboxRecord? {
        try rows().first { row in
            row.ownerId == userId && attempts[row.id, default: 0] < Self.attemptsPerRun
                && (kinds.map { $0.contains { $0.rawValue == row.kindRaw } } ?? true)
                && !(unblocking && row.kindRaw == Kind.block.rawValue)
        }
    }

    /// Thrown after an await when the session changed meanwhile: the run ends without touching anything.
    struct SessionChanged: Error {}

    func ensureCurrent(_ token: Int) throws {
        if token != generation { throw SessionChanged() }
    }

    private func process(_ row: ShareOutboxRecord, token: Int) async throws -> Outcome {
        do {
            switch Kind(rawValue: row.kindRaw) {
            case .share: try await share(row, token: token)
            case .confirm: try await confirm(row, token: token)
            case .report: try await sendReport(row, token: token)
            case .block: try await sendBlock(row, token: token)
            case nil: context.delete(row); try context.save()
            }
            return .next
        } catch is SessionChanged {
            return .stop
        } catch is CancellationError {
            return .stop
        } catch GymCatalogError.offline, GymCatalogError.signedOut {
            return .stop
        } catch {
            guard token == generation else { return .stop }
            try await settle(row, error)
            return .next
        }
    }

    private func share(_ row: ShareOutboxRecord, token: Int) async throws {
        guard let listing = try repository.listingRecord(row.targetId),
              let gym = try repository.gymRecord(listing.gymId) else {
            context.delete(row)
            try context.save()
            return
        }
        let hadId = gym.remoteId != nil
        let gymId = try await serverId(of: gym, token: token)
        let photo = try await uploadedPhoto(of: listing, token: token)
        let item = try itemRecord(listing.itemId)
        let loads = try JSONDecoder().decode(ListingLoads.self, from: listing.loadsData)
        let request = ShareRequest(listingId: listing.id, gymId: gymId, kindId: listing.kindId, brand: item?.brand,
                                   model: item?.model, loads: loads, quantity: listing.quantity,
                                   notes: listing.notes, photoPath: photo, forceNew: row.forceNew)
        let result = try await send(request, to: gym, hadStoredId: hadId, token: token)
        try ensureCurrent(token)
        switch result {
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

    /// Sends the share. A gym the server refuses (`gym_not_shareable`) under an id stored earlier is looked up by its
    /// place once: a moderator may have removed it and someone recreated the place under a new id. A different id
    /// replaces the stored one and the share goes there; the same id means it really is under review; no gym clears
    /// the stored id, and the listing shows the review message.
    private func send(_ request: ShareRequest, to gym: GymRecord, hadStoredId: Bool, token: Int) async throws
        -> ShareResult {
        do {
            return try await transport.share(request)
        } catch GymCatalogError.gymNotShareable where hadStoredId {
            let found = try await transport.publicGym(mapsPlaceId: gym.mapsPlaceId ?? "")
            try ensureCurrent(token)
            guard let found else {
                gym.remoteId = nil
                try context.save()
                throw GymCatalogError.gymNotShareable
            }
            guard found.id != request.gymId else { throw GymCatalogError.gymNotShareable }
            gym.remoteId = found.id
            try context.save()
            let moved = ShareRequest(listingId: request.listingId, gymId: found.id, kindId: request.kindId,
                                     brand: request.brand, model: request.model, loads: request.loads,
                                     quantity: request.quantity, notes: request.notes, photoPath: request.photoPath,
                                     forceNew: request.forceNew)
            return try await transport.share(moved)
        }
    }

    private func confirm(_ row: ShareOutboxRecord, token: Int) async throws {
        let count = try await transport.confirm(listingId: row.targetId)
        try ensureCurrent(token)
        if let listing = try repository.listingRecord(row.targetId) {
            listing.confirmCount = count
            listing.confirmedByMe = true
        }
        context.delete(row)
        try context.save()
    }

    /// The server's id for the gym, asking the server to create the gym the first time.
    private func serverId(of gym: GymRecord, token: Int) async throws -> UUID {
        if let known = gym.remoteId { return known }
        let id = try await transport.findOrCreateGym(mapsPlaceId: gym.mapsPlaceId ?? "", name: gym.name,
                                                     address: gym.address, latitude: gym.latitude,
                                                     longitude: gym.longitude)
        try ensureCurrent(token)
        gym.remoteId = id
        try context.save()
        return id
    }

    /// The name of the photo on the server. A name already stored means the upload happened: the retry skips it.
    private func uploadedPhoto(of listing: GymListingRecord, token: Int) async throws -> String? {
        if let known = listing.remotePhotoPath { return known }
        guard let file = listing.photoFile, let data = photoData(file) else { return nil }
        let name = "\(UUID().uuidString.lowercased()).jpg"
        let stored = try await transport.uploadSharedPhoto(data, name: name)
        try ensureCurrent(token)
        listing.remotePhotoPath = stored
        try context.save()
        return stored
    }

    /// An answer that isn't "done": the row either waits for another try or the listing shows why it stopped.
    private func settle(_ row: ShareOutboxRecord, _ error: Error) async throws {
        if Kind(rawValue: row.kindRaw) == .report || Kind(rawValue: row.kindRaw) == .block {
            return try settleModeration(row, error)
        }
        let listing = try repository.listingRecord(row.targetId)
        if case GymCatalogError.photoMissing = error {
            listing?.remotePhotoPath = nil
            try context.save()
            return
        }
        if Kind(rawValue: row.kindRaw) == .confirm {
            Self.log.error("Dropped a confirmation the server refused: \(String(describing: error), privacy: .public)")
            listing?.confirmedByMe = false
            context.delete(row)
            try context.save()
            return
        }
        let uploaded = listing?.remotePhotoPath
        listing?.visibilityRaw = GymVisibility.device.rawValue
        listing?.uploadStateRaw = UploadState.failed.rawValue
        listing?.uploadError = Self.message(for: error)
        listing?.updatedAt = now()
        // A retry uploads a fresh photo; the old object is deleted where the server has no listing using it.
        if Self.freesPhoto(after: error) { listing?.remotePhotoPath = nil }
        context.delete(row)
        try context.save()
        if let uploaded, Self.deletesPhoto(after: error) { await deleteUploaded(uploaded) }
    }

    private static func message(for error: Error) -> String {
        switch error as? GymCatalogError {
        case .gymNotShareable: gymUnderReview
        case .dailyLimit: dailyLimit
        case .gymFull: gymFull
        case .photoRefused, .photoInUse: photoRefused
        case .notAllowed: notAllowed
        default: couldNotShare
        }
    }

    /// Refusals after which no listing of mine uses the uploaded photo. A generic refusal is left out: its answer may
    /// be one this phone couldn't read, with the listing created.
    static func deletesPhoto(after error: Error) -> Bool {
        switch error as? GymCatalogError {
        case .dailyLimit, .gymNotShareable, .notAllowed, .gymFull: true
        default: false
        }
    }

    static func freesPhoto(after error: Error) -> Bool {
        if case .photoInUse = error as? GymCatalogError { return true }
        if case .photoRefused = error as? GymCatalogError { return true }
        return deletesPhoto(after: error)
    }

    // MARK: - Helpers

    typealias Kind = ShareOutboxRecord.Kind

    func rows() throws -> [ShareOutboxRecord] {
        try context.fetch(FetchDescriptor<ShareOutboxRecord>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    func removeRows(kind: Kind, target: UUID) throws {
        try rows().filter { $0.kindRaw == kind.rawValue && $0.targetId == target }.forEach(context.delete)
    }

    func itemRecord(_ id: UUID) throws -> EquipmentItemRecord? {
        try context.fetch(FetchDescriptor<EquipmentItemRecord>(predicate: #Predicate { $0.id == id })).first
    }
}
